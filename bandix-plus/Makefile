include $(TOPDIR)/rules.mk

PKG_NAME:=bandix-plus
PKG_VERSION:=0.1.1
PKG_RELEASE:=1

PKG_LICENSE:=Apache-2.0
PKG_MAINTAINER:=timsaya

include $(INCLUDE_DIR)/package.mk

# 使用OpenWrt的Rust映射机制
include $(TOPDIR)/feeds/packages/lang/rust/rust-values.mk

# 二进制文件的文件名和URL
RUST_BANDIX_PLUS_VERSION:=0.1.1
RUST_BINARY_FILENAME:=bandix-plus-$(RUST_BANDIX_PLUS_VERSION)-$(RUSTC_TARGET_ARCH).tar.gz


# 修正下载地址定义方式
PKG_SOURCE:=$(RUST_BINARY_FILENAME)
PKG_SOURCE_URL:=https://github.com/timsaya/bandix-plus/releases/download/v$(RUST_BANDIX_PLUS_VERSION)

# 修正二进制文件校验值
ifeq ($(ARCH),aarch64)
	PKG_HASH:=f01067b831fdc911fc178d21f846050da4efe4555303f588c0b55d4d241c94f6
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
		PKG_HASH:=1992636069d2e70ddd26ecb16c67f6fe97c736e37d11fc5205e5191554a454d8
	else ifeq ($(ARM_CPU_TYPE),arm-armhf)
		PKG_HASH:=c26c31af86745ed13bc1b7372daf65bf21cce89d4e44826ac030641184f1b273
	else ifeq ($(ARM_CPU_TYPE),armv5te-armel)
		PKG_HASH:=9b09d6fa994babd90fbc43c89ef230f6e94f48a8dcab03f18ba9f091168705c1
	else ifeq ($(ARM_CPU_TYPE),armv7-armel)
		PKG_HASH:=a010e987deb953193740345a1e8552a0e38f9a7be9e8bf985e42181955f5bf98
	else ifeq ($(ARM_CPU_TYPE),armv7-armhf)
		PKG_HASH:=6bd67684596cca82f956785a632f855903681fd5dcd00df90caac6d5cf248309
	else
		PKG_HASH:=dummy
	endif
else ifeq ($(ARCH),mips)
	PKG_HASH:=1ca78937bf61406a8ba6be80738ac13bbf7dfeb7a239661cd28a19f4701df194
else ifeq ($(ARCH),mipsel)
	PKG_HASH:=1bdeaefddf57daf3f56bd47fb935e963c1d2e017e23d9cf4ff6e5ea40b890c65
else ifeq ($(ARCH),powerpc64)
	PKG_HASH:=bcb71b9f866bc132c35cf09100b3a634383f6dd2707f485b878f7327609e373a
else ifeq ($(ARCH),riscv64)
	PKG_HASH:=47aa992e9e63b6fbd69d48d39dadad0a815ed79f753f413e53452163d5453477
else ifeq ($(ARCH),x86_64)
	PKG_HASH:=70cfe6704060269dd285aa12e5fee11784c69ec047b763e9dcc1b48b1603120d
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

	# 安装 UCI defaults（仅补齐缺失配置项，不覆盖用户已有值）
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/99-bandix-plus-defaults $(1)/etc/uci-defaults/99-bandix-plus-defaults
	
	# 配置 sysupgrade 保留列表
	$(INSTALL_DIR) $(1)/lib/upgrade/keep.d
	$(INSTALL_DATA) ./files/bandix-plus.keep $(1)/lib/upgrade/keep.d/bandix-plus
endef

define Package/$(PKG_NAME)/conffiles
/etc/config/bandix-plus
endef

define Package/$(PKG_NAME)/postinst
#!/bin/sh
[ -n "$$IPKG_INSTROOT" ] && exit 0

DEFAULTS_SCRIPT="/etc/uci-defaults/99-bandix-plus-defaults"
if [ -x "$$DEFAULTS_SCRIPT" ]; then
	"$$DEFAULTS_SCRIPT" && rm -f "$$DEFAULTS_SCRIPT"
fi

exit 0
endef

$(eval $(call BuildPackage,bandix-plus))
