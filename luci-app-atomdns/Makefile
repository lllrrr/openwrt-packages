include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-atomdns
PKG_VERSION:=0.7.1
PKG_RELEASE:=1
PKG_LICENSE:=GPL-3.0-only
PKG_MAINTAINER:=NetForgeCN <lonelysoul@users.noreply.github.com>
PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)-$(PKG_VERSION)

# ---------------------------------------------------------------------------
# AtomDNS 主程序打包（原独立 atomdns 包已并入本包，装一个 ipk 即全部功能）
# 官方发布包：https://github.com/jasonxtt/atomdns/releases/tag/v$(PKG_VERSION)
# 直接用 musl 静态二进制，避免在 OpenWrt 上自建 Rust 工具链。
# 版本与各 HASH 由 scripts/bump.py 每日检测上游 release 后自动更新；
# 构建时仍由 OpenWrt 下载框架强制校验 SHA256，并在 Build/Prepare 检查归档路径。
# ---------------------------------------------------------------------------
ATOMDNS_RELEASE_URL:=https://github.com/jasonxtt/atomdns/releases/download/v$(PKG_VERSION)
ATOMDNS_CONF_FILE:=config_rust.zip
ATOMDNS_CONF_HASH:=4a610c1477571f11dd0136ac9738cdbcc33050d125a9ad20d0a2ac8adc9a4868

# 按架构选择二进制变体：x86_64 / arm64 / armv7（官方仅提供这三个 musl 静态版）
# 注：官方 amd64-v3 是 glibc 动态链接，与 OpenWrt 的 musl 环境不兼容，故不用。
# 不支持的架构（mips / armv5 / armv6 等）在编译阶段直接报错，避免静默打入错误二进制。
ATOMDNS_ARCH_UNSUPPORTED:=0

ifeq ($(ARCH),x86_64)
  ATOMDNS_BIN_VARIANT:=amd64-musl
  ATOMDNS_BIN_HASH:=d61b4dcccc55e8292044ba22d912a592f380866ca7df1147693af948f6a2afe5
else ifneq ($(filter aarch64%,$(ARCH)),)
  ATOMDNS_BIN_VARIANT:=arm64
  ATOMDNS_BIN_HASH:=22e7b8f3ee7d3568b5c0da832ff00c454ec1102a37b6e70194366d2a6ef1dc8e
else ifneq ($(filter arm%,$(ARCH)),)
  ATOMDNS_BIN_VARIANT:=armv7
  ATOMDNS_BIN_HASH:=cfa33def5aeedfc064e306320ecf5ce48fb9b773dc3a19dcf8cfbe647c13a239
  # 官方 armv7 包要求 ARMv7 指令集，armv5/armv6 目标（如 BCM2835、ARM926）跑不了
  ifneq ($(filter arm_arm1176jzf-s_vfp arm_arm1136jf-s arm_arm926ej-s arm_xscale arm_fa526,$(CPU_TYPE)),)
    ATOMDNS_ARCH_UNSUPPORTED:=1
  endif
else
  # 占位值仅用于让 download 阶段可解析；实际编译会在 Build/Prepare 中止
  ATOMDNS_ARCH_UNSUPPORTED:=1
  ATOMDNS_BIN_VARIANT:=amd64-musl
  ATOMDNS_BIN_HASH:=d61b4dcccc55e8292044ba22d912a592f380866ca7df1147693af948f6a2afe5
endif

ATOMDNS_BIN_FILE:=atomdns-linux-$(ATOMDNS_BIN_VARIANT).tar.gz

# 两个下载源交给 OpenWrt 下载框架（HASH 由 download.pl 在下载时校验）。
#
# 这里只「定义」数据，千万不要在这里 $(eval $(call Download,...))：
# download.mk 里的 Download 宏此时尚未被 include（它由 package.mk 引入，package.mk 又在
# luci.mk 里），宏未定义时 $(call Download,x) 展开为空串，$(eval ) 等于空操作，
# 结果就是「一条下载规则都没生成」——编译时 prepare 直接 tar 找不到 dl/ 下的文件。
# 真正的 eval 放在文件末尾 include luci.mk 之后。
# 注意：URL 必须写到「目录」，不能写完整文件地址。
# download.pl 内部是 download_cmd("$mirror/$download_filename")，会自己拼上 FILE；
# 若 URL 已经含文件名，实际请求会变成
#   .../atomdns-linux-amd64-musl.tar.gz/atomdns-linux-amd64-musl.tar.gz  → 404
# 这也是官方包里 PKG_SOURCE_URL 一律写目录（文件名由 PKG_SOURCE 提供）的原因。
define Download/atomdns-bin
  FILE:=$(ATOMDNS_BIN_FILE)
  URL:=$(ATOMDNS_RELEASE_URL)
  HASH:=$(ATOMDNS_BIN_HASH)
endef

define Download/atomdns-conf
  FILE:=$(ATOMDNS_CONF_FILE)
  URL:=$(ATOMDNS_RELEASE_URL)
  HASH:=$(ATOMDNS_CONF_HASH)
endef

# LuCI 元数据：主程序已在本包内，不再依赖 +atomdns。
# 本包含架构相关二进制，故 LUCI_PKGARCH 留空（不设 all，走目标架构）。
LUCI_TITLE:=AtomDNS - Rust DNS splitter with WebUI and LuCI control
LUCI_DEPENDS:=+ca-certificates
LUCI_PKGARCH:=

