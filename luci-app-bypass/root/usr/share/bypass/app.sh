#!/bin/sh
# Copyright (c) 2026 Eugene Chan
# SPDX-License-Identifier: MIT
#
# Orchestrator for luci-app-bypass. Read UCI, run the naiveproxy carrier, run
# ChinaDNS-NG for split DNS, generate BypassCore's config.json (BypassCore is
# the routing/split-decision engine; traffic is carried by naiveproxy), install
# the transparent-proxy firewall ruleset, and manage the process lifecycle.
# Mirrors openwrt-passwall2/app.sh but in pure shell.

. /lib/functions.sh
. /lib/functions/service.sh
. /usr/share/libubox/jshn.sh
. ${APP_PATH:-/usr/share/bypass}/utils.sh

NAIVE_TAG=naive
CHINADNS_TAG=chinadns-ng
DNS2SOCKS_TAG=dns2socks

# ------------------------------------------------------------------------------
# Config snapshot
# ------------------------------------------------------------------------------

get_direct_dns() {
	RESOLVFILE=/tmp/resolv.conf.d/resolv.conf.auto
	[ -f "${RESOLVFILE}" ] && [ -s "${RESOLVFILE}" ] || RESOLVFILE=/tmp/resolv.conf.auto

	ISP_DNS=$(get_direct_dns_ipv4)

	local DOMESTIC
	DOMESTIC=$(config_t_get global_dns domestic_dns auto)
	case "$DOMESTIC" in
		""|auto)
			DOMESTIC_DNS=$(echo -n "$ISP_DNS" | tr ' ' '\n' | head -2 | tr '\n' ',' | sed 's/,$//')
			[ -z "$DOMESTIC_DNS" ] && DOMESTIC_DNS=223.5.5.5
			;;
		*)
			DOMESTIC_DNS=$DOMESTIC
			;;
	esac
}

