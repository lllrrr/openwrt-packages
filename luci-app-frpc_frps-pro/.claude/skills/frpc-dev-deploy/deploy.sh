#!/bin/sh
# 一键部署：scp 推送所有 LuCI 源码 → 清 LuCI 缓存 → 重启 web server + rpcd
# 部署前自动调用 backup.sh 做一次备份（仅首次，已有就跳过）

set -e
. "$(dirname "$0")/config.sh"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🚀 frpc-dev-deploy: 推送本地源码 → $TARGET_HOST"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ──── 0. 连通性检查 ────────────────────────────────
log "🔌 SSH 连通性测试..."
if ! ssh_run 'echo ok' >/dev/null 2>&1; then
    err "无法 SSH 到 $TARGET_USER@$TARGET_HOST"
    err "检查：1) 设备在线 2) SSH key 在 $SSH_KEY 3) 公钥已在远端 authorized_keys"
    exit 1
fi
ok "SSH 联通"

# ──── 1. 首次备份（已存在则跳过） ──────────────────
log "💾 备份远端原文件（首次执行才会备份）..."
sh "$SKILL_DIR/backup.sh"

# ──── 2. 推送本地文件 ──────────────────────────────
log "📤 推送本地源码..."
# POSIX shell 用 paste 把两个列表逐行配对
i=1
PUSHED=0
SKIPPED=0
for lf in $LOCAL_FILES; do
    rf=$(echo "$REMOTE_FILES" | sed -n "${i}p")
    i=$((i+1))

    if [ ! -f "$PROJECT_ROOT/$lf" ]; then
        warn "本地文件不存在，跳过：$lf"
        SKIPPED=$((SKIPPED+1))
        continue
    fi

    scp_to "$lf" "$rf"
    PUSHED=$((PUSHED+1))
    echo "  ✓ $lf → $rf"
done
ok "已推送 $PUSHED 个文件（跳过 $SKIPPED 个）"

# ──── 3. 清 LuCI 缓存 ──────────────────────────────
log "🧹 清 LuCI 模块/索引缓存..."
ssh_run 'rm -rf /tmp/luci-modulecache/* /tmp/luci-indexcache* 2>/dev/null; echo cleared'
ok "缓存已清"

# ──── 4. 重启 web server 和 rpcd ───────────────────
log "🔄 重启 $WEB_SERVER + rpcd..."
ssh_run "/etc/init.d/$WEB_SERVER restart 2>&1 | tail -3; [ -x /etc/init.d/rpcd ] && /etc/init.d/rpcd restart 2>&1 | tail -3 || true"
ok "服务已重启"

# ──── 5. 健康检查 ──────────────────────────────────
log "🩺 健康检查（等 1s 让服务起来）..."
sleep 1
HEALTH=$(ssh_run "ps w 2>/dev/null | grep -E '$WEB_SERVER|rpcd' | grep -v grep | wc -l")
if [ "$HEALTH" -ge 2 ]; then
    ok "$WEB_SERVER + rpcd 都在跑（共 $HEALTH 个相关进程）"
else
    warn "进程数异常（$HEALTH），可能服务没起来。手动 ssh 查看"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ 部署完成"
echo ""
echo "📱 浏览器测试入口："
echo "   规则页：     http://$TARGET_HOST/cgi-bin/luci/admin/services/frpc/rules"
echo "   服务器页：   http://$TARGET_HOST/cgi-bin/luci/admin/services/frpc/servers"
echo "   设置页：     http://$TARGET_HOST/cgi-bin/luci/admin/services/frpc/common"
echo ""
echo "🔙 如有问题秒回滚：sh $SKILL_DIR/rollback.sh"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
