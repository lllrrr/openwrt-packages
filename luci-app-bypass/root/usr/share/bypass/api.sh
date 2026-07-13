#!/bin/sh
# Copyright (c) 2026 Eugene Chan
# SPDX-License-Identifier: MIT
#
# rpcd `file.exec` backend for luci-app-bypass. The LuCI JS frontend calls
#   fs.exec('/usr/share/bypass/api.sh', [action, ...args])
# and parses the JSON object printed on stdout. All output is a single JSON
# line so it is trivial to consume with JSON.parse().

. /lib/functions.sh
. /usr/share/libubox/jshn.sh
. ${APP_PATH:-/usr/share/bypass}/utils.sh
# Source app.sh to inherit get_config / gen_bypasscore_config. Guard against the
# dispatcher: setting APP_SOURCED=1 makes app.sh define functions and return
# without running its own start/stop argument handler.
APP_SOURCED=1 . ${APP_PATH:-/usr/share/bypass}/app.sh

emit() {
	json_dump
}

# status -> { running, naive_present, chinadns_present, bypasscore_present,
#             bypasscore_linux_elf, use_tables, egress_iface, redir_port }
do_status() {
	get_config
	local naive_present=0 chinadns_present=0 bypasscore_present=0 elf=0 running=0
	[ -n "$NAIVE_BIN" ] && naive_present=1
	[ -n "$CHINADNS_BIN" ] && chinadns_present=1
	[ -x "$BYPASSCORE_FILE" ] && bypasscore_present=1
	is_linux_elf "$BYPASSCORE_FILE" 2>/dev/null && elf=1
	# Running if any bypass-managed proxy process is alive.
	busybox pgrep -f "$TMP_BIN_PATH" >/dev/null 2>&1 && running=1
	local use_tables egress
	use_tables=$(get_cache_var USE_TABLES)
	egress=$(get_cache_var EGRESS_IFACE)

	json_init
	json_add_int running "$running"
	json_add_int naive_present "$naive_present"
	json_add_int chinadns_present "$chinadns_present"
	json_add_int bypasscore_present "$bypasscore_present"
	json_add_int bypasscore_linux_elf "$elf"
	json_add_string use_tables "$use_tables"
	json_add_string egress_iface "$egress"
	json_add_string redir_port "$REDIR_PORT"
	json_add_string node "$NODE"
	emit
}

# route_test <net:host:port> -> { code, matched, raw }
do_route_test() {
	local dest=$1
	get_config
	json_init
	if [ -z "$dest" ]; then
		json_add_int code -1
		json_add_string error "missing destination"
	elif ! is_linux_elf "$BYPASSCORE_FILE" 2>/dev/null; then
		json_add_int code -1
		json_add_string error "bypasscore unavailable (set bypasscore_file to a Linux ELF from https://github.com/kinmeic/BypassCore/releases)"
	else
		local raw
		raw=$("$BYPASSCORE_FILE" -config "$BYPASSCORE_CFG" -test "$dest" 2>&1)
		local rc=$?
		json_add_int code "$rc"
		json_add_string matched "$(echo "$raw" | grep -iE 'outbound|tag|rule' | head -5 | tr '\n' ' ')"
		json_add_string raw "$raw"
	fi
	emit
}

# observatory -> { code, raw }
do_observe() {
	get_config
	json_init
	if ! is_linux_elf "$BYPASSCORE_FILE" 2>/dev/null; then
		json_add_int code -1
		json_add_string error "bypasscore unavailable"
	else
		local raw
		raw=$("$BYPASSCORE_FILE" -config "$BYPASSCORE_CFG" -observe 2>&1)
		json_add_int code $?
		json_add_string raw "$raw"
	fi
	emit
}

# resolve <domain> -> { code, raw }  (BypassCore -resolve, uses the dns section)
do_resolve() {
	local domain=$1
	get_config
	json_init
	if [ -z "$domain" ]; then
		json_add_int code -1
		json_add_string error "missing domain"
	elif ! is_linux_elf "$BYPASSCORE_FILE" 2>/dev/null; then
		json_add_int code -1
		json_add_string error "bypasscore unavailable (set bypasscore_file to a Linux ELF from https://github.com/kinmeic/BypassCore/releases)"
	else
		# Make sure the config (incl. dns section) is up to date for this query.
		gen_bypasscore_config >/dev/null 2>&1
		local raw
		raw=$("$BYPASSCORE_FILE" -config "$BYPASSCORE_CFG" -resolve "$domain" 2>&1)
		json_add_int code $?
		json_add_string raw "$raw"
	fi
	emit
}

