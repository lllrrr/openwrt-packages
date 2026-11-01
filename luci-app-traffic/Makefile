include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-traffic
PKG_VERSION:=1.0.0
PKG_RELEASE:=1
PKG_LICENSE:=MIT
PKG_MAINTAINER:=GitHubjunjun

LUCI_TITLE:=WAN traffic monitor for LuCI
LUCI_DESCRIPTION:=Lightweight WAN traffic statistics and charts. \
Reads /proc/net/dev directly, so it keeps working with flow offloading enabled.
LUCI_PKGARCH:=all
LUCI_DEPENDS:=

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
