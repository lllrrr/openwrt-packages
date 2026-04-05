#!/bin/sh
#===========================================================
#  ClawPanel install.sh
#  功能：安装 Node.js + npm + ClawPanel（跳过 OpenClaw npm）
#===========================================================
set -e

# 颜色
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

log()   { echo "${GREEN}[✓]${NC} $1"; }
info()  { echo "${BLUE}[ℹ]${NC} $1"; }
warn()  { echo "${YELLOW}[!]${NC} $1"; }
err()   { echo "${RED}[✗]${NC} $1" >&2; }
step()  { echo ""; echo "${CYAN}═══ $1 ═══${NC}"; }
pr()    { echo "${BLUE}▸${NC} $1"; }

#===========================================================
# 全局变量
#===========================================================
ARCH="$(uname -m)"
case "$ARCH" in
    x86_64)
        TARGET_ARCH="x64"; TARGET_ARCH_NODE="x64"; TARGET_ARCH_CP="amd64"
        NODE_SOURCE="official"
        ;;
    aarch64|arm64)
        TARGET_ARCH="arm64"; TARGET_ARCH_NODE="arm64"; TARGET_ARCH_CP="arm64"
        NODE_SOURCE="github"
        ;;
    *)
        err "不支持架构: $ARCH（仅支持 x86_64 和 aarch64/arm64）"
        exit 1
        ;;
esac

CP_BASE_PATH="${CP_BASE_PATH:-}"
CP_VERSION="${CP_VERSION:-latest}"

# OpenClaw 跳过标记
OPENCLAW_SKIP=1

clear
echo "╔══════════════════════════════════════════════════╗"
echo "║   ClawPanel 一键安装脚本                      ║"
echo "║   /Configs 统一目录 · Node.js 系统级安装       ║"
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
    BEST=""; BEST_AVAIL=0
    for mp in $(df -m | awk '$6 ~ /^\/mnt/ || $6 ~ /^\/ext/ || $6 ~ /^\/storage/ {print $6":"$4}' | sort -t: -k2 -rn); do
        mount_point=$(echo "$mp" | cut -d: -f1)
        avail_mb=$(echo "$mp" | cut -d: -f2)
        if [ "$avail_mb" -ge 500 ] && [ "$avail_mb" -gt "$BEST_AVAIL" ]; then
            BEST="$mount_point"; BEST_AVAIL="$avail_mb"
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

avail_human=$(df -h "$CP_BASE_PATH" | tail -1 | awk '{print $4}')
log "存储: $CP_BASE_PATH (${avail_human} 可用)"

# /Configs 结构
CONFIGS_DIR="${CP_BASE_PATH}/Configs"
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

# 检测已有
if command -v node >/dev/null 2>&1; then
    log "Node.js 已安装: $(node --version)"
elif [ -x "/usr/local/bin/node" ]; then
    log "Node.js 已安装: $(/usr/local/bin/node --version)"
