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
# Process launch (symlink into $TMP_BIN_PATH so pgrep -f $TMP_BIN_PATH works).
# ------------------------------------------------------------------------------

ln_run() {
	local file_func=${2}
	local ln_name=${3}
	local output=${4}
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
		[ -x "${file_func}" ] || log 1 "%s is not executable: %s %s" "${file_func}" "${file_func}" "$*"
	fi
	[ -n "${file_func}" ] || log 1 "%s not found, cannot start." "${ln_name}"

	${file_func:-log 1 "${ln_name}"} "$@" >"${output}" 2>&1 &
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

# resolve_uplink_ips <node_id> writes one destination per line to
# uplink_ips/uplink_ips6. Both families are required because a Naive hostname
# may be IPv6-only or change family between DNS refreshes.
resolve_uplink_ips() {
	local node_id=$1
	local server_host
	server_host=$(config_n_get "$node_id" address)
	mkdir -p "$TMP_PATH"
	: > "$TMP_PATH/uplink_ips"
	: > "$TMP_PATH/uplink_ips6"
	[ -z "$server_host" ] && return 0
	resolve_all_ipv4 "$server_host" | awk '!seen[$0]++' > "$TMP_PATH/uplink_ips"
	resolve_all_ipv6 "$server_host" | awk '!seen[$0]++' > "$TMP_PATH/uplink_ips6"
	[ -s "$TMP_PATH/uplink_ips" ] || [ -s "$TMP_PATH/uplink_ips6" ] || \
		log 1 "Could not resolve naive server address [%s] for egress routing." "$server_host"
}

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

# setup_egress_routing <logical_iface> <table> <rule_priority>
#
# Only the selected Naive server destinations are sent to the dedicated table.
# Destination rules avoid overwriting packet marks owned by mwan3/PBR and are a
# better fit than reimplementing mwan3 for this one narrowly scoped tunnel.
setup_egress_routing() {
	local iface=$1 table=$2 priority=$3
	[ -z "$iface" ] && return 0
	get_egress_runtime "$iface" || {
		log 0 "Configured egress interface [%s] is down or has no L3 device." "$iface"
		return 1
	}
	[ -s "$TMP_PATH/uplink_ips" ] || [ -s "$TMP_PATH/uplink_ips6" ] || {
		log 0 "No address resolved for the selected Naive server; cannot apply egress interface [%s]." "$iface"
		return 1
	}

	teardown_egress_routing
	local existing_default existing_default6
	existing_default=$(ip -o route show table "$table" default 2>/dev/null)
	existing_default6=$(ip -6 -o route show table "$table" default 2>/dev/null)
	if { [ -n "$existing_default" ] && ! echo "$existing_default" | grep -q 'proto 99'; } || \
	   { [ -n "$existing_default6" ] && ! echo "$existing_default6" | grep -q 'proto 99'; }; then
		log 0 "Egress route table [%s] already has a foreign default route; choose another table." "$table"
		return 1
	fi
	# Cache ownership before mutating the selected table so every subsequent
	# failure path can use the common teardown routine without leaking a route.
	set_cache_var EGRESS_IFACE "$iface"
	set_cache_var EGRESS_TABLE "$table"
	set_cache_var EGRESS_RULE_PRIORITY "$priority"
	: > "$TMP_PATH/egress_rule_ips"
	: > "$TMP_PATH/egress_rule_ips6"
	if [ -s "$TMP_PATH/uplink_ips" ]; then
		if [ -n "$EGRESS_GATEWAY" ]; then
			ip route replace default via "$EGRESS_GATEWAY" dev "$EGRESS_DEVICE" onlink proto 99 table "$table" 2>/dev/null \
				|| ip route replace default via "$EGRESS_GATEWAY" dev "$EGRESS_DEVICE" proto 99 table "$table" 2>/dev/null \
				|| { teardown_egress_routing; return 1; }
		else
			ip route replace default dev "$EGRESS_DEVICE" proto 99 table "$table" 2>/dev/null \
				|| { teardown_egress_routing; return 1; }
		fi
	fi
	if [ -s "$TMP_PATH/uplink_ips6" ]; then
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
	expected=$(awk 'NF { n++ } END { print n + 0 }' "$TMP_PATH/uplink_ips")
	expected6=$(awk 'NF { n++ } END { print n + 0 }' "$TMP_PATH/uplink_ips6")
	while read -r ip; do
		[ -n "$ip" ] || continue
		while ip rule del priority "$priority" to "$ip/32" lookup "$table" 2>/dev/null; do :; done
		if ip rule add priority "$priority" to "$ip/32" lookup "$table" 2>/dev/null; then
			echo "$ip" >> "$TMP_PATH/egress_rule_ips"
			installed=$((installed + 1))
		else
			log 0 "Could not install IPv4 egress rule for [%s]." "$ip"
			teardown_egress_routing
			return 1
		fi
	done < "$TMP_PATH/uplink_ips"
	while read -r ip; do
		[ -n "$ip" ] || continue
		while ip -6 rule del priority "$priority" to "$ip/128" lookup "$table" 2>/dev/null; do :; done
		if ip -6 rule add priority "$priority" to "$ip/128" lookup "$table" 2>/dev/null; then
			echo "$ip" >> "$TMP_PATH/egress_rule_ips6"
			installed6=$((installed6 + 1))
		else
			log 0 "Could not install IPv6 egress rule for [%s]." "$ip"
			teardown_egress_routing
			return 1
		fi
	done < "$TMP_PATH/uplink_ips6"
	[ "$installed" -eq "$expected" ] && [ "$installed6" -eq "$expected6" ] && \
		[ $((installed + installed6)) -gt 0 ] || {
		teardown_egress_routing
		return 1
	}

	log 0 "Egress routing: Naive server -> %s/%s (IPv4=%s, IPv6=%s, table=%s, priority=%s)." \
		"$iface" "$EGRESS_DEVICE" "$installed" "$installed6" "$table" "$priority"
}

teardown_egress_routing() {
	local iface table priority ip
	iface=$(get_cache_var EGRESS_IFACE)
	table=$(get_cache_var EGRESS_TABLE)
	priority=$(get_cache_var EGRESS_RULE_PRIORITY)
	[ -z "$priority" ] && priority=900
	if [ -n "$table" ] && [ -s "$TMP_PATH/egress_rule_ips" ]; then
		while read -r ip; do
			[ -n "$ip" ] || continue
			while ip rule del priority "$priority" to "$ip/32" lookup "$table" 2>/dev/null; do :; done
		done < "$TMP_PATH/egress_rule_ips"
	fi
	if [ -n "$table" ] && [ -s "$TMP_PATH/egress_rule_ips6" ]; then
		while read -r ip; do
			[ -n "$ip" ] || continue
			while ip -6 rule del priority "$priority" to "$ip/128" lookup "$table" 2>/dev/null; do :; done
		done < "$TMP_PATH/egress_rule_ips6"
	fi
	[ -n "$table" ] && ip route flush table "$table" proto 99 2>/dev/null
	[ -n "$table" ] && ip -6 route flush table "$table" proto 99 2>/dev/null
	[ -n "$iface" ] && log 0 "Egress routing torn down (iface=%s)." "$iface"
	rm -f "$TMP_PATH/egress_rule_ips" "$TMP_PATH/egress_rule_ips6"
	unset_cache_var EGRESS_IFACE
	unset_cache_var EGRESS_TABLE
	unset_cache_var EGRESS_RULE_PRIORITY
}

# refresh_uplink_ips <node_id> -> re-resolve and rebuild destination rules.
refresh_uplink_ips() {
	local node_id=$1
	resolve_uplink_ips "$node_id"
	local iface table priority
	iface=$(config_n_get "$node_id" egress_interface)
	[ -n "$iface" ] || iface=$(config_t_get global default_egress_interface)
	[ -n "$iface" ] || { teardown_egress_routing; return 0; }
	table=$(config_t_get global naive_egress_table 20200)
	priority=$(config_t_get global naive_egress_rule_priority 900)
	setup_egress_routing "$iface" "$table" "$priority"
}
