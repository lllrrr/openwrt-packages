include $(TOPDIR)/rules.mk

PKG_VERSION:=1.1.1
PKG_RELEASE:=1
PKG_LICENSE:=MIT
PKG_MAINTAINER:=chmod740

LUCI_TITLE:=LuCI Internet Connectivity Monitor
LUCI_DESCRIPTION:=Multi-target Internet connectivity monitoring with availability history and incident tracking
LUCI_DEPENDS:=+luci-base +rpcd +jshn +jsonfilter +curl +ca-bundle
LUCI_PKGARCH:=all

define Package/luci-app-monitor/conffiles
/etc/config/internet-monitor
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
