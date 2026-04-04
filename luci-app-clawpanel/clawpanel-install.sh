#!/bin/sh
#===========================================================
#  ClawPanel 一键安装脚本 (完整发行版)
#  适用于 OpenWrt / iStoreOS
#  
#  功能: 自动检测挂载盘 → 安装 Node.js + OpenClaw + ClawPanel
#  数据保存在外部存储，系统重装后恢复即可
#
#  使用方式:
#    CP_BASE_PATH=/mnt/sda1 sh clawpanel-install.sh
#
#  环境变量:
#    CP_BASE_PATH    外部存储路径 (默认: 自动检测最大挂载盘)
#    CP_VERSION      ClawPanel 版本 (默认: pro-v5.3.3)
#    CP_OPENCLAW_DIR OpenClaw 数据目录 (默认: ${CP_BASE_PATH}/.openclaw)
#===========================================================

set -e

# 配色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo "${GREEN}[INFO]${NC} $1"; }
warn() { echo "${YELLOW}[WARN]${NC} $1"; }
err() { echo "${RED}[ERROR]${NC} $1" >&2; }
step() { echo "${BLUE}[STEP]${NC} $1"; }

# 默认配置
CP_BASE_PATH="${CP_BASE_PATH:-}"
CP_VERSION="${CP_VERSION:-pro-v5.3.3}"
CP_OPENCLAW_DIR="${CP_OPENCLAW_DIR:-}"

#===========================================================
# 第一步: 检测架构和环境
#===========================================================
step "检测系统环境..."

ARCH="$(uname -m)"
case "$ARCH" in
    aarch64|arm64) TARGET_ARCH="aarch64" ;;
    x86_64) TARGET_ARCH="x86_64" ;;
    armv7l|armv7) TARGET_ARCH="armv7" ;;
    *) err "不支持的架构: $ARCH"; exit 1 ;;
esac
log "架构: $ARCH → $TARGET_ARCH"

# 检测是否 root
[ "$(id -u)" = "0" ] || { err "必须以 root 用户运行"; exit 1; }

#===========================================================
# 第二步: 检测或使用外部存储
#===========================================================
if [ -z "$CP_BASE_PATH" ]; then
    step "自动检测外部存储..."
    
    # 列出所有挂载的外部存储（排除系统分区）
    MOUNTS=$(df -m | awk '$6 ~ /^\/mnt/ && $1 !~ /^(tmpfs|overlay|dev\/root|ubifs)/ {print $6":"$4}' | sort -t: -k2 -rn)
    
    if [ -z "$MOUNTS" ]; then
        err "未找到外部存储挂载点！请先挂载 USB/SATA 存储，然后重试。"
        err "或者手动指定: CP_BASE_PATH=/mnt/sda1 $0"
        exit 1
    fi
    
    # 选择最大的挂载盘
    CP_BASE_PATH=$(echo "$MOUNTS" | head -1 | cut -d: -f1)
    AVAILABLE=$(echo "$MOUNTS" | head -1 | cut -d: -f2)
    log "检测到外部存储: $CP_BASE_PATH (可用: ${AVAILABLE}MB)"
    
    if [ "$AVAILABLE" -lt 500 ]; then
        err "存储空间不足！需要至少 500MB，可用: ${AVAILABLE}MB"
        exit 1
    fi
else
    log "使用指定存储: $CP_BASE_PATH"
fi

# 确保路径是绝对路径且已挂载
[ "${CP_BASE_PATH#/}" = "$CP_BASE_PATH" ] && CP_BASE_PATH="/$CP_BASE_PATH"
[ -d "$CP_BASE_PATH" ] || { err "目录不存在: $CP_BASE_PATH"; exit 1; }
mount | grep -q " $CP_BASE_PATH " || { err "$CP_BASE_PATH 未挂载"; exit 1; }

