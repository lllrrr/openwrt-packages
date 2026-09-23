include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-oxidns
PKG_VERSION:=0.1.5
PKG_RELEASE:=3

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
