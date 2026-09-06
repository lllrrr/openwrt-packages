include $(TOPDIR)/rules.mk

PKG_NAME:=portweaver-lite
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

PKG_SOURCE_DATE:=2026-09-06
PKG_SOURCE_VERSION:=45a7cd3cfdba1dc2f04e7d291eedd54320bc0684
PKG_BUILD_DIR:=$(BUILD_DIR)/portweaver-$(PKG_SOURCE_VERSION)
PKG_SOURCE:=$(PKG_NAME)-$(PKG_SOURCE_VERSION).tar.gz
PKG_SOURCE_URL:=https://codeload.github.com/LazuliKao/portweaver/tar.gz/$(PKG_SOURCE_VERSION)?
PKG_HASH:=e09fe2503ae49b64e38522a4b2c19cdf2612817569aad7b3b80b5be0de98c634

PKG_LICENSE:=GPL-3.0
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=LazuliKao

# Zig is downloaded and managed by Build/Compile
PKG_BUILD_PARALLEL:=1

include $(INCLUDE_DIR)/package.mk

# Zig configuration
ZIG := $(STAGING_DIR_HOST)/bin/zig
ZIG_TARGET := $(subst openwrt-,,$(GNU_TARGET_NAME))
ZIG_OPTIMIZE ?= ReleaseSmall

define Package/portweaver-lite
  SECTION:=net
  CATEGORY:=Network
  TITLE:=Port forwarding tool (lite, no frpc/frps/ddns)
  URL:=https://github.com/LazuliKao/portweaver
  DEPENDS:=+libuci
  PROVIDES:=portweaver-impl
endef

define Package/portweaver-lite/description
  PortWeaver Lite is a lightweight build of PortWeaver for OpenWrt.
  UCI, ubus, nftables and wol support are enabled; frpc, frps and ddns are excluded,
  resulting in a smaller binary suitable for resource-constrained devices.
endef

# Macro: build one variant
# $(1) = zig binary, $(2) = extra flags, $(3) = install prefix
define BuildVariant
	cd $(PKG_BUILD_DIR) && \
	$(1) build \
		-Dtarget=$(ZIG_TARGET) \
		-Dcpu=$(if $(CPU_TYPE),$(CPU_TYPE),baseline) \
		-Doptimize=$(ZIG_OPTIMIZE) \
		$(2) \
		--prefix $(3)
endef

define Build/Compile
	# Check if Zig is available, download if not
	@if [ ! -f "$(ZIG)" ]; then \
		echo "Zig not found, downloading..."; \
		mkdir -p $(PKG_BUILD_DIR)/zig-tmp; \
		cd $(PKG_BUILD_DIR)/zig-tmp && \
		wget -q -O zig.tar.xz https://ziglang.org/download/0.16.0/zig-x86_64-linux-0.16.0.tar.xz && \
		tar xf zig.tar.xz; \
		$(call BuildVariant, \
			$(PKG_BUILD_DIR)/zig-tmp/zig-x86_64-linux-0.16.0/zig, \
			-Duci=true -Dubus=true -Dfrpc=false -Dfrps=false -Dddns=false -Dnftables=true -Dwol=true, \
			$(PKG_INSTALL_DIR)); \
	else \
		$(call BuildVariant, \
			$(ZIG), \
			-Duci=true -Dubus=true -Dfrpc=false -Dfrps=false -Dddns=false -Dnftables=true -Dwol=true, \
			$(PKG_INSTALL_DIR)); \
	fi
endef

define Package/portweaver-lite/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_INSTALL_DIR)/bin/portweaver $(1)/usr/bin/portweaver

	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_DATA) ./files/portweaver.config $(1)/etc/config/portweaver

	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/portweaver.init $(1)/etc/init.d/portweaver
endef

define Package/portweaver-lite/conffiles
/etc/config/portweaver
endef

$(eval $(call BuildPackage,portweaver-lite))
