# Copyright 2024 OpenWrt.org
# SPDX-License-Identifier: Apache-2.0-only

include $(TOPDIR)/rules.mk

LUCI_TITLE:=Auto Redial
LUCI_DEPENDS:=+luci-base +luci-compat +iputils-ping +wget-ssl
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

define Build/Compile
endef

define Build/InstallDev
endef

$(eval $(call BuildPackage,luci-app-autoredial))
