#!/bin/sh
# Manage isolated nftables table (inet wrtbox_tun) when active sing-box JSON uses TUN inbound

NFT_TABLE="wrtbox_tun"
ACTIVE_CONF="/etc/wrtbox/active.json"

clean_rules() {
	if command -v nft >/dev/null 2>&1; then
		nft delete table inet "$NFT_TABLE" 2>/dev/null || true
	fi
}

apply_rules() {
	clean_rules
	command -v nft >/dev/null 2>&1 || return 0
	[ -s "$ACTIVE_CONF" ] || return 0

	local tun_ifaces
	tun_ifaces="$(ucode -e '
		let fs = require("fs");
		let raw = fs.readfile(ARGV[0]);
		if (!raw) exit(0);
		let cfg;
		try { cfg = json(raw); } catch (e) { exit(0); }
		if (type(cfg.inbounds) != "array") exit(0);
		let seen = {};
		for (let ib in cfg.inbounds) {
			if (type(ib) == "object" && ib.type == "tun") {
				let iface = ib.interface_name || "tun0";
				if (match(iface, /^[a-zA-Z0-9_.-]{1,15}$/) && !seen[iface]) {
					seen[iface] = true;
					print(iface + "\n");
				}
			}
		}
	' "$ACTIVE_CONF" 2>/dev/null)"

	[ -z "$tun_ifaces" ] && return 0

	{
		echo "table inet ${NFT_TABLE} {"
		echo "  chain input {"
		echo "    type filter hook input priority filter - 5; policy accept;"
		for iface in $tun_ifaces; do
			echo "    iifname \"${iface}\" accept"
		done
		echo "  }"
		echo "  chain forward {"
		echo "    type filter hook forward priority filter - 5; policy accept;"
		for iface in $tun_ifaces; do
			echo "    iifname \"${iface}\" accept"
			echo "    oifname \"${iface}\" accept"
		done
		echo "  }"
		echo "}"
	} | nft -f - 2>/dev/null || true
}

case "$1" in
	apply)
		apply_rules
		;;
	clean)
		clean_rules
		;;
	*)
		echo "Usage: $0 {apply|clean}" >&2
		exit 1
		;;
esac
