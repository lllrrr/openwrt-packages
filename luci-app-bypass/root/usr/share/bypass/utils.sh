#!/bin/sh
# Copyright (c) 2026 Eugene Chan
# SPDX-License-Identifier: MIT
#
# Shared library for luci-app-bypass. Sourced by app.sh, the nftables backend, the init script and the rpcd api.sh helper.
#
# Conventions mirror openwrt-passwall2/utils.sh but are trimmed: no Lua runtime,
# no i18n indirection, plain-text logging.

CONFIG=bypass
APP_PATH=/usr/share/${CONFIG}
TMP_PATH=/tmp/etc/${CONFIG}
TMP_PATH2=${TMP_PATH}_tmp
LOCK_PATH=/tmp/lock
LOG_FILE=/tmp/log/${CONFIG}.log
TMP_ACL_PATH=${TMP_PATH}/acl
TMP_BIN_PATH=${TMP_PATH}/bin
TMP_IFACE_PATH=${TMP_PATH}/iface
TMP_ROUTE_PATH=${TMP_PATH}/route
TMP_SCRIPT_FUNC_PATH=${TMP_PATH}/script_func
TMP_PROCESS_LIST_PATH=${TMP_PATH}/process_list
BYPASSCORE_CFG=${TMP_PATH}/bypasscore/config.json

. /lib/functions/network.sh

# ------------------------------------------------------------------------------
# UCI access (plain uci CLI; no libuci-lua needed)
# ------------------------------------------------------------------------------

config_get_type() {
	local ret=$(uci -q get "${CONFIG}.${1}" 2>/dev/null)
	echo "${ret:=$2}"
}

config_n_get() {
	local ret=$(uci -q get "${CONFIG}.${1}.${2}" 2>/dev/null)
	echo "${ret:=$3}"
}

config_t_get() {
	local index=${4:-0}
	local ret=$(uci -q get "${CONFIG}.@${1}[${index}].${2}" 2>/dev/null)
	echo "${ret:=${3}}"
}

config_t_set() {
	local index=${4:-0}
	uci -q set "${CONFIG}.@${1}[${index}].${2}=${3}" 2>/dev/null
}

eval_set_val() {
	for i in "$@"; do
		for j in $i; do
			eval "$j"
		done
	done
}

eval_unset_val() {
	for i in "$@"; do
		for j in $i; do
			eval unset "$j"
		done
	done
}

# ------------------------------------------------------------------------------
# State cache (persisted across sub-invocations in $TMP_PATH/var)
# ------------------------------------------------------------------------------

eval_cache_var() {
	[ -s "$TMP_PATH/var" ] && eval "$(cat "$TMP_PATH/var")"
}

get_cache_var() {
	local key="${1}"
	[ -n "${key}" ] && [ -s "$TMP_PATH/var" ] && {
		echo "$(cat "$TMP_PATH/var" | grep "^${key}=" | awk -F '=' '{print $2}' | tail -n 1 | awk -F'"' '{print $2}')"
	}
}

set_cache_var() {
	local key="${1}"
	shift 1
	local val="$*"
	[ -n "${key}" ] && [ -n "${val}" ] && {
		[ ! -d "$TMP_PATH" ] && mkdir -p "$TMP_PATH"
		sed -i "/${key}=/d" "$TMP_PATH/var" >/dev/null 2>&1
		echo "${key}=\"${val}\"" >> "$TMP_PATH/var"
		eval "${key}=\"${val}\""
	}
}

# ------------------------------------------------------------------------------
# Logging (plain text; i18n is handled in the LuCI JS frontend)
# ------------------------------------------------------------------------------

echolog() {
	echo -e "$*" >>"$LOG_FILE"
}

echolog_date() {
	local d
	d="$(date "+%Y-%m-%d %H:%M:%S")"
	echolog "$d: $*"
}

