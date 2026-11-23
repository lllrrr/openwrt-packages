#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
RELAY="$ROOT/package/luci-app-upnp-nat-relay/root/usr/bin/upnp-nat-relay"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

LOG_STATE_DIR="$TMP/log_state"
OUT="$TMP/out.log"
: > "$OUT"
export LOG_STATE_DIR OUT

extract_function() {
	awk -v name="$1" '
		$0 == name "() {" { copying = 1 }
		copying { print }
		copying && $0 == "}" { exit }
	' "$RELAY" >> "$TMP/functions.sh"
}

for function in log_once log_recovered log_prune_cycle_keys; do
	extract_function "$function"
done

cat >> "$TMP/functions.sh" <<'EOF'
log_err()  { printf 'ERR %s\n' "$1" >> "$OUT"; }
log_warn() { printf 'WARN %s\n' "$1" >> "$OUT"; }
log_info() { printf 'INFO %s\n' "$1" >> "$OUT"; }
log_debug() { printf 'DEBUG %s\n' "$1" >> "$OUT"; }

lines() { wc -l < "$OUT" | tr -d ' '; }
reset_log() { : > "$OUT"; }

# A suppressed repeat must emit nothing at all - not even a duplicate info.
expect_lines() {
	_name="$1"; _want="$2"; _got="$(lines)"
	[ "$_got" -eq "$_want" ] || {
		echo "FAIL: $_name expected $_want line(s), got $_got" >&2
		cat "$OUT" >&2
		exit 1
	}
}

expect_contains() {
	_name="$1"; _needle="$2"
	grep -qF "$_needle" "$OUT" || {
		echo "FAIL: $_name missing '$_needle'" >&2
		cat "$OUT" >&2
		exit 1
	}
}

# 1. A condition that persists across ticks is reported once, then repeats go
#    to debug only (which the default info threshold drops).
reset_log
log_once upnpc_read "exit:1" err "Sync failed: upnpc read failed"
log_once upnpc_read "exit:1" err "Sync failed: upnpc read failed"
log_once upnpc_read "exit:1" err "Sync failed: upnpc read failed"
expect_lines "persistent error" 3
expect_contains "persistent error level" "ERR Sync failed: upnpc read failed"
[ "$(grep -c '^ERR' "$OUT")" -eq 1 ] || { echo "FAIL: error repeated in syslog" >&2; exit 1; }

# 2. A changed signature is a new event (timeout instead of exit 1).
log_once upnpc_read "exit:124" err "Sync failed: upnpc read timed out"
[ "$(grep -c '^ERR' "$OUT")" -eq 2 ] || { echo "FAIL: changed signature not reported" >&2; exit 1; }

# 3. Recovery announces itself exactly once.
reset_log
log_recovered upnpc_read "upnpc read recovered after 3 failed cycle(s)"
log_recovered upnpc_read "upnpc read recovered after 3 failed cycle(s)"
expect_lines "recovery" 1
expect_contains "recovery" "INFO upnpc read recovered"

# 4. After recovery the same condition is reported again.
log_once upnpc_read "exit:1" err "Sync failed: upnpc read failed"
[ "$(grep -c '^ERR' "$OUT")" -eq 1 ] || { echo "FAIL: re-armed condition silent" >&2; cat "$OUT" >&2; exit 1; }

# 5. Per-cycle keys: seen key survives, unseen key is pruned so it can be
#    reported again when the conflict comes back.
reset_log
log_once conflict_tcp_80 "source=nft_redirect" info "nft conflict: TCP 80"
log_once conflict_tcp_443 "source=uci_redirect" info "UCI conflict: TCP 443"
expect_lines "two conflicts" 2

log_prune_cycle_keys conflict " conflict_tcp_80"
[ -f "$LOG_STATE_DIR/conflict_tcp_80" ] || { echo "FAIL: seen key pruned" >&2; exit 1; }
[ -f "$LOG_STATE_DIR/conflict_tcp_443" ] && { echo "FAIL: unseen key kept" >&2; exit 1; }

reset_log
log_once conflict_tcp_80 "source=nft_redirect" info "nft conflict: TCP 80"
log_once conflict_tcp_443 "source=uci_redirect" info "UCI conflict: TCP 443"
expect_contains "pruning re-arms" "INFO UCI conflict: TCP 443"
grep -q "^INFO nft conflict" "$OUT" && { echo "FAIL: surviving key logged again" >&2; cat "$OUT" >&2; exit 1; }

# 6. Pruning an empty cycle clears every cycle-scoped key.
log_prune_cycle_keys conflict ""
if ls "$LOG_STATE_DIR"/conflict_* >/dev/null 2>&1; then
	echo "FAIL: empty cycle left conflict keys behind" >&2
	ls -A "$LOG_STATE_DIR" >&2
	exit 1
fi

echo "PASS: log repeat suppression"
EOF

. "$TMP/functions.sh"
