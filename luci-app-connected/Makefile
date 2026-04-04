# Copyright 2026 Bruno Marinier (bmgm41@gmail.com)
# This is free software, licensed under the GNU General Public License v2.

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-connected
PKG_VERSION:=2.0.0
PKG_RELEASE:=2

PKG_MAINTAINER:=Bruno Marinier <bmgm41@gmail.com>
PKG_LICENSE:=Apache-2.0

LUCI_TITLE:=LuCI Status Page for Connected devices
LUCI_DESCRIPTION:=Status page for viewing information about connected devices
LUCI_DEPENDS:=+luci-base +rpcd +ucode +ucode-mod-resolv

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
