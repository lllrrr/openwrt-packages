#!/bin/sh
# Copyright (c) 2026 Eugene Chan
# SPDX-License-Identifier: MIT
#
# Orchestrator for luci-app-bypass. Read UCI, run the naiveproxy carrier,
# generate BypassCore's routing, native DNS and DNS-result NFTSet configuration,
# install the transparent-proxy firewall ruleset, and manage the lifecycle.
# Mirrors openwrt-passwall2/app.sh but in pure shell.

. /lib/functions.sh
. /usr/share/libubox/jshn.sh
. ${APP_PATH:-/usr/share/bypass}/utils.sh

NAIVE_TAG=naive

# ------------------------------------------------------------------------------
# Config snapshot
# ------------------------------------------------------------------------------

get_direct_dns() {
	local DOMESTIC ISP_DNS
	ISP_DNS=$(get_direct_dns_ipv4)
	DOMESTIC=$(config_t_get global_dns domestic_dns auto)
	case "$DOMESTIC" in
		""|auto)
			DOMESTIC_DNS=$(printf '%s' "$ISP_DNS" | tr ' ' '\n' | head -2 | tr '\n' ',' | sed 's/,$//')
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
	# Passwall2-style virtual catch-all and inherited Naive node interface.
	# Neither setting is stored on a shunt_rules/node section when inherited.
	DEFAULT_NODE=$(config_t_get global_rules default_node _direct)
	DEFAULT_NAIVE_EGRESS_IFACE=$(config_t_get global_rules default_naive_interface)

	# Reuse the active runtime ports when API helpers source this file. Without
	# this, merely opening a status/preview page while the service is running
	# would select a different free port and overwrite the live config preview.
	REDIR_PORT=$(get_cache_var ACL_GLOBAL_redir_port)
	[ -n "$REDIR_PORT" ] || REDIR_PORT=$(get_new_port 1041 tcp)
	TCP_PROXY_WAY=$(config_t_get global_forwarding tcp_proxy_way redirect)
	TCP_NO_REDIR_PORTS=$(config_t_get global_forwarding tcp_no_redir_ports 'disable')
	UDP_NO_REDIR_PORTS=$(config_t_get global_forwarding udp_no_redir_ports 'disable')
	TCP_REDIR_PORTS=$(config_t_get global_forwarding tcp_redir_ports '1:65535')
	PROXY_IPV6=$(config_t_get global_forwarding ipv6_tproxy 0)
	ACCEPT_ICMP=$(config_t_get global_forwarding accept_icmp 0)

	# Left empty on purpose: when the Default node is WireGuard, the remote
	# resolver is derived from that node's Local DNS (the resolver its tunnel
	# egress is known to reach). The 1.1.1.1 fallback lives in
	# gen_bypasscore_config, where the Default node type is known.
	REMOTE_DNS=$(config_t_get global_dns remote_dns)
	REMOTE_DNS_PROTOCOL=$(config_t_get global_dns remote_dns_protocol tcp)
	REMOTE_DNS_DOH=$(config_t_get global_dns remote_dns_doh https://1.1.1.1/dns-query)
	REMOTE_DNS_CLIENT_IP=$(config_t_get global_dns remote_dns_client_ip)
	REMOTE_DNS_DETOUR=$(config_t_get global_dns remote_dns_detour remote)
	DIRECT_DNS_QUERY_STRATEGY=$(config_t_get global_dns direct_dns_query_strategy UseIP)
	REMOTE_DNS_QUERY_STRATEGY=$(config_t_get global_dns remote_dns_query_strategy UseIPv4)
	DIRECT_DNS_SHUNT=$(config_t_get global_dns direct_dns_shunt)
	DNS_HOSTS=$(config_t_get global_dns dns_hosts)
	# BypassCore's native DNS listener is dnsmasq's main upstream. Reuse the live
	# port for status/config previews; select a free TCP+UDP port only when there
	# is no active runtime value.
	BYPASSCORE_DNS_PORT=$(get_cache_var BYPASSCORE_DNS_PORT)
	if [ -z "$BYPASSCORE_DNS_PORT" ]; then
		BYPASSCORE_DNS_PORT=$(config_t_get global_dns bypasscore_dns_listen_port 10554)
		echo "$BYPASSCORE_DNS_PORT" | grep -qE '^[0-9]+$' || BYPASSCORE_DNS_PORT=10554
		[ "$BYPASSCORE_DNS_PORT" -ge 1 ] 2>/dev/null && [ "$BYPASSCORE_DNS_PORT" -le 65535 ] 2>/dev/null || BYPASSCORE_DNS_PORT=10554
		while [ "$BYPASSCORE_DNS_PORT" = "$REDIR_PORT" ] || \
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

# Return a node's explicit interface. NaiveProxy nodes inherit the global
# default Naive interface; WireGuard nodes intentionally fall back to the
# system route because that default is protocol-specific.
node_egress_interface() {
	local iface
	iface=$(config_n_get "$1" egress_interface)
	if [ -z "$iface" ] && [ "$(node_type "$1")" = "naiveproxy" ]; then
		iface=$DEFAULT_NAIVE_EGRESS_IFACE
	fi
	printf '%s\n' "$iface"
}

# Return the node protocol family. Configurations created before the Type field
# existed remain NaiveProxy nodes.
node_type() {
	case "$(config_n_get "$1" node_type naiveproxy)" in
		wireguard) echo wireguard ;;
		*) echo naiveproxy ;;
	esac
}

