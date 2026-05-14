# SPDX-License-Identifier: MIT
#
# Sheep — Shadowsocks-Rust Server
# 从 GitHub Releases 按目标架构下载预编译 musl 静态二进制

include $(TOPDIR)/rules.mk
include $(INCLUDE_DIR)/package.mk

PKG_NAME    := sheep
PKG_VERSION := 1.24.0
PKG_RELEASE := 1

PKG_LICENSE    := MIT
PKG_MAINTAINER := Pi <pi@example.com>

# ── 架构映射：OpenWrt ARCH → Rust musl target triple ────────────────
# 注意：此处不使用 $(error)，避免包扫描阶段（ARCH 为空）导致包无法加载。
# 不支持的架构在 Build/Prepare 的 Shell 脚本中报错。
ifeq ($(ARCH),x86_64)
  SS_TARGET := x86_64-unknown-linux-musl
else ifeq ($(ARCH),aarch64)
  SS_TARGET := aarch64-unknown-linux-musl
else ifeq ($(ARCH),arm)
  ifneq ($(CONFIG_arm_v7),)
    SS_TARGET := armv7-unknown-linux-musleabihf
  else ifneq ($(CONFIG_HAS_FPU),)
    SS_TARGET := arm-unknown-linux-musleabihf
  else
    SS_TARGET := arm-unknown-linux-musleabi
  endif
else ifeq ($(ARCH),i386)
  SS_TARGET := i686-unknown-linux-musl
else ifeq ($(ARCH),mipsel)
  SS_TARGET := mipsel-unknown-linux-musl
else ifeq ($(ARCH),mips)
  SS_TARGET := mips-unknown-linux-musl
else
  SS_TARGET :=
endif

SS_TARBALL  := shadowsocks-v$(PKG_VERSION).$(SS_TARGET).tar.xz
SS_DL_URL   := https://github.com/shadowsocks/shadowsocks-rust/releases/download/v$(PKG_VERSION)/$(SS_TARBALL)

define Package/sheep
  SECTION   := net
  CATEGORY  := Network
  TITLE     := Sheep (Shadowsocks-Rust Server)
  URL       := https://github.com/shadowsocks/shadowsocks-rust
  DEPENDS   :=
endef

define Package/sheep/description
  Shadowsocks-Rust ssserver，从 GitHub Releases 下载 musl 静态二进制。
endef

define Package/sheep/conffiles
/etc/config/sheep
/etc/shadowsocks-rust/config.json
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	# 构建期架构检查（$(error) 在解析期会阻止包被发现，故在此处检查）
	[ -n "$(SS_TARGET)" ] || { \
		echo "Sheep: 不支持的架构 $(ARCH)，支持：x86_64 aarch64 arm i386 mipsel mips" >&2; \
		exit 1; \
	}
	# 下载 tarball（已缓存则跳过）
	if [ ! -f "$(DL_DIR)/$(SS_TARBALL)" ]; then \
		echo "Sheep: 下载 $(SS_DL_URL)"; \
		curl -fsSL --retry 3 \
			-o "$(DL_DIR)/$(SS_TARBALL).tmp" \
			"$(SS_DL_URL)" \
		&& mv "$(DL_DIR)/$(SS_TARBALL).tmp" "$(DL_DIR)/$(SS_TARBALL)"; \
	fi
	# 解压 tarball（ssserver 直接落在 PKG_BUILD_DIR 根目录）
	tar -xJf "$(DL_DIR)/$(SS_TARBALL)" -C "$(PKG_BUILD_DIR)"
	# 改名为 sheep
	mv "$(PKG_BUILD_DIR)/ssserver" "$(PKG_BUILD_DIR)/sheep"
endef

define Build/Compile
endef

define Package/sheep/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/sheep $(1)/usr/bin/sheep

	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) $(CURDIR)/files/sheep.init $(1)/etc/init.d/sheep

	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) $(CURDIR)/files/sheep.config $(1)/etc/config/sheep

	$(INSTALL_DIR) $(1)/etc/shadowsocks-rust
	$(INSTALL_CONF) $(CURDIR)/files/ss-server.json $(1)/etc/shadowsocks-rust/config.json

	$(INSTALL_DIR) $(1)/usr/libexec
	$(INSTALL_BIN) $(CURDIR)/files/sheep-ctrl.sh $(1)/usr/libexec/sheep-ctrl.sh
endef

define Package/sheep/postinst
#!/bin/sh
exit 0
endef

define Package/sheep/prerm
#!/bin/sh
[ -z "$${IPKG_INSTROOT}" ] && {
	[ -x /etc/init.d/sheep ] && {
		/etc/init.d/sheep stop    2>/dev/null || true
		/etc/init.d/sheep disable 2>/dev/null || true
	}
}
exit 0
endef

$(eval $(call BuildPackage,sheep))