else
    # ClawPanel 要求 Node.js v22+
    pr "查询 GitHub 最新 v22 版本..."
    if [ "$NODE_SOURCE" = "github" ]; then
        NODE_VER=$(curl -sL --connect-timeout 10 \
            "https://github.com/a10463981/node-openwrt-arm64/releases" 2>/dev/null \
            | grep -o 'href="/a10463981/node-openwrt-arm64/releases/tag/[^"]*"' \
            | sed 's/.*tag\///;s/"//' \
            | grep '^v22\.' \
            | head -1) || true
        : "${NODE_VER:=v22.15.1}"
        info "版本: $NODE_VER"
    else
        NODE_VER="v22.22.2"
        info "版本: $NODE_VER (ClawPanel 最低要求 v22)"
    fi

    NODE_TGZ="/tmp/node-${TARGET_ARCH_NODE}.tar.gz"
    pr "下载..."
    if [ "$NODE_SOURCE" = "official" ]; then
        pr "来源: npmmirror.com"
        URL="https://npmmirror.com/mirrors/node/${NODE_VER}/node-${NODE_VER}-linux-${TARGET_ARCH_NODE}.tar.xz"
        if ! curl -fsSL --connect-timeout 120 -o "$NODE_TGZ" "$URL" 2>/dev/null; then
            pr "回退: nodejs.org"
            URL="https://nodejs.org/download/release/${NODE_VER}/node-${NODE_VER}-linux-${TARGET_ARCH_NODE}.tar.xz"
            curl -fsSL --connect-timeout 120 -o "$NODE_TGZ" "$URL" || { err "Node.js 下载失败"; exit 1; }
        fi
    else
        pr "来源: a10463981/node-openwrt-arm64 (musl)"
        URL="https://github.com/a10463981/node-openwrt-arm64/releases/download/v${NODE_VER#v}/node-${NODE_VER}-openwrt-arm64-fixed.tar.gz"
        curl -fsSL --connect-timeout 120 -o "$NODE_TGZ" "$URL" || { err "Node.js 下载失败"; exit 1; }
    fi

    pr "解压到 /usr/local..."
    mkdir -p /usr/local/bin /usr/local/lib /usr/local/share
    if [ "$NODE_SOURCE" = "official" ]; then
        tar -xJf "$NODE_TGZ" -C /tmp || { err "解压失败(xz)"; rm -f "$NODE_TGZ"; exit 1; }
    else
        tar -xzf "$NODE_TGZ" -C /tmp || { err "解压失败(gz)"; rm -f "$NODE_TGZ"; exit 1; }
    fi

    NODE_SRC=""
    for d in /tmp/node-*; do [ -d "$d" ] && [ -x "$d/bin/node" ] && NODE_SRC="$d" && break; done
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
mkdir -p /usr/local/bin
cat > /usr/local/bin/npm << 'NPMEOF'
#!/bin/sh
SELF="$(readlink -f "$0" 2>/dev/null || echo "$0")"
BASE="$(cd "$(dirname "$SELF")/.." && pwd)"
export NODE_ICU_DATA="${BASE}/share/icu"
export LD_LIBRARY_PATH="${BASE}/lib:$LD_LIBRARY_PATH"
export PATH="${BASE}/bin:$PATH"
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
log "Node.js 环境配置完成"

#===========================================================
# Git + Python3
#===========================================================
step "基础工具"
for pkg in git python3; do
    if command -v $pkg >/dev/null 2>&1; then
        info "$pkg 已安装"
    else
        pr "安装 $pkg..."
        opkg update >/dev/null 2>&1 && opkg install $pkg >/dev/null 2>&1 || warn "$pkg 安装失败，请在 LuCI 手动安装"
        command -v $pkg >/dev/null 2>&1 && log "$pkg 安装成功" || warn "$pkg 可能未安装成功"
    fi
done
log "基础工具完成"

#===========================================================
# OpenClaw（跳过）
#===========================================================
step "OpenClaw（跳过）"
info "OpenClaw CLI 已跳过，由用户稍后手动安装"
info "ClawPanel 主程序不受影响"
log "跳过 OpenClaw npm 安装"

#===========================================================
# ClawPanel 二进制
#===========================================================
step "安装 ClawPanel 二进制"

# 获取版本
if [ "$CP_VERSION" = "latest" ] || [ -z "$CP_VERSION" ]; then
    LATEST=$(curl -sL --connect-timeout 10 \
        "https://api.github.com/repos/zhaoxinyi02/ClawPanel/releases" \
        | grep -o '"tag_name"[^,]*' | grep '"tag_name"' | head -1 \
        | cut -d'"' -f4 | grep '^pro-' | head -1 || echo "pro-v5.3.3")
else
    LATEST="$CP_VERSION"
fi
info "版本: $LATEST"

if [ -x "${CLAWPANEL_DIR}/clawpanel" ]; then
    info "二进制已存在: $(cat ${CLAWPANEL_DIR}/.version 2>/dev/null || echo '')"
