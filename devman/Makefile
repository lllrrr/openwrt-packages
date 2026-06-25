include $(TOPDIR)/rules.mk

PKG_NAME:=devman
PKG_VERSION:=0.1.0
PKG_RELEASE:=5

PKG_SOURCE_PROTO:=local
PKG_SOURCE_DIR:=src

include $(INCLUDE_DIR)/package.mk

define Package/devman
	SECTION:=utils
	CATEGORY:=Utilities
	TITLE:=Device Manager Daemon
	DEPENDS:=+tc-tiny +kmod-ifb +kmod-sched-core +kmod-sched-act-police
	URL:=https://github.com/r1172464137/devman
endef

define Package/devman/description
	Real-time device monitoring and control daemon.
	Auto-discovery, DHCP fingerprint, per-device speed,
	block (nftables) and rate limit (tc HTB + IFB).
endef

define Build/Compile
	bash $(PKG_BUILD_DIR)/build.sh $(PKG_BUILD_DIR) $(PKG_BUILD_DIR)
endef

define Package/devman/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/devman $(1)/usr/bin/devman
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/devman.init $(1)/etc/init.d/devman
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_DATA) ./files/devman.config $(1)/etc/config/devman
endef

$(eval $(call BuildPackage,devman))
