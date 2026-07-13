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

UTIL_NAIVE=${APP_PATH}/util_naive.sh      # reserved for future per-protocol config generators
NAIVE_TAG=naive
CHINADNS_TAG=chinadns-ng

# Effective egress interface for the current global node (per-node override or
# the global default). Empty = use the system default route.
get_effective_egress_iface() {
	local node_egress
	node_egress=$(config_n_get "$NODE" egress_interface)
	[ -n "$node_egress" ] && { echo "$node_egress"; return; }
	config_t_get global default_egress_interface
}

# ------------------------------------------------------------------------------
# Config snapshot
# ------------------------------------------------------------------------------

get_direct_dns() {
	RESOLVFILE=/tmp/resolv.conf.d/resolv.conf.auto
	[ -f "${RESOLVFILE}" ] && [ -s "${RESOLVFILE}" ] || RESOLVFILE=/tmp/resolv.conf.auto

	ISP_DNS=$(cat "$RESOLVFILE" 2>/dev/null | grep -E -o "[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" | grep -v -E '^(0\.0\.0\.0|127\.0\.0\.1)$' | awk '!seen[$0]++')

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
	NODE=$(config_t_get global node)
	NODE_SOCKS_PORT=$(config_t_get global node_socks_port 1070)
	LOCALHOST_PROXY=$(config_t_get global localhost_proxy 1)
	CLIENT_PROXY=$(config_t_get global client_proxy 1)
	LOGLEVEL=$(config_t_get global loglevel error)
	DNS_REDIRECT=$(config_t_get global dns_redirect 1)

	BYPASSCORE_FILE=$(config_t_get global bypasscore_file /usr/bin/bypasscore)
	NAIVE_BIN=$(first_type "$(config_t_get global naive_file /usr/bin/naive)" naive)
	CHINADNS_BIN=$(first_type "$(config_t_get global chinadns_file /usr/bin/chinadns-ng)" chinadns-ng)
	# bypass_as_core=1: BypassCore runs `-run` as the transparent proxy core
	# (inbound + sniff + route); naiveproxy is demoted to a SOCKS upstream that
	# BypassCore's `proxy` outbound dials into. Requires BypassCore's proxy-mode
	# SOCKS5 dialer (pending upstream). =0 (default, legacy): naiveproxy carries
	# traffic, BypassCore is diagnostic-only.
	BYPASS_AS_CORE=$(config_t_get global bypass_as_core 0)
	V2RAY_LOCATION_ASSET=$(config_t_get global_rules v2ray_location_asset /usr/share/v2ray/)
	DOMAIN_STRATEGY=$(config_t_get global_rules domainStrategy IpIfNonMatch)

	REDIR_PORT=$(echo $(get_new_port 1041 tcp,udp))
	TCP_PROXY_WAY=$(config_t_get global_forwarding tcp_proxy_way redirect)
	TCP_NO_REDIR_PORTS=$(config_t_get global_forwarding tcp_no_redir_ports 'disable')
	UDP_NO_REDIR_PORTS=$(config_t_get global_forwarding udp_no_redir_ports 'disable')
	TCP_REDIR_PORTS=$(config_t_get global_forwarding tcp_redir_ports '1:65535')
	UDP_REDIR_PORTS=$(config_t_get global_forwarding udp_redir_ports '1:65535')
	PROXY_IPV6=$(config_t_get global_forwarding ipv6_tproxy 0)

	DOMESTIC_DNS_USER=$(config_t_get global_dns domestic_dns auto)
	REMOTE_DNS=$(config_t_get global_dns remote_dns 1.1.1.1)
	REMOTE_DNS_PROTOCOL=$(config_t_get global_dns remote_dns_protocol udp)
	CHINADNS_PORT=$(config_t_get global_dns chinadns_listen_port 10553)
	# BypassCore DNS subsystem (the real split-DNS engine; ChinaDNS-NG stays as
	# an ipset/nftset populator mirroring passwall2). Empty upstream -> disabled.
	BC_DOMESTIC_DNS=$(config_t_get global_dns bc_domestic_dns https://223.5.5.5/dns-query)
	BC_REMOTE_DNS=$(config_t_get global_dns bc_remote_dns https://1.1.1.1/dns-query)
	BC_QUERY_STRATEGY=$(config_t_get global_dns query_strategy UseIPv4)
	DNS_SPLIT_DOMAIN=$(config_t_get global_dns dns_split_domain geosite:cn)

	# Egress (dest-IP fwmark policy routing).
	DEFAULT_EGRESS_IFACE=$(config_t_get global default_egress_interface)
	NAIVE_EGRESS_FWMARK=$(config_t_get global naive_egress_fwmark 0x2)
	NAIVE_EGRESS_TABLE=$(config_t_get global naive_egress_table 200)

	get_direct_dns
	QUEUE_RUN=1
}

# ------------------------------------------------------------------------------
# naiveproxy carrier (https only). Listens in redir/tproxy/tun mode for the
# transparent proxy, plus a SOCKS instance for per-app use / API urltest.
# ------------------------------------------------------------------------------

run_naive() {
	[ -z "$NODE" ] && { log 0 "No node selected, skip naive."; return 1; }
	[ -z "$NAIVE_BIN" ] && {
		log 0 "naiveproxy binary not found (install naiveproxy or set naive_file). Transparent proxy disabled."
		NAIVE_OK=0
		return 1
	}

	local address port username password
	address=$(config_n_get "$NODE" address)
	port=$(config_n_get "$NODE" port)
	username=$(config_n_get "$NODE" username)
	password=$(config_n_get "$NODE" password)
	[ -z "$address" ] || [ -z "$port" ] && { log 0 "Node [%s] has no address/port, skip naive." "$NODE"; return 1; }

	# IPv6 host bracketing for the proxy URL.
	local server_host=$address
	echo "$address" | grep -qE "([A-Fa-f0-9]{1,4}::?){1,7}[A-Fa-f0-9]{1,4}" && server_host="[$address]"

	# In bypass_as_core mode, naive does NOT open the redir/tproxy listener
	# (BypassCore owns the transparent inbound on REDIR_PORT). naive only runs
	# a SOCKS listener that BypassCore's `proxy` outbound dials into.
	local run_redir=1
	[ "$BYPASS_AS_CORE" = "1" ] && run_redir=0

	local listen_proto
	if [ "$run_redir" = "1" ]; then
		case "$TCP_PROXY_WAY" in
			tproxy)   listen_proto="tproxy"; log 0 "Warning: tproxy mode needs a naive build compiled with tproxy support." ;;
			tun|redirect|*) listen_proto="redir" ;;
		esac
	fi

	local cfg_dir=$TMP_ACL_PATH
	mkdir -p "$cfg_dir"
	local config_file="${cfg_dir}/naive.json"
	local log_file="${cfg_dir}/naive.log"
	[ "$LOGLEVEL" = "debug" ] || log_file="/dev/null"

	# naiveproxy transparent listener (legacy mode only).
	if [ "$run_redir" = "1" ]; then
		json_init
		json_add_string "listen" "${listen_proto}://127.0.0.1:${REDIR_PORT}"
		json_add_string "proxy" "https://${username}:${password}@${server_host}:${port}"
		[ "$log_file" != "/dev/null" ] && json_add_string "log" "$log_file"
		json_dump > "$config_file"
	fi

	# Egress policy routing: resolve the naive server IP(s) and install the
	# fwmark/route so the naive -> server connection leaves via the chosen
	# interface. The matching mangle-OUTPUT mark rule is installed by the
	# tables backend (sourced later in start()).
	local egress_iface
	egress_iface=$(get_effective_egress_iface)
	if [ -n "$egress_iface" ]; then
		resolve_uplink_ips "$NODE"
		setup_egress_routing "$egress_iface" "$NAIVE_EGRESS_FWMARK" "$NAIVE_EGRESS_TABLE"
	else
		log 0 "No egress interface configured; naive uses the system default route."
	fi

	# SOCKS instance for per-app use + API tcping/urltest target.
	local socks_cfg="${cfg_dir}/naive_socks.json"
	json_init
	json_add_string "listen" "socks://127.0.0.1:${NODE_SOCKS_PORT}"
	json_add_string "proxy" "https://${username}:${password}@${server_host}:${port}"
	[ "$log_file" != "/dev/null" ] && json_add_string "log" "$log_file"
	json_dump > "$socks_cfg"

	if [ "$run_redir" = "1" ]; then
		ln_run ${QUEUE_RUN} "$NAIVE_BIN" "$NAIVE_TAG" "$log_file" "$config_file"
	fi
	ln_run ${QUEUE_RUN} "$NAIVE_BIN" "${NAIVE_TAG}_socks" "/dev/null" "$socks_cfg"

	NAIVE_OK=1
	set_cache_var GLOBAL_SOCKS_server "127.0.0.1:${NODE_SOCKS_PORT}"
	set_cache_var ACL_GLOBAL_node "$NODE"
	if [ "$run_redir" = "1" ]; then
		set_cache_var ACL_GLOBAL_redir_port "$REDIR_PORT"
		log 0 "naiveproxy: %s listen=%s://%s, proxy=https://%s:%s@%s:%s" \
			"$NODE" "$listen_proto" "127.0.0.1:${REDIR_PORT}" "${username}" "${password:+***}" "$server_host" "$port"
	else
		log 0 "naiveproxy (socks upstream for BypassCore): %s socks://127.0.0.1:%s, proxy=https://%s:%s@%s:%s" \
			"$NODE" "$NODE_SOCKS_PORT" "${username}" "${password:+***}" "$server_host" "$port"
	fi
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

	# Build vpslist from all node server addresses (always-direct set).
	[ ! -s "$cfg_dir/vpslist" ] && {
		local node_servers
		node_servers=$(uci show "${CONFIG}" 2>/dev/null | grep -E "(.address=)" | cut -d "'" -f 2)
		echo "$node_servers" | while read -r h; do host_from_url "$h"; done | grep '[a-zA-Z]$' | sort -u > "$cfg_dir/vpslist"
	}

	# nftset names (nftables is the only supported backend).
	local set_names vps_set_names
	set_names="inet@bypass@bypass_chn,inet@bypass@bypass_chn6"
	vps_set_names="inet@bypass@bypass_vps,inet@bypass@bypass_vps6"

	local remote_upstream=$REMOTE_DNS
	case "$REMOTE_DNS_PROTOCOL" in
		udp) remote_upstream=$REMOTE_DNS ;;
		tcp) remote_upstream="tcp:${REMOTE_DNS}" ;;
		tls) remote_upstream="tls:${REMOTE_DNS%%:*}" ;;
		https|doh) remote_upstream="https://${REMOTE_DNS#https://}/dns-query" ;;
	esac

	cat <<-EOF > "$config_file"
		bind-addr 127.0.0.1
		bind-port ${CHINADNS_PORT}
		china-dns ${DOMESTIC_DNS}
		trust-dns ${remote_upstream}
		filter-qtype 65
		add-tagchn-ip ${set_names}
		default-tag chn
		group vpslist
		group-dnl ${cfg_dir}/vpslist
		group-upstream ${DOMESTIC_DNS}
		group-ipset ${vps_set_names}
	EOF

	ln_run 0 "$CHINADNS_BIN" "$CHINADNS_TAG" "/dev/null" -C "$config_file" -v
	CHINADNS_OK=1
	log 0 "ChinaDNS-NG: :%s  domestic=%s  remote=%s (%s)" "$CHINADNS_PORT" "$DOMESTIC_DNS" "$remote_upstream" "$REMOTE_DNS_PROTOCOL"
}

