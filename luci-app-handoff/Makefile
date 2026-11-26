#
# LuCI support for handoff（多网关分流）的后端与页面一起打包
#
# This is free software, licensed under the Apache License, Version 2.0 .
#

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-handoff
PKG_VERSION:=0.2.2
PKG_RELEASE:=1
PKG_LICENSE:=Apache-2.0
PKG_LICENSE_FILES:=LICENSE

LUCI_TITLE:=LuCI support for handoff (网关分流)
LUCI_DEPENDS:=+firewall4 +ip-full +jshn
LUCI_PKGARCH:=all

define Package/$(PKG_NAME)/conffiles
/etc/config/handoff
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
