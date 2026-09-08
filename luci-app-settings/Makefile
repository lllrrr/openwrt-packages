# Copyright (C) 2026
#
# This is free software, licensed under the Apache License, Version 2.0

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-settings
PKG_VERSION:=1.5.0
PKG_RELEASE:=1

PKG_LICENSE:=Apache-2.0
PKG_MAINTAINER:=lyl2dora <lyl2dora@gmail.com>

LUCI_TITLE:=LuCI support for editing raw UCI configuration files
LUCI_DESCRIPTION:=Directly view and edit /etc/config/network, firewall, dhcp and \
	other configuration files in LuCI and apply the changes. Custom files can be \
	added to the editor as well.
LUCI_DEPENDS:=+luci-base
LUCI_PKGARCH:=all

# cm6.js 是 esbuild 预压缩产物,跳过 luci.mk 的 jsmin 以免二次压缩损坏代码
LUCI_MINIFY_JS:=0

# 卸载时清理 LuCI 缓存和本应用的临时目录,并让 rpcd 丢弃已卸载的 ACL。
# 自定义文件列表 /etc/luci-app-settings.json 有意保留(用户数据,重装可恢复;
# opkg 升级会走 remove+install,若在此删除会导致每次升级丢失列表)。
define Package/luci-app-settings/postrm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	rm -f /tmp/luci-indexcache.*
	rm -rf /tmp/luci-modulecache/ /tmp/luci-app-settings/
	/etc/init.d/rpcd reload 2>/dev/null
	exit 0
}
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
