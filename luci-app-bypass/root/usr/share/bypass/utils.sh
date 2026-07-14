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
LOG_FILE=/tmp/log/${CONFIG}.log
TMP_ACL_PATH=${TMP_PATH}/acl
TMP_BIN_PATH=${TMP_PATH}/bin
TMP_PID_PATH=${TMP_PATH}/pids
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

# ------------------------------------------------------------------------------
# State cache (persisted across sub-invocations in $TMP_PATH/var)
# ------------------------------------------------------------------------------

get_cache_var() {
	local key="${1}"
	case "$key" in ''|*[!A-Za-z0-9_]*) return 1 ;; esac
	[ -n "${key}" ] && [ -s "$TMP_PATH/var" ] && {
		awk -v key="$key" -F'"' '$0 ~ ("^" key "=") { value=$2 } END { print value }' "$TMP_PATH/var"
	}
}

set_cache_var() {
	local key="${1}"
	shift 1
	local val="$*"
	case "$key" in ''|*[!A-Za-z0-9_]*) return 1 ;; esac
	val=$(printf '%s' "$val" | tr -d '\r\n"')
	[ -n "${key}" ] && [ -n "${val}" ] && {
		[ ! -d "$TMP_PATH" ] && mkdir -p "$TMP_PATH"
		sed -i "/${key}=/d" "$TMP_PATH/var" >/dev/null 2>&1
		echo "${key}=\"${val}\"" >> "$TMP_PATH/var"
	}
}

unset_cache_var() {
	local key="${1}"
	case "$key" in ''|*[!A-Za-z0-9_]*) return 1 ;; esac
	[ -s "$TMP_PATH/var" ] && sed -i "/^${key}=/d" "$TMP_PATH/var" >/dev/null 2>&1
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
	case "$protocol" in tcp|udp|tcp,udp) ;; *) protocol="tcp,udp" ;; esac
	case "$port" in ''|*[!0-9]*) echo 0; return 1 ;; esac
	[ "$port" -ge 1 ] 2>/dev/null && [ "$port" -le 65535 ] 2>/dev/null || {
		echo 0
		return 1
	}

	# /proc/net is stable across BusyBox netstat variants and lets us match the
	# local port exactly instead of relying on column spacing such as ":1088 ".
	# TCP state 0A is LISTEN; UDP state 07 is the unconnected listening socket.
	local hex result=0 file state
	hex=$(printf '%04X' "$port" 2>/dev/null) || { echo 0; return 1; }
	for file in \
		$([ "$protocol" != "udp" ] && echo /proc/net/tcp /proc/net/tcp6) \
		$([ "$protocol" != "tcp" ] && echo /proc/net/udp /proc/net/udp6); do
		[ -r "$file" ] || continue
		case "$file" in */tcp*) state=0A ;; *) state=07 ;; esac
		result=$((result + $(awk -v port="$hex" -v state="$state" '
			NR > 1 && $2 ~ (":" port "$") && $4 == state { count++ }
			END { print count + 0 }
		' "$file" 2>/dev/null)))
	done
	if [ "$result" -gt 0 ] 2>/dev/null || [ -r /proc/net/tcp ]; then
		echo "$result"
		return 0
	fi

	# Fallback for non-/proc development hosts. Scan fields instead of assuming
	# a particular netstat column layout.
	if [ "$protocol" = "tcp" ]; then
		netstat -an -t 2>/dev/null
	elif [ "$protocol" = "udp" ]; then
		netstat -an -u 2>/dev/null
	else
		netstat -an 2>/dev/null
	fi | awk -v port="$port" -v proto="$protocol" '
		BEGIN { count = 0 }
		{
			is_tcp = ($1 ~ /^tcp/); is_udp = ($1 ~ /^udp/)
			if ((proto == "tcp" && !is_tcp) || (proto == "udp" && !is_udp)) next
			if (is_tcp && $0 !~ /LISTEN/) next
			for (i = 1; i <= NF; i++)
				if ($i ~ ("[.:]" port "$") || $i ~ ("[.:]" port "[* ]")) { count++; break }
		}
		END { print count + 0 }
	'
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
	case "$port" in ''|*[!0-9]*) port=$default_start_port ;; esac
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
# Process launch and health tracking.
# ------------------------------------------------------------------------------

process_pid() {
	local name=$1 pid
	case "$name" in ''|*[!A-Za-z0-9_.-]*) return 1 ;; esac
	pid=$(cat "$TMP_PID_PATH/${name}.pid" 2>/dev/null)
	case "$pid" in ''|*[!0-9]*) return 1 ;; esac
	kill -0 "$pid" 2>/dev/null || return 1
	# PID files live in /tmp and can outlast a crashed child. Refuse a reused PID
	# when procfs is available instead of signalling an unrelated process.
	if [ -r "/proc/$pid/cmdline" ]; then
		tr '\000' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -Fq "$TMP_BIN_PATH/$name" || return 1
	fi
	echo "$pid"
}

