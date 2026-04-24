#!/bin/sh
# Copyright (C) 2026 huchd0 <https://github.com/huchd0/luci-app-netwiz>
# Licensed under the GNU General Public License v3.0

LOCK_FILE="/var/run/netwiz_autodetect.lock"
BAK_FILE="/etc/config/network.netwiz_bak"

if [ -f "$LOCK_FILE" ]; then exit 0; fi
touch "$LOCK_FILE"
trap "rm -f $LOCK_FILE" EXIT INT TERM

# 读取系统当前记录的物理网卡名称 (如 eth0)
WAN_DEV=$(uci -q get network.wan.device)
[ -z "$WAN_DEV" ] && WAN_DEV=$(uci -q get network.wan.ifname)
[ -z "$WAN_DEV" ] && WAN_DEV="eth0"

# 直接读取"链路状态" (ubus 高层数据)
check_physical_link() {
    # 如果 ubus 返回 "up": true，说明界面上显示的是 "已连接" (网线已插好)
    local link_status=$(ubus call network.device status "{\"name\":\"$WAN_DEV\"}" 2>/dev/null | grep '"up": true')
    if [ -n "$link_status" ]; then
        return 0 # 已插线
    else
        return 1 # 未插线
    fi
}

wait_for_internet() {
    local max_wait=20
    local i=0
    while [ $i -lt $max_wait ]; do
        # 如果等待期间发现网线拔了（链路状态变为断开），立刻终止探测
        if ! check_physical_link; then return 1; fi
        
        # Ping 测外网
        if ping -c 1 -W 1 223.5.5.5 >/dev/null 2>&1; then return 0; fi
        sleep 2
        i=$((i+1))
    done
    return 1
}

# 确认是否有网线插入
if ! check_physical_link; then
    exit 0
fi

logger -t Netwiz "Cable connected detected via UBUS. Testing internet..."
sleep 5
if wait_for_internet; then
    exit 0
fi

logger -t Netwiz "Current config has no internet. Switching protocols."
cp /etc/config/network "$BAK_FILE"
sync

ORIG_PROTO=$(uci -q get network.wan.proto)
HAS_PPPOE_USER=$(uci -q get network.wan.username)
success=0

if [ "$ORIG_PROTO" != "dhcp" ]; then
    logger -t Netwiz "Trying DHCP..."
    uci set network.wan.proto='dhcp'
    uci commit network
    /etc/init.d/network restart
    if wait_for_internet; then success=1; fi
fi

if [ "$success" -eq 0 ] && [ "$ORIG_PROTO" != "pppoe" ] && [ -n "$HAS_PPPOE_USER" ]; then
    logger -t Netwiz "Trying PPPoE..."
    cp "$BAK_FILE" /etc/config/network
    uci set network.wan.proto='pppoe'
    uci commit network
    /etc/init.d/network restart
    if wait_for_internet; then success=1; fi
fi

if [ "$success" -eq 1 ]; then
    rm -f "$BAK_FILE"
else
    logger -t Netwiz "All failed. Rolling back."
    cp "$BAK_FILE" /etc/config/network
    rm -f "$BAK_FILE"
    /etc/init.d/network restart
fi

exit 0
