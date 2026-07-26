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
endef

$(eval $(call BuildPackage,luci-proto-hysteria))
