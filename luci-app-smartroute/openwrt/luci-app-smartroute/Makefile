# 智能分流界面（与架构无关）。文件由 scripts/build-packages.sh 从仓库 luci/ 复制到 files/
include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-smartroute
PKG_VERSION:=$(or $(SR_VERSION),0.0.0)
PKG_RELEASE:=1
PKG_LICENSE:=Apache-2.0
PKG_LICENSE_FILES:=LICENSE

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-smartroute
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=LuCI support for smartroute（智能分流）
  DEPENDS:=+smartroute
  # 后台要求同版本：只升级界面包时也会一并升级后台
  EXTRA_DEPENDS:=luci-base (>=0), rpcd-mod-ucode (>=0), smartroute (=$(PKG_VERSION)-r$(PKG_RELEASE))
  PKGARCH:=all
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
endef

define Build/Compile
endef

define Package/luci-app-smartroute/install
	$(INSTALL_DIR) $(1)/www $(1)/usr/share
	$(CP) ./files/htdocs/* $(1)/www/
	$(CP) ./files/root/usr/share/* $(1)/usr/share/
endef

define Package/luci-app-smartroute/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	rm -rf /tmp/luci-indexcache* /tmp/luci-modulecache
	/etc/init.d/rpcd reload
}
exit 0
endef

$(eval $(call BuildPackage,luci-app-smartroute))
