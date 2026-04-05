#!/bin/sh
#===========================================================
#  ClawPanel install.sh v3
#  统一目录: /Configs/clawpanel /Configs/openclaw /Configs/.openclaw
#  Node.js: 系统级安装到 /usr/local/bin/
#
#  用法:
#    CP_BASE_PATH=/mnt/sda1 sh install.sh    # 手动指定存储盘
#    sh install.sh                           # 自动检测最大可用盘
#===========================================================
set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

log()   { echo "${GREEN}[✓]${NC} $1"; }
info()  { echo "${BLUE}[ℹ]${NC} $1"; }
warn()  { echo "${YELLOW}[!]${NC} $1"; }
err()   { echo "${RED}[✗]${NC} $1" >&2; }
step()  { echo ""; echo "${CYAN}═══ $1 ═══${NC}"; }
pr()    { echo "${BLUE}▸${NC} $1"; }
done_() { echo "${GREEN}[✓]${NC} $1"; }

#===========================================================
# 全局
#===========================================================
ARCH="$(uname -m)"
case "$ARCH" in
    aarch64|arm64) TARGET_ARCH="aarch64" ;;
    x86_64)        TARGET_ARCH="x64" ;;
    armv7l|armv7)  TARGET_ARCH="armv7l" ;;
    *)             err "不支持架构: $ARCH"; exit 1 ;;
esac

CP_BASE_PATH="${CP_BASE_PATH:-}"
CP_VERSION="${CP_VERSION:-latest}"

clear
echo "╔══════════════════════════════════════════════════╗"
echo "║   ClawPanel 一键安装脚本 v3                     ║"
echo "║   /Configs 统一目录 · Node.js 系统级安装          ║"
echo "╚══════════════════════════════════════════════════╝"

[ "$(id -u)" = "0" ] || { err "必须以 root 运行"; exit 1; }
info "架构: $ARCH → $TARGET_ARCH"
info "时间: $(date '+%Y-%m-%d %H:%M:%S')"

#===========================================================
# 检测存储
#===========================================================
step "检测存储位置"

if [ -n "$CP_BASE_PATH" ]; then
    info "手动指定: $CP_BASE_PATH"
else
    pr "扫描可用存储..."
    BEST=""
    BEST_AVAIL=0
    for mp in $(df -m | awk '$6 ~ /^\/mnt/ || $6 ~ /^\/ext/ || $6 ~ /^\/storage/ {print $6":"$4}' | sort -t: -k2 -rn); do
        mount_point=$(echo "$mp" | cut -d: -f1)
        avail_mb=$(echo "$mp" | cut -d: -f2)
        if [ "$avail_mb" -ge 500 ] && [ "$avail_mb" -gt "$BEST_AVAIL" ]; then
            BEST="$mount_point"
            BEST_AVAIL="$avail_mb"
            info "  发现: $mount_point (可用 ${avail_mb}MB)"
        fi
    done
    if [ -z "$BEST" ]; then
        warn "未找到外部存储，使用 /opt"
        BEST="/opt"
    fi
    CP_BASE_PATH="$BEST"
fi

CP_BASE_PATH="${CP_BASE_PATH%/}"

# 验证非系统路径
case "$CP_BASE_PATH" in
    /|/overlay|/rom|/boot|/proc|/sys|/dev|/tmp|/var|/etc|/root|/usr)
        err "禁止使用系统路径: $CP_BASE_PATH"
        exit 1 ;;
esac

[ -d "$CP_BASE_PATH" ] || { err "目录不存在: $CP_BASE_PATH"; exit 1; }

log "存储: $CP_BASE_PATH ($(df -h "$CP_BASE_PATH" | tail -1 | awk '{print $4}' 可用))"

# /Configs 结构
CONFIGS_DIR="${CP_BASE_PATH}/Configs"
NODE_DIR="${CONFIGS_DIR}/node"
OPENCLAW_DIR="${CONFIGS_DIR}/openclaw"
OPENCLAW_DATA="${CONFIGS_DIR}/.openclaw"
OPENCLAW_WORK="${CONFIGS_DIR}/.openclaw-work"
CLAWPANEL_DIR="${CONFIGS_DIR}/clawpanel"
CLAWPANEL_DATA="${CLAWPANEL_DIR}/data"

#===========================================================
# 目录
#===========================================================
step "创建目录"
mkdir -p "$CONFIGS_DIR" "$CLAWPANEL_DIR" "$CLAWPANEL_DATA"
mkdir -p "$OPENCLAW_DIR" "$OPENCLAW_DATA" "$OPENCLAW_WORK"
log "目录就绪"
echo "  $CONFIGS_DIR/"
echo "  ├── clawpanel/"
echo "  ├── openclaw/"
echo "  ├── .openclaw/"
echo "  └── .openclaw-work/"

