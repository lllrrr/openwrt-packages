include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-vnt2

LUCI_TITLE:=LuCI support for VNT2 VNTS2
LUCI_DEPENDS:=+luci-base +luci-compat +kmod-tun
LUCI_PKGARCH:=all

PKG_VERSION:=1.7.6
PKG_RELEASE:=1
PKG_PO_VERSION:=$(PKG_VERSION)

LUCI_MINIFY_JS:=0
LUCI_MINIFY_CSS:=0

PKG_LICENSE:=Apache-2.0
PKG_MAINTAINER:=whzhni1

define Build/Prepare/$(PKG_NAME)
	$(SED) "s/^const ASSET_VERSION = '[^']*';/const ASSET_VERSION = '$(PKG_VERSION)';/" $(PKG_BUILD_DIR)/htdocs/luci-static/resources/vnt2/common.js
endef

include $(TOPDIR)/feeds/luci/luci.mk

define Package/$(PKG_NAME)/conffiles
/etc/config/vnt2
endef

define Package/$(PKG_NAME)/postinst
#!/bin/sh
/usr/libexec/vnt2/vnt2-package.sh postinst "$$@"
endef

define Package/$(PKG_NAME)/prerm
#!/bin/sh
/usr/libexec/vnt2/vnt2-package.sh prerm "$$@"
endef

define Package/$(PKG_NAME)/postrm
#!/bin/sh
/usr/libexec/vnt2/vnt2-package.sh postrm "$$@"
endef

$(eval $(call BuildPackage,$(PKG_NAME)))
