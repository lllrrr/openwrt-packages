#!/bin/sh

set -eu

# 用法: release-check.sh [version] [dist-dir]
#   version  形如 v0.1.2 或 v0.1.2-r2；留空则读 Makefile 的 PKG_VERSION / PKG_RELEASE
#   dist-dir 已构建好的产物目录，默认 dist
#
# 本脚本只校验、不构建。产物由 .github/workflows/build-packages.yml 用官方 SDK
# 编译（OpenWrt 25.12，apk-tools 3 的 ADB 容器格式）—— 与设备上和 ImageBuilder
# 里实际使用的格式完全一致，不再是本地脚本那种 apk-tools 2.x 风格的文件。
#
# 传入的版本必须与 Makefile 一致，否则直接失败：包版本只有一处事实源
# （Makefile），tag 与它脱节时校验会拿错文件名、把好产物判成坏的。
ARG_VERSION="${1:-${VERSION:-}}"
OUT_DIR="${2:-${OUT_DIR:-dist}}"

# 供 check-apk.py 定位用：本脚本可能在仓库根之外被调用（CI 里从工作区根调用，
# 而代码签出在子目录 luci-app-oxidns/ 下）。
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

MAKEFILE="${PKG_MAKEFILE:-Makefile}"
MK_VERSION="$(sed -n 's/^PKG_VERSION:=//p' "$MAKEFILE" | head -n 1)"
MK_RELEASE="$(sed -n 's/^PKG_RELEASE:=//p' "$MAKEFILE" | head -n 1)"

if [ -n "$ARG_VERSION" ]; then
	PKG_VERSION="$(printf '%s' "$ARG_VERSION" | sed -e 's/^v//' -e 's/-r[0-9][0-9]*$//')"
	PKG_RELEASE="$(printf '%s' "$ARG_VERSION" | sed -n 's/.*-r\([0-9][0-9]*\)$/\1/p')"
	[ -n "$PKG_RELEASE" ] || PKG_RELEASE="$MK_RELEASE"
else
	PKG_VERSION="$MK_VERSION"
	PKG_RELEASE="$MK_RELEASE"
fi

if [ -z "$PKG_VERSION" ] || [ -z "$PKG_RELEASE" ]; then
	printf 'could not determine PKG_VERSION/PKG_RELEASE (version=%s release=%s)\n' \
		"$PKG_VERSION" "$PKG_RELEASE" >&2
	exit 1
fi

if [ "$PKG_VERSION" != "$MK_VERSION" ] || [ "$PKG_RELEASE" != "$MK_RELEASE" ]; then
	printf 'version mismatch: requested %s-r%s, but %s declares %s-r%s\n' \
		"$PKG_VERSION" "$PKG_RELEASE" "$MAKEFILE" "$MK_VERSION" "$MK_RELEASE" >&2
	exit 1
fi

# SDK 编译出的 apk 文件名是 <包名>-<版本>-r<修订>.apk（无 _all 后缀，那是
# apk-tools 2.x 的命名习惯）。
#
# 翻译包按 glob 找、不按版本拼名字：它的版本由 luci.mk 的 PKG_PO_VERSION 定，
# 万一哪天 Makefile 里的钉法失效，这里也不该报「artifact 缺失」这种误导性的错，
# 而应该让它带着真实版本号进到下面 --same-version 的断言里，报出真正的原因。
APP_APK="${OUT_DIR}/luci-app-oxidns-${PKG_VERSION}-r${PKG_RELEASE}.apk"

I18N_GLOB="${OUT_DIR}/luci-i18n-oxidns-zh-cn-*.apk"

need_cmd() {
	command -v "$1" >/dev/null 2>&1 || {
		printf 'required command not found: %s\n' "$1" >&2
		exit 1
	}
}

need_cmd awk
need_cmd grep
need_cmd sha256sum

# python3 用来校验 apk 容器格式（见 scripts/check-apk.py）。
PYTHON="${PYTHON:-}"
if [ -z "$PYTHON" ]; then
	for c in python3 python; do
		if command -v "$c" >/dev/null 2>&1; then
			PYTHON="$c"
			break
		fi
	done
fi
if [ -z "$PYTHON" ]; then
	printf '需要 python3 来校验 apk 格式（scripts/check-apk.py）\n' >&2
	exit 1
fi

[ -d "$OUT_DIR" ] || {
	printf 'out-dir does not exist: %s\n' "$OUT_DIR" >&2
	exit 1
}

[ -f "$APP_APK" ] || {
	printf 'missing artifact: %s\n' "$APP_APK" >&2
	printf -- '--- %s 里实际有什么 ---\n' "$OUT_DIR" >&2
	ls -l "$OUT_DIR" >&2 || true
	exit 1
}

