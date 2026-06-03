include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-wizard
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

LUCI_TITLE:=Initial Setup Wizard
LUCI_PKGARCH:=all
LUCI_DEPENDS:=+luci-base

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-wizard/conffiles
/etc/config/wizard
endef

define Package/luci-app-wizard/install
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/controller
	$(INSTALL_DATA) ./luasrc/controller/wizard.lua $(1)/usr/lib/lua/luci/controller/wizard.lua
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/model/cbi/wizard
	$(INSTALL_DATA) ./luasrc/model/cbi/wizard/*.lua $(1)/usr/lib/lua/luci/model/cbi/wizard/
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_DATA) ./root/etc/config/wizard $(1)/etc/config/wizard
	$(INSTALL_DIR) $(1)/rom/etc/config
	$(INSTALL_DATA) ./root/rom/etc/config/wizard $(1)/rom/etc/config/wizard
endef

$(eval $(call BuildPackage,luci-app-wizard))