log() {
	local num="$1"
	shift
	local fmt="$1"
	shift
	local content
	# Substitute printf-style %s/%d when value args are present; otherwise the
	# message is a plain literal string.
	if [ "$#" -gt 0 ]; then
		content=$(printf -- "$fmt" "$@")
	else
		content="$fmt"
	fi
	local indent=""
	if [ "$num" -ge 1 ] 2>/dev/null; then
		local i
		for i in $(seq 1 "$num"); do
			indent="${indent}  "
		done
		echolog_date "${indent}- ${content}"
	else
		echolog_date "${content}"
	fi
}

clean_log() {
	local logsnum
	logsnum=$(cat "$LOG_FILE" 2>/dev/null | wc -l)
	[ "$logsnum" -gt 1000 ] && {
		echo "" > "$LOG_FILE"
		log 0 "Log file too long, cleared."
	}
}

# ------------------------------------------------------------------------------
# Binary / port helpers
# ------------------------------------------------------------------------------

first_type() {
	[ "${1#/}" != "$1" ] && [ -x "$1" ] && echo "$1" && return
	for p in "/bin/$1" "/usr/bin/$1" "${TMP_BIN_PATH:-/tmp}/$1"; do
		[ -x "$p" ] && echo "$p" && return
	done
	command -v "$1" 2>/dev/null || command -v "$2" 2>/dev/null
}

check_port_exists() {
	local port=$1
	local protocol=$2
	[ -n "$protocol" ] || protocol="tcp,udp"
	local result=
	if [ "$protocol" = "tcp" ]; then
		result=$(netstat -tln 2>/dev/null | grep -c ":$port ")
	elif [ "$protocol" = "udp" ]; then
		result=$(netstat -uln 2>/dev/null | grep -c ":$port ")
	elif [ "$protocol" = "tcp,udp" ]; then
		result=$(netstat -tuln 2>/dev/null | grep -c ":$port ")
	fi
	echo "${result}"
}

get_new_port() {
	local default_start_port=2001
	local min_port=1025
	local max_port=49151
	local port=$1
	local last_get_new_port_auto
	if [ "$1" = "auto" ]; then
		last_get_new_port_auto=$(get_cache_var "last_get_new_port_auto")
		if [ -n "$last_get_new_port_auto" ]; then
			port=$last_get_new_port_auto
			port=$(expr "$port" + 1)
		else
			port=$default_start_port
		fi
	fi
	[ "$port" -lt $min_port ] 2>/dev/null && port=$default_start_port
	[ "$port" -gt $max_port ] 2>/dev/null && port=$default_start_port
	local protocol
	protocol=$(echo "$2" | tr 'A-Z' 'a-z')
	local result
	result=$(check_port_exists "$port" "$protocol")
	if [ "$result" != 0 ]; then
		local temp=
		if [ "$port" -lt $max_port ]; then
			temp=$(expr "$port" + 1)
		elif [ "$port" -gt $min_port ]; then
			temp=$(expr "$port" - 1)
		else
			temp=$default_start_port
		fi
		get_new_port "$temp" "$protocol"
	else
		[ "$1" = "auto" ] && set_cache_var "last_get_new_port_auto" "$port"
		echo "$port"
	fi
}

# ------------------------------------------------------------------------------
# Process launch (symlink into $TMP_BIN_PATH so pgrep -f $TMP_BIN_PATH works),
# with optional queueing for a deferred run_process_queue() barrier.
# ------------------------------------------------------------------------------

ln_run() {
	local queue_run=${1}
	local file_func=${2}
	local ln_name=${3}
	local output=${4}
	shift 4

	if [ "${file_func%%/*}" != "${file_func}" ]; then
		[ ! -L "${file_func}" ] && {
			ln -s "${file_func}" "${TMP_BIN_PATH}/${ln_name}" >/dev/null 2>&1
			file_func="${TMP_BIN_PATH}/${ln_name}"
		}
		[ -x "${file_func}" ] || log 1 "%s is not executable: %s %s" "${file_func}" "${file_func}" "$*"
	fi
	[ -n "${file_func}" ] || log 1 "%s not found, cannot start." "${ln_name}"

	[ "${queue_run}" = "1" ] && {
		mkdir -p "$TMP_PROCESS_LIST_PATH"
		process_count=$(ls "$TMP_PROCESS_LIST_PATH" 2>/dev/null | grep -v "^_" | wc -l)
		process_count=$((process_count + 1))
		echo "${file_func:-log 1 "${ln_name}"} $* >${output}" > "$TMP_PROCESS_LIST_PATH/$process_count"
		return
	}

	${file_func:-log 1 "${ln_name}"} "$@" >"${output}" 2>&1 &

	[ -n "$NO_REC_PROCESS" ] && return

	process_count=$(ls "$TMP_SCRIPT_FUNC_PATH" 2>/dev/null | grep -v "^_" | wc -l)
	process_count=$((process_count + 1))
	echo "${file_func:-log 1 "${ln_name}"} $* >${output}" > "$TMP_SCRIPT_FUNC_PATH/$process_count"
}