process_alive() {
	process_pid "$1" >/dev/null 2>&1
}

log_component_tail() {
	local name=$1 output=$2
	[ -s "$output" ] || {
		log 1 "%s exited without diagnostic output." "$name"
		return 0
	}
	tail -n 12 "$output" 2>/dev/null | while IFS= read -r line; do
		[ -n "$line" ] && log 1 "%s: %s" "$name" "$line"
	done
}

# wait_for_listener <process-name> <port> <tcp|udp> <seconds> <log-file>
wait_for_listener() {
	local name=$1 port=$2 protocol=$3 timeout=${4:-10} output=$5 elapsed=0
	while [ "$elapsed" -lt "$timeout" ]; do
		if ! process_alive "$name"; then
			log 0 "%s exited before opening %s/%s." "$name" "$protocol" "$port"
			log_component_tail "$name" "$output"
			return 1
		fi
		[ "$(check_port_exists "$port" "$protocol")" -gt 0 ] 2>/dev/null && return 0
		elapsed=$((elapsed + 1))
		sleep 1
	done
	log 0 "%s is alive but did not open %s/%s within %s seconds." "$name" "$protocol" "$port" "$timeout"
	log_component_tail "$name" "$output"
	return 1
}

ln_run() {
	local file_func=$2
	local ln_name=$3
	local output=$4
	shift 4

	if [ "${file_func%%/*}" != "${file_func}" ]; then
		case "$file_func" in
		"${TMP_BIN_PATH}"/*) ;;
		*)
			mkdir -p "$TMP_BIN_PATH"
			ln -sf "${file_func}" "${TMP_BIN_PATH}/${ln_name}" >/dev/null 2>&1
			file_func="${TMP_BIN_PATH}/${ln_name}"
			;;
		esac
		[ -x "${file_func}" ] || {
			log 1 "%s is not executable: %s %s" "${ln_name}" "${file_func}" "$*"
			return 1
		}
	fi
	[ -n "${file_func}" ] && [ -x "${file_func}" ] || {
		log 1 "%s not found, cannot start." "${ln_name}"
		return 1
	}

	mkdir -p "$TMP_PID_PATH" "$(dirname "$output")"
	rm -f "$TMP_PID_PATH/${ln_name}.pid"
	"$file_func" "$@" >"$output" 2>&1 &
	local pid=$!
	printf '%s\n' "$pid" > "$TMP_PID_PATH/${ln_name}.pid"
	kill -0 "$pid" 2>/dev/null
}

# Percent-encode a raw URI user-info component. NaiveProxy consumes its server
# credentials from a proxy URI, so reserved characters such as @, :, / and %
# must not be allowed to change the parsed host or password.
uri_encode_userinfo() {
	local value=$1 char encoded="" code LC_ALL=C
	while [ -n "$value" ]; do
		char=${value%"${value#?}"}
		value=${value#?}
		case "$char" in
			[A-Za-z0-9._~-]) encoded="${encoded}${char}" ;;
			*)
				code=$(printf '%d' "'$char" 2>/dev/null) || return 1
				encoded="${encoded}$(printf '%%%02X' "$code")"
				;;
		esac
	done
	printf '%s\n' "$encoded"
}

stop_managed_processes() {
	local pidfile pid name remaining=3
	[ -d "$TMP_PID_PATH" ] || return 0
	for pidfile in "$TMP_PID_PATH"/*.pid; do
		[ -f "$pidfile" ] || continue
		name=${pidfile##*/}; name=${name%.pid}
		pid=$(process_pid "$name") || continue
		kill "$pid" 2>/dev/null
	done
	while [ "$remaining" -gt 0 ]; do
		local alive=0
		for pidfile in "$TMP_PID_PATH"/*.pid; do
			[ -f "$pidfile" ] || continue
			name=${pidfile##*/}; name=${name%.pid}
			process_alive "$name" && alive=1
		done
		[ "$alive" = "0" ] && break
		remaining=$((remaining - 1))
		sleep 1
	done
	for pidfile in "$TMP_PID_PATH"/*.pid; do
		[ -f "$pidfile" ] || continue
		name=${pidfile##*/}; name=${name%.pid}
		pid=$(process_pid "$name") || continue
		kill -9 "$pid" 2>/dev/null
	done
}

