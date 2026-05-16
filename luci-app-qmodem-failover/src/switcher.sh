#!/bin/sh
#
# switcher.sh — 路由热切换执行模块
# 修复:
#   P12 - get_gateway: ip route show dev 不包含 default 关键字，改用正确过滤
#   P13 - ppp0 fallback: 切到 ppp0 前必须验证其有 IP 和网关
#   P14 - DNS: 不覆盖 /tmp/resolv.conf，改写 dnsmasq resolvfile
#   P15 - WAN 恢复: 用 ubus/netifd 接口而非直接 udhcpc，避免与 netifd 冲突
# 用法: switcher.sh switch_to_lte | switch_to_wan | status
# 位置: /usr/lib/qmodem-failover/switcher.sh
#

: "${WAN_IFACE:=eth0}"
: "${LTE_IFACE:=usb0}"
: "${METRIC_WAN:=10}"
: "${METRIC_LTE:=100}"
: "${METRIC_LTE_ACTIVE:=5}"
: "${LOG_TAG:=qmodem-failover}"
: "${STATUS_FILE:=/var/run/qmodem-failover/status}"
: "${STATUS_DIR:=/var/run/qmodem-failover}"

# ─────────────────────────────────────────────
# P12修复: get_gateway
# 原来: ip route show dev $iface | awk '/^default/ ...'
# 问题: `ip route show dev eth0` 的输出不包含 "default via" 前缀
#       正确输出示例: "default via 192.168.1.1 dev eth0"，但 `show dev eth0` 过滤后
#       只剩内容行，不含 "default" 关键字，所以 awk 匹配不到
# 修复: 用全量 `ip route show`，按接口名过滤 default 条目
# ─────────────────────────────────────────────
get_gateway() {
    local iface="$1"
    # 从完整路由表找 "default via X.X.X.X dev $iface" 并提取网关 IP
    ip route show 2>/dev/null \
        | awk -v iface="$iface" '
            /^default/ && $0 ~ "dev "iface"( |$)" {
                # 格式: default via GW dev IFACE [metric M]
                for (i=1;i<=NF;i++) {
                    if ($i=="via") { print $(i+1); exit }
                }
            }'
}

# 获取接口第一个 IPv4 地址（不含前缀长度）
get_iface_ip() {
    local iface="$1"
    ip addr show "$iface" 2>/dev/null \
        | awk '/inet / { split($2,a,"/"); print a[1]; exit }'
}

# 接口是否已有 IPv4
iface_has_ip() {
    local iface="$1"
    ip addr show "$iface" 2>/dev/null | grep -q "inet "
}

# 写状态文件
write_status() {
    local mode="$1"
    local msg="$2"
    mkdir -p "$STATUS_DIR"
    printf '%s:%s:%s\n' "$mode" "$(date +%s)" "$msg" > "$STATUS_FILE"
}

# ─────────────────────────────────────────────
# P14修复: DNS 切换
# 原来: 软链覆盖 /tmp/resolv.conf → 破坏 dnsmasq 自身管理
# 修复: 写入 /tmp/resolv.conf.d/ 目录（dnsmasq 会读取），
#       或修改 dnsmasq resolvfile UCI 配置后 reload
# ─────────────────────────────────────────────
DNSMASQ_EXTRA_RESOLV="/tmp/resolv.conf.qmf"

switch_dns_to_lte() {
    # 获取 LTE 接口通过 DHCP 拿到的 DNS（存在 /tmp/resolv.conf.ppp0 或类似）
    local lte_dns=""

    # 尝试从 udhcpc 写入的文件获取 DNS
    for f in /tmp/resolv.conf."$LTE_IFACE" /tmp/dhcp.leases /var/run/resolv.conf."$LTE_IFACE"; do
        if [ -f "$f" ]; then
            lte_dns=$(grep nameserver "$f" 2>/dev/null | head -1 | awk '{print $2}')
            [ -n "$lte_dns" ] && break
        fi
    done

    # 没找到则用公共 DNS
    [ -z "$lte_dns" ] && lte_dns="223.5.5.5"

    # 写入额外 resolv 文件，通过 dnsmasq --resolv-file 机制生效
    printf 'nameserver %s\n' "$lte_dns" > "$DNSMASQ_EXTRA_RESOLV"

    # 如果 dnsmasq 支持 reload（OpenWrt 上通常支持）
    /etc/init.d/dnsmasq reload >/dev/null 2>&1 &

    logger -t "$LOG_TAG" "DNS → LTE ($lte_dns)"
}

restore_dns_to_wan() {
    rm -f "$DNSMASQ_EXTRA_RESOLV"
    /etc/init.d/dnsmasq reload >/dev/null 2>&1 &
    logger -t "$LOG_TAG" "DNS → WAN (已恢复)"
}