run_process_queue() {
	[ -d "${TMP_PROCESS_LIST_PATH}" ] && {
		for filename in $(ls "${TMP_PROCESS_LIST_PATH}" 2>/dev/null); do
			cmd=$(cat "${TMP_PROCESS_LIST_PATH}/${filename}")
			cmd_check=$(echo "$cmd" | awk -F '>' '{print $1}')
			icount=$(busybox pgrep -f "$(echo "$cmd_check")" 2>/dev/null | wc -l)
			if [ "$icount" = 0 ]; then
				eval "$(echo "nohup ${cmd} 2>&1 &")" >/dev/null 2>&1 &
			fi
			rm -rf "${TMP_PROCESS_LIST_PATH}/${filename}"
		done
	}
	rm -rf "${TMP_PROCESS_LIST_PATH}"
}

kill_all() {
	kill -9 $(pidof "$@" 2>/dev/null) >/dev/null 2>&1
}

# ------------------------------------------------------------------------------
# Host / IP resolution (via resolveip; falls back to nslookup)
# ------------------------------------------------------------------------------

get_host_ip() {
	local family=$1
	local host=$2
	local count=$3
	[ -z "$count" ] && count=3
	local isip=""
	local ip=""
	if [ "$family" = "ipv6" ]; then
		isip=$(echo "$host" | grep -E "([A-Fa-f0-9]{1,4}::?){1,7}[A-Fa-f0-9]{1,4}")
		[ -n "$isip" ] && ip=$(echo "$host" | tr -d '[]')
	else
		isip=$(echo "$host" | grep -E "([0-9]{1,3}[\.]){3}[0-9]{1,3}")
		[ -n "$isip" ] && ip=$isip
	fi
	[ -z "$isip" ] && {
		local t=4
		[ "$family" = "ipv6" ] && t=6
		local resolved
		resolved=$(resolveip -$t -t "$count" "$host" 2>/dev/null | awk 'NR==1{print}')
		ip=$resolved
	}
	[ -n "$ip" ] && echo "$ip"
}

get_node_host_ip() {
	local ip
	local address
	address=$(config_n_get "$1" address)
	[ -n "$address" ] && {
		local use_ipv6
		use_ipv6=$(config_n_get "$1" use_ipv6)
		local family="ipv4"
		[ "$use_ipv6" = "1" ] && family="ipv6"
		ip=$(get_host_ip "$family" "$address")
	}
	echo "$ip"
}

# Resolve all A records for a host (DNS round-robin safe). Writes one IP per
# line to stdout (used to populate the bypass_uplink egress set).
resolve_all_ipv4() {
	local host=$1
	[ -z "$host" ] && return 0
	# Already an IP?
	echo "$host" | grep -qE "([0-9]{1,3}[\.]){3}[0-9]{1,3}" && {
		echo "$host"
		return 0
	}
	resolveip -4 -t 3 "$host" 2>/dev/null | awk '!seen[$0]++'
}

host_from_url() {
	local f=$1
	f="${f##http://}"
	f="${f##https://}"
	f="${f##ftp://}"
	f="${f##*:*@}"
	f="${f##*@}"
	f="${f%%/*}"
	echo "${f%%:*}"
}

# ------------------------------------------------------------------------------
# WAN / local IP enumeration
# ------------------------------------------------------------------------------

