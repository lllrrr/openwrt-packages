# SPDX-License-Identifier: GPL-2.0-only
#
# Copyright (C) 2024 IPv6Check
#
# IPv6 连通性检测 LuCI 插件 - OpenWrt 软件包构建文件

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-ipv6check
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

LUCI_TITLE:=LuCI support for IPv6 Connectivity Check
LUCI_DESCRIPTION:=IPv6 连通性定时检测与自动恢复插件，支持多源检测和接口自动重启
LUCI_DEPENDS:=+iputils-ping +jsonfilter
LUCI_PKGARCH:=all

PKG_LICENSE:=GPL-2.0-only
PKG_MAINTAINER:=IPv6Check

define Package/$(PKG_NAME)/conffiles
/etc/config/ipv6check
endef

define Package/$(PKG_NAME)/install
	# 安装 UCI 配置
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./root/etc/config/ipv6check $(1)/etc/config/ipv6check

	# 安装 init.d 服务脚本
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./root/etc/init.d/ipv6check $(1)/etc/init.d/ipv6check

	# 安装 uci-defaults 初始化脚本
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./root/etc/uci-defaults/luci-app-ipv6check $(1)/etc/uci-defaults/luci-app-ipv6check

	# 安装核心监测脚本
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./root/usr/bin/ipv6check $(1)/usr/bin/ipv6check

	# 安装 rpcd 后端
	$(INSTALL_DIR) $(1)/usr/libexec/rpcd
	$(INSTALL_BIN) ./root/usr/libexec/rpcd/ipv6check $(1)/usr/libexec/rpcd/ipv6check

	# 安装 ACL 权限
	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./root/usr/share/rpcd/acl.d/luci-app-ipv6check.json $(1)/usr/share/rpcd/acl.d/luci-app-ipv6check.json

	# 安装 LuCI 菜单
	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DATA) ./root/usr/share/luci/menu.d/luci-app-ipv6check.json $(1)/usr/share/luci/menu.d/luci-app-ipv6check.json

	# 安装 LuCI 前端视图
	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/ipv6check
	$(INSTALL_DATA) ./htdocs/luci-static/resources/view/ipv6check/status.js $(1)/www/luci-static/resources/view/ipv6check/status.js
	$(INSTALL_DATA) ./htdocs/luci-static/resources/view/ipv6check/config.js $(1)/www/luci-static/resources/view/ipv6check/config.js
endef


include $(TOPDIR)/feeds/luci/luci.mk

$(eval $(call BuildPackage,$(PKG_NAME)))
