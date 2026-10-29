#!/bin/sh
# Removes luci-app-languard files and state.

[ "$(id -u)" = "0" ] || { echo "error: must run as root"; exit 1; }

echo "==> stopping service"
/etc/init.d/languard stop    >/dev/null 2>&1 || true
/etc/init.d/languard disable >/dev/null 2>&1 || true

echo "==> removing files"
rm -f  /usr/libexec/rpcd/luci.languard
rm -f  /usr/sbin/languard-watch
rm -f  /etc/init.d/languard
rm -f  /www/luci-static/resources/view/languard.js
rm -f  /usr/share/luci/menu.d/luci-app-languard.json
rm -f  /usr/share/rpcd/acl.d/luci-app-languard.json
rm -f  /etc/nftables.d/90-languard.nft
rm -f  /tmp/languard-hits

echo "==> removing state (blocked lists and names)"
rm -rf /etc/languard

echo "==> reloading services"
fw4 reload >/dev/null 2>&1 || true
/etc/init.d/rpcd restart >/dev/null 2>&1 || true

echo "Removed."
