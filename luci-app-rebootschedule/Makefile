#
# Copyright (C) 2026 Wenjw
#
# This is free software, licensed under the GNU General Public License v2.
#

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-rebootschedule
PKG_VERSION:=1.0.0
PKG_RELEASE:=5
PKG_LICENSE:=GPL-2.0
PKG_MAINTAINER:=Wenjw <wenjw@example.com>

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-rebootschedule
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=LuCI support for scheduled reboot
  # 纯脚本包，故意不写 +luci-base：写了会让 buildroot 去编 luci-base ->
  # lucihttp，而 SDK 的 staging 里缺 lua 头文件，构建直接失败。
  # luci-base 在任何装了 LuCI 的系统上都存在。
  PKGARCH:=all
endef

define Package/luci-app-rebootschedule/description
 Reboot this device automatically on a daily, weekly or uptime-interval
 schedule, configurable from LuCI.
endef

# 纯脚本包：没有任何需要编译的源码
define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
endef

define Build/Configure
endef

define Build/Compile
endef

define Package/luci-app-rebootschedule/install
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_DIR) $(1)/usr/libexec/rebootschedule
	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/rebootschedule

	$(INSTALL_CONF) ./root/etc/config/rebootschedule $(1)/etc/config/rebootschedule
	$(INSTALL_BIN) ./root/etc/init.d/rebootschedule $(1)/etc/init.d/rebootschedule
	$(INSTALL_BIN) ./root/usr/libexec/rebootschedule/daemon $(1)/usr/libexec/rebootschedule/daemon
	$(INSTALL_DATA) ./root/usr/share/luci/menu.d/luci-app-rebootschedule.json $(1)/usr/share/luci/menu.d/
	$(INSTALL_DATA) ./root/usr/share/rpcd/acl.d/luci-app-rebootschedule.json $(1)/usr/share/rpcd/acl.d/
	$(INSTALL_DATA) ./htdocs/luci-static/resources/view/rebootschedule/overview.js \
		$(1)/www/luci-static/resources/view/rebootschedule/overview.js
endef

# 安装后必须清 LuCI 的菜单缓存并 reload rpcd，否则新菜单不会出现；
# luci.mk 会自动生成这段，普通包定义得自己写。
define Package/luci-app-rebootschedule/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	rm -f /tmp/luci-indexcache.*
	rm -rf /tmp/luci-modulecache/
	/etc/init.d/rpcd reload 2>/dev/null
	/etc/init.d/rebootschedule enable 2>/dev/null
	/etc/init.d/rebootschedule start 2>/dev/null
	exit 0
}
endef

define Package/luci-app-rebootschedule/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	/etc/init.d/rebootschedule stop 2>/dev/null
	/etc/init.d/rebootschedule disable 2>/dev/null
	rm -f /tmp/luci-indexcache.*
	rm -rf /tmp/luci-modulecache/
	/etc/init.d/rpcd reload 2>/dev/null
	exit 0
}
endef

$(eval $(call BuildPackage,luci-app-rebootschedule))
