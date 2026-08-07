include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-netmonitor
PKG_VERSION:=1.4.0
PKG_RELEASE:=07082026

PKG_MAINTAINER:=Fidz
PKG_LICENSE:=Unlicense
PKG_LICENSE_FILES:=LICENSE

PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)

include $(INCLUDE_DIR)/package.mk

define Package/$(PKG_NAME)
	CATEGORY:=LuCI
	SUBMENU:=3. Applications
	TITLE:=LuCI Network Monitor
	PKGARCH:=all
	DEPENDS:=+libc +vnstat2 +vnstati2
	MAINTAINER:=Fidz
endef

define Package/$(PKG_NAME)/description
    Network monitoring for LuCI
endef

define Build/Prepare
	$(CP) $(CURDIR)/root $(PKG_BUILD_DIR)
	$(CP) $(CURDIR)/luasrc $(PKG_BUILD_DIR)
	$(CP) $(CURDIR)/htdocs $(PKG_BUILD_DIR)
	mkdir -p $(PKG_BUILD_DIR)/root/etc/vnstat
	chmod 0755 $(PKG_BUILD_DIR)/htdocs/cgi-bin/netmonitor/stats
	chmod 0755 $(PKG_BUILD_DIR)/htdocs/netmonitor/vnstati/vnstati.sh
endef

define Build/Configure
endef

define Build/Compile
endef

define Package/$(PKG_NAME)/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	/etc/init.d/vnstat restart
}
exit 0
endef

define Package/$(PKG_NAME)/install
	$(CP) $(PKG_BUILD_DIR)/root/* $(1)/
	$(CP) $(PKG_BUILD_DIR)/luasrc/* $(1)/usr/lib/lua/luci/
	$(INSTALL_DIR) $(1)/www/cgi-bin/netmonitor
	$(CP) $(PKG_BUILD_DIR)/htdocs/cgi-bin/netmonitor/* $(1)/www/cgi-bin/netmonitor/
	$(INSTALL_DIR) $(1)/www/netmonitor
	$(CP) $(PKG_BUILD_DIR)/htdocs/netmonitor/* $(1)/www/netmonitor/
endef

$(eval $(call BuildPackage,$(PKG_NAME)))
