#
# Copyright (C) 2026
#
# This is free software, licensed under the Apache License, Version 2.0.
#

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-workbuddy
PKG_VERSION:=1.7.0
PKG_RELEASE:=1

PKG_LICENSE:=Apache-2.0
PKG_MAINTAINER:=AI Relay Server Port

LUCI_TITLE:=AI 中转服务器（AI Relay Server）
LUCI_DESCRIPTION:=Aggregate the on-router WorkBuddy account and any number of \
	third-party OpenAI-compatible servers into one local endpoint. Each server \
	can carry multiple API keys with round-robin load balancing and automatic \
	cooldown on failure. Exposes /v1/chat/completions and /v1/models, plus a \
	standalone admin web panel (/admin, password protected) for servers, keys, \
	credential pool and model policy, and a read-only LuCI status page.
LUCI_DEPENDS:=+ucode +ucode-mod-fs +ucode-mod-uloop +ucode-mod-socket \
	+ucode-mod-uci +ucode-mod-ubus +ucode-mod-digest +curl +rpcd +luci-base
LUCI_PKGARCH:=all

define Package/luci-app-workbuddy/conffiles
/etc/config/workbuddy
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
$(eval $(call BuildPackage,luci-app-workbuddy))