get_config() {
	ENABLED=$(config_t_get global enabled 0)
	NODE_SOCKS_PORT=$(config_t_get global node_socks_port 1088)
	NODE_SOCKS_BIND_LOCAL=$(config_t_get global node_socks_bind_local 1)
	CLIENT_PROXY=$(config_t_get global client_proxy 1)
	LOG_NODE=$(config_t_get global log_node 1)
	LOGLEVEL=$(config_t_get global loglevel warning)
	DNS_REDIRECT=$(config_t_get global dns_redirect 1)

	BYPASSCORE_FILE=$(config_t_get global bypasscore_file /usr/bin/bypasscore)
	NAIVE_BIN=$(first_type "$(config_t_get global naive_file /usr/bin/naive)" naive)
	CHINADNS_BIN=$(first_type "$(config_t_get global chinadns_file /usr/bin/chinadns-ng)" chinadns-ng)
	DNS2SOCKS_BIN=$(first_type "$(config_t_get global dns2socks_file /usr/bin/dns2socks)" dns2socks)
	# BypassCore is the mandatory transparent routing core. NaiveProxy only
	# exposes the selected Naive node as a local SOCKS upstream for BypassCore.
	V2RAY_LOCATION_ASSET=$(config_t_get global_rules v2ray_location_asset /usr/share/v2ray/)
	local detected_geosite
	detected_geosite=$(get_geo_asset_path geosite)
	[ -n "$detected_geosite" ] && V2RAY_LOCATION_ASSET="${detected_geosite%/*}/"
	DOMAIN_STRATEGY=$(config_t_get global_rules domainStrategy IpOnDemand)
	DOMAIN_MATCHER=$(config_t_get global_rules domainMatcher hybrid)
	WRITE_IPSET_DIRECT=$(config_t_get global_rules write_ipset_direct 1)
	ENABLE_GEOVIEW_IP=$(config_t_get global_rules enable_geoview_ip 1)
	# Direct outbound egress interface (bind the freedom "direct" outbound to a
	# named WAN so all _direct shunt traffic egresses there). Empty = unbound.
	DIRECT_EGRESS_IFACE=$(config_t_get global_rules direct_egress_interface)

	# Reuse the active runtime ports when API helpers source this file. Without
	# this, merely opening a status/preview page while the service is running
	# would select a different free port and overwrite the live config preview.
	REDIR_PORT=$(get_cache_var ACL_GLOBAL_redir_port)
	[ -n "$REDIR_PORT" ] || REDIR_PORT=$(echo $(get_new_port 1041 tcp))
	TCP_PROXY_WAY=$(config_t_get global_forwarding tcp_proxy_way redirect)
	TCP_NO_REDIR_PORTS=$(config_t_get global_forwarding tcp_no_redir_ports 'disable')
	UDP_NO_REDIR_PORTS=$(config_t_get global_forwarding udp_no_redir_ports 'disable')
	TCP_REDIR_PORTS=$(config_t_get global_forwarding tcp_redir_ports '1:65535')
	UDP_REDIR_PORTS=$(config_t_get global_forwarding udp_redir_ports '1:65535')
	PROXY_IPV6=$(config_t_get global_forwarding ipv6_tproxy 0)
	FORCE_PROXY_LAN_IP=$(config_t_get global_forwarding force_proxy_lan_ip 0)

	DOMESTIC_DNS_USER=$(config_t_get global_dns domestic_dns auto)
	REMOTE_DNS=$(config_t_get global_dns remote_dns 1.1.1.1)
	REMOTE_DNS_PROTOCOL=$(config_t_get global_dns remote_dns_protocol tcp)
	REMOTE_DNS_DOH=$(config_t_get global_dns remote_dns_doh https://1.1.1.1/dns-query)
	REMOTE_DNS_CLIENT_IP=$(config_t_get global_dns remote_dns_client_ip)
	REMOTE_DNS_DETOUR=$(config_t_get global_dns remote_dns_detour remote)
	DIRECT_DNS_QUERY_STRATEGY=$(config_t_get global_dns direct_dns_query_strategy UseIP)
	REMOTE_DNS_QUERY_STRATEGY=$(config_t_get global_dns remote_dns_query_strategy UseIPv4)
	DIRECT_DNS_SHUNT=$(config_t_get global_dns direct_dns_shunt)
	DNS_HOSTS=$(config_t_get global_dns dns_hosts)
	CHINADNS_PORT=$(config_t_get global_dns chinadns_listen_port 10553)
	DNS2SOCKS_PORT=$(get_cache_var DNS2SOCKS_PORT)
	[ -n "$DNS2SOCKS_PORT" ] || DNS2SOCKS_PORT=$(echo $(get_new_port 10554 udp))
	[ "$DNS2SOCKS_PORT" = "$CHINADNS_PORT" ] && DNS2SOCKS_PORT=$(expr "$DNS2SOCKS_PORT" + 1)
	DNS_SPLIT_DOMAIN=$(config_t_get global_dns dns_split_domain geosite:cn)

	# Egress (destination policy routing, independent of mwan3 packet marks).
	DEFAULT_EGRESS_IFACE=$(config_t_get global default_egress_interface)
	NAIVE_EGRESS_TABLE=$(config_t_get global naive_egress_table 20200)
	NAIVE_EGRESS_RULE_PRIORITY=$(config_t_get global naive_egress_rule_priority 900)
	echo "$NAIVE_EGRESS_TABLE" | grep -qE '^[0-9]+$' || NAIVE_EGRESS_TABLE=20200
	echo "$NAIVE_EGRESS_RULE_PRIORITY" | grep -qE '^[0-9]+$' || NAIVE_EGRESS_RULE_PRIORITY=900

	get_direct_dns
	QUEUE_RUN=0
}

# Build the unique list of Naive nodes referenced by shunt rules, including the
# reserved Default row.  Blank/direct/blackhole rules do not start a tunnel.
prepare_selected_nodes() {
	mkdir -p "$TMP_PATH"
	local sid outbound index=0 port
	: > "$TMP_PATH/selected_nodes"
	for sid in $(uci -q show "${CONFIG}" 2>/dev/null | sed -n 's/^bypass\.\([^.=]*\)=shunt_rules$/\1/p'); do
		outbound=$(config_n_get "$sid" outbound)
		[ "$(config_get_type "$outbound")" = "nodes" ] && echo "$outbound"
	done | awk 'NF && !seen[$0]++' > "$TMP_PATH/selected_nodes"

	# Keep mappings stable only while the service is actually active. Status or
	# preview calls made while stopped must not reserve stale ports for startup.
	[ -s "$TMP_PATH/node_ports" ] && busybox pgrep -f "$TMP_BIN_PATH/" >/dev/null 2>&1 && return 0
	: > "$TMP_PATH/node_ports"
	while read -r sid; do
		[ -n "$sid" ] || continue
		port=$(get_new_port $((NODE_SOCKS_PORT + index)) tcp)
		printf '%s %s\n' "$sid" "$port" >> "$TMP_PATH/node_ports"
		index=$((index + 1))
	done < "$TMP_PATH/selected_nodes"
}

node_socks_port() {
	awk -v node="$1" '$1 == node { print $2; exit }' "$TMP_PATH/node_ports" 2>/dev/null
}

default_proxy_node() {
	local sid outbound
	for sid in $(uci -q show "${CONFIG}" 2>/dev/null | sed -n 's/^bypass\.\([^.=]*\)=shunt_rules$/\1/p'); do
		[ "$(config_n_get "$sid" is_default 0)" = "1" ] || continue
		outbound=$(config_n_get "$sid" outbound)
		[ "$(config_get_type "$outbound")" = "nodes" ] && { echo "$outbound"; return; }
	done
	head -1 "$TMP_PATH/selected_nodes" 2>/dev/null
}

# Relay the trusted DNS over Naive's local SOCKS listener. Passwall2 can route
# remote DNS inside Xray/sing-box; this project needs an explicit DNS-to-SOCKS
# bridge because BypassCore's DNS clients and ChinaDNS-NG dial directly.
run_dns2socks() {
	DNS2SOCKS_OK=0
	DNS_PROXY_NODE=$(default_proxy_node)
	DNS_PROXY_PORT=$(node_socks_port "$DNS_PROXY_NODE")
	[ "$REMOTE_DNS_DETOUR" = "remote" ] || {
		log 0 "Remote DNS outbound is Direct; DNS2SOCKS is not used."
		return 0
	}
	[ -n "$DNS_PROXY_PORT" ] || {
		log 0 "Remote DNS outbound is Remote but no Naive node is selected; service cannot provide proxied DNS."
		return 1
	}
	case "$REMOTE_DNS_PROTOCOL" in tls|doh)
		log 0 "Remote DNS protocol [%s] cannot be carried by DNS2SOCKS; choose Direct outbound or TCP/UDP to avoid a DNS leak." "$REMOTE_DNS_PROTOCOL"
		return 1
		;;
	esac
	[ -n "$DNS2SOCKS_BIN" ] || {
		log 0 "dns2socks is not installed; refusing Remote DNS outbound to prevent a DNS leak."
		return 1
	}
	local upstream
	upstream="${REMOTE_DNS#*://}"
	case "$upstream" in
		\[*\]:*|*:*:*) ;;
		*:*) ;;
		*) upstream="${upstream}:53" ;;
	esac
	ln_run 0 "$DNS2SOCKS_BIN" "$DNS2SOCKS_TAG" "/dev/null" /q \
		"127.0.0.1:${DNS_PROXY_PORT}" "$upstream" "127.0.0.1:${DNS2SOCKS_PORT}"
	sleep 1
	# dns2socks receives ordinary DNS over UDP locally, then carries the query
	# over a SOCKS TCP CONNECT. NaiveProxy does not need SOCKS UDP ASSOCIATE.
	if [ "$(check_port_exists "$DNS2SOCKS_PORT" udp)" -gt 0 ] 2>/dev/null; then
		DNS2SOCKS_OK=1
		set_cache_var DNS2SOCKS_PORT "$DNS2SOCKS_PORT"
		set_cache_var DNS2SOCKS_OK 1
		log 0 "Remote DNS: %s -> DNS2SOCKS :%s -> Naive node [%s] SOCKS :%s." "$upstream" "$DNS2SOCKS_PORT" "$DNS_PROXY_NODE" "$DNS_PROXY_PORT"
	else
		log 0 "dns2socks failed to listen; refusing to start to prevent a DNS leak."
		return 1
	fi
}

# ------------------------------------------------------------------------------
# NaiveProxy protocol adapter. It exposes the selected HTTPS node as a local
# SOCKS upstream; BypassCore remains the only transparent routing core.
# ------------------------------------------------------------------------------

run_naive_node() {
	local node=$1 socks_port=$2 index=$3
	[ -z "$NAIVE_BIN" ] && {
		log 0 "naiveproxy binary not found (install naiveproxy or set naive_file). Transparent proxy disabled."
		NAIVE_OK=0
		return 1
	}

	local address port username password
	address=$(config_n_get "$node" address)
	port=$(config_n_get "$node" port)
	username=$(config_n_get "$node" username)
	password=$(config_n_get "$node" password)
	[ -z "$address" ] || [ -z "$port" ] && { log 0 "Node [%s] has no address/port, skip naive." "$node"; return 1; }

	# IPv6 host bracketing for the proxy URL.
	local server_host=$address
	echo "$address" | grep -qE "([A-Fa-f0-9]{1,4}::?){1,7}[A-Fa-f0-9]{1,4}" && server_host="[$address]"

	local cfg_dir="${TMP_ACL_PATH}/nodes"
	mkdir -p "$cfg_dir"
	local log_file="${cfg_dir}/naive_${node}.log"
	[ "$LOGLEVEL" = "debug" ] && [ "$LOG_NODE" = "1" ] || log_file="/dev/null"

	local socks_cfg="${cfg_dir}/naive_${node}.json"
	json_init
	local socks_host=127.0.0.1
	[ "$NODE_SOCKS_BIND_LOCAL" = "1" ] || socks_host=0.0.0.0
	json_add_string "listen" "socks://${socks_host}:${socks_port}"
	json_add_string "proxy" "https://${username}:${password}@${server_host}:${port}"
	[ "$log_file" != "/dev/null" ] && json_add_string "log" "$log_file"
	json_dump > "$socks_cfg"

	ln_run ${QUEUE_RUN} "$NAIVE_BIN" "${NAIVE_TAG}_${node}" "$log_file" "$socks_cfg"

	NAIVE_OK=1
	log 0 "NaiveProxy node [%s]: socks://127.0.0.1:%s, server=%s:%s" \
		"$node" "$socks_port" "$server_host" "$port"
}

