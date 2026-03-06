# Copyright (C) 2024
# This is free software, licensed under the Apache License, Version 2.0

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-argo
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

PKG_LICENSE:=Apache-2.0
PKG_MAINTAINER:=Your Name <your@email.com>

LUCI_TITLE:=LuCI support for Cloudflare Tunnel (Argo)
LUCI_DEPENDS:=+wget-ssl +ca-certificates +ca-bundle
LUCI_PKGARCH:=all

define Package/luci-app-argo/conffiles
/etc/config/argo
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot magic that sets up the package
