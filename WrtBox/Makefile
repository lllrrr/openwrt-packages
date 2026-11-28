include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-wrtbox
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

LUCI_TITLE:=LuCI support for WRTBox (sing-box Community Edition)
LUCI_DESCRIPTION:=Web interface and automation manager for reF1nd sing-box Community Edition with independent core management, CDN acceleration, and JSON subscription hot-reload.
LUCI_DEPENDS:=+luci-base +rpcd +rpcd-mod-ucode +ucode +ucode-mod-fs +ucode-mod-ubus +ucode-mod-uci +curl +ca-bundle
LUCI_PKGARCH:=all

PKG_LICENSE:=Apache-2.0
PKG_MAINTAINER:=wrtbox

include $(TOPDIR)/feeds/luci/luci.mk

define Package/$(PKG_NAME)/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
mkdir -p /etc/wrtbox/profiles /usr/libexec/wrtbox /tmp/log
chmod 0755 /etc/init.d/wrtbox 2>/dev/null || true
chmod 0755 /usr/libexec/wrtbox/core-manager.sh \
	/usr/libexec/wrtbox/sub-manager.uc \
	/usr/libexec/wrtbox/fw4-tun.sh \
	/usr/libexec/wrtbox/cron-task.sh 2>/dev/null || true
rm -rf /tmp/luci-indexcache /tmp/luci-modulecache/*
/etc/init.d/rpcd reload >/dev/null 2>&1 || true
exit 0
endef

define Package/$(PKG_NAME)/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
/etc/init.d/wrtbox stop >/dev/null 2>&1 || true
/etc/init.d/wrtbox disable >/dev/null 2>&1 || true
/usr/libexec/wrtbox/cron-task.sh remove >/dev/null 2>&1 || true
exit 0
endef

# call BuildPackage - OpenWrt buildroot signature
