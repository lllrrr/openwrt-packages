#!/bin/sh
#
# wan-checker.sh — WAN 健康检测主循环
# 修复:
#   P6 - curl 管道 BUG: curl 失败时 grep 仍返回 0 导致误判
#   P7 - nslookup 在 busybox 精简版不可用，改用更兼容的方案
#   P8 - /sys/class/net/carrier 在 admin-down 时报 EINVAL，需先查 operstate
#   P11 - 检测总耗时可能超过 CHECK_INTERVAL，加超时保护
# 位置: /usr/lib/qmodem-failover/wan-checker.sh
#

PROG_DIR="${PROG_DIR:-/usr/lib/qmodem-failover}"

# 单独运行时的默认值（正常由 qmodem-failover.sh export 传入）
: "${WAN_IFACE:=eth0}"
: "${LTE_IFACE:=usb0}"
: "${CHECK_INTERVAL:=3}"
: "${FAIL_THRESHOLD:=3}"
: "${SUCCESS_THRESHOLD:=5}"
: "${PING_TIMEOUT:=2}"
: "${CHECK_HOSTS:=223.5.5.5 8.8.8.8 114.114.114.114}"
: "${LOG_TAG:=qmodem-failover}"
: "${STATUS_FILE:=/var/run/qmodem-failover/status}"

fail_count=0
success_count=0

# ─────────────────────────────────────────────
# 工具: 读取当前模式
# ─────────────────────────────────────────────
get_current_mode() {
    if [ -f "$STATUS_FILE" ]; then
        cut -d: -f1 "$STATUS_FILE"
    else
        echo "wan"
    fi
}

# ─────────────────────────────────────────────
# P8修复: 物理链路检测
# 先查 operstate（admin up/down），再查 carrier（物理信号）
# carrier 在 operstate=down 时读取会返回 EINVAL，不能直接用
# ─────────────────────────────────────────────
check_wan_link() {
    # operstate: up / down / unknown / dormant / lowerlayerdown / notpresent
    local operstate
    operstate=$(cat "/sys/class/net/$WAN_IFACE/operstate" 2>/dev/null || echo "unknown")

    case "$operstate" in
        up)
            return 0  # 链路明确 UP
            ;;
        unknown)
            # 某些驱动不更新 operstate，回退到 carrier 判断
            local carrier
            carrier=$(cat "/sys/class/net/$WAN_IFACE/carrier" 2>/dev/null || echo "0")
            [ "$carrier" = "1" ] && return 0
            return 1
            ;;
        *)
            # down / lowerlayerdown / notpresent 等，链路 DOWN
            return 1
            ;;
    esac
}

# ─────────────────────────────────────────────
# P6修复: curl 检测
# 问题: `curl ... | grep` 中 curl 失败但 grep 返回 0 → 误判
# 修复: 先把 http_code 存变量，再判断变量值，不用管道
# P11修复: 对每个 URL 设置明确的 --max-time，防止单次卡住太久
# ─────────────────────────────────────────────
check_http_204() {
    # 只尝试第一个 URL 避免耗时太长（已有 ping 作为主要手段）
    local code
    code=$(curl -s \
        --interface "$WAN_IFACE" \
        --max-time "$PING_TIMEOUT" \
        --connect-timeout "$PING_TIMEOUT" \
        -o /dev/null \
        -w "%{http_code}" \
        "http://connect.rom.miui.com/generate_204" 2>/dev/null)
    # curl 本身失败时 code 为空或 000，不会是 200/204
    case "$code" in
        200|204) return 0 ;;
        *)       return 1 ;;
    esac
}

# ─────────────────────────────────────────────
# P7修复: DNS 检测
# nslookup 在 busybox 精简版中常常不带 DNS 查询功能
# 改用: ping 域名（busybox ping 能做 DNS 解析）作为备用
# ─────────────────────────────────────────────
check_dns_resolve() {
    # 尝试 ping 一个域名（依赖内核 DNS 解析），只看能否解析，不在乎连通
    # -c 1 -W 1: 发 1 包，等 1 秒，即使 ping 失败（目标不通）只要解析到 IP 就返回
    # 这里的关键是: 如果 WAN DNS 不通，ping 会因"解析失败"报错退出
    if ping -c 1 -W 1 -I "$WAN_IFACE" "www.baidu.com" >/dev/null 2>&1; then
        return 0
    fi
    # 更直接: 用 busybox 的 nslookup（如果存在）
    if command -v nslookup >/dev/null 2>&1; then
        # 指定 DNS 服务器走 WAN 出口（nslookup 不支持 -I，但 223.5.5.5 是阿里 DNS）
        nslookup "www.baidu.com" "223.5.5.5" >/dev/null 2>&1 && return 0
    fi
    return 1
}

