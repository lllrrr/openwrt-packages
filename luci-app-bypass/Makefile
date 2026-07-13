# Copyright (c) 2026 Eugene Chan
# SPDX-License-Identifier: MIT
# This is free software, licensed under the MIT License.

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-bypass
PKG_VERSION:=1.3.4
PKG_RELEASE:=1
PKG_PO_VERSION:=$(PKG_VERSION)
PKG_LICENSE:=MIT
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=Eugene Chan

# Build-system symbols that, when toggled in menuconfig, should trigger a rebuild.
PKG_CONFIG_DEPENDS:= \
	CONFIG_PACKAGE_$(PKG_NAME)_INCLUDE_NaiveProxy \
	CONFIG_PACKAGE_$(PKG_NAME)_INCLUDE_ChinaDNS_NG \
	CONFIG_PACKAGE_$(PKG_NAME)_INCLUDE_Dns2socks \
	CONFIG_PACKAGE_$(PKG_NAME)_INCLUDE_Geoview \
	CONFIG_PACKAGE_$(PKG_NAME)_INCLUDE_V2ray_Geo \
	CONFIG_PACKAGE_$(PKG_NAME)_INCLUDE_Tcping

LUCI_TITLE:=LuCI support for Bypass (naiveproxy + ChinaDNS-ng + BypassCore)
LUCI_PKGARCH:=all

# This application only supports fw4/nftables. Keep the firewall userspace and
# kernel expressions as runtime dependencies so installing the generated
# package also installs everything required by REDIRECT and TPROXY modes.
LUCI_DEPENDS:=+curl +ip-full +resolveip +libubox +coreutils-nohup +coreutils-timeout \
	+nftables +kmod-nft-nat +kmod-nft-tproxy +kmod-nft-socket

define Package/$(PKG_NAME)/config
menu "Configuration"
	depends on PACKAGE_$(PKG_NAME)

config PACKAGE_$(PKG_NAME)_INCLUDE_NaiveProxy
	bool "Include NaiveProxy (https proxy core)"
	depends on !(arc||armeb||loongarch64||mips||mips64||powerpc||TARGET_gemini)
	select PACKAGE_naiveproxy
	default n

config PACKAGE_$(PKG_NAME)_INCLUDE_ChinaDNS_NG
	bool "Include ChinaDNS-NG (split DNS)"
	select PACKAGE_chinadns-ng
	default n

config PACKAGE_$(PKG_NAME)_INCLUDE_Dns2socks
	bool "Include DNS2SOCKS (remote DNS through Naive)"
	select PACKAGE_dns2socks
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
