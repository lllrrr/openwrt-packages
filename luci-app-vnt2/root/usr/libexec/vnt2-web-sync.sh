#!/bin/sh

LOCK_FILE="/var/lock/vnt2-web-sync.lock"
RESTORE_FLAG="/tmp/vnt2_log/vnt2_web_restoring"
SLEEP_SEC=2

ADDR="$(uci -q get vnt2.global.web_addr 2>/dev/null)"
TOKEN="$(uci -q get vnt2.global.web_token 2>/dev/null)"
TIMEOUT="$(uci -q get vnt2.global.web_sync_timeout 2>/dev/null)"
[ -z "$ADDR" ] && ADDR="0.0.0.0:19099"
case "$TIMEOUT" in
    ''|*[!0-9]*) TIMEOUT=60 ;;
esac
[ "$TIMEOUT" -lt 2 ] && TIMEOUT=2
MAX_TRIES=$((TIMEOUT / SLEEP_SEC))

case "$ADDR" in
    0.0.0.0:*) ADDR="127.0.0.1${ADDR#0.0.0.0}" ;;
    0.0.0.0)   ADDR="127.0.0.1:19099" ;;
    "[::]")    ADDR="[::1]:19099" ;;
    "[::]:"*)  ADDR="[::1]:${ADDR#\[::\]:}" ;;
    "::")      ADDR="[::1]:19099" ;;
    ":::"*)    ADDR="[::1]:${ADDR#:::}" ;;
    :*)        ADDR="127.0.0.1$ADDR" ;;
esac

exec 9>"$LOCK_FILE" 2>/dev/null || exit 0
flock -n 9 2>/dev/null || exit 0

mkdir -p /tmp/vnt2_log 2>/dev/null
touch "$RESTORE_FLAG" 2>/dev/null

web_ready() {
    if [ -n "$TOKEN" ]; then
        curl -fsS --connect-timeout 2 --max-time 3 -H "Authorization: Bearer $TOKEN" "http://$ADDR/api/version" >/dev/null 2>&1
    else
        curl -fsS --connect-timeout 2 --max-time 3 "http://$ADDR/api/version" >/dev/null 2>&1
    fi
}

i=0
while [ "$i" -lt "$MAX_TRIES" ]; do
    if web_ready; then
        ubus call luci.vnt2 restore_web_state '{}' >/dev/null 2>&1
        rm -f "$RESTORE_FLAG" 2>/dev/null
        exit 0
    fi
    sleep "$SLEEP_SEC"
    i=$((i + 1))
done

rm -f "$RESTORE_FLAG" 2>/dev/null
exit 0

