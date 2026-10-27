#!/bin/sh
# build-apk.sh —— 把一个已编译好的 smartmwand 组装成 OpenWrt APK 包
#
# 为什么不用 OpenWrt SDK 的 `make package/.../compile`：
#   那会拉起整套构建系统（feeds 更新 + 工具链 + 全包 Makefile 解析），
#   而本包的 Rust 侧只是一个普通的 musl 静态二进制，用 cargo 交叉编译即可。
#   这里只借 SDK 的 `apk` 打包工具（`apk mkpkg`），文件树由本脚本按
#   Makefile 的 install 段等价组装 —— 两条渠道产出的包内容一致。
#
# 用法：
#   scripts/build-apk.sh <目标架构二进制> <宿主机二进制> <输出目录> [架构]
#
#   目标架构二进制：aarch64-unknown-linux-musl 交叉编译产物（进包）
#   宿主机二进制  ：本机编译产物，只用来生成 --dump-defaults / --dump-include
#                   （这两份是纯文本，与架构无关；交叉产物在 CI 上跑不了）
#   架构          ：默认 aarch64_cortex-a53（mediatek/filogic 等）
#
# 环境变量：
#   APK_TOOL  apk 可执行文件路径（默认 `apk`，CI 里指向 SDK 的 host 工具）
#
# 产物：<输出目录>/luci-app-smartmwan-<版本>-r<发布号>.apk（未签名）

set -eu

# ---- 属主修正 ----------------------------------------------------------------
# apk 会记录文件的实际 uid/gid。CI 里文件由 runner 用户创建，直接打包会得到
# 「装到路由器上属主是 1001」这种坏包。
#
# 实测（GitHub Actions, ubuntu-24.04）：fakeroot 在这里**不生效** —— 它靠
# LD_PRELOAD 拦截 stat/lstat，而 SDK 自带的是 apk 包装脚本 + 自己的 ld-linux，
# 那个 ld-linux 加载不到系统的 libfakeroot.so，属主照样是 runner。
# 所以顺序改成：能 sudo 就直接 chown 成 root（最可靠）；不能 sudo 才退回 fakeroot。
can_sudo() {
	[ "$(id -u)" = "0" ] && return 0
	command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null
}

if [ "$(id -u)" != "0" ] && ! can_sudo && [ -z "${SMW_NO_FAKEROOT:-}" ] \
	&& command -v fakeroot >/dev/null 2>&1; then
	exec fakeroot -- "$0" "$@"
fi

BIN_TARGET=${1:?用法: build-apk.sh <目标二进制> <宿主机二进制> <输出目录> [架构]}
BIN_HOST=${2:?缺少宿主机二进制}
OUT=${3:-dist}
ARCH=${4:-aarch64_cortex-a53}
APK_TOOL=${APK_TOOL:-apk}

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
NAME=luci-app-smartmwan

VER=$(sed -n 's/^PKG_VERSION:=//p' "$ROOT/Makefile" | tr -d '[:space:]')
REL=$(sed -n 's/^PKG_RELEASE:=//p' "$ROOT/Makefile" | tr -d '[:space:]')
[ -n "$VER" ] && [ -n "$REL" ] || { echo "无法从 Makefile 读出 PKG_VERSION/PKG_RELEASE" >&2; exit 1; }
FULL_VERSION="${VER}-r${REL}"

for f in "$BIN_TARGET" "$BIN_HOST"; do
	[ -f "$f" ] || { echo "找不到二进制：$f" >&2; exit 1; }
done

WORK=$(mktemp -d)
# chown 成 root 之后普通 rm 删不掉，清理必须跟着提权；否则 CI 里会留一堆临时目录。
cleanup() {
	if [ "$(id -u)" = "0" ]; then
		rm -rf "$WORK"
	elif can_sudo; then
		sudo rm -rf "$WORK"
	else
		rm -rf "$WORK" 2>/dev/null || true
	fi
}
trap cleanup EXIT
IDIR="$WORK/$NAME"

echo "==> 组装文件树（$NAME $FULL_VERSION, $ARCH）"
mkdir -p \
	"$IDIR/usr/bin" \
	"$IDIR/etc/config" \
	"$IDIR/etc/init.d" \
	"$IDIR/usr/share/rpcd/ucode" \
	"$IDIR/usr/share/rpcd/acl.d" \
	"$IDIR/usr/share/luci/menu.d" \
	"$IDIR/usr/share/nftables.d/ruleset-post" \
	"$IDIR/usr/share/smartmwan/presets" \
	"$IDIR/www/luci-static/resources/view/smartmwan" \
	"$IDIR/www/luci-static/resources/smartmwan" \
	"$IDIR/lib/apk/packages"

