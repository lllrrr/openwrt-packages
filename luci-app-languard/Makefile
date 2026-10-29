include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-languard
PKG_VERSION:=2.8.0
PKG_RELEASE:=1

PKG_LICENSE:=Apache-2.0
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=rheatin

LUCI_TITLE:=LuCI app for LAN access control
LUCI_DEPENDS:=+luci-base +rpcd +nftables +firewall4 +coreutils +coreutils-sleep +bash
LUCI_PKGARCH:=all

define Package/luci-app-languard/conffiles
endef

# luci.mk copies root/ without preserving the execute bit, and rpcd refuses to
# run a handler it cannot exec, so restore the modes after the generic install.
define Package/luci-app-languard/install
	$(call Package/luci/install/template,$(1),.)
	$(INSTALL_DIR) $(1)/usr/libexec/rpcd $(1)/usr/sbin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/root/usr/libexec/rpcd/luci.languard $(1)/usr/libexec/rpcd/
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/root/usr/sbin/languard-watch $(1)/usr/sbin/
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/root/etc/init.d/languard $(1)/etc/init.d/
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
$(eval $(call BuildPackage,luci-app-languard))
