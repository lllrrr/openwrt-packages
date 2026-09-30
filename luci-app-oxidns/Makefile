include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-oxidns
PKG_VERSION:=0.1.5
PKG_RELEASE:=5

PKG_LICENSE:=GPL-3.0-or-later
PKG_MAINTAINER:=Sven Shi <isvenshi@gmail.com>

LUCI_TITLE:=LuCI support for OxiDNS
LUCI_DEPENDS:=+luci-base +rpcd +jsonfilter +uclient-fetch +ca-bundle
LUCI_PKGARCH:=all

define Package/luci-app-oxidns/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT:-}" ] && exit 0
rm -f /tmp/luci-indexcache* 2>/dev/null || true
rm -rf /tmp/luci-modulecache/* 2>/dev/null || true
if [ -d /www/luci-static/resources/view/oxidns ]; then
	find /www/luci-static/resources/view/oxidns -type f -name '*.js' -exec touch {} + 2>/dev/null || true
fi
if [ -x /etc/init.d/rpcd ]; then
	/etc/init.d/rpcd restart >/dev/null 2>&1 || true
fi
# 0.1.4-r1 把 learn-reset 脚本从 /usr/bin 挪到了 /usr/libexec/oxidns，旧 cron 块里的
# 路径要跟着改，否则定时重置只会在 cron 日志里静默失败。
#
# 这段必须写在这里：发版走官方 SDK（.github/workflows/build-packages.yml 用
# gh-action-sdk），它的 postinst 只来自本文件的 define 块，不读
# scripts/build-luci-package.sh 里的任何东西。它原先只写在那个脚本的 heredoc 里，
# 于是线上安装从来没有跑过这段迁移 —— 本地造包解出来核对也永远核不到。
if [ -f /etc/crontabs/root ] && [ -x /usr/libexec/oxidns/learn-reset.sh ]; then
	sed -i 's#/usr/bin/oxidns-learn-reset\.sh#/usr/libexec/oxidns/learn-reset.sh#g' /etc/crontabs/root 2>/dev/null || true
	if [ -x /etc/init.d/cron ]; then
		/etc/init.d/cron restart >/dev/null 2>&1 || true
	fi
fi
exit 0
endef

define Package/luci-app-oxidns/postrm
#!/bin/sh
[ -n "$${IPKG_INSTROOT:-}" ] && exit 0
rm -f /tmp/luci-indexcache* 2>/dev/null || true
rm -rf /tmp/luci-modulecache/* 2>/dev/null || true
if [ -x /etc/init.d/rpcd ]; then
	/etc/init.d/rpcd restart >/dev/null 2>&1 || true
fi
exit 0
endef

# 翻译包（luci-i18n-oxidns-*）的版本号。
#
# luci.mk 默认拿 PKG_PO_VERSION 给翻译包定版，它由「最后一次改动 po/ 的提交」推导而来
# （形如 26.263.19088~0985e71，见 luci.mk 里的 findrev），与 PKG_VERSION/PKG_RELEASE 无关。
# 不钉住的话，同一个 Release 里应用包叫 luci-app-oxidns-0.1.4-r4.apk、翻译包却叫
# luci-i18n-oxidns-zh-cn-26.263.19088~0985e71.apk，用户按 Release 说明拼不出后者。
# luci.mk 里该变量是 `PKG_PO_VERSION?=`（可覆盖），这里显式钉成与应用包同一版本。
PKG_PO_VERSION:=$(PKG_VERSION)-r$(PKG_RELEASE)

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
