include $(TOPDIR)/rules.mk

LUCI_TITLE:=Simple 2FA (TOTP) for Login
LUCI_DEPENDS:=+oath-toolkit +qrencode +luci-base +luci-compat +ucode +ucode-mod-fs
LUCI_PKGARCH:=all

PKG_VERSION:=1.0.0
PKG_RELEASE:=1

include $(TOPDIR)/feeds/luci/luci.mk

define Package/luci-app-simple2fa/install
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/controller
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/model/cbi/simple2fa
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/view/simple2fa
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_DIR) $(1)/usr/share/luci-app-simple2fa
	
	$(INSTALL_DATA) ./luasrc/controller/simple2fa.lua $(1)/usr/lib/lua/luci/controller/
	$(INSTALL_DATA) ./luasrc/model/cbi/simple2fa/*.lua $(1)/usr/lib/lua/luci/model/cbi/simple2fa/
	$(INSTALL_DATA) ./luasrc/view/simple2fa/*.htm $(1)/usr/lib/lua/luci/view/simple2fa/
	$(INSTALL_DATA) ./root/etc/config/simple2fa $(1)/etc/config/simple2fa
	$(INSTALL_BIN) ./root/etc/init.d/simple2fa $(1)/etc/init.d/
	$(INSTALL_BIN) ./root/etc/uci-defaults/99_simple2fa_setup $(1)/etc/uci-defaults/99_simple2fa
	$(INSTALL_BIN) ./root/usr/share/luci-app-simple2fa/luci $(1)/usr/share/luci-app-simple2fa/luci
	$(INSTALL_DATA) ./root/usr/share/luci-app-simple2fa/sysauth.htm $(1)/usr/share/luci-app-simple2fa/sysauth.htm
	$(INSTALL_DATA) ./root/usr/share/luci-app-simple2fa/sysauth.ut $(1)/usr/share/luci-app-simple2fa/sysauth.ut
	$(INSTALL_DATA) ./root/usr/share/luci-app-simple2fa/sysauth.js $(1)/usr/share/luci-app-simple2fa/sysauth.js

	# Fix CRLF line endings (project developed on Windows)
	find $(1) -type f \( -name "*.lua" -o -name "*.htm" -o -name "*.ut" -o -name "*.js" \) -exec sed -i 's/\r//' {} \;
	sed -i 's/\r//' $(1)/usr/share/luci-app-simple2fa/luci
	sed -i 's/\r//' $(1)/etc/init.d/simple2fa
	sed -i 's/\r//' $(1)/etc/config/simple2fa
endef

define Package/luci-app-simple2fa/prerm
#!/bin/sh
# 恢复所有被替换的文件
for f in /www/cgi-bin/luci /www/luci-static/resources/view/*/sysauth.js /usr/lib/lua/luci/view/themes/*/sysauth.htm /usr/lib/lua/luci/view/sysauth.htm; do
	if [ -f "$${f}.bak" ]; then
		mv -f "$${f}.bak" "$$f"
	fi
done
exit 0
endef

$(eval $(call BuildPackage,luci-app-simple2fa))
