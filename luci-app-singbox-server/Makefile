# SPDX-License-Identifier: GPL-3.0-or-later
# LuCI support for sing-box server (OpenWrt 25.03+)

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-sing-box-server
PKG_VERSION:=1.0.0
PKG_RELEASE:=0

LUCI_TITLE:=LuCI support for sing-box server
LUCI_DEPENDS:=+luci-base +rpcd +rpcd-mod-file
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
