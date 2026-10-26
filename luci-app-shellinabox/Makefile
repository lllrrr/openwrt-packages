# SPDX-License-Identifier: Apache-2.0
include $(TOPDIR)/rules.mk

LUCI_TITLE:=ShellInABox - Command-line tool for sharing terminal over the web
LUCI_DEPENDS:=+luci-base +shellinabox +openssl-util +ucode-mod-fs +ucode-mod-uci

PKG_VERSION:=1.0.0
PKG_RELEASE:=1
PKG_LICENSE:=Apache-2.0

define Package/luci-app-shellinabox/conffiles
/etc/config/shellinabox
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
