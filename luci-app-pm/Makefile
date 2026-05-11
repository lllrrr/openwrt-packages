include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-pm
PKG_VERSION:=0.3.5
PKG_RELEASE:=$(shell date +%Y%m%d%H%M%S)

LUCI_TITLE:=Luci plugin that make ImmortalWRT poweroff and reboot to easy.
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

$(eval $(call BuildPackage,$(PKG_NAME)))
