#!/bin/sh
# Copyright (c) 2026 Eugene Chan
# SPDX-License-Identifier: MIT
#
# nftables transparent-proxy backend for luci-app-bypass.
#
# One table is managed:
#   table inet bypass        - the redirect/tproxy ruleset + direct-DNS and
#                              bypass_vps sets (filled by static resolution and
#                              BypassCore's native DNS-result writer).
#
# Sources utils.sh (via app.sh) for $REDIR_PORT, $TCP_PROXY_WAY,
# $TCP_REDIR_PORTS and cache helpers.

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
	PROXY_IPV6=$(config_t_get global_forwarding ipv6_tproxy 0)
	ACCEPT_ICMP=$(config_t_get global_forwarding accept_icmp 0)
	CLIENT_PROXY=$(config_t_get global client_proxy 1)
	DNS_REDIRECT=$(config_t_get global dns_redirect 1)
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

# Import a potentially large CIDR list with one nft process instead of spawning
# one process per element. Commands are split into moderate-sized batches while
# nft still applies the file as one transaction.
nft_import_elements() {
	local set_name input unique batch
	set_name=$1
	input=$2
	unique="${input}.unique"
	batch="${input}.nft"
	[ -s "$input" ] || return 0
	# Drop anything that is not a valid IPv4/IPv6 address or CIDR. Mirrors the
	# passwall2 defence-in-depth: a fused record such as "223.255.252.0/230.0.0.0/8"
	# (two CIDRs with no separating newline) fails the single-/ rule and is
	# discarded before it can abort "nft -f". Octet range and prefix length are
	# left to nft; this is structural filtering only. The IPv6 branch accepts
	# compressed forms (::, ::1, 2001:db8::/32) and IPv4-mapped tails (::ffff:1.2.3.4)
	# because it allows hex groups, colons and dots with an optional /prefix.
	grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$|^([0-9A-Fa-f]{1,4}:)+[0-9A-Fa-f:.]*(/[0-9]{1,3})?$|^[0-9A-Fa-f:.]*:[0-9A-Fa-f:.]*(/[0-9]{1,3})?$' "$input" \
		| sort -u > "$unique" || return 1
	awk -v table="$NFT_TABLE" -v set_name="$set_name" '
		# Treat any run of whitespace as a record separator (passwall2 style) so
		# splitting never depends on a trailing newline: even if grep lets a line
		# through whose final newline is missing, it cannot fuse with the next one.
		BEGIN { RS = "[ \t\n\r]+" }
		NF {
			gsub(/\r/, "")
			# BusyBox awk commonly limits one output record to about 4 KiB. Keep
			# each nft command comfortably below that limit, including IPv6 CIDRs.
			if (count % 32 == 0) {
				if (count > 0) print " }"
				printf "add element inet %s %s { ", table, set_name
			} else {
				printf ", "
			}
			printf "%s", $0
			count++
		}
		END { if (count > 0) print " }" }
	' "$unique" > "$batch" || return 1
	$NFT -f "$batch" 2>>"$LOG_FILE"
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

	local tcp_expr tcp_no_expr udp_no_expr
	tcp_expr=$(nft_port_expr "$TCP_REDIR_PORTS") || return 1
	tcp_no_expr=$(nft_port_expr "$TCP_NO_REDIR_PORTS") || return 1
	udp_no_expr=$(nft_port_expr "$UDP_NO_REDIR_PORTS") || return 1

	local mode=$TCP_PROXY_WAY
	local wireguard_active=0
	[ -s "$TMP_PATH/selected_wireguard_nodes" ] && wireguard_active=1
	# naive upstream builds support redir everywhere; tproxy only in builds
	# compiled with it. Treat anything other than tproxy as redirect.
	[ "$mode" = "tproxy" ] || mode=redirect
	# IPv6 transparent proxying is only possible through TPROXY. Enabling it
	# therefore moves the shared IPv4 listener to TPROXY as well.
	[ "$PROXY_IPV6" = "1" ] && mode=tproxy

	# Sets shared with BypassCore (filled at runtime). Keep router-local
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
	set bypass_direct {
		type ipv4_addr
		size 1048576
		flags interval
		auto-merge
	}
	set bypass_direct6 {
		type ipv6_addr
		size 1048576
		flags interval
		auto-merge
	}
	set bypass_dns {
		type ipv4_addr
		size 32
	}
	set bypass_direct_dns {
		type ipv4_addr
		size 65536
		flags interval, timeout
		auto-merge
	}
	set bypass_direct_dns6 {
		type ipv6_addr
		size 65536
		flags interval, timeout
		auto-merge
	}
	set bypass_vps {
		type ipv4_addr
		size 1024
		flags interval, timeout
	}
	set bypass_vps6 {
		type ipv6_addr
		size 1024
		flags interval, timeout
	}
EOF
)

	local wan_accept="" wan_devices="" dev
	for dev in $({ ip -o -4 route show default; ip -o -6 route show default; } 2>/dev/null | awk '{ for (i=1; i<=NF; i++) if ($i == "dev") print $(i+1) }' | sort -u); do
		wan_devices="${wan_devices:+$wan_devices, }\"$dev\""
	done
	[ -n "$wan_devices" ] && wan_accept="iifname { ${wan_devices} } accept"
	local direct_accept="ip daddr @bypass_direct accept"
	local direct6_accept="ip6 daddr @bypass_direct6 accept"
	# Never accept a connection solely because a previous DNS answer placed its
	# destination in bypass_direct_dns. IP addresses are shared by unrelated CDN
	# hostnames, and an IP-only fast path cannot preserve BypassCore's ordered
	# Proxy/Block/Direct domain semantics. The sets are still populated for
	# compatibility and diagnostics, but BypassCore remains the routing authority.
	if { [ "$WRITE_IPSET_DIRECT" = "1" ] || [ "$ENABLE_GEOVIEW_IP" = "1" ]; }; then
		log 0 "Direct DNS/GeoIP NFTSets are informational; ordered traffic decisions remain inside BypassCore."
	fi

	local nat_chain="" udp_guard_chain="" mangle_chain="" mangle6_chain="" tcp_redirect_rule="" icmp_redirect_rule="" dns_redirect_rule="" dns_tproxy_bypass="" tcp_no_redir_rule="" udp_no_redir_rule=""
	# REDIRECT mode uses NAT PREROUTING for TCP. ICMP hijacking is implemented
	# in the same NAT base chain and makes the router answer matching IPv4 pings,
	# matching Passwall2's nftables behavior without sending ICMP to BypassCore.
	if [ "$CLIENT_PROXY" = "1" ] && [ "$mode" = "redirect" ] && [ -n "$tcp_expr" ]; then
		# This is an inet-family chain. Restrict the IPv4 listener explicitly;
		# otherwise IPv6 TCP can also hit REDIRECT while no IPv6 inbound exists.
		tcp_redirect_rule="meta nfproto ipv4 meta l4proto tcp tcp dport { ${tcp_expr} } redirect to :${REDIR_PORT}"
	fi
	if [ "$CLIENT_PROXY" = "1" ] && [ "$ACCEPT_ICMP" = "1" ]; then
		icmp_redirect_rule="ip protocol icmp redirect"
	fi
	# Build the no-redirect exclusion rule as a standalone variable. The port-set
	# braces must not be embedded inside a ${var:+...} expansion: ash/dash (and
	# bash) close the expansion at the first '}' after the nested ${...}, leaving
	# a dangling "accept}" that breaks the nft ruleset.
	[ -n "$tcp_no_expr" ] && tcp_no_redir_rule="meta l4proto tcp tcp dport { ${tcp_no_expr} } accept"
	[ -n "$udp_no_expr" ] && udp_no_redir_rule="meta l4proto udp udp dport { ${udp_no_expr} } accept"
	if [ "$CLIENT_PROXY" = "1" ] && [ "$DNS_REDIRECT" = "1" ]; then
		# Match Passwall2's DNS Redirect semantics: LAN clients using a hardcoded
		# port-53 resolver are sent to the router's dnsmasq, whose upstream is the
		# validated BypassCore DNS listener. WAN and router-local input are exempted
		# before this rule.
		dns_redirect_rule="meta l4proto { tcp, udp } th dport 53 redirect to :53"
		dns_tproxy_bypass="meta l4proto { tcp, udp } th dport 53 accept"
	fi
	# Without a selected WireGuard outbound, NaiveProxy's lack of UDP support
	# keeps the strict fail-closed guard. With WireGuard, UDP is sent to the
	# native BypassCore TPROXY listener below and routed by the same rule order.
	local udp_dns_accept=""
	[ "$DNS_REDIRECT" = "1" ] && udp_dns_accept="meta l4proto udp udp dport 53 accept"
	if [ "$CLIENT_PROXY" = "1" ] && [ "$wireguard_active" != "1" ]; then
		udp_guard_chain="chain udp_guard { type filter hook prerouting priority -151; policy accept;
			meta l4proto != udp accept
			${wan_accept}
			iif lo accept
			# DHCP broadcast must not depend on the user-editable Direct IP list.
			ip daddr 255.255.255.255 udp sport 68 udp dport 67 accept
			ip daddr @bypass_local accept
			ip6 daddr @bypass_local6 accept
			${direct_accept}
			${direct6_accept}
			${udp_dns_accept}
			${udp_no_redir_rule}
			counter drop comment \"bypass: NaiveProxy has no UDP support\"
		}"
		if [ -n "$udp_no_expr" ]; then
			log 0 "UDP No Redir Ports [%s] go Direct and may expose the real egress IP; other forwarded external UDP is blocked." "$UDP_NO_REDIR_PORTS"
		else
			log 0 "UDP strict mode: forwarded external UDP is blocked to prevent NaiveProxy bypass."
		fi
	elif [ "$CLIENT_PROXY" = "1" ]; then
		log 0 "WireGuard UDP mode: forwarded UDP is routed through BypassCore; NaiveProxy UDP routes fail closed."
		if [ "$PROXY_IPV6" != "1" ]; then
			udp_guard_chain="chain udp_guard6 { type filter hook prerouting priority -151; policy accept;
				meta l4proto != udp accept
				meta nfproto != ipv6 accept
				${wan_accept}
				iif lo accept
				ip6 daddr @bypass_local6 accept
				${direct6_accept}
				${udp_dns_accept}
				${udp_no_redir_rule}
				counter drop comment \"bypass: IPv6 UDP proxying is disabled\"
			}"
		fi
	fi
	if [ -n "$tcp_redirect_rule" ] || [ -n "$icmp_redirect_rule" ] || [ -n "$dns_redirect_rule" ]; then
		nat_chain="chain prerouting { type nat hook prerouting priority -100; policy accept;
			ip daddr @bypass_local accept
			${wan_accept}
			iif lo accept
			${dns_redirect_rule}
			ip daddr @bypass_vps accept
			${direct_accept}
			ip daddr @bypass_dns meta l4proto { tcp, udp } th dport 53 accept
			${tcp_no_redir_rule}
			${tcp_redirect_rule}
			${icmp_redirect_rule}
		}"
	fi
	# TPROXY is used for TCP when selected globally and independently for UDP
	# whenever a WireGuard node is active.
	local tcp_tproxy_rule="" udp_tproxy_rule="" tcp6_tproxy_rule="" udp6_tproxy_rule=""
	if [ "$CLIENT_PROXY" = "1" ] && [ "$mode" = "tproxy" ] && [ -n "$tcp_expr" ]; then
		tcp_tproxy_rule="meta nfproto ipv4 meta l4proto tcp tcp dport { ${tcp_expr} } tproxy ip to 127.0.0.1:${REDIR_PORT} meta mark set meta mark | 0x10000 accept"
		[ "$PROXY_IPV6" = "1" ] && \
			tcp6_tproxy_rule="meta l4proto tcp tcp dport { ${tcp_expr} } tproxy ip6 to [::1]:${REDIR_PORT} meta mark set meta mark | 0x10000 accept"
	fi
	if [ "$CLIENT_PROXY" = "1" ] && [ "$wireguard_active" = "1" ]; then
		udp_tproxy_rule="meta nfproto ipv4 meta l4proto udp tproxy ip to 127.0.0.1:${REDIR_PORT} meta mark set meta mark | 0x10000 accept"
		[ "$PROXY_IPV6" = "1" ] && \
			udp6_tproxy_rule="meta l4proto udp tproxy ip6 to [::1]:${REDIR_PORT} meta mark set meta mark | 0x10000 accept"
	fi
	if [ -n "$tcp_tproxy_rule$udp_tproxy_rule" ]; then
		mangle_chain="chain tproxy_prerouting { type filter hook prerouting priority mangle; policy accept;
			ip daddr @bypass_vps accept
			ip daddr @bypass_local accept
			${direct_accept}
			ip daddr @bypass_dns meta l4proto { tcp, udp } th dport 53 accept
			${wan_accept}
			iif lo accept
			${dns_tproxy_bypass}
			${tcp_no_redir_rule}
			${udp_no_redir_rule}
			${tcp_tproxy_rule}
			${udp_tproxy_rule}
		}"
		if [ "$PROXY_IPV6" = "1" ] && [ -n "$tcp6_tproxy_rule$udp6_tproxy_rule" ]; then
			mangle6_chain="chain tproxy_prerouting6 { type filter hook prerouting priority mangle; policy accept;
				ip6 daddr @bypass_vps6 accept
				ip6 daddr @bypass_local6 accept
				${direct6_accept}
				${wan_accept}
				iif lo accept
				${dns_tproxy_bypass}
				${tcp_no_redir_rule}
				${udp_no_redir_rule}
				${tcp6_tproxy_rule}
				${udp6_tproxy_rule}
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
	${udp_guard_chain}
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

	# Passwall2-style Direct IP List: literal prefixes and geoip:CODE entries are
	# inserted into sets matched before REDIRECT/TPROXY, so they never enter the
	# transparent core. Keep the editable source as an opkg conffile.
	local direct_file=/usr/share/bypass/direct_ip direct4_file="$TMP_PATH2/direct-ip4" direct6_file="$TMP_PATH2/direct-ip6" direct_entry direct_code lan_device
	: > "$direct4_file"
	: > "$direct6_file"
	if [ -s "$direct_file" ]; then
		while IFS= read -r direct_entry || [ -n "$direct_entry" ]; do
			direct_entry=$(printf '%s' "$direct_entry" | sed 's/\r$//;s/^[[:space:]]*//;s/[[:space:]]*$//')
			case "$direct_entry" in
				''|'#'*) continue ;;
				geoip:*)
					direct_code=${direct_entry#geoip:}
					get_geoip "$direct_code" ipv4 >> "$direct4_file"
					get_geoip "$direct_code" ipv6 >> "$direct6_file"
					;;
				*:*) printf '%s\n' "$direct_entry" >> "$direct6_file" ;;
				*) printf '%s\n' "$direct_entry" >> "$direct4_file" ;;
			esac
		done < "$direct_file"
	fi
	# Like current Passwall2, always protect the actual LAN interface prefixes
	# even when the user customizes the static list. Resolve the runtime netifd
	# device instead of relying on the obsolete network.lan.ifname state key.
	network_flush_cache 2>/dev/null
	network_get_device lan_device lan 2>/dev/null
	if [ -n "$lan_device" ]; then
		ip -o -4 addr show dev "$lan_device" 2>/dev/null | awk '{print $4}' >> "$direct4_file"
		ip -o -6 addr show dev "$lan_device" 2>/dev/null | awk '{print $4}' >> "$direct6_file"
	fi
	if ! nft_import_elements bypass_direct "$direct4_file" || \
	   ! nft_import_elements bypass_direct6 "$direct6_file"; then
		$NFT delete table inet ${NFT_TABLE} 2>/dev/null
		log 0 "Direct IP List could not be loaded; removed the incomplete nftables ruleset."
		return 1
	fi

	# Pre-populate bypass_vps only for active node server IPs (literal or
	# resolved), so unused node definitions do not consume DNS work or set space.
	# This also protects a future router-OUTPUT implementation from recursion.
	local ip node address direct_dns
	while IFS= read -r node; do
		[ -n "$node" ] || continue
		address=$(config_n_get "$node" address)
		for ip in $(resolve_all_ipv4 "$address"); do
			[ -n "$ip" ] && $NFT add element inet ${NFT_TABLE} bypass_vps "{ $ip }" 2>/dev/null
		done
		for ip in $(resolve_all_ipv6 "$address"); do
			[ -n "$ip" ] && $NFT add element inet ${NFT_TABLE} bypass_vps6 "{ $ip }" 2>/dev/null
		done
	done < "$TMP_PATH/selected_nodes"
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

	# Optionally parse Direct-rule GeoIP entries into informational interval sets.
	# These sets are intentionally not accepted before BypassCore: an IP-only
	# shortcut cannot preserve ordered domain rules or distinguish shared CDN IPs.
	if [ "$ENABLE_GEOVIEW_IP" = "1" ]; then
		local sid ip_rule code geo4_file geo6_file geo4_count geo6_count
		geo4_file="$TMP_PATH2/direct-geoip4"
		geo6_file="$TMP_PATH2/direct-geoip6"
		: > "$geo4_file"
		: > "$geo6_file"
		log 0 "Parsing Direct GeoIP entries into informational nftables sets..."
		for sid in $(shunt_rule_sections); do
			[ "$(config_n_get "$sid" is_default 0)" = "1" ] && continue
			[ "$(config_n_get "$sid" outbound)" = "_direct" ] || continue
			while IFS= read -r ip_rule; do
				case "$ip_rule" in ''|'#'*) continue ;; esac
				case "$ip_rule" in
					geoip:*)
						code=${ip_rule#geoip:}
						get_geoip "$code" ipv4 >> "$geo4_file"
						get_geoip "$code" ipv6 >> "$geo6_file"
						;;
					*:*/*|*:*) printf '%s\n' "$ip_rule" >> "$geo6_file" ;;
					*) printf '%s\n' "$ip_rule" >> "$geo4_file" ;;
				esac
			done <<-EOF
			$(config_n_get "$sid" ip_list)
			EOF
		done
		geo4_count=$(sort -u "$geo4_file" 2>/dev/null | grep -c .)
		geo6_count=$(sort -u "$geo6_file" 2>/dev/null | grep -c .)
		if nft_import_elements bypass_direct_dns "$geo4_file" && nft_import_elements bypass_direct_dns6 "$geo6_file"; then
			log 0 "Direct GeoIP parsing completed: IPv4=%s, IPv6=%s." "$geo4_count" "$geo6_count"
		else
			$NFT flush set inet ${NFT_TABLE} bypass_direct_dns 2>/dev/null
			$NFT flush set inet ${NFT_TABLE} bypass_direct_dns6 2>/dev/null
			log 0 "Direct GeoIP parsing failed; BypassCore remains authoritative."
		fi
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
	for wan in $(get_wan_ips ip4); do
		$NFT add element inet ${NFT_TABLE} bypass_vps "{ $wan }" 2>/dev/null
	done
	for wan in $(get_wan_ips ip6); do
		$NFT add element inet ${NFT_TABLE} bypass_vps6 "{ $wan }" 2>/dev/null
	done
}

nft_start_and_resync() {
	nft_start || return 1
	# A standalone invocation comes from fw4's generated include. The table has
	# just been recreated, so refresh BypassCore's set metadata and invalidate
	# its writer-side TTL dedupe state before accepting later DNS results.
	if [ -z "${BYPASS_NFT_ACTION:-}" ] && \
	   [ "$(config_t_get global enabled 0)" = "1" ] && process_alive bypasscore; then
		if ! bypasscore_control_request POST /v1/dns/nftsets/probe "" >/dev/null 2>&1; then
			log 0 "Firewall reloaded, but BypassCore could not resynchronize its DNS-result NFTSets."
			return 1
		fi
	fi
}

# Dispatch. app.sh sets BYPASS_NFT_ACTION before sourcing; standalone invocations
# continue to use their first argument.
case "${BYPASS_NFT_ACTION:-${1:-start}}" in
	start)        nft_start_and_resync ;;
	stop)         nft_stop ;;
	gen_include)  nft_gen_include ;;
	update_wan_sets) nft_update_wan_sets ;;
esac
