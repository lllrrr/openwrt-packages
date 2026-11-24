#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
RELAY="$ROOT/package/luci-app-upnp-nat-relay/root/usr/bin/upnp-nat-relay"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

awk '
    $0 == "load_config() {" || $0 == "port_in_deny_list() {" { copy=1 }
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
            upnp_nat_relay.main.downstream_lan_subnet) printf '11.0.2.0/24\n' ;;
            upnp_nat_relay.main.upstream_wan_if) printf 'eth0\n' ;;
            upnp_nat_relay.default.port)
                [ -n "${MOCK_DENY_PORTS:-}" ] || exit 1
                printf '%s\n' "$MOCK_DENY_PORTS"
                ;;
            upnp_nat_relay.default.port.*)
                # Real libuci list options are read as one value; `.0` is not an item.
                exit 1
                ;;
            *) exit 1 ;;
        esac
        ;;
    show)
        [ "${2:-}" = "upnp_nat_relay" ] || exit 2
        printf "upnp_nat_relay.main=service\n"
        printf "upnp_nat_relay.main.bind_ip='11.0.1.1'\n"
        printf "upnp_nat_relay.main.downstream_lan_subnet='11.0.2.0/24'\n"
        printf "upnp_nat_relay.main.upstream_wan_if='eth0'\n"
        [ -n "${MOCK_DENY_PORTS:-}" ] || exit 0
        # libuci serializes a list option as one line of quoted items.
        _line=""
        for _p in $MOCK_DENY_PORTS; do
            _line="${_line:+${_line} }'${_p}'"
        done
        printf "upnp_nat_relay.default.port=%s\n" "$_line"
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

MOCK_DENY_PORTS='22 443 8443'
export MOCK_DENY_PORTS
load_config
[ "$cfg_deny_ports" = '22 443 8443' ]
port_in_deny_list 443 || { echo 'FAIL: configured denied port was not applied' >&2; exit 1; }
if port_in_deny_list 55005; then
	echo 'FAIL: an unrelated port was denied' >&2
	exit 1
fi

MOCK_DENY_PORTS='8443 55000'
export MOCK_DENY_PORTS
load_config
[ "$cfg_deny_ports" = '8443 55000' ]
port_in_deny_list 8443 || { echo 'FAIL: custom list item was lost' >&2; exit 1; }
port_in_deny_list 55000 || { echo 'FAIL: custom high port was lost' >&2; exit 1; }
if port_in_deny_list 443; then
	echo 'FAIL: stale default deny list replaced the configured list' >&2
	exit 1
fi

MOCK_DENY_PORTS=''
export MOCK_DENY_PORTS
load_config
case " $cfg_deny_ports " in *' 443 '*|*' 8443 '*) ;; *) echo 'FAIL: safe defaults were not restored when the list is absent' >&2; exit 1 ;; esac
port_in_deny_list 443 || { echo 'FAIL: default port 443 was not denied' >&2; exit 1; }
port_in_deny_list 8443 || { echo 'FAIL: default port 8443 was not denied' >&2; exit 1; }

echo 'PASS: libuci-style list read honors configured ports and retains safe defaults when absent'
EOF
chmod +x "$TMP/runner.sh"
PATH="$TMP/bin:$PATH" "$TMP/runner.sh" "$TMP/functions.sh"
