#!/bin/sh
#===========================================================
#  ClawPanel 一键安装脚本 (通用发行版)
#  适用于 OpenWrt / iStoreOS
#
#  功能: 自动检测挂载盘 → 安装完整工具链 → 配置 ClawPanel + OpenClaw
#  数据保存在外部存储，系统重装后恢复即可
#
#  使用方式:
#    CP_BASE_PATH=/mnt/sda1 sh install.sh        # 手动指定
#    sh install.sh                               # 自动检测
#===========================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log() { echo "${GREEN}[✓]${NC} $1"; }
info() { echo "${BLUE}[ℹ]${NC} $1"; }
warn() { echo "${YELLOW}[!]${NC} $1"; }
err() { echo "${RED}[✗]${NC} $1" >&2; }
step() { echo ""; echo "${CYAN}═══ $1 ═══${NC}"; }
done_msg() { echo "${GREEN}[✓]${NC} $1 完成"; }

# 彩色进度条
progress() { echo "${BLUE}▸${NC} $1"; }

#===========================================================
# 全局变量
#===========================================================
ARCH="$(uname -m)"
case "$ARCH" in
    aarch64|arm64) TARGET_ARCH="aarch64" ;;
    x86_64) TARGET_ARCH="x86_64" ;;
    armv7l|armv7) TARGET_ARCH="armv7" ;;
    *) err "不支持的架构: $ARCH"; exit 1 ;;
esac

NODE_VERSION="v22.15.1"
CP_VERSION="${CP_VERSION:-pro-v5.3.3}"
CP_BASE_PATH="${CP_BASE_PATH:-}"
CP_OPENCLAW_DIR="${CP_OPENCLAW_DIR:-}"

#===========================================================
# 第一步: 检测环境
#===========================================================
clear
echo "╔══════════════════════════════════════════════════╗"
echo "║   ClawPanel 全自动安装脚本 v1.0                  ║"
echo "║   OpenWrt / iStoreOS 通用版                      ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""
info "架构检测: $ARCH → $TARGET_ARCH"
[ "$(id -u)" = "0" ] || { err "必须以 root 用户运行"; exit 1; }
info "当前时间: $(date '+%Y-%m-%d %H:%M:%S')"

#===========================================================
# 第二步: 自动检测外部存储
#===========================================================
step "检测存储位置"

if [ -n "$CP_BASE_PATH" ]; then
    info "使用手动指定路径: $CP_BASE_PATH"
else
    progress "扫描可用存储设备..."

    # 收集所有非系统分区（排除 overlay/rom/tmpfs/devfs）
    CANDIDATES=""
    for mp in $(df -m | awk '$6 ~ /^\/mnt/ || $6 ~ /^\/ext/ || $6 ~ /^\/storage/ {print $6":"$4}' | sort -t: -k2 -rn); do
        mount_point=$(echo "$mp" | cut -d: -f1)
        avail_mb=$(echo "$mp" | cut -d: -f2)
        if [ "$avail_mb" -ge 500 ]; then
            CANDIDATES="${CANDIDATES}${mount_point}:${avail_mb}MB\n"
            info "  发现: ${mount_point} (可用: ${avail_mb}MB)"
        fi
    done

    if [ -z "$CANDIDATES" ]; then
        warn "未找到外部存储，尝试检测 /opt..."
        if df -m /opt 2>/dev/null | grep -q "^/dev"; then
            CP_BASE_PATH="/opt"
            info "使用 /opt 作为安装目录"
        else
            err "无法找到合适的安装目录！"
            err "请手动指定: CP_BASE_PATH=/mnt/sda1 $0"
            err "或者确保有至少 500MB 的挂载存储"
            exit 1
        fi
    else
        # 选择最大可用空间
        CP_BASE_PATH=$(echo -e "$CANDIDATES" | head -1 | cut -d: -f1)
        AVAIL_MB=$(echo -e "$CANDIDATES" | head -1 | cut -d: -f2)
        info "选择: ${CP_BASE_PATH} (可用: ${AVAIL_MB})"
    fi
fi

# 标准化路径
CP_BASE_PATH="${CP_BASE_PATH%/}"
[ -d "$CP_BASE_PATH" ] || { err "目录不存在: $CP_BASE_PATH"; exit 1; }

