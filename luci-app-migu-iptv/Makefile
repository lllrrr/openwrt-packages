#
# Copyright (C) 2026
#
# This is free software, licensed under the Apache License, Version 2.0.
#

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-migu-iptv
PKG_VERSION:=1.5.0
PKG_RELEASE:=1

PKG_LICENSE:=Apache-2.0
PKG_MAINTAINER:=Migu IPTV Relay

LUCI_TITLE:=咪咕直播（Migu IPTV Relay）
LUCI_DESCRIPTION:=Fetch Migu Video live channels and relay them to a TV-BOX as a \
	standard M3U playlist. Fully configurable from LuCI under \
	Services -> Migu Live; no separate web panel. Provides /m3u and /txt \
	playlists, on-demand stream resolution (/ch/<pid>) with 302 redirect to \
	the final HLS URL, EPG (tvg-id) mapping, service control, channel \
	testing and log viewing. Guest mode up to 540p; a Migu account token \
	unlocks 720p and VIP unlocks 1080p/original/4K. No Node.js or Docker \
	required.
LUCI_DEPENDS:=+ucode +ucode-mod-fs +ucode-mod-uloop +ucode-mod-socket \
	+ucode-mod-uci +ucode-mod-digest +curl +rpcd +luci-base
LUCI_PKGARCH:=all

define Package/luci-app-migu-iptv/conffiles
/etc/config/migu
endef

include $(TOPDIR)/feeds/luci/luci.mk

# luci.mk 只自动收集 root/ htdocs/ luasrc/ 这类标准目录，
# 本项目用的是 files/ 整树布局，所以这里显式安装一次。
define Package/luci-app-migu-iptv/install
	$(INSTALL_DIR) $(1)/
	$(CP) ./files/* $(1)/
endef

# call BuildPackage - OpenWrt buildroot signature
$(eval $(call BuildPackage,luci-app-migu-iptv))