# Build the unique list of nodes referenced by shunt rules and by the virtual
# Default row, plus protocol-specific subsets used by the process adapter and
# the native WireGuard outbound.
prepare_selected_nodes() {
	mkdir -p "$TMP_PATH"
	local sid outbound index=0 port
	: > "$TMP_PATH/selected_nodes"
	: > "$TMP_PATH/selected_naive_nodes"
	: > "$TMP_PATH/selected_wireguard_nodes"
	{
		for sid in $(shunt_rule_sections); do
			[ "$(config_n_get "$sid" is_default 0)" = "1" ] && continue
			outbound=$(config_n_get "$sid" outbound)
			[ "$(config_get_type "$outbound")" = "nodes" ] && echo "$outbound"
		done
		[ "$(config_get_type "$DEFAULT_NODE")" = "nodes" ] && echo "$DEFAULT_NODE"
	} | awk 'NF && !seen[$0]++' > "$TMP_PATH/selected_nodes"
	while IFS= read -r sid; do
		[ -n "$sid" ] || continue
		case "$(node_type "$sid")" in
			wireguard) printf '%s\n' "$sid" >> "$TMP_PATH/selected_wireguard_nodes" ;;
			*) printf '%s\n' "$sid" >> "$TMP_PATH/selected_naive_nodes" ;;
		esac
	done < "$TMP_PATH/selected_nodes"

	# Keep mappings stable while the same Naive node set is already represented
	# by either the active core or its carrier processes. During startup the
	# carriers deliberately bind their ports before BypassCore's config is
	# generated; recomputing at that point would see 1088 as occupied and write
	# 1089 into the core config even though Naive is listening on 1088.
	if [ -s "$TMP_PATH/node_ports" ]; then
		local mapped_nodes selected_naive mapping_live=0 mapped_node
		mapped_nodes=$(awk 'NF { print $1 }' "$TMP_PATH/node_ports" 2>/dev/null | sort -u)
		selected_naive=$(sort -u "$TMP_PATH/selected_naive_nodes" 2>/dev/null)
		if [ "$mapped_nodes" = "$selected_naive" ]; then
			process_alive bypasscore && mapping_live=1
			if [ "$mapping_live" = "0" ]; then
				while IFS= read -r mapped_node; do
					[ -n "$mapped_node" ] || continue
					process_alive "${NAIVE_TAG}_${mapped_node}" && {
						mapping_live=1
						break
					}
				done <<-EOF
				$mapped_nodes
				EOF
			fi
			[ "$mapping_live" = "1" ] && return 0
		fi
	fi
	: > "$TMP_PATH/node_ports"
	while read -r sid; do
		[ -n "$sid" ] || continue
		port=$(get_new_port $((NODE_SOCKS_PORT + index)) tcp)
		printf '%s %s\n' "$sid" "$port" >> "$TMP_PATH/node_ports"
		index=$((index + 1))
	done < "$TMP_PATH/selected_naive_nodes"
}

node_socks_port() {
	awk -v node="$1" '$1 == node { print $2; exit }' "$TMP_PATH/node_ports" 2>/dev/null
}

default_proxy_node() {
	[ "$(config_get_type "$DEFAULT_NODE")" = "nodes" ] && { echo "$DEFAULT_NODE"; return; }
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
	local server_host
	server_host=$(host_for_url "$address")

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
		log 0 "No active rule selects an outbound node."
		return 0
	}
	if [ -s "$TMP_PATH/selected_naive_nodes" ]; then
		[ -n "$NAIVE_BIN" ] || { log 0 "naiveproxy binary not found; selected proxy rules cannot start."; return 1; }
		local naive_version
		naive_version=$("$NAIVE_BIN" --version 2>&1 | sed -n '1p')
		[ -n "$naive_version" ] && log 0 "NaiveProxy runtime: %s." "$naive_version"
	fi

	# Resolve and record each node separately. Different nodes may use different
	# logical WANs, so they receive consecutive policy tables and priorities.
	# A destination IP cannot safely belong to two different WANs because Linux
	# destination rules cannot distinguish the originating process; reject that
	# ambiguous configuration instead of silently choosing one interface.
	: > "$TMP_PATH/egress_plan"
	: > "$TMP_PATH/egress_map4"
	: > "$TMP_PATH/egress_map6"
	local node address iface iface_key ipv4_file ipv6_file node_kind index=0
	while read -r node; do
		[ -n "$node" ] || continue
		if [ "$(node_type "$node")" = "wireguard" ]; then
			node_kind=WireGuard
			address=$(config_n_get "$node" peer_address)
		else
			node_kind=Naive
			address=$(config_n_get "$node" address)
		fi
		iface=$(node_egress_interface "$node")
		ipv4_file="$TMP_PATH/uplink_ips.${index}"
		ipv6_file="$TMP_PATH/uplink_ips6.${index}"
		resolve_all_ipv4 "$address" | awk 'NF' | sort -u > "$ipv4_file"
		resolve_all_ipv6 "$address" | awk 'NF' | sort -u > "$ipv6_file"
		[ -s "$ipv4_file" ] || [ -s "$ipv6_file" ] || {
			log 0 "%s node [%s] endpoint address [%s] could not be resolved." "$node_kind" "$node" "$address"
			return 1
		}
		iface_key=${iface:-system-default}
		awk -v iface="$iface_key" -v node="$node" 'NF { print $1, iface, node }' "$ipv4_file" >> "$TMP_PATH/egress_map4"
		awk -v iface="$iface_key" -v node="$node" 'NF { print $1, iface, node }' "$ipv6_file" >> "$TMP_PATH/egress_map6"
		if [ -n "$iface" ]; then
			# Static resolution in NaiveProxy eliminates the race where Chromium
			# resolves a different round-robin address after policy rules are built.
			if [ "$node_kind" = "Naive" ] && ! grep -Fxq "$address" "$ipv4_file" "$ipv6_file" 2>/dev/null; then
				{ sed -n '1p' "$ipv4_file"; sed -n '1p' "$ipv6_file"; } | awk 'NF { print; exit }' > "$TMP_PATH/naive_resolve.${node}"
				[ -s "$TMP_PATH/naive_resolve.${node}" ] || {
					log 0 "Naive node [%s] could not select a stable address for interface [%s]." "$node" "$iface"
					return 1
				}
			fi
			printf '%s %s %s %s %s\n' "$index" "$node" "$iface" "$ipv4_file" "$ipv6_file" >> "$TMP_PATH/egress_plan"
		else
			log 0 "%s node [%s] uses the system default route." "$node_kind" "$node"
		fi
		index=$((index + 1))
	done < "$TMP_PATH/selected_nodes"

	local conflict
	conflict=$(
		awk 'seen[$1] && owner[$1] != $2 { print $1 " (" owner[$1] " vs " $2 ")"; exit } { seen[$1]=1; owner[$1]=$2 }' \
			"$TMP_PATH/egress_map4" "$TMP_PATH/egress_map6"
	)
	[ -z "$conflict" ] || {
		log 0 "Outbound nodes resolve to the same endpoint IP with conflicting egress selections: %s." "$conflict"
		return 1
	}

	local table priority label
	while read -r index node iface ipv4_file ipv6_file; do
		[ -n "$iface" ] || continue
		table=$((NAIVE_EGRESS_TABLE + index))
		priority=$((NAIVE_EGRESS_RULE_PRIORITY + index))
		if [ "$(node_type "$node")" = "wireguard" ]; then
			label="WireGuard node [$node]"
		else
			label="Naive node [$node]"
		fi
		setup_egress_routing "$iface" "$table" "$priority" "$ipv4_file" "$ipv6_file" "$label" || {
			teardown_egress_routing
			return 1
		}
	done < "$TMP_PATH/egress_plan"

	[ -s "$TMP_PATH/selected_naive_nodes" ] || {
		log 0 "No active rule selects a NaiveProxy node; no NaiveProxy adapter is needed."
		return 0
	}
	local port
	while read -r node; do
		[ -n "$node" ] || continue
		port=$(node_socks_port "$node")
		run_naive_node "$node" "$port" || return 1
	done < "$TMP_PATH/selected_naive_nodes"
}

