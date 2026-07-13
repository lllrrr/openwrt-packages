#!/bin/sh
# Copyright (c) 2026 Eugene Chan
# SPDX-License-Identifier: MIT
#
# nftables transparent-proxy backend for luci-app-bypass.
#
# Two tables are managed:
#   table inet bypass        - the redirect/tproxy ruleset + the bypass_chn /
#                              bypass_vps sets (the latter filled at runtime by
#                              chinadns-ng via add-tagchn-ip / group-ipset).
#   table inet bypass_egress - the dest-IP fwmark rule that steers the naive ->
#                              server connection out of the chosen egress iface
#                              (only installed when an egress interface is set).
#
# Sources utils.sh (via app.sh) for $REDIR_PORT, $TCP_PROXY_WAY, $TCP_REDIR_PORTS,
# $UDP_REDIR_PORTS, $NAIVE_EGRESS_FWMARK, $TMP_PATH/uplink_ips, cache helpers.

NFT=$(first_type /usr/sbin/nft nft)
NFT_TABLE=bypass
NFT_EGRESS_TABLE=bypass_egress
INCLUDE_FILE=/var/etc/bypass.include

# Port-list "1:65535" / "80,443" / "80-90" -> nft range/set syntax helper.
# Returns empty for "disable" (meaning: do not redirect that protocol).
nft_port_expr() {
	local v=$1
	[ "$v" = "disable" ] && { echo ""; return; }
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
	[ -z "$NFT" ] && { log 0 "nft not found; cannot install nftables rules."; return 1; }
	mkdir -p "$(dirname "$INCLUDE_FILE")"

	local tcp_expr udp_expr
	tcp_expr=$(nft_port_expr "$TCP_REDIR_PORTS")
	udp_expr=$(nft_port_expr "$UDP_REDIR_PORTS")

	local mode=$TCP_PROXY_WAY
	# naive upstream builds support redir everywhere; tproxy only in builds
	# compiled with it. Treat anything other than tproxy as redirect.
	[ "$mode" = "tproxy" ] || mode=redirect

	# Sets shared with chinadns-ng (filled at runtime). Built with cat (busybox
	# ash lacks `read -d`).
	local sets
	sets=$(cat <<EOF
flush table inet ${NFT_TABLE}
table inet ${NFT_TABLE} {
	set bypass_chn {
		type ipv4_addr
		size 65536
		flags timeout
	}
	set bypass_chn6 {
		type ipv6_addr
		size 65536
		flags timeout
	}
	set bypass_vps {
		type ipv4_addr
		size 1024
	}
	set bypass_vps6 {
		type ipv6_addr
		size 1024
	}
EOF
)

	local nat_chain="" mangle_chain=""
	# Redirect mode: NAT PREROUTING REDIRECT for TCP.
	if [ "$mode" = "redirect" ] && [ -n "$tcp_expr" ]; then
		nat_chain="chain prerouting { type nat hook prerouting priority -100; policy accept;
			ip daddr @bypass_vps accept
			ip daddr @bypass_chn accept
			iif lo accept
			meta l4proto tcp tcp dport { ${tcp_expr} } redirect to :${REDIR_PORT}
		}"
	fi
	# TProxy mode: mangle PREROUTING TPROXY for TCP+UDP (needs the local-route setup).
	if [ "$mode" = "tproxy" ]; then
		[ -n "$tcp_expr" ] && mangle_chain="chain prerouting { type filter hook prerouting priority mangle; policy accept;
			ip daddr @bypass_vps accept
			ip daddr @bypass_chn accept
			iif lo accept
			meta l4proto { tcp } tcp dport { ${tcp_expr} } tproxy ip to 127.0.0.1:${REDIR_PORT} mark set 0x1 accept
		}"
		[ -n "$udp_expr" ] && mangle_chain="${mangle_chain}
		chain prerouting_udp { type filter hook prerouting priority mangle; policy accept;
			ip daddr @bypass_vps accept
			ip daddr @bypass_chn accept
			iif lo accept
			meta l4proto udp udp dport { ${udp_expr} } tproxy ip to 127.0.0.1:${REDIR_PORT} mark set 0x1 accept
		}"
		# TProxy needs a local route so marked packets are delivered locally.
		ip rule add fwmark 1 lookup 100 2>/dev/null || ip rule replace fwmark 1 lookup 100
		ip route replace local 0.0.0.0/0 dev lo table 100 2>/dev/null
	fi

	# OUTPUT chain: keep locally-originated traffic to the naive server from
	# looping back into the redirect (naive -> server must egress directly).
	local out_chain="chain output { type route hook output priority mangle; policy accept;
		ip daddr @bypass_vps accept
		ip daddr @bypass_chn accept
	}"

	local ruleset="${sets}
	${nat_chain}
	${mangle_chain}
	${out_chain}
	}"
	nft_apply "$ruleset" || { log 0 "nft ruleset apply failed."; return 1; }

	# Pre-populate bypass_vps with resolved node server IPs (always-direct).
	local ip
	[ -s "$TMP_ACL_PATH/vpslist" ] && for ip in $(cat "$TMP_ACL_PATH/vpslist" 2>/dev/null); do
		local resolved
		resolved=$(get_host_ip ipv4 "$ip" 2>/dev/null)
		[ -n "$resolved" ] && $NFT add element inet ${NFT_TABLE} bypass_vps "{ $resolved }" 2>/dev/null
	done

	egress_mark_start
	gen_include
	log 0 "nftables ruleset installed (mode=%s, redir_port=%s)." "$mode" "$REDIR_PORT"
}