# 标准化路径（去除末尾斜杠）
CP_BASE_PATH="${CP_BASE_PATH%/}"

# OpenClaw 数据目录
if [ -z "$CP_OPENCLAW_DIR" ]; then
    CP_OPENCLAW_DIR="${CP_BASE_PATH}/.openclaw"
fi

# 安装目录
CP_INSTALL_PATH="${CP_BASE_PATH}/clawpanel"
CP_DATA="${CP_INSTALL_PATH}/data"
CP_BINARY="${CP_INSTALL_PATH}/clawpanel"
CP_PORT="19527"

log "存储路径:"
log "  安装目录: $CP_INSTALL_PATH"
log "  数据目录: $CP_DATA"
log "  OpenClaw: $CP_OPENCLAW_DIR"

#===========================================================
# 第三步: 检测或安装 Node.js
#===========================================================
step "检查 Node.js..."

if command -v node >/dev/null 2>&1; then
    NODE_VER=$(node --version 2>/dev/null)
    log "Node.js 已安装: $NODE_VER"
    
    # 检查版本是否满足 OpenClaw 要求 (v22.12+)
    NODE_MAJOR=$(node --version 2>/dev/null | cut -d. -f1 | tr -d 'v')
    if [ "$NODE_MAJOR" -lt 22 ]; then
        warn "Node.js 版本过低，建议升级到 v22+"
    fi
    
    NODE_PATH=$(command -v node)
    NPM_PATH=$(command -v npm)
else
    step "安装 Node.js v22..."
    
    # 下载预编译的 Node.js
    NODE_VERSION="v22.15.1"
    NODE_TGZ="/tmp/node-${TARGET_ARCH}.tar.xz"
    
    # 尝试多个镜像源
    for mirror in \
        "https://unofficial-builds.nodejs.org/download/release/${NODE_VERSION}/node-${NODE_VERSION}-linux-${TARGET_ARCH}.tar.xz" \
        "https://nodejs.org/download/release/${NODE_VERSION}/node-${NODE_VERSION}-linux-${TARGET_ARCH}.tar.xz"
    do
        log "尝试下载: $mirror"
        if curl -fsSL --connect-timeout 10 -o "$NODE_TGZ" "$mirror" 2>/dev/null; then
            log "下载成功!"
            break
        fi
    done
    
    if [ ! -s "$NODE_TGZ" ]; then
        err "Node.js 下载失败！请检查网络连接。"
        err "或者手动安装 Node.js 后重试。"
        exit 1
    fi
    
    # 解压到 /opt
    mkdir -p /opt
    tar -xJf "$NODE_TGZ" -C /opt/ 2>/dev/null || { err "解压失败"; exit 1; }
    
    # 重命名为 node22
    rm -rf /opt/node22
    mv /opt/node-${NODE_VERSION}-linux-${TARGET_ARCH} /opt/node22
    
    # 创建符号链接
    ln -sf /opt/node22/bin/node /usr/local/bin/node
    ln -sf /opt/node22/bin/npm /usr/local/bin/npm
    ln -sf /opt/node22/bin/npx /usr/local/bin/npx 2>/dev/null || true
    
    # npm wrapper（修复 ICU 路径）
    cat > /opt/node22/bin/npm << 'NPMEOF'
#!/bin/sh
SELF="$(readlink -f "$0" 2>/dev/null || echo "$0")"
BASE="$(cd "$(dirname "$SELF")/.." && pwd)"
export NODE_ICU_DATA="${BASE}/share/icu"
export PATH="${BASE}/bin:${PATH}"
exec "${BASE}/bin/node" "${BASE}/lib/node_modules/npm/bin/npm-cli.js" "$@"
NPMEOF
    chmod +x /opt/node22/bin/npm
    
    NODE_PATH="/opt/node22/bin/node"
    NPM_PATH="/opt/node22/bin/npm"
    
    rm -f "$NODE_TGZ"
    log "Node.js 安装完成: $(node --version)"
