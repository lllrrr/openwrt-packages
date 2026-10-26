#
# Copyright (C) 2026 luci-app-smartmwan contributors
#
# This is free software, licensed under the GNU General Public License v2.
# See /LICENSE for more information.
#
# luci-app-smartmwan —— OpenWrt/ImmortalWrt 25.12+ 多 WAN 智能选路
#
# 打包说明（M9）：
#   * 本 SDK（25.12 apk 时代）的 include/ 下**没有** rust-package.mk，
#     因此按研究笔记的兜底方案自建交叉编译：直接用 host 的 cargo，
#     目标三元组由 SDK 的 CONFIG_ARCH + LIBC 推导，未知组合**直接报错**，
#     不静默按宿主机三元组构建（那会产出跑不了的二进制）；
#   * 两个安装期文件由**刚编好的二进制**生成，保证与代码同源：
#       /etc/config/smartmwan      ← smartmwand --dump-defaults
#       /usr/share/nftables.d/ruleset-post/smartmwan.nft ← smartmwand --dump-include
#     仓库 root/ 下的同名文件只是评审快照，安装时被覆盖；
#   * 依赖声明从**产物**推导（readelf -d 见 docs/TESTING.md）：
#     Rust musl 静态二进制无 soname 依赖，DEPENDS 里写的是**功能**依赖；
#   * 绝不声明任何 Lua 运行时包（禁 Lua 扫描脚本按关键字拦截，注释里也不能出现）。
#

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-smartmwan
PKG_VERSION:=0.4.0
PKG_RELEASE:=1
PKG_LICENSE:=GPL-3.0-or-later
PKG_LICENSE_FILES:=LICENSE

PKG_MAINTAINER:=luci-app-smartmwan contributors

PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)-$(PKG_VERSION)

include $(INCLUDE_DIR)/package.mk

# ---- Rust 目标三元组：由 SDK 架构 + libc 推导，未知组合直接失败 ----
# 已验证：本 SDK（mediatek/filogic, gcc 14.4.0 musl）→ aarch64-unknown-linux-musl。
# 新增目标必须在真实 SDK 里构建验证后在此登记（research/buildsystem.md §6）。
#
# 注意：包上下文里 kconfig 变量带引号（CONFIG_ARCH=\"aarch64\"），必须先剥掉，
# 否则 ifeq 永远不命中 —— 本 SDK 首次构建时就踩了这个坑。
ARCH:=$(patsubst "%",%,$(CONFIG_ARCH))
LIBC_NAME:=$(patsubst "%",%,$(LIBC))

ifeq ($(ARCH),aarch64)
  ifeq ($(LIBC_NAME),musl)
    RUST_TARGET:=aarch64-unknown-linux-musl
  else
    RUST_TARGET:=aarch64-unknown-linux-gnu
  endif
else ifeq ($(ARCH),x86_64)
  ifeq ($(LIBC_NAME),musl)
    RUST_TARGET:=x86_64-unknown-linux-musl
  else
    RUST_TARGET:=x86_64-unknown-linux-gnu
  endif
else ifeq ($(ARCH),arm)
  ifeq ($(CONFIG_EABI),y)
    RUST_TARGET:=arm-unknown-linux-musleabi
  else
    RUST_TARGET:=armv7-unknown-linux-musleabihf
  endif
else
  # 内层 make（OpenWrt 的 .compile 就绪检查）会脱离 kconfig 上下文重新解析本文件，
  # 此时 CONFIG_ARCH/LIBC 均为空。**不能在这里静默回落宿主机三元组** ——
  # 那会产出跑不了的 x86_64 二进制。留空，让真正执行构建的配方自行报错；
  # 顶层 make（recipe 展开处）上下文齐全，推导正常。
  RUST_TARGET:=
endif

# cargo 变量名的 make  escaping：aarch64-unknown-linux-musl → AARCH64_UNKNOWN_LINUX_MUSL
RUST_TARGET_UPPER:=$(subst -,_,$(toupper $(RUST_TARGET)))

# 构建机要求：host 上有 cargo，且 `rustup target list --installed` 含 $(RUST_TARGET)。
CARGO?=cargo

