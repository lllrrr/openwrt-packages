#!/bin/sh
# chfs 二进制提取脚本
#
# 由 chfs/Makefile 的 Build/Prepare 阶段调用。
#
# 背景: 上游 iscute.cn 发布的压缩包内, 可执行文件名形如
#   chfs-linux-arm64-3.1
# 即 "chfs-linux-<架构>-<版本>" 形式且不带文件扩展名。
# 因此不能用固定文件名查找, 需按前缀通配匹配, 并排除压缩包与 Windows 版本。
#
# 实现上只使用 POSIX sh 内建能力 (case / test / 参数展开), 不依赖
# find / sed / awk 等外部工具, 以保证在各类构建主机上行为一致。
#
# 用法: sh extract-bin.sh <构建目录>
# 产物: <构建目录>/chfs-bin (权限 0755)

set -e

BUILD_DIR="$1"

if [ -z "$BUILD_DIR" ]; then
	echo "ERROR: 缺少构建目录参数" >&2
	exit 1
fi

if [ ! -d "$BUILD_DIR" ]; then
	echo "ERROR: 构建目录不存在: $BUILD_DIR" >&2
	exit 1
fi

cd "$BUILD_DIR"

BIN=""
FOUND_LIST=""

# 候选模式: 依次尝试上游命名与裸名
# 注意: 未匹配时通配符会保持字面量, 因此必须在赋值前用 [ -f ] 复核
for pattern in chfs-linux-* chfs-* chfs; do
	for f in $pattern; do
		# 通配未展开时 f 为字面量模式串, 用它自身判断不会命中
		[ -f "$f" ] || continue

		# 排除压缩包与文本类文件
		case "$f" in
			*.zip|*.tar|*.gz|*.xz|*.bz2|*.7z) continue ;;
			*.txt|*.md|*.ini|*.conf|*.log) continue ;;
			*.exe|*.dll|*.bat|*.cmd) continue ;;
		esac

		# 记录所有候选, 便于报错时输出
		FOUND_LIST="$FOUND_LIST $f"

		# 取第一个可用候选
		[ -z "$BIN" ] && BIN="$f"
	done
done

if [ -z "$BIN" ]; then
	echo "ERROR: 压缩包内未找到 chfs 可执行文件" >&2
	echo "构建目录内容:" >&2
	ls -la >&2
	exit 1
fi

# 二次确认候选为普通文件
if [ ! -f "$BIN" ]; then
	echo "ERROR: 候选文件不存在: $BIN" >&2
	exit 1
fi

# 拒绝 Windows 可执行文件: PE 文件以 MZ 魔数开头
# 用 dd 读取前两字节, 避免依赖 head 的行为差异
MAGIC=$(dd if="$BIN" bs=1 count=2 2>/dev/null || echo "")
if [ "$MAGIC" = "MZ" ]; then
	echo "ERROR: 候选 '$BIN' 是 Windows 可执行文件, 不适用于目标平台" >&2
	exit 1
fi

echo "chfs: 找到上游二进制 '$BIN' (候选列表:${FOUND_LIST})"

if command -v file >/dev/null 2>&1; then
	file "$BIN" || true
fi

install -D -m0755 "$BIN" "$BUILD_DIR/chfs-bin"
echo "chfs: 已规范化安装为 chfs-bin"
