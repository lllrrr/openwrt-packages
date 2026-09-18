# SPDX-License-Identifier: GPL-2.0-only
# Copyright (C) 2026 xiaokeikei

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-wan-latency
PKG_VERSION:=1.4.0
PKG_RELEASE:=1
PKG_MAINTAINER:=xiaokeikei
PKG_LICENSE:=GPL-2.0-only
PKG_LICENSE_FILES:=LICENSE

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-wan-latency
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=WAN latency monitor for LuCI
  PKGARCH:=all
  DEPENDS:=+luci-base +lua +luci-lib-nixio +cgi-io +rpcd-mod-file +curl +ip-full
endef

define Package/luci-app-wan-latency/description
 Continuously measures WAN latency, stores compact time-series data, and shows
 an interactive LuCI dashboard with custom targets and time ranges.
endef

define Package/luci-app-wan-latency/conffiles
/etc/config/wan-latency
endef

define Build/Compile
endef

define Package/luci-app-wan-latency/install
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/etc/config/wan-latency $(1)/etc/config/wan-latency
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/wan-latency $(1)/etc/init.d/wan-latency
	$(INSTALL_DIR) $(1)/usr/lib/lua
	$(INSTALL_DATA) ./files/usr/lib/lua/wanlatency.lua $(1)/usr/lib/lua/wanlatency.lua
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) ./files/usr/sbin/wan-latencyd $(1)/usr/sbin/wan-latencyd
	$(INSTALL_BIN) ./files/usr/sbin/wan-latency-probe $(1)/usr/sbin/wan-latency-probe
	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DATA) ./files/usr/share/luci/menu.d/luci-app-wan-latency.json $(1)/usr/share/luci/menu.d/luci-app-wan-latency.json
	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./files/usr/share/rpcd/acl.d/luci-app-wan-latency.json $(1)/usr/share/rpcd/acl.d/luci-app-wan-latency.json
	$(INSTALL_DIR) $(1)/usr/libexec
	$(INSTALL_BIN) ./files/usr/libexec/wan-latency-api $(1)/usr/libexec/wan-latency-api
	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/status
	$(INSTALL_DATA) ./files/www/luci-static/resources/view/status/wan_latency.js $(1)/www/luci-static/resources/view/status/wan_latency.js
	$(INSTALL_DIR) $(1)/www/wan-latency
	$(INSTALL_DATA) ./files/www/wan-latency/index.html $(1)/www/wan-latency/index.html
endef

define Package/luci-app-wan-latency/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	/etc/init.d/wan-latency enable
	/etc/init.d/wan-latency restart
	rm -f /www/cgi-bin/wan-latency
	rm -f /tmp/luci-indexcache /tmp/luci-modulecache/* 2>/dev/null
	/etc/init.d/rpcd restart
	/etc/init.d/uhttpd reload
}
exit 0
endef

define Package/luci-app-wan-latency/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || /etc/init.d/wan-latency stop
exit 0
endef

$(eval $(call BuildPackage,luci-app-wan-latency))
