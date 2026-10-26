#
# luci-app-server-ctl - manual and scheduled power control for LAN servers
#

include $(TOPDIR)/rules.mk

LUCI_TITLE:=Server Control
LUCI_DESCRIPTION:=Manual and scheduled Wake-on-LAN, suspend and power-off control for LAN servers via etherwake and SSH.
LUCI_DEPENDS:=+luci-base +etherwake +sshpass +openssh-client
LUCI_PKGARCH:=all

PKG_LICENSE:=Apache-2.0
PKG_MAINTAINER:=luci-plugin

# 版本号: CI 编译时通过 make CTL_BUILDID=<id> 注入构建号(日期+commit短哈希),
# 本地直接编译时回退到 1.0。版本号会写入 ipk 文件名, 便于区分新旧构建。
PKG_VERSION ?= $(if $(CTL_BUILDID),$(CTL_BUILDID),1.0)
PKG_PO_VERSION ?= $(PKG_VERSION)

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
