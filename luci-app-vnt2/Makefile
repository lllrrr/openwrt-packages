#
# Copyright (C) 2008-2014 The LuCI Team <luci@lists.subsignal.org>
#
# This is free software, licensed under the Apache License, Version 2.0 .
#

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-vnt2
PKG_VERSION:=2.0.0
PKG_RELEASE:=1

LUCI_TITLE:=LuCI support for VNT2
LUCI_DEPENDS:=+kmod-tun +luci-compat
LUCI_PKGARCH:=all

define Package/$(PKG_NAME)/description
LuCI web interface for VNT2 client
Provide web-based configuration and management for VNT2.
endef

define Package/$(PKG_NAME)/conffiles
	/etc/vnt2/config.toml
endef

define Package/$(PKG_NAME)/postinst
#!/bin/sh
[ -n "$$IPKG_INSTROOT" ] && exit 0
/etc/init.d/vnt2 enable >/dev/null 2>&1 || true
exit 0
endef

define Package/$(PKG_NAME)/prerm
#!/bin/sh
/etc/init.d/vnt2 stop >/dev/null 2>&1 || true
/etc/init.d/vnt2 disable >/dev/null 2>&1 || true
exit 0
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
$(eval $(call BuildPackage,$(PKG_NAME)))