# 检测是否为 overlay 内部目录（不允许）
if df -m "$CP_BASE_PATH" 2>/dev/null | grep -q "overlay\|/dev/root"; then
    err "不能使用 overlay 分区作为安装目录: $CP_BASE_PATH"
    err "请使用外部存储挂载点，如 /mnt/sda1, /mnt/sdb1 等"
    exit 1
fi

# 标准化路径
CP_BASE_PATH="$(echo "$CP_BASE_PATH" | sed 's|//*|/|g; s|/$||')"

log "存储位置: $CP_BASE_PATH"
log "可用空间: $(df -h "$CP_BASE_PATH" | tail -1 | awk '{print $4}')"

#===========================================================
# 第三步: 设置目录结构
#===========================================================
info "设置目录结构..."

# 子目录（使用相对路径，避免硬编码）
STORAGE_SUBDIR="clawpanel-storage"  # 所有数据放这个子目录
INSTALL_ROOT="${CP_BASE_PATH}/${STORAGE_SUBDIR}"

NODE_DIR="${INSTALL_ROOT}/node"
OPENCLAW_NPM_DIR="${INSTALL_ROOT}/openclaw-npm"
OPENCLAW_DATA_DIR="${INSTALL_ROOT}/.openclaw"
OPENCLAW_WORK_DIR="${INSTALL_ROOT}/.openclaw-work"
CLAWPANEL_DIR="${INSTALL_ROOT}/clawpanel"
CLAWPANEL_DATA="${CLAWPANEL_DIR}/data"

# npm 全局安装路径
NPM_PREFIX="${INSTALL_ROOT}/npm-global"

log "安装根目录: $INSTALL_ROOT"
log "Node.js: $NODE_DIR"
log "OpenClaw: $OPENCLAW_NPM_DIR"
log "数据目录: $OPENCLAW_DATA_DIR"
log "ClawPanel: $CLAWPANEL_DIR"

# 创建目录
progress "创建目录结构..."
mkdir -p "$NODE_DIR" "$OPENCLAW_NPM_DIR" "$OPENCLAW_DATA_DIR" "$OPENCLAW_WORK_DIR"
mkdir -p "$CLAWPANEL_DIR" "$CLAWPANEL_DATA"
mkdir -p "$NPM_PREFIX"
done_msg "目录创建"

#===========================================================
# 第四步: 安装 Node.js
#===========================================================
step "安装 Node.js $NODE_VERSION"

# 检查是否已有
if command -v node >/dev/null 2>&1; then
    CURRENT_VER=$(node --version 2>/dev/null)
    info "Node.js 已安装: $CURRENT_VER"
    # 检查版本
    MAJOR=$(echo "$CURRENT_VER" | cut -d. -f1 | tr -d 'v')
    if [ "$MAJOR" -ge 22 ]; then
        log "版本满足要求 (≥v22)，跳过安装"
    else
        warn "版本过低: $CURRENT_VER，升级中..."
    fi
fi

# 检查 $NODE_DIR/node/bin/node
if [ -x "${NODE_DIR}/bin/node" ]; then
    info "检测到已有 Node.js: $(${NODE_DIR}/bin/node --version)"
    log "使用已有 Node.js"
else
    progress "下载 Node.js..."

    NODE_TGZ="/tmp/node-${TARGET_ARCH}.tar.xz"

    # 尝试多个镜像源
    MIRRORS="
        https://nodejs.org/download/release/${NODE_VERSION}/node-${NODE_VERSION}-linux-${TARGET_ARCH}.tar.xz
        https://npmmirror.com/mirrors/node/${NODE_VERSION}/node-${NODE_VERSION}-linux-${TARGET_ARCH}.tar.xz
    "

    for url in $MIRRORS; do
        progress "尝试: $url"
        if curl -fsSL --connect-timeout 15 -o "$NODE_TGZ" "$url" 2>/dev/null; then
            log "下载成功!"
            break
        fi
    done

    if [ ! -s "$NODE_TGZ" ]; then
        err "Node.js 下载失败！"
        err "请检查网络连接或手动下载后放置在 $NODE_DIR"
        exit 1
    fi

    progress "解压到 $NODE_DIR..."
    tar -xJf "$NODE_TGZ" -C "$INSTALL_ROOT" 2>/dev/null || {
        err "解压失败"
        exit 1
    }

    # 移动到标准位置
    EXTRACTED_DIR=""
    for d in "$INSTALL_ROOT"/node-*; do
        [ -d "$d" ] && EXTRACTED_DIR="$d" && break
    done

    if [ -n "$EXTRACTED_DIR" ] && [ "$EXTRACTED_DIR" != "$NODE_DIR" ]; then
        mv "$EXTRACTED_DIR" "$NODE_DIR" 2>/dev/null || {
            ln -sf "$EXTRACTED_DIR" "$NODE_DIR"
        }
    fi

    rm -f "$NODE_TGZ"