# node_tcping <node_id> -> { code, latency_ms, raw }
do_node_tcping() {
	local node_id=$1
	[ -z "$node_id" ] && { json_init; json_add_int code -1; json_add_string error "missing node"; emit; return; }
	local address port
	address=$(config_n_get "$node_id" address)
	port=$(config_n_get "$node_id" port)
	json_init
	if [ -z "$address" ] || [ -z "$port" ]; then
		json_add_int code -1
		json_add_string error "node has no address/port"
	else
		local ip
		ip=$(get_host_ip ipv4 "$address" 2>/dev/null)
		[ -z "$ip" ] && ip=$address
		local bin raw latency
		bin=$(first_type /usr/bin/tcping tcping)
		if [ -n "$bin" ]; then
			raw=$("$bin" -c 1 "$ip" "$port" 2>&1)
			latency=$(echo "$raw" | grep -oE '[0-9]+(\.[0-9]+)?\s?ms' | head -1 | grep -oE '[0-9]+(\.[0-9]+)?')
			json_add_int code 0
			json_add_string latency_ms "${latency:-0}"
		else
			json_add_int code -1
			json_add_string error "tcping not installed"
		fi
		json_add_string raw "$raw"
	fi
	emit
}

# config_preview -> { config }  (regenerate + cat)
do_config_preview() {
	get_config
	gen_bypasscore_config >/dev/null 2>&1
	json_init
	if [ -s "$BYPASSCORE_CFG" ]; then
		# Escape into a JSON string via jshn.
		local content
		content=$(cat "$BYPASSCORE_CFG")
		json_add_string config "$content"
	else
		json_add_string config ""
		json_add_string error "config not generated"
	fi
	emit
}

# rule_update -> { code, msg }
do_rule_update() {
	json_init
	if [ -x "$APP_PATH/rule_update.sh" ]; then
		local out
		out=$("$APP_PATH/rule_update.sh" 2>&1)
		json_add_int code $?
		json_add_string msg "$out"
	else
		json_add_int code -1
		json_add_string error "rule_update.sh missing"
	fi
	emit
}

# log_tail [n] -> { log }
do_log_tail() {
	local n=${1:-200}
	json_init
	if [ -s "$LOG_FILE" ]; then
		json_add_string log "$(tail -n "$n" "$LOG_FILE" 2>/dev/null)"
	else
		json_add_string log ""
		json_add_string error "no log yet"
	fi
	emit
}

# clear_log
do_clear_log() {
	: > "$LOG_FILE"
	json_init
	json_add_int code 0
	emit
}

# interfaces -> { interfaces: ["wan","wan1",...] } (for the egress dropdowns)
do_interfaces() {
	json_init
	json_add_array interfaces
	local iface
	for iface in $(ubus call network.interface.dump 2>/dev/null | \
		jsonfilter -e '@.interface[@.interface=true].interface' 2>/dev/null); do
		[ -n "$iface" ] && json_add_string '' "$iface"
	done
	json_close_array
	emit
}

# connect_status <type> <url> -> { ping_type:"curl", use_time:N } | { status:0 }
# Mirrors passwall2's connect_status: curl a URL and report the round-trip in
# ms. Used by the Basic Settings status cards (Baidu/Google/GitHub latency).
do_connect_status() {
	local type=$1 url=$2
	local out code use_time
	# curl -w time_total prints the total time in seconds (e.g. 0.234).
	out=$(curl -s -o /dev/null -w '%{time_total}' --connect-timeout 3 --max-time 5 "$url" 2>/dev/null)
	code=$?
	use_time=$(echo "$out" | awk '{printf "%d", $1*1000}')
	json_init
	if [ "$code" = "0" ] && [ -n "$use_time" ]; then
		json_add_string ping_type "curl"
		json_add_int use_time "$use_time"
	else
		json_add_int status 0
	fi
	emit
}

usage() {
	echo "Usage: $0 {status|route_test|observe|resolve|node_tcping|config_preview|rule_update|log_tail|clear_log|interfaces|connect_status} [args]" >&2
}

main() {
	local action=$1
	shift
	case "$action" in
		status)         do_status ;;
		route_test)     do_route_test "$1" ;;
		observe)        do_observe ;;
		resolve)        do_resolve "$1" ;;
		node_tcping)    do_node_tcping "$1" ;;
		config_preview) do_config_preview ;;
		rule_update)    do_rule_update ;;
		log_tail)       do_log_tail "$1" ;;
		clear_log)      do_clear_log ;;
		interfaces)     do_interfaces ;;
		connect_status) do_connect_status "$1" "$2" ;;
		*) usage; exit 1 ;;
	esac
}

main "$@"
