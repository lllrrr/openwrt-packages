include $(TOPDIR)/rules.mk

LUCI_TITLE:=luci-app-naived
LUCI_PKGARCH:=all
PKG_NAME:=luci-app-naived
PKG_VERSION:=251
PKG_RELEASE:=1

PKG_CONFIG_DEPENDS:= \
	CONFIG_PACKAGE_$(PKG_NAME)_Nftables_Transparent_Proxy \
	CONFIG_PACKAGE_$(PKG_NAME)_INCLUDE_ChinaDNS_NG \
	CONFIG_PACKAGE_$(PKG_NAME)_INCLUDE_DNS2TCP \
	CONFIG_PACKAGE_$(PKG_NAME)_INCLUDE_DNSPROXY \
	CONFIG_PACKAGE_$(PKG_NAME)_INCLUDE_NaiveProxy

LUCI_TITLE:=NaiveProxy LuCI interface
LUCI_PKGARCH:=all
LUCI_DEPENDS:= \
	+coreutils +coreutils-base64 +dns2tcp +dnsmasq-full \
	+jq +ip-full +lua +libuci-lua +microsocks \
	+tcping +resolveip +curl +nping \
	+PACKAGE_$(PKG_NAME)_INCLUDE_ChinaDNS_NG:chinadns-ng \
	+PACKAGE_$(PKG_NAME)_INCLUDE_DNSPROXY:dnsproxy \
	+PACKAGE_$(PKG_NAME)_INCLUDE_NaiveProxy:naiveproxy


define Package/$(PKG_NAME)/config
select PACKAGE_luci-lua-runtime if PACKAGE_$(PKG_NAME)

config PACKAGE_$(PKG_NAME)_Nftables_Transparent_Proxy
	bool "Nftables Transparent Proxy"
	select PACKAGE_dnsmasq_full_nftset
	select PACKAGE_nftables
	select PACKAGE_kmod-nft-socket
	select PACKAGE_kmod-nft-tproxy
	select PACKAGE_kmod-nft-nat

config PACKAGE_$(PKG_NAME)_INCLUDE_ChinaDNS_NG
	bool "Include ChinaDNS-NG"
	default n

config PACKAGE_$(PKG_NAME)_INCLUDE_DNSPROXY
	bool "Include DNSproxy"
	default n

config PACKAGE_$(PKG_NAME)_INCLUDE_NaiveProxy
	bool "Include NaiveProxy"
	depends on !(arc||armeb||mips||mips64||powerpc||TARGET_gemini)
	default n

endef


define Package/$(PKG_NAME)/conffiles
/etc/config/naived
/etc/naived/
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
