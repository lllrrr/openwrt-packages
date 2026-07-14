#!/bin/sh
# Copyright (c) 2026 Eugene Chan
# SPDX-License-Identifier: MIT
#
# nftables transparent-proxy backend for luci-app-bypass.
#
# One table is managed:
#   table inet bypass        - the redirect/tproxy ruleset + the bypass_chn /
#                              bypass_vps sets (the latter filled at runtime by
#                              chinadns-ng via add-tagchn-ip / group-ipset).
#
# Sources utils.sh (via app.sh) for $REDIR_PORT, $TCP_PROXY_WAY, $TCP_REDIR_PORTS,
# $UDP_REDIR_PORTS and cache helpers.

# app.sh sources this file during service start. Firewall reloads and hotplug
# actions execute it directly, so initialize the shared helpers and reload the
# persisted runtime port/config in that case.
if ! type first_type >/dev/null 2>&1; then
	. ${APP_PATH:-/usr/share/bypass}/utils.sh
fi

load_standalone_config() {
	[ -n "$TCP_PROXY_WAY" ] && return 0
	[ "$(config_t_get global enabled 0)" = "1" ] || return 1
	REDIR_PORT=$(get_cache_var ACL_GLOBAL_redir_port)
	[ -n "$REDIR_PORT" ] || return 1
	TCP_PROXY_WAY=$(config_t_get global_forwarding tcp_proxy_way redirect)
	TCP_NO_REDIR_PORTS=$(config_t_get global_forwarding tcp_no_redir_ports disable)
	UDP_NO_REDIR_PORTS=$(config_t_get global_forwarding udp_no_redir_ports disable)
	TCP_REDIR_PORTS=$(config_t_get global_forwarding tcp_redir_ports 1:65535)
	UDP_REDIR_PORTS=$(config_t_get global_forwarding udp_redir_ports 1:65535)
	PROXY_IPV6=$(config_t_get global_forwarding ipv6_tproxy 0)
	FORCE_PROXY_LAN_IP=$(config_t_get global_forwarding force_proxy_lan_ip 0)
	ACCEPT_ICMP=$(config_t_get global_forwarding accept_icmp 0)
	CLIENT_PROXY=$(config_t_get global client_proxy 1)
	WRITE_IPSET_DIRECT=$(config_t_get global_rules write_ipset_direct 1)
	ENABLE_GEOVIEW_IP=$(config_t_get global_rules enable_geoview_ip 1)
}

NFT=$(first_type /usr/sbin/nft nft)
NFT_TABLE=bypass
INCLUDE_FILE=/var/etc/bypass.include

# Port-list "1:65535" / "80,443" / "80-90" -> nft range/set syntax helper.
# Returns empty for "disable" (meaning: do not redirect that protocol).
nft_port_expr() {
	local v=$1
	[ "$v" = "disable" ] && { echo ""; return; }
	echo "$v" | grep -qE '^[0-9]+([:-][0-9]+)?(,[0-9]+([:-][0-9]+)?)*$' || {
		log 0 "Invalid port expression rejected: %s" "$v"
		echo ""
		return 1
	}
	# Convert a:b form and comma list into a nft set of ports/ranges.
	echo "$v" | sed -e 's/:/-/g' -e 's/,/, /g'
}

# Apply a ruleset string via a temp file (atomic).
nft_apply() {
	local ruleset=$1
	local tmp="$TMP_PATH2/nft-ruleset"
	mkdir -p "$TMP_PATH2"
	printf '%s\n' "$ruleset" > "$tmp"
	$NFT -f "$tmp" 2>>"$LOG_FILE"
}

