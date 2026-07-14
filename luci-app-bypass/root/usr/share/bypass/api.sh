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
#             use_tables, egress_ifaces, redir_port }
do_status() {
	get_config
	prepare_selected_nodes
	local naive_present=0 chinadns_present=0 dns2socks_present=0 bypasscore_present=0 running=0
	[ -n "$NAIVE_BIN" ] && naive_present=1
	[ -n "$CHINADNS_BIN" ] && chinadns_present=1
	[ -n "$DNS2SOCKS_BIN" ] && dns2socks_present=1
	is_bypasscore "$BYPASSCORE_FILE" && bypasscore_present=1
	# BypassCore plus the ready marker represent a fully installed firewall/DNS
	# path; a stray core process during startup or teardown is not RUNNING.
	[ -f /var/lock/bypass_ready.lock ] && process_alive bypasscore && \
		[ "$(check_port_exists "$REDIR_PORT" tcp)" -gt 0 ] 2>/dev/null && running=1
	local use_tables egress active_redir_port
	use_tables=$(get_cache_var USE_TABLES)
	egress=$(get_cache_var EGRESS_IFACES)
	active_redir_port=$(get_cache_var ACL_GLOBAL_redir_port)

	json_init
	json_add_int running "$running"
	json_add_int naive_present "$naive_present"
	json_add_int chinadns_present "$chinadns_present"
	json_add_int dns2socks_present "$dns2socks_present"
	json_add_int bypasscore_present "$bypasscore_present"
	json_add_string use_tables "$use_tables"
	json_add_string egress_ifaces "$egress"
	# Retain the old singular key for callers written before per-node egress.
	json_add_string egress_iface "$egress"
	json_add_string redir_port "$active_redir_port"
	json_add_string version "$(cat "$APP_PATH/version" 2>/dev/null)"
	json_add_string default_node "$(default_proxy_node)"
	json_add_int selected_nodes "$(awk 'NF { n++ } END { print n + 0 }' "$TMP_PATH/selected_nodes" 2>/dev/null)"
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
	elif ! is_bypasscore "$BYPASSCORE_FILE"; then
		json_add_int code -1
		json_add_string error "bypasscore unavailable (set bypasscore_file from https://github.com/kinmeic/BypassCore/releases)"
	else
		if ! gen_bypasscore_config >/dev/null 2>&1; then
			json_init
			json_add_int code -1
			json_add_string error "invalid Bypass configuration"
		else
			local raw rc
			raw=$("$BYPASSCORE_FILE" -config "$BYPASSCORE_CFG" -test "$dest" 2>&1)
			rc=$?
			json_init
			json_add_int code "$rc"
			json_add_string matched "$(echo "$raw" | grep -iE 'outbound|tag|rule' | head -5 | tr '\n' ' ')"
			json_add_string raw "$raw"
		fi
	fi
	emit
}

