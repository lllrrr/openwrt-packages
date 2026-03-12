include $(TOPDIR)/rules.mk

PKG_NAME:=portweaver
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

PKG_SOURCE_PROTO:=git
PKG_SOURCE_URL:=https://github.com/LazuliKao/portweaver.git
PKG_SOURCE_VERSION:=HEAD
PKG_MIRROR_HASH:=2ef3cef58cb22255fc4eb6be240f3db09209b205d8e814d9c585094c4e3e5b38

PKG_LICENSE:=GPL-3.0
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=LazuliKao

PKG_BUILD_PARALLEL:=1

include $(INCLUDE_DIR)/package.mk

# ---------------------------------------------------------------------------
# Zig toolchain configuration
# ---------------------------------------------------------------------------
ZIG_VERSION := 0.15.2
ZIG_HOST_ARCH := x86_64-linux
ZIG_DIST_NAME := zig-$(ZIG_HOST_ARCH)-$(ZIG_VERSION)
ZIG_DIST_URL := https://ziglang.org/download/$(ZIG_VERSION)/$(ZIG_DIST_NAME).tar.xz

ZIG := $(STAGING_DIR_HOST)/bin/zig
ZIG_BOOTSTRAP := $(PKG_BUILD_DIR)/zig-tmp/$(ZIG_DIST_NAME)/zig

ZIG_TARGET := $(subst openwrt-,,$(GNU_TARGET_NAME))
ZIG_CPU := $(if $(CPU_TYPE),$(CPU_TYPE),baseline)
ZIG_OPTIMIZE ?= ReleaseSmall

# ---------------------------------------------------------------------------
# Install directories for the two build variants
# ---------------------------------------------------------------------------
PKG_INSTALL_DIR_FULL := $(PKG_INSTALL_DIR)-full
PKG_INSTALL_DIR_LITE := $(PKG_INSTALL_DIR)-lite

# ---------------------------------------------------------------------------
# Package definitions
# ---------------------------------------------------------------------------
define Package/portweaver
  SECTION:=net
  CATEGORY:=Network
  TITLE:=Port forwarding and NAT traversal tool
  URL:=https://github.com/LazuliKao/portweaver
  DEPENDS:=+libuci
  PROVIDES:=portweaver-impl
endef

define Package/portweaver/description
  PortWeaver is a flexible port forwarding and NAT traversal tool
  for OpenWrt, with UCI configuration support.
  Includes: frpc, frps, ddns, uci, ubus.
endef

define Package/portweaver-lite
  SECTION:=net
  CATEGORY:=Network
  TITLE:=Port forwarding tool (lite, no frpc/frps/ddns)
  URL:=https://github.com/LazuliKao/portweaver
  DEPENDS:=+libuci
  PROVIDES:=portweaver-impl
  CONFLICTS:=portweaver
endef

define Package/portweaver-lite/description
  PortWeaver Lite is a lightweight build of PortWeaver for OpenWrt.
  Only UCI and ubus support are enabled; frpc, frps and ddns are excluded,
  resulting in a smaller binary suitable for resource-constrained devices.
endef

# ---------------------------------------------------------------------------
# Build helpers
# ---------------------------------------------------------------------------

# Ensure Zig is available; download bootstrap copy if not installed on host.
define ZigEnsure
	if [ ! -f "$(ZIG)" ]; then \
		echo "Zig $(ZIG_VERSION) not found in staging_dir, downloading bootstrap..."; \
		mkdir -p $(PKG_BUILD_DIR)/zig-tmp; \
		wget -q -O $(PKG_BUILD_DIR)/zig-tmp/zig.tar.xz $(ZIG_DIST_URL) && \
		tar -xf $(PKG_BUILD_DIR)/zig-tmp/zig.tar.xz -C $(PKG_BUILD_DIR)/zig-tmp; \
	fi
endef

# Resolve the Zig binary path (prefer host installation, fall back to bootstrap).
ZIG_BIN = $$(if [ -f "$(ZIG)" ]; then echo "$(ZIG)"; else echo "$(ZIG_BOOTSTRAP)"; fi)

# Build one variant.
# $(1) = feature flags   e.g. -Dfrpc=true -Dfrps=true -Dddns=true
# $(2) = install prefix  e.g. $(PKG_INSTALL_DIR_FULL)
define BuildVariant
	ZIG_BIN=$(ZIG_BIN); \
	cd $(PKG_BUILD_DIR) && \
	$$ZIG_BIN build \
		-Dtarget=$(ZIG_TARGET) \
		-Dcpu=$(ZIG_CPU) \
		-Doptimize=$(ZIG_OPTIMIZE) \
		-Duci=true -Dubus=true \
		$(1) \
		--prefix $(2)
endef

PORTWEAVER_FEATURES_FULL := -Dfrpc=true -Dfrps=true -Dddns=true
PORTWEAVER_FEATURES_LITE := -Dfrpc=false -Dfrps=false -Dddns=false

PORTWEAVER_FEATURES := $(if $(CONFIG_PACKAGE_portweaver-lite),$(PORTWEAVER_FEATURES_LITE),$(PORTWEAVER_FEATURES_FULL))
PORTWEAVER_INSTALL_DIR := $(if $(CONFIG_PACKAGE_portweaver-lite),$(PKG_INSTALL_DIR_LITE),$(PKG_INSTALL_DIR_FULL))

define Build/Compile
	$(call ZigEnsure)
	$(call BuildVariant,$(PORTWEAVER_FEATURES),$(PORTWEAVER_INSTALL_DIR))
endef

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------

define Package/portweaver/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_INSTALL_DIR_FULL)/bin/portweaver $(1)/usr/bin/portweaver
	$(INSTALL_BIN) ./files/log-processor.sh $(1)/usr/bin/portweaver-log-processor
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_DATA) ./files/portweaver.config $(1)/etc/config/portweaver
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/portweaver.init $(1)/etc/init.d/portweaver
endef

define Package/portweaver-lite/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_INSTALL_DIR_LITE)/bin/portweaver $(1)/usr/bin/portweaver
	$(INSTALL_BIN) ./files/log-processor.sh $(1)/usr/bin/portweaver-log-processor
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_DATA) ./files/portweaver.config $(1)/etc/config/portweaver
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/portweaver.init $(1)/etc/init.d/portweaver
endef

define Package/portweaver/conffiles
/etc/config/portweaver
endef

define Package/portweaver-lite/conffiles
/etc/config/portweaver
endef

# ---------------------------------------------------------------------------

$(eval $(call BuildPackage,portweaver))
$(eval $(call BuildPackage,portweaver-lite))
