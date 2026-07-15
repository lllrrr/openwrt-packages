#!/bin/sh
# Copyright (c) 2026 Eugene Chan
# SPDX-License-Identifier: MIT
#
# Orchestrator for luci-app-bypass. Read UCI, run the naiveproxy carrier,
# generate BypassCore's routing and native DNS configuration, run ChinaDNS-NG
# as the Direct/NFTSet helper, install the transparent-proxy firewall ruleset,
# and manage the process lifecycle.
# Mirrors openwrt-passwall2/app.sh but in pure shell.

. /lib/functions.sh
. /usr/share/libubox/jshn.sh
. ${APP_PATH:-/usr/share/bypass}/utils.sh

NAIVE_TAG=naive
CHINADNS_TAG=chinadns-ng

# ------------------------------------------------------------------------------
# Config snapshot
# ------------------------------------------------------------------------------

get_direct_dns() {
	local DOMESTIC ISP_DNS
	ISP_DNS=$(get_direct_dns_ipv4)
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
	LOG_LEVEL=$(config_t_get global loglevel error)
	case "$LOG_LEVEL" in
		debug|info|warning|error) ;;
		*) LOG_LEVEL=error ;;
	esac
	DNS_REDIRECT=$(config_t_get global dns_redirect 1)
	START_DAEMON=$(config_t_get global_delay start_daemon 1)

	BYPASSCORE_FILE=$(config_t_get global bypasscore_file /usr/bin/bypasscore)
	NAIVE_BIN=$(first_type "$(config_t_get global naive_file /usr/bin/naive)" naive)
	CHINADNS_BIN=$(first_type "$(config_t_get global chinadns_file /usr/bin/chinadns-ng)" chinadns-ng)
	# BypassCore is the mandatory transparent routing core. NaiveProxy only
	# exposes the selected Naive node as a local SOCKS upstream for BypassCore.
	V2RAY_LOCATION_ASSET=$(config_t_get global_rules v2ray_location_asset /usr/share/v2ray/)
	local detected_geosite
	detected_geosite=$(get_geo_asset_path geosite)
	[ -n "$detected_geosite" ] && V2RAY_LOCATION_ASSET="${detected_geosite%/*}/"
	DOMAIN_STRATEGY=$(config_t_get global_rules domainStrategy IpOnDemand)
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
	PROXY_IPV6=$(config_t_get global_forwarding ipv6_tproxy 0)
	ACCEPT_ICMP=$(config_t_get global_forwarding accept_icmp 0)

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
	# BypassCore's native DNS listener is dnsmasq's main upstream. Reuse the live
	# port for status/config previews; select a free TCP+UDP port only when there
	# is no active runtime value.
	BYPASSCORE_DNS_PORT=$(get_cache_var BYPASSCORE_DNS_PORT)
	if [ -z "$BYPASSCORE_DNS_PORT" ]; then
		BYPASSCORE_DNS_PORT=$(config_t_get global_dns bypasscore_dns_listen_port 10554)
		echo "$BYPASSCORE_DNS_PORT" | grep -qE '^[0-9]+$' || BYPASSCORE_DNS_PORT=10554
		[ "$BYPASSCORE_DNS_PORT" -ge 1 ] 2>/dev/null && [ "$BYPASSCORE_DNS_PORT" -le 65535 ] 2>/dev/null || BYPASSCORE_DNS_PORT=10554
		while [ "$BYPASSCORE_DNS_PORT" = "$CHINADNS_PORT" ] || \
			[ "$BYPASSCORE_DNS_PORT" = "$REDIR_PORT" ] || \
			[ "$(check_port_exists "$BYPASSCORE_DNS_PORT" tcp)" -gt 0 ] 2>/dev/null || \
			[ "$(check_port_exists "$BYPASSCORE_DNS_PORT" udp)" -gt 0 ] 2>/dev/null; do
			BYPASSCORE_DNS_PORT=$((BYPASSCORE_DNS_PORT + 1))
			[ "$BYPASSCORE_DNS_PORT" -le 65535 ] || BYPASSCORE_DNS_PORT=10554
		done
	fi
	DNS_SPLIT_DOMAIN=$(config_t_get global_dns dns_split_domain geosite:cn)

	# Per-node egress uses destination policy routing, independent of mwan3
	# packet marks. These are base values; each selected node receives +index.
	NAIVE_EGRESS_TABLE=$(config_t_get global naive_egress_table 20200)
	NAIVE_EGRESS_RULE_PRIORITY=$(config_t_get global naive_egress_rule_priority 900)
	echo "$NAIVE_EGRESS_TABLE" | grep -qE '^[0-9]+$' || NAIVE_EGRESS_TABLE=20200
	echo "$NAIVE_EGRESS_RULE_PRIORITY" | grep -qE '^[0-9]+$' || NAIVE_EGRESS_RULE_PRIORITY=900

	get_direct_dns
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

# ------------------------------------------------------------------------------
# NaiveProxy protocol adapter. It exposes the selected node (HTTPS or QUIC) as
# a local SOCKS upstream; BypassCore remains the only transparent routing core.
# ------------------------------------------------------------------------------

