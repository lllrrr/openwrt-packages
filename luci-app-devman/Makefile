include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-devman
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

PKG_SOURCE_PROTO:=git
PKG_SOURCE_URL:=https://github.com/r1172464137/devman.git
PKG_SOURCE_VERSION:=f7695bf
PKG_MIRROR_HASH:=skip

PKG_MAINTAINER:=r1172464137
PKG_LICENSE:=MIT

LUCI_TITLE:=Device Manager Web UI
LUCI_DEPENDS:=+devman +luci-base
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

define Package/luci-app-devman/description
  LuCI interface for devman - device monitoring, blocking, and rate limiting.
endef

$(eval $(call BuildPackage,luci-app-devman))
