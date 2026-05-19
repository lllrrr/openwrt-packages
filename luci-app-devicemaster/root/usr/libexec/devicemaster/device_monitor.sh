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
PAGE_ACTIVE_FILE="/tmp/dm_page_active"
PAGE_ACTIVE_TIMEOUT=10   # Page considered active if polled within 10s
IDLE_INTERVAL=300        # 5 minutes when no page viewer or no unknown devices

log_msg() {
    logger -t devicemaster-monitor "$1"
}

UCI_MAC_FILE="/tmp/dm_uci_macs"
ARP_MAC_FILE="/tmp/dm_arp_macs"

# Get list of MACs from UCI device profiles (newline-separated, uppercased)
get_uci_macs() {
    > "$UCI_MAC_FILE"
    local idx=0
    while uci -q get "devicemaster.@device[$idx].mac" >/dev/null 2>&1; do
        uci -q get "devicemaster.@device[$idx].mac" | tr 'a-f' 'A-F' >> "$UCI_MAC_FILE"
        idx=$((idx + 1))
    done
}

# Get list of MACs from ARP table (newline-separated, uppercased)
get_arp_macs() {
    awk 'NR>1 && $4!="00:00:00:00:00:00" {print toupper($4)}' "$ARP_TABLE" 2>/dev/null | sort -u > "$ARP_MAC_FILE"
}

# Check if there are new devices in ARP that aren't in UCI
detect_new_device() {
    get_arp_macs

    if [ ! -s "$ARP_MAC_FILE" ]; then
        rm -f "$ARP_MAC_FILE"
        return 1
    fi

    get_uci_macs

    if [ ! -s "$UCI_MAC_FILE" ]; then
        rm -f "$UCI_MAC_FILE" "$ARP_MAC_FILE"
        return 0
    fi

    # Use grep -F -f to find ARP MACs NOT in UCI (fast, subshell-safe)
    local missing_mac=$(grep -F -v -f "$UCI_MAC_FILE" "$ARP_MAC_FILE" 2>/dev/null | head -1)

    if [ -n "$missing_mac" ]; then
        log_msg "New device detected: $missing_mac"
        rm -f "$UCI_MAC_FILE" "$ARP_MAC_FILE"
        return 0
    fi

    rm -f "$UCI_MAC_FILE" "$ARP_MAC_FILE"
    return 1
}

# Check if device list page is being actively viewed
is_page_active() {
    [ ! -f "$PAGE_ACTIVE_FILE" ] && return 1
    local last_active=$(cat "$PAGE_ACTIVE_FILE" 2>/dev/null)
    [ -z "$last_active" ] && return 1
    local now=$(date +%s)
    [ $((now - last_active)) -lt $PAGE_ACTIVE_TIMEOUT ]
}

# Count devices with unknown vendor, type, or hostname (fast: single uci show + awk)
count_unknown_devices() {
    uci show devicemaster 2>/dev/null | awk '
        /\.(mac|vendor|type|hostname)=/ {
            idx = index($0, ".")
            rest = substr($0, idx + 1)
            eq = index(rest, "=")
            field = substr(rest, 1, eq - 1)
            val = substr(rest, eq + 1)
            gsub(/^'"'"'|'"'"'$/, "", val)
            # Extract section: everything before first dot in field
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

# Signal handler
cleanup() {
    log_msg "Shutting down..."
    rm -f "$PID_FILE"
    exit 0
}

trap cleanup TERM INT

# ============================================================
# Sub-node: write local WiFi stations to public file
# Master polls this URL to discover devices behind sub-nodes
# ============================================================
write_sub_stations() {
    local has_mesh=$(iw dev wl1-mesh0 info 2>/dev/null)
    [ -z "$has_mesh" ] && return
    local dhcp_ignore=$(uci -q get dhcp.lan.ignore 2>/dev/null)
    [ "$dhcp_ignore" != "1" ] && return
    
    local node_mac=$(ip link show dev br-lan 2>/dev/null | grep 'link/ether' | awk '{print $2}')
    [ -z "$node_mac" ] && return
    node_mac=$(echo "$node_mac" | tr 'a-f' 'A-F')
    
    local stmp="/tmp/dm_sub_stations.$$"
    > "$stmp"
    
    # Collect all (mac,iface) pairs: one per line to avoid subshell issues
    local raw="/tmp/dm_sub_raw.$$"
    > "$raw"
    local ifaces=$(ls /sys/class/net/ 2>/dev/null | grep '^wl' | tr '\n' ' ')
    if [ -z "$ifaces" ]; then ifaces="wl0-ap0 wl1-ap0 wl0-ap1 wl1-ap1"; fi
    for iface in $ifaces; do
        iwinfo "$iface" assoclist 2>/dev/null | while read -r mac rest; do
            [ ${#mac} -ne 17 ] && continue
            echo "${mac}|${iface}" >> "$raw"
        done
    done
    
    # Build JSON from the collected pairs
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

# ============================================================
# Sub-node: push full device report to master
# Called when new device detected + every SUB_REPORT_INTERVAL
# ============================================================
push_to_master() {
    local has_mesh=$(iw dev wl1-mesh0 info 2>/dev/null)
    [ -z "$has_mesh" ] && return
    local dhcp_ignore=$(uci -q get dhcp.lan.ignore 2>/dev/null)
    [ "$dhcp_ignore" != "1" ] && return

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
        # Decide interval: 30s only when page is active AND 2+ unknown devices
        local interval=$IDLE_INTERVAL
        if is_page_active; then
            local unknown_count=$(count_unknown_devices)
            if [ "$unknown_count" -ge 2 ]; then
                interval=$POLL_INTERVAL
            fi
        fi

        sleep $interval
        
        # New device detection (all roles)
        if detect_new_device; then
            if [ -x "$EVENT_HANDLER" ]; then
                "$EVENT_HANDLER" discover
            fi
            # Sub-node: immediately report new device to master
            push_to_master
        fi
        
        # Sub-node: push stations to master periodically
        local now=$(date +%s)
        if [ $((now - sub_last_report)) -ge $SUB_REPORT_INTERVAL ]; then
            # Write local WiFi stations to cache file first (needed by push_to_master)
            write_sub_stations
            push_to_master
            sub_last_report=$now
        fi
    done
}

main "$@"