#===========================================================
# Node.js（系统级）
#===========================================================
step "安装 Node.js（系统级 → /usr/local/bin/node）"

if command -v node >/dev/null 2>&1; then
    log "Node.js 已安装: $(node --version)"
elif [ -x "/usr/local/bin/node" ]; then
    log "Node.js 已安装: $(/usr/local/bin/node --version)"
else
    pr "获取最新 LTS 版本..."
    NODE_VER=$(curl -sL --max-time 10 "https://nodejs.org/dist/index.json" 2>/dev/null \
        | grep -o '"version":"v[0-9][^"]*lts[^"]*"' \
        | head -1 | grep -o 'v[0-9][^"]*' || echo "v22.15.1")
    : "${NODE_VER:=v22.15.1}"
    info "版本: $NODE_VER"

    NODE_TGZ="/tmp/node-${TARGET_ARCH}.tar.xz"
    pr "下载..."
    URL="https://npmmirror.com/mirrors/node/${NODE_VER}/node-${NODE_VER}-linux-${TARGET_ARCH}.tar.xz"
    curl -fsSL --connect-timeout 15 -o "$NODE_TGZ" "$URL" || {
        URL="https://nodejs.org/download/release/${NODE_VER}/node-${NODE_VER}-linux-${TARGET_ARCH}.tar.xz"
        curl -fsSL --connect-timeout 15 -o "$NODE_TGZ" "$URL" || { err "Node.js 下载失败"; exit 1; }
    }
    pr "解压到 /usr/local..."
    mkdir -p /usr/local/bin /usr/local/lib /usr/local/share
    tar -xJf "$NODE_TGZ" -C /tmp
    NODE_SRC=""
    for d in /tmp/node-*; do [ -d "$d" ] && NODE_SRC="$d"; done
    [ -n "$NODE_SRC" ] && {
        cp -a "$NODE_SRC/bin/node" /usr/local/bin/
        cp -a "$NODE_SRC/bin/npm"  /usr/local/bin/
        cp -a "$NODE_SRC/bin/npx"  /usr/local/bin/ 2>/dev/null || true
        cp -a "$NODE_SRC/lib/"*    /usr/local/lib/
        [ -d "$NODE_SRC/share/icu" ] && cp -a "$NODE_SRC/share/icu" /usr/local/share/
        chmod +x /usr/local/bin/node /usr/local/bin/npm /usr/local/bin/npx 2>/dev/null || true
    }
    rm -f "$NODE_TGZ"
    rm -rf /tmp/node-*
    log "Node.js: $(/usr/local/bin/node --version)"
    log "npm: $(/usr/local/bin/npm --version)"
fi

# npm wrapper
cat > /usr/local/bin/npm << 'NPMEOF'
#!/bin/sh
SELF="$(readlink -f "$0" 2>/dev/null || echo "$0")"
BASE="$(cd "$(dirname "$SELF")/.." && pwd)"
export NODE_ICU_DATA="${BASE}/share/icu"
export LD_LIBRARY_PATH="${BASE}/lib:$LD_LIBRARY_PATH"
exec "${BASE}/bin/node" "${BASE}/lib/node_modules/npm/bin/npm-cli.js" "$@"
NPMEOF
chmod +x /usr/local/bin/npm

# profile.d
mkdir -p /etc/profile.d
cat > /etc/profile.d/node.sh << 'EOF'
#!/bin/sh
export PATH="/usr/local/bin:$PATH"
export NODE_ICU_DATA="/usr/local/share/icu"
export LD_LIBRARY_PATH="/usr/local/lib:$LD_LIBRARY_PATH"
EOF
chmod +x /etc/profile.d/node.sh
done_ "Node.js 环境"

#===========================================================
# Git + Python3
#===========================================================
step "基础工具"
for pkg in git python3; do
    if command -v $pkg >/dev/null 2>&1; then
        info "$pkg 已安装"
    else
        pr "安装 $pkg..."
        opkg update 2>/dev/null && opkg install $pkg 2>/dev/null || warn "$pkg 安装失败"
    fi
done
done_ "基础工具"

#===========================================================
# OpenClaw
#===========================================================
step "安装 OpenClaw"

export PATH="/usr/local/bin:$PATH"
export NODE_ICU_DATA="/usr/local/share/icu"
export LD_LIBRARY_PATH="/usr/local/lib:$LD_LIBRARY_PATH"

