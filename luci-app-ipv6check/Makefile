# SPDX-License-Identifier: GPL-2.0-only
#
# Copyright (C) 2024 IPv6Check

include $(TOPDIR)/rules.mk

PKG_LICENSE:=GPL-2.0-only
PKG_MAINTAINER:=IPv6Check

LUCI_TITLE:=LuCI support for IPv6 Connectivity Check
LUCI_DEPENDS:=+iputils-ping +jsonfilter
LUCI_PKGARCH:=all

PKG_VERSION:=1.0.0
PKG_RELEASE:=1

include $(TOPDIR)/feeds/luci/luci.mk

define Package/$(PKG_NAME)/conffiles
/etc/config/ipv6check
endef

define Package/$(PKG_NAME)/install
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./root/etc/config/ipv6check $(1)/etc/config/ipv6check
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./root/etc/init.d/ipv6check $(1)/etc/init.d/ipv6check
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./root/etc/uci-defaults/luci-app-ipv6check $(1)/etc/uci-defaults/luci-app-ipv6check
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./root/usr/bin/ipv6check $(1)/usr/bin/ipv6check
	$(INSTALL_DIR) $(1)/usr/libexec/rpcd
	$(INSTALL_BIN) ./root/usr/libexec/rpcd/ipv6check $(1)/usr/libexec/rpcd/ipv6check
	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./root/usr/share/rpcd/acl.d/luci-app-ipv6check.json $(1)/usr/share/rpcd/acl.d/luci-app-ipv6check.json
	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DATA) ./root/usr/share/luci/menu.d/luci-app-ipv6check.json $(1)/usr/share/luci/menu.d/luci-app-ipv6check.json
	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/ipv6check
	$(INSTALL_DATA) ./htdocs/luci-static/resources/view/ipv6check/status.js $(1)/www/luci-static/resources/view/ipv6check/status.js
	$(INSTALL_DATA) ./htdocs/luci-static/resources/view/ipv6check/config.js $(1)/www/luci-static/resources/view/ipv6check/config.js
endef

# call BuildPackage - OpenWrt buildroot signature
