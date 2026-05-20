#!/bin/sh
# 从 $REMOTE_BACKUP_DIR 一键恢复所有 LuCI 源码 → 清缓存 → 重启服务

set -e
. "$(dirname "$0")/config.sh"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🔙 frpc-dev-deploy: 回滚到首次备份的版本"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# 确认备份存在
COUNT=$(ssh_run "[ -d $REMOTE_BACKUP_DIR ] && ls $REMOTE_BACKUP_DIR 2>/dev/null | wc -l || echo 0")
if [ "$COUNT" -eq 0 ]; then
    err "远端备份目录为空或不存在：$REMOTE_BACKUP_DIR"
    err "无法回滚。先跑 deploy.sh 至少一次生成备份"
    exit 1
fi
info "找到 $COUNT 个备份文件"

# 构造恢复命令
CMDS=""
for rf in $REMOTE_FILES; do
    bf=$(echo "$rf" | sed 's|^/||; s|/|__|g')
    if [ -z "$CMDS" ]; then
        CMDS="[ -f $REMOTE_BACKUP_DIR/$bf ] && cp $REMOTE_BACKUP_DIR/$bf $rf"
    else
        CMDS="$CMDS && [ -f $REMOTE_BACKUP_DIR/$bf ] && cp $REMOTE_BACKUP_DIR/$bf $rf"
    fi
done

log "📦 从备份恢复文件..."
ssh_run "$CMDS && echo restored"
ok "文件已恢复"

log "🧹 清缓存..."
ssh_run 'rm -rf /tmp/luci-modulecache/* /tmp/luci-indexcache* 2>/dev/null; echo cleared'

log "🔄 重启 $WEB_SERVER + rpcd..."
ssh_run "/etc/init.d/$WEB_SERVER restart 2>&1 | tail -3; [ -x /etc/init.d/rpcd ] && /etc/init.d/rpcd restart 2>&1 | tail -3 || true"

echo ""
echo "✅ 回滚完成，请浏览器 Ctrl+F5 刷新 LuCI 验证"
