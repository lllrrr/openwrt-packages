#!/bin/sh
# DeviceMaster Monitor Daemon v2 - Dual Mode (Power Save / Active)
#   - Idle mode:  device sweep every 5min, new devices get a 'light' identify
#   - Active mode: device sweep every 30s,  new devices get a 'full' identify
#
# The mode tick itself runs every MODE_CHECK_INTERVAL seconds in both modes (two
# file reads), only the expensive sweep is gated by IDLE_INTERVAL/ACTIVE_INTERVAL.

EVENT_HANDLER="/usr/libexec/devicemaster/event_handler.sh"
PID_FILE="/var/run/devicemaster/monitor.pid"
ARP_TABLE="/proc/net/arp"
PAGE_ACTIVE_FILE="/tmp/dm_page_active"
MODE_FILE="/tmp/dm_mode"  # 'active' or 'idle'

# Intervals
IDLE_INTERVAL=300        # device sweep every 5 minutes in idle mode
ACTIVE_INTERVAL=30       # device sweep every 30 seconds in active mode
PAGE_ACTIVE_TIMEOUT=90   # Page considered active if polled within 90s
MODE_CHECK_INTERVAL=10   # Check mode switch every 10s

log_msg() {
    logger -t devicemaster-monitor "$1"
}

# ============================================================
# Mode Management
# ============================================================

# Check current mode: active or idle
# Default is idle unless explicitly set to active
# Also checks page activity timeout to handle browser crash/close without beforeunload
get_mode() {
    # Priority 1: Check explicit mode file (most reliable)
    if [ -f "$MODE_FILE" ]; then
        local mode=$(cat "$MODE_FILE" 2>/dev/null | tr -d '\n\r')
        if [ "$mode" = "active" ]; then
            # Double-check: if page_active file exists and is stale, treat as idle
            # This handles browser crash/close without triggering beforeunload
            if [ -f "$PAGE_ACTIVE_FILE" ]; then
                local last_active=$(cat "$PAGE_ACTIVE_FILE" 2>/dev/null | tr -d '\n\r')
                local now=$(date +%s)
                if [ -n "$last_active" ] && [ "$last_active" -gt 0 ] 2>/dev/null; then
                    local elapsed=$((now - last_active))
                    if [ "$elapsed" -gt "$PAGE_ACTIVE_TIMEOUT" ]; then
                        # Page activity timed out, switch to idle
                        log_msg "Page activity timed out (${elapsed}s > ${PAGE_ACTIVE_TIMEOUT}s), forcing idle"
                        set_mode "idle"
                        echo "idle"
                        return
                    fi
                fi
            fi
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
# Device Detection
# ============================================================

UCI_MAC_FILE="/tmp/dm_uci_macs"
ARP_MAC_FILE="/tmp/dm_arp_macs"

get_uci_macs() {
    > "$UCI_MAC_FILE"
    local idx=0
    while uci -q get "devicemaster.@device[$idx].mac" >/dev/null 2>&1; do
        uci -q get "devicemaster.@device[$idx].mac" | tr 'a-f' 'A-F' >> "$UCI_MAC_FILE"
        # Also include alt_macs so merged device aliases are not treated as new devices
        local alts=$(uci -q get "devicemaster.@device[$idx].alt_macs" 2>/dev/null)
        if [ -n "$alts" ]; then
            OLD_IFS="$IFS"; IFS=','
            for alt in $alts; do
                [ -n "$alt" ] && echo "$alt" | tr 'a-f' 'A-F' | tr -d ' ' >> "$UCI_MAC_FILE"
            done
            IFS="$OLD_IFS"
        fi
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

# Re-apply persisted rate limits whose tc class has gone missing.
#
# UCI keeps `rate_limit` across reboots and init.d restores the nft block rules,
# but nothing re-created the HTB classes - so after every reboot the plugin
# claimed a device was rate limited while its traffic was in fact not shaped at
# all (and a device that was offline at boot never got its class back either).
#
# `status` prints the rate only when the class really exists, so this costs two
# short process spawns per *limited* device per sweep and nothing for the rest.
TRAFFIC_CONTROL="/usr/libexec/devicemaster/traffic_control.sh"

reapply_rate_limits() {
    [ -x "$TRAFFIC_CONTROL" ] || return
    command -v tc >/dev/null 2>&1 || return

    local idx=0
    while uci -q get "devicemaster.@device[$idx]" >/dev/null 2>&1; do
        local mac=$(uci -q get "devicemaster.@device[$idx].mac" 2>/dev/null)
        local rate=$(uci -q get "devicemaster.@device[$idx].rate_limit" 2>/dev/null)
        if [ -n "$mac" ] && [ -n "$rate" ]; then
            if [ -z "$("$TRAFFIC_CONTROL" status "$mac" 2>/dev/null)" ]; then
                log_msg "Re-applying stored rate limit for $mac ($rate)"
                "$TRAFFIC_CONTROL" limit "$mac" "$rate" >/dev/null 2>&1
            fi
        fi
        idx=$((idx + 1))
    done
}

# ============================================================
# Sub-node Functions
# ============================================================

# NOTE: a write_sub_stations() used to live here. It built
# /www/luci-static/resources/dm_sub_stations.json every SUB_REPORT_INTERVAL.
# Nothing ever read that file: the master does not fetch it (snapshot_writer.lua
# polls each peer's /luci-static/resources/dm_snapshot.json instead), and the
# report that actually reaches the master is the one push_to_master() sends
# below via sub_report_gen.lua + POST /api/report_sub. It was dead code, and it
# was also the sub node's only reason to write to the overlay filesystem on a
# timer. Removed.

push_to_master() {
    local has_mesh=$(iw dev wl1-mesh0 info 2>/dev/null)
    [ -z "$has_mesh" ] && return
    [ "$(uci -q get dhcp.lan.ignore 2>/dev/null)" != "1" ] && return
    
    # The default gateway, not a hard-coded master address: on a multi-hop mesh
    # a node sits behind a repeater, so its upstream is that repeater. The
    # repeater forwards the report one level further up (the `relayed` section
    # sub_report_gen.lua builds), which is what makes deeper nodes visible on the
    # real master.
    local master_ip=$(ip route show default 2>/dev/null | awk '{print $3}' | head -1)
    [ -z "$master_ip" ] && return
    
    local node_mac=$(ip link show dev br-lan 2>/dev/null | grep 'link/ether' | awk '{print $2}')
    [ -z "$node_mac" ] && return
    node_mac=$(echo "$node_mac" | tr 'a-f' 'A-F')
    
    local report_file="/tmp/dm_sub_push_report.json"
    lua /usr/libexec/devicemaster/sub_report_gen.lua "$node_mac" > "$report_file" 2>/dev/null
    [ ! -s "$report_file" ] && return
    
    local resp=$(curl -s --connect-timeout 2 --max-time 5 \
        -X POST \
        -H "Content-Type: application/json" \
        -d @"$report_file" \
        "http://$master_ip/cgi-bin/luci/admin/network/devicemaster/api/report_sub" \
        2>/dev/null)
    
    rm -f "$report_file"
    
    # A silent failure here is invisible from the master side - it just never
    # shows this node's clients, with nothing saying why. Log a short, bounded
    # reason (the response is an error string or, if the endpoint is behind an
    # auth wall, an HTML login page).
    case "$resp" in
        *'"success":true'*)
            : ;;
        *)
            log_msg "Report push to $master_ip failed: $(echo "$resp" | cut -c1-120)"
            ;;
    esac
}

