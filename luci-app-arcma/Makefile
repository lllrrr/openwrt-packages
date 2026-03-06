# SPDX-License-Identifier: MIT
# Copyright (C) 2026 arcma contributors

include $(TOPDIR)/rules.mk

LUCI_NAME:=luci-app-arcma
PKG_VERSION:=1.0.0

LUCI_TITLE:=LuCI for ARCMA
LUCI_DESCRIPTION:=Automatically change MAC addresses of all network interfaces. \
	Zero external dependencies — pure POSIX sh with embedded OUI vendor database.

PKG_MAINTAINER:=arcma contributors
PKG_LICENSE:=MIT

# Only hard dependency is ip-tiny (provides `ip link`) which is part of
# OpenWrt base since 21.02. On very minimal images ifconfig (busybox) is
# the automatic fallback inside arcma.
LUCI_DEPENDS:=+ip-tiny

define Package/$(LUCI_NAME)/conffiles
/etc/config/arcma
endef

define Package/$(LUCI_NAME)/postinst
#!/bin/sh
[ -n "$$IPKG_INSTROOT" ] && exit 0
chmod +x /usr/sbin/arcma
chmod +x /etc/init.d/arcma
chmod +x /etc/hotplug.d/iface/20-arcma
/etc/init.d/arcma enable
exit 0
endef

define Package/$(LUCI_NAME)/prerm
#!/bin/sh
[ -n "$$IPKG_INSTROOT" ] && exit 0
/etc/init.d/arcma stop 2>/dev/null
/etc/init.d/arcma disable 2>/dev/null
exit 0
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
