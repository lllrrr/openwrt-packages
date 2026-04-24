#!/bin/sh
# Copyright (C) 2026 huchd0 <https://github.com/huchd0/luci-app-netwiz>
# Licensed under the GNU General Public License v3.0
# 独立的防失联倒计时守护进程
TARGET_LAN_IP="$1"

sleep 10
for i in $(seq 1 110); do
    # 安全退出
    if [ ! -f /tmp/netwiz_pending_confirm ]; then exit 0; fi
    
    # 探测新 IP 网页访问
    if netstat -tn 2>/dev/null | grep -E "(^|[ \t:])${TARGET_LAN_IP}:(80|443)[ \t]+.*ESTABLISHED" >/dev/null; then
        logger -t Netwiz "Web access detected on $TARGET_LAN_IP. Auto-confirming settings."
        rm -f /tmp/netwiz_pending_confirm /tmp/network.netwiz_bak /tmp/dhcp.netwiz_bak
        exit 0
    fi
    sleep 1
done

# 时间到，执行回退
if [ -f /tmp/netwiz_pending_confirm ]; then
    logger -t Netwiz "Rollback triggered! No web access to $TARGET_LAN_IP detected within 2 minutes."
    cp /tmp/network.netwiz_bak /etc/config/network
    cp /tmp/dhcp.netwiz_bak /etc/config/dhcp
    rm -f /tmp/netwiz_pending_confirm /tmp/network.netwiz_bak /tmp/dhcp.netwiz_bak
    /etc/init.d/network restart
fi
exit 0