fi

# 创建符号链接到系统路径
progress "配置 Node.js 路径..."
mkdir -p /usr/local/bin /usr/local/lib
ln -sf "${NODE_DIR}/bin/node" /usr/local/bin/node
ln -sf "${NODE_DIR}/bin/npm" /usr/local/bin/npm
ln -sf "${NODE_DIR}/bin/npx" /usr/local/bin/npx 2>/dev/null || true

# npm wrapper（解决 ICU 路径问题）
cat > "${NODE_DIR}/bin/npm" << 'NPMEOF'
#!/bin/sh
SELF="$(readlink -f "$0" 2>/dev/null || echo "$0")"
BASE="$(cd "$(dirname "$SELF")/.." && pwd)"
export NODE_ICU_DATA="${BASE}/share/icu"
export PATH="${BASE}/bin:${PATH}"
exec "${BASE}/bin/node" "${BASE}/lib/node_modules/npm/bin/npm-cli.js" "$@"
NPMEOF
chmod +x "${NODE_DIR}/bin/npm"
ln -sf "${NODE_DIR}/bin/npm" /usr/local/bin/npm

log "Node.js 版本: $(node --version)"
log "npm 版本: $(npm --version)"

#===========================================================
# 第五步: 安装 Git 和 Python3
#===========================================================
step "安装基础工具 (Git + Python3)"

for pkg in git python3; do
    if command -v $pkg >/dev/null 2>&1; then
        log "$pkg 已安装: $($pkg --version 2>/dev/null | head -1)"
    else
        progress "安装 $pkg..."
        opkg update 2>/dev/null && opkg install $pkg 2>/dev/null || {
            warn "$pkg 安装失败，请在 LuCI 或手动: opkg install $pkg"
        }
        command -v $pkg >/dev/null 2>&1 && log "$pkg 安装成功" || warn "$pkg 安装可能失败"
    fi
done

#===========================================================
# 第六步: 安装 OpenClaw
#===========================================================
step "安装 OpenClaw"

OPENCLAW_NPM_PATH="${INSTALL_ROOT}/openclaw-npm"

if [ -d "${OPENCLAW_NPM_PATH}/node_modules/openclaw" ]; then
    info "检测到已有 OpenClaw: $(${NODE_DIR}/bin/node ${OPENCLAW_NPM_PATH}/node_modules/openclaw/openclaw.mjs --version 2>/dev/null || echo "已安装")"
    log "使用已有 OpenClaw"
elif [ -d "${OPENCLAW_DATA_DIR}/../openclaw-npm/node_modules/openclaw" ]; then
    OPENCLAW_NPM_PATH="${OPENCLAW_DATA_DIR}/../openclaw-npm"
    log "使用已有 OpenClaw"
else
    progress "安装 OpenClaw npm 包..."
    export PATH="${NODE_DIR}/bin:$PATH"
    export NODE_ICU_DATA="${NODE_DIR}/share/icu"

    # 设置 npm 全局路径到外部存储
    npm config set prefix "$NPM_PREFIX" 2>/dev/null || true

    # 安装 openclaw
    if ${NODE_DIR}/bin/npm install -g openclaw \
        --prefix "$OPENCLAW_NPM_PATH" \
        --registry https://registry.npmmirror.com \
        2>&1 | tail -5; then
        log "OpenClaw 安装成功"
    else
        err "OpenClaw 安装失败！"
        exit 1
    fi
