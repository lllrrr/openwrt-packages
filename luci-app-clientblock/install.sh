#!/bin/sh
# luci-app-clientblock - client access control for OpenWrt
# Usage: sh install.sh [--no-start]
#
# Installs the plugin from ./root, registers the rpcd plugin, enables the
# service and reloads the firewall. No package manager required.

set -e
HERE=$(cd "$(dirname "$0")" && pwd)
SRC="$HERE/root"

[ -d "$SRC" ] || { echo "error: root/ directory missing next to this script"; exit 1; }

# Accept both the release bundle layout (view inside root/) and the repo layout
# (view under ./htdocs).
if [ ! -f "$SRC/www/luci-static/resources/view/clientblock.js" ]; then
	if [ -f "$HERE/htdocs/luci-static/resources/view/clientblock.js" ]; then
		mkdir -p "$SRC/www/luci-static/resources/view"
		cp "$HERE/htdocs/luci-static/resources/view/clientblock.js" \
		   "$SRC/www/luci-static/resources/view/"
	fi
fi

[ "$(id -u)" = "0" ] || { echo "error: must run as root"; exit 1; }

echo "==> installing files"
# copy the payload over /
(cd "$SRC" && tar -cf - .) | (cd / && tar -xf -)

echo "==> fixing permissions"
chmod 755 /usr/libexec/rpcd/luci.clientblock
chmod 755 /usr/sbin/clientblock-watch
chmod 755 /etc/init.d/clientblock
chmod 644 /www/luci-static/resources/view/clientblock.js
chmod 644 /usr/share/luci/menu.d/luci-app-clientblock.json
chmod 644 /usr/share/rpcd/acl.d/luci-app-clientblock.json

echo "==> preparing state directory"
mkdir -p /etc/clientblock /etc/nftables.d
[ -s /etc/clientblock/blocked_ips.json ] || echo '{}' > /etc/clientblock/blocked_ips.json
[ -s /etc/clientblock/blocked.json ]     || echo '{}' > /etc/clientblock/blocked.json
[ -s /etc/clientblock/names.json ]       || echo '{}' > /etc/clientblock/names.json
chmod 600 /etc/clientblock/*.json 2>/dev/null || true

echo "==> registering rpcd plugin"
/etc/init.d/rpcd restart >/dev/null 2>&1 || true

if [ "$1" = "--no-start" ]; then
	echo "==> skipping service start (--no-start)"
	exit 0
fi

echo "==> enabling service"
/etc/init.d/clientblock enable >/dev/null 2>&1 || true
/etc/init.d/clientblock restart >/dev/null 2>&1 || true

echo "==> reloading firewall"
fw4 reload >/dev/null 2>&1 || /etc/init.d/firewall reload >/dev/null 2>&1 || true

sleep 1
if ubus -S call luci.clientblock status >/dev/null 2>&1; then
	echo "==> OK: plugin is answering on ubus"
else
	echo "==> WARN: ubus did not answer yet, check /etc/init.d/rpcd restart"
fi

echo
echo "Installed. Open LuCI -> Network -> Access Control."