# ------------------------------------------------------------------------------
# Host / IP resolution (via the required resolveip package)
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

resolve_all_ipv6() {
	local host=$1
	[ -z "$host" ] && return 0
	echo "$host" | grep -q ':' && { echo "$host"; return 0; }
	resolveip -6 -t 3 "$host" 2>/dev/null | awk '!seen[$0]++'
}

# Find files installed by v2ray-geoip/v2ray-geosite. The configured asset
# directory wins, followed by common package locations and package manifests.
get_geo_asset_path() {
	local name=$1 configured candidate package path
	configured=$(config_t_get global_rules v2ray_location_asset /usr/share/v2ray/)
	configured="${configured%*/}/${name}.dat"
	for candidate in "$configured" \
		"/usr/share/v2ray/${name}.dat" \
		"/usr/share/xray/${name}.dat" \
		"/usr/share/sing-box/${name}.dat"; do
		[ -s "$candidate" ] && { echo "$candidate"; return 0; }
	done
	package="v2ray-${name}"
	if command -v opkg >/dev/null 2>&1; then
		path=$(opkg files "$package" 2>/dev/null | sed -n "/\/${name}\.dat$/p" | head -1)
	elif command -v apk >/dev/null 2>&1; then
		path=$(apk info -L "$package" 2>/dev/null | sed -n "/\/${name}\.dat$/p" | head -1)
	fi
	[ -n "$path" ] && [ -s "$path" ] && echo "$path"
}

# List resolver IPv4 addresses that must remain directly reachable. This
# includes netifd/dnsmasq's current ISP resolvers and explicitly configured
# domestic resolvers, but deliberately excludes the remote/trusted resolver.
get_direct_dns_ipv4() {
	local resolv domestic
	resolv=/tmp/resolv.conf.d/resolv.conf.auto
	[ -s "$resolv" ] || resolv=/tmp/resolv.conf.auto
	{
		grep -E -o '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' "$resolv" 2>/dev/null
		domestic=$(config_t_get global_dns domestic_dns auto)
		[ "$domestic" = "auto" ] || printf '%s\n' "$domestic" | grep -E -o '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'
	} | grep -v -E '^(0\.0\.0\.0|127\.0\.0\.1)$' | awk '!seen[$0]++'
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
		geoip_path=$(get_geo_asset_path geoip)
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
	# Ensure every record ends with a newline. geoview may omit the final
	# newline; a bare cat would then fuse its last CIDR with the next line a
	# caller appends, producing invalid entries such as "223.255.252.0/230.0.0.0/8"
	# (223.255.252.0/23 + 0.0.0.0/8). awk re-emits each line with a guaranteed
	# trailing newline so the batch importer always sees one CIDR per record.
	[ -s "${output_path}" ] && awk '{print}' "${output_path}"
}

