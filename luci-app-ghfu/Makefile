include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-ghfu
PKG_VERSION:=1.3.2
PKG_RELEASE:=1
PKG_LICENSE:=GPL-3.0-only
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=smallprogram

LUCI_TITLE:=LuCI support for GitHub Firmware Upgrade
LUCI_DEPENDS:=+luci-base +uclient-fetch +ca-bundle
LUCI_PKGARCH:=all

ifneq ($(wildcard $(TOPDIR)/feeds/luci/luci.mk),)
  include $(TOPDIR)/feeds/luci/luci.mk
else
  include $(TOPDIR)/feeds/luci/luci.mk
endif

# call BuildPackage - OpenWrt buildroot signature
