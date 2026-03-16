# Makefile for luci-app-backup
include $(TOPDIR)/rules.mk

LUCI_TITLE:=LuCI support for Backup and Restore
LUCI_DEPENDS:=+jsonfilter +gnupg +luci-lib-jsonc
LUCI_PKGARCH:=all

PKG_NAME:=luci-app-backup
PKG_VERSION:=2.0
PKG_RELEASE:=1

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
