#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
PKG="$ROOT/package/luci-app-upnp-nat-relay"
INIT="$PKG/root/etc/init.d/upnp_nat_relay"
RELAY="$PKG/root/usr/bin/upnp-nat-relay"
MAKEFILE="$PKG/Makefile"

if grep -q 'procd_set_param file /etc/config/upnp_nat_relay' "$INIT"; then
	echo 'FAIL: relay UCI file watch can restart the process during a hot config update' >&2
	exit 1
fi

if grep -q 'cfg_openclash_auto_restart.*=.*1' "$RELAY"; then
	echo 'FAIL: legacy auto restart can still invoke an OpenClash restart' >&2
	exit 1
fi

if grep -q "uci -q delete upnp_nat_relay.main.openclash_auto_restart" "$MAKEFILE"; then
	echo 'PASS: upgrade removes the deprecated restart flag'
else
	echo 'FAIL: package upgrade does not migrate the deprecated restart flag' >&2
	exit 1
fi

UI="$PKG/htdocs/luci-static/resources/view/upnp-nat-relay/openclash.js"
for obsolete in '_sync_oc_now' '_generate_rule' '_write_oc' 'openclash_return_strategy' 'openclash_rule_remark' 'openclash_backup' 'openclash_sync_interval'; do
	if grep -q "$obsolete" "$UI"; then
		echo "FAIL: obsolete OpenClash write control remains in LuCI: $obsolete" >&2
		exit 1
	fi
done

for obsolete_label in 'Sync OpenClash Now' 'Generate RETURN Rule' 'Write OpenClash Rule' 'Restart OpenClash manually to apply'; do
	if grep -q "$obsolete_label" "$UI"; then
		echo "FAIL: LuCI still implies an OpenClash write/apply action: $obsolete_label" >&2
		exit 1
	fi
done

grep -q 'Inbound Mapping Compatibility' "$UI" || { echo 'FAIL: LuCI has no inbound compatibility explanation' >&2; exit 1; }
grep -q 'openclash_inbound_bypass_unsupported' "$RELAY" || { echo 'FAIL: backend unsupported error is missing' >&2; exit 1; }
echo 'PASS: LuCI exposes compatibility status and legacy cleanup without unsupported write/sync controls'

if [ "$(grep -c 'openclash_restart_service' "$RELAY")" -ne 2 ]; then
	echo 'FAIL: review OpenClash restart call sites; only the explicit manual action is allowed' >&2
	grep -n 'openclash_restart_service' "$RELAY" >&2 || true
	exit 1
fi

echo 'PASS: UPnP hot apply contract'
