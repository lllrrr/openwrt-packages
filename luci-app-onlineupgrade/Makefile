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
  # 增加了 jsonfilter 依赖，确保环境识别脚本能正常运行
  DEPENDS:=+luci-base +curl +jsonfilter
  PKGARCH:=all
endef

# 不需要进行编译操作
define Build/Prepare
endef

define Build/Compile
endef

define Package/luci-app-onlineupgrade/install
	# 安装 Controller
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/controller
	$(CP) ./luasrc/controller/* $(1)/usr/lib/lua/luci/controller/

	# 安装 View (如果有的话)
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/view/ota
	$(CP) ./luasrc/view/ota/* $(1)/usr/lib/lua/luci/view/ota/

	# 安装 Model
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/model/cbi
	$(CP) ./luasrc/model/cbi/* $(1)/usr/lib/lua/luci/model/cbi/

	# 安装配置文件
	$(INSTALL_DIR) $(1)/etc/config
	$(CP) ./root/etc/config/ota $(1)/etc/config/ota

	# 安装核心脚本 (ota.sh 和 ota-check)
	$(INSTALL_DIR) $(1)/usr/bin
	
	# 安装原有的升级脚本
	$(CP) ./root/usr/bin/ota.sh $(1)/usr/bin/ota.sh
	chmod 755 $(1)/usr/bin/ota.sh

	# 【新增】安装环境识别脚本 ota-check
	$(CP) ./root/usr/bin/ota-check $(1)/usr/bin/ota-check
	chmod 755 $(1)/usr/bin/ota-check
endef

$(eval $(call BuildPackage,luci-app-onlineupgrade))