#!/bin/sh
# OpenVPN管理界面垃圾文件清理脚本
# 清理临时目录中的旧文件

TEMP_DIR="/tmp/openvpn-admin"
LOG_FILE="/tmp/openvpn-admin-clean.log"
RETENTION_DAYS=7

# 创建日志文件
echo "=== OpenVPN管理垃圾清理开始 $(date) ===" >> "$LOG_FILE"

# 检查目录是否存在
if [ ! -d "$TEMP_DIR" ]; then
    echo "错误：临时目录不存在: $TEMP_DIR" >> "$LOG_FILE"
    exit 1
fi

# 清理7天前的文件
echo "清理$RETENTION_DAYS天前的文件..." >> "$LOG_FILE"
find "$TEMP_DIR" -type f -mtime +$RETENTION_DAYS -delete 2>/dev/null

# 清理空目录
echo "清理空目录..." >> "$LOG_FILE"
find "$TEMP_DIR" -type d -empty -delete 2>/dev/null

# 记录清理结果
CURRENT_SIZE=$(du -sh "$TEMP_DIR" 2>/dev/null | cut -f1)
echo "清理完成。当前临时目录大小: $CURRENT_SIZE" >> "$LOG_FILE"
echo "=== OpenVPN管理垃圾清理结束 $(date) ===" >> "$LOG_FILE"