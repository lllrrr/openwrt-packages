include $(TOPDIR)/rules.mk

LUCI_TITLE:=LuCI support for VNT2 VNTS2
LUCI_DEPENDS:=+luci-base +luci-compat +kmod-tun
LUCI_PKGARCH:=all

PKG_NAME:=luci-app-vnt2
PKG_VERSION:=1.7.4
PKG_RELEASE:=1
PKG_PO_VERSION:=$(PKG_VERSION)

LUCI_MINIFY_JS:=0
LUCI_MINIFY_CSS:=0

PKG_LICENSE:=Apache-2.0
PKG_MAINTAINER:=whzhni1

include $(TOPDIR)/feeds/luci/luci.mk

define Package/$(PKG_NAME)/conffiles
/etc/config/vnt2
endef

define Package/$(PKG_NAME)/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
INITD=/etc/init.d
if [ -f /etc/uci-defaults/99-vnt2 ]; then
    /etc/uci-defaults/99-vnt2 || true
    rm -f /etc/uci-defaults/99-vnt2
fi
as="$$(uci -q get vnt2.global.autostart)"
if [ "$$as" != "0" ]; then
    $${INITD}/vnt2 enable
    ( setsid "$${INITD}/vnt2" start </dev/null >/dev/null 2>&1 & )
fi
$${INITD}/rpcd reload >/dev/null 2>&1 || true
rm -rf /tmp/luci-*

exit 0
endef

define Package/$(PKG_NAME)/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
INITD=/etc/init.d
$${INITD}/vnt2 stop 2>/dev/null || true
$${INITD}/vnt2 fw_purge 2>/dev/null || true
rm -rf /tmp/luci-*

exit 0
endef

$(eval $(call BuildPackage,$(PKG_NAME)))
