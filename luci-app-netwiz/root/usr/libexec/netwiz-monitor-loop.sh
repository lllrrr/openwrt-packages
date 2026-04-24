#!/bin/sh
# Netwiz 不死守护神：统管 WAN 监听与 LAN 拆弹
LOG_FILE="/tmp/netwiz.log"

log() {
    echo "$(date '+%F %T') [Monitor] $1" >> "$LOG_FILE"
}

WAN_DEV=$(uci -q get network.wan.device)
[ -z "$WAN_DEV" ] && WAN_DEV=$(uci -q get network.wan.ifname)
[ -z "$WAN_DEV" ] && WAN_DEV="eth0"

# 🌟 精准读取 LuCI 界面上的“链路状态”
check_wan_link() {
    if ubus call network.device status "{\"name\":\"$WAN_DEV\"}" 2>/dev/null | grep -q '"carrier": true'; then
        echo "up"
    else
        echo "down"
    fi
}

LAST_WAN_STATE=$(check_wan_link)
log "Service started. Monitoring WAN ($WAN_DEV) and LAN rollback timer."

while true; do
    # ---------------- 1. WAN 盲插监听 ----------------
    CURRENT_WAN_STATE=$(check_wan_link)
    
    if [ "$LAST_WAN_STATE" = "down" ] && [ "$CURRENT_WAN_STATE" = "up" ]; then
        log "WAN cable plug-in detected! Waking up autodetect engine."
        /usr/libexec/netwiz-autodetect.sh >/dev/null 2>&1 </dev/null &
    fi
    LAST_WAN_STATE="$CURRENT_WAN_STATE"

    # ---------------- 2. LAN 防失联定时炸弹 ----------------
    if [ -f /tmp/netwiz_rollback_time ]; then
        TARGET_TIME=$(cat /tmp/netwiz_rollback_time)
        CURRENT_TIME=$(date +%s)
        
        # 如果当前时间超过了设定的爆炸时间
        if [ "$CURRENT_TIME" -ge "$TARGET_TIME" ]; then
            log "Time is up (120s)! No frontend confirm received. BOOM!"
            rm -f /tmp/netwiz_rollback_time
            if [ -f /tmp/network.netwiz_bak ]; then
                log "Restoring original network config..."
                cp /tmp/network.netwiz_bak /etc/config/network
                cp /tmp/dhcp.netwiz_bak /etc/config/dhcp
                rm -f /tmp/network.netwiz_bak /tmp/dhcp.netwiz_bak
                /etc/init.d/network restart
                log "Rollback successfully completed."
            fi
        fi
    fi

    # 每 3 秒偷瞄一眼，极其稳定且不占 CPU
    sleep 3
done