else
    FILE_VER=$(echo "$LATEST" | sed 's/^pro-v/v/;s/^lite-v/v/')
    URL="https://github.com/zhaoxinyi02/ClawPanel/releases/download/${LATEST}/clawpanel-${FILE_VER}-linux-arm64"
    pr "下载: $(basename $URL)"
    TMP="/tmp/clawpanel_bin_$$"
    curl -fsSL --connect-timeout 30 -o "$TMP" "$URL" || {
        err "下载失败"; rm -f "$TMP"; exit 1; }

    # 验证 ELF
    magic=$(head -c 4 "$TMP" 2>/dev/null | od -An -tx1 | tr -d ' \n')
    if [ "$magic" != "7f454c46" ]; then
        err "下载的不是有效 ELF 二进制"
        rm -f "$TMP"; exit 1
    fi

    mv -f "$TMP" "${CLAWPANEL_DIR}/clawpanel"
    chmod +x "${CLAWPANEL_DIR}/clawpanel"
    log "下载完成: $(wc -c < "${CLAWPANEL_DIR}/clawpanel" 2>/dev/null | awk '{printf "%.1f MB", $1/1024/1024}')"
fi

echo "$LATEST" > "${CLAWPANEL_DIR}/.version"
log "ClawPanel 二进制完成"

#===========================================================
# 配置文件
#===========================================================
step "配置文件"

cat > "${CLAWPANEL_DATA}/clawpanel.json" << 'CEOF'
{
  "port": 19527,
  "dataDir": "%DATA_DIR%",
  "openClawDir": "%OPENCLAW_DATA_DIR%",
  "openClawApp": "",
  "openClawWork": "%OPENCLAW_WORK_DIR%",
  "edition": "pro",
  "jwtSecret": "clawpanel-secret-change-me",
  "adminToken": "clawpanel",
  "debug": false
}
CEOF
sed -i "s|%DATA_DIR%|${CLAWPANEL_DATA}|g" "${CLAWPANEL_DATA}/clawpanel.json"
sed -i "s|%OPENCLAW_DATA_DIR%|${OPENCLAW_DATA}|g" "${CLAWPANEL_DATA}/clawpanel.json"
sed -i "s|%OPENCLAW_WORK_DIR%|${OPENCLAW_WORK}|g" "${CLAWPANEL_DATA}/clawpanel.json"
log "clawpanel.json"

if [ ! -f "${OPENCLAW_DATA}/openclaw.json" ]; then
    mkdir -p "${OPENCLAW_DATA}"
    cat > "${OPENCLAW_DATA}/openclaw.json" << 'EOF'
{
  "agents": { "defaults": { "model": { "primary": "claude-sonnet-4-6" } } }
}
EOF
fi
log "openclaw.json"

# UCI
uci set clawpanel.main='clawpanel' 2>/dev/null || uci add clawpanel main 2>/dev/null || true
uci set clawpanel.main.enabled='1'
uci set clawpanel.main.disk="$CP_BASE_PATH"
uci set clawpanel.main.install_path="$CONFIGS_DIR"
uci set clawpanel.main.port='19527'
uci set clawpanel.main.version="$LATEST"
uci commit clawpanel 2>/dev/null || true
log "UCI 配置"

#===========================================================
# 服务脚本
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
log "服务脚本完成"

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
echo "   ├── openclaw/        ← OpenClaw npm（未安装）"
echo "   ├── .openclaw/       ← 工作区"
echo "   └── .openclaw-work/  ← 运行时目录"
echo ""
echo "🔧 系统路径:"
echo "   /usr/local/bin/node   $(/usr/local/bin/node --version 2>/dev/null)"
echo "   /usr/local/bin/npm    $(/usr/local/bin/npm --version 2>/dev/null)"
echo ""
echo "🌐 面板: ${CYAN}http://192.168.1.1:19527/${NC}"
echo "🔑 令牌: ${YELLOW}clawpanel${NC}"
echo ""
echo "📝 OpenClaw CLI 手动安装:"
echo "   npm install -g openclaw --prefix ${OPENCLAW_DIR} --registry https://registry.npmmirror.com"
echo ""
echo "📝 恢复（系统重装后）:"
echo "   CP_BASE_PATH=${CP_BASE_PATH} sh install.sh"
echo ""
