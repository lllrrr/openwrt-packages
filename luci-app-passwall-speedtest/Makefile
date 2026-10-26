# Author: mingxiaoyu (fengying0347@163.com)
#
# Licensed to the public under the GNU General Public License v3.
#

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-passwall-speedtest

LUCI_TITLE:=LuCI support for PassWall-based Cloudflare IP speed test
LUCI_DEPENDS:=+curl
LUCI_PKGARCH:=all
PKG_VERSION:=2.0
PKG_RELEASE:=0
PKG_LICENSE:=AGPL-3.0
PKG_MAINTAINER:=<https://github.com/urbanescavenger/luci-app-passwall-speedtest>

define Package/$(PKG_NAME)/conffiles
/etc/config/passwall-speedtest
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
