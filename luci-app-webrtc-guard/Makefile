# SPDX-License-Identifier: GPL-3.0-or-later
#
# luci-app-webrtc-guard
# 在 OpenWRT (fw4/nftables) 上于网络层拦截 WebRTC STUN/ICE，防止真实 IP 泄露。
# 目标平台：OpenWRT 22.03+ / KWRT 25.12（fw4 + LuCI JS 客户端）。

include $(TOPDIR)/rules.mk

LUCI_TITLE:=LuCI support for WebRTC Guard (STUN IP leak protection)
LUCI_URL:=https://github.com/meesii/luci-app-webrtc-guard
LUCI_DESCRIPTION:=Guard real WAN egress against cleartext STUN, including \
    OpenClash DIRECT output; preserve ordinary web traffic.
LUCI_DEPENDS:=+firewall4 +kmod-nft-core +nftables-json +jsonfilter +busybox
ifeq ($(CONFIG_USE_APK),)
LUCI_DEPENDS+=+flock
endif
LUCI_PKGARCH:=all

PKG_NAME:=luci-app-webrtc-guard
PKG_VERSION:=1.2.3
PKG_RELEASE:=1
PKG_MAINTAINER:=meesii
LUCI_MAINTAINER:=$(PKG_MAINTAINER)
PKG_LICENSE:=GPL-3.0-or-later

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