# ------------------------------------------------------------------------------
# BypassCore config.json (routing/split-decision engine config).
# Generated from the same UCI shunt_rules that feed the firewall/NFTSet plane.
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

# Build domain-policy files consumed directly by BypassCore. They retain
# full/domain/geosite/regexp/keyword semantics without expanding GeoData into
# large temporary suffix lists.
prepare_native_dns_policy_lists() {
	local vps_rules="$TMP_ACL_PATH/vps-dns.rules"
	local direct_rules="$TMP_ACL_PATH/direct-shunt-dns.rules"
	local node address host sid rule
	: > "$vps_rules"
	: > "$direct_rules"
	# Node-server domains always use direct domestic DNS, whether or not an
	# active rule currently selects the node. Control-plane probes resolve node
	# domains through this policy and must stay independent of the live tunnel
	# and of the current Default selection; a WireGuard endpoint must also
	# resolve before its tunnel exists, otherwise selecting that same WireGuard
	# node for Remote DNS can recursively wait on itself.
	for node in $(uci -q show "$CONFIG" 2>/dev/null | sed -n "s/^${CONFIG}\.\([^.=]*\)=nodes$/\1/p"); do
		if [ "$(node_type "$node")" = "wireguard" ]; then
			host=$(config_n_get "$node" peer_address)
		else
			address=$(config_n_get "$node" address)
			host=$(host_from_url "$address")
		fi
		printf '%s\n' "$host" | grep -qE '^[A-Za-z0-9.-]*[A-Za-z][A-Za-z0-9.-]*$' && \
			printf 'full:%s\n' "$host" >> "$vps_rules"
	done
	if [ "$WRITE_IPSET_DIRECT" = "1" ]; then
		for sid in $(shunt_rule_sections); do
			[ "$(config_n_get "$sid" is_default 0)" = "1" ] && continue
			[ "$(config_n_get "$sid" outbound)" = "_direct" ] || continue
			while IFS= read -r rule; do
				rule=$(printf '%s' "$rule" | sed 's/\r$//;s/^[[:space:]]*//;s/[[:space:]]*$//')
				case "$rule" in ''|'#'*) continue ;; esac
				printf '%s\n' "$rule" >> "$direct_rules"
			done <<-EOF
			$(config_n_get "$sid" domain_list)
			EOF
		done
	fi
	[ -s "$vps_rules" ] && sort -u "$vps_rules" -o "$vps_rules"
	[ -s "$direct_rules" ] && sort -u "$direct_rules" -o "$direct_rules"
	VPS_DNS_RULES=$vps_rules
	DIRECT_SHUNT_DNS_RULES=$direct_rules
}

# Append one tagged direct DNS policy per configured domestic resolver. The
# last resolver is final, so failures can try the next domestic server but can
# never leak a matched policy to the remote fallback pool.
json_add_domestic_policy_servers() {
	local tag=$1 rules_file=$2 upstream count index=0 rule
	[ -s "$rules_file" ] || return 0
	count=$(printf '%s' "$DOMESTIC_DNS" | tr ',' '\n' | awk 'NF { n++ } END { print n + 0 }')
	[ "$count" -gt 0 ] 2>/dev/null || return 1
	for upstream in $(printf '%s' "$DOMESTIC_DNS" | tr ',' ' '); do
		[ -n "$upstream" ] || continue
		index=$((index + 1))
		json_add_object ''
			json_add_string address "$upstream"
			json_add_string tag "$tag"
			json_add_string outboundTag direct
			json_add_boolean skipFallback 1
			[ "$index" = "$count" ] && json_add_boolean finalQuery 1
			json_add_string queryStrategy "$DIRECT_DNS_QUERY_STRATEGY"
			json_add_array domains
				while IFS= read -r rule; do [ -n "$rule" ] && json_add_string '' "$rule"; done < "$rules_file"
			json_close_array
		json_close_object
	done
}

