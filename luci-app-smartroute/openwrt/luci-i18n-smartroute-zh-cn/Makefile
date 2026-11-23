# 智能分流界面的简体中文翻译。lmo 由 scripts/build-packages.sh 从 luci/po/zh_Hans/smartroute.po 生成（scripts/i18n.py lmo）
include $(TOPDIR)/rules.mk

PKG_NAME:=luci-i18n-smartroute-zh-cn
PKG_VERSION:=$(or $(SR_VERSION),0.0.0)
PKG_RELEASE:=1
PKG_LICENSE:=Apache-2.0

include $(INCLUDE_DIR)/package.mk

define Package/luci-i18n-smartroute-zh-cn
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=luci-app-smartroute - 简体中文 (Chinese Simplified)
  DEPENDS:=+luci-app-smartroute
  EXTRA_DEPENDS:=luci-app-smartroute (=$(PKG_VERSION)-r$(PKG_RELEASE))
  PKGARCH:=all
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
endef

define Build/Compile
endef

define Package/luci-i18n-smartroute-zh-cn/install
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/i18n
	$(INSTALL_DATA) ./files/smartroute.zh-cn.lmo $(1)/usr/lib/lua/luci/i18n/
endef

$(eval $(call BuildPackage,luci-i18n-smartroute-zh-cn))