# BypassCore is normally a native Linux executable, while some packages use an
# executable launcher. In both cases verify the program identity; merely being
# an ELF file is not enough to mark an arbitrary binary as the required core.
is_bypasscore() {
	local path=$1 target
	[ -e "$path" ] && [ -x "$path" ] || return 1
	target=$(readlink -f "$path" 2>/dev/null)
	[ -n "$target" ] || target=$path
	[ -f "$target" ] || return 1
	"$path" --version 2>/dev/null | grep -q '^BypassCore[[:space:]]'
}

# ------------------------------------------------------------------------------
# Egress-interface routing helpers (destination-policy-rule strategy).
#
# These install the *routing* half of the egress policy:
#   ip rule  to <NAIVE_SERVER_IP> lookup <TABLE>
#   ip route default [via <gw>] dev <iface> table <TABLE>
# and resolve the Naive server's IPv4/IPv6 destinations. This does not alter
# mwan3/PBR packet marks and therefore composes with their policy rules.
#
# naive stays root, so its listen mode keeps capabilities.
# ------------------------------------------------------------------------------

# Resolve an OpenWrt logical interface (wan/wan1/usbwan/...) to its current
# L3 device, IPv4 address and gateway.  network.sh reads netifd's runtime state,
# so DHCP, PPPoE and dynamically renamed devices work; UCI's static device/name
# fields are deliberately not used here.
get_egress_runtime() {
	local iface=$1
	EGRESS_DEVICE=""
	EGRESS_GATEWAY=""
	EGRESS_GATEWAY6=""
	EGRESS_LOCAL_IP=""
	EGRESS_LOCAL_IP6=""
	network_flush_cache 2>/dev/null
	network_is_up "$iface" 2>/dev/null || return 1
	network_get_device EGRESS_DEVICE "$iface" 2>/dev/null
	network_get_gateway EGRESS_GATEWAY "$iface" 2>/dev/null
	network_get_gateway6 EGRESS_GATEWAY6 "$iface" 2>/dev/null
	network_get_ipaddr EGRESS_LOCAL_IP "$iface" 2>/dev/null
	network_get_ipaddr6 EGRESS_LOCAL_IP6 "$iface" 2>/dev/null
	[ -n "$EGRESS_DEVICE" ]
}

