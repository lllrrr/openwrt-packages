#!/bin/sh
# Copyright (C) 2026 huchd0 <https://github.com/huchd0/luci-app-netwiz>
# Licensed under the GNU General Public License v3.0

LOCK_FILE="/var/run/netwiz_autodetect.lock"
BAK_FILE="/etc/config/network.netwiz_bak"

if [ -f "$LOCK_FILE" ]; then exit 0; fi
touch "$LOCK_FILE"
trap "rm -f $LOCK_FILE" EXIT INT TERM

# 最多等待 30 秒 (15次循环)，给足 PPPoE 拨号的时间
wait_for_internet() {
    local max_wait=15
    local i=0
    while [ $i -lt $max_wait ]; do
        # 在拨号等待途中，网线被拔出，立刻中止探测！
        if [ "$(cat /sys/class/net/eth0/carrier 2>/dev/null)" = "0" ]; then
            return 1
        fi
        # 只要能 Ping 通，立刻判定成功
        if ping -c 1 -W 1 223.5.5.5 >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
        i=$((i+1))
    done
    return 1
}

# 1. 初始状态检测，等待网卡获取到硬件信号
sleep 5
if wait_for_internet; then
    exit 0
fi

# 2. 备份【全局】网络状态,断电防呆预备
cp /etc/config/network "$BAK_FILE"
sync

ORIG_PROTO=$(uci -q get network.wan.proto)
HAS_PPPOE_USER=$(uci -q get network.wan.username)
success=0

# 3. 尝试 A: 自动获取 IP (DHCP)
if [ "$ORIG_PROTO" != "dhcp" ]; then
    uci set network.wan.proto='dhcp'
    uci commit network
    /etc/init.d/network restart
    
    if wait_for_internet; then
        success=1
    fi
fi

# 4. 尝试 B: PPPoE 拨号 (如果有账号残留)
if [ "$success" -eq 0 ] && [ "$ORIG_PROTO" != "pppoe" ] && [ -n "$HAS_PPPOE_USER" ]; then
    # 恢复全局配置，然后只修改为 PPPoE
    cp "$BAK_FILE" /etc/config/network
    uci set network.wan.proto='pppoe'
    uci commit network
    /etc/init.d/network restart
    
    # 开始长达 30 秒的耐心等待...
    if wait_for_internet; then
        success=1
    fi
fi

# 5. 终极回退机制 (全局时光倒流)
if [ "$success" -eq 1 ]; then
    rm -f "$BAK_FILE"
else
    cp "$BAK_FILE" /etc/config/network
    rm -f "$BAK_FILE"
    /etc/init.d/network restart
fi

exit 0