if [ -d "${OPENCLAW_DIR}/node_modules/openclaw" ]; then
    info "OpenClaw 已存在"
elif [ -d "/usr/local/lib/node_modules/openclaw" ]; then
    info "使用全局 OpenClaw"
else
    pr "安装 OpenClaw npm..."
    mkdir -p "$OPENCLAW_DIR"
    /usr/local/bin/npm install -g openclaw \
        --prefix "$OPENCLAW_DIR" \
        --registry https://registry.npmmirror.com 2>&1 | tail -3 || {
        /usr/local/bin/npm install -g openclaw \
            --prefix "$OPENCLAW_DIR" \
            --registry https://registry.npmjs.org 2>&1 | tail -3 || {
            err "OpenClaw 安装失败"; exit 1; }
    }
fi

OPENCLAW_MJS=""
for p in "${OPENCLAW_DIR}/node_modules/openclaw/openclaw.mjs" \
         "${OPENCLAW_DIR}/lib/node_modules/openclaw/openclaw.mjs"; do
    [ -f "$p" ] && OPENCLAW_MJS="$p" && break
done

[ -z "$OPENCLAW_MJS" ] && OPENCLAW_MJS="/usr/local/lib/node_modules/openclaw/openclaw.mjs"
[ -f "$OPENCLAW_MJS" ] || { err "找不到 openclaw.mjs"; exit 1; }

mkdir -p /usr/local/lib/node_modules
rm -rf /usr/local/lib/node_modules/openclaw
ln -sf "$(dirname "$OPENCLAW_MJS")" /usr/local/lib/node_modules/openclaw

cat > /usr/local/bin/openclaw << OCEOF
#!/bin/sh
export NODE_ICU_DATA="/usr/local/share/icu"
export LD_LIBRARY_PATH="/usr/local/lib:\$LD_LIBRARY_PATH"
export PATH="/usr/local/bin:\$PATH"
exec /usr/local/bin/node "$OPENCLAW_MJS" "\$@"
OCEOF
chmod +x /usr/local/bin/openclaw
ln -sf /usr/local/bin/openclaw /usr/bin/openclaw 2>/dev/null || true
done_ "OpenClaw"

#===========================================================
# ClawPanel 二进制
#===========================================================
step "安装 ClawPanel 二进制"

if [ -x "${CLAWPANEL_DIR}/clawpanel" ]; then
    info "二进制已存在: $(cat ${CLAWPANEL_DIR}/.version 2>/dev/null || echo '')"
else
    # 获取版本
    if [ "$CP_VERSION" = "latest" ] || [ -z "$CP_VERSION" ]; then
        LATEST=$(curl -sL --max-time 10 \
            "https://api.github.com/repos/zhaoxinyi02/ClawPanel/releases" \
            | grep -o '"tag_name"[^,]*' | grep '"tag_name"' | head -1 \
            | cut -d'"' -f4 | grep '^pro-' | head -1 || echo "pro-v5.3.3")
    else
        LATEST="$CP_VERSION"
    fi
    info "版本: $LATEST"

    FILE_VER=$(echo "$LATEST" | sed 's/^pro-v/v/;s/^lite-v/v/')
    URL="https://github.com/zhaoxinyi02/ClawPanel/releases/download/${LATEST}/clawpanel-${FILE_VER}-linux-${TARGET_ARCH}"
    pr "下载: $(basename $URL)"
    TMP="/tmp/clawpanel_bin_$$"
    curl -fsSL --connect-timeout 30 --max-time 600 -o "$TMP" "$URL" || {
        err "下载失败"; rm -f "$TMP"; exit 1; }
    mv -f "$TMP" "${CLAWPANEL_DIR}/clawpanel"
    chmod +x "${CLAWPANEL_DIR}/clawpanel"
fi

echo "$LATEST" > "${CLAWPANEL_DIR}/.version"
done_ "ClawPanel 二进制"

#===========================================================
# 配置文件
#===========================================================
step "配置文件"

# clawpanel.json
cat > "${CLAWPANEL_DATA}/clawpanel.json" << CEOF
{
  "port": 19527,
  "dataDir": "${CLAWPANEL_DATA}",
  "openClawDir": "${OPENCLAW_DATA}",
  "openClawApp": "$(dirname $OPENCLAW_MJS)",
  "openClawWork": "${OPENCLAW_WORK}",
  "edition": "pro",
  "jwtSecret": "clawpanel-secret-change-me",
  "adminToken": "clawpanel",
  "debug": false
}
CEOF
done_ "clawpanel.json"

