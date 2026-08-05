include $(TOPDIR)/rules.mk

PKG_NAME:=luci-proto-hysteria
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

PKG_LICENSE:=MIT
PKG_MAINTAINER:=luunarrr

include $(INCLUDE_DIR)/package.mk

define Package/luci-proto-hysteria
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=2. Protocols
  TITLE:=Support for Hysteria2 PPP
  PKGARCH:=all
  DEPENDS:=+luci-base +hysteria2-ppp
endef

define Package/luci-proto-hysteria/description
  LuCI protocol support for Hysteria2 PPP.

  Adds a Hysteria2 PPP protocol to Network -> Interfaces, backed by the netifd
  protocol handler shipped in hysteria2-ppp. The link is then an ordinary
  OpenWrt interface: it can be brought up and down, assigned to a firewall
  zone, and given routing metrics like any other protocol.
endef

define Build/Compile
endef

define Package/luci-proto-hysteria/install
	$(INSTALL_DIR) $(1)/www/luci-static/resources/protocol
	$(INSTALL_DATA) ./htdocs/luci-static/resources/protocol/hysteria.js \
		$(1)/www/luci-static/resources/protocol/hysteria.js

	# Shared by the protocol class and the status page: the reason strings and
	# the judgement about what counts as a degraded bundle. One copy, so the
	# interface list and the status page cannot disagree about the same router.
	$(INSTALL_DATA) ./htdocs/luci-static/resources/hysteria.js \
		$(1)/www/luci-static/resources/hysteria.js

	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/hysteria
	$(INSTALL_DATA) ./htdocs/luci-static/resources/view/hysteria/multilink.js \
		$(1)/www/luci-static/resources/view/hysteria/multilink.js

	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DATA) ./root/usr/share/luci/menu.d/luci-proto-hysteria.json \
		$(1)/usr/share/luci/menu.d/luci-proto-hysteria.json

	# The ubus object is shipped by hysteria2-ppp; this is the grant that lets a
	# LuCI session read it. Read-only -- there is no method on that object that
	# changes anything.
	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./root/usr/share/rpcd/acl.d/luci-proto-hysteria.json \
		$(1)/usr/share/rpcd/acl.d/luci-proto-hysteria.json
endef

$(eval $(call BuildPackage,luci-proto-hysteria))