run_naive_node() {
	local node=$1 socks_port=$2
	[ -z "$NAIVE_BIN" ] && {
		log 0 "naiveproxy binary not found (install naiveproxy or set naive_file). Transparent proxy disabled."
		NAIVE_OK=0
		return 1
	}

	local address port username password protocol auth=""
	address=$(config_n_get "$node" address)
	port=$(config_n_get "$node" port)
	username=$(config_n_get "$node" username)
	password=$(config_n_get "$node" password)
	protocol=$(config_n_get "$node" protocol https)
	case "$protocol" in
		quic) protocol="quic" ;;
		*) protocol="https" ;;
	esac
	[ -z "$address" ] || [ -z "$port" ] && { log 0 "Node [%s] has no address/port, skip naive." "$node"; return 1; }

	# IPv6 host bracketing for the proxy URL.
	local server_host=$address
	echo "$address" | grep -qE "([A-Fa-f0-9]{1,4}::?){1,7}[A-Fa-f0-9]{1,4}" && server_host="[$address]"

	local cfg_dir="${TMP_ACL_PATH}/nodes"
	mkdir -p "$cfg_dir"
	local log_file="${cfg_dir}/naive_${node}.log"
	: > "$log_file"

	local socks_cfg="${cfg_dir}/naive_${node}.json"
	json_init
	local socks_host=127.0.0.1
	[ "$NODE_SOCKS_BIND_LOCAL" = "1" ] || socks_host=0.0.0.0
	if [ -n "$username$password" ]; then
		username=$(uri_encode_userinfo "$username") || return 1
		password=$(uri_encode_userinfo "$password") || return 1
		auth="${username}:${password}@"
	fi
	json_add_string "listen" "socks://${socks_host}:${socks_port}"
	json_add_string "proxy" "${protocol}://${auth}${server_host}:${port}"
	# A destination-only policy rule cannot distinguish two processes after DNS
	# round-robin changes. Pin interface-bound nodes to an address which was
	# installed in their route table; NaiveProxy keeps the hostname for TLS/SNI.
	local pinned_ip
	pinned_ip=$(cat "$TMP_PATH/naive_resolve.${node}" 2>/dev/null)
	if [ -n "$pinned_ip" ]; then
		local resolver_target=$pinned_ip
		case "$pinned_ip" in *:*) resolver_target="[$pinned_ip]" ;; esac
		json_add_string "host-resolver-rules" "MAP ${address} ${resolver_target}"
	fi
	# An empty log target tells NaiveProxy to use stderr. ln_run already redirects
	# stdout/stderr to this node's log file, avoiding two writers opening the same
	# path independently.
	[ "$LOG_NODE" = "1" ] && json_add_string "log" ""
	json_dump > "$socks_cfg"

	# Cold boot can briefly race process exec or transient system readiness. Give
	# NaiveProxy one clean retry; a second failure still aborts startup before any
	# DNS or firewall takeover.
	local attempt=1 process_name="${NAIVE_TAG}_${node}" pid
	while [ "$attempt" -le 2 ]; do
		: > "$log_file"
		if ln_run 0 "$NAIVE_BIN" "$process_name" "$log_file" "$socks_cfg"; then
			wait_for_listener "$process_name" "$socks_port" tcp 15 "$log_file" && break
		else
			log 0 "NaiveProxy node [%s] could not create a live child process." "$node"
		fi
		[ "$attempt" = "2" ] && return 1
		pid=$(process_pid "$process_name") && {
			kill "$pid" 2>/dev/null
			sleep 1
		}
		rm -f "$TMP_PID_PATH/${process_name}.pid"
		log 0 "Retrying NaiveProxy node [%s] after an early startup failure." "$node"
		attempt=$((attempt + 1))
		sleep 2
	done

	NAIVE_OK=1
	log 0 "NaiveProxy node [%s]: socks://127.0.0.1:%s, server=%s:%s" \
		"$node" "$socks_port" "$server_host" "$port"
}

run_naive_nodes() {
	prepare_selected_nodes
	teardown_egress_routing
	[ -s "$TMP_PATH/selected_nodes" ] || {
		log 0 "No shunt rule selects a NaiveProxy node; starting BypassCore with direct/blackhole rules only."
		return 0
	}
	[ -n "$NAIVE_BIN" ] || { log 0 "naiveproxy binary not found; selected proxy rules cannot start."; return 1; }
	local naive_version
	naive_version=$("$NAIVE_BIN" --version 2>&1 | sed -n '1p')
	[ -n "$naive_version" ] && log 0 "NaiveProxy runtime: %s." "$naive_version"

	# Resolve and record each node separately. Different nodes may use different
	# logical WANs, so they receive consecutive policy tables and priorities.
	# A destination IP cannot safely belong to two different WANs because Linux
	# destination rules cannot distinguish the originating Naive process; reject
	# that ambiguous configuration instead of silently choosing one interface.
	: > "$TMP_PATH/egress_plan"
	: > "$TMP_PATH/egress_map4"
	: > "$TMP_PATH/egress_map6"
	local node address iface iface_key ipv4_file ipv6_file index=0
	while read -r node; do
		[ -n "$node" ] || continue
		iface=$(config_n_get "$node" egress_interface)
		address=$(config_n_get "$node" address)
		ipv4_file="$TMP_PATH/uplink_ips.${index}"
		ipv6_file="$TMP_PATH/uplink_ips6.${index}"
		resolve_all_ipv4 "$address" | awk 'NF && !seen[$0]++' > "$ipv4_file"
		resolve_all_ipv6 "$address" | awk 'NF && !seen[$0]++' > "$ipv6_file"
		[ -s "$ipv4_file" ] || [ -s "$ipv6_file" ] || {
			log 0 "Naive node [%s] server address [%s] could not be resolved." "$node" "$address"
			return 1
		}
		iface_key=${iface:-system-default}
		awk -v iface="$iface_key" -v node="$node" 'NF { print $1, iface, node }' "$ipv4_file" >> "$TMP_PATH/egress_map4"
		awk -v iface="$iface_key" -v node="$node" 'NF { print $1, iface, node }' "$ipv6_file" >> "$TMP_PATH/egress_map6"
		if [ -n "$iface" ]; then
			# Static resolution in NaiveProxy eliminates the race where Chromium
			# resolves a different round-robin address after policy rules are built.
			if ! grep -Fxq "$address" "$ipv4_file" "$ipv6_file" 2>/dev/null; then
				{ sed -n '1p' "$ipv4_file"; sed -n '1p' "$ipv6_file"; } | awk 'NF { print; exit }' > "$TMP_PATH/naive_resolve.${node}"
				[ -s "$TMP_PATH/naive_resolve.${node}" ] || {
					log 0 "Naive node [%s] could not select a stable address for interface [%s]." "$node" "$iface"
					return 1
				}
			fi
			printf '%s %s %s %s %s\n' "$index" "$node" "$iface" "$ipv4_file" "$ipv6_file" >> "$TMP_PATH/egress_plan"
		else
			log 0 "Naive node [%s] uses the system default route." "$node"
		fi
		index=$((index + 1))
	done < "$TMP_PATH/selected_nodes"

	local conflict
	conflict=$(
		awk 'seen[$1] && owner[$1] != $2 { print $1 " (" owner[$1] " vs " $2 ")"; exit } { seen[$1]=1; owner[$1]=$2 }' \
			"$TMP_PATH/egress_map4" "$TMP_PATH/egress_map6"
	)
	[ -z "$conflict" ] || {
		log 0 "Naive nodes resolve to the same server IP with conflicting egress selections: %s." "$conflict"
		return 1
	}

	local table priority
	while read -r index node iface ipv4_file ipv6_file; do
		[ -n "$iface" ] || continue
		table=$((NAIVE_EGRESS_TABLE + index))
		priority=$((NAIVE_EGRESS_RULE_PRIORITY + index))
		setup_egress_routing "$iface" "$table" "$priority" "$ipv4_file" "$ipv6_file" "Naive node [$node]" || {
			teardown_egress_routing
			return 1
		}
	done < "$TMP_PATH/egress_plan"

	local port
	while read -r node; do
		[ -n "$node" ] || continue
		port=$(node_socks_port "$node")
		run_naive_node "$node" "$port" || return 1
	done < "$TMP_PATH/selected_nodes"
}

