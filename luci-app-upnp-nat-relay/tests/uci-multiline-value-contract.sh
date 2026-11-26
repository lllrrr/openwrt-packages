#!/bin/sh
# libuci prints a newline inside a quoted value literally. The snapshot parser
# must keep the value intact instead of stopping at the first line.
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
RELAY="$ROOT/package/luci-app-upnp-nat-relay/root/usr/bin/upnp-nat-relay"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

awk '
    $0 == "load_config() {" { copy=1 }
    copy { print }
    copy && $0 == "}" { copy=0; print "" }
' "$RELAY" >"$TMP/functions.sh"

mkdir -p "$TMP/bin"
cat >"$TMP/bin/uci" <<'EOF'
#!/bin/sh
[ "${1:-}" = "-q" ] && shift
case "${1:-}" in
    get)
        case "${2:-}" in
            upnp_nat_relay.main.bind_ip) printf '11.0.1.1\n' ;;
            upnp_nat_relay.main.upstream_wan_if) printf 'first\nsecond\n' ;;
            *) exit 1 ;;
        esac
        ;;
    show)
        [ "${2:-}" = "upnp_nat_relay" ] || exit 2
        printf "upnp_nat_relay.main=service\n"
        printf "upnp_nat_relay.main.bind_ip='11.0.1.1'\n"
        printf "upnp_nat_relay.main.upstream_wan_if='first\nsecond'\n"
        ;;
    *) exit 2 ;;
esac
EOF
chmod +x "$TMP/bin/uci"

cat >"$TMP/runner.sh" <<'EOF'
#!/bin/sh
set -u
UCI_CONFIG=upnp_nat_relay
uci_get() { uci -q get "${UCI_CONFIG}.$1" 2>/dev/null; }
. "$1"
load_config
expected="first
second"
[ "$cfg_upstream_wan_if" = "$expected" ] || {
    printf 'FAIL: multi-line value was truncated: [%s]\n' "$cfg_upstream_wan_if" >&2
    exit 1
}
echo 'PASS: multi-line uci values survive the snapshot parser'
EOF
chmod +x "$TMP/runner.sh"
PATH="$TMP/bin:$PATH" "$TMP/runner.sh" "$TMP/functions.sh"