# ------------------------------------------------------------------------------
# BypassCore config.json (routing/split-decision engine config).
# Generated from the same UCI shunt_rules that feed the firewall/ipset plane.
# ------------------------------------------------------------------------------

# Map a UCI shunt outbound token to a BypassCore outbound tag.
map_outbound_tag() {
	case "$1" in
		_direct) echo "direct" ;;
		_proxy)  echo "proxy" ;;
		_block)  echo "block" ;;
		*)       echo "$1" ;;
	esac
}

gen_bypasscore_config() {
	mkdir -p "$(dirname "$BYPASSCORE_CFG")"
	local node_socks_port=$NODE_SOCKS_PORT
	[ -z "$node_socks_port" ] && node_socks_port=1070

	json_init
	# outbounds: direct / block / proxy (+ optional multi-WAN wan freedom outbounds)
	json_add_array outbounds
		json_add_object ''
			json_add_string tag direct
			json_add_string mode freedom
		json_close_object
		json_add_object ''
			json_add_string tag block
			json_add_string mode blackhole
		json_close_object
		# Multi-WAN: emit a bound freedom outbound for every named egress
		# interface configured (global default + the active node's override).
		# Mirrors BypassCore's wan1/wan2 binding model.
		local _wan_emit _w
		for _w in "$DEFAULT_EGRESS_IFACE" "$(get_effective_egress_iface)"; do
			[ -z "$_w" ] && continue
			case " $_wan_emit " in *" $_w "*) continue ;; esac
			_wan_emit="$_wan_emit $_w"
			local _lip
			_lip=$(uci -q get "network.${_w}.ipaddr" 2>/dev/null)
			json_add_object ''
				json_add_string tag "$_w"
				json_add_string mode freedom
				json_add_object bind
					json_add_string interface "$_w"
					[ -n "$_lip" ] && json_add_string localIP "$_lip"
				json_close_object
			json_close_object
		done
		json_add_object ''
			json_add_string tag proxy
			json_add_string mode proxy
			json_add_object upstream
				json_add_string protocol naive
				json_add_string server "127.0.0.1:${node_socks_port}"
				json_add_object settings
				json_close_object
			json_close_object
		json_close_object
	json_close_array

	# dns: BypassCore's split-DNS subsystem. Domestic upstream is selected by
	# the split-domain list (default geosite:cn); everything else falls through
	# to the remote upstream. Mirrors the "ChinaDNS-style" effect inside the
	# routing engine, complementing ChinaDNS-NG's ipset-population role.
	if [ -n "$BC_DOMESTIC_DNS" ] || [ -n "$BC_REMOTE_DNS" ]; then
		json_add_object dns
			json_add_array servers
				if [ -n "$BC_DOMESTIC_DNS" ] && [ -n "$DNS_SPLIT_DOMAIN" ]; then
					json_add_object ''
						json_add_string address "$BC_DOMESTIC_DNS"
						json_add_string tag domestic
						json_add_array domains
							local _sd
							for _sd in $(echo "$DNS_SPLIT_DOMAIN" | tr '\n' ' '); do
								[ -n "$_sd" ] && json_add_string '' "$_sd"
							done
						json_close_array
					json_close_object
				fi
				if [ -n "$BC_REMOTE_DNS" ]; then
					json_add_object ''
						json_add_string address "$BC_REMOTE_DNS"
						json_add_string tag remote
					json_close_object
				fi
			json_close_array
			json_add_string queryStrategy "$BC_QUERY_STRATEGY"
		json_close_object
	fi

	# routing
	json_add_object routing
		json_add_string domainStrategy "$DOMAIN_STRATEGY"
		json_add_array rules
			local sid tag domains ips net
			for sid in $(uci -q show "${CONFIG}" 2>/dev/null | grep "=shunt_rules" | cut -d '.' -f2 | cut -d '=' -f1); do
				tag=$(map_outbound_tag "$(config_n_get "$sid" outbound _direct)")
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
			# catch-all -> proxy
			json_add_object ''
				json_add_string outboundTag proxy
			json_close_object
		json_close_array
	json_close_object

	# observatory (only useful if the bypasscore binary is present)
	if is_linux_elf "$BYPASSCORE_FILE" 2>/dev/null; then
		json_add_object observatory
			json_add_array subject_selector
				json_add_string '' proxy
			json_close_array
			json_add_string probe_url "https://www.gstatic.com/generate_204"
			json_add_int probe_interval 10000000000
			# enable_concurrency omitted: jshn's json_add_boolean is unreliable
			# across OpenWrt versions (can emit a string "true" that the Go proto
			# bool rejects, failing the whole config parse). The field defaults
			# to false in the proto, which is fine for the routing engine.
		json_close_object
	fi

	# inbounds: only emitted in bypass_as_core mode. BypassCore listens on
	# inbounds: only emitted in bypass_as_core mode. BypassCore listens on
	# REDIR_PORT as a transparent listener; nftables REDIRECT/TPROXY sends
	# traffic here instead of to naiveproxy. type/network follow tcp_proxy_way:
	#   redirect -> TCP only (SO_ORIGINAL_DST)
	#   tproxy   -> TCP + UDP (UDP needs TPROXY/IP_TRANSPARENT)
	if [ "$BYPASS_AS_CORE" = "1" ]; then
		local in_type="redirect" in_net="tcp"
		if [ "$TCP_PROXY_WAY" = "tproxy" ]; then
			in_type="tproxy"
			in_net="tcp,udp"
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
		json_close_array
	fi

	json_dump > "$BYPASSCORE_CFG"
	log 0 "BypassCore config written to %s (bypass_as_core=%s)." "$BYPASSCORE_CFG" "$BYPASS_AS_CORE"
}