egress_mark_start() {
	local iface fwmark table
	iface=$(get_cache_var EGRESS_IFACE)
	fwmark=${NAIVE_EGRESS_FWMARK:-$(get_cache_var EGRESS_FWMARK)}
	table=${NAIVE_EGRESS_TABLE:-$(get_cache_var EGRESS_TABLE)}
	[ -z "$iface" ] && return 0
	[ -z "$fwmark" ] && fwmark=0x2
	[ -z "$table" ] && table=200

	local ruleset="flush table inet ${NFT_EGRESS_TABLE}
table inet ${NFT_EGRESS_TABLE} {
	set bypass_uplink {
		type ipv4_addr
		size 1024
	}
	chain output {
		type route hook output priority mangle; policy accept
		ip daddr @bypass_uplink meta mark set ${fwmark}
		ip daddr @bypass_uplink ct mark set ${fwmark}
	}
}"
	nft_apply "$ruleset" 2>/dev/null
	refresh_uplink
}

# Repopulate bypass_uplink from $TMP_PATH/uplink_ips. Called on start, on
# rule_update and on hotplug ifupdate.
refresh_uplink() {
	[ -z "$NFT" ] && return 0
	$NFT flush set inet ${NFT_EGRESS_TABLE} bypass_uplink 2>/dev/null
	[ -s "$TMP_PATH/uplink_ips" ] || return 0
	local ips="" ip
	while read -r ip; do
		[ -n "$ip" ] && ips="${ips:+$ips, }$ip"
	done < "$TMP_PATH/uplink_ips"
	[ -n "$ips" ] && $NFT add element inet ${NFT_EGRESS_TABLE} bypass_uplink "{ $ips }" 2>/dev/null
}

egress_mark_stop() {
	$NFT delete table inet ${NFT_EGRESS_TABLE} 2>/dev/null
}

nft_stop() {
	[ -z "$NFT" ] && return 0
	egress_mark_stop
	$NFT delete table inet ${NFT_TABLE} 2>/dev/null
	# Remove tproxy local-route scaffolding if present.
	ip rule del fwmark 1 lookup 100 2>/dev/null
	ip route flush table 100 2>/dev/null
	rm -f "$INCLUDE_FILE" 2>/dev/null
	log 0 "nftables ruleset removed."
}

# Write the fw4 include script so the ruleset survives firewall reloads.
nft_gen_include() {
	mkdir -p "$(dirname "$INCLUDE_FILE")"
	cat <<-EOF > "$INCLUDE_FILE"
		#!/bin/sh
		nft 'flush table inet ${NFT_TABLE}' 2>/dev/null
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
	refresh_uplink
}

# Dispatch (app.sh sources this file then calls $1, or we dispatch on $1 directly).
case "${1:-start}" in
	start)        nft_start ;;
	stop)         nft_stop ;;
	gen_include)  nft_gen_include ;;
	update_wan_sets) nft_update_wan_sets ;;
	refresh_uplink) refresh_uplink ;;
esac
