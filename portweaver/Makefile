include $(TOPDIR)/rules.mk

PKG_NAME:=portweaver
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

PKG_SOURCE_DATE:=2026-07-12
PKG_SOURCE_VERSION:=eb54eaea830da746c33ba06840f719559f6fec94
PKG_SOURCE:=$(PKG_NAME)-$(PKG_SOURCE_VERSION).tar.gz
PKG_SOURCE_URL:=https://codeload.github.com/LazuliKao/portweaver/tar.gz/$(PKG_SOURCE_VERSION)?
PKG_HASH:=a931ecbd4b63f22c2029a2433c78bb87e1116e28848c4ca84721d1e97d609ffb
PKG_UNPACK:=$(STAGING_DIR_HOST)/bin/libdeflate-gzip -dc $(DL_DIR)/$(PKG_SOURCE) | $(TAR) -C $(PKG_BUILD_DIR) --strip-components=1 -xf -

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
  Includes: frpc, frps, ddns, uci, ubus.
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
			-Duci=true -Dubus=true -Dfrpc=true -Dfrps=true -Dddns=true, \
			$(PKG_INSTALL_DIR)); \
	else \
		$(call BuildVariant, \
			$(ZIG), \
			-Duci=true -Dubus=true -Dfrpc=true -Dfrps=true -Dddns=true, \
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
