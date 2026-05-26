#!/bin/sh
# DeviceMaster Monitor Daemon v2 - Dual Mode (Power Save / Active)
#   - Idle mode: 5min poll, no traffic monitoring
#   - Active mode: 30s poll, traffic monitoring enabled

EVENT_HANDLER="/usr/libexec/devicemaster/event_handler.sh"
PID_FILE="/var/run/devicemaster/monitor.pid"
ARP_TABLE="/proc/net/arp"
PAGE_ACTIVE_FILE="/tmp/dm_page_active"
MODE_FILE="/tmp/dm_mode"  # 'active' or 'idle'

# Intervals
IDLE_INTERVAL=300        # 5 minutes in idle mode
ACTIVE_INTERVAL=30       # 30 seconds in active mode
PAGE_ACTIVE_TIMEOUT=15   # Page considered active if polled within 15s
MODE_CHECK_INTERVAL=10   # Check mode switch every 10s

# Traffic monitor control
TRAFFIC_MONITOR_PID="/var/run/devicemaster/traffic_monitor.pid"

log_msg() {
    logger -t devicemaster-monitor "$1"
}

# ============================================================
# Mode Management
# ============================================================

# Check current mode: active or idle
# Default is idle unless explicitly set to active
get_mode() {
    # Priority 1: Check explicit mode file (most reliable)
    if [ -f "$MODE_FILE" ]; then
        local mode=$(cat "$MODE_FILE" 2>/dev/null | tr -d '\n\r')
        if [ "$mode" = "active" ]; then
            echo "active"
            return
        fi
        # Any other value (including "idle") returns idle
        echo "idle"
        return
    fi
    
    # Priority 2: Check page activity (backward compat, but require explicit active)
    # Only go active if mode file explicitly says so
    echo "idle"
}

# Set mode explicitly
set_mode() {
    echo "$1" > "$MODE_FILE"
    log_msg "Mode switched to: $1"
}

# ============================================================
# Traffic Monitor Control
# ============================================================

start_traffic_monitor() {
    [ -f "$TRAFFIC_MONITOR_PID" ] && return  # Already running
    
    if [ -x "/usr/libexec/devicemaster/traffic_monitor.sh" ]; then
        /usr/libexec/devicemaster/traffic_monitor.sh monitor &
        echo $! > "$TRAFFIC_MONITOR_PID"
        log_msg "Traffic monitor started (PID: $!)"
    fi
}

stop_traffic_monitor() {
    [ ! -f "$TRAFFIC_MONITOR_PID" ] && return  # Not running
    
    local pid=$(cat "$TRAFFIC_MONITOR_PID" 2>/dev/null)
    if [ -n "$pid" ]; then
        kill "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
        log_msg "Traffic monitor stopped (PID: $pid)"
    fi
    rm -f "$TRAFFIC_MONITOR_PID"
}

# ============================================================
# Device Detection (same as v1)
# ============================================================

UCI_MAC_FILE="/tmp/dm_uci_macs"
ARP_MAC_FILE="/tmp/dm_arp_macs"

get_uci_macs() {
    > "$UCI_MAC_FILE"
    local idx=0
    while uci -q get "devicemaster.@device[$idx].mac" >/dev/null 2>&1; do
        uci -q get "devicemaster.@device[$idx].mac" | tr 'a-f' 'A-F' >> "$UCI_MAC_FILE"
        idx=$((idx + 1))
    done
}

get_arp_macs() {
    awk 'NR>1 && $4!="00:00:00:00:00:00" {print toupper($4)}' "$ARP_TABLE" 2>/dev/null | sort -u > "$ARP_MAC_FILE"
}

detect_new_device() {
    get_arp_macs
    [ ! -s "$ARP_MAC_FILE" ] && { rm -f "$ARP_MAC_FILE"; return 1; }
    
    get_uci_macs
    [ ! -s "$UCI_MAC_FILE" ] && { rm -f "$UCI_MAC_FILE" "$ARP_MAC_FILE"; return 0; }
    
    local missing_mac=$(grep -F -v -f "$UCI_MAC_FILE" "$ARP_MAC_FILE" 2>/dev/null | head -1)
    rm -f "$UCI_MAC_FILE" "$ARP_MAC_FILE"
    
    if [ -n "$missing_mac" ]; then
        log_msg "New device detected: $missing_mac"
        return 0
    fi
    return 1
}

count_unknown_devices() {
    uci show devicemaster 2>/dev/null | awk '
        /\.(mac|vendor|type|hostname)=/ {
            idx = index($0, ".")
            rest = substr($0, idx + 1)
            eq = index(rest, "=")
            field = substr(rest, 1, eq - 1)
            val = substr(rest, eq + 1)
            gsub(/^'"'"'|'"'"'$/, "", val)
            dot2 = index(field, ".")
            section = substr(field, 1, dot2 - 1)
            fname = substr(field, dot2 + 1)
            if (fname == "mac") macs[section] = val
            if (fname == "vendor") vendors[section] = val
            if (fname == "type") types[section] = val
            if (fname == "hostname") hostnames[section] = val
        }
        END {
            count = 0
            for (s in macs) {
                u = 0
                v = vendors[s]; t = types[s]; h = hostnames[s]
                if (v == "" || v == "LAA" || v == "unknown" || v == "Unknown") u++
                if (t == "" || t == "unknown" || t == "Unknown") u++
                if (h == "" || h == "*" || h == "-" || h == "unknown") u++
                if (u >= 2) count++
            }
            print count
        }
    '
}

# ============================================================
# Sub-node Functions (same as v1)
# ============================================================

