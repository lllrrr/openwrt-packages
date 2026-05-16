#!/bin/sh
# DeviceMaster Monitor Daemon (Simplified)
# Architecture: Event-driven only
#   - Listens for netlink ARP events
#   - When new device detected, triggers event_handler.sh to register it in UCI
#   - No cache files, no periodic scanning
#   - Frontend handles online status via real-time API

COLLECTOR="/usr/libexec/devicemaster/device_collector.sh"
EVENT_HANDLER="/usr/libexec/devicemaster/event_handler.sh"
PID_FILE="/var/run/devicemaster/monitor.pid"
ARP_TABLE="/proc/net/arp"

log_msg() {
    logger -t devicemaster-monitor "$1"
}

# Get list of MACs from UCI device profiles
get_uci_macs() {
    uci -q batch <<-EOF 2>/dev/null
EOF
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

# Signal handler
cleanup() {
    log_msg "Shutting down..."
    [ -n "$NETLINK_PID" ] && kill "$NETLINK_PID" 2>/dev/null
    rm -f "$PID_FILE" /var/run/devicemaster/last_check
    exit 0
}

trap cleanup TERM INT

# Main loop
main() {
    mkdir -p /var/run/devicemaster
    echo $$ > "$PID_FILE"

    log_msg "Started (event-driven mode, no cache)"

    # Initial discovery: register any ARP devices not yet in UCI
    if [ -x "$EVENT_HANDLER" ]; then
        "$EVENT_HANDLER" discover
    fi

    # Start netlink monitor in background
    if command -v ip >/dev/null 2>&1; then
        ip monitor neigh 2>/dev/null &
        NETLINK_PID=$!
        log_msg "Netlink monitor started (pid=$NETLINK_PID)"
    fi

    # Event loop
    while true; do
        if [ -n "$NETLINK_PID" ] && kill -0 "$NETLINK_PID" 2>/dev/null; then
            # Wait for netlink events with timeout
            sleep 30
            handle_netlink_event
        else
            sleep 30
            # Restart netlink monitor if it died
            if command -v ip >/dev/null 2>&1; then
                ip monitor neigh 2>/dev/null &
                NETLINK_PID=$!
            fi
        fi
    done
}

main "$@"
