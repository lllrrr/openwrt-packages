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
	NODE=$(config_t_get global node)
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
	CHINADNS_PORT=$(config_t_get global_dns chinadns_listen_port 10553)
	DNS2SOCKS_PORT=$(get_cache_var DNS2SOCKS_PORT)
	[ -n "$DNS2SOCKS_PORT" ] || DNS2SOCKS_PORT=$(echo $(get_new_port 10554 tcp))
	[ "$DNS2SOCKS_PORT" = "$CHINADNS_PORT" ] && DNS2SOCKS_PORT=$(expr "$DNS2SOCKS_PORT" + 1)
	# BypassCore DNS subsystem (the real split-DNS engine; ChinaDNS-NG stays as
	# an ipset/nftset populator mirroring passwall2). Empty upstream -> disabled.
	BC_DOMESTIC_DNS=$(config_t_get global_dns bc_domestic_dns https://223.5.5.5/dns-query)
	BC_REMOTE_DNS=$(config_t_get global_dns bc_remote_dns https://1.1.1.1/dns-query)
	BC_QUERY_STRATEGY=$(config_t_get global_dns query_strategy UseIPv4)
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

# Relay the trusted DNS over Naive's local SOCKS listener. Passwall2 can route
# remote DNS inside Xray/sing-box; this project needs an explicit DNS-to-SOCKS
# bridge because BypassCore's DNS clients and ChinaDNS-NG dial directly.
run_dns2socks() {
	DNS2SOCKS_OK=0
	[ "$REMOTE_DNS_PROTOCOL" = "tls" ] && {
		log 0 "Remote DNS uses TLS; DNS2SOCKS cannot preserve DoT, so the remote resolver remains direct."
		return 0
	}
	[ -n "$DNS2SOCKS_BIN" ] || {
		log 0 "dns2socks is not installed; remote DNS remains direct. Install dns2socks to carry it through NaiveProxy."
		return 0
	}
	local upstream
	upstream="${REMOTE_DNS#*://}"
	case "$upstream" in
		\[*\]:*|*:*:*) ;;
		*:*) ;;
		*) upstream="${upstream}:53" ;;
	esac
	ln_run 0 "$DNS2SOCKS_BIN" "$DNS2SOCKS_TAG" "/dev/null" /q \
		"127.0.0.1:${NODE_SOCKS_PORT}" "$upstream" "127.0.0.1:${DNS2SOCKS_PORT}"
	sleep 1
	if [ "$(check_port_exists "$DNS2SOCKS_PORT" tcp)" -gt 0 ] 2>/dev/null; then
		DNS2SOCKS_OK=1
		set_cache_var DNS2SOCKS_PORT "$DNS2SOCKS_PORT"
		set_cache_var DNS2SOCKS_OK 1
		log 0 "Remote DNS: %s -> DNS2SOCKS :%s -> Naive SOCKS :%s." "$upstream" "$DNS2SOCKS_PORT" "$NODE_SOCKS_PORT"
	else
		log 0 "dns2socks failed to listen; remote DNS remains direct."
	fi
}

