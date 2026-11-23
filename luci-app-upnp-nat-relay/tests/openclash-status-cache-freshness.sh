#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
RELAY="$ROOT/package/luci-app-upnp-nat-relay/root/usr/bin/upnp-nat-relay"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

ENV_CACHE_FILE="$TMP/env_cache.json"
export ENV_CACHE_FILE

extract_function() {
	awk -v name="$1" '
		$0 == name "() {" { copying = 1 }
		copying { print }
		copying && $0 == "}" { exit }
	' "$RELAY" >> "$TMP/functions.sh"
}

extract_function refresh_openclash_cache

cat >> "$TMP/functions.sh" <<'EOF'
# Stubbed probes: FAKE_OC holds "installed<TAB>running<TAB>has_ac".
detect_openclash_status() {
	printf '%b' "$FAKE_OC"
}

do_refresh_env() {
	printf '%s\n' '{"openclash_status":"not_installed","openclash_installed":0,"openclash_running":0,"openclash_has_access_control":0,"updated_at":"fresh"}' > "$ENV_CACHE_FILE"
}
EOF

. "$TMP/functions.sh"

# Seed a stale snapshot: OpenClash was down when the daemon last scanned.
seed_stale() {
	cat > "$ENV_CACHE_FILE" <<'EOF'
{"nft_table_status":"present","openclash_status":"installed","version":"1.3.16","openwrt_version":"25.12.6","package_manager":"apk","firewall":"fw4","fw4":1,"nft":1,"upnpc":1,"luci":1,"openclash_installed":1,"openclash_running":0,"openclash_has_access_control":1,"updated_at":"2026-11-22 14:03:15"}
EOF
}

field() {
	sed -n 's/.*"'"$1"'":"\{0,1\}\([^",}]*\)"\{0,1\}.*/\1/p' "$ENV_CACHE_FILE"
}

expect() {
	_name="$1"; _field="$2"; _want="$3"
	_got="$(field "$_field")"
	[ "$_got" = "$_want" ] || {
		echo "FAIL: $_name expected $_field=$_want, got '$_got'" >&2
		cat "$ENV_CACHE_FILE" >&2
		exit 1
	}
}

# 1. OpenClash started after the snapshot was taken: the badge must flip to running.
seed_stale
FAKE_OC='1\t1\t1' refresh_openclash_cache
expect "started" openclash_status running
expect "started" openclash_running 1
expect "started" openclash_installed 1

# 2. OpenClash stops again: back to installed-but-stopped, not "not installed".
seed_stale
sed -i -e 's/"openclash_status":"[^"]*"/"openclash_status":"running"/; s/"openclash_running":[0-9]*/"openclash_running":1/' "$ENV_CACHE_FILE"
FAKE_OC='1\t0\t1' refresh_openclash_cache
expect "stopped" openclash_status installed
expect "stopped" openclash_running 0

# 3. Leftover /etc/config/openclash after uninstall: report not_installed.
seed_stale
FAKE_OC='0\t0\t0' refresh_openclash_cache
expect "uninstalled" openclash_status not_installed
expect "uninstalled" openclash_installed 0
expect "uninstalled" openclash_has_access_control 0

# 4. "Last Env Check" must keep meaning the last FULL scan, not the live patch.
seed_stale
FAKE_OC='1\t1\t1' refresh_openclash_cache
expect "timestamp untouched" updated_at "2026-11-22 14:03:15"

# 5. Missing cache: fall back to a full scan instead of writing a broken file.
rm -f "$ENV_CACHE_FILE"
FAKE_OC='1\t1\t1' refresh_openclash_cache
expect "cold start" openclash_status not_installed
expect "cold start" updated_at fresh

echo "PASS: openclash status cache freshness"
