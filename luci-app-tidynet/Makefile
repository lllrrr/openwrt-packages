include $(TOPDIR)/rules.mk

LUCI_TITLE:=TidyNet - Mihomo, DNS and Ad Blocking Manager
LUCI_DEPENDS:=+luci-base +rpcd +libubox +libubus +ubus +jsonfilter +curl +ca-bundle +gzip +coreutils-sha256sum +yq +kmod-tun +ip-full +firewall4
LUCI_PKGARCH:=all
PKG_LICENSE:=GPL-3.0-or-later
PKG_VERSION:=0.4.0
PKG_RELEASE:=37

define Package/luci-app-tidynet/conffiles
/etc/config/tidynet
endef

define Package/luci-app-tidynet/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	if [ -x /etc/uci-defaults/90-tidynet ]; then
		/etc/uci-defaults/90-tidynet && rm -f /etc/uci-defaults/90-tidynet
	fi
	[ -x /etc/init.d/rpcd ] && /etc/init.d/rpcd reload >/dev/null 2>&1 || :
	if [ -x /etc/init.d/tidynet ] && /etc/init.d/tidynet enabled; then /etc/init.d/tidynet restart >/dev/null 2>&1 || :; fi
}
exit 0
endef

define Package/luci-app-tidynet/prerm
#!/bin/sh
if [ "$${IPKG_INSTROOT}" = "" ] && [ "$$1" = remove ]; then
	cron_tmp=$$(mktemp /tmp/tidynet-cron-remove.XXXXXX)
	if [ -n "$$cron_tmp" ]; then
		if crontab -l > "$$cron_tmp" 2>/dev/null; then
			sed -i '/# tidynet-rule-update$$/d' "$$cron_tmp"
			sed -i '/# tidynet-subscription-[A-Za-z0-9_]*$$/d' "$$cron_tmp"
			crontab "$$cron_tmp"
		fi
		rm -f "$$cron_tmp"
	fi
	/etc/init.d/tidynet stop >/dev/null 2>&1 || :
	/etc/init.d/tidynet disable >/dev/null 2>&1 || :
	/etc/init.d/tidynet-stats stop >/dev/null 2>&1 || :
	/etc/init.d/tidynet-stats disable >/dev/null 2>&1 || :
	if [ -z "$$(uci -q changes dhcp 2>/dev/null)" ]; then
		uci -q del_list 'dhcp.@dnsmasq[0].addnhosts=/etc/tidynet/rules/blocked.hosts'
		hash=$$(printf '\043')
		uci -q del_list "dhcp.@dnsmasq[0].server=/$${hash}/127.0.0.1$${hash}10535"
		if [ -f /etc/tidynet/state/logqueries-managed ] && [ "$$(uci -q get 'dhcp.@dnsmasq[0].logqueries')" = 1 ]; then
			old=$$(cat /etc/tidynet/state/logqueries-original 2>/dev/null)
			if [ -n "$$old" ]; then uci -q set "dhcp.@dnsmasq[0].logqueries=$$old"; else uci -q delete 'dhcp.@dnsmasq[0].logqueries'; fi
		fi
		if [ -f /etc/tidynet/state/dns-noresolv-managed ] && [ "$$(uci -q get 'dhcp.@dnsmasq[0].noresolv')" = 1 ]; then
			old=$$(cat /etc/tidynet/state/dns-noresolv-original 2>/dev/null)
			if [ -n "$$old" ]; then uci -q set "dhcp.@dnsmasq[0].noresolv=$$old"; else uci -q delete 'dhcp.@dnsmasq[0].noresolv'; fi
		fi
		uci -q commit dhcp
		[ -x /etc/init.d/dnsmasq ] && /etc/init.d/dnsmasq restart >/dev/null 2>&1 || :
	else
		logger -t tidynet 'Skipped dnsmasq cleanup during package removal because DHCP settings have pending edits.'
	fi
fi
exit 0
endef

define Package/luci-app-tidynet/install
	$(INSTALL_DIR) $(1)/usr/lib/tidynet
	$(INSTALL_DATA) ./root/usr/lib/tidynet/core.sh $(1)/usr/lib/tidynet/core.sh
	$(INSTALL_DATA) ./root/usr/lib/tidynet/traffic.sh $(1)/usr/lib/tidynet/traffic.sh
	$(INSTALL_DIR) $(1)/usr/libexec/rpcd
	$(INSTALL_BIN) ./root/usr/libexec/rpcd/tidynet $(1)/usr/libexec/rpcd/tidynet
	$(INSTALL_BIN) ./root/usr/libexec/tidynet-job $(1)/usr/libexec/tidynet-job
	$(INSTALL_BIN) ./root/usr/libexec/tidynet-stats $(1)/usr/libexec/tidynet-stats
	$(INSTALL_BIN) ./root/usr/libexec/tidynet-rule-update $(1)/usr/libexec/tidynet-rule-update
	$(INSTALL_BIN) ./root/usr/libexec/tidynet-subscription-update $(1)/usr/libexec/tidynet-subscription-update
	$(INSTALL_BIN) ./root/usr/libexec/tidynet-core-check $(1)/usr/libexec/tidynet-core-check
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./root/etc/init.d/tidynet $(1)/etc/init.d/tidynet
	$(INSTALL_BIN) ./root/etc/init.d/tidynet-stats $(1)/etc/init.d/tidynet-stats
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./root/etc/config/tidynet $(1)/etc/config/tidynet
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./root/etc/uci-defaults/90-tidynet $(1)/etc/uci-defaults/90-tidynet
	$(INSTALL_DIR) $(1)/usr/share/tidynet
	$(INSTALL_DATA) ./root/etc/tidynet/config.yaml $(1)/usr/share/tidynet/default.yaml
	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DATA) ./root/usr/share/luci/menu.d/luci-app-tidynet.json $(1)/usr/share/luci/menu.d/luci-app-tidynet.json
	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./root/usr/share/rpcd/acl.d/luci-app-tidynet.json $(1)/usr/share/rpcd/acl.d/luci-app-tidynet.json
	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/tidynet
	$(INSTALL_DATA) ./htdocs/luci-static/resources/view/tidynet/home.js $(1)/www/luci-static/resources/view/tidynet/main.js
	$(INSTALL_DATA) ./htdocs/luci-static/resources/view/tidynet/home.css $(1)/www/luci-static/resources/view/tidynet/home.css
	$(INSTALL_DATA) ./htdocs/luci-static/resources/view/tidynet/mascot.svg $(1)/www/luci-static/resources/view/tidynet/mascot.svg
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