run_naive_nodes() {
	prepare_selected_nodes
	[ -s "$TMP_PATH/selected_nodes" ] || {
		log 0 "No shunt rule selects a NaiveProxy node; starting BypassCore with direct/blackhole rules only."
		return 0
	}
	[ -n "$NAIVE_BIN" ] || { log 0 "naiveproxy binary not found; selected proxy rules cannot start."; return 1; }

	# Every Naive server uses the one Default NaiveProxy Interface. Aggregate all
	# server destinations into one policy table so there is no per-node override.
	if [ -n "$DEFAULT_EGRESS_IFACE" ]; then
		: > "$TMP_PATH/uplink_ips"
		: > "$TMP_PATH/uplink_ips6"
		local node address
		while read -r node; do
			address=$(config_n_get "$node" address)
			resolve_all_ipv4 "$address"
		done < "$TMP_PATH/selected_nodes" | awk 'NF && !seen[$0]++' > "$TMP_PATH/uplink_ips"
		while read -r node; do
			address=$(config_n_get "$node" address)
			resolve_all_ipv6 "$address"
		done < "$TMP_PATH/selected_nodes" | awk 'NF && !seen[$0]++' > "$TMP_PATH/uplink_ips6"
		setup_egress_routing "$DEFAULT_EGRESS_IFACE" "$NAIVE_EGRESS_TABLE" "$NAIVE_EGRESS_RULE_PRIORITY" || return 1
	else
		log 0 "No Default NaiveProxy Interface configured; all Naive nodes use the system default route."
	fi

	local node port index=0
	while read -r node; do
		[ -n "$node" ] || continue
		port=$(node_socks_port "$node")
		run_naive_node "$node" "$port" "$index" || return 1
		index=$((index + 1))
	done < "$TMP_PATH/selected_nodes"
}

# ------------------------------------------------------------------------------
# ChinaDNS-NG split DNS. china-dns = domestic, trust-dns = remote; tags resolved
# domestic IPs into the bypass_chn nftset/ipset so the firewall lets them pass
# direct. Node server IPs go into bypass_vps (always direct).
# ------------------------------------------------------------------------------

