#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
INIT="$ROOT/package/luci-app-upnp-nat-relay/root/etc/init.d/upnp_nat_relay"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

awk '
	$0 == "reload_service() {" { copying = 1 }
	copying { print }
	copying && $0 == "}" { exit }
' "$INIT" > "$TMP/reload.sh"

cat >> "$TMP/reload.sh" <<'EOF'
config_load() { :; }
config_get_bool() { eval "$1=\$TEST_ENABLED"; }
service_running() { [ "$RUNNING" = 1 ]; }
start() { STARTS=$((STARTS + 1)); RUNNING=1; }
stop() { STOPS=$((STOPS + 1)); RUNNING=0; }

reset_case() {
	TEST_ENABLED="$1"
	RUNNING="$2"
	STARTS=0
	STOPS=0
}

reset_case 1 0
reload_service
[ "$STARTS:$STOPS:$RUNNING" = '1:0:1' ] || { echo "FAIL: disabled-to-enabled did not start once: $STARTS:$STOPS:$RUNNING" >&2; exit 1; }

reset_case 1 1
reload_service
[ "$STARTS:$STOPS:$RUNNING" = '0:0:1' ] || { echo "FAIL: enabled reload restarted a running daemon: $STARTS:$STOPS:$RUNNING" >&2; exit 1; }

reset_case 0 1
reload_service
[ "$STARTS:$STOPS:$RUNNING" = '0:1:0' ] || { echo "FAIL: enabled-to-disabled did not stop once: $STARTS:$STOPS:$RUNNING" >&2; exit 1; }

reset_case 0 0
reload_service
[ "$STARTS:$STOPS:$RUNNING" = '0:0:0' ] || { echo "FAIL: disabled reload acted on a stopped daemon: $STARTS:$STOPS:$RUNNING" >&2; exit 1; }

echo 'PASS: enabled transitions start only when stopped and stop only when running'
EOF

sh "$TMP/reload.sh"