# ------------------------------------------------------------------------------
# BypassCore as transparent core: `bypasscore -run -c <cfg>` (daemon). Only
# used when bypass_as_core=1. Needs BypassCore's proxy-mode SOCKS5 dialer to
# be useful for "proxy" routes (until then only direct/blackhole work).
# ------------------------------------------------------------------------------
run_bypasscore_core() {
	[ "$BYPASS_AS_CORE" = "1" ] || return 0
	if ! is_linux_elf "$BYPASSCORE_FILE" 2>/dev/null; then
		log 0 "bypass_as_core=1 but bypasscore is missing/not a Linux ELF; cannot run as core. Falling back to legacy (naiveproxy carrier)."
		return 1
	fi
	gen_bypasscore_config
	local cfg_dir=$TMP_ACL_PATH
	mkdir -p "$cfg_dir"
	local log_file="${cfg_dir}/bypasscore.log"
	[ "$LOGLEVEL" = "debug" ] || log_file="/dev/null"
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
	# Save the current upstream so we can restore on stop.
	local old
	old=$(uci -q get dhcp.@dnsmasq[0].server 2>/dev/null)
	[ -n "$old" ] && set_cache_var bak_dnsmasq_server "$old"
	uci -q delete dhcp.@dnsmasq[0].server 2>/dev/null
	uci -q add_list dhcp.@dnsmasq[0].server="127.0.0.1#${CHINADNS_PORT}" 2>/dev/null
	[ "$DNS_REDIRECT" = "1" ] && {
		uci -q set dhcp.@dnsmasq[0].rebind_protection='0' 2>/dev/null
	}
	uci -q commit dhcp 2>/dev/null
	/etc/init.d/dnsmasq restart >/dev/null 2>&1
	log 0 "dnsmasq forwarded to ChinaDNS-NG :%s." "$CHINADNS_PORT"
}