get_wan_ips() {
	local family=$1
	local NET_ADDR
	local iface
	local INTERFACES
	INTERFACES=$(ubus call network.interface dump 2>/dev/null | jsonfilter -e \
		'@.interface[!(@.interface ~ /lan/) && !(@.l3_device ~ /\./) && @.route[0]].interface' 2>/dev/null)
	for iface in $INTERFACES; do
		local addr
		if [ "$family" = "ip6" ]; then
			network_get_ipaddr6 addr "$iface"
			case "$addr" in
				""|fe80*) continue ;;
			esac
		else
			network_get_ipaddr addr "$iface"
			case "$addr" in
				""|"0.0.0.0") continue ;;
			esac
		fi
		case " $NET_ADDR " in
			*" $addr "*) ;;
			*) NET_ADDR="${NET_ADDR:+$NET_ADDR }$addr" ;;
		esac
	done
	echo "$NET_ADDR"
}

get_local_ips() {
	local family=$1
	local ALL_IPS WAN_IPS ip NET_ADDR
	if [ "$family" = "ip6" ]; then
		ALL_IPS=$(ip -o -6 addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
		WAN_IPS=$(get_wan_ips ip6)
	else
		ALL_IPS=$(ip -o -4 addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
		WAN_IPS=$(get_wan_ips ip4)
	fi
	[ "$family" = "ip6" ] && ALL_IPS="$ALL_IPS ::1"
	[ "$family" != "ip6" ] && ALL_IPS="$ALL_IPS 127.0.0.1"
	for ip in $ALL_IPS; do
		case "$ip" in
			""|0.0.0.0|::) continue ;;
		esac
		case " $WAN_IPS " in
			*" $ip "*) continue ;;
		esac
		case " $NET_ADDR " in
			*" $ip "*) ;;
			*) NET_ADDR="${NET_ADDR:+$NET_ADDR }$ip" ;;
		esac
	done
	for ip in $NET_ADDR; do
		echo "$ip"
	done
}

# ------------------------------------------------------------------------------
# GeoData: extract an IP list for a geo code via geoview (mirrors passwall2).
# ------------------------------------------------------------------------------

get_geoip() {
	local geo_output_path="$TMP_PATH2/geo_output"
	mkdir -p "$geo_output_path"
	local geoip_code=$1
	local family=$2
	local output_path="${geo_output_path}/geoip-${geoip_code}-${family}"
	[ ! -s "${output_path}" ] && {
		local geoip_path
		geoip_path=$(config_t_get global_rules v2ray_location_asset "/usr/share/v2ray/")
		geoip_path="${geoip_path%*/}/geoip.dat"
		local bin
		bin=$(first_type "$(config_t_get global_app geoview_file /usr/bin/geoview)" geoview)
		[ -n "$bin" ] && [ -s "$geoip_path" ] || { echo ""; return; }
		local flag=""
		case "$family" in
			ipv4) flag="-ipv6=false" ;;
			ipv6) flag="-ipv4=false" ;;
		esac
		"$bin" -input "$geoip_path" -list "$geoip_code" $flag -lowmem=true -output "$output_path" 2>/dev/null
	}
	[ -s "${output_path}" ] && cat "${output_path}"
}

# ------------------------------------------------------------------------------
# BypassCore binary validation: a Linux ELF is required (the routing/split
# engine). Release tarballs for OpenWrt are at
# https://github.com/kinmeic/BypassCore/releases ; this guard rejects a
# wrong-arch (e.g. darwin) binary so the LuCI status page can warn clearly.
# Returns 0 only when the path is an executable Linux ELF.
# ------------------------------------------------------------------------------

is_elf() {
	local path=$1
	[ -f "$path" ] || return 1
	local magic
	magic=$(od -An -tx1 -N4 "$path" 2>/dev/null | tr -d ' \n')
	[ "$magic" = "7f454c46" ]
}

is_linux_elf() {
	local path=$1
	is_elf "$path" || return 1
	# EI_OSABI is byte index 7 (0=SYSV/Linux-acceptable, 3=Linux). Reject wrong-
	# arch binaries (e.g. darwin) and obviously non-Linux ABIs.
	local osabi
	osabi=$(od -An -tx1 -j7 -N1 "$path" 2>/dev/null | tr -d ' \n')
	case "$osabi" in
		00|03|06) return 0 ;;
		*) return 1 ;;
	esac
}