# Sub-node report cadence. Raised from 120s to 300s back when the report still
# used `iwinfo assoclist` (ubus -> hostapd, which grew hostapd's memory over
# long uptimes). The report now reads `iw ... station dump` straight from the
# kernel, but the interval is kept: a report costs a dozen process spawns plus
# a POST, and 5 minutes is plenty fresh for devices behind a mesh backhaul.
SUB_REPORT_INTERVAL=300
sub_last_report=0

# ============================================================
# Main Loop - Dual Mode
# ============================================================

cleanup() {
    log_msg "Shutting down..."
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
    local last_scan=$(date +%s)
    
    log_msg "Started (dual mode: idle=${IDLE_INTERVAL}s, active=${ACTIVE_INTERVAL}s)"
    
    # Initial discovery stays lightweight; expensive identification is opened by
    # the device list page or explicit manual discovery.
    [ -x "$EVENT_HANDLER" ] && "$EVENT_HANDLER" discover light
    
    # Initial mode check
    current_mode=$(get_mode)
    if [ "$current_mode" = "active" ]; then
        interval=$ACTIVE_INTERVAL
        log_msg "Initial mode: active"
    else
        log_msg "Initial mode: idle"
    fi
    
    while true; do
        # Use a short tick for responsive mode switching: 10s while the page is
        # open, 60s otherwise. The tick itself is cheap (two file reads), the
        # expensive part below is what the interval gate protects.
        local sleep_time=$MODE_CHECK_INTERVAL
        [ "$current_mode" = "idle" ] && sleep_time=60
        
        sleep $sleep_time
        
        # Mode switch handling
        local new_mode=$(get_mode)
        if [ "$new_mode" != "$current_mode" ]; then
            current_mode="$new_mode"
            log_msg "Mode switched to: $current_mode"
            
            if [ "$current_mode" = "active" ]; then
                interval=$ACTIVE_INTERVAL
            else
                interval=$IDLE_INTERVAL
            fi
        fi
        
        # New device sweep.
        #
        # This is the only expensive step (get_arp_macs + get_uci_macs + a uci
        # sweep per device), so it runs on the mode-dependent interval rather
        # than on every 10s tick. `interval` used to be assigned but never read,
        # which made the sweep run 6x more often than IDLE_INTERVAL/ACTIVE_INTERVAL
        # advertise. DHCP lease events still register new devices immediately via
        # event_handler.sh, this sweep is only the backstop.
        local now=$(date +%s)
        if [ $((now - last_scan)) -ge "$interval" ]; then
            last_scan=$now
            if detect_new_device; then
                if [ "$current_mode" = "active" ]; then
                    [ -x "$EVENT_HANDLER" ] && "$EVENT_HANDLER" discover full
                else
                    [ -x "$EVENT_HANDLER" ] && "$EVENT_HANDLER" discover light
                fi
                push_to_master
            fi
            reapply_rate_limits
        fi
        
        # Sub-node: push a full report to the master periodically
        if [ $((now - sub_last_report)) -ge $SUB_REPORT_INTERVAL ]; then
            push_to_master
            sub_last_report=$now
        fi
    done
}

main "$@"
