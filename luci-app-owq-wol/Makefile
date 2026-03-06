include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-owq-wol
PKG_VERSION:=1.0.1
PKG_RELEASE:=1

PKG_MAINTAINER:=isalikai
PKG_LICENSE:=GPL-3.0-or-later
PKG_LICENSE_FILES:=LICENSE

# 依赖 etherwake
LUCI_TITLE:=OWQ Visual WOL
LUCI_DEPENDS:=+luci-base +etherwake
LUCI_PKGARCH:=all

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
  Visual Wake-on-LAN tool with status monitoring.
endef

define Build/Compile
endef

define Package/$(PKG_NAME)/install
	# 安装 JS
	$(INSTALL_DIR) $(1)/www/luci-static/resources/view
	$(INSTALL_DATA) ./htdocs/luci-static/resources/view/owq-wol.js $(1)/www/luci-static/resources/view/

	# 安装 菜单
	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DATA) ./root/usr/share/luci/menu.d/luci-app-owq-wol.json $(1)/usr/share/luci/menu.d/

	# 安装 ACL (权限文件)
	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./root/usr/share/rpcd/acl.d/luci-app-owq-wol.json $(1)/usr/share/rpcd/acl.d/

	# 安装 默认配置
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./root/etc/config/owq-wol $(1)/etc/config/owq-wol
endef

# --- 关键修复：添加安装后脚本 ---
# 这段脚本会在 opkg install 结束后自动执行
define Package/$(PKG_NAME)/postinst
#!/bin/sh
# 判断是否在真实的路由器系统中运行 (而不是在编译过程中)
if [ -z "$${IPKG_INSTROOT}" ]; then
    # 自动重载 rpcd 服务，使 ACL 权限文件立即生效
    /etc/init.d/rpcd reload
    # 自动重启 uhttpd (网页服务器) 清理缓存
    /etc/init.d/uhttpd reload
fi
exit 0
endef

# 定义中文包
define Package/luci-i18n-owq-wol-zh-cn
  SECTION:=luci
  CATEGORY:=LuCI
  TITLE:=Chinese translations for owq-wol
  DEPENDS:=+luci-app-owq-wol
  PKGARCH:=all
endef

define Package/luci-i18n-owq-wol-zh-cn/install
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/i18n
	po2lmo ./po/zh-cn/owq-wol.po $(1)/usr/lib/lua/luci/i18n/owq-wol.zh-cn.lmo
endef

$(eval $(call BuildPackage,$(PKG_NAME)))
$(eval $(call BuildPackage,luci-i18n-owq-wol-zh-cn))