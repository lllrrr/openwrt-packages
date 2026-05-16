#!/bin/sh
# DeviceMaster Monitor Daemon (Simplified)
# Architecture: Event-driven only
#   - Listens for netlink ARP events
#   - When new device detected, triggers event_handler.sh to register it in UCI
#   - No cache files, no periodic scanning
#   - Frontend handles online status via real-time API

EVENT_HANDLER="/usr/libexec/devicemaster/event_handler.sh"
PID_FILE="/var/run/devicemaster/monitor.pid"
ARP_TABLE="/proc/net/arp"

log_msg() {
    logger -t devicemaster-monitor "$1"
}

# Get list of MACs from UCI device profiles
get_uci_macs() {
    local idx=0
    while uci -q get "devicemaster.@device[$idx].mac" >/dev/null 2>&1; do
        uci -q get "devicemaster.@device[$idx].mac" | tr '[:lower:]' '[:upper:]'
        idx=$((idx + 1))
    done
}

# Get list of MACs from ARP table
get_arp_macs() {
    awk 'NR>1 && $4!="00:00:00:00:00:00" {print toupper($4)}' "$ARP_TABLE" 2>/dev/null | sort -u
}

# Check if there are new devices in ARP that aren't in UCI
detect_new_device() {
    local uci_macs=$(get_uci_macs)
    local arp_macs=$(get_arp_macs)

    # 修复：UCI 为空时，还需检查 ARP 表是否也为空
    # 如果 ARP 也为空，说明没有任何设备，不应触发 discover
    if [ -z "$uci_macs" ]; then
        if [ -z "$arp_macs" ]; then
            return 1
        fi
        return 0
    fi

    for mac in $arp_macs; do
        if ! echo "$uci_macs" | grep -q "^${mac}$"; then
            log_msg "New device detected: $mac"
            return 0
        fi
    done

    return 1
}

# Handle netlink events
handle_netlink_event() {
    local now=$(date +%s)
    # Debounce: only check if last check was >5 seconds ago
    if [ -f "/var/run/devicemaster/last_check" ]; then
        local last=$(cat /var/run/devicemaster/last_check 2>/dev/null)
        if [ "$((now - last))" -lt 5 ]; then
            return
        fi
    fi
    echo "$now" > /var/run/devicemaster/last_check

    if detect_new_device; then
        # Trigger event handler to register new devices
        if [ -x "$EVENT_HANDLER" ]; then
            "$EVENT_HANDLER" discover
        fi
    fi
}

# Kill all orphan ip monitor neigh processes except the one we own
# Called at startup to clean up zombies from previous respawns
cleanup_orphan_monitors() {
    local my_pid=$$
    local netlink_pid=""

    # Find ip monitor neigh processes that are children of THIS shell
    # (not yet started, so we look for orphans from previous instances)
    local all_monitors=$(ps w 2>/dev/null | grep 'ip monitor neigh' | grep -v grep)
    if [ -n "$all_monitors" ]; then
        local count=$(echo "$all_monitors" | wc -l)
        if [ "$count" -gt 1 ]; then
            log_msg "Cleaning up $count orphan ip monitor neigh processes (keeping 1)"
            # Keep only the first one, kill the rest
            local keep=1
            # 修复：使用临时文件遍历，避免管道子 shell 导致 keep 变量修改丢失
            local tmpfile=$(mktemp)
            echo "$all_monitors" > "$tmpfile"
            while read -r line; do
                local pid=$(echo "$line" | awk '{print $1}')
                if [ $keep -eq 0 ] && [ -n "$pid" ]; then
                    kill "$pid" 2>/dev/null
                fi
                keep=0
            done < "$tmpfile"
            rm -f "$tmpfile"
        fi
    fi
}

# Signal handler - MUST kill ip monitor neigh child on exit
cleanup() {
    log_msg "Shutting down..."
    # Kill our child ip monitor neigh process
    [ -n "$NETLINK_PID" ] && kill "$NETLINK_PID" 2>/dev/null
    # Also kill any ip monitor neigh by PGID to catch all children
    kill $(ps w 2>/dev/null | grep 'ip monitor neigh' | grep -v grep | awk '{print $1}') 2>/dev/null
    rm -f "$PID_FILE" /var/run/devicemaster/last_check
    exit 0
}

trap cleanup TERM INT EXIT

# Main loop
main() {
    mkdir -p /var/run/devicemaster
    echo $$ > "$PID_FILE"

    log_msg "Started (event-driven mode, no cache)"

    # Clean up orphan ip monitor neigh processes from previous respawns
    cleanup_orphan_monitors

    # Initial discovery: register any ARP devices not yet in UCI
    if [ -x "$EVENT_HANDLER" ]; then
        "$EVENT_HANDLER" discover
    fi

    # Start netlink monitor in background (only once)
    if command -v ip >/dev/null 2>&1; then
        ip monitor neigh 2>/dev/null &
        NETLINK_PID=$!
        log_msg "Netlink monitor started (pid=$NETLINK_PID)"
    fi

    # Event loop - just check if netlink is alive, don't restart here
    while true; do
        sleep 30
        handle_netlink_event
        
        # If netlink died, log it but don't auto-restart (avoid process leak)
        if [ -n "$NETLINK_PID" ] && ! kill -0 "$NETLINK_PID" 2>/dev/null; then
            log_msg "Netlink monitor died, not restarting to avoid process leak"
            NETLINK_PID=""
        fi
    done
}

main "$@"
