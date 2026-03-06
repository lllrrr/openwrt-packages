#!/bin/sh
# OpenVPN client-connect脚本，用于检查客户端CN是否在黑名单中

# 读取openvpn-admin配置获取黑名单文件路径
if [ -f /etc/config/openvpn-admin ]; then
    # 从配置文件中读取黑名单文件路径
    BLACKLIST_FILE=$(uci -q get openvpn-admin.@settings[0].blacklist_file 2>/dev/null || echo "/etc/openvpn/blacklist.json")
else
    BLACKLIST_FILE="/etc/openvpn/blacklist.json"
fi

LOG_TAG="openvpn-client-connect"

# 记录开始
logger -t "$LOG_TAG" "客户端连接处理开始，环境变量:"
env | grep -E "common_name|client_cn|trusted_ip" | while read line; do
    logger -t "$LOG_TAG" "  $line"
done

# 获取客户端CN
CLIENT_CN=""

# 方法1: 从环境变量获取
if [ -n "$common_name" ]; then
    CLIENT_CN="$common_name"
    logger -t "$LOG_TAG" "从环境变量获取CN: $CLIENT_CN"
fi

# 方法2: 如果没有common_name，尝试从其他变量获取
if [ -z "$CLIENT_CN" ] && [ -n "$X509_0_CN" ]; then
    CLIENT_CN="$X509_0_CN"
    logger -t "$LOG_TAG" "从X509变量获取CN: $CLIENT_CN"
fi

if [ -z "$CLIENT_CN" ]; then
    logger -t "$LOG_TAG" "警告：无法获取客户端CN，允许连接"
    # 无法验证时允许连接
    echo "INFO: 无法验证客户端CN，允许连接"
    exit 0
fi

logger -t "$LOG_TAG" "开始验证客户端CN: $CLIENT_CN"

# 检查黑名单文件是否存在
if [ ! -f "$BLACKLIST_FILE" ]; then
    logger -t "$LOG_TAG" "黑名单文件不存在，允许连接: $CLIENT_CN"
    echo "INFO: 允许连接: $CLIENT_CN"
    exit 0
fi

# 检查JSON格式
if ! jq -e . "$BLACKLIST_FILE" >/dev/null 2>&1; then
    logger -t "$LOG_TAG" "黑名单文件格式错误，允许连接: $CLIENT_CN"
    echo "INFO: 黑名单文件格式错误，允许连接"
    exit 0
fi

# 获取当前时间戳
CURRENT_TIME=$(date +%s)

# 检查客户端CN是否在黑名单中且未过期
BLOCK_REASON=$(jq -r --arg cn "$CLIENT_CN" --arg time "$CURRENT_TIME" '
    .entries[] |
    select(.cn == $cn and (.expiry_time | tonumber) > ($time | tonumber)) |
    "原因: " + (.reason // "未知") + "，过期时间: " + (.expiry_time_formatted // "未知")
' "$BLACKLIST_FILE" 2>/dev/null)

if [ -n "$BLOCK_REASON" ]; then
    logger -t "$LOG_TAG" "拒绝客户端连接: $CLIENT_CN - $BLOCK_REASON"
    # 输出拒绝消息给客户端
    echo "client-deny \"CN $CLIENT_CN 在黑名单中: $BLOCK_REASON\""
    # 返回1表示拒绝连接
    exit 1
fi

# 允许连接
logger -t "$LOG_TAG" "允许客户端连接: $CLIENT_CN"
echo "INFO: 允许连接: $CLIENT_CN"
exit 0