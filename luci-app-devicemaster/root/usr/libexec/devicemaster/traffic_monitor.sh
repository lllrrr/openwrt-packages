#!/bin/sh
# Traffic Monitor - Monitor bandwidth usage per device
# Uses nfacct (netfilter accounting) or iptables byte counters per IP

TRAFFIC_DB="/var/run/devicemaster/traffic.json"
STATS_DIR="/var/run/devicemaster/stats"
# 修复：刷新间隔从 5 秒改为 30 秒，避免过于频繁地读取 conntrack 造成 CPU 浪费
REFRESH_INTERVAL=30

mkdir -p "$STATS_DIR" "$TRAFFIC_DB" 2>/dev/null || true

# Initialize traffic database
init_db() {
    [ ! -f "$TRAFFIC_DB" ] && echo '{}' > "$TRAFFIC_DB"
}

# Get per-device traffic stats using /proc/net/nf_conntrack
# Counts bytes for connections originating from or destined to this IP
get_conntrack_stats() {
    local mac="$1"
    local ip=$(grep -i "$mac" /proc/net/arp 2>/dev/null | awk '{print $1}')
    
    if [ -z "$ip" ]; then
        echo '{"connections": 0, "rx": 0, "tx": 0}'
        return
    fi

    # Count connections
    local conns=$(grep -c "src=$ip " /proc/net/nf_conntrack 2>/dev/null || echo 0)
    
    # Sum bytes from conntrack: src=ip means uploaded (tx), dst=ip means downloaded (rx)
    # conntrack format: ... src=ip ... bytes=NNN ... or ... dst=ip ... bytes=NNN ...
    local rx_bytes=0
    local tx_bytes=0
    
    # Use awk for efficient single-pass parsing
    awk -v ip="$ip" '
    BEGIN { rx=0; tx=0 }
    {
        if (index($0, "dst="ip" ") > 0) {
            # Incoming traffic to this IP
            for (i=1; i<=NF; i++) {
                if ($i ~ /^bytes=[0-9]/) {
                    sub(/^bytes=/, "", $i)
                    rx += $i
                }
            }
        }
        if (index($0, "src="ip" ") > 0) {
            # Outgoing traffic from this IP
            for (i=1; i<=NF; i++) {
                if ($i ~ /^bytes=[0-9]/) {
                    sub(/^bytes=/, "", $i)
                    tx += $i
                }
            }
        }
    }
    END { print rx, tx }
    ' /proc/net/nf_conntrack 2>/dev/null | {
        read -r rx tx
        echo "{\"connections\": $conns, \"rx\": ${rx:-0}, \"tx\": ${tx:-0}}"
    }

    # If conntrack parsing failed, return zeros
    if [ $? -ne 0 ]; then
        echo "{\"connections\": $conns, \"rx\": 0, \"tx\": 0}"
    fi
}

# Calculate bandwidth (bytes per second)
calc_bandwidth() {
    local mac="$1"
    local current_stats="$2"
    local stats_file="$STATS_DIR/${mac//:/_}.json"
    local now=$(date +%s)
    
    if [ -f "$stats_file" ]; then
        local prev_time=$(jsonfilter -i "$stats_file" -e '@.time' 2>/dev/null)
        local prev_rx=$(jsonfilter -i "$stats_file" -e '@.rx' 2>/dev/null)
        local prev_tx=$(jsonfilter -i "$stats_file" -e '@.tx' 2>/dev/null)
        
        if [ -n "$prev_time" ] && [ -n "$prev_rx" ] && [ -n "$prev_tx" ]; then
            local time_diff=$((now - prev_time))
            [ $time_diff -eq 0 ] && time_diff=1
            
            local current_rx=$(echo "$current_stats" | jsonfilter -e '@.rx' 2>/dev/null || echo 0)
            local current_tx=$(echo "$current_stats" | jsonfilter -e '@.tx' 2>/dev/null || echo 0)
            
            local rx_rate=$(( (current_rx - prev_rx) / time_diff ))
            local tx_rate=$(( (current_tx - prev_tx) / time_diff ))
            
            # Ensure non-negative
            [ $rx_rate -lt 0 ] && rx_rate=0
            [ $tx_rate -lt 0 ] && tx_rate=0
            
            echo "{\"rx_rate\": $rx_rate, \"tx_rate\": $tx_rate}"
        else
            echo '{"rx_rate": 0, "tx_rate": 0}'
        fi
    else
        echo '{"rx_rate": 0, "tx_rate": 0}'
    fi
    
    # Save current stats for next calculation
    local current_rx=$(echo "$current_stats" | jsonfilter -e '@.rx' 2>/dev/null || echo 0)
    local current_tx=$(echo "$current_stats" | jsonfilter -e '@.tx' 2>/dev/null || echo 0)
    echo "{\"time\": $now, \"rx\": $current_rx, \"tx\": $current_tx}" > "$stats_file"
}

# Main monitoring loop
monitor_loop() {
    init_db
    
    while true; do
        for mac in $(awk 'NR>1 && $4!="00:00:00:00:00:00" {print $4}' /proc/net/arp 2>/dev/null); do
            [ "$mac" = "00:00:00:00:00:00" ] && continue
            local stats=$(get_conntrack_stats "$mac")
            calc_bandwidth "$mac" "$stats" > /dev/null
        done
        
        sleep $REFRESH_INTERVAL
    done
}

# Entry point
case "$1" in
    stats)
        get_conntrack_stats "$2"
        ;;
    bandwidth)
        calc_bandwidth "$2" "$(get_conntrack_stats "$2")"
        ;;
    *)
        monitor_loop
        ;;
esac
