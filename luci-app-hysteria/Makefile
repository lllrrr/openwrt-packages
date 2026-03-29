include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-hysteria
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

PKG_LICENSE:=MIT
PKG_MAINTAINER:=luunarrr

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-hysteria
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=LuCI support for Hysteria2 PPP VPN
  PKGARCH:=all
  DEPENDS:=+luci-base +hysteria2-ppp +ppp +jsonfilter
endef

define Package/luci-app-hysteria/description
  LuCI web interface for configuring Hysteria2 as a PPP VPN client.
endef

define Build/Compile
endef

define Package/luci-app-hysteria/install
	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DATA) ./root/usr/share/luci/menu.d/luci-app-hysteria.json $(1)/usr/share/luci/menu.d/

	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./root/usr/share/rpcd/acl.d/luci-app-hysteria.json $(1)/usr/share/rpcd/acl.d/

	$(INSTALL_DIR) $(1)/usr/libexec/rpcd
	$(INSTALL_BIN) ./root/usr/libexec/rpcd/luci.hysteria $(1)/usr/libexec/rpcd/

	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./root/etc/config/hysteria $(1)/etc/config/

	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./root/etc/init.d/hysteria $(1)/etc/init.d/

	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./root/etc/uci-defaults/80_luci_hysteria $(1)/etc/uci-defaults/

	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/hysteria
	$(INSTALL_DATA) ./htdocs/luci-static/resources/view/hysteria/*.js $(1)/www/luci-static/resources/view/hysteria/
endef

define Package/luci-app-hysteria/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	( . /etc/uci-defaults/80_luci_hysteria ) && rm -f /etc/uci-defaults/80_luci_hysteria
	rm -rf /tmp/luci-indexcache /tmp/luci-modulecache
	exit 0
}
endef

$(eval $(call BuildPackage,luci-app-hysteria))
