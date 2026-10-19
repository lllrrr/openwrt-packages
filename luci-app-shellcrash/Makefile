include $(TOPDIR)/rules.mk

LUCI_TITLE:=LuCI support for ShellCrash
LUCI_DEPENDS:=+curl +ca-certificates +kmod-tun +kmod-inet-diag
LUCI_PKGARCH:=all

PKG_NAME:=luci-app-shellcrash
PKG_VERSION:=1.0.0
PKG_RELEASE:=1
PKG_MAINTAINER:=hhCodingCat
PKG_LICENSE:=GPL-3.0-or-later

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
