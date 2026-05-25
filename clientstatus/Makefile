#
# This is free software, licensed under the MIT.
# See /LICENSE for more information.
# Copyright (C) 2026 Mige99 
#


include $(TOPDIR)/rules.mk

PKG_NAME:=clientstatus
PKG_VERSION:=1.0.8
PKG_RELEASE:=1

PKG_MAINTAINER:=Mige99
PKG_LICENSE:=MIT
PKG_LICENSE_FILES:=LICENSE

include $(INCLUDE_DIR)/package.mk

define Package/clientstatus
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=Client Status Monitor Daemon
  DEPENDS:=
endef

define Package/clientstatus/description
  A lightweight daemon that monitors LAN client online/offline status
  by combining ARP table, ip neigh, and DHCP lease data with ICMP probes.
endef

define Build/Compile
	$(TARGET_CC) $(TARGET_CFLAGS) $(EXTRA_CFLAGS) \
		$(TARGET_LDFLAGS) $(EXTRA_LDFLAGS) \
		-o $(PKG_BUILD_DIR)/clientstatus \
		$(PKG_BUILD_DIR)/clientstatus.c
endef

define Package/clientstatus/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/clientstatus $(1)/usr/bin/clientstatus

	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/clientstatus.init $(1)/etc/init.d/clientstatus
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/clientstatus.conf $(1)/etc/config/clientstatus
endef

$(eval $(call BuildPackage,clientstatus))
