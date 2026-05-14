include $(TOPDIR)/rules.mk

PKG_NAME:=pi
PKG_VERSION:=1.0.0
PKG_RELEASE:=1
PKG_MAINTAINER:=Pi Contributors <pi@localhost>
PKG_LICENSE:=GPL-3.0-or-later

# ── Mihomo 上游源码 ───────────────────────────────────────────────
MIHOMO_VERSION:=1.19.21
PKG_SOURCE_PROTO:=git
PKG_SOURCE_URL:=https://github.com/MetaCubeX/mihomo.git
PKG_SOURCE_VERSION:=v$(MIHOMO_VERSION)
PKG_MIRROR_HASH:=skip

PKG_BUILD_DEPENDS:=golang/host
PKG_BUILD_PARALLEL:=1
PKG_USE_MIPS16:=0

GO_PKG:=github.com/metacubex/mihomo
GO_PKG_LDFLAGS_X:=$(GO_PKG)/constant.Version=v$(MIHOMO_VERSION)

# gvisor 仅支持 amd64 / arm64，其余架构跳过
ifeq ($(ARCH),x86_64)
  GO_PKG_TAGS:=with_gvisor
else ifeq ($(ARCH),aarch64)
  GO_PKG_TAGS:=with_gvisor
else
  GO_PKG_TAGS:=
endif

include $(INCLUDE_DIR)/package.mk
include $(TOPDIR)/feeds/packages/lang/golang/golang-package.mk

define Package/pi
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=Web Servers/Proxies
  TITLE:=Pi - Mihomo Transparent Proxy
  DEPENDS:=$(GO_ARCH_DEPENDS) \
           +ca-certificates \
           +kmod-tun \
           +kmod-nft-tproxy \
           +kmod-nft-socket \
           +kmod-nf-tproxy \
           +kmod-nf-conntrack \
           +nftables \
           +ip-full \
           +kmod-ipt-tproxy
endef

define Package/pi/description
  基于 Mihomo 的 OpenWrt 透明代理管理器。
  提供 TProxy 透明代理、DNS 分流、自动 nftables 防火墙规则配置等功能。
  支持 OpenWrt 25.12 (firewall4 / nftables)。
  内置 Mihomo v$(MIHOMO_VERSION) 核心，编译产出二进制命名为 pi。
endef

define Build/Prepare
	$(Build/Prepare/Default)
	$(RM) -r $(PKG_BUILD_DIR)/rules/logic_test
endef

define Package/pi/conffiles
/etc/pi/config.yaml
endef

define Package/pi/install
	$(call GoPackage/Package/Install/Bin,$(PKG_INSTALL_DIR))

	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_INSTALL_DIR)/usr/bin/mihomo $(1)/usr/bin/pi

	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/pi.init $(1)/etc/init.d/pi

	$(INSTALL_DIR) $(1)/etc/pi
	$(INSTALL_CONF) ./files/config.yaml $(1)/etc/pi/config.yaml

	$(INSTALL_BIN) ./files/pi-ctl $(1)/usr/bin/pi-ctl

	$(INSTALL_DIR) $(1)/lib/upgrade/keep.d
	$(INSTALL_DATA) ./files/pi.keep $(1)/lib/upgrade/keep.d/pi
endef

$(eval $(call GoBinPackage,pi))
$(eval $(call BuildPackage,pi))
