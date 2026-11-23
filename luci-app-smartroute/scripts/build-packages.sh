#!/bin/sh
# 打包：build-packages.sh <SDK 所在目录的 URL> <输出目录> [版本]
#   例：build-packages.sh https://downloads.immortalwrt.org/releases/24.10.6/targets/x86/64 out 0.2.0
# 先用官方 Go 交叉编译全部架构（与 SDK 无关，SDK 里的 Go 版本不够新），再用 SDK 打包成该版本的 ipk 或 apk。
# 需要：go、python3、curl、zstd，以及 OpenWrt SDK 的编译依赖（build-essential、python3 等）。
# 设置 KEY_DIR（含 key-build 与 private-key.pem）时生成签名的软件源：$OUT/feed/<架构>/（24.10 为 Packages，25.12 为 packages.adb）
set -eu
URL=$1; OUT=$(realpath -m "$2"); VER=${3:-0.0.0}
REPO=$(cd "$(dirname "$0")/.." && pwd)
WORK=${WORK:-$REPO/.build}
mkdir -p "$WORK/bin" "$OUT"

for a in amd64 arm64 arm mipsle mips 386 riscv64; do
	# CI 的 bin 任务已统一编译好时设 SR_PREBUILT=1 复用；本地每次重新编译，免得打进旧程序
	[ -n "${SR_PREBUILT:-}" ] && [ -f "$WORK/bin/smartroute-$a" ] && continue
	(cd "$REPO" && env CGO_ENABLED=0 GOOS=linux GOARCH=$a GOARM=7 GOMIPS=softfloat GO386=softfloat \
		go build -trimpath -ldflags "-s -w" -o "$WORK/bin/smartroute-$a" ./cmd/smartroute)
done

SDKF=$(curl -fsSL "$URL/sha256sums" | grep -o '[^ *]*sdk-[^ ]*\.tar\.zst' | head -1)
SDK=$WORK/${SDKF%.tar.zst}
[ -d "$SDK" ] || { curl -fsSL "$URL/$SDKF" | zstd -d | tar -x -C "$WORK"; }

rm -rf "$SDK/package/smartroute" "$SDK/package/luci-app-smartroute" "$SDK/package/luci-i18n-smartroute-zh-cn"
cp -r "$REPO/openwrt/smartroute" "$REPO/openwrt/luci-app-smartroute" "$REPO/openwrt/luci-i18n-smartroute-zh-cn" "$SDK/package/"
mkdir -p "$SDK/package/luci-i18n-smartroute-zh-cn/files"
python3 "$REPO/scripts/i18n.py" lmo "$REPO/luci/po/zh_Hans/smartroute.po" "$SDK/package/luci-i18n-smartroute-zh-cn/files/smartroute.zh-cn.lmo" >/dev/null
cp -r "$WORK/bin" "$SDK/package/smartroute/bin"
[ -s "$REPO/luci/root/usr/share/smartroute/oui.txt" ] || "$REPO/scripts/oui.sh" "$REPO/luci/root/usr/share/smartroute/oui.txt"
cp -r "$REPO/luci" "$SDK/package/luci-app-smartroute/files"
rm -rf "$SDK/package/luci-app-smartroute/files/po"

cd "$SDK"
# 只打包本仓库的两个包，不需要 feeds：外部依赖写在 EXTRA_DEPENDS 里，由路由器上的软件源提供
SIGN=n
if [ -n "${KEY_DIR:-}" ]; then
	cp "$KEY_DIR/key-build" "$KEY_DIR/private-key.pem" .
	SIGN=y
fi
printf 'CONFIG_PACKAGE_smartroute=m\nCONFIG_PACKAGE_luci-app-smartroute=m\nCONFIG_PACKAGE_luci-i18n-smartroute-zh-cn=m\nCONFIG_SIGNED_PACKAGES=%s\n' $SIGN > .config
make defconfig >/dev/null
rm -rf bin/packages   # 本地重复打包时别把旧版本带进软件源
for p in smartroute luci-app-smartroute luci-i18n-smartroute-zh-cn; do
	make package/$p/compile SR_VERSION="$VER" -j1 V=s >"$WORK/$p.log" 2>&1 || { tail -40 "$WORK/$p.log"; exit 1; }
done
# apk 的文件名不含架构，补上，避免各架构的包重名（ipk 自带架构）
ARCH=$(sed -n 's/^CONFIG_TARGET_ARCH_PACKAGES="\(.*\)"/\1/p' .config)
for f in $(find bin/packages -name 'smartroute*.[ia]pk' -o -name 'luci-*-smartroute*.[ia]pk'); do
	n=$(basename "$f")
	case "$n" in
	*.apk) a=$ARCH; case "$n" in luci-*) a=all;; esac; n=${n%.apk}_$a.apk ;;
	esac
	cp "$f" "$OUT/$n"
done
if [ $SIGN = y ]; then
	make package/index >/dev/null
	rm -f key-build private-key.pem
	mkdir -p "$OUT/feed/$ARCH"
	cp bin/packages/"$ARCH"/base/* "$OUT/feed/$ARCH/"
fi
ls -la "$OUT"