# Add the configured remote DNS transport fields to the current JSON object.
# Normal remote DNS and the URL-test-only direct resolver share the transport,
# but deliberately use different outbound tags.
json_add_remote_dns_transport() {
	local remote_address remote_port=""
	remote_address=${REMOTE_DNS#udp://}
	if [ "$REMOTE_DNS_PROTOCOL" = "udp" ]; then
		case "$remote_address" in
			*:*:*) ;;
			*:*) remote_port=${remote_address##*:}; remote_address=${remote_address%:*} ;;
		esac
	fi
	case "$REMOTE_DNS_PROTOCOL" in
		doh) json_add_string address "$REMOTE_DNS_DOH" ;;
		tls) json_add_string address "tls://${REMOTE_DNS#tls://}" ;;
		tcp) json_add_string address "tcp://${REMOTE_DNS#tcp://}" ;;
		*) json_add_string address "$remote_address" ;;
	esac
	[ -n "$remote_port" ] && json_add_int port "$remote_port"
}

gen_bypasscore_config() {
	mkdir -p "$(dirname "$BYPASSCORE_CFG")" "$TMP_ACL_PATH"
	BYPASSCORE_CONFIG_ERROR=0
	prepare_selected_nodes
	prepare_native_dns_policy_lists
	DNS_PROXY_NODE=$(default_proxy_node)
	DNS_PROXY_PORT=$(node_socks_port "$DNS_PROXY_NODE")
	DNS_PROXY_TYPE=$(node_type "$DNS_PROXY_NODE")
	# An explicit remote_dns always wins. When it is left empty and the Default
	# node is WireGuard, derive the remote resolver from that node's Local DNS:
	# it is the resolver the tunnel egress is known to reach, while public
	# resolvers queried through a domestic egress are blocked or poisoned.
	if [ -z "$REMOTE_DNS" ] && [ -n "$DNS_PROXY_NODE" ] && [ "$DNS_PROXY_TYPE" = "wireguard" ]; then
		case "$REMOTE_DNS_PROTOCOL" in
			udp|tcp)
				REMOTE_DNS=$(printf '%s' "$(config_n_get "$DNS_PROXY_NODE" local_dns)" | tr ',\n\r\t' ' ' | awk 'NF { print $1; exit }')
				# Local DNS is plain DNS through the tunnel; UDP is the only
				# transport a LAN resolver is guaranteed to answer.
				[ -n "$REMOTE_DNS" ] && REMOTE_DNS_PROTOCOL=udp
				;;
		esac
	fi
	[ -n "$REMOTE_DNS" ] || REMOTE_DNS=1.1.1.1
	if [ "$REMOTE_DNS_DETOUR" = "remote" ]; then
		if [ "$DNS_PROXY_TYPE" = "naiveproxy" ]; then
			case "$REMOTE_DNS_PROTOCOL" in
				tcp|tls|doh) ;;
				*)
					# NaiveProxy has no SOCKS UDP ASSOCIATE. Refuse UDP here instead
					# of silently sending the resolver to the router's real WAN.
					log 0 "Remote DNS through NaiveProxy supports TCP, TLS (DoT), or DoH; protocol [%s] would require UDP and is blocked." "$REMOTE_DNS_PROTOCOL"
					BYPASSCORE_CONFIG_ERROR=1
					;;
			esac
		fi
		[ -n "$DNS_PROXY_NODE" ] || {
			log 0 "Remote DNS outbound is Remote but no proxy node is selected."
			BYPASSCORE_CONFIG_ERROR=1
		}
	fi

	json_init
	# outbounds: direct / block / Naive SOCKS proxy / native WireGuard.
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
		local _node _node_port _node_type _wg_value _wg_mtu _wg_dns _wg_reserved _wg_oct _peer_address _peer_port _peer_endpoint _keep_alive
		while read -r _node; do
			[ -n "$_node" ] || continue
			json_add_object ''
				json_add_string tag "proxy_${_node}"
				_node_type=$(node_type "$_node")
				if [ "$_node_type" = "wireguard" ]; then
					json_add_string mode wireguard
					json_add_object wireguard
						json_add_string secretKey "$(config_n_get "$_node" secret_key)"
						[ -n "$(config_n_get "$_node" public_key)" ] && \
							json_add_string publicKey "$(config_n_get "$_node" public_key)"
						json_add_array address
							for _wg_value in $(printf '%s' "$(config_n_get "$_node" wireguard_address)" | tr ',\n\r\t' '    '); do
								[ -n "$_wg_value" ] && json_add_string '' "$_wg_value"
							done
						json_close_array
						# Local DNS (wg-quick [Interface] DNS semantics) resolves
						# through the tunnel itself: control-plane probes and domain
						# destinations prefer it over the host resolver. Emitted only
						# when configured; BypassCore >= 1.5.0 rejects unknown fields.
						_wg_dns=$(config_n_get "$_node" local_dns)
						if [ -n "$_wg_dns" ]; then
							json_add_array dns
							for _wg_value in $(printf '%s' "$_wg_dns" | tr ',\n\r\t' '    '); do
								[ -n "$_wg_value" ] && json_add_string '' "$_wg_value"
							done
							json_close_array
						fi
						# Reserved carries the 3-byte client identifier required by
						# WARP-derived providers. Accept passwall2-style decimal
						# triples or base64; emit canonical base64.
						_wg_reserved=$(config_n_get "$_node" reserved)
						if [ -n "$_wg_reserved" ]; then
							if printf '%s' "$_wg_reserved" | grep -qE '^[0-9]{1,3}(,[0-9]{1,3}){2}$'; then
								_wg_oct=$(printf '%s' "$_wg_reserved" | awk -F, \
									'$1 > 255 || $2 > 255 || $3 > 255 { exit 1 } { printf "\\%04o\\%04o\\%04o", $1, $2, $3 }') || _wg_oct=""
								if [ -n "$_wg_oct" ]; then
									_wg_reserved=$(printf '%b' "$_wg_oct" | base64)
								else
									_wg_reserved="invalid"
								fi
							else
								# wc -c output may be space-padded; compare numerically.
								[ "$(printf '%s' "$_wg_reserved" | base64 -d 2>/dev/null | wc -c)" -eq 3 ] 2>/dev/null || _wg_reserved="invalid"
							fi
							if [ "$_wg_reserved" = "invalid" ]; then
								log 0 "WireGuard node [%s] has invalid reserved (use d1,d2,d3 or base64)." "$_node"
								BYPASSCORE_CONFIG_ERROR=1
							else
								json_add_string reserved "$_wg_reserved"
							fi
						fi
						_wg_mtu=$(config_n_get "$_node" mtu 1420)
						if ! uint_in_range "$_wg_mtu" 576 65535; then
							log 0 "WireGuard node [%s] has invalid MTU [%s]." "$_node" "$_wg_mtu"
							BYPASSCORE_CONFIG_ERROR=1
							_wg_mtu=1420
						fi
						json_add_int mtu "$_wg_mtu"
						_peer_address=$(config_n_get "$_node" peer_address)
						_peer_port=$(config_n_get "$_node" peer_port)
						if [ -z "$_peer_address" ] || ! uint_in_range "$_peer_port" 1 65535; then
							log 0 "WireGuard node [%s] has an invalid endpoint address or port." "$_node"
							BYPASSCORE_CONFIG_ERROR=1
						fi
						_peer_endpoint="$(host_for_url "$_peer_address"):${_peer_port}"
						json_add_array peers
							json_add_object ''
								json_add_string publicKey "$(config_n_get "$_node" peer_public_key)"
								json_add_string endpoint "$_peer_endpoint"
								json_add_array allowedIPs
									json_add_string '' "0.0.0.0/0"
									json_add_string '' "::/0"
								json_close_array
								[ -n "$(config_n_get "$_node" pre_shared_key)" ] && \
									json_add_string preSharedKey "$(config_n_get "$_node" pre_shared_key)"
								_keep_alive=$(config_n_get "$_node" keep_alive)
								if [ -n "$_keep_alive" ]; then
									if ! uint_in_range "$_keep_alive" 0 65535; then
										log 0 "WireGuard node [%s] has invalid keepalive [%s]." "$_node" "$_keep_alive"
										BYPASSCORE_CONFIG_ERROR=1
									else
										json_add_int keepAlive "$_keep_alive"
									fi
								fi
							json_close_object
						json_close_array
					json_close_object
				else
					_node_port=$(node_socks_port "$_node")
					json_add_string mode proxy
					json_add_object upstream
						json_add_string protocol socks
						json_add_string server "127.0.0.1:${_node_port}"
						json_add_object settings
						json_close_object
					json_close_object
				fi
			json_close_object
		done < "$TMP_PATH/selected_nodes"
		# A Direct shunt rule may override the global Direct interface. The bind
		# belongs to an outbound, so every override needs a dedicated freedom tag.
		local _sid _outbound _egress
		for _sid in $(shunt_rule_sections); do
			[ "$(config_n_get "$_sid" is_default 0)" = "1" ] && continue
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

	# DNS mirrors Passwall2's direct/remote model. BypassCore routes each DNS
	# server through its explicit outboundTag, so resolver traffic cannot be
	# captured accidentally by ordinary user routing rules.
	if [ -n "$DOMESTIC_DNS" ] || [ -n "$REMOTE_DNS" ] || [ -n "$REMOTE_DNS_DOH" ]; then
		json_add_object dns
			# Domain-specific direct resolvers must never participate in the
			# fallback pool for an unrelated domain. finalQuery also makes a
			# matched policy fail closed instead of leaking to another resolver.
			json_add_array servers
				# Node-server domains always use direct domestic DNS so their
				# addresses can enter the loop-prevention NFTSets before use.
				json_add_domestic_policy_servers vps_dns "$VPS_DNS_RULES" || BYPASSCORE_CONFIG_ERROR=1
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
						json_add_string outboundTag direct
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

				# Direct shunt domains follow user DNS overrides in priority, exactly
				# preserving the old override-vs-helper precedence inside one core.
				json_add_domestic_policy_servers direct_shunt_dns "$DIRECT_SHUNT_DNS_RULES" || BYPASSCORE_CONFIG_ERROR=1

				if [ -n "$DOMESTIC_DNS" ] && [ -n "$DNS_SPLIT_DOMAIN" ]; then
					local _domestic_first
					_domestic_first=$(printf '%s' "$DOMESTIC_DNS" | tr ',' ' ' | awk '{print $1}')
					json_add_object ''
						json_add_string address "$_domestic_first"
						json_add_string tag domestic
						json_add_string outboundTag direct
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
						json_add_remote_dns_transport
						json_add_string tag remote
						if [ "$REMOTE_DNS_DETOUR" = "remote" ] && [ -n "$DNS_PROXY_NODE" ]; then
							json_add_string outboundTag "proxy_${DNS_PROXY_NODE}"
						else
							json_add_string outboundTag direct
						fi
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

	# BypassCore writes accepted A/AAAA results straight to nftables over netlink.
	# Element timeouts follow DNS TTL, removing the permanent stale entries and
	# the helper process/port previously required for this job.
	if [ -s "$VPS_DNS_RULES" ] || [ -s "$DIRECT_SHUNT_DNS_RULES" ]; then
		json_add_object dnsResultNFTSets
			json_add_int queueSize 256
			json_add_int batchSize 128
			json_add_int flushIntervalMs 25
			json_add_array policies
				if [ -s "$VPS_DNS_RULES" ]; then
					json_add_object ''
						json_add_array serverTags
							json_add_string '' vps_dns
						json_close_array
						json_add_string ipv4Set inet@bypass@bypass_vps
						json_add_string ipv6Set inet@bypass@bypass_vps6
					json_close_object
				fi
				if [ -s "$DIRECT_SHUNT_DNS_RULES" ]; then
					json_add_object ''
						json_add_array serverTags
							json_add_string '' direct_shunt_dns
						json_close_array
						json_add_string ipv4Set inet@bypass@bypass_direct_dns
						json_add_string ipv6Set inet@bypass@bypass_direct_dns6
					json_close_object
				fi
			json_close_array
		json_close_object
	fi

	# routing
	json_add_object routing
		json_add_string domainStrategy "$DOMAIN_STRATEGY"
		# Resolve the Passwall2-style virtual Default row once and express it via
		# BypassCore's native final outbound instead of a synthetic catch-all rule.
		local default_outbound default_tag
		default_outbound=${DEFAULT_NODE:-_direct}
		case "$default_outbound" in
			_default|_direct|"") default_tag="direct" ;;
			*)
				default_tag=$(map_outbound_tag "$default_outbound")
				[ -n "$default_tag" ] || {
					log 0 "Default node references an invalid outbound [%s]." "$default_outbound"
					BYPASSCORE_CONFIG_ERROR=1
					default_tag=block
				}
				;;
		esac
		json_add_string finalOutboundTag "$default_tag"
		json_add_array rules
			local sid tag domains ips net outbound egress protocols inbound sources ports
			for sid in $(shunt_rule_sections); do
				[ "$(config_n_get "$sid" is_default 0)" = "1" ] && continue
				outbound=$(config_n_get "$sid" outbound _direct)
				[ -n "$outbound" ] || continue
				egress=$(config_n_get "$sid" egress_interface)
				if [ "$outbound" = "_default" ]; then
					# Inherit the virtual Default row's resolved outbound exactly.
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
					json_add_string ruleTag "$sid"
					json_add_string outboundTag "$tag"
					domains=$(config_n_get "$sid" domain_list)
					if [ -n "$domains" ]; then
						json_add_array domain
							local d
							while IFS= read -r d; do
								d=$(printf '%s' "$d" | sed 's/\r$//;s/^[[:space:]]*//;s/[[:space:]]*$//')
								case "$d" in ''|'#'*) continue ;; esac
								json_add_string '' "$d"
							done <<-EOF
							$domains
							EOF
						json_close_array
					fi
					ips=$(config_n_get "$sid" ip_list)
					if [ -n "$ips" ]; then
						json_add_array ip
							local i
							while IFS= read -r i; do
								i=$(printf '%s' "$i" | sed 's/\r$//;s/^[[:space:]]*//;s/[[:space:]]*$//')
								case "$i" in ''|'#'*) continue ;; esac
								json_add_string '' "$i"
							done <<-EOF
							$ips
							EOF
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
							[ -s "$TMP_PATH/selected_wireguard_nodes" ] && json_add_string '' udp_tproxy
							[ "$PROXY_IPV6" = "1" ] && json_add_string '' ipv6_tproxy
							[ "$PROXY_IPV6" = "1" ] && [ -s "$TMP_PATH/selected_wireguard_nodes" ] && \
								json_add_string '' ipv6_udp_tproxy
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
		json_close_array
	json_close_object

	# Local Unix-socket control plane: readiness, diagnostics, metrics and route
	# explanation without loading a second copy of GeoData or DNS state.
	json_add_object control
		json_add_boolean enabled 1
		json_add_string socket "$BYPASSCORE_CONTROL_SOCKET"
		json_add_string mode "0600"
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

	# BypassCore owns REDIR_PORT as a transparent listener; nftables
	# REDIRECT/TPROXY sends traffic here instead of to NaiveProxy.
	# TCP follows tcp_proxy_way. When a WireGuard outbound is selected, a
	# separate UDP TPROXY listener lets rule-matched datagrams enter its userspace
	# tunnel; UDP routed to a Naive node still fails closed at SOCKS negotiation.
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
		if [ -s "$TMP_PATH/selected_wireguard_nodes" ]; then
			json_add_object ''
				json_add_string tag "udp_tproxy"
				json_add_string type "tproxy"
				json_add_string listen "0.0.0.0"
				json_add_int port "$REDIR_PORT"
				json_add_string network "udp"
				json_add_boolean sniffing 1
			json_close_object
		fi
		if [ "$PROXY_IPV6" = "1" ]; then
			json_add_object ''
				json_add_string tag "ipv6_tproxy"
				json_add_string type "tproxy"
				json_add_string listen "::1"
				json_add_int port "$REDIR_PORT"
				json_add_string network "tcp"
				json_add_boolean sniffing 1
			json_close_object
			if [ -s "$TMP_PATH/selected_wireguard_nodes" ]; then
				json_add_object ''
					json_add_string tag "ipv6_udp_tproxy"
					json_add_string type "tproxy"
					json_add_string listen "::1"
					json_add_int port "$REDIR_PORT"
					json_add_string network "udp"
					json_add_boolean sniffing 1
				json_close_object
			fi
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
	set_cache_var BYPASSCORE_CONTROL_SOCKET "$BYPASSCORE_CONTROL_SOCKET"
	log 0 "BypassCore running as transparent core on tcp://0.0.0.0:%s (-run)." "$REDIR_PORT"
	if [ "$REMOTE_DNS_DETOUR" = "remote" ]; then
		if [ "$DNS_PROXY_TYPE" = "wireguard" ]; then
			log 0 "Remote DNS: %s (%s) -> BypassCore DNS :%s -> WireGuard node [%s]." \
				"$([ "$REMOTE_DNS_PROTOCOL" = "doh" ] && echo "$REMOTE_DNS_DOH" || echo "$REMOTE_DNS")" \
				"$REMOTE_DNS_PROTOCOL" "$BYPASSCORE_DNS_PORT" "$DNS_PROXY_NODE"
		else
			log 0 "Remote DNS: %s (%s) -> BypassCore DNS :%s -> Naive node [%s] SOCKS :%s." \
				"$([ "$REMOTE_DNS_PROTOCOL" = "doh" ] && echo "$REMOTE_DNS_DOH" || echo "$REMOTE_DNS")" \
				"$REMOTE_DNS_PROTOCOL" "$BYPASSCORE_DNS_PORT" "$DNS_PROXY_NODE" "$DNS_PROXY_PORT"
		fi
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
# dnsmasq integration: one upstream to BypassCore. Domain-specific direct DNS,
# remote DNS, caching and NFTSet writes are all handled inside that process.
# ------------------------------------------------------------------------------