define Package/luci-app-smartmwan
  SECTION:=luci
  CATEGORY:=LuCI
  TITLE:=Multi-WAN smart routing (Rust daemon + LuCI JS, zero Lua)
  URL:=https://github.com/LianXia233/luci-app-smartmwan
  DEPENDS:=+firewall4 +nftables +luci-base +rpcd +ucode-mod-socket
  # 功能依赖说明：
  #   firewall4/nftables —— nft 可执行文件与 fw4 的自动片段 include 机制；
  #   luci-base          —— 25.12 的 LuCI 运行时（视图与 rpcd 桥的宿主）；
  #   rpcd               —— ucode 桥的宿主。**不含任何 Lua 包**；
  #   ucode-mod-socket   —— ucode 桥连守护进程 Unix socket 必需。真机实证
  #                         （ImmortalWrt SNAPSHOT）：该模块是**独立包**，基础
  #                         ucode/rpcd 都不带；缺了它 rpcd 加载插件直接抛
  #                         「No module named 'socket'」，ubus 对象无法注册。
  # 二进制本身是 musl 静态链接（readelf -d 无 NEEDED），无需 libc 依赖声明。
  PKGARCH:=all
endef

define Package/luci-app-smartmwan/description
  Multi-WAN policy routing with health probing, balancing/failover and game
  routing. Backend is a Rust daemon (smartmwand), frontend is native LuCI
  JavaScript bridged through an rpcd ucode plugin. No Lua anywhere.

  Safety defaults: enabled=0 on first install — the plugin never changes
  existing routing until explicitly enabled. It only ever touches its own
  objects: ip rules in the 1000-1023 priority band, routing tables 101-124,
  and the "inet smw" nftables table.
endef

define Package/luci-app-smartmwan/conffiles
/etc/config/smartmwan
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) ./src $(PKG_BUILD_DIR)/
	$(CP) ./Cargo.toml ./Cargo.lock $(PKG_BUILD_DIR)/
	$(CP) ./LICENSE $(PKG_BUILD_DIR)/
endef

define Build/Compile
	@test -n "$(RUST_TARGET)" || { echo "ERROR: RUST_TARGET 为空 —— 构建上下文缺少 SDK 架构信息（CONFIG_ARCH/LIBC），拒绝构建"; exit 1; }
	# 交叉编译：链接器用 SDK 的目标 CC；目标三元组由上面的映射表推导。
	# --offline：Cargo.lock 已锁定版本，构建机用本地 cargo 缓存（无网也可复现）。
	CARGO_TARGET_$(RUST_TARGET_UPPER)_LINKER="$(TARGET_CC)" \
	CARGO_HOME=$(HOME)/.cargo \
	$(CARGO) build --release --offline \
		--target $(RUST_TARGET) \
		--manifest-path $(PKG_BUILD_DIR)/Cargo.toml
endef

