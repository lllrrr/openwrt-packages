#
# Copyright (C) 2026 Arthur97172 <arthur97172@outlook.com>
#
# This is free software, licensed under the GNU General Public License v3.0
# (SPDX: GPL-3.0-only).
#

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-tasks
PKG_VERSION:=1.1.1
PKG_RELEASE:=1

PKG_LICENSE:=GPL-3.0-only
PKG_MAINTAINER:=Arthur97172 <Arthur97172@users.noreply.github.com>

LUCI_TITLE:=Fool-proof scheduled tasks and boot services
LUCI_DESCRIPTION:=Manage scheduled reboot, network and firewall restarts, WiFi on/off, temporary file and memory cleanup, boot commands and internet access control without writing cron syntax.
LUCI_PKGARCH:=all
LUCI_DEPENDS:=+luci-base

define Package/luci-app-tasks/conffiles
/etc/config/tasks
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