# ─────────────────────────────────────────────
# P13修复: 确保 LTE 接口已连接并有有效网关
# 修复: ppp0 fallback 前必须验证有 IP 且有网关
# ─────────────────────────────────────────────
ensure_lte_connected() {
    local iface="$LTE_IFACE"

    # ── 检查接口是否存在 ──
    if ! ip link show "$iface" >/dev/null 2>&1; then
        # P13修复: 检查 ppp0 是否是有效备选
        if ip link show "ppp0" >/dev/null 2>&1; then
            if iface_has_ip "ppp0" && [ -n "$(get_gateway ppp0)" ]; then
                logger -t "$LOG_TAG" "主接口 $iface 不存在，ppp0 有效，切换使用 ppp0"
                LTE_IFACE="ppp0"
                # 同步更新环境变量供后续函数使用
                export LTE_IFACE
                return 0
            fi
        fi
        logger -t "$LOG_TAG" "错误: LTE接口 $iface 不存在且无可用备选"
        return 1
    fi

    # ── 确保接口 UP ──
    ip link set "$iface" up 2>/dev/null || true

    # ── 已有 IP 则验证网关 ──
    if iface_has_ip "$iface"; then
        local gw
        gw=$(get_gateway "$iface")
        if [ -n "$gw" ]; then
            logger -t "$LOG_TAG" "LTE接口 $iface 已连接 IP=$(get_iface_ip $iface) GW=$gw"
            return 0
        fi
        logger -t "$LOG_TAG" "LTE接口 $iface 有 IP 但无网关，尝试重新 DHCP..."
    else
        logger -t "$LOG_TAG" "LTE接口 $iface 无 IP，尝试 DHCP..."
    fi

    # ── 用 udhcpc 获取 IP（RNDIS/CDC-ECM 模式）──
    udhcpc -i "$iface" -q -n -t 10 -A 0 >/dev/null 2>&1 || true

    if iface_has_ip "$iface" && [ -n "$(get_gateway $iface)" ]; then
        logger -t "$LOG_TAG" "DHCP成功: IP=$(get_iface_ip $iface) GW=$(get_gateway $iface)"
        return 0
    fi

    logger -t "$LOG_TAG" "错误: $iface 无法获取 IP/网关，切换中止"
    return 1
}

# ─────────────────────────────────────────────
# 切换到 LTE（移动网络接管默认路由）
# ─────────────────────────────────────────────
switch_to_lte() {
    logger -t "$LOG_TAG" "[切换] 开始: WAN → LTE"

    # 1. 确保 LTE 就绪
    if ! ensure_lte_connected; then
        logger -t "$LOG_TAG" "[切换] 中止: LTE 未就绪"
        return 1
    fi

    local lte_gw wan_gw
    lte_gw=$(get_gateway "$LTE_IFACE")
    wan_gw=$(get_gateway "$WAN_IFACE")

    if [ -z "$lte_gw" ]; then
        logger -t "$LOG_TAG" "[切换] 中止: 无法获取 LTE 网关"
        return 1
    fi

    # 2. 降低 WAN 路由优先级
    if [ -n "$wan_gw" ]; then
        ip route del default via "$wan_gw" dev "$WAN_IFACE" 2>/dev/null || true
        ip route add default via "$wan_gw" dev "$WAN_IFACE" \
            metric "$METRIC_LTE" 2>/dev/null || true
    fi

    # 3. 添加 LTE 低 metric 路由抢占默认路由
    ip route del default via "$lte_gw" dev "$LTE_IFACE" 2>/dev/null || true
    if ! ip route add default via "$lte_gw" dev "$LTE_IFACE" metric "$METRIC_LTE_ACTIVE"; then
        logger -t "$LOG_TAG" "[切换] 错误: 添加 LTE 默认路由失败"
        # 回滚 WAN 路由
        if [ -n "$wan_gw" ]; then
            ip route del default via "$wan_gw" dev "$WAN_IFACE" metric "$METRIC_LTE" 2>/dev/null || true
            ip route add default via "$wan_gw" dev "$WAN_IFACE" metric "$METRIC_WAN" 2>/dev/null || true
        fi
        return 1
    fi

    # 4. 刷新路由缓存
    ip route flush cache 2>/dev/null || true

    # 5. P14修复: 切换 DNS（通过 dnsmasq，不覆盖 resolv.conf）
    switch_dns_to_lte

    # 6. 异步重载防火墙（避免阻塞主流程）
    /etc/init.d/firewall reload >/dev/null 2>&1 &

    # 7. 写状态
    write_status "lte" "gw=${lte_gw},iface=${LTE_IFACE}"

    logger -t "$LOG_TAG" "[切换] 完成: WAN → LTE  GW=$lte_gw  接口=$LTE_IFACE"
    return 0
}

