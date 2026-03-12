#!/bin/sh
# ============================================================================
# OpenList 网盘上传脚本
# 将构建产物上传到 OpenList (AList) 网盘，便于国内用户下载
#
# 用法:
#   sh scripts/upload_openlist.sh [dist_dir]
#
# 环境变量 (必须):
#   OPENLIST_URL      — OpenList 服务地址 (如 https://pan.example.com)
#   OPENLIST_USER     — 登录用户名
#   OPENLIST_PASS     — 登录密码
#
# 环境变量 (可选):
#   OPENLIST_PATH     — 上传根路径 (默认: /Quark)
#   OPENLIST_TOKEN    — 直接提供 token, 跳过登录
#   UPLOAD_MODE       — 上传模式: offline / online / auto (默认 auto)
#                       auto 模式自动检测: 有 *_offline.run 则离线, 有 .run/.ipk 则在线
# ============================================================================
set -e

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PKG_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
DIST_DIR="${1:-$PKG_DIR/dist}"

case "$DIST_DIR" in
	/*) ;;
	*) DIST_DIR="$PKG_DIR/$DIST_DIR" ;;
esac

# 检查必要的环境变量
if [ -z "$OPENLIST_URL" ]; then
	echo "错误: 请设置 OPENLIST_URL 环境变量"
	echo "  例: export OPENLIST_URL=https://pan.example.com"
	exit 1
fi

if [ -z "$OPENLIST_TOKEN" ] && { [ -z "$OPENLIST_USER" ] || [ -z "$OPENLIST_PASS" ]; }; then
	echo "错误: 请设置登录凭据"
	echo "  方式一: export OPENLIST_USER=xxx OPENLIST_PASS=xxx"
	echo "  方式二: export OPENLIST_TOKEN=xxx"
	exit 1
fi

UPLOAD_ROOT="${OPENLIST_PATH:-/Quark}"
UPLOAD_MODE="${UPLOAD_MODE:-auto}"
PKG_VERSION=$(cat "$PKG_DIR/VERSION" 2>/dev/null | tr -d '[:space:]' || echo "unknown")

# 去除路径末尾的 /
UPLOAD_ROOT="${UPLOAD_ROOT%/}"

# 自动检测上传模式
if [ "$UPLOAD_MODE" = "auto" ]; then
	if ls "$DIST_DIR"/*_offline.run >/dev/null 2>&1; then
		UPLOAD_MODE="offline"
	elif ls "$DIST_DIR"/*.run >/dev/null 2>&1 || ls "$DIST_DIR"/*.ipk >/dev/null 2>&1; then
		UPLOAD_MODE="online"
	else
		echo "错误: 无法自动检测上传模式，dist 目录中无可识别文件"
		exit 1
	fi
fi

# 根据模式设置子目录和文件匹配规则
case "$UPLOAD_MODE" in
	offline)
		UPLOAD_SUBDIR="openclaw-离线安装"
		;;
	online)
		UPLOAD_SUBDIR="openclaw-在线安装"
		;;
	*)
		echo "错误: 无效的 UPLOAD_MODE: $UPLOAD_MODE (可选: offline / online / auto)"
		exit 1
		;;
esac

OPENLIST_URL="${OPENLIST_URL%/}"

log_info()  { echo "  [✓] $1"; }
log_warn()  { echo "  [!] $1"; }
log_error() { echo "  [✗] $1"; }

# ── 获取 Token ──
get_token() {
	if [ -n "$OPENLIST_TOKEN" ]; then
		echo "$OPENLIST_TOKEN"
		return
	fi

	log_info "正在登录 OpenList..." >&2
	local resp
	resp=$(curl -s -X POST "${OPENLIST_URL}/api/auth/login" \
		-H "Content-Type: application/json" \
		-d "{\"username\":\"${OPENLIST_USER}\",\"password\":\"${OPENLIST_PASS}\"}" 2>/dev/null)

	local token
	# 尝试解析 JSON 响应 (兼容多种 alist 版本)
	# alist v3 响应格式: {"code":200,"data":{"token":"xxx"},"message":"success"}
	if command -v jq >/dev/null 2>&1; then
		token=$(echo "$resp" | jq -r '.data.token // empty' 2>/dev/null)
	else
		# 无 jq 时用 grep/sed 提取
		token=$(echo "$resp" | grep -o '"token":"[^"]*"' | sed 's/"token":"//;s/"//')
	fi

	if [ -z "$token" ]; then
		log_error "登录失败" >&2
		echo "  响应: $resp" >&2
		exit 1
	fi

	log_info "登录成功" >&2
	echo "$token"
}

# ── 创建远程目录 ──
create_remote_dir() {
	local token="$1"
	local remote_path="$2"

	curl -s -X POST "${OPENLIST_URL}/api/fs/mkdir" \
		-H "Authorization: ${token}" \
		-H "Content-Type: application/json" \
		-d "{\"path\":\"${remote_path}\"}" >/dev/null 2>&1 || true
}

# ── 上传单个文件 ──
upload_file() {
	local token="$1"
	local local_file="$2"
	local remote_path="$3"
	local filename=$(basename "$local_file")
	local fsize=$(du -h "$local_file" | cut -f1)

	echo "  上传: ${filename} (${fsize})..."

	local resp
	resp=$(curl -s -X PUT "${OPENLIST_URL}/api/fs/put" \
		-H "Authorization: ${token}" \
		-H "File-Path: ${remote_path}/${filename}" \
		-H "Content-Type: application/octet-stream" \
		--data-binary "@${local_file}" \
		--max-time 3600 2>/dev/null)

	# 检查响应
	local code=""
	if command -v jq >/dev/null 2>&1; then
		code=$(echo "$resp" | jq -r '.code // empty' 2>/dev/null)
	else
		code=$(echo "$resp" | grep -o '"code":[0-9]*' | grep -o '[0-9]*')
	fi

	if [ "$code" = "200" ]; then
		log_info "${filename} 上传成功"
	else
		log_error "${filename} 上传失败"
		echo "    响应: $resp"
	fi
}

# ── 主流程 ──
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║      上传到 OpenList 网盘                                   ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "  服务地址:  ${OPENLIST_URL}"
echo "  上传模式:  ${UPLOAD_MODE}"
echo "  上传路径:  ${UPLOAD_ROOT}/${UPLOAD_SUBDIR}/v${PKG_VERSION}"
echo "  本地目录:  ${DIST_DIR}"
echo ""

# 查找要上传的文件
UPLOAD_FILES=""
case "$UPLOAD_MODE" in
	offline)
		# 离线包: 仅 *_offline.run 文件
		UPLOAD_FILES=$(find "$DIST_DIR" -name "*_offline.run" 2>/dev/null)
		;;
	online)
		# 在线包: .run (非 offline) + .ipk
		for f in "$DIST_DIR"/*.run "$DIST_DIR"/*.ipk; do
			[ -f "$f" ] || continue
			case "$(basename "$f")" in *_offline.run) continue ;; esac
			UPLOAD_FILES="$UPLOAD_FILES $f"
		done
		UPLOAD_FILES=$(echo "$UPLOAD_FILES" | sed 's/^ //')
		;;
esac

if [ -z "$UPLOAD_FILES" ]; then
	echo "错误: 未找到可上传的文件"
	echo "  模式: $UPLOAD_MODE"
	echo "  目录: $DIST_DIR"
	exit 1
fi

# 获取 token
TOKEN=$(get_token)

# 创建远程目录
REMOTE_DIR="${UPLOAD_ROOT}/${UPLOAD_SUBDIR}/v${PKG_VERSION}"
echo ""
echo "创建远程目录: ${REMOTE_DIR}"
create_remote_dir "$TOKEN" "$REMOTE_DIR"

# 上传文件
echo ""
echo "开始上传..."
UPLOAD_COUNT=0
for f in $UPLOAD_FILES; do
	upload_file "$TOKEN" "$f" "$REMOTE_DIR"
	UPLOAD_COUNT=$((UPLOAD_COUNT + 1))
done

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  ✅ 上传完成！共 ${UPLOAD_COUNT} 个文件                              ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "下载地址: ${OPENLIST_URL}${REMOTE_DIR}"