write_sub_stations() {
    local has_mesh=$(iw dev wl1-mesh0 info 2>/dev/null)
    [ -z "$has_mesh" ] && return
    [ "$(uci -q get dhcp.lan.ignore 2>/dev/null)" != "1" ] && return
    
    local node_mac=$(ip link show dev br-lan 2>/dev/null | grep 'link/ether' | awk '{print $2}')
    [ -z "$node_mac" ] && return
    node_mac=$(echo "$node_mac" | tr 'a-f' 'A-F')
    
    local stmp="/tmp/dm_sub_stations.$$"
    local raw="/tmp/dm_sub_raw.$$"
    > "$stmp"; > "$raw"
    
    local ifaces=$(ls /sys/class/net/ 2>/dev/null | grep '^wl' | tr '\n' ' ')
    [ -z "$ifaces" ] && ifaces="wl0-ap0 wl1-ap0 wl0-ap1 wl1-ap1"
    
    for iface in $ifaces; do
        iwinfo "$iface" assoclist 2>/dev/null | while read -r mac rest; do
            [ ${#mac} -ne 17 ] && continue
            echo "${mac}|${iface}" >> "$raw"
        done
    done
    
    printf '{"node_mac":"%s","iface":"br-lan","stations":[' "$node_mac" > "$stmp"
    local sep=""
    while IFS='|' read -r mac iface; do
        printf '%s{"mac":"%s","iface":"%s"}' "$sep" "$(echo "$mac" | tr 'a-f' 'A-F')" "$iface" >> "$stmp"
        sep=","
    done < "$raw"
    printf ']}\n' >> "$stmp"
    
    cp "$stmp" "/www/luci-static/resources/dm_sub_stations.json" 2>/dev/null
    rm -f "$stmp" "$raw"
}

push_to_master() {
    local has_mesh=$(iw dev wl1-mesh0 info 2>/dev/null)
    [ -z "$has_mesh" ] && return
    [ "$(uci -q get dhcp.lan.ignore 2>/dev/null)" != "1" ] && return
    
    local master_ip=$(ip route show default 2>/dev/null | awk '{print $3}' | head -1)
    [ -z "$master_ip" ] && return
    
    local node_mac=$(ip link show dev br-lan 2>/dev/null | grep 'link/ether' | awk '{print $2}')
    [ -z "$node_mac" ] && return
    node_mac=$(echo "$node_mac" | tr 'a-f' 'A-F')
    
    local report_file="/tmp/dm_sub_push_report.json"
    lua /usr/libexec/devicemaster/sub_report_gen.lua "$node_mac" > "$report_file" 2>/dev/null
    [ ! -s "$report_file" ] && return
    
    curl -s --connect-timeout 2 --max-time 5 \
        -X POST \
        -H "Content-Type: application/json" \
        -d @"$report_file" \
        "http://$master_ip/cgi-bin/luci/admin/network/devicemaster/api/report_sub" \
        >/dev/null 2>&1
    
    rm -f "$report_file"
}

SUB_REPORT_INTERVAL=120
sub_last_report=0

# ============================================================
# Main Loop - Dual Mode
# ============================================================

cleanup() {
    log_msg "Shutting down..."
    stop_traffic_monitor
    rm -f "$PID_FILE" "$MODE_FILE"
    exit 0
}

trap cleanup TERM INT

main() {
    mkdir -p /var/run/devicemaster
    
    # Check if already running
    if [ -f "$PID_FILE" ]; then
        local old_pid=$(cat "$PID_FILE" 2>/dev/null)
        if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
            log_msg "Already running (PID: $old_pid), exiting"
            exit 0
        fi
    fi
    
    echo $$ > "$PID_FILE"
    
    local current_mode="idle"
    local interval=$IDLE_INTERVAL
    local mode_check_counter=0
    
    log_msg "Started (dual mode: idle=${IDLE_INTERVAL}s, active=${ACTIVE_INTERVAL}s)"
    
    # Initial discovery
    [ -x "$EVENT_HANDLER" ] && "$EVENT_HANDLER" discover
    
    # Initial mode check
    current_mode=$(get_mode)
    if [ "$current_mode" = "active" ]; then
        start_traffic_monitor
        interval=$ACTIVE_INTERVAL
        log_msg "Initial mode: active"
    else
        log_msg "Initial mode: idle"
    fi
    
    while true; do
        # Use shorter sleep for responsive mode switching
        # In active mode: check every 10s, in idle mode: check every 60s
        local sleep_time=$MODE_CHECK_INTERVAL
        [ "$current_mode" = "idle" ] && sleep_time=60
        
        sleep $sleep_time
        
        # Check mode
        mode_check_counter=$((mode_check_counter + sleep_time))
        
        if [ $mode_check_counter -ge $MODE_CHECK_INTERVAL ]; then
            mode_check_counter=0
            local new_mode=$(get_mode)
            
            # Mode switch handling
            if [ "$new_mode" != "$current_mode" ]; then
                current_mode="$new_mode"
                log_msg "Mode switched to: $current_mode"
                
                if [ "$current_mode" = "active" ]; then
                    start_traffic_monitor
                    interval=$ACTIVE_INTERVAL
                else
                    stop_traffic_monitor
                    interval=$IDLE_INTERVAL
                fi
            fi
        fi
        
        # New device detection
        if detect_new_device; then
            [ -x "$EVENT_HANDLER" ] && "$EVENT_HANDLER" discover
            push_to_master
        fi
        
        # Sub-node: push stations periodically
        local now=$(date +%s)
        if [ $((now - sub_last_report)) -ge $SUB_REPORT_INTERVAL ]; then
            write_sub_stations
            push_to_master
            sub_last_report=$now
        fi
    done
}

main "$@"
