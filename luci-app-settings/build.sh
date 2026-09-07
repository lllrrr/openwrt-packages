#!/bin/bash
# 用 OpenWrt SDK 编译本包(本地 WSL/Linux 和 GitHub Actions CI 共用)。
# 用法: bash build.sh                  (默认 SDK 25.12.5)
#       SDK_VER=25.12.x bash build.sh  (指定 SDK 版本)
# SDK 缓存在 ~/openwrt-sdk-work/<版本>/,重复运行为增量编译。
set -eu
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

SDK_VER="${SDK_VER:-25.12.5}"
SDK_BASEURL="https://downloads.openwrt.org/releases/${SDK_VER}/targets/x86/64"
WORK="$HOME/openwrt-sdk-work/${SDK_VER}"
SRC="$(cd "$(dirname "$0")" && pwd)"

mkdir -p "$WORK"
cd "$WORK"

if [ ! -d sdk ]; then
	if [ ! -f sdk.tar.zst ]; then
		# 从下载目录索引自动发现 SDK 文件名(gcc 版本随发布变化)
		SDK_NAME="$(curl -fsSL "$SDK_BASEURL/" | grep -o 'openwrt-sdk-[^"<]*\.tar\.zst' | sort -u | head -n1)"
		[ -n "$SDK_NAME" ] || { echo "ERROR: no SDK found at $SDK_BASEURL" >&2; exit 1; }
		echo "downloading $SDK_NAME"
		curl -fL --retry 3 -o sdk.tar.zst.part "$SDK_BASEURL/$SDK_NAME"
		mv sdk.tar.zst.part sdk.tar.zst
	fi
	tar --zstd -xf sdk.tar.zst
	mv openwrt-sdk-* sdk
fi

cd sdk

if [ ! -d package/feeds/base ]; then
	./scripts/feeds update base luci
	# 注意: 必须 install -a,只 install -p luci 不会把 base feed 的依赖链接进来
	./scripts/feeds install -a
fi

rm -rf package/luci-app-settings
mkdir -p package/luci-app-settings
rsync -a --exclude=.git --exclude=dist --exclude=vendor "$SRC/" package/luci-app-settings/

make defconfig
make package/luci-app-settings/compile -j"$(nproc)"

mkdir -p "$SRC/dist"
cp -v bin/packages/*/base/luci-app-settings-*.apk bin/packages/*/base/luci-i18n-settings-*.apk "$SRC/dist/" 2>/dev/null || \
cp -v bin/packages/*/base/luci-app-settings-*.ipk bin/packages/*/base/luci-i18n-settings-*.ipk "$SRC/dist/"
echo "DONE - packages copied to $SRC/dist/"
