# 智能分流后台。Go 程序由 scripts/build-packages.sh 预先交叉编译放进 bin/，SDK 只负责打包（ipk / apk）
include $(TOPDIR)/rules.mk

PKG_NAME:=smartroute
PKG_VERSION:=$(or $(SR_VERSION),0.0.0)
PKG_RELEASE:=1
PKG_LICENSE:=Apache-2.0
PKG_LICENSE_FILES:=LICENSE

include $(INCLUDE_DIR)/package.mk

# OpenWrt ARCH → 预编译程序（bin/smartroute-<GOARCH>）
SR_BIN_x86_64:=amd64
SR_BIN_aarch64:=arm64
SR_BIN_arm:=arm
SR_BIN_mipsel:=mipsle
SR_BIN_mips:=mips
SR_BIN_i386:=386
SR_BIN_riscv64:=riscv64
SR_BIN:=$(SR_BIN_$(ARCH))

define Package/smartroute
  SECTION:=net
  CATEGORY:=Network
  TITLE:=Smart traffic steering by device and rule group (eBPF)
  EXTRA_DEPENDS:=ca-bundle (>=0)
endef

define Package/smartroute/description
  智能分流后台：按“设备 × 规则组”把流量改投到网关、直连或拦截，v4 / v6 一起处理。
  数据面为 LAN 口 eBPF，需要内核 6.6 及以上（TCX），不需要 BTF。
endef

define Package/smartroute/conffiles
/etc/config/smartroute
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
endef

define Build/Compile
	$(if $(SR_BIN),,$(error 不支持的架构 $(ARCH)))
endef

define Package/smartroute/install
	$(INSTALL_DIR) $(1)/usr/bin $(1)/etc/config $(1)/etc/init.d $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./bin/smartroute-$(SR_BIN) $(1)/usr/bin/smartroute
	$(INSTALL_CONF) ./files/etc/config/smartroute $(1)/etc/config/
	$(INSTALL_BIN) ./files/etc/init.d/smartroute $(1)/etc/init.d/
	$(INSTALL_DATA) ./files/etc/uci-defaults/90-smartroute $(1)/etc/uci-defaults/
endef

$(eval $(call BuildPackage,smartroute))
