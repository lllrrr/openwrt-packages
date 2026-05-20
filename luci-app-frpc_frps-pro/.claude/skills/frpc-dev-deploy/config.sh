#!/bin/sh
# ─────────────────────────────────────────────────────────────────
# frpc-dev-deploy 配置
# 改设备/账号只需要修改本文件，deploy/rollback/backup 自动跟随
# ─────────────────────────────────────────────────────────────────

# 测试设备
TARGET_HOST="${TARGET_HOST:-192.168.0.187}"
TARGET_USER="${TARGET_USER:-root}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/openwrt_frpc_dev}"

# 设备上的 web server 名（OpenWrt 原版=uhttpd，Kwrt/iStoreOS=nginx，ImmortalWrt 可能=uhttpd）
WEB_SERVER="${WEB_SERVER:-nginx}"

# 设备上的备份目录
REMOTE_BACKUP_DIR="${REMOTE_BACKUP_DIR:-/tmp/luci_frpc_backup}"

# 项目根（脚本所在位置往上 3 层）
SKILL_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SKILL_DIR/../../.." && pwd)"

# SSH/SCP 公共参数
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=5"

# ─────────────────────────────────────────────────────────────────
# 文件部署映射：本地路径 → 远端绝对路径
# 加新文件时，往两个数组里同步加（顺序对应）
# ─────────────────────────────────────────────────────────────────
LOCAL_FILES="
luci-app-frpc/luasrc/controller/frpc.lua
luci-app-frpc/luasrc/model/cbi/frpc/rules.lua
luci-app-frpc/luasrc/model/cbi/frpc/servers.lua
luci-app-frpc/luasrc/model/cbi/frpc/rule-detail.lua
luci-app-frpc/luasrc/model/cbi/frpc/server-detail.lua
luci-app-frpc/luasrc/model/cbi/frpc/common.lua
luci-app-frpc/luasrc/model/cbi/frpc/log.lua
luci-app-frpc/luasrc/view/frpc/status_header.htm
luci-app-frpc/luasrc/view/frpc/file_viewer.htm
luci-app-frpc/luasrc/view/frpc/frpc_log.htm
luci-app-frpc/luasrc/view/frpc/program_manager.htm
"

REMOTE_FILES="
/usr/lib/lua/luci/controller/frpc.lua
/usr/lib/lua/luci/model/cbi/frpc/rules.lua
/usr/lib/lua/luci/model/cbi/frpc/servers.lua
/usr/lib/lua/luci/model/cbi/frpc/rule-detail.lua
/usr/lib/lua/luci/model/cbi/frpc/server-detail.lua
/usr/lib/lua/luci/model/cbi/frpc/common.lua
/usr/lib/lua/luci/model/cbi/frpc/log.lua
/usr/lib/lua/luci/view/frpc/status_header.htm
/usr/lib/lua/luci/view/frpc/file_viewer.htm
/usr/lib/lua/luci/view/frpc/frpc_log.htm
/usr/lib/lua/luci/view/frpc/program_manager.htm
"

# 把空行剔掉，得到数组（POSIX shell 兼容）
LOCAL_FILES=$(echo "$LOCAL_FILES" | sed '/^$/d')
REMOTE_FILES=$(echo "$REMOTE_FILES" | sed '/^$/d')

# ─────────────────────────────────────────────────────────────────
# 工具函数
# ─────────────────────────────────────────────────────────────────
log()   { echo "[$(date '+%H:%M:%S')] $*"; }
info()  { echo "ℹ️  $*"; }
ok()    { echo "✅ $*"; }
warn()  { echo "⚠️  $*"; }
err()   { echo "❌ $*" >&2; }

ssh_run() {
    ssh $SSH_OPTS "$TARGET_USER@$TARGET_HOST" "$@"
}

scp_to() {
    # $1 = 本地路径, $2 = 远端绝对路径
    scp $SSH_OPTS "$PROJECT_ROOT/$1" "$TARGET_USER@$TARGET_HOST:$2" >/dev/null
}
