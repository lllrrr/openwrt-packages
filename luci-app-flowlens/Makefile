include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-flowlens
PKG_VERSION:=0.1.27
PKG_RELEASE:=1
PKG_LICENSE:=MIT
PKG_MAINTAINER:=FlowLens Contributors

LUCI_TITLE:=FlowLens realtime device traffic dashboard
LUCI_DESCRIPTION:=A LuCI dashboard for LAN device presence and realtime per-device throughput.
LUCI_DEPENDS:=+nlbwmon +ip-full
LUCI_PKGARCH:=all

LUCI_MK:=$(firstword $(wildcard $(TOPDIR)/feeds/luci/luci.mk $(TOPDIR)/feeds/luci/luci.mk))
ifeq ($(LUCI_MK),)
  $(error Unable to find luci.mk. Put this package in an OpenWrt feed or under feeds/luci/applications)
endif

include $(LUCI_MK)

# call BuildPackage - OpenWrt buildroot signature
