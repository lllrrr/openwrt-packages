include $(TOPDIR)/rules.mk

PKG_NAME:=bandix-plus
PKG_VERSION:=0.1.0
PKG_RELEASE:=1

PKG_LICENSE:=Apache-2.0
PKG_MAINTAINER:=timsaya

include $(INCLUDE_DIR)/package.mk

# 使用OpenWrt的Rust映射机制
include $(TOPDIR)/feeds/packages/lang/rust/rust-values.mk

# 二进制文件的文件名和URL
RUST_BANDIX_PLUS_VERSION:=0.1.0
RUST_BINARY_FILENAME:=bandix-plus-$(RUST_BANDIX_PLUS_VERSION)-$(RUSTC_TARGET_ARCH).tar.gz


# 修正下载地址定义方式
PKG_SOURCE:=$(RUST_BINARY_FILENAME)
PKG_SOURCE_URL:=https://github.com/timsaya/bandix-plus/releases/download/v$(RUST_BANDIX_PLUS_VERSION)

# 修正二进制文件校验值
ifeq ($(ARCH),aarch64)
	PKG_HASH:=89c866d63f26b516d77c545df20b6d6a5ff08e8f41dc915336c1d5dad339ae5d
else ifeq ($(ARCH),arm) # update.sh skip this tag, do not delete this comment
	# Ref https://github.com/openwrt/packages/blob/master/lang/rust/rust-values.mk

	ARM_CPU_TYPE:=arm-armel
	ifeq ($(CONFIG_arm_v6)$(CONFIG_arm_v7),)
		ARM_CPU_TYPE:=$(subst arm-,armv5te-,$(ARM_CPU_TYPE))
	else ifeq ($(CONFIG_arm_v7),y)
		ARM_CPU_TYPE:=$(subst arm-,armv7-,$(ARM_CPU_TYPE))
	endif

	ifeq ($(CONFIG_HAS_FPU),y)
		ARM_CPU_TYPE:=$(subst -armel,-armhf,$(ARM_CPU_TYPE))
	endif

	ifeq ($(ARM_CPU_TYPE),arm-armel)
		PKG_HASH:=357902f5e8b2ca53af4388a5b2cf9e5d442e044f41a159801146d56bfc2f73f7
	else ifeq ($(ARM_CPU_TYPE),arm-armhf)
		PKG_HASH:=def390d304b4acbf41731d4e5522c4640bd6d66a409d7d87becf1016b2ad35c6
	else ifeq ($(ARM_CPU_TYPE),armv5te-armel)
		PKG_HASH:=1776c21e8bf2c662269d07f5509ae625315d13ee356273eb5c8ec32854194f3c
	else ifeq ($(ARM_CPU_TYPE),armv7-armel)
		PKG_HASH:=d970055fd2fdaff9440e0696aaeed6970ab6f8667284fb9c656da782769906f1
	else ifeq ($(ARM_CPU_TYPE),armv7-armhf)
		PKG_HASH:=280b2f379e526206b4bd45a3083bfe90572e7516bb2a4a1e6b45f764ae72322f
	else
		PKG_HASH:=dummy
	endif
else ifeq ($(ARCH),mips)
	PKG_HASH:=ab014bd19829c8b42b63091c41e8d1113b945dbec6b7c9f5b59ff6b3308a96ff
else ifeq ($(ARCH),mipsel)
	PKG_HASH:=7f3fcddedcb91607f552b4e892ccdbafbd12438af0ad3f036e78467eca8c4249
else ifeq ($(ARCH),powerpc64)
	PKG_HASH:=5ad8d9b419371a18388d6c4a14e77533b3ffb055ddeb405b355d4ce07ce8d487
else ifeq ($(ARCH),riscv64)
	PKG_HASH:=ca3649865edf0f2c11f757ecdfbd6ca66348dd97e6e74ea9a5228c9c9d8d433a
else ifeq ($(ARCH),x86_64)
	PKG_HASH:=a64bd3acf0ca145216e904c273d0685f3b7bad3e33349f8f4250c0aed87e6786
else
	PKG_HASH:=dummy
endif

define Package/$(PKG_NAME)
	SECTION:=net
	CATEGORY:=Network
	TITLE:=Bandix Plus - Network traffic monitoring tool
	DEPENDS:=+zoneinfo-all +conntrack +iw
endef

define Package/$(PKG_NAME)/description
	Bandix Plus core service for network traffic monitoring
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)/bin
	gzip -dc "$(DL_DIR)/$(PKG_SOURCE)" | tar -C $(PKG_BUILD_DIR)/bin --strip-components=1 -xf -
	$(Build/Patch)
endef

define Build/Compile
	# nothing to do
endef

define Package/$(PKG_NAME)/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/bin/bandix-plus $(1)/usr/bin/

	# 添加启动脚本和配置文件
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_BIN) ./files/bandix-plus.init $(1)/etc/init.d/bandix-plus

	# 安装配置文件
	$(INSTALL_DIR) $(1)/usr/share/bandix-plus
	$(INSTALL_CONF) ./files/bandix-plus.config $(1)/etc/config/bandix-plus
	
	# 配置 sysupgrade 保留列表
	$(INSTALL_DIR) $(1)/lib/upgrade/keep.d
	$(INSTALL_DATA) ./files/bandix-plus.keep $(1)/lib/upgrade/keep.d/bandix-plus
endef

define Package/$(PKG_NAME)/conffiles
/etc/config/bandix-plus
endef

$(eval $(call BuildPackage,bandix-plus))