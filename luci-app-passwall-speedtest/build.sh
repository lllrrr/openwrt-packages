#!/bin/sh

appdir="${PWD}"
workdir="${PWD}/tmp"
rm -rf $workdir
txt=$(cat applications/luci-app-cfpick/Makefile|tr '\n' ',')
version=`echo $txt|sed -r 's/.*PKG_VERSION:=(.*),PKG_RELEASE.*/\1/'`

[ -d applications/luci-app-cfpick/htdocs ] && mkdir -p $workdir/luci-app-cfpick/www && cp -R applications/luci-app-cfpick/htdocs/* $workdir/luci-app-cfpick/www/
[ -d applications/luci-app-cfpick/root ] && cp -R applications/luci-app-cfpick/root/* $workdir/luci-app-cfpick/
chmod +x $workdir/luci-app-cfpick/etc/init.d/* >/dev/null 2>&1
[ -d applications/luci-app-cfpick/po ] && sudo -E apt-get -y install gcc make && \
mkdir -p $workdir/po2lmo && mkdir -p $workdir/luci-app-cfpick/usr/lib/lua/luci/i18n/ && \
wget -O $workdir/po2lmo/po2lmo.c https://raw.githubusercontent.com/openwrt/luci/openwrt-18.06/modules/luci-base/src/po2lmo.c && \
wget -O $workdir/po2lmo/Makefile https://raw.githubusercontent.com/openwrt/luci/openwrt-18.06/modules/luci-base/src/Makefile && \
wget -O $workdir/po2lmo/template_lmo.h https://raw.githubusercontent.com/openwrt/luci/openwrt-18.06/modules/luci-base/src/template_lmo.h && \
wget -O $workdir/po2lmo/template_lmo.c https://raw.githubusercontent.com/openwrt/luci/openwrt-18.06/modules/luci-base/src/template_lmo.c && \
cd $workdir/po2lmo && make po2lmo && ./po2lmo $appdir/applications/luci-app-cfpick/po/zh_Hans/cfpick.po $workdir/luci-app-cfpick/usr/lib/lua/luci/i18n/cfpick.zh-cn.lmo
mkdir -p $workdir/luci-app-cfpick/CONTROL
cat > $workdir/luci-app-cfpick/CONTROL/control <<EOF
Package: luci-app-cfpick
Version: ${version}
Depends: libc, curl
Architecture: all
Maintainer: mingxiaoyu <fengying0347@163.com>
Section: luci
Priority: optional
Description: CFPick - Cloudflare IP optimizer for OpenWrt
Source: https://github.com/urbanescavenger/CFPick
EOF
cat > $workdir/luci-app-cfpick/CONTROL/postinst <<EOF
#!/bin/sh
[ "${IPKG_NO_SCRIPT}" = "1" ] && exit 0
[ -s ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
. ${IPKG_INSTROOT}/lib/functions.sh
default_postinst \$0 \$@
EOF

chmod +x $workdir/luci-app-cfpick/usr/lib/cfpick/bin/*.sh $workdir/luci-app-cfpick/usr/bin/cfpick
chmod +x $workdir/luci-app-cfpick/CONTROL/postinst
wget -O $workdir/ipkg-build https://raw.githubusercontent.com/openwrt/openwrt/openwrt-18.06/scripts/ipkg-build && \
chmod +x $workdir/ipkg-build && \
$workdir/ipkg-build -o root -g root $workdir/luci-app-cfpick $workdir