#!/bin/sh
# 在测试设备上把当前 /usr/lib/lua/luci/ 下的 frpc 相关文件备份到 $REMOTE_BACKUP_DIR
# 由 deploy.sh 自动调用一次（如果备份已存在就跳过）；也可手动重新调用强制覆盖

set -e
. "$(dirname "$0")/config.sh"

FORCE="${1:-}"

info "目标设备：$TARGET_USER@$TARGET_HOST"
info "备份目录：$REMOTE_BACKUP_DIR"

# 检查备份是否已存在
EXISTS=$(ssh_run "[ -d $REMOTE_BACKUP_DIR ] && ls $REMOTE_BACKUP_DIR 2>/dev/null | wc -l || echo 0")
if [ "$EXISTS" -gt 0 ] && [ "$FORCE" != "--force" ]; then
    ok "备份已存在（$EXISTS 个文件），跳过。如需重建用：$0 --force"
    exit 0
fi

# 构造一条 ssh 命令，把所有 REMOTE_FILES 拷贝到备份目录（保留目录结构）
CMDS="mkdir -p $REMOTE_BACKUP_DIR"
for rf in $REMOTE_FILES; do
    # 把绝对路径中的 / 替换为 _ 作为备份文件名（避免冲突 + 保留来源信息）
    bf=$(echo "$rf" | sed 's|^/||; s|/|__|g')
    CMDS="$CMDS && cp $rf $REMOTE_BACKUP_DIR/$bf"
done
CMDS="$CMDS && ls -1 $REMOTE_BACKUP_DIR | wc -l"

log "在远端执行备份..."
COUNT=$(ssh_run "$CMDS")
ok "备份完成，共 $COUNT 个文件 → $REMOTE_BACKUP_DIR"
