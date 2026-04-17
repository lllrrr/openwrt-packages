
include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-onlineupgrade
PKG_VERSION:=3.0.0
PKG_RELEASE:=1

LUCI_TITLE:=LuCI Online Upgrade V3
LUCI_DEPENDS:=+lua +luci-base +curl +ubus +ubusd

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-onlineupgrade
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=$(LUCI_TITLE)
endef

define Build/Compile
endef

define Package/luci-app-onlineupgrade/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./root/usr/bin/ota.sh $(1)/usr/bin/

	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./root/etc/config/ota $(1)/etc/config/
endef

$(eval $(call BuildPackage,luci-app-onlineupgrade))
