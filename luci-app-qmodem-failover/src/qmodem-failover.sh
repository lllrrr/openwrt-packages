#!/bin/sh
#
# qmodem-failover.sh — 主守护进程
# 修复 P9: 不再用 exec 替换进程（否则 trap 失效），改为 fork + wait
# 位置: /usr/lib/qmodem-failover/qmodem-failover.sh
#

PROG_DIR="/usr/lib/qmodem-failover"
STATUS_DIR="/var/run/qmodem-failover"
STATUS_FILE="$STATUS_DIR/status"
PID_FILE="$STATUS_DIR/checker.pid"
LOG_TAG="qmodem-failover"

# ─────────────────────────────────────────────
# 加载 UCI 配置
# 修复 P10: UCI list 用 uci -q get 逐条读取，避免末尾空格
# ─────────────────────────────────────────────
load_config() {
    ENABLED=$(uci -q get qmodem_failover.general.enabled 2>/dev/null)
    ENABLED="${ENABLED:-1}"

    WAN_IFACE=$(uci -q get qmodem_failover.general.wan_iface 2>/dev/null)
    WAN_IFACE="${WAN_IFACE:-eth0}"

    LTE_IFACE=$(uci -q get qmodem_failover.general.lte_iface 2>/dev/null)
    LTE_IFACE="${LTE_IFACE:-usb0}"

    CHECK_INTERVAL=$(uci -q get qmodem_failover.general.check_interval 2>/dev/null)
    CHECK_INTERVAL="${CHECK_INTERVAL:-3}"

    FAIL_THRESHOLD=$(uci -q get qmodem_failover.general.fail_threshold 2>/dev/null)
    FAIL_THRESHOLD="${FAIL_THRESHOLD:-3}"

    SUCCESS_THRESHOLD=$(uci -q get qmodem_failover.general.success_threshold 2>/dev/null)
    SUCCESS_THRESHOLD="${SUCCESS_THRESHOLD:-5}"

    PING_TIMEOUT=$(uci -q get qmodem_failover.general.ping_timeout 2>/dev/null)
    PING_TIMEOUT="${PING_TIMEOUT:-2}"

    METRIC_WAN=$(uci -q get qmodem_failover.general.metric_wan 2>/dev/null)
    METRIC_WAN="${METRIC_WAN:-10}"

    METRIC_LTE=$(uci -q get qmodem_failover.general.metric_lte 2>/dev/null)
    METRIC_LTE="${METRIC_LTE:-100}"

    WEBHOOK_URL=$(uci -q get qmodem_failover.notify.webhook_url 2>/dev/null)
    WEBHOOK_URL="${WEBHOOK_URL:-}"

    WEBHOOK_TYPE=$(uci -q get qmodem_failover.notify.webhook_type 2>/dev/null)
    WEBHOOK_TYPE="${WEBHOOK_TYPE:-dingtalk}"

    # P10修复: UCI list 正确读取方式 —— 用 uci -q get 返回换行分隔列表
    # 通过逐行读取构建空格分隔字符串，去除末尾空白
    CHECK_HOSTS=""
    while IFS= read -r host; do
        [ -n "$host" ] && CHECK_HOSTS="$CHECK_HOSTS $host"
    done <<EOF
$(uci -q get qmodem_failover.hosts.host 2>/dev/null)
EOF
    # strip leading space
    CHECK_HOSTS="${CHECK_HOSTS# }"
    [ -z "$CHECK_HOSTS" ] && CHECK_HOSTS="223.5.5.5 8.8.8.8 114.114.114.114"

    # 导出供子进程使用
    export WAN_IFACE LTE_IFACE CHECK_INTERVAL FAIL_THRESHOLD SUCCESS_THRESHOLD
    export PING_TIMEOUT METRIC_WAN METRIC_LTE CHECK_HOSTS
    export WEBHOOK_URL WEBHOOK_TYPE LOG_TAG STATUS_FILE STATUS_DIR PROG_DIR
}

