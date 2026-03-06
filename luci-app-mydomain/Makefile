include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-mydomain
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

define Package/luci-app-mydomain
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=LuCI Support for MyDomain Manager
  DEPENDS:=+luci-base +haproxy +acme +curl +wget +ca-certificates +openssl-util
  PKGARCH:=all
endef

define Package/luci-app-mydomain/description
  LuCI Support for MyDomain Manager - Dynamic DNS, Reverse Proxy and Certificate Management
endef

define Package/luci-app-mydomain/install
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/controller
	$(INSTALL_DATA) ./luasrc/controller/mydomain.lua $(1)/usr/lib/lua/luci/controller/mydomain.lua
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/view/mydomain
	$(INSTALL_DATA) ./luasrc/view/mydomain/index.htm $(1)/usr/lib/lua/luci/view/mydomain/index.htm
	$(INSTALL_DATA) ./luasrc/view/mydomain/status.htm $(1)/usr/lib/lua/luci/view/mydomain/status.htm
	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/mydomain
	$(INSTALL_DATA) ./htdocs/luci-static/resources/view/mydomain/ddns.js $(1)/www/luci-static/resources/view/mydomain/ddns.js
	$(INSTALL_DATA) ./htdocs/luci-static/resources/view/mydomain/proxy.js $(1)/www/luci-static/resources/view/mydomain/proxy.js
	$(INSTALL_DATA) ./htdocs/luci-static/resources/view/mydomain/cert.js $(1)/www/luci-static/resources/view/mydomain/cert.js
	$(INSTALL_DATA) ./htdocs/luci-static/resources/view/mydomain/status.js $(1)/www/luci-static/resources/view/mydomain/status.js
	$(INSTALL_DATA) ./htdocs/luci-static/resources/view/mydomain.js $(1)/www/luci-static/resources/view/mydomain.js
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_DATA) ./root/etc/config/mydomain $(1)/etc/config/mydomain
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./root/etc/init.d/mydomain $(1)/etc/init.d/mydomain
	$(INSTALL_DIR) $(1)/etc/hotplug.d/iface
	$(INSTALL_DATA) ./root/etc/hotplug.d/iface/99-mydomain $(1)/etc/hotplug.d/iface/99-mydomain
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./root/usr/bin/mydomain-update $(1)/usr/bin/mydomain-update
	$(INSTALL_BIN) ./root/usr/bin/mydomain-cert $(1)/usr/bin/mydomain-cert
	$(INSTALL_BIN) ./root/usr/bin/mydomain-proxy $(1)/usr/bin/mydomain-proxy
	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./root/usr/share/rpcd/acl.d/luci-app-mydomain.json $(1)/usr/share/rpcd/acl.d/luci-app-mydomain.json
endef

include $(TOPDIR)/feeds/luci/luci.mk