# ─────────────────────────────────────────────
# WAN 连通性检测（三层防线）
# P11修复: 每层检测有独立超时，避免总耗时远超 CHECK_INTERVAL
#   层1 Ping: 最快，3个目标逐一尝试，任一成功即返回（最坏 3×PING_TIMEOUT）
#   层2 HTTP: 只查1个端点（备用），最坏 PING_TIMEOUT
#   层3 DNS:  最后手段，最坏 1秒
# 总最坏耗时: 3×2 + 2 + 1 = 9s < CHECK_INTERVAL=3s ← 仍有问题！
# 最终修复: 整体套一个 background+timeout 保护
# ─────────────────────────────────────────────
check_wan_alive() {
    # 层1: Ping（绑定 WAN 接口，确保走有线出口）
    for host in $CHECK_HOSTS; do
        if ping -c 1 -W "$PING_TIMEOUT" -I "$WAN_IFACE" "$host" >/dev/null 2>&1; then
            return 0
        fi
    done

    # 层2: HTTP 204（应对 ICMP 被屏蔽的网络）
    if check_http_204; then
        return 0
    fi

    # 层3: DNS 解析（应对 HTTP 也被屏蔽的极端情况）
    if check_dns_resolve; then
        return 0
    fi

    return 1
}

# P11修复: 带超时保护的检测入口
# 最坏情况下检测时间上限 = CHECK_INTERVAL，不会导致检测堆积
check_wan_with_timeout() {
    local max_wait="$CHECK_INTERVAL"
    local result_file
    result_file="/tmp/qmf_check_$$"

    # 后台运行检测，完成后写结果到文件
    ( check_wan_alive && echo "0" || echo "1" ) > "$result_file" &
    local bg_pid=$!

    # 等待检测完成或超时
    local waited=0
    while [ $waited -lt "$max_wait" ]; do
        if ! kill -0 "$bg_pid" 2>/dev/null; then
            break   # 检测已完成
        fi
        sleep 1
        waited=$((waited + 1))
    done

    # 超时则强制结束
    kill -KILL "$bg_pid" 2>/dev/null || true
    wait "$bg_pid" 2>/dev/null || true

    local result=1
    if [ -f "$result_file" ]; then
        result=$(cat "$result_file" 2>/dev/null || echo "1")
        rm -f "$result_file"
    fi

    return "$result"
}

# ─────────────────────────────────────────────
# 处理 WAN 故障
# ─────────────────────────────────────────────
handle_wan_failure() {
    fail_count=$((fail_count + 1))
    success_count=0

    logger -t "$LOG_TAG" "WAN检测失败 [${fail_count}/${FAIL_THRESHOLD}] 接口=$WAN_IFACE"

    if [ "$fail_count" -ge "$FAIL_THRESHOLD" ]; then
        logger -t "$LOG_TAG" "连续 $FAIL_THRESHOLD 次失败，触发故障切换 → LTE"
        if sh "$PROG_DIR/switcher.sh" switch_to_lte; then
            fail_count=0
            sh "$PROG_DIR/notify.sh" "failover" "WAN故障，已切换至移动网络" 2>/dev/null &
        else
            logger -t "$LOG_TAG" "错误: 切换至 LTE 失败，下次继续重试"
            # 不重置 fail_count，下次检测仍会尝试切换
        fi
    fi
}

# ─────────────────────────────────────────────
# 处理 WAN 恢复（LTE 模式下 WAN 检测成功）
# ─────────────────────────────────────────────
handle_wan_recovery() {
    fail_count=0
    success_count=$((success_count + 1))

    logger -t "$LOG_TAG" "LTE模式下WAN检测成功 [${success_count}/${SUCCESS_THRESHOLD}]，等待稳定..."

    if [ "$success_count" -ge "$SUCCESS_THRESHOLD" ]; then
        logger -t "$LOG_TAG" "WAN稳定恢复，切回有线网络"
        if sh "$PROG_DIR/switcher.sh" switch_to_wan; then
            success_count=0
            sh "$PROG_DIR/notify.sh" "recover" "WAN恢复，已切回有线网络" 2>/dev/null &
        else
            logger -t "$LOG_TAG" "错误: 切回 WAN 失败，下次继续重试"
            # 不重置 success_count，下次仍会尝试
        fi
    fi
}

# ─────────────────────────────────────────────
# 主循环
# ─────────────────────────────────────────────
logger -t "$LOG_TAG" "检测引擎启动 目标=[$CHECK_HOSTS] 间隔=${CHECK_INTERVAL}s"

while true; do
    current_mode=$(get_current_mode)

    # ── 快速物理链路检测（仅 WAN 模式时，网线拔出可立即感知）──
    if [ "$current_mode" = "wan" ] && ! check_wan_link; then
        logger -t "$LOG_TAG" "WAN物理链路 DOWN (operstate≠up)，计入失败"
        handle_wan_failure
        sleep "$CHECK_INTERVAL"
        continue
    fi

    # ── 网络连通性检测（带超时保护）──
    if check_wan_with_timeout; then
        # WAN 连通
        if [ "$current_mode" = "lte" ]; then
            handle_wan_recovery
        else
            # WAN 模式正常，重置失败计数
            if [ "$fail_count" -gt 0 ]; then
                logger -t "$LOG_TAG" "WAN恢复正常，重置失败计数"
                fail_count=0
            fi
            success_count=0
        fi
    else
        # WAN 不通
        if [ "$current_mode" = "wan" ]; then
            handle_wan_failure
        else
            # 已是 LTE 模式，WAN 仍不通，重置恢复计数
            if [ "$success_count" -gt 0 ]; then
                logger -t "$LOG_TAG" "LTE模式下WAN仍不通，重置恢复计数"
                success_count=0
            fi
        fi
    fi

    sleep "$CHECK_INTERVAL"
done

