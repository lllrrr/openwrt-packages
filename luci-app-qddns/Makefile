# SPDX-License-Identifier: GPL-2.0-only

include $(TOPDIR)/rules.mk

LUCI_TITLE:=LuCI support for qddns
LUCI_DEPENDS:=+luci-base +qddns
LUCI_PKGARCH:=all
PKG_VERSION:=0.2.0
PKG_RELEASE:=1

PKG_LICENSE:=GPL-2.0-only
PKG_MAINTAINER:=OpenAI

define Build/Prepare/luci-app-qddns
	$(FIND) $(PKG_BUILD_DIR) -type d -exec chmod 0755 {} +
	$(FIND) $(PKG_BUILD_DIR) -type f -exec chmod 0644 {} +
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