nft_start() {
	load_standalone_config || { log 0 "Bypass is disabled or has no active redirect port; skip firewall rules."; return 0; }
	[ -z "$NFT" ] && { log 0 "nft not found; cannot install nftables rules."; return 1; }
	mkdir -p "$(dirname "$INCLUDE_FILE")"

	# Drop any prior table first. `delete table` errors if the table doesn't
	# exist yet (first run), so ignore its stderr; this makes the (re)install
	# idempotent without relying on `flush table` (which also errors when the
	# table is absent and would abort the whole ruleset load below).
	$NFT delete table inet ${NFT_TABLE} 2>/dev/null

	local tcp_expr udp_expr tcp_no_expr udp_no_expr
	tcp_expr=$(nft_port_expr "$TCP_REDIR_PORTS")
	udp_expr=$(nft_port_expr "$UDP_REDIR_PORTS")
	tcp_no_expr=$(nft_port_expr "$TCP_NO_REDIR_PORTS")
	udp_no_expr=$(nft_port_expr "$UDP_NO_REDIR_PORTS")

	local mode=$TCP_PROXY_WAY
	# naive upstream builds support redir everywhere; tproxy only in builds
	# compiled with it. Treat anything other than tproxy as redirect.
	[ "$mode" = "tproxy" ] || mode=redirect
	# IPv6 transparent proxying is only possible through TPROXY. Enabling it
	# therefore moves the shared IPv4 listener to TPROXY as well.
	[ "$PROXY_IPV6" = "1" ] && mode=tproxy

	# Sets shared with chinadns-ng (filled at runtime). Keep router-local
	# addresses in a set as well so management traffic is never intercepted.
	local sets local_elements="" local6_elements="" local_ip
	for local_ip in $(ip -o -4 addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1); do
		local_elements="${local_elements:+$local_elements, }$local_ip"
	done
	[ -n "$local_elements" ] || local_elements=127.0.0.1
	for local_ip in $(ip -o -6 addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1); do
		local6_elements="${local6_elements:+$local6_elements, }$local_ip"
	done
	[ -n "$local6_elements" ] || local6_elements=::1
	sets=$(cat <<EOF
table inet ${NFT_TABLE} {
	set bypass_local {
		type ipv4_addr
		elements = { ${local_elements} }
	}
	set bypass_local6 {
		type ipv6_addr
		elements = { ${local6_elements} }
	}
	set bypass_lan {
		type ipv4_addr
		flags interval
		elements = { 10.0.0.0/8, 100.64.0.0/10, 172.16.0.0/12, 192.168.0.0/16 }
	}
	set bypass_lan6 {
		type ipv6_addr
		flags interval
		elements = { fc00::/7 }
	}
	set bypass_dns {
		type ipv4_addr
		size 32
	}
	set bypass_direct_dns {
		type ipv4_addr
		size 65536
		flags interval
	}
	set bypass_direct_dns6 {
		type ipv6_addr
		size 65536
		flags interval
	}
	set bypass_chn {
		type ipv4_addr
		size 65536
		flags interval
	}
	set bypass_chn6 {
		type ipv6_addr
		size 65536
		flags interval
	}
	set bypass_vps {
		type ipv4_addr
		size 1024
		flags interval
	}
	set bypass_vps6 {
		type ipv6_addr
		size 1024
		flags interval
	}
EOF
)

	local wan_accept="" wan_devices="" dev
	for dev in $({ ip -o -4 route show default; ip -o -6 route show default; } 2>/dev/null | awk '{ for (i=1; i<=NF; i++) if ($i == "dev") print $(i+1) }' | sort -u); do
		wan_devices="${wan_devices:+$wan_devices, }\"$dev\""
	done
	[ -n "$wan_devices" ] && wan_accept="iifname { ${wan_devices} } accept"
	# BypassCore, not the firewall approximation, owns all live shunt decisions.
	local china_accept=""

	local lan_accept="" lan6_accept=""
	if [ "$FORCE_PROXY_LAN_IP" != "1" ]; then
		lan_accept="ip daddr @bypass_lan accept"
		lan6_accept="ip6 daddr @bypass_lan6 accept"
	fi
	local direct_dns_accept="" direct_dns6_accept=""
	local direct_bind_configured=0 _bind_sid
	[ -n "$(config_t_get global_rules direct_egress_interface)" ] && direct_bind_configured=1
	for _bind_sid in $(uci -q show "$CONFIG" 2>/dev/null | sed -n 's/^bypass\.\([^.=]*\)=shunt_rules$/\1/p'); do
		[ "$(config_n_get "$_bind_sid" outbound)" = "_direct" ] && [ -n "$(config_n_get "$_bind_sid" egress_interface)" ] && direct_bind_configured=1
	done
	if { [ "$WRITE_IPSET_DIRECT" = "1" ] || [ "$ENABLE_GEOVIEW_IP" = "1" ]; } && [ "$direct_bind_configured" = "0" ]; then
		direct_dns_accept="ip daddr @bypass_direct_dns accept"
		direct_dns6_accept="ip6 daddr @bypass_direct_dns6 accept"
	elif [ "$direct_bind_configured" = "1" ]; then
		log 0 "Direct interface binding is configured; keeping direct DNS/GeoIP matches inside BypassCore so the selected interface is honored."
	fi

	local nat_chain="" mangle_chain="" mangle6_chain="" tcp_redirect_rule="" icmp_redirect_rule=""
	# REDIRECT mode uses NAT PREROUTING for TCP. ICMP hijacking is implemented
	# in the same NAT base chain and makes the router answer matching IPv4 pings,
	# matching Passwall2's nftables behavior without sending ICMP to BypassCore.
	if [ "$CLIENT_PROXY" = "1" ] && [ "$mode" = "redirect" ] && [ -n "$tcp_expr" ]; then
		tcp_redirect_rule="meta l4proto tcp tcp dport { ${tcp_expr} } redirect to :${REDIR_PORT}"
	fi
	if [ "$CLIENT_PROXY" = "1" ] && [ "$ACCEPT_ICMP" = "1" ]; then
		icmp_redirect_rule="ip protocol icmp redirect"
	fi
	if [ -n "$tcp_redirect_rule" ] || [ -n "$icmp_redirect_rule" ]; then
		nat_chain="chain prerouting { type nat hook prerouting priority -100; policy accept;
			ip daddr @bypass_vps accept
			${direct_dns_accept}
			${china_accept}
			ip daddr @bypass_local accept
			${lan_accept}
			ip daddr @bypass_dns meta l4proto { tcp, udp } th dport 53 accept
			${wan_accept}
			iif lo accept
			${tcp_no_expr:+meta l4proto tcp tcp dport { ${tcp_no_expr} } accept}
			${tcp_redirect_rule}
			${icmp_redirect_rule}
		}"
	fi
	# TProxy mode: mangle PREROUTING TPROXY for TCP. NaiveProxy's SOCKS5
	# listener rejects UDP ASSOCIATE, so UDP must remain direct.
	if [ "$CLIENT_PROXY" = "1" ] && [ "$mode" = "tproxy" ] && [ -n "$tcp_expr" ]; then
		[ -n "$tcp_expr" ] && mangle_chain="chain prerouting { type filter hook prerouting priority mangle; policy accept;
			ip daddr @bypass_vps accept
			${direct_dns_accept}
			${china_accept}
			ip daddr @bypass_local accept
			${lan_accept}
			ip daddr @bypass_dns meta l4proto { tcp, udp } th dport 53 accept
			${wan_accept}
			iif lo accept
			${tcp_no_expr:+meta l4proto tcp tcp dport { ${tcp_no_expr} } accept}
			meta l4proto tcp tcp dport { ${tcp_expr} } tproxy ip to 127.0.0.1:${REDIR_PORT} meta mark set meta mark | 0x10000 accept
		}"
		if [ "$PROXY_IPV6" = "1" ]; then
			[ -n "$tcp_expr" ] && mangle6_chain="chain prerouting6_tcp { type filter hook prerouting priority mangle; policy accept;
				ip6 daddr @bypass_vps6 accept
				${direct_dns6_accept}
				ip6 daddr @bypass_local6 accept
				${lan6_accept}
				${wan_accept}
				iif lo accept
				${tcp_no_expr:+meta l4proto tcp tcp dport { ${tcp_no_expr} } accept}
				meta l4proto tcp tcp dport { ${tcp_expr} } tproxy ip6 to [::1]:${REDIR_PORT} meta mark set meta mark | 0x10000 accept
			}"
		fi
		# Preserve mwan3/PBR marks in the low bits and reserve one high bit only.
		while ip rule del priority 998 fwmark 0x10000/0x10000 lookup 20100 2>/dev/null; do :; done
		ip rule add priority 998 fwmark 0x10000/0x10000 lookup 20100 2>/dev/null || {
			log 0 "Could not install the TPROXY policy rule."
			return 1
		}
		ip route replace local 0.0.0.0/0 dev lo proto 99 table 20100 2>/dev/null || {
			ip rule del priority 998 fwmark 0x10000/0x10000 lookup 20100 2>/dev/null
			log 0 "Could not install the TPROXY local route."
			return 1
		}
		if [ "$PROXY_IPV6" = "1" ]; then
			while ip -6 rule del priority 998 fwmark 0x10000/0x10000 lookup 20101 2>/dev/null; do :; done
			ip -6 rule add priority 998 fwmark 0x10000/0x10000 lookup 20101 2>/dev/null || {
				while ip rule del priority 998 fwmark 0x10000/0x10000 lookup 20100 2>/dev/null; do :; done
				ip route flush table 20100 proto 99 2>/dev/null
				log 0 "Could not install the IPv6 TPROXY policy rule."
				return 1
			}
			ip -6 route replace local ::/0 dev lo proto 99 table 20101 2>/dev/null || {
				ip -6 rule del priority 998 fwmark 0x10000/0x10000 lookup 20101 2>/dev/null
				while ip rule del priority 998 fwmark 0x10000/0x10000 lookup 20100 2>/dev/null; do :; done
				ip route flush table 20100 proto 99 2>/dev/null
				log 0 "Could not install the IPv6 TPROXY local route."
				return 1
			}
		fi
	fi

	local ruleset="${sets}
	${nat_chain}
	${mangle_chain}
	${mangle6_chain}
	}"
	nft_apply "$ruleset" || {
		while ip rule del priority 998 fwmark 0x10000/0x10000 lookup 20100 2>/dev/null; do :; done
		ip route flush table 20100 proto 99 2>/dev/null
		while ip -6 rule del priority 998 fwmark 0x10000/0x10000 lookup 20101 2>/dev/null; do :; done
		ip -6 route flush table 20101 proto 99 2>/dev/null
		log 0 "nft ruleset apply failed."
		return 1
	}

	# Pre-populate bypass_vps with every node server IP (literal or resolved),
	# so a future router-OUTPUT implementation cannot recurse into the tunnel.
	local ip node address direct_dns
	for node in $(uci -q show "$CONFIG" 2>/dev/null | sed -n 's/^bypass\.\([^.=]*\)=nodes$/\1/p'); do
		address=$(config_n_get "$node" address)
		for ip in $(resolve_all_ipv4 "$address"); do
			[ -n "$ip" ] && $NFT add element inet ${NFT_TABLE} bypass_vps "{ $ip }" 2>/dev/null
		done
		for ip in $(resolve_all_ipv6 "$address"); do
			[ -n "$ip" ] && $NFT add element inet ${NFT_TABLE} bypass_vps6 "{ $ip }" 2>/dev/null
		done
	done
	for ip in $(get_wan_ips ip4); do
		$NFT add element inet ${NFT_TABLE} bypass_vps "{ $ip }" 2>/dev/null
	done
	for ip in $(get_wan_ips ip6); do
		$NFT add element inet ${NFT_TABLE} bypass_vps6 "{ $ip }" 2>/dev/null
	done
	direct_dns=$(get_direct_dns_ipv4)
	[ -n "$direct_dns" ] || direct_dns=223.5.5.5
	for ip in $direct_dns; do
		if $NFT add element inet ${NFT_TABLE} bypass_dns "{ $ip }" 2>/dev/null; then
			log 1 "Add direct IPv4 DNS to whitelist: %s" "$ip"
		fi
	done

	# Passwall2-style GeoIP preloading for Direct rules. Populate the same
	# interval sets used by direct DNS results so matching IPs bypass the core.
	if [ "$ENABLE_GEOVIEW_IP" = "1" ]; then
		local sid ip_rule code cidr
		for sid in $(uci -q show "$CONFIG" 2>/dev/null | sed -n 's/^bypass\.\([^.=]*\)=shunt_rules$/\1/p'); do
			[ "$(config_n_get "$sid" outbound)" = "_direct" ] || continue
			while IFS= read -r ip_rule; do
				case "$ip_rule" in ''|'#'*) continue ;; esac
				case "$ip_rule" in
					geoip:*)
						code=${ip_rule#geoip:}
						for cidr in $(get_geoip "$code" ipv4); do $NFT add element inet ${NFT_TABLE} bypass_direct_dns "{ $cidr }" 2>/dev/null; done
						for cidr in $(get_geoip "$code" ipv6); do $NFT add element inet ${NFT_TABLE} bypass_direct_dns6 "{ $cidr }" 2>/dev/null; done
						;;
					*:*/*|*:*) $NFT add element inet ${NFT_TABLE} bypass_direct_dns6 "{ $ip_rule }" 2>/dev/null ;;
					*) $NFT add element inet ${NFT_TABLE} bypass_direct_dns "{ $ip_rule }" 2>/dev/null ;;
				esac
			done <<-EOF
			$(config_n_get "$sid" ip_list)
			EOF
		done
	fi

	nft_gen_include
	log 0 "nftables ruleset installed (mode=%s, redir_port=%s)." "$mode" "$REDIR_PORT"
}

nft_stop() {
	# Remove tproxy local-route scaffolding if present.
	while ip rule del priority 998 fwmark 0x10000/0x10000 lookup 20100 2>/dev/null; do :; done
	ip route flush table 20100 proto 99 2>/dev/null
	while ip -6 rule del priority 998 fwmark 0x10000/0x10000 lookup 20101 2>/dev/null; do :; done
	ip -6 route flush table 20101 proto 99 2>/dev/null
	[ -n "$NFT" ] && $NFT delete table inet ${NFT_TABLE} 2>/dev/null
	rm -f "$INCLUDE_FILE" 2>/dev/null
	log 0 "nftables ruleset removed."
}

# Write the fw4 include script so the ruleset survives firewall reloads.
nft_gen_include() {
	mkdir -p "$(dirname "$INCLUDE_FILE")"
	cat <<-EOF > "$INCLUDE_FILE"
		#!/bin/sh
		${APP_PATH}/nftables.sh start
	EOF
	chmod +x "$INCLUDE_FILE" 2>/dev/null
}

# Cheap WAN-IP refresh on hotplug ifupdate (no full restart).
nft_update_wan_sets() {
	[ -z "$NFT" ] && return 0
	# Re-add current WAN IPs to bypass_vps so the router's own egress stays direct.
	local wan
	wan=$(get_wan_ips ip4)
	[ -n "$wan" ] && $NFT add element inet ${NFT_TABLE} bypass_vps "{ $wan }" 2>/dev/null
	wan=$(get_wan_ips ip6)
	[ -n "$wan" ] && $NFT add element inet ${NFT_TABLE} bypass_vps6 "{ $wan }" 2>/dev/null
}

# Dispatch (app.sh sources this file then calls $1, or we dispatch on $1 directly).
case "${1:-start}" in
	start)        nft_start ;;
	stop)         nft_stop ;;
	gen_include)  nft_gen_include ;;
	update_wan_sets) nft_update_wan_sets ;;
esac
