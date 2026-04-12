#
# Copyright (c) 2024 aime_rick (https://github.com/debugdoctor/luci-app-chinesecalendar)
#
# This is free software, licensed under the MIT License.
#


include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-chinesecalendar
PKG_VERSION:=2.0.1
PKG_BUILD_DIR := $(BUILD_DIR)/$(PKG_NAME)
LUCI_TITLE:=Show Chinese calendar in overview page
LUCI_PKGARCH:=all
PKG_LICENSE:=MIT

include $(INCLUDE_DIR)/package.mk

# include $(TOPDIR)/feeds/luci/luci.mk
# include $(TOPDIR)/feeds/luci/luci.mk

define Package/$(PKG_NAME)
	CATEGORY:=LuCI
	SUBMENU:=Luci
	TITLE:=luci-app-chinesecalendar
	PKGARCH:=all
endef

define Package/$(PKG_NAME)/description
	luci-app-chinesecalendar
endef

define Build/Prepare
	cp -r ${CURDIR}/htdocs $(PKG_BUILD_DIR)
	cp -r ${CURDIR}/root $(PKG_BUILD_DIR)
	cd ${CURDIR}/tools/po2lmo && make && make install
	${CURDIR}/tools/po2lmo/po2lmo ${CURDIR}/po/zh-cn/chinese-calendar.po  $(PKG_BUILD_DIR)/chinesecalendar.zh-cn.lmo
endef

define Build/Compile
endef

define Package/$(PKG_NAME)/install
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/i18n
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/chinesecalendar.*.lmo $(1)/usr/lib/lua/luci/i18n/

	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/status/include/
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/htdocs/luci-static/resources/view/status/include/* $(1)/www/luci-static/resources/view/status/include/

	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d/
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/root/usr/share/rpcd/acl.d/* $(1)/usr/share/rpcd/acl.d/
endef


$(eval $(call BuildPackage,$(PKG_NAME)))