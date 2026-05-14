# SPDX-License-Identifier: GPL-2.0-only
#
# Copyright (C) 2024 OpenWrt-DeviceMaster Project
#

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-devicemaster
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

PKG_MAINTAINER:=OpenWrt-DeviceMaster Team
PKG_LICENSE:=GPL-2.0-only

LUCI_TITLE:=LuCI Device Master - Enhanced Device Management Plugin
LUCI_DEPENDS:=+luci-lib-base +luci-lib-jsonc +libubus-lua +ipset +nftables +kmod-sched-core
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

# Auto-cleanup on package removal
define Package/luci-app-devicemaster/postrm
#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] || /etc/init.d/devicemaster service_cleanup 2>/dev/null
/etc/init.d/rpcd restart 2>/dev/null
/etc/init.d/uhttpd restart 2>/dev/null
endef

$(eval $(call BuildPackage,luci-app-devicemaster))