fi

# 找到 openclaw.mjs
OPENCLAW_MJS=""
for path in \
    "${OPENCLAW_NPM_PATH}/node_modules/openclaw/openclaw.mjs" \
    "${OPENCLAW_NPM_PATH}/lib/node_modules/openclaw/openclaw.mjs" \
    "${NODE_DIR}/lib/node_modules/openclaw/openclaw.mjs"; do
    [ -f "$path" ] && OPENCLAW_MJS="$path" && break
done

if [ -z "$OPENCLAW_MJS" ]; then
    err "找不到 openclaw.mjs"
    ls "${OPENCLAW_NPM_PATH}"/node_modules/openclaw/ 2>/dev/null || true
    exit 1
fi

log "OpenClaw 入口: $OPENCLAW_MJS"

# 创建符号链接
mkdir -p /usr/local/lib/node_modules
rm -rf /usr/local/lib/node_modules/openclaw
ln -sf "$(dirname "$OPENCLAW_MJS")" /usr/local/lib/node_modules/openclaw

# 创建 openclaw 命令
cat > /usr/local/bin/openclaw << OCEOF
#!/bin/sh
export NODE_ICU_DATA="${NODE_DIR}/share/icu"
export LD_LIBRARY_PATH="${NODE_DIR}/lib:\$LD_LIBRARY_PATH"
export PATH="${NODE_DIR}/bin:\$PATH"
exec "${NODE_DIR}/bin/node" "${OPENCLAW_MJS}" "\$@"
OCEOF
chmod +x /usr/local/bin/openclaw
ln -sf /usr/local/bin/openclaw /usr/bin/openclaw 2>/dev/null || true

log "OpenClaw CLI 版本: $(openclaw --version 2>/dev/null)"

#===========================================================
# 第七步: 下载 ClawPanel 二进制
#===========================================================
step "安装 ClawPanel Go 二进制"

if [ -x "${CLAWPANEL_DIR}/clawpanel" ]; then
    info "ClawPanel 已存在: $(cat ${CLAWPANEL_DIR}/.version 2>/dev/null || echo '已安装')"
    log "跳过下载"
else
    progress "获取 ClawPanel 下载链接..."

    # 获取最新版本信息
    API_RESP=$(curl -fsSL --connect-timeout 10 \
        "https://api.github.com/repos/zhaoxinyi02/ClawPanel/releases/latest" \
        2>/dev/null)

    LATEST_VER=$(echo "$API_RESP" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('tag_name', '$CP_VERSION'))
" 2>/dev/null || echo "$CP_VERSION")

    info "最新版本: $LATEST_VER"

    # 构建下载 URL
    FILENAME="ClawPanel-${LATEST_VER#v}-linux-${TARGET_ARCH}.tar.gz"
    DOWNLOAD_URL="https://github.com/zhaoxinyi02/ClawPanel/releases/download/${LATEST_VER}/${FILENAME}"

    progress "下载: $FILENAME"
    TEMP_TGZ="/tmp/clawpanel.tar.gz"

    if curl -fsSL --connect-timeout 30 \
        -o "$TEMP_TGZ" "$DOWNLOAD_URL" 2>/dev/null; then
        log "下载成功!"
    else
        err "下载失败: $DOWNLOAD_URL"
        exit 1
    fi

    progress "解压..."
    tar -xzf "$TEMP_TGZ" -C "$CLAWPANEL_DIR" 2>/dev/null || {
        err "解压失败"
        exit 1
    }
    chmod +x "${CLAWPANEL_DIR}/clawpanel"
    rm -f "$TEMP_TGZ"
fi

echo "$CP_VERSION" > "${CLAWPANEL_DIR}/.version"
log "ClawPanel 版本: $(cat ${CLAWPANEL_DIR}/.version)"

#===========================================================
# 第八步: 配置 PATH 环境变量
#===========================================================
step "配置环境变量"

# 安装到 /etc/profile.d/（每次 SSH 登录自动生效）
mkdir -p /etc/profile.d
cat > /etc/profile.d/node.sh << PEOF
#!/bin/sh
# Node.js + OpenClaw 环境变量（自动生成）
export PATH="${NODE_DIR}/bin:\$PATH"
export NODE_ICU_DATA="${NODE_DIR}/share/icu"
export LD_LIBRARY_PATH="${NODE_DIR}/lib:\$LD_LIBRARY_PATH"
PEOF
chmod +x /etc/profile.d/node.sh
log "已安装: /etc/profile.d/node.sh"

