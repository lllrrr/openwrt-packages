# 

#
# This is free software, licensed under the GNU General Public License v2.
# See /LICENSE for more information.
#

include $(TOPDIR)/rules.mk

PKG_NAME:=clientstatus
PKG_VERSION:=1.0.8
PKG_RELEASE:=1

include $(INCLUDE_DIR)/package.mk

define Package/clientstatus
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=LAN Client Status Monitor
  DEPENDS:
endef

define Package/clientstatus/description
  A lightweight daemon that monitors LAN client online/offline status
  by combining ARP table, ip neigh, and DHCP lease data with ICMP probes.
endef

define Build/Compile
endef

define Package/clientstatus/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./files/clientstatus.sh $(1)/usr/bin/clientstatus.sh

	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/clientstatus.init $(1)/etc/init.d/clientstatus

	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/clientstatus.conf $(1)/etc/config/clientstatus
endef

define Package/clientstatus/conffiles
/etc/config/clientstatus
endef

$(eval $(call BuildPackage,clientstatus))