# 以下 define 必须在 include luci.mk 之前：luci.mk 在 include 时会 eval BuildPackage，
# 之后定义的 description / conffiles / Build/Prepare 钩子都不会被读取。
# 唯一例外是 Download/xxx：数据可以写在这里，但 $(eval $(call Download,...)) 必须放到
# include luci.mk 之后（见文件末尾），因为 Download 宏和 $(STAMP_PREPARED) 都还没定义。
define Package/$(PKG_NAME)/description
 AtomDNS 是 MosDNS 的 Rust 重写版，单静态二进制，支持国内外 DNS 分流、FakeIP、
 路由学习、乐观缓存、DoH/DoT、SRS/geosite 规则与内置 WebUI。
 本包整合主程序二进制、默认配置、WebUI 与 LuCI 控制面板，装一个 ipk 即可用。
 默认 DNS 监听 2053（避开 dnsmasq 的 53）、WebUI 9099，安装后默认不启用。
endef

define Package/$(PKG_NAME)/conffiles
/etc/config/atomdns
endef

# 钩子名写死为包名：LUCI_NAME 要到 include luci.mk 时才定义，此处用 $(LUCI_NAME) 会展开为空。
# luci.mk 的 Build/Prepare 在复制完 root/ 后调用本钩子（luci.mk line 213），
# 借此把官方二进制与配置包解压进打包路径，随后由 luci.mk 的 install 统一安装。
define Build/Prepare/luci-app-atomdns
	$(if $(filter 1,$(ATOMDNS_ARCH_UNSUPPORTED)),$(error luci-app-atomdns: 不支持的架构 ARCH=$(ARCH) CPU_TYPE=$(CPU_TYPE)，官方仅提供 x86_64 / arm64 / armv7 的 musl 静态二进制),)
	@bin_entries="$$($(TAR) -tzf $(DL_DIR)/$(ATOMDNS_BIN_FILE))" || exit 1; \
	if echo "$$bin_entries" | grep -Eq '(^|/)\.\.(/|$$)|^/'; then \
		echo "luci-app-atomdns: unsafe path in binary archive" >&2; exit 1; \
	fi
	@conf_entries="$$(unzip -Z1 $(DL_DIR)/$(ATOMDNS_CONF_FILE))" || exit 1; \
	if echo "$$conf_entries" | grep -Eq '(^|/)\.\.(/|$$)|^/|[A-Za-z]:[\\/]'; then \
		echo "luci-app-atomdns: unsafe path in config archive" >&2; exit 1; \
	fi
	$(INSTALL_DIR) $(PKG_BUILD_DIR)/root/usr/bin || exit 1
	$(INSTALL_DIR) $(PKG_BUILD_DIR)/root/usr/share/atomdns || exit 1
	$(TAR) -xzf $(DL_DIR)/$(ATOMDNS_BIN_FILE) -C $(PKG_BUILD_DIR)/root/usr/bin || exit 1
	(cd $(PKG_BUILD_DIR)/root/usr/share/atomdns && unzip -oq $(DL_DIR)/$(ATOMDNS_CONF_FILE)) || exit 1
	chmod 0755 $(PKG_BUILD_DIR)/root/usr/bin/atomdns || exit 1
	# 脚本可执行位兜底：经 GitHub API 推送的脚本会被压成 644，打包阶段纠正
	chmod 0755 $(PKG_BUILD_DIR)/root/etc/init.d/atomdns || exit 1
	chmod 0755 $(PKG_BUILD_DIR)/root/etc/uci-defaults/99-atomdns || exit 1
	chmod 0755 $(PKG_BUILD_DIR)/root/usr/libexec/rpcd/atomdns || exit 1
endef

# luci.mk 会在末尾对 LUCI_BUILD_PACKAGES 执行 BuildPackage，无需再次调用。
include $(TOPDIR)/feeds/luci/luci.mk

# 下载规则必须在这一行之后 eval：
# 1) Download 宏由 download.mk 定义，download.mk 被 package.mk 引入，package.mk 直到上一行才 include；
# 2) $(DOWNLOAD_RDEP) 展开成 $(STAMP_PREPARED)，该变量同样来自 package.mk。
# 少了这两样，$(call Download,...) 只能生成空依赖。展开后得到
#   $(STAMP_PREPARED): $(DL_DIR)/atomdns-linux-<arch>.tar.gz $(DL_DIR)/config_rust.zip
# compile 就会先下载、再解压。
$(eval $(call Download,atomdns-bin))
$(eval $(call Download,atomdns-conf))

# ---------------------------------------------------------------------------
# 下面这一行「注释」不能删，它不是给人看的说明，而是 buildroot 的扫描标记。
# include/scan.mk 用
#   grep 'call BuildPackage'（还有 Build/DefaultTargets 等）
# 判断某个 Makefile 是否为一个包；扫不到就静默跳过，不进 menuconfig、也不报错。
# 本包的 BuildPackage 在 luci.mk 里 eval，正文中不含该关键字，因此必须手写此行。
# 官方 luci 包的 Makefile 末尾同样有这一行，原因完全相同。
# call BuildPackage - OpenWrt buildroot signature
# ---------------------------------------------------------------------------
