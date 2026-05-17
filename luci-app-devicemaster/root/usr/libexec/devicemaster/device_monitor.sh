#!/bin/sh
# DeviceMaster Monitor Daemon (Simplified)
# Architecture: Poll-based (safe, no memory leak)
#   - Polls ARP table every 30 seconds
#   - When new device detected, triggers event_handler.sh to register it in UCI
#   - No ip monitor, no netlink, no background processes
#   - Frontend handles online status via real-time API

EVENT_HANDLER="/usr/libexec/devicemaster/event_handler.sh"
PID_FILE="/var/run/devicemaster/monitor.pid"
ARP_TABLE="/proc/net/arp"
POLL_INTERVAL=30

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

    if [ -z "$arp_macs" ]; then
        return 1
    fi

    if [ -z "$uci_macs" ]; then
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

# Signal handler
cleanup() {
    log_msg "Shutting down..."
    rm -f "$PID_FILE"
    exit 0
}

trap cleanup TERM INT

# Main loop
main() {
    mkdir -p /var/run/devicemaster
    echo $$ > "$PID_FILE"

    log_msg "Started (poll mode, interval=${POLL_INTERVAL}s)"

    # Initial discovery
    if [ -x "$EVENT_HANDLER" ]; then
        "$EVENT_HANDLER" discover
    fi

    # Simple poll loop - no background processes, no memory leak
    while true; do
        sleep $POLL_INTERVAL
        if detect_new_device; then
            if [ -x "$EVENT_HANDLER" ]; then
                "$EVENT_HANDLER" discover
            fi
        fi
    done
}

main "$@"
