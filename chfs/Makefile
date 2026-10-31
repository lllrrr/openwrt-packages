#
# Copyright (C) 2026 LianXia233
#
# This is free software, licensed under the Apache License, Version 2.0.
#

include $(TOPDIR)/rules.mk

PKG_NAME:=chfs
PKG_VERSION:=3.1
PKG_RELEASE:=1

# ---------------------------------------------------------------------------
# chfs (CuteHttpFileServer) 上游仅提供预编译二进制压缩包, 不发布源码 tarball.
# 下载地址规律 (经官网 http://iscute.cn/chfs 核对):
#   http://iscute.cn/tar/chfs/<version>/chfs-linux-<arch>-<version>.zip
# 包内为单个静态链接可执行文件, 文件名形如 chfs-linux-arm64-3.1 (无扩展名).
#
# 因此本包不执行源码编译, 仅做解压 + 安装二进制.
#
# 【重要】此处必须使用 http:// 而非 https://
#   实测 (2026-09-19) iscute.cn 的 TLS 证书已过期, 使用 https 会在构建时
#   报 "SSL certificate problem: certificate has expired" 导致下载失败.
#   HTTP 协议下证书不参与校验, 下载正常 (实测 HTTP 200).
#
# PKG_HASH 说明:
#   上游未公布各架构二进制的校验值, 且下载包随构建时间变化,
#   故置为 skip. 如需强校验, 请自行下载后在下方逐架构填写 sha256.
# ---------------------------------------------------------------------------

PKG_SOURCE_PROTO:=default
PKG_HASH:=skip


PKG_LICENSE:=Apache-2.0
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=LianXia233

# 纯预编译二进制包, 不参与 OpenWrt 的交叉编译流程
PKG_BUILD_PARALLEL:=1
# 注意: 不可设为 all。包内是可执行二进制, 与目标架构强绑定,
# 标 all 会让不同架构的包在仓库索引中互相覆盖。

include $(INCLUDE_DIR)/package.mk

# ---------------------------------------------------------------------------
# 架构映射: OpenWrt ARCH -> chfs 上游命名
# ---------------------------------------------------------------------------
# OpenWrt ARCH       chfs arch 后缀      说明
# -----------------  ------------------  --------------------------------
# mips               mips                32 位大端        (MT7620/MT7621 常见)
# mipsel             mipsle              32 位小端        (MT7621A 部分机型)
# mips64             mips64              64 位大端
# mips64el           mips64le            64 位小端        (MT798x 常见)
# arm                arm                 armv7 硬浮点
# armeb              arm                 arm 大端, 上游无专门包
# aarch64            arm64               64 位 ARM
# i386              386                 32 位 x86
# x86_64             amd64               64 位 x86
#
# 注: 上游另提供 mipssoftfloat / mips64softfloat 软浮点变体,
#     对应 OpenWrt 的 mips_24kc 软浮点目标, 如遇 SIGILL 可切换.
# ---------------------------------------------------------------------------

CHFS_ARCH:=$(patsubst mipsel,mipsle,$(ARCH))
CHFS_ARCH:=$(patsubst mips64el,mips64le,$(CHFS_ARCH))
CHFS_ARCH:=$(patsubst aarch64,arm64,$(CHFS_ARCH))
CHFS_ARCH:=$(patsubst i386,386,$(CHFS_ARCH))
CHFS_ARCH:=$(patsubst x86_64,amd64,$(CHFS_ARCH))
CHFS_ARCH:=$(patsubst armeb,arm,$(CHFS_ARCH))

PKG_SOURCE:=chfs-linux-$(CHFS_ARCH)-$(PKG_VERSION).zip
PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)-$(PKG_VERSION)

define Package/chfs
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=File Transfer
  TITLE:=CuteHttpFileServer - HTTP 协议的文件共享服务器
  URL:=http://iscute.cn/chfs
  DEPENDS:=@(mips||mipsel||mips64||mips64el||arm||aarch64||i386||x86_64)
endef

define Package/chfs/description
  CuteHttpFileServer (chfs) 是一个免费的、基于 HTTP 协议的文件共享服务器。
  单个二进制文件即可运行, 支持账户权限控制、地址过滤、WebDAV 与 HTTPS, 可通过
  浏览器直接访问与上传下载文件, 适合在路由器上搭建轻量级共享存储。

  本包直接安装上游官方发布的预编译二进制, 不进行源码编译。
endef

# ---------------------------------------------------------------------------
# 二进制来源：优先使用仓库内预置的二进制 (bin/<chfs-arch>/chfs)
#
#   上游 iscute.cn 的 TLS 证书已过期，且站点可用性不可控，
#   云编译不应依赖实时下载。故各架构二进制预先入库，
#   仅当本地缺失时才回退到上游下载。
#   更新入库二进制：运行 tools/fetch-chfs.py
#
# 【重要】不能通过设置 PKG_SKIP_DOWNLOAD 来跳过下载。
#   include/package.mk 第 14 行会无条件覆盖它：
#     PKG_SKIP_DOWNLOAD=$(USE_SOURCE_DIR)$(USE_GIT_TREE)$(USE_GIT_SRC_CHECKOUT)
#   而下载判定在 Build/DefaultTargets（package.mk 第 295 行）：
#     $(if $(PKG_SKIP_DOWNLOAD),,$(if $(strip $(PKG_SOURCE_URL)),$(call Download,default)))
#   因此唯一可靠的跳过方式是：本地有二进制时把 PKG_SOURCE_URL 置空。
# ---------------------------------------------------------------------------
CHFS_LOCAL_BIN:=$(CURDIR)/bin/$(CHFS_ARCH)/chfs

# 用 $(shell) 而非 $(wildcard)：确保在 ARCH 展开后再判定。
CHFS_HAVE_LOCAL:=$(shell test -s "$(CHFS_LOCAL_BIN)" && echo 1)

ifeq ($(CHFS_HAVE_LOCAL),1)
  # 本地已预置该架构二进制 -> 置空 URL，构建系统不会尝试下载
  PKG_SOURCE_URL:=
else
  PKG_SOURCE_URL:=http://iscute.cn/tar/chfs/$(PKG_VERSION)
endif

define Build/Prepare
	rm -rf $(PKG_BUILD_DIR)
	mkdir -p $(PKG_BUILD_DIR)
	if [ -s "$(CHFS_LOCAL_BIN)" ]; then \
		echo "chfs: 使用仓库内预置二进制 $(CHFS_ARCH)"; \
		$(INSTALL_BIN) $(CHFS_LOCAL_BIN) $(PKG_BUILD_DIR)/chfs-bin; \
	else \
		echo "chfs: 本地无 $(CHFS_ARCH) 二进制, 回退上游下载"; \
		$(CP) $(DL_DIR)/$(PKG_SOURCE) $(PKG_BUILD_DIR)/; \
		cd $(PKG_BUILD_DIR) && unzip -o -q $(PKG_SOURCE); \
		sh $(CURDIR)/extract-bin.sh $(PKG_BUILD_DIR); \
	fi
	@test -s $(PKG_BUILD_DIR)/chfs-bin || { echo "ERROR: chfs-bin 提取失败"; exit 1; }
	@echo "chfs: 架构 $(ARCH) -> 上游 $(CHFS_ARCH), 二进制大小 $$(stat -c%s $(PKG_BUILD_DIR)/chfs-bin) 字节"
endef


define Build/Compile
	# 预编译二进制包, 无需编译
endef

define Package/chfs/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/chfs-bin $(1)/usr/bin/chfs
endef

$(eval $(call BuildPackage,chfs))