# 翻译包：glob 出来要求恰好一个。同一个语言只会产出一个，多了说明产物目录脏了。
I18N_APK=""
for f in $I18N_GLOB; do
	[ -f "$f" ] || continue
	if [ -n "$I18N_APK" ]; then
		printf 'artifact 不唯一：%s 与 %s\n' "$I18N_APK" "$f" >&2
		ls -l "$OUT_DIR" >&2 || true
		exit 1
	fi
	I18N_APK="$f"
done
[ -n "$I18N_APK" ] || {
	printf 'missing artifact: 没有任何 %s\n' "$I18N_GLOB" >&2
	printf -- '--- %s 里实际有什么 ---\n' "$OUT_DIR" >&2
	ls -l "$OUT_DIR" >&2 || true
	exit 1
}

# 1) 容器格式、pkgname、arch，以及必须落进包里的成员。
#
# --contains 用的是在 ADB 元数据流里直接可见的片段：ADB 的文件条目按目录栈
# 分段记录（例如先出现 "usr/share/luci"，再出现 "menu.d"），完整路径并不作为
# 一个连续字符串存在，所以这里断言的是目录段与文件名，而不是整条路径。
#
# --same-version 盯着翻译包的版本号：它来自 luci.mk 的 PKG_PO_VERSION，
# Makefile 忘了钉就会退化成 LuCI feed 的日期版本（形如 26.263.19088~0985e71）。
"$PYTHON" "$SCRIPT_DIR/check-apk.py" \
	--name luci-app-oxidns \
	--name luci-i18n-oxidns-zh-cn \
	--arch noarch \
	--same-version \
	--contains etc/config \
	--contains etc/init.d \
	--contains luci.oxidns \
	--contains learn-reset.sh \
	--contains targets.json \
	--contains luci-app-oxidns.json \
	--contains overview.js \
	--contains oxidns.zh-cn.lmo \
	"$APP_APK" "$I18N_APK"

# 2) 用 apk-tools 3 自带的 apk 建一次索引：ImageBuilder 拼装时走的正是
#    `apk mkndx` 这条路（OpenWrt 的 package/index 目标也是它），能建出索引
#    才说明这两个包真的会被装进镜像。
#
#    只有本机确实能拿到 apk 二进制时才跑。CI 里拿不到：SDK 是在容器内编译的，
#    apk 待在容器的 staging_dir/host/bin 下，而容器只把 bin/ 搬到 /artifacts，
#    staging_dir/ 从不落到宿主工作区。CI 那份 mkndx 校验由 gh-action-sdk 的
#    INDEX=1（`make package/index`）在容器里完成，用的是同一套 apk。
#
#    APK_BIN 显式给了却不可执行，要当场报错：放着不管只会在后面变成一句
#    没头没尾的 `... not found`（exit 127），查起来贵得多。
APK_BIN="${APK_BIN:-}"
if [ -n "$APK_BIN" ]; then
	if [ ! -x "$APK_BIN" ]; then
		printf 'APK_BIN 指向的不是可执行文件：%s\n' "$APK_BIN" >&2
		exit 1
	fi
elif [ -x staging_dir/host/bin/apk ]; then
	APK_BIN="staging_dir/host/bin/apk"
fi
if [ -n "$APK_BIN" ]; then
	case "$APK_BIN" in
	/*) : ;;
	*) APK_BIN="$PWD/$APK_BIN" ;;
	esac
	IDX_DIR="$(mktemp -d "${TMPDIR:-/tmp}/luci-app-oxidns-idx.XXXXXX")"
	cp "$APP_APK" "$I18N_APK" "$IDX_DIR/"
	(cd "$IDX_DIR" && "$APK_BIN" mkndx \
		--allow-untrusted --output packages.adb ./*.apk) >/dev/null
	if [ ! -s "$IDX_DIR/packages.adb" ]; then
		printf 'apk mkndx 没有产出索引，包可能不被接受\n' >&2
		rm -rf "$IDX_DIR"
		exit 1
	fi
	printf 'apk mkndx OK（索引 %s 字节）\n' "$(wc -c < "$IDX_DIR/packages.adb" | tr -d ' ')"
	rm -rf "$IDX_DIR"
else
	printf 'note: 本机没有可用的 apk 二进制，跳过 mkndx 检查（CI 里由 SDK 的 INDEX=1 承担）\n'
fi

# 3) 校验和清单（发布资产之一）
(
	cd "$OUT_DIR"
	rm -f sha256sums.txt
	sha256sum ./*.apk > sha256sums.txt
	sha256sum -c sha256sums.txt >/dev/null
)

printf 'Release check passed for %s-r%s in %s\n' "$PKG_VERSION" "$PKG_RELEASE" "$OUT_DIR"
