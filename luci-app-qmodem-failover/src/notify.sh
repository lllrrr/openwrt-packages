#!/bin/sh
#
# notify.sh - 通知模块
# 用法: notify.sh <event_type> <message>
# event_type: failover | recover | test
# 位置: /usr/lib/qmodem-failover/notify.sh
#

: "${WEBHOOK_URL:=}"
: "${WEBHOOK_TYPE:=dingtalk}"     # dingtalk | wecom | feishu | custom
: "${LOG_TAG:=qmodem-failover}"

EVENT_TYPE="${1:-test}"
MESSAGE="${2:-测试通知}"

# ─────────────────────────────────────────────
# 获取设备信息（用于通知内容）
# ─────────────────────────────────────────────
get_device_info() {
    HOSTNAME=$(uci -q get system.@system[0].hostname 2>/dev/null || hostname)
    WAN_IP=$(ip addr show "${WAN_IFACE:-eth0}" 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1)
    LTE_IP=$(ip addr show "${LTE_IFACE:-usb0}" 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1)
    CURRENT_TIME=$(date "+%Y-%m-%d %H:%M:%S")
}

# ─────────────────────────────────────────────
# 钉钉机器人通知
# ─────────────────────────────────────────────
notify_dingtalk() {
    local title color
    case "$EVENT_TYPE" in
        failover) title="⚠️ 网络故障切换"; color="0xFF5733" ;;
        recover)  title="✅ 网络恢复正常"; color="0x28B463" ;;
        *)        title="📡 QMODEM通知";   color="0x2E86C1" ;;
    esac

    local payload
    payload=$(cat <<EOF
{
    "msgtype": "markdown",
    "markdown": {
        "title": "${title}",
        "text": "### ${title}\n\n**设备:** ${HOSTNAME}\n\n**事件:** ${MESSAGE}\n\n**时间:** ${CURRENT_TIME}\n\n**WAN IP:** ${WAN_IP:-无}\n\n**LTE IP:** ${LTE_IP:-无}"
    }
}
EOF
)
    curl -s -X POST \
        -H "Content-Type: application/json" \
        -d "$payload" \
        --max-time 10 \
        "$WEBHOOK_URL" >/dev/null 2>&1
}

# ─────────────────────────────────────────────
# 企业微信机器人通知
# ─────────────────────────────────────────────
notify_wecom() {
    local payload
    payload=$(cat <<EOF
{
    "msgtype": "markdown",
    "markdown": {
        "content": "**QMODEM故障切换通知**\n>设备: <font color=\"comment\">${HOSTNAME}</font>\n>事件: <font color=\"warning\">${MESSAGE}</font>\n>时间: ${CURRENT_TIME}\n>WAN IP: ${WAN_IP:-无}\n>LTE IP: ${LTE_IP:-无}"
    }
}
EOF
)
    curl -s -X POST \
        -H "Content-Type: application/json" \
        -d "$payload" \
        --max-time 10 \
        "$WEBHOOK_URL" >/dev/null 2>&1
}

# ─────────────────────────────────────────────
# 飞书机器人通知
# ─────────────────────────────────────────────
notify_feishu() {
    local payload
    payload=$(cat <<EOF
{
    "msg_type": "text",
    "content": {
        "text": "[QMODEM] ${MESSAGE}\n设备: ${HOSTNAME}\n时间: ${CURRENT_TIME}\nWAN: ${WAN_IP:-无} | LTE: ${LTE_IP:-无}"
    }
}
EOF
)
    curl -s -X POST \
        -H "Content-Type: application/json" \
        -d "$payload" \
        --max-time 10 \
        "$WEBHOOK_URL" >/dev/null 2>&1
}

# ─────────────────────────────────────────────
# 主入口
# ─────────────────────────────────────────────
main() {
    # 没有配置 Webhook，只记日志
    if [ -z "$WEBHOOK_URL" ]; then
        logger -t "$LOG_TAG" "[通知] Webhook未配置，跳过推送: $MESSAGE"
        return 0
    fi

    get_device_info

    logger -t "$LOG_TAG" "[通知] 发送 $WEBHOOK_TYPE 通知: $MESSAGE"

    case "$WEBHOOK_TYPE" in
        dingtalk) notify_dingtalk ;;
        wecom)    notify_wecom    ;;
        feishu)   notify_feishu  ;;
        *)
            # custom: 直接 POST JSON body
            curl -s -X POST \
                -H "Content-Type: application/json" \
                -d "{\"event\":\"$EVENT_TYPE\",\"message\":\"$MESSAGE\",\"device\":\"$HOSTNAME\",\"time\":\"$CURRENT_TIME\"}" \
                --max-time 10 \
                "$WEBHOOK_URL" >/dev/null 2>&1
            ;;
    esac

    if [ $? -eq 0 ]; then
        logger -t "$LOG_TAG" "[通知] 发送成功"
    else
        logger -t "$LOG_TAG" "[通知] 发送失败"
    fi
}

main

