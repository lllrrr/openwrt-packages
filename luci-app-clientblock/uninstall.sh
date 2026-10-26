#!/bin/sh
# Removes luci-app-clientblock files and state.

[ "$(id -u)" = "0" ] || { echo "error: must run as root"; exit 1; }

echo "==> stopping service"
/etc/init.d/clientblock stop    >/dev/null 2>&1 || true
/etc/init.d/clientblock disable >/dev/null 2>&1 || true

echo "==> removing files"
rm -f  /usr/libexec/rpcd/luci.clientblock
rm -f  /usr/sbin/clientblock-watch
rm -f  /etc/init.d/clientblock
rm -f  /www/luci-static/resources/view/clientblock.js
rm -f  /usr/share/luci/menu.d/luci-app-clientblock.json
rm -f  /usr/share/rpcd/acl.d/luci-app-clientblock.json
rm -f  /etc/nftables.d/90-clientblock.nft
rm -f  /tmp/clientblock-hits

echo "==> removing state (blocked lists and names)"
rm -rf /etc/clientblock

echo "==> reloading services"
fw4 reload >/dev/null 2>&1 || true
/etc/init.d/rpcd restart >/dev/null 2>&1 || true

echo "Removed."
