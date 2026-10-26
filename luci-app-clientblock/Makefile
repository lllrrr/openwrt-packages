include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-clientblock
PKG_VERSION:=1.2.1
PKG_RELEASE:=1

PKG_LICENSE:=Apache-2.0
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=rheatin

LUCI_TITLE:=LuCI app for client access control
LUCI_DEPENDS:=+luci-base +rpcd +nftables +firewall4 +coreutils +coreutils-sleep +bash
LUCI_PKGARCH:=all

define Package/luci-app-clientblock/conffiles
endef

# luci.mk copies root/ without preserving the execute bit, and rpcd refuses to
# run a handler it cannot exec, so restore the modes after the generic install.
define Package/luci-app-clientblock/install
	$(call Package/luci/install/template,$(1),.)
	$(INSTALL_DIR) $(1)/usr/libexec/rpcd $(1)/usr/sbin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/root/usr/libexec/rpcd/luci.clientblock $(1)/usr/libexec/rpcd/
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/root/usr/sbin/clientblock-watch $(1)/usr/sbin/
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/root/etc/init.d/clientblock $(1)/etc/init.d/
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
$(eval $(call BuildPackage,luci-app-clientblock))