restore_dnsmasq_forward() {
	local bak
	bak=$(get_cache_var bak_dnsmasq_server)
	uci -q delete dhcp.@dnsmasq[0].server 2>/dev/null
	[ -n "$bak" ] && {
		local s
		for s in $bak; do uci -q add_list dhcp.@dnsmasq[0].server="$s" 2>/dev/null; done
	}
	uci -q commit dhcp 2>/dev/null
	/etc/init.d/dnsmasq restart >/dev/null 2>&1
}

# ------------------------------------------------------------------------------
# Crontab (periodic geodata update + uplink re-resolve)
# ------------------------------------------------------------------------------

start_crontab() {
	local minute=$(config_t_get global_rules auto_update_minute 30)
	local enable_geo
	enable_geo=$(config_t_get global_rules geosite_update 1)
	[ "$enable_geo" = "1" ] && {
		echo "${minute:-30} 4 * * * ${APP_PATH}/rule_update.sh >>${LOG_FILE} 2>&1" >> /etc/crontabs/root
	}
	# Re-resolve naive uplink IPs every hour (DNS round-robin / IP changes).
	echo "0 * * * * ${APP_PATH}/rule_update.sh refresh_uplink >>${LOG_FILE} 2>&1" >> /etc/crontabs/root
	/etc/init.d/cron restart >/dev/null 2>&1
}

