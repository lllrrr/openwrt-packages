include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-httping
PKG_VERSION:=1.1.14
PKG_RELEASE:=1

PKG_MAINTAINER:=No Name
PKG_LICENSE:=MIT

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-httping
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=LuCI support for Network Latency Monitor (HTTPing)
  PKGARCH:=all
  DEPENDS:=+luci-base +luci-lib-jsonc +curl +sqlite3-cli
endef

define Package/luci-app-httping/description
  A LuCI plugin to monitor network latency using HTTP requests.
endef

# 【新增】这里告诉 opkg，这个文件是配置文件，升级时不要覆盖！
define Package/luci-app-httping/conffiles
/etc/config/httping
endef

define Build/Compile
endef

define Package/luci-app-httping/install
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/controller
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/model/cbi/httping
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/view/httping
	$(INSTALL_DIR) $(1)/www/luci-static/resources/httping

	$(INSTALL_CONF) ./root/etc/config/httping $(1)/etc/config/httping
	$(INSTALL_BIN) ./root/etc/init.d/httping $(1)/etc/init.d/httping
	$(INSTALL_BIN) ./root/usr/bin/httping-daemon.lua $(1)/usr/bin/httping-daemon.lua
	
	$(INSTALL_DATA) ./root/usr/lib/lua/luci/controller/httping.lua $(1)/usr/lib/lua/luci/controller/httping.lua
	$(INSTALL_DATA) ./root/usr/lib/lua/luci/model/cbi/httping/setting.lua $(1)/usr/lib/lua/luci/model/cbi/httping/setting.lua
	$(INSTALL_DATA) ./root/usr/lib/lua/luci/view/httping/graph.htm $(1)/usr/lib/lua/luci/view/httping/graph.htm
	$(INSTALL_DATA) ./root/www/luci-static/resources/httping/echarts.min.js $(1)/www/luci-static/resources/httping/echarts.min.js
endef

define Package/luci-app-httping/postinst
#!/bin/sh
if [ -z "$${IPKG_INSTROOT}" ]; then
    chmod +x /usr/bin/httping-daemon.lua
    chmod +x /etc/init.d/httping
    /etc/init.d/httping enable
    /etc/init.d/httping start
    rm -rf /tmp/luci-modulecache/
    rm -f /tmp/luci-indexcache
fi
exit 0
endef

define Package/luci-app-httping/prerm
#!/bin/sh
if [ -z "$${IPKG_INSTROOT}" ]; then
    /etc/init.d/httping stop
    /etc/init.d/httping disable
fi
exit 0
endef

$(eval $(call BuildPackage,luci-app-httping))