run_chinadns_ng() {
	[ -z "$CHINADNS_BIN" ] && {
		log 0 "chinadns-ng not found (install chinadns-ng or set chinadns_file). Split DNS disabled."
		CHINADNS_OK=0
		return 1
	}
	[ -z "$DOMESTIC_DNS" ] && get_direct_dns

	local cfg_dir=$TMP_ACL_PATH
	mkdir -p "$cfg_dir"
	local config_file="${cfg_dir}/chinadns-ng.conf"
	local domain_rules="default-tag gfw"
	local geoview_bin geosite_path chnlist_path
	geoview_bin=$(first_type "$(config_t_get global_app geoview_file /usr/bin/geoview)" geoview)
	geosite_path=$(get_geo_asset_path geosite)
	chnlist_path="${cfg_dir}/chnlist.txt"
	if [ -n "$geoview_bin" ] && [ -s "$geosite_path" ]; then
		rm -f "$chnlist_path"
		"$geoview_bin" -type geosite -action extract -input "$geosite_path" -list cn \
			-lowmem=true -output "$chnlist_path" >/dev/null 2>&1
		if [ -s "$chnlist_path" ]; then
			domain_rules="chnlist-file ${chnlist_path}
	default-tag gfw"
		else
			log 0 "Could not extract geosite:cn; ChinaDNS-NG will use the trusted upstream for all domains."
		fi
	else
		log 0 "geoview/geosite.dat is unavailable; ChinaDNS-NG will use the trusted upstream for all domains."
	fi

	# Include literal and geosite domains from every Direct shunt row. This is
	# the functional counterpart of Passwall2's "Direct DNS result write to
	# IPSet" option; ChinaDNS-NG writes their answers into bypass_chn NFTSet.
	if [ "$WRITE_IPSET_DIRECT" = "1" ]; then
		local _rsid _rdomain _rline _rcode _rtmp
		for _rsid in $(uci -q show "${CONFIG}" 2>/dev/null | sed -n 's/^bypass\.\([^.=]*\)=shunt_rules$/\1/p'); do
			[ "$(config_n_get "$_rsid" outbound)" = "_direct" ] || continue
			_rdomain=$(config_n_get "$_rsid" domain_list)
			while IFS= read -r _rline; do
				case "$_rline" in ''|'#'*) continue ;; esac
				case "$_rline" in
					geosite:*)
						_rcode=${_rline#geosite:}
						_rtmp="${cfg_dir}/geosite-${_rcode}.txt"
						[ -n "$geoview_bin" ] && "$geoview_bin" -type geosite -action extract -input "$geosite_path" -list "$_rcode" -lowmem=true -output "$_rtmp" >/dev/null 2>&1
						[ -s "$_rtmp" ] && cat "$_rtmp" >> "$chnlist_path"
						;;
					domain:*|full:*) echo "${_rline#*:}" >> "$chnlist_path" ;;
					regexp:*|ext:*) ;;
					*) echo "$_rline" >> "$chnlist_path" ;;
				esac
			done <<-EOF
			$_rdomain
			EOF
		done
		[ -s "$chnlist_path" ] && sort -u "$chnlist_path" -o "$chnlist_path"
	fi

	# Build the domain list consumed by ChinaDNS-NG. Literal node IPs are added
	# to bypass_vps directly by nftables.sh.
	[ ! -s "$cfg_dir/vpslist" ] && {
		local node_servers
		node_servers=$(uci show "${CONFIG}" 2>/dev/null | grep -E "(.address=)" | cut -d "'" -f 2)
		echo "$node_servers" | while read -r h; do host_from_url "$h"; done | grep '[a-zA-Z]$' | sort -u > "$cfg_dir/vpslist"
	}

	# nftset names (nftables is the only supported backend).
	local set_names direct_set_names vps_set_names
	set_names="inet@bypass@bypass_chn,inet@bypass@bypass_chn6"
	direct_set_names="inet@bypass@bypass_direct_dns,inet@bypass@bypass_direct_dns6"
	vps_set_names="inet@bypass@bypass_vps,inet@bypass@bypass_vps6"

	local remote_upstream=$REMOTE_DNS
	if [ "$DNS2SOCKS_OK" = "1" ]; then
		remote_upstream="udp://127.0.0.1:${DNS2SOCKS_PORT}"
	else case "$REMOTE_DNS_PROTOCOL" in
		udp) remote_upstream=$REMOTE_DNS ;;
		tcp) remote_upstream="tcp://${REMOTE_DNS#tcp://}" ;;
		tls) remote_upstream="tls://${REMOTE_DNS#tls://}" ;;
		doh) remote_upstream="$REMOTE_DNS_DOH" ;;
		*) remote_upstream="tcp://${REMOTE_DNS#*://}" ;;
	esac
	fi
	# ChinaDNS-NG is the DNS listener used by LAN clients, so mirror the
	# Passwall2 Domain Override values into its hosts table as well as the
	# BypassCore DNS client below.
	local hosts_file="${cfg_dir}/hosts" _host_name _host_target _host_extra
	: > "$hosts_file"
	while IFS=' ' read -r _host_name _host_target _host_extra; do
		case "$_host_name" in ''|'#'*) continue ;; esac
		[ -n "$_host_target" ] && [ -z "$_host_extra" ] || continue
		_host_name=${_host_name#full:}
		_host_name=${_host_name#domain:}
		case "$_host_target" in
			*:*|[0-9]*.[0-9]*.[0-9]*.[0-9]*) printf '%s %s\n' "$_host_target" "$_host_name" >> "$hosts_file" ;;
			*) log 0 "Domain Override [%s] is not an IPv4/IPv6 address; ChinaDNS-NG ignored it." "$_host_target" ;;
		esac
	done <<-EOF
	$DNS_HOSTS
	EOF

	local tagchn_line="add-tagchn-ip ${set_names}"
	local direct_ipset_line=""
	[ "$WRITE_IPSET_DIRECT" = "1" ] && direct_ipset_line="group-ipset ${direct_set_names}"

	# Direct domain DNS routing groups (same line format as Passwall2). Each
	# group selects its own upstream and writes answers to the direct NFTSet.
	local direct_dns_groups="" _dd_domain _dd_upstream _dd_extra _dd_index=0 _dd_file _dd_code
	while IFS=' ' read -r _dd_domain _dd_upstream _dd_extra; do
		case "$_dd_domain" in ''|'#'*) continue ;; esac
		[ -n "$_dd_upstream" ] && [ -z "$_dd_extra" ] || continue
		_dd_index=$((_dd_index + 1))
		_dd_file="${cfg_dir}/direct-dns-${_dd_index}.list"
		: > "$_dd_file"
		case "$_dd_domain" in
			geosite:*)
				_dd_code=${_dd_domain#geosite:}
				[ -n "$geoview_bin" ] && "$geoview_bin" -type geosite -action extract -input "$geosite_path" -list "$_dd_code" -lowmem=true -output "$_dd_file" >/dev/null 2>&1
				;;
			domain:*|full:*) echo "${_dd_domain#*:}" > "$_dd_file" ;;
		esac
		[ -s "$_dd_file" ] || continue
		direct_dns_groups="${direct_dns_groups}
	group direct_dns_${_dd_index}
	group-dnl ${_dd_file}
	group-upstream ${_dd_upstream}
	${direct_ipset_line}"
	done <<-EOF
	$DIRECT_DNS_SHUNT
	EOF

	cat <<-EOF > "$config_file"
		bind-addr 127.0.0.1
		bind-port ${CHINADNS_PORT}
		china-dns ${DOMESTIC_DNS}
		trust-dns ${remote_upstream}
		filter-qtype 65
		$([ -s "$hosts_file" ] && echo "hosts ${hosts_file}")
		${tagchn_line}
		${domain_rules}
		group vpslist
		group-dnl ${cfg_dir}/vpslist
		group-upstream ${DOMESTIC_DNS}
		group-ipset ${vps_set_names}
		${direct_dns_groups}
	EOF

	ln_run 0 "$CHINADNS_BIN" "$CHINADNS_TAG" "/dev/null" -C "$config_file" -v
	sleep 1
	if [ "$(check_port_exists "$CHINADNS_PORT" udp)" -gt 0 ] 2>/dev/null; then
		CHINADNS_OK=1
		log 0 "ChinaDNS-NG: :%s  domestic=%s  remote=%s (%s)" "$CHINADNS_PORT" "$DOMESTIC_DNS" "$remote_upstream" "$REMOTE_DNS_PROTOCOL"
	else
		CHINADNS_OK=0
		log 0 "ChinaDNS-NG failed to listen on UDP :%s; check its generated config and binary capabilities." "$CHINADNS_PORT"
		return 1
	fi
}

# ------------------------------------------------------------------------------
# BypassCore config.json (routing/split-decision engine config).
# Generated from the same UCI shunt_rules that feed the firewall/ipset plane.
# ------------------------------------------------------------------------------

# Map a UCI shunt outbound token to a BypassCore outbound tag.
map_outbound_tag() {
	case "$1" in
		_direct) echo "direct" ;;
		_blackhole|_block) echo "block" ;;
		"") echo "" ;;
		*)
			if [ "$(config_get_type "$1")" = "nodes" ]; then
				echo "proxy_$1"
			else
				echo "$1"
			fi
			;;
	esac
}

