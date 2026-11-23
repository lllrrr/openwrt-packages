#!/bin/sh
# Contract: results of openclash_apply / openclash_sync_per_mapping never reach
# syslog as-is, and a command that keeps failing is reported once per streak.
#
# Regression source: log_warn "OpenClash per-mapping RETURN rules failed:
# $_so_result" put the whole JSON payload - which can embed multi-line nft
# stderr - into a single syslog record, every sync tick. The nft table / rule
# batch paths had the same shape: a condition that stays broken logged one line
# per interval instead of one per streak.
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
RELAY="$ROOT/package/luci-app-upnp-nat-relay/root/usr/bin/upnp-nat-relay"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

OUT="$TMP/out.log"
: > "$OUT"
LOG_STATE_DIR="$TMP/log_state"
export OUT LOG_STATE_DIR

: > "$TMP/functions.sh"
extract_function() {
	awk -v name="$1" '
		$0 == name "() {" { copying = 1 }
		copying { print }
		copying && $0 == "}" { exit }
	' "$RELAY" >> "$TMP/functions.sh"
}

for function in summarize_command_output log_once log_recovered log_result_failure; do
	extract_function "$function"
done

cat >> "$TMP/functions.sh" <<'EOF'
log_err()  { printf 'ERR %s\n' "$1" >> "$OUT"; }
log_warn() { printf 'WARN %s\n' "$1" >> "$OUT"; }
log_info() { printf 'INFO %s\n' "$1" >> "$OUT"; }
# The default cfg_log_level is info, so a suppressed repeat - which log_once
# downgrades to debug - emits nothing at all.
log_debug() { :; }

lines() { wc -l < "$OUT" | tr -d ' '; }
EOF

. "$TMP/functions.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# A payload shaped like openclash_apply's failure output, with nft stderr
# embedded in it.
PAYLOAD='{"success":false,"error":"nft: Could not process rule: Operation not supported
nft: rule insert failed in chain upnp_nat_relay_dnat
add rule inet fw4 upnp_nat_relay_dnat ip daddr 1.2.3.4 tcp dport 8080 dnat to 192.168.1.5:80"}'

# 1. Multi-line payload collapses to one bounded line.
detail="$(summarize_command_output "$PAYLOAD")"
[ -n "$detail" ] || fail "summary is empty"
[ "$(printf '%s' "$detail" | wc -l | tr -d ' ')" -eq 0 ] || fail "summary spans multiple lines"
case "$detail" in
	*"Operation not supported"*) ;;
	*) fail "summary dropped the failure text: $detail" ;;
esac
case "$detail" in
	*" | "*) ;;
	*) fail "summary did not join the lines: $detail" ;;
esac
bytes="$(printf '%s' "$detail" | LC_ALL=C wc -c | tr -d ' ')"
[ "$bytes" -le 180 ] || fail "summary is ${bytes} bytes, above the 180 byte budget"

# 2. The clamp keeps the ASCII ellipsis (OpenWrt has no UTF-8 locale).
long="$(awk 'BEGIN { for (i = 0; i < 600; i++) printf "y" }')"
detail="$(summarize_command_output "$long")"
[ "$(printf '%s' "$detail" | LC_ALL=C wc -c | tr -d ' ')" -eq 180 ] \
	|| fail "clamp did not land on exactly 180 bytes"
case "$detail" in
	*...) ;;
	*) fail "clamped summary lost its ASCII ellipsis" ;;
esac

# 3. One failure -> one WARN line, deduplicated across ticks.
log_result_failure openclash_per_mapping "OpenClash per-mapping RETURN rules failed" "$PAYLOAD"
[ "$(lines)" -eq 1 ] || fail "failing result wrote $(lines) lines, expected 1"
grep -q '^WARN OpenClash per-mapping RETURN rules failed: {"success":false' "$OUT" \
	|| { cat "$OUT" >&2; fail "summary line missing or malformed"; }
[ "$(grep -c '^WARN' "$OUT")" -eq 1 ] || fail "failure not emitted exactly once"

log_result_failure openclash_per_mapping "OpenClash per-mapping RETURN rules failed" "$PAYLOAD"
[ "$(lines)" -eq 1 ] || fail "identical failure on the next tick was re-announced"

# 4. A different failure is still reported.
log_result_failure openclash_per_mapping "OpenClash per-mapping RETURN rules failed" '{"success":false,"error":"openclash config not ready"}'
[ "$(lines)" -eq 2 ] || fail "changed failure was suppressed"

# 5. Success re-arms the key, so the same failure is reported again later.
log_recovered openclash_per_mapping ""
[ "$(lines)" -eq 2 ] || fail "recovery without a prior key wrote a line"
log_result_failure openclash_per_mapping "OpenClash per-mapping RETURN rules failed" "$PAYLOAD"
[ "$(lines)" -eq 3 ] || fail "recovery did not re-arm the failure report"

# 6. Static guard: no log_* call may interpolate a raw capture. Everything goes
#    through log_result_failure / summarize_command_output instead.
if grep -nE '^[[:space:]]*log_(err|warn|info) ".*\$(\{[A-Za-z_]*(result|output|stdout|stderr|detail|payload)[A-Za-z_]*\}|_s_upnpc_output|_so_result|_dsoc_result)' "$RELAY" >"$TMP/raw" 2>/dev/null; then
	cat "$TMP/raw" >&2
	fail "log_* still interpolates a raw command capture"
fi

printf 'log-output-bounded contract passed\n'
