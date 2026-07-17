include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-httping
PKG_VERSION:=1.1.15
PKG_RELEASE:=2

PKG_MAINTAINER:=davidu2003
PKG_LICENSE:=MIT

LUCI_TITLE:=Network Latency Monitor (HTTPing)
LUCI_DESCRIPTION:=A LuCI plugin to monitor network latency using HTTP requests with ECharts visualization.
LUCI_DEPENDS:=+luci-base +luci-lib-jsonc +curl +sqlite3-cli
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

define Package/luci-app-httping/conffiles
/etc/config/httping
endef

define Package/luci-app-httping/install
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_CONF) ./root/etc/config/httping $(1)/etc/config/
	$(INSTALL_BIN) ./root/etc/init.d/httping $(1)/etc/init.d/
	$(INSTALL_BIN) ./root/usr/bin/httping-daemon.lua $(1)/usr/bin/
	$(CP) ./root/usr/lib $(1)/usr/
	$(CP) ./root/www $(1)/
endef

define Package/luci-app-httping/postinst
#!/bin/sh
[ -z "$${IPKG_INSTROOT}" ] && /etc/init.d/httping enable
exit 0
endef

define Package/luci-app-httping/prerm
#!/bin/sh
[ -z "$${IPKG_INSTROOT}" ] && /etc/init.d/httping disable
exit 0
endef

$(eval $(call BuildPackage,luci-app-httping))
