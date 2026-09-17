# SPDX-License-Identifier: GPL-2.0-only

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-wan-latency-higoos
PKG_VERSION:=1.3.0
PKG_RELEASE:=1
PKGARCH:=all

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-wan-latency-higoos
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=HigoOS integration for WAN latency monitor
  DEPENDS:=+luci-app-wan-latency
endef

define Package/luci-app-wan-latency-higoos/description
 Adds a native read-only WAN latency panel to HigoOS Other Settings.
endef

define Build/Compile
endef

define Package/luci-app-wan-latency-higoos/install
	$(INSTALL_DIR) $(1)/usr/libexec
	$(INSTALL_BIN) ./files/usr/libexec/wan-latency-higoos-install $(1)/usr/libexec/wan-latency-higoos-install
	$(INSTALL_DIR) $(1)/usr/share/wan-latency/higoos
	$(INSTALL_DATA) ./files/usr/share/wan-latency/higoos/higo-wan-latency-native.js $(1)/usr/share/wan-latency/higoos/higo-wan-latency-native.js
endef

define Package/luci-app-wan-latency-higoos/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || /usr/libexec/wan-latency-higoos-install install
exit 0
endef

define Package/luci-app-wan-latency-higoos/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || /usr/libexec/wan-latency-higoos-install remove
exit 0
endef

$(eval $(call BuildPackage,luci-app-wan-latency-higoos))
