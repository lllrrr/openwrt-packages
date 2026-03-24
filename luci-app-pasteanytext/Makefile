#
# Copyright (C) 2024 OpenWrt.org
#
# This is free software, licensed under the Apache License, Version 2.0 .
#

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-pasteanytext
PKG_VERSION:=1.1
PKG_RELEASE:=4

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-pasteanytext
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=LuCI support for PasteAnyText
  PKGARCH:=all
  DEPENDS:=+luci-base
endef

define Package/luci-app-pasteanytext/description
  A simple LuCI application that allows you to store and retrieve text snippets temporarily.
  Send text from one device and receive it on another device via temporary file storage.
endef

define Build/Compile
endef

define Package/luci-app-pasteanytext/install
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/etc/config/pasteanytext $(1)/etc/config/
	
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/pasteanytext $(1)/etc/init.d/
	
	# Install LuCI Lua files
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/controller
	$(INSTALL_DATA) ./luasrc/controller/pasteanytext.lua $(1)/usr/lib/lua/luci/controller/
	
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/view/pasteanytext
	$(INSTALL_DATA) ./luasrc/view/pasteanytext/index.htm $(1)/usr/lib/lua/luci/view/pasteanytext/
endef

$(eval $(call BuildPackage,luci-app-pasteanytext))
