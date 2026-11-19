#
# Copyright (C) 2008-2014 The LuCI Team <luci@lists.subsignal.org>
#
# This is free software, licensed under the Apache License, Version 2.0 .
#

include $(TOPDIR)/rules.mk

LUCI_TITLE:=LuCI for Cloudflare
LUCI_PKGARCH:=all
PKG_VERSION:=1.0
PKG_RELEASE:=1
# 依赖 luci-compat(提供 legacy CBI 表单) 与时区数据(zoneinfo-asia,否则无法正确输出北京时区)
LUCI_DEPENDS:=+luci-compat +zoneinfo-asia

include $(TOPDIR)/feeds/luci/luci.mk
# call BuildPackage - OpenWrt buildroot signature
