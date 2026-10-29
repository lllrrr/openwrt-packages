#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Generate a runtime mixin; downloaded subscription files remain untouched.
traffic_profile() {
	local source=$1 target=$2 enabled=${3:-$(uci -q get tidynet.main.traffic_enabled)}
	command -v yq >/dev/null 2>&1 || return 1
	if [ "$enabled" = 1 ]; then
		[ -c /dev/net/tun ] || { modprobe tun 2>/dev/null; [ -c /dev/net/tun ]; } || return 1
		yq eval '.tun = {"enable": true, "device": "tidynet-tun", "stack": "mixed", "mtu": 1500, "auto-route": true, "auto-redirect": true, "auto-detect-interface": true, "strict-route": false, "dns-mode": "disabled", "dns-hijack": [], "route-exclude-address": ["0.0.0.0/8", "10.0.0.0/8", "127.0.0.0/8", "169.254.0.0/16", "172.16.0.0/12", "192.168.0.0/16", "224.0.0.0/4", "::1/128", "fc00::/7", "fe80::/10"]} | .sniffer.enable = true | .sniffer."parse-pure-ip" = true | .sniffer.sniff = (.sniffer.sniff // {"HTTP": {"ports": [80, 8080]}, "TLS": {"ports": [443, 8443]}, "QUIC": {"ports": [443, 8443]}})' "$source" > "$target.new" || return 1
	else
		yq eval '.tun.enable = false' "$source" > "$target.new" || return 1
	fi
	if [ "$enabled" = 1 ] && [ "$(uci -q get tidynet.main.tcp_mode)" != redirect ] && [ -n "$(uci -q get tidynet.main.tcp_mode)" ]; then
		yq eval -i '.tun."auto-redirect" = false' "$target.new" || return 1
	fi
	chmod 600 "$target.new" && mv "$target.new" "$target"
}

traffic_clear_policy() {
	ip -4 rule del priority 8988 ipproto tcp table main 2>/dev/null || :
	ip -4 rule del priority 8989 ipproto udp table main 2>/dev/null || :
}

traffic_apply_policy() {
	traffic_clear_policy
	[ "$(uci -q get tidynet.main.traffic_enabled)" = 1 ] || return 0
	[ "$(uci -q get tidynet.main.tcp_mode)" != direct ] || ip -4 rule add priority 8988 ipproto tcp table main || return 1
	[ "$(uci -q get tidynet.main.udp_mode)" != direct ] || ip -4 rule add priority 8989 ipproto udp table main || return 1
}