# ------------------------------------------------------------------------------
# Egress-interface routing helpers (dest-IP fwmark strategy).
#
# These install the *routing* half of the egress policy:
#   ip rule  fwmark <FWMARK> lookup <TABLE>
#   ip route default [via <gw>] dev <iface> table <TABLE>
# and resolve the naive server IP(s) into $TMP_PATH/uplink_ips (consumed by the
# nftables backend, which installs the matching mangle-OUTPUT mark
# rule + the bypass_uplink set).
#
# naive stays root, so its listen mode keeps capabilities.
# ------------------------------------------------------------------------------

# resolve_uplink_ips <node_id>  -> writes $TMP_PATH/uplink_ips (one IPv4/line)
resolve_uplink_ips() {
	local node_id=$1
	local server_host
	server_host=$(config_n_get "$node_id" address)
	mkdir -p "$TMP_PATH"
	: > "$TMP_PATH/uplink_ips"
	[ -z "$server_host" ] && return 0
	resolve_all_ipv4 "$server_host" | awk '!seen[$0]++' > "$TMP_PATH/uplink_ips"
	[ -s "$TMP_PATH/uplink_ips" ] || log 1 "Could not resolve naive server address [%s] for egress set." "$server_host"
}

# get_egress_gateway <iface> -> echoes the IPv4 gateway (empty for p2p/tunnel)
get_egress_gateway() {
	local iface=$1
	local gateway
	network_get_gateway gateway "$iface" 2>/dev/null
	[ -n "$gateway" ] && { echo "$gateway"; return; }
	gateway=$(ubus call "network.interface.$iface" status 2>/dev/null | jsonfilter -e '@.route[0].target' 2>/dev/null)
	echo "$gateway"
}

# setup_egress_routing <iface> <fwmark> <table>
setup_egress_routing() {
	local iface=$1 fwmark=$2 table=$3
	[ -z "$iface" ] && return 0
	# Routing table entry: default via <gw> dev <iface> (or dev-only for tunnels)
	local gateway
	gateway=$(get_egress_gateway "$iface")
	local dev_route="dev $iface"
	if [ -n "$gateway" ]; then
		ip route replace default via "$gateway" dev "$iface" table "$table" 2>/dev/null \
			|| ip route replace default dev "$iface" table "$table" 2>/dev/null
	else
		ip route replace default dev "$iface" table "$table" 2>/dev/null
	fi
	# Policy rule: marked packets use our table.
	ip rule add fwmark "$fwmark" lookup "$table" 2>/dev/null || ip rule replace fwmark "$fwmark" lookup "$table"
	log 0 "Egress routing: naive -> %s (gw=%s, fwmark=%s, table=%s)." "$iface" "${gateway:-p2p}" "$fwmark" "$table"
	set_cache_var EGRESS_IFACE "$iface"
	set_cache_var EGRESS_FWMARK "$fwmark"
	set_cache_var EGRESS_TABLE "$table"
}

teardown_egress_routing() {
	local iface fwmark table
	iface=$(get_cache_var EGRESS_IFACE)
	fwmark=$(get_cache_var EGRESS_FWMARK)
	table=$(get_cache_var EGRESS_TABLE)
	[ -n "$table" ] && ip route flush table "$table" 2>/dev/null
	[ -n "$fwmark" ] && ip rule del fwmark "$fwmark" 2>/dev/null
	[ -n "$iface" ] && log 0 "Egress routing torn down (iface=%s)." "$iface"
}

# refresh_uplink_ips <node_id> -> re-resolve + signal the tables backend to
# repopulate its bypass_uplink set. The tables backend's refresh_uplink() (if
# loaded) does the set repopulation; this just refreshes the IP file.
refresh_uplink_ips() {
	local node_id=$1
	resolve_uplink_ips "$node_id"
	# If a tables backend is sourced, let it repopulate its set.
	type refresh_uplink >/dev/null 2>&1 && refresh_uplink
	return 0
}
