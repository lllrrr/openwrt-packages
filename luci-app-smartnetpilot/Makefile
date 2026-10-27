#
# Copyright (C) 2026 Arthur97172 <arthur97172@outlook.com>
#
# This is free software, licensed under the GNU General Public License v3.0
# (SPDX: GPL-3.0-only).
#

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-smartnetpilot
PKG_VERSION:=1.1.8
PKG_RELEASE:=1

PKG_LICENSE:=GPL-3.0-only
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=Arthur97172 <Arthur97172@users.noreply.github.com>

LUCI_TITLE:=LuCI Smart NetPilot network setup wizard
LUCI_DEPENDS:=+luci-base
LUCI_PKGARCH:=all
LUCI_MAINTAINER:=Arthur97172 <Arthur97172@users.noreply.github.com>
LUCI_URL:=https://github.com/Arthur97172/luci-app-smartnetpilot

# Keep the translation package on the same version as the app package.
PKG_PO_VERSION:=$(PKG_VERSION)-r$(PKG_RELEASE)

define Package/luci-app-smartnetpilot/conffiles
/etc/config/smartnetpilot
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