# openclaw.json
if [ ! -f "${OPENCLAW_DATA}/openclaw.json" ]; then
    mkdir -p "${OPENCLAW_DATA}"
    cat > "${OPENCLAW_DATA}/openclaw.json" << 'EOF'
{
  "agents": { "defaults": { "model": { "primary": "claude-sonnet-4-6" } } }
}
EOF
fi
done_ "openclaw.json"

# UCI
uci set clawpanel.main='clawpanel' 2>/dev/null || uci add clawpanel main 2>/dev/null || true
uci set clawpanel.main.enabled='1'
uci set clawpanel.main.disk="$CP_BASE_PATH"
uci set clawpanel.main.install_path="$CONFIGS_DIR"
uci set clawpanel.main.port='19527'
uci set clawpanel.main.version="$LATEST"
uci commit clawpanel 2>/dev/null || true
done_ "UCI"

#===========================================================
# 服务
#===========================================================
step "服务脚本"
cat > /etc/init.d/clawpanel << 'IDEOF'
#!/bin/sh /etc/rc.common
USE_PROCD=0
START=99
STOP=10
_load() {
    CP_BASE_PATH="$(uci -q get clawpanel.main.disk || echo '')"
    CONFIGS_DIR="${CP_BASE_PATH}/Configs"
    CLAWPANEL_BIN="${CONFIGS_DIR}/clawpanel/clawpanel"
    CLAWPANEL_DATA="${CONFIGS_DIR}/clawpanel/data"
}
start_service() {
    _load
    [ "$(uci -q get clawpanel.main.enabled)" = "1" ] || return 0
    [ -x "$CLAWPANEL_BIN" ] || return 1
    mkdir -p "$CLAWPANEL_DATA"
    stop_service
    (
        export HOME="/root"
        export PATH="/usr/local/bin:$PATH"
        export NODE_ICU_DATA="/usr/local/share/icu"
        export LD_LIBRARY_PATH="/usr/local/lib:$LD_LIBRARY_PATH"
        setsid /bin/bash -c "$CLAWPANEL_BIN >> /tmp/clawpanel.log 2>&1 &"
    )
    local i=0
    while [ $i -lt 20 ]; do
        netstat -tulnp 2>/dev/null | grep -q ":19527 " && { echo "ClawPanel started"; return 0; }
        sleep 1; i=$((i+1))
    done
    return 0
}
stop_service() {
    _load 2>/dev/null || true
    for pid in $(pgrep -f "clawpanel" 2>/dev/null); do kill $pid 2>/dev/null; done
    sleep 1
}
reload_service() { stop_service; sleep 1; start_service; }
status_service() {
    _load 2>/dev/null || { echo "Not configured"; return 1; }
    if netstat -tulnp 2>/dev/null | grep -q ":19527 "; then
        echo "Status: RUNNING"
    else
        echo "Status: NOT running"
    fi
}
IDEOF
chmod +x /etc/init.d/clawpanel
/etc/init.d/clawpanel enable 2>/dev/null || true
done_ "服务"

#===========================================================
# 启动
#===========================================================
step "启动服务"
pr "启动 ClawPanel..."
/etc/init.d/clawpanel stop 2>/dev/null || true
sleep 1
/etc/init.d/clawpanel start

i=0
while [ $i -lt 15 ]; do
    netstat -tulnp 2>/dev/null | grep -q ":19527 " && break
    sleep 1; i=$((i+1))
done

echo ""
if netstat -tulnp 2>/dev/null | grep -q ":19527 "; then
    log "✅ 启动成功！"
else
    warn "可能还在启动，稍后检查"
fi

#===========================================================
# 完成
#===========================================================
echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║           ✅ 安装完成！                          ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""
echo "📦 存储目录（/Configs 统一结构）:"
echo "   ${CYAN}${CONFIGS_DIR}${NC}"
echo "   ├── clawpanel/        ← ClawPanel 程序"
echo "   ├── openclaw/        ← OpenClaw npm 包"
echo "   ├── .openclaw/       ← OpenClaw 工作区"
echo "   └── .openclaw-work/  ← 运行时目录"
echo ""
echo "🔧 系统路径:"
echo "   /usr/local/bin/node   $(/usr/local/bin/node --version 2>/dev/null)"
echo "   /usr/local/bin/npm    $(/usr/local/bin/npm --version 2>/dev/null)"
echo ""
echo "🌐 面板: ${CYAN}http://192.168.1.1:19527/${NC}"
echo "🔑 令牌: ${YELLOW}clawpanel${NC}"
echo ""
echo "📝 恢复（系统重装后）:"
echo "   CP_BASE_PATH=${CP_BASE_PATH} sh install.sh"
