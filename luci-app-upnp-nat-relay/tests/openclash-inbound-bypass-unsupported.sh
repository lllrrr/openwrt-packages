#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
RELAY="$ROOT/package/luci-app-upnp-nat-relay/root/usr/bin/upnp-nat-relay"
RPCD="$ROOT/package/luci-app-upnp-nat-relay/root/usr/libexec/rpcd/upnp_nat_relay"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

extract_function() {
	awk -v name="$1" '
		$0 == name "() {" { copying = 1 }
		copying { print }
		copying && $0 == "}" { exit }
	' "$RELAY" >> "$TMP/functions.sh"
}

for function in \
	openclash_inbound_bypass_unsupported \
	openclash_set_lan_ac_traffic_rule \
	openclash_apply \
	openclash_sync_per_mapping \
	openclash_generate_return_rule \
	openclash_generate_per_mapping_rules; do
	extract_function "$function"
done

cat >> "$TMP/functions.sh" <<'EOF'
uci() {
	for _arg in "$@"; do
		case "$_arg" in
			add|set|delete|commit)
				printf '%s\n' "$*" >> "$UCI_MUTATIONS"
				return 0
				;;
		esac
	done
	return 1
}

assert_unsupported() {
	_name="$1"
	shift
	set +e
	_result="$("$@" 2>/dev/null)"
	_rc=$?
	set -e
	case "$_result" in
		*'"action":"unsupported"'*'"error":"openclash_inbound_bypass_unsupported"'*) ;;
		*) echo "FAIL: $_name did not report unsupported: $_result" >&2; exit 1 ;;
	esac
	[ "$_rc" -ne 0 ] || { echo "FAIL: $_name returned success" >&2; exit 1; }
}

assert_unsupported openclash_apply openclash_apply
assert_unsupported openclash_sync_per_mapping openclash_sync_per_mapping /tmp/accepted.txt
assert_unsupported openclash_set_lan_ac_traffic_rule openclash_set_lan_ac_traffic_rule remark 192.0.2.1 50001 tcp eth0
assert_unsupported openclash_generate_return_rule openclash_generate_return_rule
assert_unsupported openclash_generate_per_mapping_rules openclash_generate_per_mapping_rules /tmp/accepted.txt

[ ! -s "$UCI_MUTATIONS" ] || { echo 'FAIL: unsupported path mutated OpenClash UCI' >&2; cat "$UCI_MUTATIONS" >&2; exit 1; }
EOF

mkdir -p "$TMP/bin"
cat > "$TMP/bin/uci" <<'EOF'
#!/bin/sh
for _arg in "$@"; do
	case "$_arg" in
		add|set|delete|commit)
			printf '%s\n' "$*" >> "$UCI_MUTATIONS"
			exit 0
			;;
	esac
done
exit 1
EOF
chmod +x "$TMP/bin/uci"

: > "$TMP/uci-mutations"
UCI_MUTATIONS="$TMP/uci-mutations" . "$TMP/functions.sh"
UCI_MUTATIONS="$TMP/uci-mutations" PATH="$TMP/bin:$PATH" "$RELAY" --setup-openclash > "$TMP/setup.json" || true
case "$(cat "$TMP/setup.json")" in
	*'"action":"unsupported"'*'"error":"openclash_inbound_bypass_unsupported"'*) ;;
	*) echo "FAIL: setup RPC path did not report unsupported: $(cat "$TMP/setup.json")" >&2; exit 1 ;;
esac

UCI_MUTATIONS="$TMP/uci-mutations" PATH="$TMP/bin:$PATH" "$RELAY" --generate-openclash-rule > "$TMP/generate.json" || true
case "$(cat "$TMP/generate.json")" in
	*'"action":"unsupported"'*'"error":"openclash_inbound_bypass_unsupported"'*) ;;
	*) echo "FAIL: rule preview still generated a RETURN rule: $(cat "$TMP/generate.json")" >&2; exit 1 ;;
esac

UCI_MUTATIONS="$TMP/uci-mutations" PATH="$TMP/bin:$PATH" "$RELAY" --sync-openclash > "$TMP/sync.json" || true
case "$(cat "$TMP/sync.json")" in
	*'"action":"unsupported"'*'"error":"openclash_inbound_bypass_unsupported"'*) ;;
	*) echo "FAIL: OpenClash sync did not report the unsupported result: $(cat "$TMP/sync.json")" >&2; exit 1 ;;
esac

sed "s|UPNP_NAT_RELAY_BIN=\"/usr/bin/upnp-nat-relay\"|UPNP_NAT_RELAY_BIN=\"$RELAY\"|" "$RPCD" > "$TMP/rpcd"
chmod +x "$TMP/rpcd"
for method in setup-openclash generate-openclash-rule sync-openclash; do
	UCI_MUTATIONS="$TMP/uci-mutations" PATH="$TMP/bin:$PATH" "$TMP/rpcd" call "$method" > "$TMP/rpc-$method.json"
	case "$(cat "$TMP/rpc-$method.json")" in
		*'"action":"unsupported"'*'"error":"openclash_inbound_bypass_unsupported"'*) ;;
		*) echo "FAIL: rpcd $method did not return the same unsupported contract: $(cat "$TMP/rpc-$method.json")" >&2; exit 1 ;;
	esac
done

if grep -Eq 'callSetupOpenclash|callGenerateOpenclashRule|callSyncOpenclash|method: .(setup-openclash|generate-openclash-rule|sync-openclash)' \
	"$ROOT/package/luci-app-upnp-nat-relay/htdocs/luci-static/resources/view/upnp-nat-relay/openclash.js"; then
	echo 'FAIL: LuCI still invokes an OpenClash rule write or sync RPC' >&2
	exit 1
fi

[ ! -s "$TMP/uci-mutations" ] || { echo 'FAIL: CLI paths mutated OpenClash UCI' >&2; cat "$TMP/uci-mutations" >&2; exit 1; }

if grep -Eq 'nft (add|delete) element inet fw4 localnetwork([[:space:]]|$)|openclash_(inject|remove)_localnetwork' "$RELAY"; then
	echo 'FAIL: relay still mutates OpenClash shared localnetwork without ownership' >&2
	exit 1
fi

echo 'PASS: LuCI hides write/sync RPCs and CLI/rpcd return the same unsupported error without UCI writes'