# ------------------------------------------------------------------------------
# ChinaDNS-NG auxiliary Direct DNS/NFTSet writer. Only domains belonging to an
# explicitly Direct shunt rule are sent here and written to the direct NFTSet;
# BypassCore DNS is the primary resolver for every other query.
# ------------------------------------------------------------------------------

run_chinadns_ng() {
	[ -z "$CHINADNS_BIN" ] && {
		log 0 "chinadns-ng not found (install chinadns-ng or set chinadns_file). Direct/NFTSet DNS helper disabled."
		CHINADNS_OK=0
		return 1
	}
	[ -z "$DOMESTIC_DNS" ] && get_direct_dns

	local cfg_dir=$TMP_ACL_PATH
	mkdir -p "$cfg_dir"
	local config_file="${cfg_dir}/chinadns-ng.conf"
	local geoview_bin geosite_path
	geoview_bin=$(first_type "$(config_t_get global_app geoview_file /usr/bin/geoview)" geoview)
	geosite_path=$(get_geo_asset_path geosite)

	# Build the dnsmasq helper-domain list from every Direct shunt row. This is
	# the functional counterpart of Passwall2's "Direct DNS result write to
	# IPSet" option; other domains continue to use BypassCore DNS.
	local direct_shunt_path="${cfg_dir}/direct-shunt.list"
	: > "$direct_shunt_path"
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
						[ -s "$_rtmp" ] && cat "$_rtmp" >> "$direct_shunt_path"
						;;
						domain:*) echo "${_rline#*:}" >> "$direct_shunt_path" ;;
						# dnsmasq server=/domain/ is a suffix match. Converting a
						# BypassCore full: rule would incorrectly include subdomains,
						# so exact rules remain on the main BypassCore DNS path.
						full:*) ;;
					regexp:*|ext:*) ;;
					# Bare rules are BypassCore substring matches, which cannot be
					# represented by ChinaDNS-NG's domain-suffix list. Leave them to
					# BypassCore instead of broadening their meaning silently.
					*) ;;
				esac
			done <<-EOF
			$_rdomain
			EOF
		done
		[ -s "$direct_shunt_path" ] && sort -u "$direct_shunt_path" -o "$direct_shunt_path"
	fi

	# dnsmasq must send configured Direct DNS override domains to BypassCore even
	# when they also belong to a Direct shunt list. Otherwise the more general
	# ChinaDNS-NG helper route would bypass the user's per-domain DNS upstream.
	local direct_dns_main_path="${cfg_dir}/direct-dns-main.list"
	local _dd_domain _dd_upstream _dd_extra _dd_code _dd_tmp
	: > "$direct_dns_main_path"
	rm -f "${cfg_dir}/disable-direct-helper"
	while IFS=' ' read -r _dd_domain _dd_upstream _dd_extra; do
		case "$_dd_domain" in ''|'#'*) continue ;; esac
		[ -n "$_dd_upstream" ] && [ -z "$_dd_extra" ] || continue
		case "$_dd_domain" in
			geosite:*)
				_dd_code=${_dd_domain#geosite:}
				_dd_tmp="${cfg_dir}/direct-dns-${_dd_code}.txt"
				rm -f "$_dd_tmp"
				[ -n "$geoview_bin" ] && [ -s "$geosite_path" ] && \
					"$geoview_bin" -type geosite -action extract -input "$geosite_path" -list "$_dd_code" -lowmem=true -output "$_dd_tmp" >/dev/null 2>&1
				if [ -s "$_dd_tmp" ]; then
					cat "$_dd_tmp" >> "$direct_dns_main_path"
					grep -qE '^(regexp|keyword):' "$_dd_tmp" && touch "${cfg_dir}/disable-direct-helper"
				fi
				;;
			domain:*|full:*) echo "${_dd_domain#*:}" >> "$direct_dns_main_path" ;;
			regexp:*) touch "${cfg_dir}/disable-direct-helper" ;;
		esac
	done <<-EOF
	$DIRECT_DNS_SHUNT
	EOF
	[ -s "$direct_dns_main_path" ] && sort -u "$direct_dns_main_path" -o "$direct_dns_main_path"

	# Build the domain list consumed by ChinaDNS-NG. Literal node IPs are added
	# to bypass_vps directly by nftables.sh.
	[ ! -s "$cfg_dir/vpslist" ] && {
		local node_servers
		node_servers=$(uci show "${CONFIG}" 2>/dev/null | grep -E "(.address=)" | cut -d "'" -f 2)
		echo "$node_servers" | while read -r h; do host_from_url "$h"; done | grep '[a-zA-Z]$' | sort -u > "$cfg_dir/vpslist"
	}

	# Passwall2 uses this ChinaDNS-NG instance only as an auxiliary direct DNS
	# resolver/NFTSet writer. The main resolver is BypassCore DNS below.
	local direct_set_names vps_set_names
	direct_set_names="inet@bypass@bypass_direct_dns,inet@bypass@bypass_direct_dns6"
	vps_set_names="inet@bypass@bypass_vps,inet@bypass@bypass_vps6"

	local filtered_qtypes=65
	[ "$PROXY_IPV6" = "1" ] || filtered_qtypes=65,28
	local direct_set_line=""
	[ "$WRITE_IPSET_DIRECT" = "1" ] && direct_set_line="add-tagchn-ip ${direct_set_names}"
	cat <<-EOF > "$config_file"
		bind-addr 127.0.0.1
		bind-port ${CHINADNS_PORT}
		china-dns ${DOMESTIC_DNS}
		trust-dns ${DOMESTIC_DNS}
		filter-qtype ${filtered_qtypes}
		${direct_set_line}
		default-tag chn
		group vpslist
		group-dnl ${cfg_dir}/vpslist
		group-upstream ${DOMESTIC_DNS}
		group-ipset ${vps_set_names}
	EOF

	local chinadns_log="${cfg_dir}/chinadns-ng.log"
	: > "$chinadns_log"
	# "Enable Node Log" applies to NaiveProxy nodes. Passing -v to ChinaDNS-NG
	# prints every loaded/queried domain and can fill flash-backed log viewers;
	# Passwall2 discards that stream. Keep only normal diagnostics in our private
	# component log so startup failures remain inspectable without list noise.
	ln_run 0 "$CHINADNS_BIN" "$CHINADNS_TAG" "$chinadns_log" -C "$config_file" || return 1
	# Use a process-aware startup window rather than a fixed sleep.
	if wait_for_listener "$CHINADNS_TAG" "$CHINADNS_PORT" udp 20 "$chinadns_log"; then
		CHINADNS_OK=1
		log 0 "ChinaDNS-NG NFTSet helper: :%s  direct=%s." "$CHINADNS_PORT" "$DOMESTIC_DNS"
	else
		CHINADNS_OK=0
		log 1 "ChinaDNS-NG generated config: %s" "$config_file"
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
				echo ""
			fi
			;;
	esac
}

