#!/bin/sh
# Copyright (C) 2026 huchd0 <https://github.com/huchd0/luci-app-netwiz>
# Licensed under the GNU General Public License v3.0

LOCK_FILE="/var/run/netwiz_autodetect.lock"
BAK_FILE="/etc/config/network.netwiz_bak"

if [ -f "$LOCK_FILE" ]; then exit 0; fi
touch "$LOCK_FILE"
trap "rm -f $LOCK_FILE" EXIT INT TERM

WAN_DEV=$(uci -q get network.wan.device)
[ -z "$WAN_DEV" ] && WAN_DEV=$(uci -q get network.wan.ifname)
[ -z "$WAN_DEV" ] && WAN_DEV="eth0"

wait_for_internet() {
    # 测试给予最多 25 次循环 (约 50 秒) 
    local max_wait=25
    local i=0
    while [ $i -lt $max_wait ]; do
        if [ "$(cat /sys/class/net/$WAN_DEV/carrier 2>/dev/null)" = "0" ]; then
            return 1 # 网线被拔出，立刻放弃
        fi
        # 尝试 Ping 阿里云公共 DNS，判定是否具备外网访问能力
        if ping -c 1 -W 1 223.5.5.5 >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
        i=$((i+1))
    done
    return 1
}

# 网线刚插入，【当前配置】50 秒的时间去尝试连网
logger -t Netwiz "Cable plugged. Testing current config..."
sleep 5
if wait_for_internet; then
    logger -t Netwiz "Current config is working. No need to switch."
    exit 0
fi

# 当前配置上不了网，准备开始切换协议
logger -t Netwiz "Current config failed to surf. Preparing to switch protocol."
cp /etc/config/network "$BAK_FILE"
sync

ORIG_PROTO=$(uci -q get network.wan.proto)
HAS_PPPOE_USER=$(uci -q get network.wan.username)
success=0

# 尝试 A：如果当前不是 DHCP，则切为 DHCP 试试
if [ "$ORIG_PROTO" != "dhcp" ]; then
    logger -t Netwiz "Switching to DHCP..."
    uci set network.wan.proto='dhcp'
    uci commit network
    /etc/init.d/network restart
    if wait_for_internet; then success=1; fi
fi

# 尝试 B：如果刚才 DHCP 没成功，且有保存过宽带账号，切为 PPPoE 试试
if [ "$success" -eq 0 ] && [ "$ORIG_PROTO" != "pppoe" ] && [ -n "$HAS_PPPOE_USER" ]; then
    logger -t Netwiz "Switching to PPPoE..."
    # 先恢复一下备份，确保在纯净状态下切 PPPoE
    cp "$BAK_FILE" /etc/config/network
    uci set network.wan.proto='pppoe'
    uci commit network
    /etc/init.d/network restart
    if wait_for_internet; then success=1; fi
fi

# 终极回退逻辑判定
if [ "$success" -eq 1 ]; then
    logger -t Netwiz "Protocol switched successfully."
    rm -f "$BAK_FILE"
else
    # 切来切去还是上不了网，无条件退回拔网线前的状态
    logger -t Netwiz "All protocols failed. Rolling back to original $ORIG_PROTO."
    cp "$BAK_FILE" /etc/config/network
    rm -f "$BAK_FILE"
    /etc/init.d/network restart
fi

exit 0
