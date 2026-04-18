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
	# 1. 安装 Controller (Lua 脚本)
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/controller
	$(CP) ./luasrc/controller/* $(1)/usr/lib/lua/luci/controller/

	# 2. 安装 View (HTM 模板) - 这里的 ota 文件夹必须对应
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/view/ota
	$(CP) ./luasrc/view/ota/* $(1)/usr/lib/lua/luci/view/ota/

	# 3. 安装配置文件或启动脚本 (如果有)
	$(INSTALL_DIR) $(1)/etc/config
	[ -d ./root/etc/config ] && $(CP) ./root/etc/config/* $(1)/etc/config/ || true
	
	$(INSTALL_DIR) $(1)/etc/init.d
	[ -d ./root/etc/init.d ] && $(CP) ./root/etc/init.d/* $(1)/etc/init.d/ || true
endef

$(eval $(call BuildPackage,luci-app-onlineupgrade))
