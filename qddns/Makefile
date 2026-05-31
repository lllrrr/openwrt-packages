# SPDX-License-Identifier: GPL-2.0-only

include $(TOPDIR)/rules.mk

PKG_NAME:=qddns
PKG_VERSION:=0.2.0
PKG_RELEASE:=1

PKG_LICENSE:=GPL-2.0-only
PKG_MAINTAINER:=OpenAI

PKG_BUILD_DEPENDS:=rust/host
PKG_BUILD_PARALLEL:=1

include $(INCLUDE_DIR)/package.mk
include $(TOPDIR)/feeds/packages/lang/rust/rust-package.mk

define Package/qddns
  SECTION:=net
  CATEGORY:=Network
  TITLE:=General-purpose DDNS platform with DUID-aware IPv6 sources
  DEPENDS:=$(RUST_ARCH_DEPENDS) +procd +ip-full +ucode +ucode-mod-fs +ucode-mod-uci
  URL:=https://example.invalid/qddns
endef

define Package/qddns/description
  qddns is a general-purpose DDNS engine for OpenWrt/ImmortalWrt.
  It supports multiple source types including DHCPv6 DUID/IAID IPv6 lookup.
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) $(CURDIR)/../../qddns/* $(PKG_BUILD_DIR)/
endef

define Package/qddns/conffiles
/etc/config/qddns
endef

define Package/qddns/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_INSTALL_DIR)/bin/qddnsctl $(1)/usr/bin/qddnsctl
	$(INSTALL_BIN) $(PKG_INSTALL_DIR)/bin/qddnsd $(1)/usr/bin/qddnsd

	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/qddns.init $(1)/etc/init.d/qddns

	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/qddns.config $(1)/etc/config/qddns

	$(INSTALL_DIR) $(1)/usr/share/qddns
	$(INSTALL_DATA) ./files/state.example.json $(1)/usr/share/qddns/state.example.json
endef

$(eval $(call RustBinPackage,qddns))
$(eval $(call BuildPackage,qddns))
