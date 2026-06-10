#
# Copyright 2024 luci-app-sxray
# Licensed to the public under the MIT License.
#

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-sxray
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

PKG_LICENSE:=MIT
PKG_MAINTAINER:=luci-app-sxray

LUCI_TITLE:=LuCI support for Xray/Sing-Box
LUCI_DEPENDS:=+jshn +luci-lib-jsonc +ip +ipset +iptables +iptables-mod-tproxy +nftables \
	+resolveip +dnsmasq-full
LUCI_PKGARCH:=all

define Package/$(PKG_NAME)/conffiles
/etc/config/sxray
/etc/sxray/transport.json
/etc/sxray/srcdirectlist.txt
/etc/sxray/directlist.txt
/etc/sxray/proxylist.txt
endef

include $(TOPDIR)/feeds/luci/luci.mk

define Package/$(PKG_NAME)/postinst
#!/bin/sh

if [ -z "$${IPKG_INSTROOT}" ] ; then
	( . /etc/uci-defaults/40_luci-sxray ) && rm -f /etc/uci-defaults/40_luci-sxray
fi

chmod 755 "$${IPKG_INSTROOT}/etc/init.d/sxray" >/dev/null 2>&1
ln -sf "../init.d/sxray" \
	"$${IPKG_INSTROOT}/etc/rc.d/S99sxray" >/dev/null 2>&1

exit 0
endef

define Package/$(PKG_NAME)/postrm
#!/bin/sh

if [ -s "$${IPKG_INSTROOT}/etc/rc.d/S99sxray" ] ; then
	rm -f "$${IPKG_INSTROOT}/etc/rc.d/S99sxray"
fi

if [ -z "$${IPKG_INSTROOT}" ] ; then
	rm -rf /tmp/luci-indexcache /tmp/luci-modulecache
fi

exit 0
endef

# call BuildPackage - OpenWrt buildroot signature