define Package/luci-app-smartmwan/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) \
		$(PKG_BUILD_DIR)/target/$(RUST_TARGET)/release/smartmwand \
		$(1)/usr/bin/

	# UCI 默认配置：与代码同源生成（enabled=0，首次安装不改变现有路由）
	$(INSTALL_DIR) $(1)/etc/config
	$(PKG_BUILD_DIR)/target/$(RUST_TARGET)/release/smartmwand --dump-defaults \
		> $(1)/etc/config/smartmwan

	# fw4 自动片段（ruleset-post）：独立表必须在 ruleset **顶层**声明。
	# 真机实证（ImmortalWrt fw4-2025.03.17，Airpi AP3000M）：该固件的 fw4 把
	# /etc/nftables.d/*.nft 用内置 glob include 进 table inet fw4 **表体内部**
	# （fw4 print 第 33 行），独立表片段放那里必然语法错误、fw4 整体拒绝加载；
	# /usr/share/nftables.d/ruleset-post/ 才是顶层位置（fw4 README 载明，
	# miniupnpd 同款机制）。安装期文件与代码同源生成。
	$(INSTALL_DIR) $(1)/usr/share/nftables.d/ruleset-post
	$(PKG_BUILD_DIR)/target/$(RUST_TARGET)/release/smartmwand --dump-include \
		> $(1)/usr/share/nftables.d/ruleset-post/smartmwan.nft

	# procd 服务
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./root/etc/init.d/smartmwan $(1)/etc/init.d/

	# rpcd ucode 桥 + ACL + 菜单
	$(INSTALL_DIR) $(1)/usr/share/rpcd/ucode
	$(INSTALL_DATA) ./root/usr/share/rpcd/ucode/smartmwan.uc $(1)/usr/share/rpcd/ucode/
	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./root/usr/share/rpcd/acl.d/luci-app-smartmwan.json $(1)/usr/share/rpcd/acl.d/
	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DATA) ./root/usr/share/luci/menu.d/luci-app-smartmwan.json $(1)/usr/share/luci/menu.d/

	# LuCI 视图与样式
	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/smartmwan
	$(INSTALL_DATA) ./htdocs/luci-static/resources/view/smartmwan/*.js $(1)/www/luci-static/resources/view/smartmwan/
	$(INSTALL_DIR) $(1)/www/luci-static/resources
	$(INSTALL_DATA) ./htdocs/luci-static/resources/smartmwan.js $(1)/www/luci-static/resources/
	$(INSTALL_DIR) $(1)/www/luci-static/resources/smartmwan
	$(INSTALL_DATA) ./htdocs/luci-static/resources/smartmwan/smartmwan.css $(1)/www/luci-static/resources/smartmwan/

	# 预置项数据目录（用户可编辑；**仓库不内置任何数据文件**）
	$(INSTALL_DIR) $(1)/usr/share/smartmwan/presets
endef

# ---- apk 维护脚本 ----
# define 名按 include/package-pack.mk 的 BuildPackVariable 调用实测（384-388 行）：
#   preinst → pre-install/pre-upgrade；postinst → 拼进 post-install；
#   prerm → 拼进 pre-deinstall；postrm → post-deinstall。
# **不要**自造 post-install / pre-deinstall 这类名字 —— 构建系统只认上面四个，
# 写错的 define 会被静默忽略，apk 里只剩下默认脚本（本项目首次构建就踩了这个坑）。
#
# **本包不需要自定义 postinst/postrm 的 UCI firewall 操纵**（真机实证的教训）：
# nft 占位片段走 /usr/share/nftables.d/ruleset-post/ 自动 include，无 UCI 可加；
# 曾尝试的 UCI include 段方案有两个真缺陷——匿名段导致 `uci get firewall.smartmwan`
# 幂等判断永远落空（升级重复加段、卸载残留），且 position 语义在该 fw4 上不可靠。
# enable/start 由构建系统生成的 default_postinst 完成（它按包名找 /etc/init.d/<name>）。

# 安装/升级前：先停旧实例（若在跑），让守护进程优雅撤销自己的内核对象。
define Package/luci-app-smartmwan/preinst
#!/bin/sh
[ -x /usr/bin/smartmwand ] || exit 0
if [ -x /etc/init.d/smartmwan ]; then
	/etc/init.d/smartmwan stop 2>/dev/null
fi
exit 0
endef

# 卸载前：停服务并撤销内核对象。守护进程的 SIGTERM 处理会做优雅回收；
# 再跑一次性 `--reclaim` 兜底（进程已不在时也能清场）。
# **绝不跑 --once** —— 那会把配置重新装回去。
define Package/luci-app-smartmwan/prerm
#!/bin/sh
[ -x /usr/bin/smartmwand ] || exit 0
if [ -x /etc/init.d/smartmwan ]; then
	/etc/init.d/smartmwan stop 2>/dev/null
	/etc/init.d/smartmwan disable 2>/dev/null
fi
/usr/bin/smartmwand --reclaim --config /etc/config/smartmwan 2>/dev/null
exit 0
endef

# 卸载后：清运行期状态文件。占位片段（在 /usr/share/nftables.d/ruleset-post/）
# 由 apk 随包删除；**不删 /etc/config/smartmwan**（用户配置归 conffiles）。
define Package/luci-app-smartmwan/postrm
#!/bin/sh
rm -rf /var/run/smartmwan /tmp/run/smartmwan 2>/dev/null
exit 0
endef

$(eval $(call BuildPackage,luci-app-smartmwan))
