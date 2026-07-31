include $(TOPDIR)/rules.mk

PKG_VERSION:=1.26.7
PKG_RELEASE:=1
PKG_NAME:=luci-app-rustdeskd
PKG_MAINTAINER:=konvict <logo@permails.com>

LUCI_TITLE:=LuCI support for RustDesk Server
LUCI_DEPENDS:=+luci-base +rpcd +rpcd-mod-ucode +unzip +curl
LUCI_PKGARCH:=all
PKG_LICENSE:=Apache-2.0

define Package/$(PKG_NAME)/conffiles
/etc/config/rustdeskd
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