# observatory -> { code, raw }
do_observe() {
	get_config
	json_init
	if ! is_bypasscore "$BYPASSCORE_FILE"; then
		json_add_int code -1
		json_add_string error "bypasscore unavailable"
	else
		if ! gen_bypasscore_config >/dev/null 2>&1; then
			json_init
			json_add_int code -1
			json_add_string error "invalid Bypass configuration"
		else
			local raw rc
			raw=$("$BYPASSCORE_FILE" -config "$BYPASSCORE_CFG" -observe 2>&1)
			rc=$?
			json_init
			json_add_int code "$rc"
			json_add_string raw "$raw"
		fi
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
	elif ! is_bypasscore "$BYPASSCORE_FILE"; then
		json_add_int code -1
		json_add_string error "bypasscore unavailable (set bypasscore_file from https://github.com/kinmeic/BypassCore/releases)"
	else
		# Make sure the config (incl. dns section) is up to date for this query.
		if ! gen_bypasscore_config >/dev/null 2>&1; then
			json_init
			json_add_int code -1
			json_add_string error "invalid Bypass configuration"
		else
			local raw rc
			raw=$("$BYPASSCORE_FILE" -config "$BYPASSCORE_CFG" -resolve "$domain" 2>&1)
			rc=$?
			json_init
			json_add_int code "$rc"
			json_add_string raw "$raw"
		fi
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
		local bin raw latency rc
		bin=$(first_type /usr/bin/tcping tcping)
		if [ -n "$bin" ]; then
			raw=$("$bin" -c 1 "$ip" "$port" 2>&1)
			rc=$?
			latency=$(echo "$raw" | grep -oE '[0-9]+(\.[0-9]+)?\s?ms' | head -1 | grep -oE '[0-9]+(\.[0-9]+)?')
			[ -n "$latency" ] || rc=1
			json_add_int code "$rc"
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
	local gen_rc=0
	gen_bypasscore_config >/dev/null 2>&1 || gen_rc=$?
	json_init
	if [ "$gen_rc" = "0" ] && [ -s "$BYPASSCORE_CFG" ]; then
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

do_clear_nftset() {
	local nft_bin rc=0 set
	nft_bin=$(first_type /usr/sbin/nft nft)
	[ -n "$nft_bin" ] || rc=1
	if [ "$rc" = "0" ]; then
		# Flush only rule-result sets. Resolver and node-address whitelists are
		# safety state and must not disappear while the service is live.
		for set in bypass_direct_dns bypass_direct_dns6; do
			"$nft_bin" flush set inet bypass "$set" 2>/dev/null || true
		done
	fi
	json_init
	json_add_int code "$rc"
	[ "$rc" = "0" ] && json_add_string msg "NFTSet cleared" || json_add_string error "nft not found"
	emit
}

# interfaces -> { interfaces: ["wan","wan1",...] } (for the egress dropdowns)
do_interfaces() {
	json_init
	json_add_array interfaces
	local iface interfaces
	interfaces=$(uci -q show network 2>/dev/null | sed -n 's/^network\.\([^.=]*\)=interface$/\1/p')
	interfaces="${interfaces}
$(ubus call network.interface dump 2>/dev/null | jsonfilter -e '@.interface[*].interface' 2>/dev/null)"
	for iface in $(printf '%s\n' "$interfaces" | awk 'NF && !seen[$0]++' | sort); do
		[ -n "$iface" ] && [ "$iface" != "loopback" ] && json_add_string '' "$iface"
	done
	json_close_array
	emit
}

# connect_status <type> <url> -> { ping_type:"curl", use_time:N } | { status:0 }
# Router OUTPUT traffic is intentionally not transparently redirected. Test
# foreign sites through the Default Naive node's SOCKS listener so these cards
# report proxy reachability rather than the router's direct-WAN reachability.
do_connect_status() {
	local type=$1 url=$2
	local out code use_time node socks_port
	case "$type" in baidu|google|github) ;; *) type="" ;; esac
	[ -n "$type" ] && [ -n "$url" ] || { json_init; json_add_int status 0; emit; return; }
	get_config
	if [ "$type" = "baidu" ]; then
		out=$(curl -s -o /dev/null -w '%{time_total}' --connect-timeout 3 --max-time 8 "$url" 2>/dev/null)
		code=$?
	else
		prepare_selected_nodes
		node=$(default_proxy_node)
		socks_port=$(node_socks_port "$node")
		if [ -z "$node" ] || [ -z "$socks_port" ] || \
		   [ "$(check_port_exists "$socks_port" tcp)" -le 0 ] 2>/dev/null; then
			code=1
			out=""
		else
			out=$(curl -s -o /dev/null -w '%{time_total}' --socks5-hostname "127.0.0.1:${socks_port}" \
				--connect-timeout 5 --max-time 12 "$url" 2>/dev/null)
			code=$?
		fi
	fi
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

# geo_view <action> <value> -> { code, output }
# Wraps the geoview binary for the Geo View page.
#   lookup  (domain/IP → geo rule list)
#   extract (geoip:cc / geosite:name → member list)
#   list    (enumerate every entry name in geoip.dat and geosite.dat)
# Mirrors passwall2's controller geo_view() invocation:
#   lookup:  geoview -type <geoip|geosite> -action lookup  -input <dat> -value <q> -lowmem=true
#   extract: geoview -type <geoip|geosite> -action extract -input <dat> -list  <c> -lowmem=true
#   list:    geoview -type <geoip|geosite> -action extract -input <dat>           -lowmem=true

