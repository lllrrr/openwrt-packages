include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-socks-clash
PKG_VERSION:=1.2.3
PKG_RELEASE:=1

PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)

include $(INCLUDE_DIR)/package.mk

define Package/$(PKG_NAME)
	SECTION:=luci
	CATEGORY:=LuCI
	SUBMENU:=3. Applications
	TITLE:=LuCI support for SocksClash Proxy
	PKGARCH:=all
	DEPENDS:=+luci-base +bash +curl +ca-bundle
endef

define Package/$(PKG_NAME)/description
SocksClash - A simplified LuCI application for SOCKS5/HTTP proxy.
Features: SOCKS5/HTTP/Mixed proxy, subscription management, rule-based routing.
endef

define Package/$(PKG_NAME)/conffiles
/etc/config/socks-clash
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) ./luasrc $(PKG_BUILD_DIR)/
	$(CP) ./root $(PKG_BUILD_DIR)/
	$(CP) ./po $(PKG_BUILD_DIR)/
	if [ -d "./htdocs" ]; then $(CP) ./htdocs $(PKG_BUILD_DIR)/; fi
endef

define Build/Compile
	# Compile PO to LMO if po2lmo exists
	if [ -d "$(PKG_BUILD_DIR)/po" ]; then \
		for lang in $$(ls $(PKG_BUILD_DIR)/po/); do \
			if [ -d "$(PKG_BUILD_DIR)/po/$$lang" ] && [ "$$lang" != "templates" ]; then \
				for po in $(PKG_BUILD_DIR)/po/$$lang/*.po; do \
					if [ -f "$$po" ]; then \
						lmo=$$(echo $$po | sed 's/\.po$$/.lmo/'); \
						po2lmo $$po $$lmo 2>/dev/null || true; \
					fi; \
				done; \
			fi; \
		done; \
	fi
endef

define Package/$(PKG_NAME)/install
	# Install Lua controller
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/controller
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/luasrc/controller/socks-clash.lua $(1)/usr/lib/lua/luci/controller/
	
	# Install CBI models
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/model/cbi/socks-clash
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/luasrc/model/cbi/socks-clash/*.lua $(1)/usr/lib/lua/luci/model/cbi/socks-clash/
	
	# Install views/templates
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/view/socks-clash
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/luasrc/view/socks-clash/*.htm $(1)/usr/lib/lua/luci/view/socks-clash/
	
	# Install translations (LMO files)
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/i18n
	for lang in $$(ls $(PKG_BUILD_DIR)/po/); do \
		if [ -d "$(PKG_BUILD_DIR)/po/$$lang" ] && [ "$$lang" != "templates" ]; then \
			for lmo in $(PKG_BUILD_DIR)/po/$$lang/*.lmo; do \
				if [ -f "$$lmo" ]; then \
					base=$$(basename $$lmo .lmo); \
					$(INSTALL_DATA) $$lmo $(1)/usr/lib/lua/luci/i18n/$$base.$$lang.lmo; \
				fi; \
			done; \
		fi; \
	done
	
	# Install root files (config, init.d, scripts, etc.)
	$(CP) $(PKG_BUILD_DIR)/root/* $(1)/
	
	# Set permissions
	chmod 755 $(1)/etc/init.d/socks-clash
	chmod 755 $(1)/usr/share/socks-clash/*.sh
	
	# Create directories
	$(INSTALL_DIR) $(1)/etc/socks-clash/config
	$(INSTALL_DIR) $(1)/etc/socks-clash/core
	
	# Install ACL
	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/root/usr/share/rpcd/acl.d/*.json $(1)/usr/share/rpcd/acl.d/ 2>/dev/null || true
	
	# Install static resources (logo, etc.)
	if [ -d "$(PKG_BUILD_DIR)/htdocs" ]; then \
		$(INSTALL_DIR) $(1)/www; \
		$(CP) $(PKG_BUILD_DIR)/htdocs/* $(1)/www/; \
	fi
endef

define Package/$(PKG_NAME)/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
 	rm -rf /tmp/luci-modulecache
 	rm -f /tmp/luci-indexcache
 	/etc/init.d/rpcd restart 2>/dev/null
 	if [ -x "/usr/share/socks-clash/migrate_config.sh" ]; then
 		/usr/share/socks-clash/migrate_config.sh
 	fi
}
exit 0
endef

define Package/$(PKG_NAME)/prerm
#!/bin/sh
uci -q set socks-clash.config.enable=0
uci -q commit socks-clash
/etc/init.d/socks-clash stop 2>/dev/null
exit 0
endef

define Package/$(PKG_NAME)/postrm
#!/bin/sh
rm -rf /etc/socks-clash
rm -rf /tmp/socks-clash*.log
rm -rf /tmp/luci-*
exit 0
endef

$(eval $(call BuildPackage,$(PKG_NAME)))