# setup_egress_routing <logical_iface> <table> <rule_priority> <ipv4_file> <ipv6_file> [label]
#
# Only one Naive node's server destinations are sent to this dedicated table.
# The caller assigns a different table to each selected node, allowing nodes to
# use different WANs without overwriting packet marks owned by mwan3/PBR.
setup_egress_routing() {
	local iface=$1 table=$2 priority=$3
	local ipv4_file=${4:-$TMP_PATH/uplink_ips}
	local ipv6_file=${5:-$TMP_PATH/uplink_ips6}
	local label=${6:-Naive}
	[ -z "$iface" ] && return 0
	get_egress_runtime "$iface" || {
		log 0 "%s egress interface [%s] is down or has no L3 device." "$label" "$iface"
		return 1
	}
	[ -s "$ipv4_file" ] || [ -s "$ipv6_file" ] || {
		log 0 "No server address resolved for %s; cannot apply egress interface [%s]." "$label" "$iface"
		return 1
	}

	local foreign_routes foreign_routes6
	foreign_routes=$(ip -o route show table "$table" 2>/dev/null | grep -v 'proto 99')
	foreign_routes6=$(ip -6 -o route show table "$table" 2>/dev/null | grep -v 'proto 99')
	if [ -n "$foreign_routes$foreign_routes6" ]; then
		log 0 "Egress route table [%s] already contains foreign routes; choose another table." "$table"
		return 1
	fi
	if ip rule show 2>/dev/null | awk -v p="${priority}:" '$1 == p { found=1 } END { exit !found }'; then
		log 0 "IPv4 policy-rule priority [%s] is already in use; choose another base priority." "$priority"
		return 1
	fi
	if ip -6 rule show 2>/dev/null | awk -v p="${priority}:" '$1 == p { found=1 } END { exit !found }'; then
		log 0 "IPv6 policy-rule priority [%s] is already in use; choose another base priority." "$priority"
		return 1
	fi
	if [ -s "$ipv4_file" ] && [ -z "$EGRESS_GATEWAY" ] && \
	   ! ip -4 route show default 2>/dev/null | grep -q " dev $EGRESS_DEVICE\( \|$\)"; then
		log 0 "%s resolved IPv4 addresses, but interface [%s] has no usable IPv4 route." "$label" "$iface"
		return 1
	fi
	if [ -s "$ipv6_file" ] && [ -z "$EGRESS_GATEWAY6" ] && \
	   ! ip -6 route show default 2>/dev/null | grep -q " dev $EGRESS_DEVICE\( \|$\)"; then
		log 0 "%s resolved IPv6 addresses, but interface [%s] has no usable IPv6 route." "$label" "$iface"
		return 1
	fi
	# Record ownership before mutating the table so every failure path can use
	# the common teardown routine without leaking routes or policy rules.
	touch "$TMP_PATH/egress_tables" "$TMP_PATH/egress_rules"
	printf '%s %s\n' "$table" "$iface" >> "$TMP_PATH/egress_tables"
	if [ -s "$ipv4_file" ]; then
		if [ -n "$EGRESS_GATEWAY" ]; then
			ip route replace default via "$EGRESS_GATEWAY" dev "$EGRESS_DEVICE" onlink proto 99 table "$table" 2>/dev/null \
				|| ip route replace default via "$EGRESS_GATEWAY" dev "$EGRESS_DEVICE" proto 99 table "$table" 2>/dev/null \
				|| { teardown_egress_routing; return 1; }
		else
			ip route replace default dev "$EGRESS_DEVICE" proto 99 table "$table" 2>/dev/null \
				|| { teardown_egress_routing; return 1; }
		fi
	fi
	if [ -s "$ipv6_file" ]; then
		if [ -n "$EGRESS_GATEWAY6" ]; then
			ip -6 route replace default via "$EGRESS_GATEWAY6" dev "$EGRESS_DEVICE" onlink proto 99 table "$table" 2>/dev/null \
				|| ip -6 route replace default via "$EGRESS_GATEWAY6" dev "$EGRESS_DEVICE" proto 99 table "$table" 2>/dev/null \
				|| { teardown_egress_routing; return 1; }
		else
			ip -6 route replace default dev "$EGRESS_DEVICE" proto 99 table "$table" 2>/dev/null \
				|| { teardown_egress_routing; return 1; }
		fi
	fi

	local ip installed=0 installed6=0 expected expected6
	expected=$(awk 'NF { n++ } END { print n + 0 }' "$ipv4_file")
	expected6=$(awk 'NF { n++ } END { print n + 0 }' "$ipv6_file")
	while read -r ip; do
		[ -n "$ip" ] || continue
		while ip rule del priority "$priority" to "$ip/32" lookup "$table" 2>/dev/null; do :; done
		if ip rule add priority "$priority" to "$ip/32" lookup "$table" 2>/dev/null; then
			printf '4 %s %s %s\n' "$priority" "$ip" "$table" >> "$TMP_PATH/egress_rules"
			installed=$((installed + 1))
		else
			log 0 "Could not install IPv4 egress rule for [%s]." "$ip"
			teardown_egress_routing
			return 1
		fi
	done < "$ipv4_file"
	while read -r ip; do
		[ -n "$ip" ] || continue
		while ip -6 rule del priority "$priority" to "$ip/128" lookup "$table" 2>/dev/null; do :; done
		if ip -6 rule add priority "$priority" to "$ip/128" lookup "$table" 2>/dev/null; then
			printf '6 %s %s %s\n' "$priority" "$ip" "$table" >> "$TMP_PATH/egress_rules"
			installed6=$((installed6 + 1))
		else
			log 0 "Could not install IPv6 egress rule for [%s]." "$ip"
			teardown_egress_routing
			return 1
		fi
	done < "$ipv6_file"
	[ "$installed" -eq "$expected" ] && [ "$installed6" -eq "$expected6" ] && \
		[ $((installed + installed6)) -gt 0 ] || {
		teardown_egress_routing
		return 1
	}

	local active_ifaces
	active_ifaces=$(get_cache_var EGRESS_IFACES)
	case " $active_ifaces " in
		*" $iface "*) ;;
		*) set_cache_var EGRESS_IFACES "${active_ifaces:+${active_ifaces} }${iface}" ;;
	esac
	log 0 "Egress routing: %s -> %s/%s (IPv4=%s, IPv6=%s, table=%s, priority=%s)." \
		"$label" "$iface" "$EGRESS_DEVICE" "$installed" "$installed6" "$table" "$priority"
}