stop_crontab() {
	sed -i "/${APP_PATH//\//\\/}\/rule_update\.sh/d" /etc/crontabs/root 2>/dev/null
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
	mkdir -p /tmp/etc /tmp/log "$TMP_PATH" "$TMP_BIN_PATH" "$TMP_SCRIPT_FUNC_PATH" "$TMP_ROUTE_PATH" "$TMP_ACL_PATH" "$TMP_PATH2"

	get_config
	export BYPASSCORE_ASSETS="$V2RAY_LOCATION_ASSET"
	export ENABLE_DEPRECATED_GEOSITE=true
	export ENABLE_DEPRECATED_GEOIP=true
	ulimit -n 65535 2>/dev/null

	NAIVE_OK=0
	BYPASSCORE_OK=0
	CHINADNS_OK=0
	check_run_environment

	[ "$ENABLED" = "1" ] && [ -n "$NODE" ] && {
		[ "$(config_get_type "$NODE")" = "nodes" ] && {
			run_naive
		}
	}
	# bypass_as_core: BypassCore runs -run as the transparent core. If it
	# fails (e.g. bypasscore missing/non-ELF), run_naive already ran in legacy
	# mode above so traffic still flows via naiveproxy.
	run_bypasscore_core
	run_chinadns_ng
	run_dnsmasq_forward
	[ "$BYPASSCORE_OK" != "1" ] && gen_bypasscore_config

	[ -n "$USE_TABLES" ] && source "$APP_PATH/${USE_TABLES}.sh" start
	set_cache_var USE_TABLES "$USE_TABLES"

	# Bridge-nf call disable so iptables sees bridged traffic cleanly.
	if [ "$NAIVE_OK" = "1" ]; then
		local bnf
		bnf=$(sysctl -e -n net.bridge.bridge-nf-call-iptables 2>/dev/null)
		[ -n "$bnf" ] && set_cache_var bak_bridge_nf_ipt "$bnf"
		sysctl -w net.bridge.bridge-nf-call-iptables=0 >/dev/null 2>&1
	fi

	run_process_queue
	start_crontab
	log 0 "Bypass started."
	echolog ""
}

stop() {
	clean_log
	eval_cache_var
	[ -n "$USE_TABLES" ] && source "$APP_PATH/${USE_TABLES}.sh" stop 2>/dev/null
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
