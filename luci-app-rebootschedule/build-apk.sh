#!/usr/bin/env bash
# 在任意 Linux 机器上一条命令产出 25.12 的 .apk
#
#   ./build-apk.sh                       # 自动从镜像站找匹配的 SDK
#   ./build-apk.sh <SDK下载地址>          # 手工指定
#   SDK_BASE=... WORK=... ./build-apk.sh  # 换镜像 / 换构建目录
#
# 依赖：curl、tar(--zstd)、zstd、make、gcc、gawk、git、gettext、unzip、
#       zlib1g-dev、libncurses-dev、rsync、cpio、python3、file
set -euo pipefail

PKG_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK="${WORK:-$(dirname "$PKG_DIR")/build}"
BASE="${SDK_BASE:-https://downloads.immortalwrt.org/snapshots/targets/airoha/an7581}"

command -v zstd >/dev/null || { echo "请先安装 zstd"; exit 1; }
mkdir -p "$WORK" && cd "$WORK"

if [ ! -d sdk ]; then
	echo "==> 查找 SDK"
	url="${1:-$(curl -fsSL "$BASE/" | grep -oE 'immortalwrt-sdk-[^"]+Linux-x86_64\.tar\.zst' | head -1)}"
	[ -n "$url" ] || { echo "没找到 SDK，请手工传入下载地址"; exit 1; }
	echo "    $url"
	curl -fL --retry 3 -o sdk.tar.zst "$BASE/$url"
	mkdir -p sdk && tar --zstd -xf sdk.tar.zst -C sdk --strip-components=1
fi

cd sdk

echo "==> 准备 luci feed（luci.mk 来自这里）"
./scripts/feeds update -a
./scripts/feeds install -a

echo "==> 放入源码"
rm -rf package/luci-app-rebootschedule
cp -r "$PKG_DIR" package/luci-app-rebootschedule

echo "==> 编译"
make package/luci-app-rebootschedule/compile V=s

echo "==> 产物"
find bin -name 'luci-app-rebootschedule*.apk' -exec ls -l {} \;
