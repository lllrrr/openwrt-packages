include $(TOPDIR)/feeds/luci/luci.mk

PKG_NAME:=luci-app-parentalcontrol
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

PKG_LICENSE:=MIT
PKG_MAINTAINER:=

LUCI_TITLE:=LuCI Parental Control
LUCI_DESCRIPTION:=Time-based parental control with per-device scheduling, temporary overrides, and global enable/disable.
LUCI_DEPENDS:=+luci-base +nftables
LUCI_PKGARCH:=all

$(eval $(call BuildPackage,luci-app-parentalcontrol))