#===========================================================
# 第九步: 写入配置文件
#===========================================================
step "写入配置文件"

# UCI 配置
progress "写入 UCI 配置..."
uci set clawpanel.main=clawpanel 2>/dev/null || uci add clawpanel main 2>/dev/null || true
uci set clawpanel.main.enabled='1'
uci set clawpanel.main.install_path="$CP_BASE_PATH"
uci set clawpanel.main.openclaw_dir="$OPENCLAW_DATA_DIR"
uci set clawpanel.main.openclaw_work="$OPENCLAW_WORK_DIR"
uci set clawpanel.main.openclaw_npm="$OPENCLAW_NPM_PATH"
uci set clawpanel.main.node_dir="$NODE_DIR"
uci set clawpanel.main.port='19527'
uci set clawpanel.main.version="$CP_VERSION"
uci commit clawpanel 2>/dev/null || true
done_msg "UCI 配置"

# clawpanel.json
progress "写入 clawpanel.json..."
cat > "${CLAWPANEL_DATA}/clawpanel.json" << CEOF
{
  "port": 19527,
  "dataDir": "${CLAWPANEL_DATA}",
  "openClawDir": "${OPENCLAW_DATA_DIR}",
  "openClawApp": "/usr/local/lib/node_modules/openclaw",
  "openClawWork": "${OPENCLAW_WORK_DIR}",
  "edition": "pro",
  "jwtSecret": "clawpanel-secret-change-me",
  "adminToken": "clawpanel",
  "debug": false
}
CEOF
done_msg "clawpanel.json"

# openclaw.json（自动生成最小配置）
progress "初始化 OpenClaw 配置..."
if [ ! -f "${OPENCLAW_DATA_DIR}/openclaw.json" ]; then
    mkdir -p "${OPENCLAW_DATA_DIR}"
    cat > "${OPENCLAW_DATA_DIR}/openclaw.json" << OEOF
{
  "agents": {
    "defaults": {
      "model": {
        "primary": "claude-sonnet-4-6"
      }
    }
  }
}
OEOF
    log "已创建 OpenClaw 配置文件"
fi

#===========================================================
# 第十步: 安装服务脚本
#===========================================================
step "配置服务脚本"

cat > /etc/init.d/clawpanel << IDEOF
#!/bin/sh /etc/rc.common
# ClawPanel 服务脚本（自动生成 by install.sh）
USE_PROCD=0
START=99
STOP=10

# 加载配置
_load() {
    CP_BASE_PATH="\$(uci -q get clawpanel.main.install_path)"
    STORAGE_SUBDIR="clawpanel-storage"
    NODE_DIR="\${CP_BASE_PATH}/\${STORAGE_SUBDIR}/node"
    OPENCLAW_DATA_DIR="\${CP_BASE_PATH}/\${STORAGE_SUBDIR}/.openclaw"
    OPENCLAW_WORK_DIR="\${CP_BASE_PATH}/\${STORAGE_SUBDIR}/.openclaw-work"
    CLAWPANEL_DIR="\${CP_BASE_PATH}/\${STORAGE_SUBDIR}/clawpanel"
    CLAWPANEL_DATA="\${CLAWPANEL_DIR}/data"
    OPENCLAW_MJS="\$(find \${CP_BASE_PATH} -name 'openclaw.mjs' -path '*/node_modules/openclaw/*' 2>/dev/null | head -1)"
}

