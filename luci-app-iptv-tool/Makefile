include $(TOPDIR)/rules.mk

LUCI_TITLE:=LuCI support for IPTV-Tool
LUCI_URL:=https://github.com/blueveryday/luci-app-iptv-tool
PKG_DESCRIPTION:=Provides a LuCI Web management interface for IPTV-Tool, allowing EPG, live source and logo management.
PKG_MAINTAINER:=blueveryday
LUCI_DEPENDS:=+luci-base
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature