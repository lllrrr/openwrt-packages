include $(TOPDIR)/rules.mk

LUCI_TITLE:=Hardware Monitor - 系统硬件监控
LUCI_DEPENDS:=+luci-compat +luci-lib-ipkg +iptables +netstat-nat

PKG_NAME:=luci-app-hardware-monitor
PKG_VERSION:=1.1
PKG_RELEASE:=1

include $(INCLUDE_DIR)/package.mk

define Package/$(PKG_NAME)
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=Hardware Monitor for OpenWrt
  PKGARCH:=all
endef

define Package/$(PKG_NAME)/description
  A comprehensive hardware monitoring application for OpenWrt with real-time status updates.
endef

define Build/Compile
endef

define Package/$(PKG_NAME)/install
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/controller
	$(INSTALL_DATA) ./luasrc/controller/hardware_monitor.lua $(1)/usr/lib/lua/luci/controller/
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/model/cbi/hardware_monitor
	$(INSTALL_DATA) ./luasrc/model/cbi/hardware_monitor/overview.lua $(1)/usr/lib/lua/luci/model/cbi/hardware_monitor/
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/view/hardware_monitor
	$(INSTALL_DATA) ./luasrc/view/hardware_monitor/*.htm $(1)/usr/lib/lua/luci/view/hardware_monitor/
	$(INSTALL_DIR) $(1)/www/luci-static/hardware_monitor
	$(INSTALL_DATA) ./root/www/cgi-bin/luci-static/hardware_monitor/* $(1)/www/luci-static/hardware_monitor/
endef

define Package/$(PKG_NAME)/postinst
#!/bin/sh
if [ -z "$${IPKG_INSTROOT}" ]; then
	rm -rf /tmp/luci-indexcache /tmp/luci-modulecache
fi
exit 0
endef

$(eval $(call BuildPackage,$(PKG_NAME)))