gen_bypasscore_config() {
	mkdir -p "$(dirname "$BYPASSCORE_CFG")"
	BYPASSCORE_CONFIG_ERROR=0
	prepare_selected_nodes

	json_init
	# outbounds: direct / block / proxy.
	json_add_array outbounds
		json_add_object ''
			json_add_string tag direct
			json_add_string mode freedom
			# BypassCore needs the runtime L3 device (e.g. pppoe-wan), not the
			# OpenWrt logical network name (e.g. wan).
			if [ -n "$DIRECT_EGRESS_IFACE" ]; then
				if get_egress_runtime "$DIRECT_EGRESS_IFACE"; then
					json_add_object bind
						json_add_string interface "$EGRESS_DEVICE"
					json_close_object
				else
					log 0 "Direct egress interface [%s] is down or has no L3 device; refusing an unbound direct outbound." "$DIRECT_EGRESS_IFACE"
					BYPASSCORE_CONFIG_ERROR=1
				fi
			fi
		json_close_object
		json_add_object ''
			json_add_string tag block
			json_add_string mode blackhole
		json_close_object
		local _node _node_port
		while read -r _node; do
			[ -n "$_node" ] || continue
			_node_port=$(node_socks_port "$_node")
			json_add_object ''
				json_add_string tag "proxy_${_node}"
				json_add_string mode proxy
				json_add_object upstream
					json_add_string protocol socks
					json_add_string server "127.0.0.1:${_node_port}"
					json_add_object settings
					json_close_object
				json_close_object
			json_close_object
		done < "$TMP_PATH/selected_nodes"
		# A Direct shunt rule may override the global Direct interface. Each
		# override needs its own freedom outbound because the bind belongs to an
		# outbound, not to an individual routing rule.
		local _sid _outbound _egress
		for _sid in $(uci -q show "${CONFIG}" 2>/dev/null | sed -n 's/^bypass\.\([^.=]*\)=shunt_rules$/\1/p'); do
			_outbound=$(config_n_get "$_sid" outbound _direct)
			_egress=$(config_n_get "$_sid" egress_interface)
			[ "$_outbound" = "_direct" ] && [ -n "$_egress" ] || continue
			json_add_object ''
				json_add_string tag "direct_${_sid}"
				json_add_string mode freedom
				if get_egress_runtime "$_egress"; then
					json_add_object bind
						json_add_string interface "$EGRESS_DEVICE"
					json_close_object
				else
					log 0 "Direct rule [%s] egress interface [%s] is down or has no L3 device." "$_sid" "$_egress"
					BYPASSCORE_CONFIG_ERROR=1
				fi
			json_close_object
		done
	json_close_array

	# DNS mirrors Passwall2's direct/remote model. Direct-domain overrides and
	# query strategies are emitted into BypassCore, while the default remote
	# resolver optionally goes through DNS2SOCKS and the selected Default node.
	if [ -n "$DOMESTIC_DNS" ] || [ -n "$REMOTE_DNS" ] || [ -n "$REMOTE_DNS_DOH" ]; then
		json_add_object dns
			json_add_array servers
				local _dns_domain _dns_upstream _dns_extra _dns_address _dns_port _dns_count=0
				while IFS=' ' read -r _dns_domain _dns_upstream _dns_extra; do
					case "$_dns_domain" in ''|'#'*) continue ;; esac
					case "$_dns_domain" in domain:*|full:*|geosite:*|regexp:*) ;; *)
						log 0 "Invalid Direct domain DNS routing rule [%s]." "$_dns_domain"
						BYPASSCORE_CONFIG_ERROR=1
						continue
						;;
					esac
					[ -n "$_dns_upstream" ] && [ -z "$_dns_extra" ] || {
						log 0 "Invalid Direct domain DNS routing entry for [%s]." "$_dns_domain"
						BYPASSCORE_CONFIG_ERROR=1
						continue
					}
					case "$_dns_upstream" in
						udp://*|tcp://*|tls://*|[0-9]*.[0-9]*.[0-9]*.[0-9]*|*:*:*) ;;
						*)
							log 0 "Unsupported Direct DNS upstream [%s]; use UDP, TCP or TLS with an IP address." "$_dns_upstream"
							BYPASSCORE_CONFIG_ERROR=1
							continue
							;;
					esac
					_dns_count=$((_dns_count + 1))
					if [ "$_dns_count" -gt 5 ]; then
						log 0 "ChinaDNS-NG supports at most five Direct domain DNS routing entries."
						BYPASSCORE_CONFIG_ERROR=1
						continue
					fi
					# BypassCore's embedded DNS client is UDP-only. ChinaDNS-NG still
					# applies TCP/TLS entries for LAN DNS; omit them here rather than
					# silently sending UDP packets to a TCP/DoT-only endpoint.
					case "$_dns_upstream" in tcp://*|tls://*) continue ;; esac
					_dns_address=$_dns_upstream
					_dns_port=""
					case "$_dns_upstream" in
						*://*)
							_dns_address=${_dns_upstream#*://}
							_dns_address=${_dns_address#*@}
							_dns_address=${_dns_address%%\?*}
							case "$_dns_address" in *#*) _dns_port=${_dns_address##*#}; _dns_address=${_dns_address%%#*} ;; esac
							case "$_dns_address" in
								*:*:*) ;;
								*:*) [ -n "$_dns_port" ] || { _dns_port=${_dns_address##*:}; _dns_address=${_dns_address%:*}; } ;;
							esac
							;;
					esac
					if [ -n "$_dns_port" ] && ! echo "$_dns_port" | grep -qE '^[0-9]+$'; then
						log 0 "Invalid DNS port in Direct domain DNS routing entry [%s]." "$_dns_upstream"
						BYPASSCORE_CONFIG_ERROR=1
						continue
					fi
					json_add_object ''
						json_add_string address "$_dns_address"
						[ -n "$_dns_port" ] && json_add_int port "$_dns_port"
						json_add_string queryStrategy "$DIRECT_DNS_QUERY_STRATEGY"
						json_add_array domains
							json_add_string '' "$_dns_domain"
						json_close_array
					json_close_object
				done <<-EOF
				$DIRECT_DNS_SHUNT
				EOF

				if [ -n "$DOMESTIC_DNS" ] && [ -n "$DNS_SPLIT_DOMAIN" ]; then
					local _domestic_first
					_domestic_first=$(printf '%s' "$DOMESTIC_DNS" | tr ',' ' ' | awk '{print $1}')
					json_add_object ''
						json_add_string address "$_domestic_first"
						json_add_string tag domestic
						json_add_string queryStrategy "$DIRECT_DNS_QUERY_STRATEGY"
						json_add_array domains
							local _sd
							for _sd in $(echo "$DNS_SPLIT_DOMAIN" | tr '\n' ' '); do [ -n "$_sd" ] && json_add_string '' "$_sd"; done
						json_close_array
					json_close_object
				fi
				if [ -n "$REMOTE_DNS" ] || [ -n "$REMOTE_DNS_DOH" ]; then
					json_add_object ''
						if [ "$DNS2SOCKS_OK" = "1" ] || [ "$(get_cache_var DNS2SOCKS_OK)" = "1" ]; then
							json_add_string address "127.0.0.1"
							json_add_int port "$DNS2SOCKS_PORT"
						else
							local _remote_address _remote_port
							_remote_address=${REMOTE_DNS#udp://}
							_remote_port=""
							if [ "$REMOTE_DNS_PROTOCOL" = "udp" ]; then
								case "$_remote_address" in *:*:*) ;; *:*) _remote_port=${_remote_address##*:}; _remote_address=${_remote_address%:*} ;; esac
							fi
							case "$REMOTE_DNS_PROTOCOL" in
								doh) json_add_string address "$REMOTE_DNS_DOH" ;;
								tls) json_add_string address "tls://${REMOTE_DNS#tls://}" ;;
								tcp) json_add_string address "tcp://${REMOTE_DNS#tcp://}" ;;
								*) json_add_string address "$_remote_address" ;;
							esac
							[ -n "$_remote_port" ] && json_add_int port "$_remote_port"
						fi
						json_add_string tag remote
						json_add_string queryStrategy "$REMOTE_DNS_QUERY_STRATEGY"
						[ -n "$REMOTE_DNS_CLIENT_IP" ] && json_add_string clientIp "$REMOTE_DNS_CLIENT_IP"
					json_close_object
				fi
			json_close_array
			json_add_string queryStrategy "$REMOTE_DNS_QUERY_STRATEGY"
			if [ -n "$DNS_HOSTS" ]; then
				json_add_object hosts
					local _host_rule _host_target _host_extra
					while IFS=' ' read -r _host_rule _host_target _host_extra; do
						case "$_host_rule" in ''|'#'*) continue ;; esac
						[ -n "$_host_target" ] && [ -z "$_host_extra" ] || { BYPASSCORE_CONFIG_ERROR=1; continue; }
						json_add_string "$_host_rule" "$_host_target"
					done <<-EOF
					$DNS_HOSTS
					EOF
				json_close_object
			fi
		json_close_object
	fi

	# routing
	json_add_object routing
		json_add_string domainStrategy "$DOMAIN_STRATEGY"
		json_add_array rules
			# This rule must precede the default PrivateIP direct rule; otherwise
			# the UI switch would only alter nftables but BypassCore would still
			# route matching private destinations directly.
			local _force_node _force_tag
			_force_node=$(default_proxy_node)
			[ -n "$_force_node" ] && _force_tag="proxy_${_force_node}"
			if [ "$FORCE_PROXY_LAN_IP" = "1" ] && [ -z "$_force_tag" ]; then
				log 0 "Force Proxy LAN IP is enabled but no NaiveProxy node is selected by any shunt rule."
				BYPASSCORE_CONFIG_ERROR=1
			fi
			if [ "$FORCE_PROXY_LAN_IP" = "1" ] && [ -n "$_force_tag" ]; then
				json_add_object ''
					json_add_string outboundTag "$_force_tag"
					json_add_string network tcp
					json_add_array ip
						json_add_string '' "10.0.0.0/8"
						json_add_string '' "100.64.0.0/10"
						json_add_string '' "172.16.0.0/12"
						json_add_string '' "192.168.0.0/16"
						json_add_string '' "fc00::/7"
					json_close_array
				json_close_object
			fi
			local sid tag domains ips net outbound egress default_sid default_outbound
			for sid in $(uci -q show "${CONFIG}" 2>/dev/null | grep "=shunt_rules" | cut -d '.' -f2 | cut -d '=' -f1); do
				[ "$(config_n_get "$sid" is_default 0)" = "1" ] && { default_sid=$sid; continue; }
				outbound=$(config_n_get "$sid" outbound _direct)
				[ -n "$outbound" ] || continue
				egress=$(config_n_get "$sid" egress_interface)
				if [ "$outbound" = "_direct" ] && [ -n "$egress" ]; then
					tag="direct_${sid}"
				else
					tag=$(map_outbound_tag "$outbound")
				fi
				[ -z "$tag" ] && tag=direct
				json_add_object ''
					json_add_string outboundTag "$tag"
					domains=$(config_n_get "$sid" domain_list)
					if [ -n "$domains" ]; then
						json_add_array domain
						local d
						for d in $(echo "$domains" | tr '\n' ' '); do [ -n "$d" ] && json_add_string '' "$d"; done
						json_close_array
					fi
					ips=$(config_n_get "$sid" ip_list)
					if [ -n "$ips" ]; then
						json_add_array ip
						local i
						for i in $(echo "$ips" | tr '\n' ' '); do [ -n "$i" ] && json_add_string '' "$i"; done
						json_close_array
					fi
					net=$(config_n_get "$sid" network tcp,udp)
					[ -n "$net" ] && json_add_string network "$net"
				json_close_object
			done
			# The reserved Default row is always emitted last as the catch-all.
			tag=""
			egress=""
			default_outbound=""
			if [ -n "$default_sid" ]; then
				default_outbound=$(config_n_get "$default_sid" outbound _direct)
				egress=$(config_n_get "$default_sid" egress_interface)
				if [ "$default_outbound" = "_direct" ] && [ -n "$egress" ]; then tag="direct_${default_sid}"; else tag=$(map_outbound_tag "$default_outbound"); fi
			fi
			[ -n "$tag" ] && {
				json_add_object ''
					json_add_string outboundTag "$tag"
					json_add_string network "$(config_n_get "$default_sid" network tcp,udp)"
				json_close_object
			}
		json_close_array
	json_close_object

	# observatory (only useful if the bypasscore binary is present)
	if is_linux_elf "$BYPASSCORE_FILE" 2>/dev/null; then
		json_add_object observatory
			json_add_array subject_selector
				json_add_string '' proxy_
			json_close_array
			json_add_string probe_url "https://www.gstatic.com/generate_204"
			json_add_int probe_interval 10000000000
			# enable_concurrency omitted: jshn's json_add_boolean is unreliable
			# across OpenWrt versions (can emit a string "true" that the Go proto
			# bool rejects, failing the whole config parse). The field defaults
			# to false in the proto, which is fine for the routing engine.
		json_close_object
	fi

	# BypassCore owns the transparent inbound on REDIR_PORT.
	# REDIR_PORT as a transparent listener; nftables REDIRECT/TPROXY sends
	# traffic here instead of to naiveproxy. type/network follow tcp_proxy_way:
	#   redirect -> TCP only (SO_ORIGINAL_DST)
	#   tproxy   -> TCP with IP_TRANSPARENT. NaiveProxy's SOCKS5 listener
	#               rejects UDP ASSOCIATE, so capturing UDP would blackhole it.
	local in_type="redirect" in_net="tcp"
	if [ "$TCP_PROXY_WAY" = "tproxy" ] || [ "$PROXY_IPV6" = "1" ]; then
		in_type="tproxy"
	fi
	json_add_array inbounds
		json_add_object ''
			json_add_string tag "tcp_redir"
			json_add_string type "$in_type"
			json_add_string listen "127.0.0.1"
			json_add_int port "$REDIR_PORT"
			json_add_string network "$in_net"
			json_add_boolean sniffing 1
		json_close_object
		if [ "$PROXY_IPV6" = "1" ]; then
			json_add_object ''
				json_add_string tag "ipv6_tproxy"
				json_add_string type "tproxy"
				json_add_string listen "::1"
				json_add_int port "$REDIR_PORT"
				json_add_string network "tcp"
				json_add_boolean sniffing 1
			json_close_object
		fi
	json_close_array

	json_dump > "$BYPASSCORE_CFG"
	log 0 "BypassCore config written to %s." "$BYPASSCORE_CFG"
	[ "$BYPASSCORE_CONFIG_ERROR" = "0" ]
}