fi

NODE_ICU="/opt/node22/share/icu"
if [ -d "$NODE_ICU" ]; then
    mkdir -p /usr/local/share
    ln -sf "$NODE_ICU" /usr/local/share/icu 2>/dev/null || true
fi

#===========================================================
# 第四步: 安装 Git 和 Python3
#===========================================================
step "安装 Git 和 Python3..."

for pkg in git python3; do
    if command -v $pkg >/dev/null 2>&1; then
        log "$pkg 已安装: $($pkg --version 2>/dev/null | head -1)"
    else
        log "安装 $pkg..."
        opkg update 2>/dev/null && opkg install $pkg 2>/dev/null || \
            warn "$pkg 安装失败，请手动安装: opkg install $pkg"
    fi
done

#===========================================================
# 第五步: 安装 OpenClaw npm 包
#===========================================================
step "安装 OpenClaw..."

OPENCLAW_NPM_PATH="/usr/local/lib/node_modules/openclaw"
OPENCLAW_EXT_PATH="${CP_BASE_PATH}/openclaw-npm"

# 优先使用外部存储版本（如果有完整 node_modules）
if [ -d "${OPENCLAW_EXT_PATH}/node_modules" ] && \
   [ -n "$(ls -A "${OPENCLAW_EXT_PATH}/node_modules/" 2>/dev/null)" ]; then
    log "使用外部存储的 OpenClaw: ${OPENCLAW_EXT_PATH}"
    OPENCLAW_SOURCE="${OPENCLAW_EXT_PATH}"
elif [ -d "${CP_BASE_PATH}/openclaw/node_modules" ] && \
     [ -n "$(ls -A "${CP_BASE_PATH}/openclaw/node_modules/" 2>/dev/null)" ]; then
    OPENCLAW_SOURCE="${CP_BASE_PATH}/openclaw"
    log "使用已有 OpenClaw: ${OPENCLAW_SOURCE}"
else
    # 需要从 npm 安装
    step "从 npm 安装 OpenClaw..."
    OPENCLAW_SOURCE="${OPENCLAW_EXT_PATH}"
    mkdir -p "$(dirname "$OPENCLAW_SOURCE")"
    
    ${NPM_PATH} install -g openclaw --registry https://registry.npmmirror.com \
        --prefix "${CP_BASE_PATH}/openclaw-npm" 2>/dev/null || \
        ${NPM_PATH} install -g openclaw \
        --prefix "${CP_BASE_PATH}/openclaw-npm" 2>/dev/null || {
        err "OpenClaw 安装失败！"
        exit 1
    }
fi

# 创建符号链接
mkdir -p /usr/local/lib/node_modules
rm -rf "$OPENCLAW_NPM_PATH"
ln -sf "$OPENCLAW_SOURCE" "$OPENCLAW_NPM_PATH"

# 创建 openclaw 命令
mkdir -p /usr/local/bin
cat > /usr/local/bin/openclaw << OCEOF
#!/bin/sh
export NODE_ICU_DATA="${NODE_ICU}"
export LD_LIBRARY_PATH="/opt/node22/lib:\$LD_LIBRARY_PATH"
export PATH="/opt/node22/bin:\$PATH"
exec /opt/node22/bin/node /usr/local/lib/node_modules/openclaw/openclaw.mjs "\$@"
OCEOF
chmod +x /usr/local/bin/openclaw
ln -sf /usr/local/bin/openclaw /usr/bin/openclaw 2>/dev/null || true

log "OpenClaw 版本: $(openclaw --version 2>/dev/null)"

#===========================================================
# 第六步: 下载 ClawPanel 二进制
#===========================================================
step "下载 ClawPanel..."

mkdir -p "$CP_INSTALL_PATH" "$CP_DATA"

if [ -x "$CP_BINARY" ]; then
    log "ClawPanel 已存在: $($CP_BINARY --version 2>/dev/null | head -1)"
