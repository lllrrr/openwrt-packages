#
# Copyright (C) 2026 System32X-code
#
# This is free software, licensed under the MIT License.
#

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-wanip-selector
PKG_VERSION:=1.0.0
PKG_RELEASE:=1
PKG_LICENSE:=MIT
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=System32X-code <System32_zyc@outlook.com>

LUCI_TITLE:=LuCI support for WAN IP Selector
LUCI_DESCRIPTION:=Redial the WAN interface until the public IPv4 address falls inside (or outside) a configurable set of address pools.
LUCI_DEPENDS:=+jsonfilter
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
