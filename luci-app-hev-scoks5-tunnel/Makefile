#
# Copyright (C) 2026 starsfall <science2468@proton.me>
#
# This is free software, licensed under the Apache License, Version 2.0 .
#
# include $(TOPDIR)/feeds/luci/luci.mk -> luci
# include $(TOPDIR)/feeds/luci/luci.mk -> SDK

include $(TOPDIR)/rules.mk

LUCI_TITLE:=LuCI Support for hev-socks5-tunnel
LUCI_DEPENDS:=+hev-socks5-tunnel
LUCI_PKGARCH:=all

PKG_MAINTAINER:=starsfall <science2468@proton.me>

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
