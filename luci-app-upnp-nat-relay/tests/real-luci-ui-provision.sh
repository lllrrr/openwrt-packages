#!/usr/bin/env bash
set -euo pipefail

CONTAINER="${1:-upnp-ui-gate}"
PORT="${2:-18083}"
LANG_CODE="${UPNP_UI_LANG:-en}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG="$ROOT/package/luci-app-upnp-nat-relay"

command -v docker >/dev/null || { echo 'missing host command: docker' >&2; exit 1; }
docker exec "$CONTAINER" sh -c 'set -eu; for command in bash jq curl ubus uci openssl; do command -v "$command" >/dev/null; done'

docker cp "$PKG/root/." "$CONTAINER:/"
docker exec "$CONTAINER" mkdir -p /www/luci-static/resources/view/upnp-nat-relay \
	/usr/lib/lua/luci/i18n
docker cp "$PKG/htdocs/luci-static/resources/view/upnp-nat-relay/." \
	"$CONTAINER:/www/luci-static/resources/view/upnp-nat-relay/"
docker cp "$PKG/htdocs/luci-static/resources/upnp-nat-relay/." \
	"$CONTAINER:/www/luci-static/resources/upnp-nat-relay/"

if [ -n "${UPNP_UI_LMO:-}" ]; then
	docker cp "$UPNP_UI_LMO" "$CONTAINER:/usr/lib/lua/luci/i18n/upnp-nat-relay.zh-cn.lmo"
fi

VERSION="$(cat "$ROOT/VERSION")"
RELEASE="$(sed -n 's/^PKG_RELEASE:=//p' "$PKG/Makefile" | head -n1)"
docker exec "$CONTAINER" sh -c "
	set -eu
	chmod +x /usr/bin/upnp-nat-relay /usr/libexec/rpcd/upnp_nat_relay /etc/init.d/upnp_nat_relay
	sed -i 's|@PKG_VERSION@|$VERSION|g; s|@PKG_FULL_VERSION@|$VERSION-r$RELEASE|g' \
		/usr/bin/upnp-nat-relay /usr/libexec/rpcd/upnp_nat_relay \
		/www/luci-static/resources/upnp-nat-relay/utils.js
	uci set upnp_nat_relay.main.enabled='0'
	uci commit upnp_nat_relay
	uci set uhttpd.main.listen_http='127.0.0.1:$PORT'
	uci set uhttpd.main.listen_https=''
	uci set luci.main.mediaurlbase='/luci-static/bootstrap'
	uci set luci.main.lang='$LANG_CODE'
	uci commit uhttpd
	uci commit luci
	rm -rf /tmp/luci-indexcache* /tmp/luci-modulecache*
	/etc/init.d/rpcd restart >/dev/null 2>&1
	/etc/init.d/uhttpd restart >/dev/null 2>&1
"

HASH="$(docker exec "$CONTAINER" openssl passwd -6 -salt upnp-ui-gate "${UPNP_UI_PASSWORD:-upnp-gate}")"
docker exec "$CONTAINER" sh -c "sed -i 's|^root:[^:]*:|root:$HASH:|' /etc/shadow"

for _ in $(seq 1 20); do
	status="$(curl -sS --max-time 3 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/cgi-bin/luci/" 2>/dev/null || true)"
	if [ "$status" = 200 ] || [ "$status" = 302 ] || [ "$status" = 403 ]; then
		break
	fi
	sleep 1
done

rpc_status="$(docker exec "$CONTAINER" ubus call upnp_nat_relay status '{}' 2>/dev/null || true)"
if [ -z "$rpc_status" ]; then
	echo 'upnp_nat_relay status RPC is unavailable' >&2
	docker exec "$CONTAINER" logread -e rpcd 2>/dev/null | tail -40 >&2 || true
	exit 1
fi
printf '%s\n' "$rpc_status"
echo "provisioned $CONTAINER on 127.0.0.1:$PORT lang=$LANG_CODE; service stays disabled"