# Print shunt-rule section IDs containing a GeoData lookup result. This mirrors
# passwall2 controller's get_rules(): compare the part after geosite:/geoip:
# and ignore commented lines.
geo_rules_for_value() {
	local search=$1 geo_type=$2 sid list line main
	search=$(printf '%s' "$search" | tr '[:upper:]' '[:lower:]')
	for sid in $(uci -q show "$CONFIG" 2>/dev/null | sed -n 's/^bypass\.\([^.=]*\)=shunt_rules$/\1/p'); do
		if [ "$geo_type" = "geoip" ]; then
			list=$(config_n_get "$sid" ip_list)
		else
			list=$(config_n_get "$sid" domain_list)
		fi
		while IFS= read -r line; do
			line=$(printf '%s' "$line" | tr -d '\r' | tr '[:upper:]' '[:lower:]')
			[ -n "$line" ] || continue
			case "$line" in *'#'*) continue ;; esac
			case "$line" in *:*) main=${line#*:} ;; *) main=$line ;; esac
			if [ "$geo_type" = "geoip" ] && { echo "$search" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$|:'; }; then
				case "$main" in *"$search"*) echo "$sid"; break ;; esac
			elif [ "$main" = "$search" ]; then
				echo "$sid"
				break
			fi
		done <<-EOF
		$list
		EOF
	done
}

do_geo_view() {
	local action=$1 value=$2
	local bin geoip_path geosite_path
	bin=$(first_type "$(config_t_get global_app geoview_file /usr/bin/geoview)" geoview)
	geoip_path=$(get_geo_asset_path geoip)
	geosite_path=$(get_geo_asset_path geosite)
	json_init
	if [ -z "$bin" ]; then
		json_add_int code -1
		json_add_string error "geoview binary not found"
		emit
		return
	fi
	if [ -z "$action" ] || { [ "$action" != "list" ] && [ -z "$value" ]; }; then
		json_add_int code -1
		json_add_string error "missing action or value"
		emit
		return
	fi

	local geo_type file_path out rc
	if [ "$action" = "lookup" ]; then
		# IP → geoip; anything else → geosite.
		if echo "$value" | grep -qE "^([0-9]{1,3}[\.]){3}[0-9]{1,3}$" || \
		   echo "$value" | grep -qE "([A-Fa-f0-9]{1,4}::?){1,7}[A-Fa-f0-9]{1,4}"; then
			geo_type="geoip"
			file_path="$geoip_path"
		else
			geo_type="geosite"
			file_path="$geosite_path"
		fi
		out=$("$bin" -type "$geo_type" -action lookup -input "$file_path" -value "$value" -lowmem=true 2>&1)
		rc=$?
		if [ "$rc" = "0" ] && [ -n "$out" ]; then
			local tmp line rules
			tmp=$(mktemp -d 2>/dev/null)
			if [ -n "$tmp" ]; then
				printf '%s\n' "$out" | awk '{ print tolower($0) }' | while IFS= read -r line; do
					[ -n "$line" ] || continue
					printf '%s:%s\n' "$geo_type" "$line" >> "$tmp/output"
					geo_rules_for_value "$line" "$geo_type" >> "$tmp/rules"
				done
				geo_rules_for_value "$value" "$geo_type" >> "$tmp/rules"
				rules=$(awk '!seen[$0]++' "$tmp/rules" 2>/dev/null)
				out=$(cat "$tmp/output" 2>/dev/null)
				if [ -n "$rules" ]; then
					out="${out}
--------------------
Rules containing this value:
${rules}"
				fi
				rm -rf "$tmp"
			fi
		fi
	elif [ "$action" = "extract" ]; then
		# Parse geoip:<list> or geosite:<list>.
		case "$value" in
			geoip:*)
				geo_type="geoip"
				file_path="$geoip_path"
				value="${value#geoip:}"
				;;
			geosite:*)
				geo_type="geosite"
				file_path="$geosite_path"
				value="${value#geosite:}"
				;;
			*)
				json_add_int code -1
				json_add_string error "format: geoip:cn or geosite:gfw"
				emit
				return
				;;
		esac
		out=$("$bin" -type "$geo_type" -action extract -input "$file_path" -list "$value" -lowmem=true 2>&1)
		rc=$?
	elif [ "$action" = "list" ]; then
		# Enumerate every entry name in both geoip.dat and geosite.dat.
		# geoview with -action extract and no -list prints "Available codes:" + names.
		local geo_codes site_codes
		if [ -n "$geoip_path" ] && [ -f "$geoip_path" ]; then
			geo_codes=$("$bin" -type geoip -action extract -input "$geoip_path" -lowmem=true 2>/dev/null \
				| sed -e '1{/^Available codes:$/d;}' -e '/^$/d' -e 's/^/geoip:/')
		fi
		if [ -n "$geosite_path" ] && [ -f "$geosite_path" ]; then
			site_codes=$("$bin" -type geosite -action extract -input "$geosite_path" -lowmem=true 2>/dev/null \
				| sed -e '1{/^Available codes:$/d;}' -e '/^$/d' -e 's/^/geosite:/')
		fi
		out=$(
			[ -n "$geo_codes" ] && printf '%s\n' "$geo_codes"
			[ -n "$site_codes" ] && printf '%s\n' "$site_codes"
		)
		[ -n "$out" ] && rc=0 || rc=1
	else
		json_add_int code -1
		json_add_string error "unknown action: $action"
		emit
		return
	fi

	json_add_int code "${rc:-1}"
	json_add_string output "$out"
	emit
}