gen_bypasscore_config() {
	mkdir -p "$(dirname "$BYPASSCORE_CFG")"
	BYPASSCORE_CONFIG_ERROR=0
	prepare_selected_nodes
	DNS_PROXY_NODE=$(default_proxy_node)
	DNS_PROXY_PORT=$(node_socks_port "$DNS_PROXY_NODE")
	if [ "$REMOTE_DNS_DETOUR" = "remote" ]; then
		case "$REMOTE_DNS_PROTOCOL" in
			tcp|tls|doh) ;;
			*)
				# NaiveProxy has no SOCKS UDP ASSOCIATE. Refuse UDP here instead of
				# silently sending the resolver to the router's real WAN.
				log 0 "Remote DNS through NaiveProxy supports TCP, TLS (DoT), or DoH; protocol [%s] would require UDP and is blocked." "$REMOTE_DNS_PROTOCOL"
				BYPASSCORE_CONFIG_ERROR=1
				;;
		esac
		[ -n "$DNS_PROXY_PORT" ] || {
			log 0 "Remote DNS outbound is Remote but no Naive node is selected; service cannot provide proxied DNS."
			BYPASSCORE_CONFIG_ERROR=1
		}
	fi

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
		# A Direct shunt rule may override the global Direct interface. The bind
		# belongs to an outbound, so every override needs a dedicated freedom tag.
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

	# DNS mirrors Passwall2's direct/remote model. Every non-local BypassCore DNS
	# transport enters the routing data plane under its server tag. Explicit
	# routing rules below bind direct/domestic DNS to freedom and remote DNS to
	# either freedom or the selected NaiveProxy SOCKS outbound.
	if [ -n "$DOMESTIC_DNS" ] || [ -n "$REMOTE_DNS" ] || [ -n "$REMOTE_DNS_DOH" ]; then
		json_add_object dns
			# Domain-specific direct resolvers must never participate in the
			# fallback pool for an unrelated domain. finalQuery also makes a
			# matched policy fail closed instead of leaking to another resolver.
			json_add_array servers
				local _dns_domain _dns_upstream _dns_extra _dns_address _dns_port
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
					_dns_address=$_dns_upstream
					_dns_port=""
					# BypassCore 1.0.5 dispatches tcp:// and tls:// URL addresses to
					# its native DNS-over-TCP/DoT clients. UDP uses an address plus an
					# optional numeric port in the JSON object.
					case "$_dns_upstream" in
						tcp://*|tls://*) ;;
						*)
							_dns_address=${_dns_upstream#udp://}
							case "$_dns_address" in *#*) _dns_port=${_dns_address##*#}; _dns_address=${_dns_address%%#*} ;; esac
							case "$_dns_address" in
								\[*\]:*) _dns_port=${_dns_address##*:}; _dns_address=${_dns_address%%]*}; _dns_address=${_dns_address#?} ;;
								*:*:*) ;;
								*:*) [ -n "$_dns_port" ] || { _dns_port=${_dns_address##*:}; _dns_address=${_dns_address%:*}; } ;;
							esac
							;;
					esac
					if [ -n "$_dns_port" ] && { ! echo "$_dns_port" | grep -qE '^[0-9]+$' ||
					   [ "$_dns_port" -lt 1 ] 2>/dev/null || [ "$_dns_port" -gt 65535 ] 2>/dev/null; }; then
						log 0 "Invalid DNS port in Direct domain DNS routing entry [%s]." "$_dns_upstream"
						BYPASSCORE_CONFIG_ERROR=1
						continue
					fi
					json_add_object ''
						json_add_string address "$_dns_address"
						[ -n "$_dns_port" ] && json_add_int port "$_dns_port"
						json_add_string tag direct_dns
						json_add_boolean skipFallback 1
						json_add_boolean finalQuery 1
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
						json_add_boolean skipFallback 1
						json_add_boolean finalQuery 1
						json_add_string queryStrategy "$DIRECT_DNS_QUERY_STRATEGY"
						json_add_array domains
							local _sd
							for _sd in $(echo "$DNS_SPLIT_DOMAIN" | tr '\n' ' '); do [ -n "$_sd" ] && json_add_string '' "$_sd"; done
						json_close_array
					json_close_object
				fi
				if [ -n "$REMOTE_DNS" ] || [ -n "$REMOTE_DNS_DOH" ]; then
					json_add_object ''
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
			local sid tag domains ips net outbound egress default_sid default_outbound default_tag protocols inbound sources ports
			default_sid=""
			# Pre-scan: find the reserved Default rule and resolve its outbound tag
			# so that non-default rules with outbound=_default can inherit it.
			for sid in $(uci -q show "${CONFIG}" 2>/dev/null | grep "=shunt_rules" | cut -d '.' -f2 | cut -d '=' -f1); do
				[ "$(config_n_get "$sid" is_default 0)" = "1" ] || continue
				default_sid=$sid
				default_outbound=$(config_n_get "$sid" outbound _direct)
				egress=$(config_n_get "$sid" egress_interface)
				if [ "$default_outbound" = "_direct" ] && [ -n "$egress" ]; then
					default_tag="direct_${default_sid}"
				elif [ "$default_outbound" = "_default" ]; then
					# The Default rule itself must not reference _default; treat as direct.
					default_tag="direct"
				elif [ -n "$default_outbound" ]; then
					default_tag=$(map_outbound_tag "$default_outbound")
					[ -n "$default_tag" ] || {
						log 0 "Default shunt rule references an invalid outbound [%s]." "$default_outbound"
						BYPASSCORE_CONFIG_ERROR=1
						default_tag=block
					}
				else
					default_tag="direct"
				fi
				break
			done
			[ -n "$default_tag" ] || default_tag="direct"
			# DNS server tags become inboundTag values while BypassCore dials the
			# configured upstream. Put these rules before traffic shunt rules so
			# resolver endpoints cannot accidentally inherit a user traffic rule.
			json_add_object ''
				json_add_string outboundTag direct
				json_add_array inboundTag
					json_add_string '' direct_dns
					json_add_string '' domestic
				json_close_array
			json_close_object
			json_add_object ''
				if [ "$REMOTE_DNS_DETOUR" = "remote" ] && [ -n "$DNS_PROXY_NODE" ]; then
					json_add_string outboundTag "proxy_${DNS_PROXY_NODE}"
				else
					json_add_string outboundTag direct
				fi
				json_add_array inboundTag
					json_add_string '' remote
				json_close_array
			json_close_object
			for sid in $(uci -q show "${CONFIG}" 2>/dev/null | grep "=shunt_rules" | cut -d '.' -f2 | cut -d '=' -f1); do
				[ "$(config_n_get "$sid" is_default 0)" = "1" ] && continue
				outbound=$(config_n_get "$sid" outbound _direct)
				[ -n "$outbound" ] || continue
				egress=$(config_n_get "$sid" egress_interface)
				if [ "$outbound" = "_default" ]; then
					# Inherit the Default rule's resolved outbound exactly.
					tag=$default_tag
				elif [ "$outbound" = "_direct" ] && [ -n "$egress" ]; then
					tag="direct_${sid}"
				else
					tag=$(map_outbound_tag "$outbound")
				fi
				[ -n "$tag" ] || {
					log 0 "Shunt rule [%s] references an invalid outbound [%s]." "$sid" "$outbound"
					BYPASSCORE_CONFIG_ERROR=1
					tag=block
				}
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
					protocols=$(config_n_get "$sid" protocol)
					if [ -n "$protocols" ]; then
						json_add_array protocol
						local p
						for p in $protocols; do json_add_string '' "$p"; done
						json_close_array
					fi
					inbound=$(config_n_get "$sid" inbound)
					case " $inbound " in
						*" tproxy "*)
							json_add_array inboundTag
							json_add_string '' tcp_redir
							[ "$PROXY_IPV6" = "1" ] && json_add_string '' ipv6_tproxy
							json_close_array
							;;
					esac
					sources=$(config_n_get "$sid" source)
					if [ -n "$sources" ]; then
						json_add_array source
						local src
						for src in $sources; do json_add_string '' "$src"; done
						json_close_array
					fi
					ports=$(config_n_get "$sid" port)
					[ -n "$ports" ] && json_add_string port "$ports"
				json_close_object
			done
			# The reserved Default row is emitted last as the catch-all, reusing
			# the default_tag resolved above (so _default rules and the catch-all
			# share one source of truth).
			json_add_object ''
				json_add_string outboundTag "$default_tag"
				json_add_string network "$(config_n_get "$default_sid" network tcp,udp)"
			json_close_object
		json_close_array
	json_close_object

	# observatory (only useful if the bypasscore binary is present)
	if is_bypasscore "$BYPASSCORE_FILE"; then
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
			json_add_string tag "dns-in"
			json_add_string type "dns"
			json_add_string listen "127.0.0.1"
			json_add_int port "$BYPASSCORE_DNS_PORT"
			json_add_string network "tcp,udp"
		json_close_object
		json_add_object ''
			json_add_string tag "tcp_redir"
			json_add_string type "$in_type"
			# Bind every interface, not just loopback. nftables "redirect to :PORT"
			# rewrites forwarded LAN traffic to the ingress interface's IP (e.g.
			# 192.168.12.1), so a 127.0.0.1-only listener would miss it. This mirrors
			# passwall2's xray/sing-box inbounds (0.0.0.0 / "::"). fw4's default WAN
			# INPUT DROP keeps the port unreachable from the internet.
			json_add_string listen "0.0.0.0"
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
	if ! is_bypasscore "$BYPASSCORE_FILE"; then
		log 0 "BypassCore is missing, not executable, or does not identify as BypassCore; service cannot start."
		return 1
	fi
	gen_bypasscore_config || return 1
	local cfg_dir=$TMP_ACL_PATH
	mkdir -p "$cfg_dir"
	# Starting a separate -test process here used to load GeoData, DNS, routing
	# and Observatory twice. The daemon performs the same validation before it
	# opens the listener, and wait_for_listener reports its captured error output.
	local log_file="${cfg_dir}/bypasscore.log"
	: > "$log_file"
	ln_run 0 "$BYPASSCORE_FILE" "bypasscore" "$log_file" -config "$BYPASSCORE_CFG" -log-level "$LOG_LEVEL" -run || return 1
	wait_for_listener bypasscore "$REDIR_PORT" tcp 20 "$log_file" || return 1
	wait_for_listener bypasscore "$BYPASSCORE_DNS_PORT" udp 5 "$log_file" || return 1
	wait_for_listener bypasscore "$BYPASSCORE_DNS_PORT" tcp 5 "$log_file" || return 1
	set_cache_var ACL_GLOBAL_redir_port "$REDIR_PORT"
	set_cache_var BYPASSCORE_DNS_PORT "$BYPASSCORE_DNS_PORT"
	log 0 "BypassCore running as transparent core on tcp://0.0.0.0:%s (-run)." "$REDIR_PORT"
	if [ "$REMOTE_DNS_DETOUR" = "remote" ]; then
		log 0 "Remote DNS: %s (%s) -> BypassCore DNS :%s -> Naive node [%s] SOCKS :%s." \
			"$([ "$REMOTE_DNS_PROTOCOL" = "doh" ] && echo "$REMOTE_DNS_DOH" || echo "$REMOTE_DNS")" \
			"$REMOTE_DNS_PROTOCOL" "$BYPASSCORE_DNS_PORT" "$DNS_PROXY_NODE" "$DNS_PROXY_PORT"
	else
		log 0 "Remote DNS: %s (%s) -> BypassCore DNS :%s -> Direct." \
			"$([ "$REMOTE_DNS_PROTOCOL" = "doh" ] && echo "$REMOTE_DNS_DOH" || echo "$REMOTE_DNS")" \
			"$REMOTE_DNS_PROTOCOL" "$BYPASSCORE_DNS_PORT"
	fi
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
# dnsmasq integration: use BypassCore DNS as the default resolver and route
# only Direct/NFTSet helper domains to ChinaDNS-NG, matching Passwall2's split
# between TUN_DNS and run_ipset_chinadns_ng.
# ------------------------------------------------------------------------------

append_dnsmasq_helper_domains() {
	local input=$1 output=$2 port=$3 allow_full=${4:-0}
	[ -s "$input" ] || return 0
	awk -v port="$port" -v allow_full="$allow_full" '
		{
			d = $1
			sub(/\r$/, "", d)
			if (d ~ /^(regexp|keyword):/) next
			if (!allow_full && d ~ /^full:/) next
			sub(/^domain:/, "", d)
			sub(/^full:/, "", d)
			sub(/^\./, "", d)
			if (d != "" && d !~ /^#/ && d ~ /^[A-Za-z0-9_.-]+$/)
				print "server=/" d "/127.0.0.1#" port
		}
	' "$input" >> "$output"
}

run_dnsmasq_forward() {
	[ "$CHINADNS_OK" != "1" ] && return 0
	[ "$(check_port_exists "$BYPASSCORE_DNS_PORT" udp)" -gt 0 ] 2>/dev/null && \
		[ "$(check_port_exists "$BYPASSCORE_DNS_PORT" tcp)" -gt 0 ] 2>/dev/null || {
		log 0 "BypassCore DNS is not listening on TCP/UDP :%s; leave dnsmasq unchanged." "$BYPASSCORE_DNS_PORT"
		return 1
	}
	[ "$(check_port_exists "$CHINADNS_PORT" udp)" -gt 0 ] 2>/dev/null || {
		log 0 "ChinaDNS-NG NFTSet helper is not listening on :%s; leave dnsmasq unchanged." "$CHINADNS_PORT"
		return 1
	}
	[ "$DNS_REDIRECT" = "1" ] || {
		log 0 "dnsmasq forwarding is disabled; BypassCore DNS :%s and ChinaDNS-NG helper :%s remain local-only." "$BYPASSCORE_DNS_PORT" "$CHINADNS_PORT"
		return 0
	}
	# Use dnsmasq's generated runtime conf-dir instead of committing changes to
	# /etc/config/dhcp. A power loss must not leave persistent DNS pointing to a
	# ChinaDNS process which no longer exists after reboot.
	local cfgid generated conf_dir include_file custom_conf_dir dnsmasq_bin dnsmasq_test_log
	cfgid=$(uci -q show 'dhcp.@dnsmasq[0]' 2>/dev/null | awk 'NR == 1 { split($0, a, /[.=]/); print a[2] }')
	generated="/tmp/etc/dnsmasq.conf.${cfgid}"
	conf_dir=$(awk -F= '/^conf-dir=/ { print $2; exit }' "$generated" 2>/dev/null)
	conf_dir=${conf_dir%%,*}
	conf_dir=${conf_dir%*/}
	if [ -z "$conf_dir" ]; then
		custom_conf_dir=$(uci -q get 'dhcp.@dnsmasq[0].confdir' 2>/dev/null)
		case "$custom_conf_dir" in /*) conf_dir=${custom_conf_dir%%,*} ;; esac
	fi
	[ -n "$conf_dir" ] || [ -z "$cfgid" ] || [ ! -d "/tmp/dnsmasq.${cfgid}.d" ] || conf_dir="/tmp/dnsmasq.${cfgid}.d"
	[ -n "$conf_dir" ] || [ ! -d /tmp/dnsmasq.d ] || conf_dir=/tmp/dnsmasq.d
	[ -n "$conf_dir" ] || {
		log 0 "Could not locate the active dnsmasq runtime conf-dir; leave dnsmasq unchanged."
		return 1
	}
	mkdir -p "$conf_dir" || return 1
	include_file="${conf_dir}/dnsmasq-bypass.conf"
	cat <<-EOF > "$include_file"
		server=/#/127.0.0.1#${BYPASSCORE_DNS_PORT}
		no-resolv
	EOF
	# These queries use direct DNS and populate compatibility/diagnostic NFTSets.
	# Traffic decisions remain inside BypassCore; resolving an IP is not enough
	# to bypass ordered rules safely because CDN hostnames can share an address.
	if [ "$WRITE_IPSET_DIRECT" = "1" ] && [ ! -f "$TMP_ACL_PATH/disable-direct-helper" ]; then
		append_dnsmasq_helper_domains "$TMP_ACL_PATH/direct-shunt.list" "$include_file" "$CHINADNS_PORT"
	elif [ -f "$TMP_ACL_PATH/disable-direct-helper" ]; then
		log 0 "Direct DNS override contains regexp/keyword semantics; Direct helper routing is disabled so BypassCore remains authoritative."
	fi
	append_dnsmasq_helper_domains "$TMP_ACL_PATH/vpslist" "$include_file" "$CHINADNS_PORT"
	local direct_dns_main_effective="$TMP_ACL_PATH/direct-dns-main.effective.list"
	if [ -s "$TMP_ACL_PATH/direct-dns-main.list" ]; then
		# Node server domains must keep using the helper so bypass_vps is populated
		# before transparent redirection. Do not let an overlapping per-domain DNS
		# override disable the loop-prevention set.
		if [ -s "$TMP_ACL_PATH/vpslist" ]; then
			awk 'NR == FNR { vps[$1] = 1; next } !vps[$1] { print }' \
				"$TMP_ACL_PATH/vpslist" "$TMP_ACL_PATH/direct-dns-main.list" > "$direct_dns_main_effective"
		else
			cp -f "$TMP_ACL_PATH/direct-dns-main.list" "$direct_dns_main_effective"
		fi
	else
		: > "$direct_dns_main_effective"
	fi
	# Append these last so an equal-specificity Direct helper rule does not mask
	# a user-configured per-domain DNS upstream handled by BypassCore.
	if [ -s "$direct_dns_main_effective" ]; then
		awk -v helper_port="$CHINADNS_PORT" '
			function within(child, parent) {
				return child == parent || (length(child) > length(parent) && substr(child, length(child) - length(parent)) == "." parent)
			}
			NR == FNR {
				d = $1
				sub(/\r$/, "", d); sub(/^domain:/, "", d); sub(/^full:/, "", d); sub(/^\./, "", d)
				if (d ~ /^[A-Za-z0-9_.-]+$/) main[++main_count] = d
				next
			}
			{
				d = $0
				if (d ~ /^server=\// && index(d, "/127.0.0.1#" helper_port) > 0) {
					sub(/^server=\//, "", d)
					sub(/\/127\.0\.0\.1#[0-9]+$/, "", d)
					for (i = 1; i <= main_count; i++) if (within(d, main[i])) next
				}
				print
			}
		' "$direct_dns_main_effective" "$include_file" > "${include_file}.tmp" && \
			mv -f "${include_file}.tmp" "$include_file"
	fi
	append_dnsmasq_helper_domains "$direct_dns_main_effective" "$include_file" "$BYPASSCORE_DNS_PORT" 1
	awk '!seen[$0]++' "$include_file" > "${include_file}.tmp" && mv -f "${include_file}.tmp" "$include_file"
	dnsmasq_bin=$(first_type /usr/sbin/dnsmasq dnsmasq)
	if [ -n "$dnsmasq_bin" ] && [ -r "$generated" ]; then
		dnsmasq_test_log="${TMP_ACL_PATH}/dnsmasq-test.log"
		if ! "$dnsmasq_bin" --test --conf-file="$generated" > "$dnsmasq_test_log" 2>&1; then
			rm -f "$include_file"
			log 0 "dnsmasq rejected the Bypass runtime forwarding file."
			log_component_tail dnsmasq "$dnsmasq_test_log"
			return 1
		fi
	fi
	set_cache_var DNSMASQ_INCLUDE "$include_file"
	set_cache_var DNSMASQ_MODIFIED 1
	if ! /etc/init.d/dnsmasq restart >/dev/null 2>&1; then
		rm -f "$include_file"
		unset_cache_var DNSMASQ_INCLUDE
		unset_cache_var DNSMASQ_MODIFIED
		log 0 "dnsmasq failed to reload the Bypass runtime forwarding file."
		return 1
	fi
	log 0 "dnsmasq default DNS -> BypassCore :%s; Direct/NFTSet domains -> ChinaDNS-NG :%s." "$BYPASSCORE_DNS_PORT" "$CHINADNS_PORT"
}

restore_dnsmasq_forward() {
	[ "$(get_cache_var DNSMASQ_MODIFIED)" = "1" ] || return 0
	local include_file
	include_file=$(get_cache_var DNSMASQ_INCLUDE)
	[ -n "$include_file" ] && rm -f "$include_file"
	/etc/init.d/dnsmasq restart >/dev/null 2>&1
	unset_cache_var DNSMASQ_INCLUDE
	unset_cache_var DNSMASQ_MODIFIED
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
	# Restarts must replace, not append, the jobs owned by this package.
	sed -i "/${APP_PATH//\//\\/}\/rule_update\.sh/d; /\/etc\/init\.d\/bypass /d" /etc/crontabs/root 2>/dev/null
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
	# Re-check interface-bound Naive destinations every hour. The helper only
	# restarts when the address pinned at startup has actually left DNS, unlike
	# the old unconditional hourly stop/start.
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

validate_runtime() {
	wait_for_listener bypasscore "$REDIR_PORT" tcp 3 "$TMP_ACL_PATH/bypasscore.log" || return 1
	wait_for_listener bypasscore "$BYPASSCORE_DNS_PORT" udp 3 "$TMP_ACL_PATH/bypasscore.log" || return 1
	wait_for_listener bypasscore "$BYPASSCORE_DNS_PORT" tcp 3 "$TMP_ACL_PATH/bypasscore.log" || return 1
	local node port
	while read -r node port; do
		[ -n "$node" ] && [ -n "$port" ] || continue
		wait_for_listener "${NAIVE_TAG}_${node}" "$port" tcp 3 "$TMP_ACL_PATH/nodes/naive_${node}.log" || return 1
	done < "$TMP_PATH/node_ports"
	if [ "$DNS_REDIRECT" = "1" ]; then
		wait_for_listener "$CHINADNS_TAG" "$CHINADNS_PORT" udp 3 "$TMP_ACL_PATH/chinadns-ng.log" || return 1
	fi
}

start_monitor() {
	[ "$START_DAEMON" = "1" ] || return 0
	local monitor_log="$TMP_ACL_PATH/monitor.log"
	: > "$monitor_log"
	ln_run 0 "$APP_PATH/monitor.sh" monitor "$monitor_log" || {
		log 0 "Process monitor could not be started."
		return 1
	}
	log 0 "Process monitor started."
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
	mkdir -p /tmp/etc /tmp/log "$TMP_PATH" "$TMP_BIN_PATH" "$TMP_PID_PATH" "$TMP_ACL_PATH" "$TMP_PATH2"

	get_config
	export BYPASSCORE_ASSETS="$V2RAY_LOCATION_ASSET"
	export ENABLE_DEPRECATED_GEOSITE=true
	export ENABLE_DEPRECATED_GEOIP=true
	ulimit -n 65535 2>/dev/null

	NAIVE_OK=0
	CHINADNS_OK=0

	# If the service is disabled, do nothing — especially do NOT install the
	# nftables REDIRECT ruleset (it would send all TCP to a dead REDIR_PORT and
	# blackhole the router's own WAN). Bail out early and cleanly.
	[ "$ENABLED" = "1" ] || {
		log 0 "Bypass is disabled (enabled=0). Skipping start."
		echolog ""
		return 0
	}
	check_run_environment || return 1
	if ! is_bypasscore "$BYPASSCORE_FILE"; then
		log 0 "BypassCore is required but unavailable at [%s]; service not started." "$BYPASSCORE_FILE"
		return 1
	fi
	if ! bypasscore_has_raw_dns "$BYPASSCORE_FILE"; then
		log 0 "BypassCore v1.0.8 or later is required for complete DNS forwarding; service not started."
		return 1
	fi
	prepare_selected_nodes
	run_naive_nodes || { stop; return 1; }
	run_bypasscore_core || { stop; return 1; }
	if ! run_chinadns_ng && [ "$DNS_REDIRECT" = "1" ]; then
		log 0 "DNS Redirect is enabled but ChinaDNS-NG is unavailable; refusing to start with an incomplete DNS path."
		stop
		return 1
	fi

	# ChinaDNS-NG may spend several seconds loading geosite data. Revalidate all
	# earlier components before installing firewall redirection so a process
	# which died during that interval is identified by name and log output.
	if ! validate_runtime; then
		log 0 "A required process failed its final health check; firewall and DNS were not modified."
		stop
		return 1
	fi
	if ! source "$APP_PATH/${USE_TABLES}.sh" start; then
		log 0 "Firewall setup failed; stopping managed processes and leaving DNS unchanged."
		stop
		return 1
	fi
	set_cache_var USE_TABLES "$USE_TABLES"
	# Only hand dnsmasq to BypassCore DNS and the ChinaDNS-NG helper after both
	# listeners are healthy and the NFTSets used by ChinaDNS-NG exist.
	if ! run_dnsmasq_forward; then
		log 0 "dnsmasq integration failed; stopping to avoid an incomplete DNS path."
		stop
		return 1
	fi

	# Bridge-nf call disable so iptables sees bridged traffic cleanly.
	if [ "$NAIVE_OK" = "1" ]; then
		local bnf
		bnf=$(sysctl -e -n net.bridge.bridge-nf-call-iptables 2>/dev/null)
		[ -n "$bnf" ] && set_cache_var bak_bridge_nf_ipt "$bnf"
		sysctl -w net.bridge.bridge-nf-call-iptables=0 >/dev/null 2>&1
	fi

	start_crontab
	start_monitor || {
		log 0 "Required process supervision is unavailable; stopping instead of leaving an unmonitored redirect path."
		stop
		return 1
	}
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

	# Stop only processes whose PIDs were recorded by this service. This avoids
	# broad pgrep patterns and gives children a chance to flush/close first.
	stop_managed_processes
	# One-time compatibility cleanup for processes launched by versions before
	# PID tracking was introduced.
	busybox pgrep -af "$TMP_BIN_PATH/" 2>/dev/null | awk '!/app\.sh|rule_update|api\.sh|ujail/{print $1}' | xargs -r kill -9 >/dev/null 2>&1

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