# ------------------------------------------------------------------------------
# BypassCore transparent core: `bypasscore -run -c <cfg>` (daemon).
# ------------------------------------------------------------------------------
run_bypasscore_core() {
	if ! is_linux_elf "$BYPASSCORE_FILE" 2>/dev/null; then
		log 0 "BypassCore is missing or is not a Linux ELF; service cannot start."
		return 1
	fi
	gen_bypasscore_config || return 1
	local cfg_dir=$TMP_ACL_PATH
	mkdir -p "$cfg_dir"
	local log_file="${cfg_dir}/bypasscore.log"
	[ "$LOGLEVEL" = "debug" ] && [ "$LOG_NODE" = "1" ] || log_file="/dev/null"
	ln_run ${QUEUE_RUN} "$BYPASSCORE_FILE" "bypasscore" "$log_file" -config "$BYPASSCORE_CFG" -run
	BYPASSCORE_OK=1
	set_cache_var ACL_GLOBAL_redir_port "$REDIR_PORT"
	log 0 "BypassCore running as transparent core on tcp://127.0.0.1:%s (-run)." "$REDIR_PORT"
}

# ------------------------------------------------------------------------------
# Firewall backend selection
# ------------------------------------------------------------------------------

check_run_environment() {
	# nftables (fw4) is the only supported backend.
	USE_TABLES=""
	if [ -x /usr/sbin/nft ] || command -v nft >/dev/null 2>&1; then
		USE_TABLES=nftables
	else
		log 0 "nftables (nft) not found. Transparent proxy will not redirect."
		return 1
	fi
	log 0 "Firewall backend: %s" "$USE_TABLES"
}

