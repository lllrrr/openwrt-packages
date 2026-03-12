#!/bin/sh
# ============================================================================
# OpenClaw 离线 .run 自解压包构建脚本
# 构建包含所有离线依赖的全架构 .run 安装包
#
# 用法:
#   sh scripts/build_offline_run.sh [output_dir]
#
# 前置条件:
#   先运行 sh scripts/download_deps.sh 下载离线依赖到 .offline-cache/
#
# 产出:
#   dist/luci-app-openclaw_<ver>_x86_64-musl_offline.run
#   dist/luci-app-openclaw_<ver>_aarch64-musl_offline.run
# ============================================================================
set -e

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PKG_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
OUT_DIR="${1:-$PKG_DIR/dist}"
CACHE_DIR="${CACHE_DIR:-$PKG_DIR/.offline-cache}"

case "$OUT_DIR" in
	/*) ;;
	*) OUT_DIR="$PKG_DIR/$OUT_DIR" ;;
esac
case "$CACHE_DIR" in
	/*) ;;
	*) CACHE_DIR="$PKG_DIR/$CACHE_DIR" ;;
esac

PKG_NAME="luci-app-openclaw"
PKG_VERSION=$(cat "$PKG_DIR/VERSION" 2>/dev/null | tr -d '[:space:]' || echo "1.0.0")
NODE_VERSION="${NODE_VERSION:-22.15.1}"
OC_VERSION=$(cat "$CACHE_DIR/openclaw/VERSION" 2>/dev/null | tr -d '[:space:]' || echo "2026.3.8")

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║      构建 OpenClaw 离线 .run 安装包                          ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "  插件版本:    v${PKG_VERSION}"
echo "  Node.js:     v${NODE_VERSION}"
echo "  OpenClaw:    v${OC_VERSION}"
echo "  缓存目录:    ${CACHE_DIR}"
echo "  输出目录:    ${OUT_DIR}"
echo ""

# 检查缓存目录
if [ ! -d "$CACHE_DIR/node" ] || [ ! -d "$CACHE_DIR/openclaw" ]; then
	echo "错误: 离线缓存不存在，请先运行:"
	echo "  sh scripts/download_deps.sh"
	exit 1
fi

mkdir -p "$OUT_DIR"

# ── 安装 LuCI 插件文件到暂存区 ──
install_luci_files() {
	local dest="$1"

	mkdir -p "$dest/etc/config"
	cp "$PKG_DIR/root/etc/config/openclaw" "$dest/etc/config/openclaw.default"

	mkdir -p "$dest/etc/uci-defaults"
	cp "$PKG_DIR/root/etc/uci-defaults/99-openclaw" "$dest/etc/uci-defaults/"
	chmod +x "$dest/etc/uci-defaults/99-openclaw"

	mkdir -p "$dest/etc/init.d"
	cp "$PKG_DIR/root/etc/init.d/openclaw" "$dest/etc/init.d/"
	chmod +x "$dest/etc/init.d/openclaw"

	mkdir -p "$dest/usr/bin"
	cp "$PKG_DIR/root/usr/bin/openclaw-env" "$dest/usr/bin/"
	chmod +x "$dest/usr/bin/openclaw-env"

	mkdir -p "$dest/usr/lib/lua/luci/controller"
	cp "$PKG_DIR/luasrc/controller/openclaw.lua" "$dest/usr/lib/lua/luci/controller/"

	mkdir -p "$dest/usr/lib/lua/luci/model/cbi/openclaw"
	cp "$PKG_DIR/luasrc/model/cbi/openclaw/"*.lua "$dest/usr/lib/lua/luci/model/cbi/openclaw/"

	mkdir -p "$dest/usr/lib/lua/luci/view/openclaw"
	cp "$PKG_DIR/luasrc/view/openclaw/"*.htm "$dest/usr/lib/lua/luci/view/openclaw/"

	mkdir -p "$dest/usr/share/openclaw"
	cp "$PKG_DIR/VERSION" "$dest/usr/share/openclaw/VERSION"
	cp "$PKG_DIR/root/usr/share/openclaw/oc-config.sh" "$dest/usr/share/openclaw/"
	chmod +x "$dest/usr/share/openclaw/oc-config.sh"
	cp "$PKG_DIR/root/usr/share/openclaw/web-pty.js" "$dest/usr/share/openclaw/"
	cp -r "$PKG_DIR/root/usr/share/openclaw/ui" "$dest/usr/share/openclaw/"

	# i18n
	mkdir -p "$dest/usr/lib/lua/luci/i18n"
	if command -v po2lmo >/dev/null 2>&1 && [ -f "$PKG_DIR/po/zh-cn/openclaw.po" ]; then
		po2lmo "$PKG_DIR/po/zh-cn/openclaw.po" "$dest/usr/lib/lua/luci/i18n/openclaw.zh-cn.lmo" 2>/dev/null || true
	fi
}

# ── 创建离线安装器脚本 ──
create_offline_installer() {
	local target_arch="$1"   # 如 x86_64
	local target_libc="$2"   # 如 musl
	local staging="$3"

	cat > "$staging/install.sh" << 'INSTALLER_HEADER'
#!/bin/sh
# ============================================================================
# luci-app-openclaw 离线安装器
# 包含所有依赖，无需联网即可完成完整安装
# ============================================================================
set -e

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║   luci-app-openclaw — OpenClaw AI Gateway 离线安装器         ║"
echo "║   包含 Node.js + OpenClaw 运行环境，无需联网                 ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# ── 基本检查 ──
if [ ! -f /etc/openwrt_release ]; then
	echo "错误: 此安装包仅适用于 OpenWrt/iStoreOS 系统"
	exit 1
fi

ARCH=$(uname -m)
TARGET_ARCH="__TARGET_ARCH__"
TARGET_LIBC="__TARGET_LIBC__"

# 架构检查
case "$ARCH" in
	x86_64|aarch64) ;;
	*) echo "错误: 不支持的架构 $ARCH (仅支持 x86_64/aarch64)"; exit 1 ;;
esac

if [ "$ARCH" != "$TARGET_ARCH" ]; then
	echo "错误: 架构不匹配！"
	echo "  当前设备: $ARCH"
	echo "  安装包:   ${TARGET_ARCH}-${TARGET_LIBC}"
	echo ""
	echo "请下载对应架构的安装包。"
	exit 1
fi

# libc 检查
detect_libc() {
	if ldd --version 2>&1 | grep -qi musl; then
		echo "musl"
	elif [ -f /lib/ld-musl-*.so.1 ] 2>/dev/null; then
		echo "musl"
	elif [ -f /etc/openwrt_release ] || grep -qi "openwrt\|istoreos\|lede" /etc/os-release 2>/dev/null; then
		echo "musl"
	else
		echo "glibc"
	fi
}

SYS_LIBC=$(detect_libc)
if [ "$SYS_LIBC" != "$TARGET_LIBC" ]; then
	echo "警告: C 库类型不匹配 (系统: $SYS_LIBC, 安装包: $TARGET_LIBC)"
	echo "  如果安装后 Node.js 无法运行，请下载对应 libc 类型的安装包。"
	echo ""
	printf "是否继续？[y/N] "
	read -r answer
	case "$answer" in
		y|Y|yes|YES) ;;
		*) echo "已取消"; exit 0 ;;
	esac
fi

# ── 磁盘空间预检查 ──
echo "检查磁盘空间..."
# 预估解压后大小: Node.js ~100-200MB + OpenClaw ~200-400MB + 插件 ~1MB
NEED_MB=500
# 检查 /opt 所在分区 (OverlayFS 下可能是 /overlay)
AVAIL_KB=0
for mount_point in /opt /overlay /; do
	if df "$mount_point" >/dev/null 2>&1; then
		AVAIL_KB=$(df "$mount_point" 2>/dev/null | tail -1 | awk '{print $4}')
		break
	fi
done
AVAIL_MB=$((AVAIL_KB / 1024))
if [ "$AVAIL_MB" -lt "$NEED_MB" ] 2>/dev/null; then
	echo "警告: 可用空间不足！"
	echo "  需要: 至少 ${NEED_MB}MB"
	echo "  当前: ${AVAIL_MB}MB 可用"
	echo ""
	printf "是否继续？[y/N] "
	read -r answer
	case "$answer" in
		y|Y|yes|YES) ;;
		*) echo "已取消"; exit 0 ;;
	esac
fi

# ── OverlayFS 修复 ──
_oc_fix_opt() {
	mkdir -p /opt/openclaw/.probe 2>/dev/null && { rmdir /opt/openclaw/.probe 2>/dev/null; return 0; }
	if [ -d /overlay/upper/opt ]; then
		mkdir -p /overlay/upper/opt/openclaw 2>/dev/null
		mount --bind /overlay/upper/opt /opt 2>/dev/null && return 0
	fi
	return 1
}
_oc_fix_opt || true

NODE_BASE="/opt/openclaw/node"
OC_GLOBAL="/opt/openclaw/global"
OC_DATA="/opt/openclaw/data"

ensure_mkdir() {
	local target="$1"
	[ -d "$target" ] && return 0
	if ! mkdir -p "$target" 2>/dev/null; then
		echo "  [✗] 无法创建目录: $target"
		return 1
	fi
}

# ── 解压安装 ──

# 先停止已有服务 (避免文件被占用导致覆盖安装失败)
if [ -x /etc/init.d/openclaw ]; then
	echo "停止已有服务..."
	/etc/init.d/openclaw stop 2>/dev/null || true
	# 等待进程退出和端口释放
	sleep 2
	# 确保 gateway 子进程也已退出
	for pid in $(pgrep -f "openclaw-gateway|openclaw" 2>/dev/null); do
		kill "$pid" 2>/dev/null
	done
	sleep 1
fi

echo ""
echo "正在提取安装文件..."

# 解压 payload (从 MARKER 行之后)
ARCHIVE=$(awk '/^__ARCHIVE_BELOW__/ {print NR + 1; exit 0; }' "$0")
EXTRACT_DIR=$(mktemp -d)
trap "rm -rf '$EXTRACT_DIR'" EXIT

tail -n +$ARCHIVE "$0" | tar xzf - -C "$EXTRACT_DIR" 2>/dev/null

# ── [Step 1/5] 安装 LuCI 插件文件 ──
echo ""
echo "[1/5] 安装 LuCI 插件..."

# 复制插件文件到系统 (从 luci-files/ 子目录)
if [ -d "$EXTRACT_DIR/luci-files" ]; then
	cp -a "$EXTRACT_DIR/luci-files/." / 2>/dev/null
fi

# UCI 配置文件保护
if [ -f /etc/config/openclaw ] && [ -f /etc/config/openclaw.default ]; then
	rm -f /etc/config/openclaw.default
elif [ -f /etc/config/openclaw.default ]; then
	mv /etc/config/openclaw.default /etc/config/openclaw
fi

echo "  [✓] LuCI 插件已安装"

# ── [Step 2/5] 安装 Node.js ──
echo ""
echo "[2/5] 安装 Node.js..."

NODE_TARBALL="$EXTRACT_DIR/node.tar.xz"
if [ -f "$NODE_TARBALL" ]; then
	# 清理旧安装
	rm -rf "$NODE_BASE" 2>/dev/null
	[ -d /overlay/upper ] && rm -rf "/overlay/upper${NODE_BASE}" 2>/dev/null
	ensure_mkdir "$NODE_BASE"

	# 解压 Node.js (兼容 BusyBox tar)
	if tar --strip-components=1 -xf "$NODE_TARBALL" -C "$NODE_BASE" 2>/dev/null; then
		: # GNU tar
	else
		# BusyBox tar 回退
		local tmp_node="/tmp/node-extract-$$"
		ensure_mkdir "$tmp_node"
		tar xf "$NODE_TARBALL" -C "$tmp_node"
		local top_dir=$(ls "$tmp_node" 2>/dev/null | head -1)
		if [ -n "$top_dir" ] && [ -d "$tmp_node/$top_dir" ]; then
			cp -a "$tmp_node/$top_dir/." "$NODE_BASE/"
		fi
		rm -rf "$tmp_node"
	fi

	if [ -x "$NODE_BASE/bin/node" ]; then
		echo "  [✓] Node.js $($NODE_BASE/bin/node --version 2>/dev/null) 已安装"
	else
		echo "  [✗] Node.js 安装失败"
		exit 1
	fi
else
	echo "  [✗] 安装包中未找到 Node.js"
	exit 1
fi

# ── [Step 3/5] 安装 OpenClaw ──
echo ""
echo "[3/5] 安装 OpenClaw..."

OC_DEPS_TARBALL="$EXTRACT_DIR/openclaw-deps.tar.gz"
if [ -f "$OC_DEPS_TARBALL" ]; then
	rm -rf "$OC_GLOBAL" 2>/dev/null
	[ -d /overlay/upper ] && rm -rf "/overlay/upper${OC_GLOBAL}" 2>/dev/null
	ensure_mkdir "$OC_GLOBAL"

	tar xzf "$OC_DEPS_TARBALL" -C "$OC_GLOBAL"

	# 验证 openclaw 入口
	OC_ENTRY=""
	for d in "$OC_GLOBAL/lib/node_modules/openclaw" "$OC_GLOBAL/node_modules/openclaw"; do
		if [ -f "${d}/openclaw.mjs" ]; then
			OC_ENTRY="${d}/openclaw.mjs"
			break
		elif [ -f "${d}/dist/cli.js" ]; then
			OC_ENTRY="${d}/dist/cli.js"
			break
		fi
	done

	if [ -n "$OC_ENTRY" ]; then
		OC_VER=$("$NODE_BASE/bin/node" "$OC_ENTRY" --version 2>/dev/null | tr -d '[:space:]' || echo "unknown")
		echo "  [✓] OpenClaw v${OC_VER} 已安装"
	else
		echo "  [✗] OpenClaw 安装验证失败"
		exit 1
	fi
else
	echo "  [✗] 安装包中未找到 OpenClaw 依赖"
	exit 1
fi

# ── [Step 4/5] 初始化 OpenClaw ──
echo ""
echo "[4/5] 初始化 OpenClaw..."

ensure_mkdir "$OC_DATA/.openclaw"

# 创建 openclaw 系统用户 (如果不存在)
if ! id openclaw >/dev/null 2>&1; then
	# OpenWrt 使用 BusyBox adduser
	if command -v adduser >/dev/null 2>&1; then
		adduser -D -H -s /bin/false -h "$OC_DATA" openclaw 2>/dev/null || true
	fi
fi

# 运行 onboard
if [ -n "$OC_ENTRY" ] && [ -x "$NODE_BASE/bin/node" ]; then
	HOME="$OC_DATA" \
	OPENCLAW_HOME="$OC_DATA" \
	OPENCLAW_STATE_DIR="${OC_DATA}/.openclaw" \
	OPENCLAW_CONFIG_PATH="${OC_DATA}/.openclaw/openclaw.json" \
	"$NODE_BASE/bin/node" "$OC_ENTRY" onboard --non-interactive --accept-risk --tools-profile coding 2>/dev/null || true
fi

# 设置权限
chown -R openclaw:openclaw "$OC_DATA" 2>/dev/null || true
chown -R openclaw:openclaw "$OC_GLOBAL" 2>/dev/null || true
chown -R openclaw:openclaw "$NODE_BASE" 2>/dev/null || true

echo "  [✓] 初始化完成"

# ── [Step 5/5] 注册 opkg + 启动服务 ──
echo ""
echo "[5/5] 注册到系统..."

# 注册到 opkg
PKG="luci-app-openclaw"
PKG_VER="__PKG_VERSION__"
INFO_DIR="/usr/lib/opkg/info"
STATUS_FILE="/usr/lib/opkg/status"
INSTALL_TIME=$(date +%s)

mkdir -p "$INFO_DIR"

cat > "$INFO_DIR/$PKG.control" << CTLEOF
Package: $PKG
Version: $PKG_VER
Depends: luci-compat, luci-base
Section: luci
Architecture: all
Installed-Size: 0
Description: OpenClaw AI Gateway — LuCI 界面 (离线安装)
CTLEOF

cat > "$INFO_DIR/$PKG.list" << LISTEOF
__FILE_LIST__
LISTEOF

cat > "$INFO_DIR/$PKG.prerm" << 'RMEOF'
#!/bin/sh
/etc/init.d/openclaw stop 2>/dev/null
/etc/init.d/openclaw disable 2>/dev/null
exit 0
RMEOF
chmod +x "$INFO_DIR/$PKG.prerm"

# 更新 opkg status
if [ -f "$STATUS_FILE" ]; then
	awk -v pkg="$PKG" '
		BEGIN { skip=0 }
		/^Package:/ { skip=($2==pkg) }
		/^$/ { if(skip){skip=0; next} }
		!skip { print }
	' "$STATUS_FILE" > "${STATUS_FILE}.tmp"
	mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
fi

cat >> "$STATUS_FILE" << STEOF

Package: $PKG
Version: $PKG_VER
Depends: luci-compat, luci-base
Status: install user installed
Architecture: all
Conffiles:
 /etc/config/openclaw 0
Installed-Time: $INSTALL_TIME
STEOF

echo "  [✓] 已注册到 opkg"

# 写入离线安装标记 (供 LuCI 界面识别安装方式)
cat > /usr/share/openclaw/.offline-install << OFFEOF
type=offline
date=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date)
arch=${TARGET_ARCH}-${TARGET_LIBC}
node=$($NODE_BASE/bin/node --version 2>/dev/null || echo unknown)
openclaw=${OC_VER:-unknown}
plugin=__PKG_VERSION__
OFFEOF
echo "  [✓] 离线安装标记已写入"

# 执行 uci-defaults
if [ -f /etc/uci-defaults/99-openclaw ]; then
	( . /etc/uci-defaults/99-openclaw ) && rm -f /etc/uci-defaults/99-openclaw
fi

# 清除 LuCI 缓存
rm -f /tmp/luci-indexcache /tmp/luci-modulecache/* 2>/dev/null
rm -f /tmp/luci-indexcache.*.json 2>/dev/null

# 启用并启动服务
/etc/init.d/openclaw enable 2>/dev/null || true
uci set openclaw.main.enabled=1 2>/dev/null || true
uci commit openclaw 2>/dev/null || true

# 清理
rm -rf "$EXTRACT_DIR"
trap - EXIT

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  ✅ 离线安装完成！                                           ║"
echo "║                                                              ║"
echo "║  Node.js + OpenClaw + LuCI 插件已全部安装                    ║"
echo "║  无需再运行 openclaw-env setup                               ║"
echo "║                                                              ║"
echo "║  下一步:                                                     ║"
echo "║    访问 LuCI → 服务 → OpenClaw 进行配置                    ║"
echo "║    或执行: /etc/init.d/openclaw start                        ║"
echo "║                                                              ║"
echo "║  配置模型 API 密钥后即可使用，全程无需联网！                 ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

exit 0
__ARCHIVE_BELOW__
INSTALLER_HEADER
}

# ============================================================================
# 为每种架构构建 .run
# ============================================================================
build_one_variant() {
	local label="$1"      # 如 x86_64-musl
	local uname_arch="$2" # 如 x86_64
	local node_suffix="$3" # 如 linux-x64-musl
	local libc="$4"       # 如 musl

	echo ""
	echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	echo "  构建: ${label}"
	echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

	local node_tarball="$CACHE_DIR/node/node-v${NODE_VERSION}-${node_suffix}.tar.xz"
	if [ ! -f "$node_tarball" ]; then
		echo "  [!] 跳过: 未找到 Node.js 包 $(basename "$node_tarball")"
		return 1
	fi

	# 查找 OpenClaw 依赖包
	local oc_deps=""
	for f in "$CACHE_DIR/openclaw/openclaw-deps-"*.tar.gz; do
		[ -f "$f" ] && oc_deps="$f" && break
	done
	if [ -z "$oc_deps" ]; then
		echo "  [!] 跳过: 未找到 OpenClaw 依赖包"
		return 1
	fi

	# 创建临时暂存区
	local staging=$(mktemp -d)

	# [1] 准备 payload 结构
	local payload="$staging/payload"
	mkdir -p "$payload/luci-files"

	echo "  [1/5] 安装 LuCI 插件文件..."
	install_luci_files "$payload/luci-files"

	echo "  [2/5] 复制 Node.js 包..."
	cp "$node_tarball" "$payload/node.tar.xz"

	echo "  [3/5] 复制 OpenClaw 依赖包..."
	cp "$oc_deps" "$payload/openclaw-deps.tar.gz"

	# [2] 生成文件列表
	echo "  [4/5] 生成安装器..."
	local file_list=$(cd "$payload/luci-files" && find . -type f | sed 's|^\./|/|' | sed 's|/etc/config/openclaw.default|/etc/config/openclaw|' | sort)

	# 创建安装器
	create_offline_installer "$uname_arch" "$libc" "$staging"

	# 替换占位符
	sed -i "s|__TARGET_ARCH__|${uname_arch}|g" "$staging/install.sh"
	sed -i "s|__TARGET_LIBC__|${libc}|g" "$staging/install.sh"
	sed -i "s|__PKG_VERSION__|${PKG_VERSION}|g" "$staging/install.sh"

	# 替换文件列表
	{
		sed '/__FILE_LIST__/,$d' "$staging/install.sh"
		echo "$file_list"
		sed '1,/__FILE_LIST__/d' "$staging/install.sh"
	} > "$staging/install_final.sh"
	mv "$staging/install_final.sh" "$staging/install.sh"

	# [3] 打包 payload
	echo "  [5/5] 打包..."
	(cd "$payload" && tar czf "$staging/payload.tar.gz" .)

	# [4] 组合: installer + payload
	local run_file="$OUT_DIR/${PKG_NAME}_${PKG_VERSION}_${label}_offline.run"
	cat "$staging/install.sh" "$staging/payload.tar.gz" > "$run_file"
	chmod +x "$run_file"

	local file_size=$(wc -c < "$run_file" | tr -d ' ')
	local file_size_mb=$((file_size / 1024 / 1024))

	echo "  [✓] ${run_file}"
	echo "      大小: ${file_size_mb}MB (${file_size} bytes)"

	# 生成 SHA256
	sha256sum "$run_file" > "${run_file}.sha256" 2>/dev/null || true

	rm -rf "$staging"
	return 0
}

# ── 主构建流程 ──
SUCCESS=0
FAILED=0

# 使用 for 循环避免 BusyBox ash 的 IFS/read 管道问题
for variant in \
	"x86_64-musl:x86_64:linux-x64-musl:musl" \
	"aarch64-musl:aarch64:linux-arm64-musl:musl" \
; do
	label=$(echo "$variant" | cut -d: -f1)
	uname_arch=$(echo "$variant" | cut -d: -f2)
	node_suffix=$(echo "$variant" | cut -d: -f3)
	libc=$(echo "$variant" | cut -d: -f4)

	if build_one_variant "$label" "$uname_arch" "$node_suffix" "$libc"; then
		SUCCESS=$((SUCCESS + 1))
	else
		FAILED=$((FAILED + 1))
	fi
done

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  构建完成                                                    ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "输出目录: $OUT_DIR"
echo ""
ls -lh "$OUT_DIR/"*_offline.run 2>/dev/null || echo "(无输出文件)"
echo ""
echo "安装方法: 将 .run 文件传输到路由器后执行:"
echo "  sh luci-app-openclaw_*_offline.run"