else
    # 从 GitHub 下载
    GITHUB_API="https://api.github.com/repos/zhaoxinyi02/ClawPanel/releases/latest"
    log "获取版本信息..."
    
    DOWNLOAD_URL=$(curl -fsSL --connect-timeout 10 "$GITHUB_API" 2>/dev/null | \
        python3 -c "import sys,json; d=json.load(sys.stdin); \
        [print(a['browser_download_url']) for a in d['assets'] \
        if '${TARGET_ARCH}' in a['name'] and 'linux' in a['name'].lower()]" 2>/dev/null | head -1)
    
    if [ -z "$DOWNLOAD_URL" ]; then
        err "无法获取 ClawPanel 下载链接"
        exit 1
    fi
    
    log "下载: $DOWNLOAD_URL"
    curl -fsSL --connect-timeout 30 -o "$CP_BINARY" "$DOWNLOAD_URL" || {
        err "下载失败！"
        exit 1
    }
    chmod +x "$CP_BINARY"
fi

echo "$CP_VERSION" > "${CP_INSTALL_PATH}/.version"
log "ClawPanel 版本: $(cat ${CP_INSTALL_PATH}/.version)"

#===========================================================
# 第七步: 配置 PATH 环境变量
#===========================================================
step "配置环境变量..."

mkdir -p /etc/profile.d
cat > /etc/profile.d/node.sh << PEOF
#!/bin/sh
export PATH="/opt/node22/bin:\$PATH"
export NODE_ICU_DATA="/opt/node22/share/icu"
export LD_LIBRARY_PATH="/opt/node22/lib:\$LD_LIBRARY_PATH"
PEOF
chmod +x /etc/profile.d/node.sh
log "已安装: /etc/profile.d/node.sh"

#===========================================================
# 第八步: 写入 ClawPanel 配置
#===========================================================
step "写入 ClawPanel 配置..."

# UCI 配置
uci set clawpanel.main=clawpanel 2>/dev/null || uci add clawpanel main 2>/dev/null || true
uci set clawpanel.main.enabled='1'
uci set clawpanel.main.install_path="$CP_BASE_PATH"
uci set clawpanel.main.openclaw_dir="$CP_OPENCLAW_DIR"
uci set clawpanel.main.port="$CP_PORT"
uci set clawpanel.main.version="$CP_VERSION"
uci commit clawpanel 2>/dev/null || true

# clawpanel.json
cat > "${CP_DATA}/clawpanel.json" << CEOF
{
  "port": ${CP_PORT},
  "dataDir": "${CP_DATA}",
  "openClawDir": "${CP_OPENCLAW_DIR}",
  "openClawApp": "/usr/local/lib/node_modules/openclaw",
  "openClawWork": "${CP_BASE_PATH}/.openclaw-work",
  "edition": "pro",
  "jwtSecret": "clawpanel-secret-change-me",
  "adminToken": "clawpanel",
  "debug": false
}
CEOF

log "配置写入完成"

#===========================================================
# 第九步: 安装 init.d 脚本
#===========================================================
step "安装服务脚本..."

cat > /etc/init.d/clawpanel << IDEOF
#!/bin/sh /etc/rc.common
# ClawPanel 服务脚本 (自动生成)
USE_PROCD=0
START=99
STOP=10

_load_uci() {
    CP_BASE_PATH="\$(uci -q get clawpanel.main.install_path || echo '')"
    [ -n "\$CP_BASE_PATH" ] || return 1
    CP_INSTALL_PATH="\${CP_BASE_PATH}/clawpanel"
    CP_DATA="\${CP_INSTALL_PATH}/data"
    CP_BIN="\${CP_INSTALL_PATH}/clawpanel"
    CP_OPENCLAW_DIR="\$(uci -q get clawpanel.main.openclaw_dir || echo '')"
    [ -n "\$CP_OPENCLAW_DIR" ] || CP_OPENCLAW_DIR="\${CP_BASE_PATH}/.openclaw"
}