# ─────────────────────────────────────────────
# 初始化检查
# ─────────────────────────────────────────────
init() {
    mkdir -p "$STATUS_DIR"

    # WAN 接口必须存在
    if ! ip link show "$WAN_IFACE" >/dev/null 2>&1; then
        logger -t "$LOG_TAG" "错误: WAN接口 [$WAN_IFACE] 不存在，请检查配置后重启服务"
        exit 1
    fi

    # LTE 接口不存在只警告，允许热插拔后再出现
    if ! ip link show "$LTE_IFACE" >/dev/null 2>&1; then
        logger -t "$LOG_TAG" "警告: LTE接口 [$LTE_IFACE] 暂不存在，等待 QMODEM 设备插入..."
    fi

    # 首次运行初始化状态文件
    if [ ! -f "$STATUS_FILE" ]; then
        echo "wan:$(date +%s):init" > "$STATUS_FILE"
    fi

    logger -t "$LOG_TAG" "配置加载: WAN=$WAN_IFACE LTE=$LTE_IFACE 间隔=${CHECK_INTERVAL}s 失败阈值=$FAIL_THRESHOLD 恢复阈值=$SUCCESS_THRESHOLD"
    logger -t "$LOG_TAG" "检测目标: [$CHECK_HOSTS]"
}

# ─────────────────────────────────────────────
# P9修复: 信号处理 — fork子进程而非exec，主进程保持trap有效
# 停止时向子进程发 TERM，等待其退出，再做清理
# ─────────────────────────────────────────────
CHECKER_PID=""

cleanup() {
    logger -t "$LOG_TAG" "收到停止信号，正在清理..."

    # 停止检测子进程
    if [ -n "$CHECKER_PID" ] && kill -0 "$CHECKER_PID" 2>/dev/null; then
        kill -TERM "$CHECKER_PID" 2>/dev/null
        # 等待子进程退出（最多5秒）
        local i=0
        while kill -0 "$CHECKER_PID" 2>/dev/null && [ $i -lt 5 ]; do
            sleep 1
            i=$((i + 1))
        done
        kill -KILL "$CHECKER_PID" 2>/dev/null || true
    fi

    # 服务停止时，如果当前是 LTE 模式则尝试切回 WAN
    local mode
    mode=$(cut -d: -f1 "$STATUS_FILE" 2>/dev/null)
    if [ "$mode" = "lte" ]; then
        logger -t "$LOG_TAG" "服务停止前切回 WAN..."
        sh "$PROG_DIR/switcher.sh" switch_to_wan 2>/dev/null || true
    fi

    rm -f "$PID_FILE"
    logger -t "$LOG_TAG" "清理完成，退出"
    exit 0
}

trap cleanup TERM INT QUIT HUP

# ─────────────────────────────────────────────
# 主入口
# ─────────────────────────────────────────────
main() {
    load_config

    if [ "$ENABLED" != "1" ]; then
        logger -t "$LOG_TAG" "插件已禁用 (enabled=0)，退出"
        exit 0
    fi

    init

    echo $$ > "$PID_FILE"
    logger -t "$LOG_TAG" "守护进程启动 PID=$$"

    # P9修复: fork 子进程运行检测循环，主进程 wait 它
    # 这样主进程的 trap 依然有效，能收到 TERM 信号
    sh "$PROG_DIR/wan-checker.sh" &
    CHECKER_PID=$!
    logger -t "$LOG_TAG" "检测子进程已启动 PID=$CHECKER_PID"

    # 主进程阻塞等待子进程（procd 靠主进程存活判断服务状态）
    wait "$CHECKER_PID"
    local exit_code=$?

    logger -t "$LOG_TAG" "检测子进程退出 code=$exit_code"
    rm -f "$PID_FILE"
    exit "$exit_code"
}

main "$@"

