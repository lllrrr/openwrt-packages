include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-nvr
PKG_VERSION:=20260122
PKG_RELEASE:=1

LUCI_TITLE:=LuCI Support for Network Video Recorder
LUCI_DESCRIPTION:=A LuCI application for network video recording using IP cameras.
LUCI_DEPENDS:=+luci-base +lsblk +coreutils-stat +luci-compat
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

define Package/luci-app-nvr/conffiles
/etc/config/nvr
endef

define Package/luci-app-nvr/install
	# 1. 安装 LuCI 核心文件 (MVC)
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/controller
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/model/cbi
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/view
	$(INSTALL_DATA) ./luasrc/controller/nvr.lua $(1)/usr/lib/lua/luci/controller/
	$(INSTALL_DATA) ./luasrc/model/cbi/nvr.lua $(1)/usr/lib/lua/luci/model/cbi/
	$(INSTALL_DATA) ./luasrc/view/nvr_status.htm $(1)/usr/lib/lua/luci/view/

	# 2. 安装系统运行文件 (从项目根部的 nvr 文件夹拷贝)
	$(INSTALL_DIR) $(1)/usr/nvr
	$(CP) ./nvr/* $(1)/usr/nvr/

	# 3. 安装配置文件
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./nvr.conf $(1)/etc/config/nvr

	# 4. 安装启动脚本
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./nvr.init $(1)/etc/init.d/nvr
endef

$(eval $(call BuildPackage,luci-app-nvr))