start_service() {
    _load_uci || { echo "ClawPanel: 未配置，运行 clawpanel-env setup"; return 1; }
    [ "\$(uci -q get clawpanel.main.enabled)" = "1" ] || return 0
    [ -x "\$CP_BIN" ] || { echo "ClawPanel: 二进制不存在"; return 1; }

    mkdir -p "\$CP_DATA" "\$CP_OPENCLAW_DIR"
    stop_service

    (
        export HOME="/root"
        export PATH="/opt/node22/bin:\$PATH"
        export NODE_ICU_DATA="/opt/node22/share/icu"
        export LD_LIBRARY_PATH="/opt/node22/lib:\$LD_LIBRARY_PATH"
        export CP_BASE_PATH="\${CP_BASE_PATH}"
        export CP_OPENCLAW_DIR="\${CP_OPENCLAW_DIR}"
        setsid /bin/bash -c "\$CP_BIN >> /tmp/clawpanel.log 2>&1 &"
    )

    local i=0
    while [ \$i -lt 20 ]; do
        netstat -tulnp 2>/dev/null | grep -q ":\${port} " && { echo "ClawPanel 已启动"; return 0; }
        sleep 1; i=\$((i+1))
    done
    echo "ClawPanel 启动中..."
    return 0
}

stop_service() {
    _load_uci 2>/dev/null || true
    for pid in \$(pgrep -f "clawpanel" 2>/dev/null); do kill -9 \$pid 2>/dev/null; done
    sleep 1
}

reload_service() { stop_service; sleep 1; start_service; }

status_service() {
    _load_uci 2>/dev/null || { echo "未安装"; return 1; }
    if netstat -tulnp 2>/dev/null | grep -q ":19527 "; then
        echo "状态: 运行中"
    else
        echo "状态: 未运行"
    fi
}
IDEOF
chmod +x /etc/init.d/clawpanel
/etc/init.d/clawpanel enable 2>/dev/null || true

log "服务脚本已安装"

#===========================================================
# 第十步: 启动服务
#===========================================================
step "启动 ClawPanel..."

/etc/init.d/clawpanel stop 2>/dev/null || true
sleep 2
/etc/init.d/clawpanel start

sleep 3
if netstat -tulnp 2>/dev/null | grep -q ":${CP_PORT} "; then
    log "✅ ClawPanel 启动成功!"
    log "  面板: http://192.168.1.1:${CP_PORT}/"
    log "  令牌: clawpanel"
else
    warn "ClawPanel 可能还在启动，请稍后检查: /etc/init.d/clawpanel status"
fi

#===========================================================
# 完成
#===========================================================
echo ""
echo "=========================================="
log "安装完成!"
echo "=========================================="
echo ""
echo "📦 数据位置（外部存储，永久保存）:"
echo "   ClawPanel: $CP_INSTALL_PATH"
echo "   OpenClaw数据: $CP_OPENCLAW_DIR"
echo "   OpenClaw包: $OPENCLAW_SOURCE"
echo "   Node.js: /opt/node22"
echo ""
echo "🔧 系统路径（可能重装后丢失）:"
echo "   /usr/local/bin/openclaw → $OPENCLAW_SOURCE/openclaw.mjs"
echo "   /usr/local/lib/node_modules/openclaw → $OPENCLAW_SOURCE"
echo "   /etc/init.d/clawpanel"
echo "   /etc/profile.d/node.sh"
echo ""
echo "📝 系统重装后恢复:"
echo "   1. 安装 luci-app-clawpanel IPK"
echo "   2. 运行: CP_BASE_PATH=$CP_BASE_PATH sh clawpanel-install.sh"
echo "   （所有数据都在 $CP_BASE_PATH，不受影响）"
echo ""