# create_backup -> { code, backup }  (backup = base64-encoded tar.gz of /etc/config/bypass)
# Mirrors passwall2's backup feature (single config file, no server config).
do_create_backup() {
	local tmp tarball b64
	tmp=$(mktemp -d 2>/dev/null) || { json_init; json_add_int code -1; json_add_string error "mktemp failed"; emit; return; }
	tarball="$tmp/bypass-backup.tar.gz"
	if tar -C / -czf "$tarball" etc/config/bypass 2>/dev/null; then
		b64=$(base64 "$tarball" 2>/dev/null | tr -d '\n')
		json_init
		json_add_int code 0
		json_add_string backup "$b64"
		json_add_string filename "bypass-$(date +%y%m%d%H%M)-backup.tar.gz"
	else
		json_init
		json_add_int code -1
		json_add_string error "tar failed"
	fi
	emit
	rm -rf "$tmp"
}

# restore_backup <base64> -> { code }
# Receives a base64-encoded tar.gz, decodes, extracts over /etc/config/bypass.
do_restore_backup() {
	local b64=$1 tmp tarball
	[ -z "$b64" ] && { json_init; json_add_int code -1; json_add_string error "missing backup data"; emit; return; }
	tmp=$(mktemp -d 2>/dev/null) || { json_init; json_add_int code -1; json_add_string error "mktemp failed"; emit; return; }
	tarball="$tmp/restore.tar.gz"
	echo "$b64" | base64 -d > "$tarball" 2>/dev/null
	local members
	members=$(tar -tzf "$tarball" 2>/dev/null) || members=""
	if [ "$members" = "etc/config/bypass" ] || [ "$members" = "./etc/config/bypass" ]; then
		mkdir -p "$tmp/extract"
		tar -C "$tmp/extract" -xzf "$tarball" "$members" 2>/dev/null
		if [ -s "$tmp/extract/${members#./}" ] && uci -q -c "$tmp/extract/etc/config" show bypass >/dev/null 2>&1; then
			cp -f "$tmp/extract/${members#./}" /etc/config/bypass
			chmod 600 /etc/config/bypass 2>/dev/null
			json_init
			json_add_int code 0
			json_add_string msg "restored; restart bypass to apply"
		else
			json_init
			json_add_int code -1
			json_add_string error "backup does not contain a valid config"
		fi
	else
		json_init
		json_add_int code -1
		json_add_string error "invalid backup archive"
	fi
	emit
	rm -rf "$tmp"
}

# reset_config -> { code }
# Restore factory defaults: stop the service, copy 0_default_config, clear log.
do_reset_config() {
	json_init
	if [ -n "${IPKG_INSTROOT}" ]; then
		json_add_int code -1
		json_add_string error "reset is unavailable during package installation"
	elif /etc/init.d/bypass stop >/dev/null 2>&1 && \
	     cp -f /usr/share/bypass/0_default_config /etc/config/bypass 2>/dev/null; then
		chmod 600 /etc/config/bypass 2>/dev/null
		: > /tmp/log/bypass.log 2>/dev/null
		# Do not reload rpcd inside its own file.exec request: doing so can
		# truncate this JSON response in exactly the same way as opkg upgrades.
		json_add_int code 0
	else
		json_add_int code -1
		json_add_string error "failed to restore the factory configuration"
	fi
	emit
}

usage() {
	echo "Usage: $0 {status|route_test|observe|resolve|node_tcping|config_preview|rule_update|log_tail|clear_log|clear_nftset|interfaces|connect_status|geo_view|create_backup|restore_backup|reset_config} [args]" >&2
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
		clear_nftset)   do_clear_nftset ;;
		interfaces)     do_interfaces ;;
		connect_status) do_connect_status "$1" "$2" ;;
		geo_view)       do_geo_view "$1" "$2" ;;
		create_backup)  do_create_backup ;;
		restore_backup) do_restore_backup "$1" ;;
		reset_config)   do_reset_config ;;
		*) usage; exit 1 ;;
	esac
}

main "$@"