install -m 0755 "$BIN_TARGET" "$IDIR/usr/bin/smartmwand"

# 配置与 nft 片段与代码同源：由宿主机二进制直接生成，避免仓库里存在一份会漂移的副本。
"$BIN_HOST" --dump-defaults > "$IDIR/etc/config/smartmwan"
"$BIN_HOST" --dump-include > "$IDIR/usr/share/nftables.d/ruleset-post/smartmwan.nft"

install -m 0755 "$ROOT/root/etc/init.d/smartmwan" "$IDIR/etc/init.d/smartmwan"
install -m 0644 "$ROOT/root/usr/share/rpcd/ucode/smartmwan.uc" "$IDIR/usr/share/rpcd/ucode/smartmwan.uc"
install -m 0644 "$ROOT/root/usr/share/rpcd/acl.d/luci-app-smartmwan.json" "$IDIR/usr/share/rpcd/acl.d/luci-app-smartmwan.json"
install -m 0644 "$ROOT/root/usr/share/luci/menu.d/luci-app-smartmwan.json" "$IDIR/usr/share/luci/menu.d/luci-app-smartmwan.json"

# LuCI 前端资源（htdocs 下的相对路径要原样保留）
# 用 cp -a 而不是 cpio：CI 的精简镜像里不一定装了 cpio，而 cp -a 到处都有。
mkdir -p "$IDIR/www"
cp -a "$ROOT/htdocs/." "$IDIR/www/"
chmod -R u=rwX,go=rX "$IDIR/www"

# ---- apk 需要的元数据（对应 include/package-pack.mk 的 lib/apk/packages/*）----
echo "/etc/config/smartmwan" > "$IDIR/lib/apk/packages/$NAME.conffiles"

SUM=$(sha256sum "$IDIR/etc/config/smartmwan" | cut -d' ' -f1)
echo "/etc/config/smartmwan $SUM" > "$IDIR/lib/apk/packages/$NAME.conffiles_static"

# 文件清单：在写 .list 之前生成，因此清单本身不会包含自己。
( cd "$IDIR" && find . \( -type f -o -type l \) -print | sed 's|^\.||' | sort ) \
	> "$IDIR/lib/apk/packages/$NAME.list"

echo "==> 文件树预览"
( cd "$IDIR" && find . -type f | sed 's|^\./||' | sort | head -30 )
COUNT=$(cd "$IDIR" && find . -type f | wc -l)
echo "    共 $COUNT 个文件，$(du -sk "$IDIR" | cut -f1) KiB"

mkdir -p "$OUT"
PKG="$OUT/$NAME-$FULL_VERSION.apk"

# 组装完成后再改属主：先 chown 会让后续的 install/cp 又变回当前用户。
if [ "$(id -u)" != "0" ] && can_sudo; then
	# 只改内容树的属主；$WORK 本身保持在当前用户手里（要能遍历、能删）。
	sudo chown -R 0:0 "$IDIR"
	sudo chmod -R u=rwX,go=rX "$IDIR"
	chmod 0755 "$WORK"
	echo "==> 文件属主已修正为 root:root（权限 0755/0644）"
elif [ "$(id -u)" = "0" ]; then
	echo "==> 以 root 运行，文件属主已是 root:root"
else
	echo "!! 警告：无法 chown（无 sudo、无 fakeroot），包内属主会保留为当前用户" >&2
fi

echo "==> 打包（$APK_TOOL mkpkg）"
# SOURCE_DATE_EPOCH=0：与 OpenWrt 一致，固定时间戳让同一份输入产出同一个包。
SOURCE_DATE_EPOCH=0 "$APK_TOOL" mkpkg \
	--info "name:$NAME" \
	--info "version:$FULL_VERSION" \
	--info "arch:$ARCH" \
	--info "tags:openwrt:section=luci" \
	--info "description:Multi-WAN smart routing: Rust daemon (smartmwand) + native LuCI JS frontend bridged through rpcd ucode. Zero Lua." \
	--info "license:GPL-3.0-or-later" \
	--info "origin:$NAME" \
	--info "url:https://github.com/LianXia233/luci-app-smartmwan" \
	--info "maintainer:luci-app-smartmwan contributors" \
	--info "depends:firewall4 nftables luci-base rpcd ucode-mod-socket" \
	--files "$IDIR" \
	--output "$PKG"

[ -f "$PKG" ] || { echo "打包失败：没有产物" >&2; exit 1; }
echo "==> 完成：$PKG（$(stat -c%s "$PKG" 2>/dev/null || echo '?') 字节）"
echo "    安装：apk add --allow-untrusted $PKG    # 未签名包需 --allow-untrusted"
