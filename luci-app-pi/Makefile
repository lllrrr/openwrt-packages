include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-pi
PKG_VERSION:=1.0.0
PKG_RELEASE:=1
PKG_MAINTAINER:=Pi Contributors <pi@localhost>
PKG_LICENSE:=MIT

LUCI_TITLE:=LuCI support for Pi (Mihomo Transparent Proxy)
LUCI_DESCRIPTION:=基于 Mihomo 的 OpenWrt 透明代理 LuCI 管理界面
LUCI_DEPENDS:=+pi

LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

define Package/luci-app-pi
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=$(LUCI_TITLE)
  DEPENDS:=$(LUCI_DEPENDS)
  PKGARCH:=all
endef

define Package/luci-app-pi/description
  $(LUCI_DESCRIPTION)
  Provides a web interface to manage Pi transparent proxy:
    - Basic settings and service control
    - Mihomo YAML configuration editor
    - Real-time log viewer
endef

define Package/luci-app-pi/install
	# Menu definition
	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DATA) ./root/usr/share/luci/menu.d/luci-app-pi.json \
		$(1)/usr/share/luci/menu.d/

	# RPCd ACL
	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./root/usr/share/rpcd/acl.d/luci-app-pi.json \
		$(1)/usr/share/rpcd/acl.d/

	# LuCI JavaScript views
	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/pi
	$(INSTALL_DATA) ./root/www/luci-static/resources/view/pi/*.js \
		$(1)/www/luci-static/resources/view/pi/

	# UCI defaults
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./root/etc/uci-defaults/luci-app-pi \
		$(1)/etc/uci-defaults/

	# Default UCI config (only if not already present)
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./root/etc/config/pi $(1)/etc/config/pi
endef

$(eval $(call BuildPackage,luci-app-pi))
