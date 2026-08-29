#!/bin/sh
# /usr/libexec/vnt2-run.sh  VNT2 wrapper v2.0

NAME="$1"
LOG_FILE="$2"
EVENT_FILE="${LOG_FILE%.log}.events"
shift 2
ROUTE_FIX_LOCK="/tmp/vnt2_log/vnt2_route_fixing"
KILL_RECORD="/tmp/vnt2_log/vnt2_kill_record"
SELF_PID=$$
START_TIME=$(date +%s)
CHECK_INTERVAL=100
ROUTE_FIXED=0
KILL_INTERVAL=1800
STARTUP_CHECK_WINDOW="$(uci get vnt2.global.startup_check_window 2>/dev/null || echo 60)"
case "$STARTUP_CHECK_WINDOW" in
    ""|*[!0-9]*) STARTUP_CHECK_WINDOW=60 ;;
esac
GOT_PUBLIC_ADDR=0
STARTUP_CHECK_DONE=0
DNS_LIST="223.5.5.5 119.29.29.29 180.76.76.76"

event() {
    mkdir -p "$(dirname "$EVENT_FILE")" 2>/dev/null
    printf '[%s] EVENT %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$EVENT_FILE"
}

log() {
    [ "$LOG_TO_FILE" = "1" ] || return
    printf '[%s] >>> %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG_FILE"
}

_network_ok() {
    local ip
    for ip in $DNS_LIST; do
        ping -c1 -W2 "$ip" > /dev/null 2>&1 && return 0
    done
    return 1
}

_check_and_kill() {
    local now last_time elapsed
    now=$(date +%s)
    last_time=$(grep "^${NAME} " "$KILL_RECORD" 2>/dev/null | awk '{print $2}')

    if [ -z "$last_time" ]; then
        printf '%s %s\n' "$NAME" "$now" >> "$KILL_RECORD"
        event "restart_triggered reason=first_kill"
        log "First kill, triggering restart..."
        kill "$SELF_PID" 2>/dev/null
        return
    fi

    elapsed=$((now - last_time))
    if [ "$elapsed" -ge "$KILL_INTERVAL" ]; then
        sed -i "/^${NAME} /d" "$KILL_RECORD"
        printf '%s %s\n' "$NAME" "$now" >> "$KILL_RECORD"
        event "restart_triggered reason=kill_interval"
        log "Kill interval reached, triggering restart..."
        kill "$SELF_PID" 2>/dev/null
    else
        event "restart_skipped reason=kill_interval elapsed=${elapsed} interval=${KILL_INTERVAL}"
        log "Skip kill, last/interval ${elapsed}s/${KILL_INTERVAL}s"
    fi
}

_check_startup_timeout() {
    [ "$STARTUP_CHECK_DONE" = "1" ] && return
    [ "$GOT_PUBLIC_ADDR" = "1" ] && { STARTUP_CHECK_DONE=1; return; }
    [ "$STARTUP_CHECK_WINDOW" -gt 0 ] 2>/dev/null || { STARTUP_CHECK_DONE=1; return; }

    local now elapsed
    now=$(date +%s)
    elapsed=$((now - START_TIME))
    [ "$elapsed" -ge "$STARTUP_CHECK_WINDOW" ] || return

    STARTUP_CHECK_DONE=1
    if _network_ok; then
        event "public_addr_timeout timeout=${STARTUP_CHECK_WINDOW} action=restart"
        log "No public_addr obtained within ${STARTUP_CHECK_WINDOW}s and network is normal, triggering restart..."
        _check_and_kill
    else
        event "restart_skipped reason=network_unavailable"
        log "No public_addr within ${STARTUP_CHECK_WINDOW}s, but network unavailable, skip restart..."
    fi
}

rotate_log() {
    LOG_TO_FILE=$(uci get vnt2.global.log_to_file 2>/dev/null || echo 1)
    LOG_ERRORS_ONLY=$(uci get vnt2.global.log_errors_only 2>/dev/null || echo 0)

    [ "$LOG_TO_FILE" = "1" ] || return
    [ -f "$LOG_FILE" ] || return

    local log_max_kb log_max
    log_max_kb=$(uci get vnt2.global.log_max_kb 2>/dev/null || echo 300)
    log_max=$(( log_max_kb * 1024 ))
    local size
    size=$(wc -c < "$LOG_FILE" 2>/dev/null)
    [ "${size:-0}" -ge "$log_max" ] || return
    local tmp
    tmp=$(mktemp) || return
    tail -c $((log_max / 2)) "$LOG_FILE" > "$tmp" \
        && mv "$tmp" "$LOG_FILE" \
        && log "Log truncated (exceeded ${log_max_kb}KB)"
}

format_line() {
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    printf '%s\n' "$1" \
        | sed "s/^\([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}\)T\([0-9]\{2\}:[0-9]\{2\}:[0-9]\{2\}\)\.[^[:space:]]* /[${ts}] /" \
        | sed 's/\] INFO /\]［INFO］/g;
               s/\] WARN /\]［WARN］/g;
               s/\] ERROR /\]［ERROR］/g;
               s/\] DEBUG /\]［DEBUG］/g'
}

reader_loop() {
    local count=0 formatted
    while IFS= read -r line; do
        formatted=$(format_line "$line")

        if [ "$LOG_TO_FILE" = "1" ]; then
            if [ "$LOG_ERRORS_ONLY" = "1" ]; then
                case "$formatted" in
                    *"［ERROR］"*|*"［WARN］"*)
                        printf '%s\n' "$formatted" >> "$LOG_FILE"
                        ;;
                esac
            else
                printf '%s\n' "$formatted" >> "$LOG_FILE"
            fi
        fi

        case "$line" in
            *"Registration failed"*)
                if [ "$ONLINE" = "0" ]; then
                    if _network_ok; then
                        _check_and_kill
                    else
                        event "restart_skipped reason=network_unavailable"
                        log "Network unavailable, skip restart..."
                    fi
                fi
                ;;
            *"连接服务器失败"*|*"kind: AlreadyExists"*)
                if [ "$ROUTE_FIXED" = "0" ] && _network_ok; then
                    ROUTE_FIXED=1
                    if mkdir "$ROUTE_FIX_LOCK" 2>/dev/null; then
                        event "route_fix_started reason=server_failure"
                        log "Server failure detected, fixing routes..."
                        setsid sh -c '/etc/init.d/vnt2 reload' > /dev/null 2>&1 &
                    fi
                fi
                ;;
            *"public_addr"*)
                case "$line" in *"0.0.0.0:0"*) ;; *)
                    ROUTE_FIXED=0
                    GOT_PUBLIC_ADDR=1
                    event "public_addr_ready"
                    ;;
                esac
                ;;
        esac

        _check_startup_timeout

        count=$((count + 1))
        if [ $((count % CHECK_INTERVAL)) -eq 0 ]; then
            rotate_log
            count=0
        fi
    done
}

rotate_log
event "process_started command=$1"
log "Starting: $*"

FIFO=$(mktemp -u)
mkfifo "$FIFO" || { event "process_start_failed reason=mkfifo_failed"
    log "mkfifo failed"; exit 1; }

reader_loop < "$FIFO" &
READER_PID=$!

exec "$@" > "$FIFO" 2>&1
EXIT_CODE=$?

event "process_exited exit=${EXIT_CODE}"
log "Process exited exit=${EXIT_CODE} cmd: $*"
wait "$READER_PID" 2>/dev/null
rm -f "$FIFO"
exit "$EXIT_CODE"