# ------------------------------------------------------------------------------
# dnsmasq integration: forward :53 to the ChinaDNS-NG listener.
# ------------------------------------------------------------------------------

run_dnsmasq_forward() {
	[ "$CHINADNS_OK" != "1" ] && return 0
	[ "$(check_port_exists "$CHINADNS_PORT" udp)" -gt 0 ] 2>/dev/null || {
		log 0 "ChinaDNS-NG is not listening on :%s; leave dnsmasq unchanged." "$CHINADNS_PORT"
		return 1
	}
	[ "$DNS_REDIRECT" = "1" ] || {
		log 0 "dnsmasq forwarding is disabled; ChinaDNS-NG remains available on :%s." "$CHINADNS_PORT"
		return 0
	}
	# Save the current upstream so we can restore on stop.
	local old old_rebind
	old=$(uci -q get dhcp.@dnsmasq[0].server 2>/dev/null)
	old_rebind=$(uci -q get dhcp.@dnsmasq[0].rebind_protection 2>/dev/null)
	set_cache_var bak_dnsmasq_server "${old:-__unset__}"
	set_cache_var bak_dnsmasq_rebind "${old_rebind:-__unset__}"
	set_cache_var DNSMASQ_MODIFIED 1
	uci -q delete dhcp.@dnsmasq[0].server 2>/dev/null
	uci -q add_list dhcp.@dnsmasq[0].server="127.0.0.1#${CHINADNS_PORT}" 2>/dev/null
	uci -q set dhcp.@dnsmasq[0].rebind_protection='0' 2>/dev/null
	uci -q commit dhcp 2>/dev/null
	/etc/init.d/dnsmasq restart >/dev/null 2>&1
	log 0 "dnsmasq forwarded to ChinaDNS-NG :%s." "$CHINADNS_PORT"
}

restore_dnsmasq_forward() {
	[ "$(get_cache_var DNSMASQ_MODIFIED)" = "1" ] || return 0
	local bak bak_rebind
	bak=$(get_cache_var bak_dnsmasq_server)
	bak_rebind=$(get_cache_var bak_dnsmasq_rebind)
	uci -q delete dhcp.@dnsmasq[0].server 2>/dev/null
	[ -n "$bak" ] && [ "$bak" != "__unset__" ] && {
		local s
		for s in $bak; do uci -q add_list dhcp.@dnsmasq[0].server="$s" 2>/dev/null; done
	}
	if [ "$bak_rebind" = "__unset__" ]; then
		uci -q delete dhcp.@dnsmasq[0].rebind_protection 2>/dev/null
	elif [ -n "$bak_rebind" ]; then
		uci -q set dhcp.@dnsmasq[0].rebind_protection="$bak_rebind" 2>/dev/null
	fi
	uci -q commit dhcp 2>/dev/null
	/etc/init.d/dnsmasq restart >/dev/null 2>&1
}

# ------------------------------------------------------------------------------
# Crontab (periodic geodata update + uplink re-resolve)
# ------------------------------------------------------------------------------

# Translate a passwall2-style week/time/interval mode triple into a 5-field
# crontab minute/hour/dow prefix. week_mode: ""=disabled, "8"=loop(by interval),
# 0=Sunday..6=Saturday, 7=every day. time_mode="HH:MM", interval_mode=N hours.
# Echoes the cron prefix (e.g. "30 4 * * *") or empty if disabled.
cron_prefix() {
	local week=$1 time=$2 interval=$3
	[ -z "$week" ] && { echo ""; return; }
	local hh mm
	hh=$(echo "$time" | awk -F: '{print $1}')
	mm=$(echo "$time" | awk -F: '{print $2}')
	[ -z "$hh" ] && hh=0
	[ -z "$mm" ] && mm=0
	if [ "$week" = "8" ]; then
		# Loop mode: every N hours.
		echo "0 */${interval:-2} * * *"
	elif [ "$week" = "7" ]; then
		echo "$mm $hh * * *"
	else
		echo "$mm $hh * * $week"
	fi
}

start_crontab() {
	# GeoData auto-update (global_rules.update_*_mode, passwall2-style).
	local week time interval prefix
	week=$(config_t_get global_rules update_week_mode)
	time=$(config_t_get global_rules update_time_mode "0:00")
	interval=$(config_t_get global_rules update_interval_mode 2)
	local geo_en geoip_en
	geo_en=$(config_t_get global_rules geosite_update 1)
	geoip_en=$(config_t_get global_rules geoip_update 1)
	if { [ "$geo_en" = "1" ] || [ "$geoip_en" = "1" ]; } && [ -n "$week" ]; then
		prefix=$(cron_prefix "$week" "$time" "$interval")
		[ -n "$prefix" ] && echo "$prefix ${APP_PATH}/rule_update.sh >>${LOG_FILE} 2>&1" >> /etc/crontabs/root
	fi
	# Re-resolve naive uplink IPs every hour (DNS round-robin / IP changes).
	echo "0 * * * * ${APP_PATH}/rule_update.sh refresh_uplink >>${LOG_FILE} 2>&1" >> /etc/crontabs/root

	# Scheduled stop / start / restart (global_delay.*_week_mode).
	local verb
	for verb in stop start restart; do
		week=$(config_t_get global_delay ${verb}_week_mode)
		[ -z "$week" ] && continue
		time=$(config_t_get global_delay ${verb}_time_mode "0:00")
		interval=$(config_t_get global_delay ${verb}_interval_mode 2)
		prefix=$(cron_prefix "$week" "$time" "$interval")
		[ -n "$prefix" ] && echo "$prefix /etc/init.d/bypass ${verb} >/dev/null 2>&1" >> /etc/crontabs/root
	done

	/etc/init.d/cron restart >/dev/null 2>&1
}

