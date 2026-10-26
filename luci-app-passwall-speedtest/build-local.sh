#!/bin/sh
# 本地构建脚本(适配本仓库顶层布局,可在 Linux 容器内运行):
#   1. 汇集 htdocs/ + root/ 成包目录,统一 CRLF→LF(Windows 检出;CI 在 Linux checkout 为 LF)
#   2. gcc 编译 po2lmo,把 po/zh_Hans 翻译转成 .lmo(lmo 为二进制,不参与 LF 归一)
#   3. 生成 CONTROL,ipkg-build 打出 all 架构 .ipk
# 用法: sh build-local.sh  →  产出 tmp/luci-app-passwall-speedtest_<ver>_all.ipk
# 依赖: gcc、wget、tar(GNU;alpine 里先 apk add gcc musl-dev wget tar)
set -e
appdir="${PWD}"
workdir="${PWD}/tmp/build"
rm -rf "$workdir"
pkgname=luci-app-passwall-speedtest
version=$(grep '^PKG_VERSION:=' Makefile | awk -F ':=' '{print $2}' | xargs)
release=$(grep '^PKG_RELEASE:=' Makefile | awk -F ':=' '{print $2}' | xargs)
pkgdir="$workdir/$pkgname"

echo "== 版本: $version-r$release =="

# 1) 汇集文件(本仓库顶层布局: htdocs/→www/, root/→/)
mkdir -p "$pkgdir"
[ -d htdocs ] && { mkdir -p "$pkgdir/www"; cp -R htdocs/* "$pkgdir/www/"; }
[ -d root ] && cp -R root/* "$pkgdir/"
# 包内全是文本文件: sh/uc/js/json/txt 及无扩展名的 init.d/uci-defaults/config
find "$pkgdir" -type f -exec sed -i 's/\r$//' {} +
chmod +x "$pkgdir"/etc/init.d/* "$pkgdir"/usr/bin/$pkgname/*.sh 2>/dev/null || true

# 2) po→lmo(LF 归一之后生成;lmo 是二进制,勿再 sed)
if [ -d po ]; then
    mkdir -p "$workdir/po2lmo" "$pkgdir/usr/lib/lua/luci/i18n"
    base=https://raw.githubusercontent.com/openwrt/luci/openwrt-18.06/modules/luci-base/src
    wget -q -O "$workdir/po2lmo/po2lmo.c" "$base/po2lmo.c"
    wget -q -O "$workdir/po2lmo/template_lmo.h" "$base/template_lmo.h"
    wget -q -O "$workdir/po2lmo/template_lmo.c" "$base/template_lmo.c"
    (cd "$workdir/po2lmo" && gcc -o po2lmo po2lmo.c template_lmo.c)
    "$workdir/po2lmo/po2lmo" "po/zh_Hans/passwall-speedtest.po" \
        "$pkgdir/usr/lib/lua/luci/i18n/$pkgname.zh-cn.lmo"
    echo "== lmo 翻译已生成 =="
fi

# 3) CONTROL + 打包
mkdir -p "$pkgdir/CONTROL"
cat > "$pkgdir/CONTROL/control" <<EOF
Package: $pkgname
Version: ${version}-${release}
Depends: libc, curl
Architecture: all
Maintainer: urbanescavenger
Section: luci
Priority: optional
Description: LuCI support for PassWall-based Cloudflare IP speed test
Source: https://github.com/urbanescavenger/luci-app-passwall-speedtest
EOF
cat > "$pkgdir/CONTROL/postinst" <<EOF
#!/bin/sh
[ "\${IPKG_NO_SCRIPT}" = "1" ] && exit 0
[ -s "\${IPKG_INSTROOT}/lib/functions.sh" ] || exit 0
. "\${IPKG_INSTROOT}/lib/functions.sh"
default_postinst \$0 \$@
EOF
cat > "$pkgdir/CONTROL/prerm" <<'EOF'
#!/bin/sh
[ -s "${IPKG_INSTROOT}/lib/functions.sh" ] || exit 0
. "${IPKG_INSTROOT}/lib/functions.sh"
default_prerm $0 $@
EOF
chmod +x "$pkgdir/CONTROL/postinst" "$pkgdir/CONTROL/prerm"

mkdir -p "$workdir/bin"
wget -q -O "$workdir/bin/ipkg-build" \
    https://raw.githubusercontent.com/openwrt/openwrt/openwrt-18.06/scripts/ipkg-build
chmod +x "$workdir/bin/ipkg-build"
"$workdir/bin/ipkg-build" -o root -g root "$pkgdir" "$PWD/tmp"
echo "== 完成: $(ls tmp/*.ipk) =="