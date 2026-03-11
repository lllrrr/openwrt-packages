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

# Install directories for the two variants
PKG_INSTALL_DIR_FULL := $(PKG_INSTALL_DIR)-full
PKG_INSTALL_DIR_LITE := $(PKG_INSTALL_DIR)-lite

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
		wget -q -O zig.tar.xz https://ziglang.org/download/0.15.2/zig-x86_64-linux-0.15.2.tar.xz && \
		tar xf zig.tar.xz; \
		if [ "$(BUILD_LITE_ONLY)" = "1" ]; then \
			$(call BuildVariant, \
				$(PKG_BUILD_DIR)/zig-tmp/zig-x86_64-linux-0.15.2/zig, \
				-Duci=true -Dubus=true -Dfrpc=false -Dfrps=false -Dddns=false, \
				$(PKG_INSTALL_DIR_LITE)); \
		else \
			$(call BuildVariant, \
				$(PKG_BUILD_DIR)/zig-tmp/zig-x86_64-linux-0.15.2/zig, \
				-Duci=true -Dubus=true -Dfrpc=true -Dfrps=true -Dddns=true, \
				$(PKG_INSTALL_DIR_FULL)); \
			$(call BuildVariant, \
				$(PKG_BUILD_DIR)/zig-tmp/zig-x86_64-linux-0.15.2/zig, \
				-Duci=true -Dubus=true -Dfrpc=false -Dfrps=false -Dddns=false, \
				$(PKG_INSTALL_DIR_LITE)); \
		fi; \
	else \
		if [ "$(BUILD_LITE_ONLY)" = "1" ]; then \
			$(call BuildVariant, \
				$(ZIG), \
				-Duci=true -Dubus=true -Dfrpc=false -Dfrps=false -Dddns=false, \
				$(PKG_INSTALL_DIR_LITE)); \
		else \
			$(call BuildVariant, \
				$(ZIG), \
				-Duci=true -Dubus=true -Dfrpc=true -Dfrps=true -Dddns=true, \
				$(PKG_INSTALL_DIR_FULL)); \
			$(call BuildVariant, \
				$(ZIG), \
				-Duci=true -Dubus=true -Dfrpc=false -Dfrps=false -Dddns=false, \
				$(PKG_INSTALL_DIR_LITE)); \
		fi; \
	fi
endef

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

$(eval $(call BuildPackage,portweaver))
$(eval $(call BuildPackage,portweaver-lite))
