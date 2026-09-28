# SPDX-License-Identifier: GPL-2.0-only
#
# Copyright (C) 2024 OpenWrt-DeviceMaster Project
#

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-devicemaster
PKG_VERSION:=1.1.0
PKG_RELEASE:=1

PKG_MAINTAINER:=OpenWrt-DeviceMaster Team
PKG_LICENSE:=GPL-2.0-only

LUCI_TITLE:=LuCI Device Master - Enhanced Device Management Plugin
LUCI_DEPENDS:=+luci-lib-base +luci-lib-jsonc +libubus-lua +jsonfilter +curl +nftables
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

# /etc/config/devicemaster holds user data (device names, groups, block/rate
# rules). luci.mk only copies `root/` into the package - it declares no
# conffiles - so without the line below opkg treats the file as an ordinary
# package file and silently overwrites the user's configuration on every
# `opkg upgrade` / sysupgrade-preserved reinstall.
define Package/luci-app-devicemaster/conffiles
/etc/config/devicemaster
endef

# Auto-cleanup on package removal.
#
# NOTE:
#  * $1 is "remove" for a real removal, "upgrade" when opkg is replacing the
#    package with a newer version. The cleanup deletes the UCI config, the DHCP
#    host entries and the runtime files - doing that during an upgrade throws
#    away all of the user's device data, so it is now restricted to "remove".
#  * $${IPKG_INSTROOT} (double $) is required: with a single $ make expands the
#    variable itself, the test degenerates to `[ -n "" ]` and the guard never
#    works.
define Package/luci-app-devicemaster/postrm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	if [ "$$1" = "remove" ]; then
		/etc/init.d/devicemaster service_cleanup 2>/dev/null
	fi
	/etc/init.d/rpcd restart 2>/dev/null
	/etc/init.d/uhttpd restart 2>/dev/null
	exit 0
}
endef

$(eval $(call BuildPackage,luci-app-devicemaster))
