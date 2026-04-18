include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-onlineupgrade
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-onlineupgrade
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=LuCI support for Online Upgrade
  DEPENDS:=+luci-base +curl +jsonfilter
  PKGARCH:=all
endef

# 【关键修复 1】告诉 SDK 不需要进行编译操作
define Build/Prepare
endef

define Build/Compile
endef

# 【关键修复 2】定义安装逻辑
# 请确保你的源码目录里有对应的文件夹
define Package/luci-app-onlineupgrade/install
	# 每一个 $(INSTALL_DIR) 和 $(CP) 前面都是一个按下 Tab 键产生的缩进
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/controller
	$(CP) ./luasrc/controller/* $(1)/usr/lib/lua/luci/controller/

	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/view/ota
	$(CP) ./luasrc/view/ota/* $(1)/usr/lib/lua/luci/view/ota/

	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/model/cbi
	$(CP) ./luasrc/model/cbi/* $(1)/usr/lib/lua/luci/model/cbi/

	$(INSTALL_DIR) $(1)/etc/config
	$(CP) ./root/etc/config/ota $(1)/etc/config/ota

	$(INSTALL_DIR) $(1)/usr/bin
	$(CP) ./root/usr/bin/ota.sh $(1)/usr/bin/ota.sh
	chmod 755 $(1)/usr/bin/ota.sh
endef

$(eval $(call BuildPackage,luci-app-onlineupgrade))
