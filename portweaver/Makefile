include $(TOPDIR)/rules.mk

PKG_NAME:=portweaver
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

define Package/portweaver
  SECTION:=net
  CATEGORY:=Network
  TITLE:=Port forwarding and NAT traversal tool
  URL:=https://github.com/LazuliKao/portweaver
  DEPENDS:=+libuci @!(TARGET_mips||TARGET_mipsel||TARGET_mips64||TARGET_mips64el)
  PROVIDES:=portweaver-impl
endef

define Package/portweaver/description
  PortWeaver is a flexible port forwarding and NAT traversal tool
  for OpenWrt, with UCI configuration support.
  Includes: frpc, frps, ddns, uci, ubus, nftables, wol.
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
			-Duci=true -Dubus=true -Dfrpc=true -Dfrps=true -Dddns=true -Dnftables=true -Dwol=true, \
			$(PKG_INSTALL_DIR)); \
	else \
		$(call BuildVariant, \
			$(ZIG), \
			-Duci=true -Dubus=true -Dfrpc=true -Dfrps=true -Dddns=true -Dnftables=true -Dwol=true, \
			$(PKG_INSTALL_DIR)); \
	fi
endef

define Package/portweaver/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_INSTALL_DIR)/bin/portweaver $(1)/usr/bin/portweaver

	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_DATA) ./files/portweaver.config $(1)/etc/config/portweaver

	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/portweaver.init $(1)/etc/init.d/portweaver
endef

define Package/portweaver/conffiles
/etc/config/portweaver
endef

$(eval $(call BuildPackage,portweaver))
