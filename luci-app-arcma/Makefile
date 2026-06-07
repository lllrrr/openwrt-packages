# SPDX-License-Identifier: MIT
# Copyright (C) 2026 arcma contributors

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-arcma
PKG_VERSION:=1.0.3
PKG_RELEASE:=2

LUCI_NAME:=luci-app-arcma
LUCI_TYPE:=app
LUCI_BASENAME:=arcma
LUCI_TITLE:=LuCI for ARCMA
LUCI_DESCRIPTION:=Automatically change MAC addresses of all network interfaces. BusyBox ash compatible with embedded OUI vendor database.
LUCI_DEPENDS:=+ip-full
LUCI_PKGARCH:=all

PKG_MAINTAINER:=arcma contributors
PKG_LICENSE:=MIT

define Package/$(PKG_NAME)/conffiles
/etc/config/arcma
/etc/arcma/orig/
endef

define Package/$(PKG_NAME)/postinst
#!/bin/sh
[ -n "$$IPKG_INSTROOT" ] && exit 0
chmod +x /usr/sbin/arcma
chmod +x /etc/init.d/arcma
chmod +x /etc/hotplug.d/iface/20-arcma
/etc/init.d/arcma enable
exit 0
endef

define Package/$(PKG_NAME)/prerm
#!/bin/sh
[ -n "$$IPKG_INSTROOT" ] && exit 0
/usr/sbin/arcma uci-restore 2>/dev/null
/etc/init.d/arcma stop 2>/dev/null
/etc/init.d/arcma disable 2>/dev/null
exit 0
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
