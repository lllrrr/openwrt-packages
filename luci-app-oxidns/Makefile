include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-oxidns
PKG_VERSION:=0.2.0
PKG_RELEASE:=20

# CodeMirror (htdocs/luci-static/resources/oxidns-codemirror) is MIT licensed;
# both license texts are shipped in the package metadata.
PKG_LICENSE:=GPL-3.0-or-later AND MIT
PKG_LICENSE_FILES:=LICENSE htdocs/luci-static/resources/oxidns-codemirror/LICENSE
PKG_MAINTAINER:=NetForgeCN

LUCI_TITLE:=LuCI support for OxiDNS
# oxidns-rules-baseline is a hard dependency, not "+PACKAGE_...:" (conditional):
# the rule files are a load-time requirement of the OxiDNS provider, so a build
# that selects this app must also bake the baseline into the image. A
# conditional dependency silently produced firmware whose first boot died with
# "failed to open text source '/etc/oxidns/rules/cn-domains.txt'" unless the
# baseline happened to be selected by hand.
LUCI_DEPENDS:=+luci-base +rpcd +jsonfilter +uclient-fetch +ca-bundle +oxidns-core +oxidns-rules-baseline
LUCI_PKGARCH:=all

define Package/luci-app-oxidns/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT:-}" ] && exit 0
# Keep the core binary, webui and configuration across firmware upgrades.
if [ -f /etc/sysupgrade.conf ]; then
	for entry in /etc/oxidns /etc/config/oxidns; do
		grep -qxF "$$entry" /etc/sysupgrade.conf 2>/dev/null || \
			echo "$$entry" >> /etc/sysupgrade.conf
	done
fi
# After a firmware upgrade the persistent core survives; just relink it so the
# service starts again without re-downloading anything.
if [ -x /etc/oxidns/core/oxidns ] && [ ! -x /usr/bin/oxidns ]; then
	mkdir -p /usr/bin
	ln -sf /etc/oxidns/core/oxidns /usr/bin/oxidns
fi
if [ -d /etc/oxidns/core/webui ] && [ ! -d /usr/share/oxidns/webui ]; then
	mkdir -p /usr/share/oxidns
	ln -sfn /etc/oxidns/core/webui /usr/share/oxidns/webui
fi
rm -f /tmp/luci-indexcache* 2>/dev/null || true
rm -rf /tmp/luci-modulecache/* 2>/dev/null || true
if [ -d /www/luci-static/resources/view/oxidns ]; then
	find /www/luci-static/resources/view/oxidns -type f -name '*.js' -exec touch {} + 2>/dev/null || true
fi
if [ -x /etc/init.d/rpcd ]; then
	/etc/init.d/rpcd restart >/dev/null 2>&1 || true
fi
# fw4 treats a redirect without `family` as IPv4 unless `family any` is set
# explicitly. Old hijack sections written without it hijacked IPv4 :53 only.
# Patch only our own tagged sections and only when family is empty; a user-
# chosen value is left alone. Idempotent.
if command -v uci >/dev/null 2>&1; then
	hijack_changed=0
	for hijack_sect in oxidns_hijack oxidns_hijack_udp oxidns_hijack_tcp; do
		[ "$$(uci -q get "firewall.$$hijack_sect.name" 2>/dev/null || true)" = "oxidns-dns-hijack" ] || continue
		[ -n "$$(uci -q get "firewall.$$hijack_sect.family" 2>/dev/null || true)" ] && continue
		if uci -q set "firewall.$$hijack_sect.family=any"; then
			hijack_changed=1
		fi
	done
	if [ "$$hijack_changed" = "1" ] && uci -q commit firewall; then
		if [ -x /etc/init.d/firewall ]; then
			/etc/init.d/firewall reload >/dev/null 2>&1 || true
		fi
	fi
fi
exit 0
endef

define Package/luci-app-oxidns/postrm
#!/bin/sh
[ -n "$${IPKG_INSTROOT:-}" ] && exit 0
rm -f /tmp/luci-indexcache* 2>/dev/null || true
rm -rf /tmp/luci-modulecache/* 2>/dev/null || true
if [ -x /etc/init.d/rpcd ]; then
	/etc/init.d/rpcd restart >/dev/null 2>&1 || true
fi
exit 0
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
