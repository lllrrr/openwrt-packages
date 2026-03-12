#!/bin/sh
# ============================================================================
# 离线依赖预下载脚本 (在有网络的构建机上运行)
# 为所有支持的架构下载 Node.js + OpenClaw + pnpm
#
# 用法:
#   sh scripts/download_deps.sh [cache_dir]
#
# 产出目录结构:
#   cache_dir/
#     node/
#       node-v22.16.0-linux-x64-musl.tar.xz
#       node-v22.16.0-linux-arm64-musl.tar.xz
#     openclaw/
#       openclaw-deps-v<version>.tar.gz          (预安装的 node_modules, 跨架构通用)
# ============================================================================
set -e

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PKG_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
CACHE_DIR="${1:-$PKG_DIR/.offline-cache}"

# 确保 CACHE_DIR 是绝对路径
case "$CACHE_DIR" in
	/*) ;;
	*) CACHE_DIR="$PKG_DIR/$CACHE_DIR" ;;
esac

# ── 版本配置 (与 openclaw-env 保持一致) ──
NODE_VERSION="${NODE_VERSION:-22.16.0}"
OC_VERSION="${OC_VERSION:-2026.3.8}"

# ── 下载镜像 ──
NODE_MIRROR="${NODE_MIRROR:-https://nodejs.org/dist}"
NODE_MIRROR_CN="https://npmmirror.com/mirrors/node"
NODE_MUSL_MIRROR="https://unofficial-builds.nodejs.org/download/release"
NODE_SELF_HOST="https://github.com/10000ge10000/luci-app-openclaw/releases/download/node-bins"
NPM_REGISTRY="${NPM_REGISTRY:-https://registry.npmjs.org}"

log_info()  { echo "  [✓] $1"; }
log_warn()  { echo "  [!] $1"; }
log_error() { echo "  [✗] $1"; }

# 自动检测 Node.js / npm (兼容 OpenWrt 上已安装的 openclaw 环境)
if ! command -v node >/dev/null 2>&1; then
	for try_path in /opt/openclaw/node/bin /usr/local/bin; do
		if [ -x "$try_path/node" ]; then
			export PATH="$try_path:$PATH"
			log_info "检测到 Node.js: $try_path/node"
			break
		fi
	done
fi

# 下载文件 (支持 curl 和 wget)
download_file() {
	local url="$1" dest="$2"
	if [ -f "$dest" ]; then
		local fsize=$(wc -c < "$dest" 2>/dev/null || echo 0)
		if [ "$fsize" -gt 1000000 ] 2>/dev/null; then
			log_info "已缓存: $(basename "$dest") ($(du -h "$dest" | cut -f1))"
			return 0
		fi
	fi
	echo "  下载: $url"
	if curl -fSL --connect-timeout 30 --max-time 600 -o "$dest" "$url" 2>/dev/null; then
		return 0
	elif wget -q --timeout=30 -O "$dest" "$url" 2>/dev/null; then
		return 0
	fi
	rm -f "$dest"
	return 1
}

# ============================================================================
# Phase 1: 下载 Node.js (全架构)
# ============================================================================
download_all_node() {
	echo ""
	echo "╔══════════════════════════════════════════════════════════════╗"
	echo "║  [1/3] 下载 Node.js v${NODE_VERSION} (musl 架构)                     ║"
	echo "╚══════════════════════════════════════════════════════════════╝"
	echo ""

	local node_dir="$CACHE_DIR/node"
	mkdir -p "$node_dir"

	# x86_64 musl
	echo "=== x86_64 musl ==="
	local x64_musl="node-v${NODE_VERSION}-linux-x64-musl.tar.xz"
	download_file "${NODE_MUSL_MIRROR}/v${NODE_VERSION}/${x64_musl}" "$node_dir/$x64_musl" || \
	download_file "${NODE_MIRROR_CN}/v${NODE_VERSION}/${x64_musl}" "$node_dir/$x64_musl" || \
		log_error "x86_64 musl 下载失败"

	# aarch64 musl (项目自托管)
	echo "=== aarch64 musl ==="
	local arm64_musl="node-v${NODE_VERSION}-linux-arm64-musl.tar.xz"
	download_file "${NODE_SELF_HOST}/${arm64_musl}" "$node_dir/$arm64_musl" || \
	download_file "${NODE_MUSL_MIRROR}/v${NODE_VERSION}/${arm64_musl}" "$node_dir/$arm64_musl" || \
		log_error "aarch64 musl 下载失败"

	echo ""
	echo "Node.js 下载完成:"
	ls -lh "$node_dir/"*.tar.xz 2>/dev/null || echo "  (无文件)"
}

# ============================================================================
# Phase 2: 下载并预装 OpenClaw + 依赖
# ============================================================================
download_openclaw_deps() {
	echo ""
	echo "╔══════════════════════════════════════════════════════════════╗"
	echo "║  [2/3] 下载 OpenClaw v${OC_VERSION} + 全部依赖                  ║"
	echo "╚══════════════════════════════════════════════════════════════╝"
	echo ""

	local oc_dir="$CACHE_DIR/openclaw"
	mkdir -p "$oc_dir"

	# 检查 npm 是否可用 (构建机上需要 node + npm)
	local NPM_CMD=""
	if command -v npm >/dev/null 2>&1; then
		NPM_CMD="npm"
	elif [ -x /opt/openclaw/node/bin/npm ]; then
		# OpenWrt 上 npm wrapper 可能需要显式 node 调用
		NPM_CMD="/opt/openclaw/node/bin/node /opt/openclaw/node/bin/npm"
	else
		log_error "构建机上需要 npm"
		log_error "请执行: apt install -y nodejs npm 或 apk add nodejs npm"
		log_error "或者确保 /opt/openclaw/node 中有 Node.js"
		exit 1
	fi
	log_info "使用 npm: $NPM_CMD"

	# 方案: 使用 npm install 到临时目录，然后打包整个 node_modules
	# 这是最可靠的方式，确保所有依赖树完整

	local tmp_install="/tmp/openclaw-offline-$$"
	trap "rm -rf '$tmp_install'" EXIT

	# ── 为每种架构生成预安装包 ──
	# 注意: openclaw 的依赖树中可能包含平台特定的 optional dependencies
	# musl 环境下用 --ignore-scripts 跳过原生编译
	# 对于离线包，我们在构建机上安装后直接打包 node_modules

	# 通用安装 (忽略平台特定编译脚本)
	echo "=== 安装 OpenClaw 依赖 (通用包) ==="
	mkdir -p "$tmp_install/global"
	echo "  正在用 npm 安装 openclaw@${OC_VERSION}..."
	$NPM_CMD install -g "openclaw@${OC_VERSION}" \
		--prefix="$tmp_install/global" \
		--ignore-scripts \
		--no-optional \
		--registry="$NPM_REGISTRY" 2>&1 | tail -20

	# 验证安装
	local oc_entry=""
	for d in "$tmp_install/global/lib/node_modules/openclaw" "$tmp_install/global/node_modules/openclaw"; do
		if [ -f "${d}/openclaw.mjs" ]; then
			oc_entry="${d}/openclaw.mjs"
			break
		elif [ -f "${d}/dist/cli.js" ]; then
			oc_entry="${d}/dist/cli.js"
			break
		fi
	done

	if [ -z "$oc_entry" ]; then
		log_error "OpenClaw 安装验证失败"
		echo "目录内容:"
		find "$tmp_install/global" -maxdepth 4 -type d 2>/dev/null | head -30
		exit 1
	fi

	log_info "OpenClaw 安装验证通过: $oc_entry"

	# 获取实际安装的版本号
	local actual_ver=""
	local oc_pkg_dir="$(dirname "$oc_entry")"
	if [ -f "$oc_pkg_dir/package.json" ]; then
		actual_ver=$(node -e "console.log(require('$oc_pkg_dir/package.json').version)" 2>/dev/null || echo "$OC_VERSION")
	fi
	echo "  实际版本: v${actual_ver:-$OC_VERSION}"

	# ── 精简 node_modules ──
	echo ""
	echo "=== 精简 node_modules ==="
	local before_size=$(du -sm "$tmp_install/global" 2>/dev/null | awk '{print $1}')

	# 删除不必要的文件以减小体积
	find "$tmp_install/global" -type f \( \
		-name "*.md" -o -name "*.markdown" -o \
		-name "*.map" -o \
		-name "*.ts" -not -name "*.d.ts" -o \
		-name "CHANGELOG*" -o -name "CHANGES*" -o -name "HISTORY*" -o \
		-name "AUTHORS*" -o -name "CONTRIBUTORS*" -o \
		-name ".npmignore" -o -name ".eslintrc*" -o -name ".jshintrc" -o \
		-name ".editorconfig" -o -name ".travis.yml" -o \
		-name "Makefile" -o -name "Gruntfile*" -o -name "Gulpfile*" -o \
		-name "*.test.js" -o -name "*.spec.js" -o \
		-name "tsconfig.json" -o -name "tsconfig.*.json" -o \
		-name ".prettierrc*" -o -name ".babelrc*" \
	\) -delete 2>/dev/null || true

	# 删除测试目录和文档目录
	# 注意: 不删除 "doc", 因为某些包 (如 yaml) 的 dist/doc/ 是运行时代码
	find "$tmp_install/global" -type d \( \
		-name "test" -o -name "tests" -o -name "__tests__" -o \
		-name "example" -o -name "examples" -o \
		-name "docs" -o \
		-name ".github" -o -name ".vscode" -o \
		-name "benchmark" -o -name "benchmarks" \
	\) -exec rm -rf {} + 2>/dev/null || true

	# 删除 node-llama-cpp 等大型原生依赖 (musl 下不可用)
	find "$tmp_install/global" -type d -name "node-llama-cpp" -exec rm -rf {} + 2>/dev/null || true
	find "$tmp_install/global" -type d -name "llama-cpp" -exec rm -rf {} + 2>/dev/null || true

	# 删除 .bin 目录中的符号链接 (安装时会重建)
	# 保留 bin 目录但不保留符号链接
	find "$tmp_install/global/lib/node_modules/.bin" -type l -delete 2>/dev/null || true
	find "$tmp_install/global/node_modules/.bin" -type l -delete 2>/dev/null || true

	local after_size=$(du -sm "$tmp_install/global" 2>/dev/null | awk '{print $1}')
	log_info "精简完成: ${before_size}MB → ${after_size}MB (节省 $((before_size - after_size))MB)"

	# ── 打包为通用 tarball ──
	# 因为 openclaw 是纯 JS 包 (使用 --ignore-scripts)，node_modules 跨架构通用
	echo ""
	echo "=== 打包 OpenClaw 依赖 ==="
	local tarball="$oc_dir/openclaw-deps-v${actual_ver:-$OC_VERSION}.tar.gz"
	echo "  正在压缩 ${after_size}MB 数据到 tar.gz (可能需要数分钟)..."
	# 注意: 不在子 shell 中用 set -e, 避免 tar 在处理损坏的符号链接时意外退出
	# --warning=no-file-changed: 忽略打包过程中文件被修改的警告
	if ! tar czf "$tarball" -C "$tmp_install/global" . 2>&1; then
		log_error "tar 打包失败"
		rm -f "$tarball"
		exit 1
	fi
	# 验证 gzip 完整性
	if ! gzip -t "$tarball" 2>/dev/null; then
		log_error "tar.gz 文件完整性检查失败！"
		rm -f "$tarball"
		exit 1
	fi
	local tgz_size=$(du -h "$tarball" | cut -f1)
	log_info "依赖包: $tarball ($tgz_size) [完整性已验证]"

	# 保存版本号
	echo "${actual_ver:-$OC_VERSION}" > "$oc_dir/VERSION"

	rm -rf "$tmp_install"
	# 清除之前的 trap
	trap - EXIT
}

# ============================================================================
# Phase 3: 生成清单
# ============================================================================
generate_manifest() {
	echo ""
	echo "╔══════════════════════════════════════════════════════════════╗"
	echo "║  [3/3] 生成构建清单                                       ║"
	echo "╚══════════════════════════════════════════════════════════════╝"
	echo ""

	local manifest="$CACHE_DIR/manifest.txt"
	local oc_ver=$(cat "$CACHE_DIR/openclaw/VERSION" 2>/dev/null || echo "$OC_VERSION")

	cat > "$manifest" << EOF
# OpenClaw Offline Bundle - 依赖清单
# 生成时间: $(date -Iseconds 2>/dev/null || date)
# Node.js: v${NODE_VERSION}
# OpenClaw: v${oc_ver}

[node]
EOF

	# 列出 Node.js 包
	for f in "$CACHE_DIR/node/"*.tar.xz; do
		[ -f "$f" ] || continue
		local fname=$(basename "$f")
		local fsize=$(du -h "$f" | cut -f1)
		local sha256=$(sha256sum "$f" 2>/dev/null | awk '{print $1}' || echo "N/A")
		echo "${fname}  size=${fsize}  sha256=${sha256}" >> "$manifest"
	done

	echo "" >> "$manifest"
	echo "[openclaw]" >> "$manifest"

	# 列出 OpenClaw 包
	for f in "$CACHE_DIR/openclaw/"*.tar.gz; do
		[ -f "$f" ] || continue
		local fname=$(basename "$f")
		local fsize=$(du -h "$f" | cut -f1)
		local sha256=$(sha256sum "$f" 2>/dev/null | awk '{print $1}' || echo "N/A")
		echo "${fname}  size=${fsize}  sha256=${sha256}" >> "$manifest"
	done

	echo ""
	echo "=== 依赖清单 ==="
	cat "$manifest"
	echo ""

	# 统计总大小
	local total_size=$(du -sh "$CACHE_DIR" 2>/dev/null | awk '{print $1}')
	echo "缓存目录: $CACHE_DIR"
	echo "总大小:   $total_size"
}

# ── 主入口 ──
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║      OpenClaw 离线依赖下载器                                ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "  Node.js:    v${NODE_VERSION}"
echo "  OpenClaw:   v${OC_VERSION}"
echo "  缓存目录:   ${CACHE_DIR}"
echo "  npm 源:     ${NPM_REGISTRY}"
echo ""

mkdir -p "$CACHE_DIR"

download_all_node
download_openclaw_deps
generate_manifest

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  ✅ 依赖下载完成！现在可以运行 build_offline_run.sh        ║"
echo "╚══════════════════════════════════════════════════════════════╝"
