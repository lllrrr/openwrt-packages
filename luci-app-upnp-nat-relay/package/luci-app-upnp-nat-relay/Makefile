include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-upnp-nat-relay
PKG_VERSION:=1.3.10
PKG_RELEASE:=1

PKG_MAINTAINER:=yunshu
PKG_LICENSE:=GPL-3.0

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-upnp-nat-relay
  SECTION:=luci
  CATEGORY:=LuCI
  TITLE:=UPnP NAT Relay - Relay downstream UPnP mappings through upstream NAT
  DEPENDS:=+luci-base +miniupnpc +nftables +coreutils-timeout +flock
  CONFLICTS:=luci-app-upnp-bridge-relay
  PKGARCH:=all
endef

define Package/luci-app-upnp-nat-relay/description
OpenWrt plugin for relaying downstream router UPnP mappings through
upstream NAT, with nftables DNAT and OpenClash RETURN support.
Includes LuCI web interface with Chinese and English translations.
endef

define Package/luci-app-upnp-nat-relay/conffiles
/etc/config/upnp_nat_relay
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) ./root ./htdocs $(PKG_BUILD_DIR)/
endef

define Build/Compile
	mkdir -p $(PKG_BUILD_DIR)/lmo; \
	for po_dir in $(CURDIR)/po/*/; do \
		[ -d "$$$$po_dir" ] || continue; \
		lang=$$$$(basename "$$$$po_dir"); \
		[ "$$$$lang" = "templates" ] && continue; \
		[ -f "$$$$po_dir/upnp-nat-relay.po" ] || continue; \
		lmo_lang="$$$$lang"; \
		[ "$$$$lmo_lang" = "zh_Hans" ] && lmo_lang="zh-cn"; \
		if [ -x "$(STAGING_DIR_HOSTPKG)/bin/po2lmo" ]; then \
			"$(STAGING_DIR_HOSTPKG)/bin/po2lmo" "$$$$po_dir/upnp-nat-relay.po" "$(PKG_BUILD_DIR)/lmo/upnp-nat-relay.$$$$lmo_lang.lmo"; \
		fi; \
	done; \
	sed -i 's/@PKG_VERSION@/$(PKG_VERSION)/g' $(PKG_BUILD_DIR)/root/usr/bin/upnp-nat-relay
	sed -i 's/@PKG_VERSION@/$(PKG_VERSION)/g' $(PKG_BUILD_DIR)/root/usr/libexec/rpcd/upnp_nat_relay
	sed -i 's/@PKG_VERSION@/$(PKG_VERSION)/g' $(PKG_BUILD_DIR)/htdocs/luci-static/resources/upnp-nat-relay/utils.js
endef

define Package/luci-app-upnp-nat-relay/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/root/usr/bin/upnp-nat-relay $(1)/usr/bin/
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) $(PKG_BUILD_DIR)/root/etc/config/upnp_nat_relay $(1)/etc/config/
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/root/etc/init.d/upnp_nat_relay $(1)/etc/init.d/
	$(INSTALL_DIR) $(1)/etc/upnp_nat_relay
	$(INSTALL_DIR) $(1)/usr/libexec/rpcd
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/root/usr/libexec/rpcd/upnp_nat_relay $(1)/usr/libexec/rpcd/
	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/upnp-nat-relay
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/htdocs/luci-static/resources/view/upnp-nat-relay/*.js $(1)/www/luci-static/resources/view/upnp-nat-relay/
	$(INSTALL_DIR) $(1)/www/luci-static/resources/upnp-nat-relay
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/htdocs/luci-static/resources/upnp-nat-relay/*.js $(PKG_BUILD_DIR)/htdocs/luci-static/resources/upnp-nat-relay/*.css $(1)/www/luci-static/resources/upnp-nat-relay/
	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/root/usr/share/luci/menu.d/luci-app-upnp-nat-relay.json $(1)/usr/share/luci/menu.d/
	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/root/usr/share/rpcd/acl.d/luci-app-upnp-nat-relay.json $(1)/usr/share/rpcd/acl.d/
	if [ -n "$$$$(ls $(PKG_BUILD_DIR)/lmo/*.lmo 2>/dev/null)" ]; then \
		$(INSTALL_DIR) $(1)/usr/lib/lua/luci/i18n; \
		$(INSTALL_DATA) $(PKG_BUILD_DIR)/lmo/*.lmo $(1)/usr/lib/lua/luci/i18n/; \
	fi
endef

define Package/luci-app-upnp-nat-relay/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || { \
	if [ -f /etc/config/upnp_bridge_relay ]; then \
		cp -p /etc/config/upnp_bridge_relay /etc/config/upnp_nat_relay 2>/dev/null || true; \
	fi; \
	[ -x /etc/init.d/upnp_bridge_relay ] && /etc/init.d/upnp_bridge_relay stop 2>/dev/null; \
	[ -x /etc/init.d/upnp_bridge_relay ] && /etc/init.d/upnp_bridge_relay disable 2>/dev/null; \
	[ -x /etc/init.d/upnp_nat_relay ] && /etc/init.d/upnp_nat_relay enable 2>/dev/null; \
	uci -q get luci.languages.zh_cn >/dev/null || uci -q set luci.languages.zh_cn='简体中文'; \
	uci -q commit luci; \
	rm -f /tmp/luci-indexcache.*; \
	rm -rf /tmp/luci-modulecache/; \
	/etc/init.d/rpcd reload 2>/dev/null; \
	exit 0; \
}
endef

define Package/luci-app-upnp-nat-relay/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || { \
	/etc/init.d/upnp_nat_relay stop 2>/dev/null; \
	/etc/init.d/upnp_nat_relay disable 2>/dev/null; \
	rm -f /tmp/luci-indexcache.*; \
	rm -rf /tmp/luci-modulecache/; \
	exit 0; \
}
endef

$(eval $(call BuildPackage,luci-app-upnp-nat-relay))