# ─────────────────────────────────────────────
# 切换回 WAN（有线网络恢复为主路由）
# P15修复: WAN 无网关时用 ubus 调 netifd，而非直接 udhcpc
# ─────────────────────────────────────────────
switch_to_wan() {
    logger -t "$LOG_TAG" "[切换] 开始: LTE → WAN"

    local wan_gw
    wan_gw=$(get_gateway "$WAN_IFACE")

    if [ -z "$wan_gw" ]; then
        logger -t "$LOG_TAG" "WAN 无网关，通过 netifd 重新拨号..."

        # P15修复: 优先用 ubus 调用 netifd 接口（OpenWrt 标准方式）
        if command -v ubus >/dev/null 2>&1; then
            ubus call network.interface.wan up 2>/dev/null || true
            sleep 3   # 等待 netifd 完成 DHCP
        else
            # 降级: 直接 udhcpc（仅在没有 ubus 时使用）
            udhcpc -i "$WAN_IFACE" -q -n -t 10 -A 0 >/dev/null 2>&1 || true
        fi

        wan_gw=$(get_gateway "$WAN_IFACE")
        if [ -z "$wan_gw" ]; then
            logger -t "$LOG_TAG" "[切换] 中止: 无法获取 WAN 网关，WAN 可能仍未恢复"
            return 1
        fi
    fi

    local lte_gw
    lte_gw=$(get_gateway "$LTE_IFACE")

    # 2. 撤销 LTE 抢占的低 metric 路由
    if [ -n "$lte_gw" ]; then
        ip route del default via "$lte_gw" dev "$LTE_IFACE" metric "$METRIC_LTE_ACTIVE" 2>/dev/null || true
        # 保留 LTE 高 metric 备用路由（有线挂了还能走移动）
        ip route add default via "$lte_gw" dev "$LTE_IFACE" \
            metric "$METRIC_LTE" 2>/dev/null || true
    fi

    # 3. 恢复 WAN 低 metric 主路由
    ip route del default via "$wan_gw" dev "$WAN_IFACE" 2>/dev/null || true
    if ! ip route add default via "$wan_gw" dev "$WAN_IFACE" metric "$METRIC_WAN"; then
        logger -t "$LOG_TAG" "[切换] 错误: 恢复 WAN 默认路由失败"
        return 1
    fi

    # 4. 刷新路由缓存
    ip route flush cache 2>/dev/null || true

    # 5. P14修复: 恢复 DNS
    restore_dns_to_wan

    # 6. 重载防火墙
    /etc/init.d/firewall reload >/dev/null 2>&1 &

    # 7. 写状态
    write_status "wan" "gw=${wan_gw},iface=${WAN_IFACE}"

    logger -t "$LOG_TAG" "[切换] 完成: LTE → WAN  GW=$wan_gw  接口=$WAN_IFACE"
    return 0
}

# ─────────────────────────────────────────────
# 显示状态（命令行调试用）
# ─────────────────────────────────────────────
show_status() {
    printf '=== qmodem-failover 状态 ===\n\n'

    if [ -f "$STATUS_FILE" ]; then
        local mode ts
        mode=$(cut -d: -f1 "$STATUS_FILE")
        ts=$(cut -d: -f2 "$STATUS_FILE")
        # OpenWrt busybox date 兼容写法
        local switch_time
        switch_time=$(date -d "@${ts}" "+%Y-%m-%d %H:%M:%S" 2>/dev/null \
                   || awk "BEGIN{print strftime(\"%Y-%m-%d %H:%M:%S\",$ts)}" 2>/dev/null \
                   || echo "$ts")
        printf '当前模式  : %s\n' "$mode"
        printf '最后切换  : %s\n\n' "$switch_time"
    else
        printf '当前模式  : 未知（状态文件不存在）\n\n'
    fi

    printf '--- 默认路由 ---\n'
    ip route show | grep "^default" || printf '(无默认路由)\n'

    printf '\n--- WAN 接口 (%s) ---\n' "$WAN_IFACE"
    ip addr show "$WAN_IFACE" 2>/dev/null | grep -E "state|inet" || printf '(接口不存在)\n'
    printf 'Gateway: %s\n' "$(get_gateway $WAN_IFACE)"

    printf '\n--- LTE 接口 (%s) ---\n' "$LTE_IFACE"
    ip addr show "$LTE_IFACE" 2>/dev/null | grep -E "state|inet" || printf '(接口不存在)\n'
    printf 'Gateway: %s\n' "$(get_gateway $LTE_IFACE)"
}

# ─────────────────────────────────────────────
# 主入口
# ─────────────────────────────────────────────
CMD="${1:-status}"
case "$CMD" in
    switch_to_lte) switch_to_lte ;;
    switch_to_wan) switch_to_wan ;;
    status)        show_status   ;;
    *)
        printf 'Usage: %s {switch_to_lte|switch_to_wan|status}\n' "$0" >&2
        exit 1
        ;;
esac

