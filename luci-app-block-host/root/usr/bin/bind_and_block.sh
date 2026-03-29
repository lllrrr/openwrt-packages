#!/bin/sh

# --- 配置 ---
# 从 UCI 配置读取目标主机名
TARGET_HOSTNAMES=$(uci -q get block_host.config.hostnames)
[ -z "$TARGET_HOSTNAMES" ] && TARGET_HOSTNAMES=""
# ------------

# 定义 nftables 的名称
TABLE_NAME="filter_block"
CHAIN_FORWARD_NAME="forward_block_bad"
DHCP_FILE="/tmp/dhcp.leases"

# 检查是否启用
ENABLED=$(uci -q get block_host.config.enabled)
[ "$ENABLED" != "1" ] && exit 0

echo "[$(date)] 开始更新封锁规则... 目标列表：$TARGET_HOSTNAMES"

# 1. 初始化 nftables 环境
# 策略：每次运行都先删除旧表，重建新表。
nft delete table inet $TABLE_NAME 2>/dev/null

# 创建新表
nft add table inet $TABLE_NAME

# 创建 forward 链
nft add chain inet $TABLE_NAME $CHAIN_FORWARD_NAME '{ type filter hook forward priority 0; policy accept; }'

# 计数器
BLOCKED_COUNT=0

# 2. 遍历每个主机名
for HOSTNAME in $TARGET_HOSTNAMES; do
    # 在 DHCP 租约文件中查找
    LEASE_LINE=$(grep -i "$HOSTNAME" "$DHCP_FILE" | head -n 1)

    if [ -z "$LEASE_LINE" ]; then
        echo "  [-] 未找到主机：$HOSTNAME (可能已离线)"
        continue
    fi

    # 解析 MAC 和 IP
    CURRENT_MAC=$(echo "$LEASE_LINE" | awk '{print $2}')
    CURRENT_IP=$(echo "$LEASE_LINE" | awk '{print $3}')
    FOUND_HOSTNAME=$(echo "$LEASE_LINE" | awk '{print $4}')

    # 清理主机名中的特殊字符，确保能作为 comment (nft comment 不支持空格)
    # 将可能的空格替换为下划线
    SAFE_NAME=$(echo "$FOUND_HOSTNAME" | tr ' ' '_')

    echo "  [+] 捕获目标：Host=$SAFE_NAME, IP=$CURRENT_IP, MAC=$CURRENT_MAC"

    # 添加 IP 封锁规则 (源 + 目的)
    if [ -n "$CURRENT_IP" ]; then
        # 修复点：将 comment 内容用双引号完整包裹，变量放在里面
        nft add rule inet $TABLE_NAME $CHAIN_FORWARD_NAME ip saddr "$CURRENT_IP" counter reject comment "Block_${SAFE_NAME}_IP_Src"
        nft add rule inet $TABLE_NAME $CHAIN_FORWARD_NAME ip daddr "$CURRENT_IP" counter reject comment "Block_${SAFE_NAME}_IP_Dst"
    fi

    # 添加 MAC 封锁规则
    if [ -n "$CURRENT_MAC" ]; then
        nft add rule inet $TABLE_NAME $CHAIN_FORWARD_NAME ether saddr "$CURRENT_MAC" counter reject comment "Block_${SAFE_NAME}_MAC"
    fi

    BLOCKED_COUNT=$((BLOCKED_COUNT + 1))
done

# 3. 最终状态报告
if [ $BLOCKED_COUNT -eq 0 ]; then
    echo "[$(date)] 警告：未找到任何配置中的主机，防火墙表已清空。"
else
    echo "[$(date)] 完成：共成功封锁 $BLOCKED_COUNT 个设备。"
fi
