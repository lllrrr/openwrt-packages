include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-easy-mwan3
PKG_VERSION:=2.1.1
PKG_RELEASE:=1

PKG_MAINTAINER:=PengCong226
PKG_LICENSE:=MIT

LUCI_TITLE:=Easy MWAN3 Configurator
LUCI_DESCRIPTION:=A simplified, intelligent interface for configuring MWAN3 Load Balancing with Hybrid Strategy support.
LUCI_DEPENDS:=+luci-base +mwan3 +ip-full
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

define Package/luci-app-easy-mwan3/install
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/controller
	$(INSTALL_DATA) ./luasrc/controller/easy_mwan3.lua $(1)/usr/lib/lua/luci/controller/easy_mwan3.lua
	
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/model/cbi
	$(INSTALL_DATA) ./luasrc/model/cbi/easy_mwan3.lua $(1)/usr/lib/lua/luci/model/cbi/easy_mwan3.lua
	
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/view/easy_mwan3
	$(INSTALL_DATA) ./luasrc/view/easy_mwan3/status.htm $(1)/usr/lib/lua/luci/view/easy_mwan3/status.htm
	$(INSTALL_DATA) ./luasrc/view/easy_mwan3/incompatible.htm $(1)/usr/lib/lua/luci/view/easy_mwan3/incompatible.htm
	
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_DATA) ./root/etc/config/easy_mwan3 $(1)/etc/config/easy_mwan3
	
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./root/etc/init.d/easy_mwan3 $(1)/etc/init.d/easy_mwan3
	
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./root/etc/uci-defaults/99_easy_mwan3 $(1)/etc/uci-defaults/99_easy_mwan3
	
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./usr/bin/easy_mwan3_apply.sh $(1)/usr/bin/easy_mwan3_apply.sh
	$(INSTALL_BIN) ./usr/bin/easy_mwan3_status.sh $(1)/usr/bin/easy_mwan3_status.sh
	$(INSTALL_BIN) ./usr/bin/easy_mwan3_validate.sh $(1)/usr/bin/easy_mwan3_validate.sh
	$(INSTALL_BIN) ./usr/bin/easy_mwan3_policy.sh $(1)/usr/bin/easy_mwan3_policy.sh
	$(INSTALL_BIN) ./usr/bin/easy_mwan3_test.sh $(1)/usr/bin/easy_mwan3_test.sh
endef

$(eval $(call BuildPackage,luci-app-easy-mwan3))