stop_crontab() {
	# Remove only the lines this app added (rule_update + init.d/bypass).
	sed -i "/${APP_PATH//\//\\/}\/rule_update\.sh/d; /\/etc\/init\.d\/bypass /d" /etc/crontabs/root 2>/dev/null
	/etc/init.d/cron restart >/dev/null 2>&1
}

# ------------------------------------------------------------------------------
# Lifecycle
# ------------------------------------------------------------------------------

start() {
	busybox pgrep -f "$TMP_BIN_PATH" >/dev/null 2>&1 && {
		log 0 "Stale subprocess detected, cleaning first..."
		(stop) 2>/dev/null
		sleep 1
	}
	mkdir -p /tmp/etc /tmp/log "$TMP_PATH" "$TMP_BIN_PATH" "$TMP_ROUTE_PATH" "$TMP_ACL_PATH" "$TMP_PATH2"

	get_config
	export BYPASSCORE_ASSETS="$V2RAY_LOCATION_ASSET"
	export ENABLE_DEPRECATED_GEOSITE=true
	export ENABLE_DEPRECATED_GEOIP=true
	ulimit -n 65535 2>/dev/null

	NAIVE_OK=0
	BYPASSCORE_OK=0
	CHINADNS_OK=0
	DNS2SOCKS_OK=0
	unset_cache_var DNS2SOCKS_OK

	# If the service is disabled, do nothing — especially do NOT install the
	# nftables REDIRECT ruleset (it would send all TCP to a dead REDIR_PORT and
	# blackhole the router's own WAN). Bail out early and cleanly.
	[ "$ENABLED" = "1" ] || {
		log 0 "Bypass is disabled (enabled=0). Skipping start."
		echolog ""
		return 0
	}
	check_run_environment || return 1
	if ! is_linux_elf "$BYPASSCORE_FILE" 2>/dev/null; then
		log 0 "BypassCore is required but unavailable at [%s]; service not started." "$BYPASSCORE_FILE"
		return 1
	fi
	prepare_selected_nodes
	run_naive_nodes || { stop; return 1; }
	run_dns2socks || { stop; return 1; }
	run_bypasscore_core || { stop; return 1; }
	if ! run_chinadns_ng && [ "$DNS_REDIRECT" = "1" ]; then
		log 0 "DNS Redirect is enabled but ChinaDNS-NG is unavailable; refusing to start with an incomplete DNS path."
		stop
		return 1
	fi

	# Give BypassCore a moment to open its listener. A core that dies immediately
	# (bad config, incompatible binary, or unavailable Naive SOCKS upstream)
	# means REDIR_PORT is dead — installing REDIRECT would blackhole
	# the router, so skip it with a clear log line.
	sleep 2
	local _check_node _check_port _listeners_ok=1
	while read -r _check_node _check_port; do
		[ -n "$_check_port" ] || continue
		[ "$(check_port_exists "$_check_port" tcp)" -gt 0 ] 2>/dev/null || _listeners_ok=0
	done < "$TMP_PATH/node_ports"
	if [ "$(check_port_exists "$REDIR_PORT" tcp)" -le 0 ] 2>/dev/null || [ "$_listeners_ok" != "1" ]; then
		log 0 "BypassCore or its required NaiveProxy SOCKS upstream failed to listen; firewall and DNS were not modified."
		stop
		return 1
	fi
	if ! source "$APP_PATH/${USE_TABLES}.sh" start; then
		log 0 "Firewall setup failed; stopping managed processes and leaving DNS unchanged."
		stop
		return 1
	fi
	set_cache_var USE_TABLES "$USE_TABLES"
	# Only hand dnsmasq to ChinaDNS-NG after the process is listening and the
	# nft sets used by add-tagchn-ip have been created.
	run_dnsmasq_forward

	# Bridge-nf call disable so iptables sees bridged traffic cleanly.
	if [ "$NAIVE_OK" = "1" ]; then
		local bnf
		bnf=$(sysctl -e -n net.bridge.bridge-nf-call-iptables 2>/dev/null)
		[ -n "$bnf" ] && set_cache_var bak_bridge_nf_ipt "$bnf"
		sysctl -w net.bridge.bridge-nf-call-iptables=0 >/dev/null 2>&1
	fi

	start_crontab
	log 0 "Bypass started."
	echolog ""
}

stop() {
	clean_log
	USE_TABLES=$(get_cache_var USE_TABLES)
	# Always tear down the nftables tables, even if USE_TABLES isn't set in the
	# cache (e.g. after a reboot where the cache file is gone). A leftover
	# REDIRECT rule pointing at a dead REDIR_PORT would blackhole the router.
	[ -n "$USE_TABLES" ] && source "$APP_PATH/${USE_TABLES}.sh" stop 2>/dev/null
	NFT_BIN=$(command -v nft 2>/dev/null || echo /usr/sbin/nft)
	[ -x "$NFT_BIN" ] && {
		$NFT_BIN delete table inet bypass 2>/dev/null
	}
	while ip rule del priority 998 fwmark 0x10000/0x10000 lookup 20100 2>/dev/null; do :; done
	ip route flush table 20100 proto 99 2>/dev/null
	while ip -6 rule del priority 998 fwmark 0x10000/0x10000 lookup 20101 2>/dev/null; do :; done
	ip -6 route flush table 20101 proto 99 2>/dev/null
	teardown_egress_routing
	restore_dnsmasq_forward

	# Kill our managed proxy processes (naive / chinadns-ng), sparing control scripts.
	busybox pgrep -af "${CONFIG}/monitor" 2>/dev/null | xargs -r kill -9 >/dev/null 2>&1
	busybox pgrep -af "$TMP_BIN_PATH" 2>/dev/null | awk '!/app\.sh|rule_update|api\.sh|ujail/{print $1}' | xargs -r kill -9 >/dev/null 2>&1

	unset BYPASSCORE_ASSETS ENABLE_DEPRECATED_GEOSITE ENABLE_DEPRECATED_GEOIP
	stop_crontab

	local bak_bnf
	bak_bnf=$(get_cache_var bak_bridge_nf_ipt)
	[ -n "$bak_bnf" ] && sysctl -w net.bridge.bridge-nf-call-iptables="$bak_bnf" >/dev/null 2>&1

	rm -rf "$TMP_PATH"
	log 0 "Bypass stopped."
}

# ------------------------------------------------------------------------------
# Dispatcher — only when run directly, not when sourced (api.sh sources this
# file to reuse get_config / gen_bypasscore_config).
# ------------------------------------------------------------------------------

if [ "${APP_SOURCED:-0}" != "1" ]; then
	arg1=$1
	shift
	case "$arg1" in
		gen_config) get_config; gen_bypasscore_config ;;
		start)     start "$@" ;;
		stop)      stop ;;
		*)
			echo "Usage: $0 {start|stop|gen_config}"
			;;
	esac
fi
