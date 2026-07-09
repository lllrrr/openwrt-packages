#
# Copyright (C) 2024 System Tools Project
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-systools
PKG_VERSION:=1.0.0
PKG_RELEASE:=1
PKG_LICENSE:=MIT
PKG_MAINTAINER:=System Tools Contributors

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-systools
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=Toolbox for OpenWrt
  URL:=https://github.com/luanmuc/luci-app-systools
  DEPENDS:=+luci-base +luci-compat
  PKGARCH:=all
endef

define Package/luci-app-systools/description
  Toolbox for OpenWrt - A collection of network wizards and smart home tools.
  Features:
  - Internet Setup Wizard (PPPoE, DHCP, Static IP)
  - IPv6 Quick Setup (Native, 6to4, 6in4, Relay, Disabled)
  - Side Route Mode (one-click bypass router mode)
  - Device Manager (device list, nicknames, static IP binding)
  - Smart Home Management (Home Assistant focused: images, storage, network)
  - Docker Storage Migration (migrate Docker data to USB drive)
  - Docker Image Pull with mirror acceleration
  - Argon theme deep adaptation
  - Multi-version support (24.12 / 25.12 / SNAPSHOT)
  - Multi-architecture support
  .
  OpenWrt 工具箱 - 网络向导和智能家居工具集合。
  功能：
  - 上网设置向导（PPPoE、DHCP、静态IP）
  - IPv6 一键设置（原生、6to4、6in4、中继、禁用）
  - 旁路由模式（一键切换旁路网关模式）
  - 设备管理（设备列表、备注名、静态IP绑定）
  - 智能家居管理（Home Assistant 专属：镜像、存储、网络）
  - Docker 存储迁移（将 Docker 数据迁移到 U 盘）
  - Docker 镜像拉取（支持国内镜像加速）
  - Argon 主题深度适配
  - 多版本支持（24.12 / 25.12 / SNAPSHOT）
  - 多架构支持
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) ./luasrc $(PKG_BUILD_DIR)/
	$(CP) ./root $(PKG_BUILD_DIR)/
	$(CP) ./po $(PKG_BUILD_DIR)/
	$(CP) ./htdocs $(PKG_BUILD_DIR)/
endef

define Build/Compile
	# Lua 插件不需要编译
endef

define Package/luci-app-systools/install
	# LuCI 控制器
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/controller
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/luasrc/controller/systools.lua $(1)/usr/lib/lua/luci/controller/systools.lua

	# LuCI 模型 (CBI)
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/model/cbi/systools
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/luasrc/model/cbi/systools/network_wizard.lua $(1)/usr/lib/lua/luci/model/cbi/systools/network_wizard.lua
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/luasrc/model/cbi/systools/ipv6.lua $(1)/usr/lib/lua/luci/model/cbi/systools/ipv6.lua
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/luasrc/model/cbi/systools/side_route.lua $(1)/usr/lib/lua/luci/model/cbi/systools/side_route.lua
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/luasrc/model/cbi/systools/device_manager.lua $(1)/usr/lib/lua/luci/model/cbi/systools/device_manager.lua
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/luasrc/model/cbi/systools/homeassistant.lua $(1)/usr/lib/lua/luci/model/cbi/systools/homeassistant.lua
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/luasrc/model/cbi/systools/smarthome_images.lua $(1)/usr/lib/lua/luci/model/cbi/systools/smarthome_images.lua
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/luasrc/model/cbi/systools/smarthome_storage.lua $(1)/usr/lib/lua/luci/model/cbi/systools/smarthome_storage.lua
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/luasrc/model/cbi/systools/smarthome_network.lua $(1)/usr/lib/lua/luci/model/cbi/systools/smarthome_network.lua

	# 静态资源 (CSS 等)
	$(INSTALL_DIR) $(1)/www/luci-static/resources/systools
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/htdocs/luci-static/resources/systools/systools.css $(1)/www/luci-static/resources/systools/systools.css

	# 视图模板
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/view/systools
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/luasrc/view/systools/about.htm $(1)/usr/lib/lua/luci/view/systools/about.htm

	# 后端 Shell 脚本
	$(INSTALL_DIR) $(1)/usr/libexec/systools
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/root/usr/libexec/systools/network_wizard.sh $(1)/usr/libexec/systools/network_wizard.sh
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/root/usr/libexec/systools/ipv6.sh $(1)/usr/libexec/systools/ipv6.sh
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/root/usr/libexec/systools/side_route.sh $(1)/usr/libexec/systools/side_route.sh
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/root/usr/libexec/systools/device_manager.sh $(1)/usr/libexec/systools/device_manager.sh
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/root/usr/libexec/systools/homeassistant.sh $(1)/usr/libexec/systools/homeassistant.sh
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/root/usr/libexec/systools/smarthome_images.sh $(1)/usr/libexec/systools/smarthome_images.sh
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/root/usr/libexec/systools/smarthome_storage.sh $(1)/usr/libexec/systools/smarthome_storage.sh
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/root/usr/libexec/systools/smarthome_network.sh $(1)/usr/libexec/systools/smarthome_network.sh

	# 公共函数库
	$(INSTALL_DIR) $(1)/usr/libexec/systools
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/root/usr/libexec/systools/systools-common.sh $(1)/usr/libexec/systools/systools-common.sh

	# UCI 配置文件
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/root/etc/config/systools $(1)/etc/config/systools

	# UCI 默认配置
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/root/etc/uci-defaults/luci-systools $(1)/etc/uci-defaults/luci-systools

	# 翻译文件
	if [ -d $(PKG_BUILD_DIR)/po ]; then \
		$(INSTALL_DIR) $(1)/usr/lib/lua/luci/i18n; \
		for lang in $(PKG_BUILD_DIR)/po/*/; do \
			lang_name=$$(basename $$lang); \
			if [ -f $$lang/systools.po ]; then \
				echo "Compiling translation: $$lang_name"; \
				po2lmo $$lang/systools.po $(1)/usr/lib/lua/luci/i18n/systools.$$lang_name.lmo 2>/dev/null || true; \
			fi; \
		done; \
	fi
endef

define Package/luci-app-systools/postinst
#!/bin/sh
# 安装后脚本
# 确保 uci-defaults 脚本被执行
if [ -x /etc/uci-defaults/luci-systools ]; then
	/etc/uci-defaults/luci-systools
	rm -f /etc/uci-defaults/luci-systools
fi

# 重启 LuCI
if [ -x /etc/init.d/uhttpd ]; then
	/etc/init.d/uhttpd restart 2>/dev/null || true
fi

exit 0
endef

define Package/luci-app-systools/prerm
#!/bin/sh
# 卸载前脚本
exit 0
endef

$(eval $(call BuildPackage,luci-app-systools))
