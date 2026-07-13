# Copyright (c) 2026 Eugene Chan
# SPDX-License-Identifier: MIT
# This is free software, licensed under the MIT License.

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-bypass
PKG_VERSION:=1.1.0
PKG_RELEASE:=1
PKG_PO_VERSION:=$(PKG_VERSION)
PKG_LICENSE:=MIT
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=Eugene Chan

# Build-system symbols that, when toggled in menuconfig, should trigger a rebuild.
PKG_CONFIG_DEPENDS:= \
	CONFIG_PACKAGE_$(PKG_NAME)_Nftables_Transparent_Proxy \
	CONFIG_PACKAGE_$(PKG_NAME)_INCLUDE_NaiveProxy \
	CONFIG_PACKAGE_$(PKG_NAME)_INCLUDE_ChinaDNS_NG \
	CONFIG_PACKAGE_$(PKG_NAME)_INCLUDE_Geoview \
	CONFIG_PACKAGE_$(PKG_NAME)_INCLUDE_V2ray_Geo \
	CONFIG_PACKAGE_$(PKG_NAME)_INCLUDE_Tcping

LUCI_TITLE:=LuCI support for Bypass (naiveproxy + ChinaDNS-ng + BypassCore)
LUCI_PKGARCH:=all

# Only the shell-runtime essentials are hard dependencies. Everything that is a
# feed package (naiveproxy, chinadns-ng, geoview, geodata, tcping, the firewall
# chain) is an optional build toggle below so the user can build a minimal image.
LUCI_DEPENDS:=+curl +ip-full +resolveip +libubox +coreutils-nohup +coreutils-timeout

define Package/$(PKG_NAME)/config
menu "Configuration"
	depends on PACKAGE_$(PKG_NAME)

config PACKAGE_$(PKG_NAME)_Nftables_Transparent_Proxy
	bool "Nftables Transparent Proxy (fw4)"
	select PACKAGE_nftables
	select PACKAGE_kmod-nft-tproxy
	select PACKAGE_kmod-nft-socket
	select PACKAGE_kmod-nft-nat
	select PACKAGE_dnsmasq-full
	select PACKAGE_dnsmasq_full_nftset
	default y

config PACKAGE_$(PKG_NAME)_INCLUDE_NaiveProxy
	bool "Include NaiveProxy (https proxy core)"
	depends on !(arc||armeb||loongarch64||mips||mips64||powerpc||TARGET_gemini)
	select PACKAGE_naiveproxy
	default n

config PACKAGE_$(PKG_NAME)_INCLUDE_ChinaDNS_NG
	bool "Include ChinaDNS-NG (split DNS)"
	select PACKAGE_chinadns-ng
	default n

config PACKAGE_$(PKG_NAME)_INCLUDE_Geoview
	bool "Include Geoview (geodata query tool)"
	select PACKAGE_geoview
	default n

config PACKAGE_$(PKG_NAME)_INCLUDE_V2ray_Geo
	bool "Include v2ray-geoip / v2ray-geosite (geoip.dat / geosite.dat)"
	select PACKAGE_v2ray-geoip
	select PACKAGE_v2ray-geosite
	default n

config PACKAGE_$(PKG_NAME)_INCLUDE_Tcping
	bool "Include tcping (node latency test)"
	select PACKAGE_tcping
	default n

endmenu
endef

define Package/$(PKG_NAME)/conffiles
/etc/config/bypass
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
