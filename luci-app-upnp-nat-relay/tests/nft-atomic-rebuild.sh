#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
RELAY="$ROOT/package/luci-app-upnp-nat-relay/root/usr/bin/upnp-nat-relay"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

awk '
    $0 == "nft_table_exists() {" || $0 == "nft_ensure_table() {" ||
    $0 == "nft_replace_dnat_rules() {" || $0 == "resolve_interface_device() {" { copy=1 }
    copy { print }
    copy && $0 == "}" { copy=0; print "" }
' "$RELAY" >"$TMP/functions.sh"

cat >>"$TMP/functions.sh" <<'EOF'
EOF

mkdir -p "$TMP/bin"
cat >"$TMP/bin/ip" <<'EOF'
#!/bin/sh
exit 0
EOF
cat >"$TMP/bin/nft" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$NFT_CALLS"
case "$*" in
    "list table inet upnp_nat_relay"|"list chain inet upnp_nat_relay prerouting") exit 0 ;;
    *) ;;
esac
if [ "$1" = "-c" ] && [ "$2" = "-f" ]; then cat "$3" >"$NFT_BATCH"; exit 0; fi
if [ "$1" = "-f" ]; then
    [ "${NFT_FAIL_COMMIT:-0}" = 0 ]
    exit $?
fi
case "$*" in
    *) exit 0 ;;
esac
EOF
chmod +x "$TMP/bin/ip" "$TMP/bin/nft"

cat >"$TMP/accepted.txt" <<'EOF'
ACCEPT|tcp|50001|192.0.2.10|50001|tcp mapping
ACCEPT|udp|50002|192.0.2.11|50002|udp mapping
REJECT|tcp|50003|192.0.2.12|50003|filtered mapping
EOF

export PATH="$TMP/bin:$PATH" NFT_CALLS="$TMP/calls" NFT_BATCH="$TMP/batch"
NFT_TABLE_NAME=upnp_nat_relay NFT_CHAIN=prerouting NFT_RULE_COMMENT=upnp_nat_relay_dnat
resolve_interface_device() { printf '%s' "$1"; }
. "$TMP/functions.sh"

added="$(nft_replace_dnat_rules "$TMP/accepted.txt" 192.0.2.2 eth0)"
[ "$added" = 2 ]
[ "$(grep -c '^add rule ' "$NFT_BATCH")" = 2 ]
grep -q '^flush chain inet upnp_nat_relay prerouting$' "$NFT_BATCH"
grep -q 'iifname "eth0" tcp dport 50001 dnat ip to 192.0.2.2:50001' "$NFT_BATCH"
grep -q 'iifname "eth0" udp dport 50002 dnat ip to 192.0.2.2:50002' "$NFT_BATCH"
[ "$(grep -Ec '(^| )-f ' "$NFT_CALLS")" = 2 ]

: >"$NFT_CALLS"
if NFT_FAIL_COMMIT=1 nft_replace_dnat_rules "$TMP/accepted.txt" 192.0.2.2 eth0 >/dev/null; then
	 echo 'FAIL: a rejected nft batch reported success' >&2
	 exit 1
fi
[ "$(grep -c 'flush chain' "$NFT_BATCH")" = 1 ]
[ "$(grep -Ec '(^| )-f ' "$NFT_CALLS")" = 2 ]

if nft_replace_dnat_rules "$TMP/accepted.txt" '192.0.2.2; flush ruleset' eth0 >/dev/null; then
	echo 'FAIL: untrusted destination escaped address validation' >&2
	exit 1
fi

echo 'PASS: relay DNAT replacement is one validated nft transaction and leaves failure handling atomic'
