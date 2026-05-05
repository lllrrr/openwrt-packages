# SPDX-License-Identifier: Apache-2.0
#
# LuCI app for Kiwi DNS
# 遵循 OpenWrt 25.12 规范

include $(TOPDIR)/rules.mk

PKG_NAME       := luci-app-kiwi
PKG_VERSION    := 0.1.0
PKG_RELEASE    := 1

LUCI_TITLE     := Kiwi — 高性能 DNS 转发器
LUCI_DEPENDS   := +kiwi
LUCI_PKGARCH   := all
LUCI_SECTION   := luci
LUCI_CATEGORY  := 3. Applications

PKG_LICENSE    := Apache-2.0
PKG_MAINTAINER := Pi <pi@example.com>

include $(TOPDIR)/feeds/luci/luci.mk

$(eval $(call BuildPackage,luci-app-kiwi))