teardown_egress_routing() {
	local family priority dest table iface
	if [ -s "$TMP_PATH/egress_rules" ]; then
		while read -r family priority dest table; do
			[ -n "$dest" ] && [ -n "$table" ] || continue
			if [ "$family" = "6" ]; then
				while ip -6 rule del priority "$priority" to "$dest/128" lookup "$table" 2>/dev/null; do :; done
			else
				while ip rule del priority "$priority" to "$dest/32" lookup "$table" 2>/dev/null; do :; done
			fi
		done < "$TMP_PATH/egress_rules"
	fi
	if [ -s "$TMP_PATH/egress_tables" ]; then
		while read -r table iface; do
			[ -n "$table" ] || continue
			ip route flush table "$table" proto 99 2>/dev/null
			ip -6 route flush table "$table" proto 99 2>/dev/null
		done < "$TMP_PATH/egress_tables"
	fi

	# Compatibility cleanup for runtime state created by v1.3.5/v1.3.6 before
	# per-node egress routing was introduced.
	iface=$(get_cache_var EGRESS_IFACE)
	table=$(get_cache_var EGRESS_TABLE)
	priority=$(get_cache_var EGRESS_RULE_PRIORITY)
	[ -z "$priority" ] && priority=900
	if [ -n "$table" ] && [ -s "$TMP_PATH/egress_rule_ips" ]; then
		while read -r dest; do
			[ -n "$dest" ] && while ip rule del priority "$priority" to "$dest/32" lookup "$table" 2>/dev/null; do :; done
		done < "$TMP_PATH/egress_rule_ips"
	fi
	if [ -n "$table" ] && [ -s "$TMP_PATH/egress_rule_ips6" ]; then
		while read -r dest; do
			[ -n "$dest" ] && while ip -6 rule del priority "$priority" to "$dest/128" lookup "$table" 2>/dev/null; do :; done
		done < "$TMP_PATH/egress_rule_ips6"
	fi
	[ -n "$table" ] && ip route flush table "$table" proto 99 2>/dev/null
	[ -n "$table" ] && ip -6 route flush table "$table" proto 99 2>/dev/null

	[ -n "$(get_cache_var EGRESS_IFACES)${iface}" ] && log 0 "NaiveProxy egress routing torn down."
	rm -f "$TMP_PATH/egress_rules" "$TMP_PATH/egress_tables" \
		"$TMP_PATH/egress_rule_ips" "$TMP_PATH/egress_rule_ips6"
	unset_cache_var EGRESS_IFACE
	unset_cache_var EGRESS_TABLE
	unset_cache_var EGRESS_RULE_PRIORITY
	unset_cache_var EGRESS_IFACES
}