run_dnsmasq_forward() {
	[ "$(check_port_exists "$BYPASSCORE_DNS_PORT" udp)" -gt 0 ] 2>/dev/null && \
		[ "$(check_port_exists "$BYPASSCORE_DNS_PORT" tcp)" -gt 0 ] 2>/dev/null || {
		log 0 "BypassCore DNS is not listening on TCP/UDP :%s; leave dnsmasq unchanged." "$BYPASSCORE_DNS_PORT"
		return 1
	}
	[ "$DNS_REDIRECT" = "1" ] || {
		log 0 "dnsmasq forwarding is disabled; BypassCore DNS :%s remains local-only." "$BYPASSCORE_DNS_PORT"
		return 0
	}
	# Use dnsmasq's generated runtime conf-dir instead of committing changes to
	# /etc/config/dhcp. A power loss therefore cannot leave a persistent upstream
	# pointing to a service which has not started yet.
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
	log 0 "dnsmasq DNS -> BypassCore :%s (native domain policy and NFTSet writer)." "$BYPASSCORE_DNS_PORT"
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

remove_owned_crontab_entries() {
	local escaped_app_path
	escaped_app_path=$(printf '%s' "$APP_PATH" | sed 's/[\/&]/\\&/g')
	sed -i "/${escaped_app_path}\/rule_update\.sh/d; /\/etc\/init\.d\/bypass /d" /etc/crontabs/root 2>/dev/null
}

start_crontab() {
	# Restarts must replace, not append, the jobs owned by this package.
	remove_owned_crontab_entries
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
	remove_owned_crontab_entries
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
}

probe_bypasscore_nftsets() {
	local response
	if ! response=$(bypasscore_control_request POST /v1/dns/nftsets/probe "" 2>&1); then
		log 0 "BypassCore could not validate its DNS-result NFTSets: %s" "$response"
		return 1
	fi
	printf '%s' "$response" | grep -Eq '"ready"[[:space:]]*:[[:space:]]*true' || {
		log 0 "BypassCore DNS-result NFTSet probe returned an unhealthy state: %s" "$response"
		return 1
	}
}

start_monitor() {
	local monitor_log="$TMP_ACL_PATH/monitor.log"
	: > "$monitor_log"
	ln_run 0 "$APP_PATH/monitor.sh" monitor "$monitor_log" || {
		log 0 "Process monitor could not be started."
		return 1
	}
	if [ "$START_DAEMON" = "1" ]; then
		log 0 "Process monitor and executable update watcher started."
	else
		log 0 "Executable update watcher started; process health monitoring is disabled."
	fi
}

# Hash only state that is owned outside BypassCore's reloadable snapshot.
# When this changes, NaiveProxy, policy routes, nftables, dnsmasq or listener
# identity must be rebuilt with a full restart. DNS policy and DNS-result set
# mappings live inside BypassCore and can reload transactionally.
runtime_restart_signature() {
	local node sid outbound geo_class
	{
		printf 'enabled=%s\nnode_socks_port=%s\nnode_socks_bind_local=%s\nclient_proxy=%s\nlog_node=%s\nlog_level=%s\ndns_redirect=%s\n' \
			"$ENABLED" "$NODE_SOCKS_PORT" "$NODE_SOCKS_BIND_LOCAL" "$CLIENT_PROXY" "$LOG_NODE" "$LOG_LEVEL" "$DNS_REDIRECT"
		printf 'bypasscore=%s\nnaive=%s\negress_table=%s\negress_priority=%s\nstart_daemon=%s\n' \
			"$BYPASSCORE_FILE" "$NAIVE_BIN" "$NAIVE_EGRESS_TABLE" "$NAIVE_EGRESS_RULE_PRIORITY" "$START_DAEMON"
		uci -q show "${CONFIG}.@global_forwarding[0]"
		uci -q show "${CONFIG}.@global_delay[0]"
		printf 'update_week=%s\nupdate_time=%s\nupdate_interval=%s\ngeosite_update=%s\ngeoip_update=%s\n' \
			"$(config_t_get global_rules update_week_mode)" "$(config_t_get global_rules update_time_mode 0:00)" \
			"$(config_t_get global_rules update_interval_mode 1)" "$(config_t_get global_rules geosite_update 1)" "$(config_t_get global_rules geoip_update 1)"
		printf 'asset=%s\ndefault_naive_interface=%s\nenable_geoview_ip=%s\n' \
			"$V2RAY_LOCATION_ASSET" "$DEFAULT_NAIVE_EGRESS_IFACE" "$ENABLE_GEOVIEW_IP"
		printf 'redir_port=%s\ndns_port=%s\n' "$REDIR_PORT" "$BYPASSCORE_DNS_PORT"
		printf 'selected_naive_nodes\n'
		sort -u "$TMP_PATH/selected_naive_nodes" 2>/dev/null
		printf 'wireguard_udp=%s\n' "$([ -s "$TMP_PATH/selected_wireguard_nodes" ] && echo 1 || echo 0)"
		printf 'node_ports\n'
		sort -u "$TMP_PATH/node_ports" 2>/dev/null
		while read -r node; do
			[ -n "$node" ] || continue
			uci -q show "${CONFIG}.${node}"
		done < "$TMP_PATH/selected_naive_nodes"
		# Native WireGuard configuration itself can reload transactionally, but
		# its endpoint destination rules are owned by the OpenWrt wrapper.
		# Changing the endpoint host, selected interface, or selected WG node
		# therefore requires the same full route rebuild as NaiveProxy egress.
		printf 'selected_wireguard_egress\n'
		while read -r node; do
			[ -n "$node" ] || continue
			printf '%s endpoint=%s egress=%s\n' "$node" \
				"$(config_n_get "$node" peer_address)" \
				"$(config_n_get "$node" egress_interface)"
		done < "$TMP_PATH/selected_wireguard_nodes"
		# Direct GeoIP prefixes are materialized outside the reloadable snapshot.
		if [ "$ENABLE_GEOVIEW_IP" = "1" ]; then
			for sid in $(shunt_rule_sections); do
				[ "$(config_n_get "$sid" is_default 0)" = "1" ] && continue
				outbound=$(config_n_get "$sid" outbound _direct)
				[ "$outbound" = "_direct" ] && geo_class=direct || geo_class=other
				printf 'geo_rule=%s\nclass=%s\nip=%s\n' "$sid" "$geo_class" "$(config_n_get "$sid" ip_list)"
			done
		fi
		busybox cksum "$APP_PATH/direct_ip" 2>/dev/null
	} | busybox cksum | awk '{print $1 ":" $2}'
}

# Return 0 for a live transactional reload, 1 for an invalid candidate, and 2
# when external runtime state or listener identity requires a full restart.
reload_core() {
	get_config
	[ "$ENABLED" = "1" ] || return 2
	process_alive bypasscore && bypasscore_ready || return 2
	prepare_selected_nodes
	local previous_signature next_signature backup response
	previous_signature=$(get_cache_var RUNTIME_RESTART_SIGNATURE)
	next_signature=$(runtime_restart_signature)
	[ -n "$previous_signature" ] && [ "$previous_signature" = "$next_signature" ] || return 2

	backup="${BYPASSCORE_CFG}.reload-backup"
	cp -f "$BYPASSCORE_CFG" "$backup" 2>/dev/null || return 2
	if ! gen_bypasscore_config; then
		cp -f "$backup" "$BYPASSCORE_CFG"
		rm -f "$backup"
		log 0 "BypassCore live reload rejected an invalid generated configuration."
		return 1
	fi
	# An empty request asks BypassCore to read its configured file directly,
	# avoiding HTTP body/argv limits for large rule sets.
	if ! response=$(bypasscore_control_request POST /v1/config/reload "" 2>&1); then
		cp -f "$backup" "$BYPASSCORE_CFG"
		rm -f "$backup"
		return 2
	fi
	if printf '%s' "$response" | grep -Eq '"(reloaded|unchanged)"[[:space:]]*:[[:space:]]*true'; then
		if ! probe_bypasscore_nftsets; then
			cp -f "$backup" "$BYPASSCORE_CFG"
			rm -f "$backup"
			return 2
		fi
		rm -f "$backup"
		set_cache_var RUNTIME_RESTART_SIGNATURE "$next_signature"
		log 0 "BypassCore configuration reloaded transactionally: %s" "$response"
		return 0
	fi
	cp -f "$backup" "$BYPASSCORE_CFG"
	rm -f "$backup"
	if printf '%s' "$response" | grep -Eq '"code"[[:space:]]*:[[:space:]]*"restart_required"'; then
		return 2
	fi
	log 0 "BypassCore live reload failed; previous runtime retained: %s" "$response"
	return 1
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
	if ! bypasscore_has_required_features "$BYPASSCORE_FILE"; then
		log 0 "BypassCore 1.4.0 schema-5 WireGuard, native NFTSet and TCP probe capabilities are required; service not started."
		return 1
	fi
	prepare_selected_nodes
	run_naive_nodes || { stop; return 1; }
	run_bypasscore_core || { stop; return 1; }
	# Revalidate every listener before installing firewall redirection.
	if ! validate_runtime; then
		log 0 "A required process failed its final health check; firewall and DNS were not modified."
		stop
		return 1
	fi
	BYPASS_NFT_ACTION=start
	if ! . "$APP_PATH/${USE_TABLES}.sh"; then
		unset BYPASS_NFT_ACTION
		log 0 "Firewall setup failed; stopping managed processes and leaving DNS unchanged."
		stop
		return 1
	fi
	unset BYPASS_NFT_ACTION
	set_cache_var USE_TABLES "$USE_TABLES"
	# The table now exists; ask the core to verify set family/type/timeout flags
	# before allowing dnsmasq to send it queries which may produce set writes.
	if ! probe_bypasscore_nftsets; then
		log 0 "Native DNS-result NFTSet integration failed validation; stopping."
		stop
		return 1
	fi
	# A configured writer deliberately remains unready until every externally
	# owned set has been probed. At this point the table and all listeners exist,
	# so aggregate readiness must become true before DNS handover.
	if ! wait_for_bypasscore_ready 5; then
		log 0 "BypassCore did not become ready after DNS-result NFTSet validation; stopping."
		stop
		return 1
	fi
	# Only hand dnsmasq to BypassCore after listeners and NFTSets are healthy.
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
	set_cache_var RUNTIME_RESTART_SIGNATURE "$(runtime_restart_signature)"
	start_monitor || {
		log 0 "Required runtime watcher is unavailable; stopping instead of leaving updates and process failures untracked."
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
	if [ -n "$USE_TABLES" ]; then
		BYPASS_NFT_ACTION=stop
		. "$APP_PATH/${USE_TABLES}.sh" 2>/dev/null
		unset BYPASS_NFT_ACTION
	fi
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
		reload_core) reload_core ;;
		start)     start "$@" ;;
		stop)      stop ;;
		*)
			echo "Usage: $0 {start|stop|reload_core|gen_config}"
			;;
	esac
fi
