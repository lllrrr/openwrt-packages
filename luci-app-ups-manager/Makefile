#
# Copyright (C) 2026 Gilbert Liu & Contributors
#
# This is free software, licensed under the GNU General Public License v2.
#

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-ups-manager
PKG_VERSION:=1.0.0
PKG_RELEASE:=2
PKG_LICENSE:=GPL-2.0-or-later
PKG_MAINTAINER:=Gilbert Liu & Contributors

LUCI_TITLE:=LuCI support for UPS Manager
LUCI_DESCRIPTION:=Enterprise UPS Power Management System for OpenWrt / iStoreOS with auto-discovery, telemetry, outage alerts and shutdown protection.
LUCI_DEPENDS:=+luci-base +rpcd +rpcd-mod-file +nut +nut-common +nut-server +nut-upsmon +nut-upsc +nut-driver-usbhid-ups +curl
LUCI_PKGARCH:=all

define Package/$(PKG_NAME)/conffiles
/etc/config/ups_manager
endef

define Package/$(PKG_NAME)/postinst
#!/bin/sh
if [ -z "$${IPKG_INSTROOT}" ]; then
	chmod 755 /etc/init.d/ups-manager 2>/dev/null || true
	chmod 755 /etc/uci-defaults/80_ups_manager 2>/dev/null || true
	chmod 755 /usr/bin/ups-manager-* 2>/dev/null || true
	chmod 755 /usr/libexec/rpcd/luci.ups-manager 2>/dev/null || true
	/etc/uci-defaults/80_ups_manager 2>/dev/null || true
	/etc/init.d/ups-manager enable
	/etc/init.d/ups-manager restart 2>/dev/null || true
	/etc/init.d/rpcd reload 2>/dev/null || true
	rm -rf /tmp/luci-indexcache /tmp/luci-modulecache/
fi
exit 0
endef

define Package/$(PKG_NAME)/prerm
#!/bin/sh
if [ -z "$${IPKG_INSTROOT}" ]; then
	/etc/init.d/ups-manager stop 2>/dev/null || true
	/etc/init.d/ups-manager disable 2>/dev/null || true
fi
exit 0
endef

define Package/$(PKG_NAME)/postrm
#!/bin/sh
if [ -z "$${IPKG_INSTROOT}" ]; then
	rm -rf /tmp/run/ups-manager* /tmp/log/ups-manager*
	/etc/init.d/rpcd reload 2>/dev/null || true
	rm -rf /tmp/luci-indexcache /tmp/luci-modulecache/
fi
exit 0
endef

include $(TOPDIR)/feeds/luci/luci.mk

# Support standalone build when feeds/luci/luci.mk is not directly present in out-of-tree env
$(eval $(call BuildPackage,$(PKG_NAME)))
