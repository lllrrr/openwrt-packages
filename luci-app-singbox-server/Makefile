# SPDX-License-Identifier: GPL-2.0-only
#
# Copyright (C) 2024 OpenWrt.org

include $(TOPDIR)/rules.mk

LUCI_TITLE:=LuCI support for sing-box server
LUCI_PKGARCH:=all


PKG_NAME:=luci-app-singbox-server


define Package/luci-app-singbox-server/conffiles
	/etc/config/singbox-server \
	/etc/singbox-server/certs/
endef


include $(TOPDIR)/feeds/luci/luci.mk
