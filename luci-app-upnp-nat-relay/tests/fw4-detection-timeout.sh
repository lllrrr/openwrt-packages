#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
RELAY="$ROOT/package/luci-app-upnp-nat-relay/root/usr/bin/upnp-nat-relay"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

if ! command -v timeout >/dev/null 2>&1; then
	echo 'SKIP: timeout utility is required (provided by coreutils-timeout)' >&2
	exit 77
fi

mkdir -p "$TMP/bin"
sed -n '/^detect_firewall() {/,/^}/p' "$RELAY" |
	sed 's/timeout -k 1s 5s fw4/timeout -k 1s 1s fw4/' > "$TMP/detect-firewall.sh"

cat > "$TMP/bin/nft" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$TMP/bin/fw4" <<'EOF'
#!/bin/sh
exec sleep 30
EOF
chmod +x "$TMP/bin/nft" "$TMP/bin/fw4"

result="$(PATH="$TMP/bin:$PATH" timeout 8 sh -c '. "$1"; detect_firewall' sh "$TMP/detect-firewall.sh")"
if [ "$result" != "nftables_only$(printf '\t')1$(printf '\t')1" ]; then
	echo "FAIL: hung fw4 should time out and preserve nft detection; got: $result" >&2
	exit 1
fi

cat > "$TMP/bin/fw4" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$TMP/bin/fw4"
result="$(PATH="$TMP/bin:$PATH" timeout 8 sh -c '. "$1"; detect_firewall' sh "$TMP/detect-firewall.sh")"
if [ "$result" != "fw4$(printf '\t')1$(printf '\t')1" ]; then
	echo "FAIL: successful fw4 detection changed; got: $result" >&2
	exit 1
fi

echo 'PASS: fw4 detection is bounded and retains nft fallback'