start_service() {
    _load
    [ "\$(uci -q get clawpanel.main.enabled)" = "1" ] || return 0
    [ -x "\${CLAWPANEL_DIR}/clawpanel" ] || return 1

    mkdir -p "\$CLAWPANEL_DATA" "\$OPENCLAW_DATA_DIR" "\$OPENCLAW_WORK_DIR"
    stop_service

    (
        export HOME="/root"
        export PATH="\${NODE_DIR}/bin:\$PATH"
        export NODE_ICU_DATA="\${NODE_DIR}/share/icu"
        export LD_LIBRARY_PATH="\${NODE_DIR}/lib:\$LD_LIBRARY_PATH"
        export CP_BASE_PATH="\${CP_BASE_PATH}"
        export CP_OPENCLAW_DIR="\${OPENCLAW_DATA_DIR}"
        setsid /bin/bash -c "\${CLAWPANEL_DIR}/clawpanel >> /tmp/clawpanel.log 2>&1 &"
    )

    # 等待端口监听
    local i=0
    while [ \$i -lt 20 ]; do
        netstat -tulnp 2>/dev/null | grep -q ":19527 " && {
            echo "ClawPanel 已启动 (端口 19527)"
            return 0
        }
        sleep 1; i=\$((i+1))
    done
    echo "ClawPanel 启动中..."
    return 0
}

stop_service() {
    _load 2>/dev/null || true
    for pid in \$(pgrep -f "clawpanel" 2>/dev/null); do
        kill -9 \$pid 2>/dev/null
    done
    sleep 1
}

reload_service() { stop_service; sleep 1; start_service; }

status_service() {
    _load 2>/dev/null || { echo "未安装"; return 1; }
    if netstat -tulnp 2>/dev/null | grep -q ":19527 "; then
        echo "状态: 运行中"
    else
        echo "状态: 未运行"
    fi
}
IDEOF
chmod +x /etc/init.d/clawpanel
/etc/init.d/clawpanel enable 2>/dev/null || true
done_msg "服务脚本"

#===========================================================
# 第十一步: 启动并验证
#===========================================================
step "启动服务"

progress "启动 ClawPanel..."
/etc/init.d/clawpanel stop 2>/dev/null || true
sleep 2
/etc/init.d/clawpanel start

# 等待
i=0
while [ $i -lt 15 ]; do
    if netstat -tulnp 2>/dev/null | grep -q ":19527 "; then
        break
    fi
    sleep 1
    i=$((i+1))
done

echo ""
if netstat -tulnp 2>/dev/null | grep -q ":19527 "; then
    log "✅ ClawPanel 启动成功!"
else
    warn "ClawPanel 可能还在启动，请稍后检查状态"
fi

# 验证 OpenClaw
info "OpenClaw 版本: $(openclaw --version 2>/dev/null || echo '无法获取')"

#===========================================================
# 完成
#===========================================================
echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║           ✅ 安装完成！                          ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""
echo "📦 安装路径（外部存储，永久保存）:"
echo "   ${CYAN}${INSTALL_ROOT}${NC}"
echo ""
echo "   ├─ node/              ← Node.js v22"
echo "   ├─ openclaw-npm/      ← OpenClaw npm 包"
echo "   ├─ .openclaw/         ← OpenClaw 工作区"
echo "   └─ clawpanel/         ← ClawPanel Go 二进制"
echo ""
echo "🔧 系统路径（系统重装后需重新创建软链接）:"
echo "   /usr/local/bin/node    → ${NODE_DIR}/bin/node"
echo "   /usr/local/bin/openclaw → OpenClaw 入口"
echo "   /usr/local/lib/node_modules/openclaw"
echo "   /etc/init.d/clawpanel"
echo "   /etc/profile.d/node.sh"
echo ""
echo "🌐 访问地址:"
echo "   ClawPanel: ${CYAN}http://192.168.1.1:19527/${NC}"
echo "   OpenClaw:  ${CYAN}http://192.168.1.1:18789/${NC}"
echo ""
echo "🔑 登录令牌: ${YELLOW}clawpanel${NC}"
echo ""
echo "📝 系统重装后恢复:"
echo "   1. 安装 IPK: opkg install luci-app-clawpanel_*.ipk"
echo "   2. 运行: ${CYAN}CP_BASE_PATH=${CP_BASE_PATH} sh install.sh${NC}"
echo "   （所有数据在 ${INSTALL_ROOT}，不受影响）"
echo ""
echo "💡 常用命令:"
echo "   /etc/init.d/clawpanel status   # 查看状态"
echo "   /etc/init.d/clawpanel restart  # 重启服务"
echo "   openclaw --version             # OpenClaw 版本"
echo ""