# ------------------------------------------------------------------------------
# NaiveProxy protocol adapter. It exposes the selected HTTPS node as a local
# SOCKS upstream; BypassCore remains the only transparent routing core.
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

	local cfg_dir=$TMP_ACL_PATH
	mkdir -p "$cfg_dir"
	local log_file="${cfg_dir}/naive.log"
	[ "$LOGLEVEL" = "debug" ] && [ "$LOG_NODE" = "1" ] || log_file="/dev/null"

	# Egress policy routing: resolve the naive server IP(s) and install the
	# destination rule so Naive's server connection leaves via the selected WAN.
	local egress_iface
	egress_iface=$(get_effective_egress_iface)
	if [ -n "$egress_iface" ]; then
		resolve_uplink_ips "$NODE"
		setup_egress_routing "$egress_iface" "$NAIVE_EGRESS_TABLE" "$NAIVE_EGRESS_RULE_PRIORITY" || return 1
	else
		log 0 "No egress interface configured; naive uses the system default route."
	fi

	# SOCKS instance for per-app use + API tcping/urltest target.
	local socks_cfg="${cfg_dir}/naive_socks.json"
	json_init
	local socks_host=127.0.0.1
	[ "$NODE_SOCKS_BIND_LOCAL" = "1" ] || socks_host=0.0.0.0
	json_add_string "listen" "socks://${socks_host}:${NODE_SOCKS_PORT}"
	json_add_string "proxy" "https://${username}:${password}@${server_host}:${port}"
	[ "$log_file" != "/dev/null" ] && json_add_string "log" "$log_file"
	json_dump > "$socks_cfg"

	ln_run ${QUEUE_RUN} "$NAIVE_BIN" "${NAIVE_TAG}_socks" "/dev/null" "$socks_cfg"

	NAIVE_OK=1
	set_cache_var GLOBAL_SOCKS_server "${socks_host}:${NODE_SOCKS_PORT}"
	set_cache_var ACL_GLOBAL_node "$NODE"
	log 0 "naiveproxy (SOCKS upstream for BypassCore): %s socks://127.0.0.1:%s, proxy=https://%s:%s@%s:%s" \
		"$NODE" "$NODE_SOCKS_PORT" "${username}" "${password:+***}" "$server_host" "$port"
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
		log 0 "geoview/geosite.dat unavailable; ChinaDNS-NG will use the trusted upstream for all domains."
	fi

	# Build the domain list consumed by ChinaDNS-NG. Literal node IPs are added
	# to bypass_vps directly by nftables.sh.
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
	if [ "$DNS2SOCKS_OK" = "1" ]; then
		remote_upstream="tcp://127.0.0.1:${DNS2SOCKS_PORT}"
	else case "$REMOTE_DNS_PROTOCOL" in
		udp) remote_upstream=$REMOTE_DNS ;;
		tcp) remote_upstream="tcp://${REMOTE_DNS#tcp://}" ;;
		tls) remote_upstream="tls://${REMOTE_DNS#tls://}" ;;
		*) remote_upstream="tcp://${REMOTE_DNS#*://}" ;;
	esac
	fi

	cat <<-EOF > "$config_file"
		bind-addr 127.0.0.1
		bind-port ${CHINADNS_PORT}
		china-dns ${DOMESTIC_DNS}
		trust-dns ${remote_upstream}
		filter-qtype 65
		add-tagchn-ip ${set_names}
		${domain_rules}
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
	BYPASSCORE_CONFIG_ERROR=0
	local node_socks_port=$NODE_SOCKS_PORT
	[ -z "$node_socks_port" ] && node_socks_port=1088

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
		json_add_object ''
			json_add_string tag proxy
			json_add_string mode proxy
			json_add_object upstream
				# BypassCore talks SOCKS5 to NaiveProxy's local listener. "naive"
				# is not an accepted BypassCore upstream protocol.
				json_add_string protocol socks
				json_add_string server "127.0.0.1:${node_socks_port}"
				json_add_object settings
				json_close_object
			json_close_object
		json_close_object
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
						# When available, use the same local DNS2SOCKS relay as
						# ChinaDNS-NG so BypassCore's own foreign lookups do not
						# bypass the selected Naive tunnel.
						if [ "$DNS2SOCKS_OK" = "1" ] || [ "$(get_cache_var DNS2SOCKS_OK)" = "1" ]; then
							json_add_string address "tcp://127.0.0.1:${DNS2SOCKS_PORT}"
						else
							json_add_string address "$BC_REMOTE_DNS"
						fi
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
			# This rule must precede the default PrivateIP direct rule; otherwise
			# the UI switch would only alter nftables but BypassCore would still
			# route matching private destinations directly.
			if [ "$FORCE_PROXY_LAN_IP" = "1" ]; then
				json_add_object ''
					json_add_string outboundTag proxy
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
			local sid tag domains ips net outbound egress
			for sid in $(uci -q show "${CONFIG}" 2>/dev/null | grep "=shunt_rules" | cut -d '.' -f2 | cut -d '=' -f1); do
				outbound=$(config_n_get "$sid" outbound _direct)
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
	[ -n "$NODE" ] && [ "$(config_get_type "$NODE")" = "nodes" ] || {
		log 0 "A valid NaiveProxy node must be selected; service not started."
		return 1
	}
	run_naive || { teardown_egress_routing; return 1; }
	run_dns2socks
	run_bypasscore_core || { teardown_egress_routing; return 1; }
	run_chinadns_ng

	# Give BypassCore a moment to open its listener. A core that dies immediately
	# (bad config, incompatible binary, or unavailable Naive SOCKS upstream)
	# means REDIR_PORT is dead — installing REDIRECT would blackhole
	# the router, so skip it with a clear log line.
	sleep 2
	if [ "$(check_port_exists "$REDIR_PORT" tcp)" -le 0 ] 2>/dev/null || \
		[ "$(check_port_exists "$NODE_SOCKS_PORT" tcp)" -le 0 ] 2>/dev/null; then
		log 0 "BypassCore or its required NaiveProxy SOCKS upstream failed to listen; firewall and DNS were not modified."
		busybox pgrep -af "$TMP_BIN_PATH" 2>/dev/null | awk '!/app\.sh|rule_update|api\.sh|ujail/{print $1}' | xargs -r kill -9 >/dev/null 2>&1
		teardown_egress_routing
		return 1
	fi
	if ! source "$APP_PATH/${USE_TABLES}.sh" start; then
		log 0 "Firewall setup failed; stopping managed processes and leaving DNS unchanged."
		source "$APP_PATH/${USE_TABLES}.sh" stop 2>/dev/null
		busybox pgrep -af "$TMP_BIN_PATH" 2>/dev/null | awk '!/app\.sh|rule_update|api\.sh|ujail/{print $1}' | xargs -r kill -9 >/dev/null 2>&1
		teardown_egress_routing
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
