# SPDX-License-Identifier: MIT
#
# Copyright (C) 2021-2026 LIKE2000-ART
#
# This is free software, licensed under the MIT License.
#
include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-picoclaw
PKG_VERSION:=1.0.0
PKG_RELEASE:=20260226

PKG_MAINTAINER:=LIKE2000-ART
PKG_CONFIG_DEPENDS:=

LUCI_TITLE:=LuCI Support for PicoClaw AI Assistant
LUCI_DEPENDS:=+picoclaw
LUCI_PKGARCH:=all



include $(TOPDIR)/feeds/luci/luci.mk

define Package/luci-app-picoclaw/prerm
#!/bin/sh
# Override default luci.mk prerm script to prevent "ubus call service delete" error.
# The core picoclaw package handles its own service shutdown.
exit 0
endef

define Package/luci-app-picoclaw/postrm
#!/bin/sh
# Override default luci.mk postrm script to prevent errors during cleanup.
exit 0
endef

# call BuildPackage - OpenWrt buildroot signature

