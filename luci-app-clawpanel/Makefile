# luci-app-clawpanel — ClawPanel LuCI 管理插件
# 兼容两种集成方式:
#   1. 作为 feeds 源: echo "src-git clawpanel ..." >> feeds.conf.default
#   2. 直接放入 package/ 目录: git clone ... package/luci-app-clawpanel

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-clawpanel
PKG_VERSION:=1.2.0
PKG_RELEASE:=2

PKG_MAINTAINER:=a10463981 <a10463981@users.noreply.github.com>
PKG_LICENSE:=CC-BY-NC-SA-4.0

LUCI_TITLE:=ClawPanel AI 管理面板 LuCI 插件
LUCI_DEPENDS:=+luci-compat +luci-base +curl +openssl-util +tar +libstdcpp6
LUCI_PKGARCH:=$(PKG_ARCH)

# 优先使用 luci.mk (feeds 模式), 不可用时回退 package.mk
ifeq ($(wildcard $(TOPDIR)/feeds/luci/luci.mk),)
  include $(INCLUDE_DIR)/package.mk

  define Package/$(PKG_NAME)
    SECTION:=luci
    CATEGORY:=LuCI
    SUBMENU:=3. Applications
    TITLE:=$(LUCI_TITLE)
    DEPENDS:=$(LUCI_DEPENDS)
    PKGARCH:=all
  endef

  define Package/$(PKG_NAME)/description
    ClawPanel AI 管理面板的 LuCI 管理插件。
    支持 OpenClaw 进程管理、通道配置、插件管理、仪表盘等功能。
  endef
else
  include $(TOPDIR)/feeds/luci/luci.mk
endif

define Package/$(PKG_NAME)/conffiles
/etc/config/clawpanel
endef

define Package/$(PKG_NAME)/install
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./root/etc/config/clawpanel $(1)/etc/config/clawpanel
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./root/etc/uci-defaults/99-clawpanel $(1)/etc/uci-defaults/99-clawpanel
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./root/etc/init.d/clawpanel $(1)/etc/init.d/clawpanel
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./root/usr/bin/clawpanel-env $(1)/usr/bin/clawpanel-env
	chmod 755 $(1)/usr/bin/clawpanel-env
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/controller
	$(INSTALL_DATA) ./luasrc/controller/clawpanel.lua $(1)/usr/lib/lua/luci/controller/clawpanel.lua
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/model/cbi/clawpanel
	$(INSTALL_DATA) ./luasrc/model/cbi/clawpanel/basic.lua $(1)/usr/lib/lua/luci/model/cbi/clawpanel/basic.lua
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/view/clawpanel
	$(INSTALL_DATA) ./luasrc/view/clawpanel/basic.htm $(1)/usr/lib/lua/luci/view/clawpanel/basic.htm
	$(INSTALL_DATA) ./luasrc/view/clawpanel/main.htm $(1)/usr/lib/lua/luci/view/clawpanel/main.htm
	$(INSTALL_DIR) $(1)/usr/share/clawpanel
	$(INSTALL_DATA) ./VERSION $(1)/usr/share/clawpanel/VERSION
endef

define Package/$(PKG_NAME)/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	[ -f /etc/uci-defaults/99-clawpanel ] && {
		( . /etc/uci-defaults/99-clawpanel ) && rm -f /etc/uci-defaults/99-clawpanel
	}
	rm -f /tmp/luci-indexcache /tmp/luci-modulecache/* 2>/dev/null
	exit 0
}
endef

define Package/$(PKG_NAME)/postrm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	rm -f /tmp/luci-indexcache /tmp/luci-modulecache/* 2>/dev/null
}
endef

$(eval $(call BuildPackage,$(PKG_NAME)))
