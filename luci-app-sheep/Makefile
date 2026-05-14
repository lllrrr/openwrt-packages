# SPDX-License-Identifier: MIT
#
# LuCI app for Sheep (Shadowsocks-Rust Server)
# 遵循 OpenWrt 25.12 规范

include $(TOPDIR)/rules.mk

PKG_NAME       := luci-app-sheep
PKG_VERSION    := 1.0.0
PKG_RELEASE    := 1

LUCI_TITLE     := LuCI app for Sheep
LUCI_DEPENDS   := +luci-base +sheep
LUCI_PKGARCH   := all

PKG_LICENSE    := MIT
PKG_MAINTAINER := Pi <pi@example.com>

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
