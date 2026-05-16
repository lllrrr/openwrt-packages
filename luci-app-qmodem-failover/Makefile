# ==============================================================
# luci-app-qmodem-failover - OpenWrt Package Makefile
# 支持: feeds 拉源码编译进固件 / 单独编译 ipk / 跨平台 all-arch
# ==============================================================

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-qmodem-failover
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

# ── feeds/源码方式引用 ──
# 当本包加入 feeds.conf 后，构建系统从此处拉取源码。
# 本地开发（直接放入 package/ 目录）时这几行不起作用，保留无害。
# PKG_SOURCE_PROTO:=git
# PKG_SOURCE_URL:=https://github.com/YOUR_GITHUB/luci-app-qmodem-failover.git
# PKG_SOURCE_VERSION:=HEAD
# PKG_MIRROR_HASH:=skip

# 纯 Shell + Lua 脚本，架构无关，一个 ipk 通用所有 CPU 平台
PKGARCH:=all

PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)

include $(INCLUDE_DIR)/package.mk

# ==============================================================
# 包描述
# ==============================================================
define Package/luci-app-qmodem-failover
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=QMODEM Failover - 有线故障自动切换移动网络
  DEPENDS:=+luci-base \
           +kmod-usb-net \
           +kmod-usb-net-rndis \
           +kmod-usb-net-cdc-ether \
           +uci \
           +curl \
           +ip-full \
           +ubus
  PKGARCH:=all
  URL:=https://github.com/YOUR_GITHUB/luci-app-qmodem-failover
  MAINTAINER:=YOUR_NAME <your@email.com>
endef

define Package/luci-app-qmodem-failover/description
  Automatically switches to QMODEM mobile network when wired WAN fails,
  and seamlessly switches back when wired connection is restored.
  Switch completes in under 15 seconds via hot route-metric swap.
  No network restart required.

  当有线 WAN 网络故障时自动切换至 QMODEM 移动网络，恢复后自动切回。
  热修改路由表 metric，切换 < 15s，无需重启网络服务。
  支持 RNDIS / CDC-ECM / PPP 三种 QMODEM 接入模式。
  平台兼容: x86_64 / arm / aarch64 / mipsel / mips64el (PKGARCH=all)
endef

define Package/luci-app-qmodem-failover/conffiles
/etc/config/qmodem_failover
endef

# ==============================================================
# 构建阶段
# ==============================================================
define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) ./src      $(PKG_BUILD_DIR)/
	$(CP) ./luasrc   $(PKG_BUILD_DIR)/
	$(CP) ./htdocs   $(PKG_BUILD_DIR)/
	$(CP) ./po       $(PKG_BUILD_DIR)/
endef

define Build/Compile
	# 编译 .po → .lmo（LuCI 要求的二进制翻译格式）
	# 如果编译环境没有 msgfmt，跳过（安装时会有警告但不影响功能）
	if command -v msgfmt >/dev/null 2>&1; then \
		mkdir -p $(PKG_BUILD_DIR)/po/zh-cn && \
		msgfmt $(PKG_BUILD_DIR)/po/zh-cn/qmodem_failover.po \
		       -o $(PKG_BUILD_DIR)/po/zh-cn/qmodem_failover.zh-cn.lmo 2>/dev/null && \
		echo "i18n: .lmo compiled OK"; \
	else \
		echo "i18n WARNING: msgfmt not found, .lmo skipped"; \
	fi
endef

# ==============================================================
# 安装阶段
# ==============================================================
define Package/luci-app-qmodem-failover/install
	# Shell 核心程序
	$(INSTALL_DIR) $(1)/usr/lib/qmodem-failover
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/src/qmodem-failover.sh \
	               $(1)/usr/lib/qmodem-failover/qmodem-failover.sh
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/src/wan-checker.sh \
	               $(1)/usr/lib/qmodem-failover/wan-checker.sh
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/src/switcher.sh \
	               $(1)/usr/lib/qmodem-failover/switcher.sh
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/src/notify.sh \
	               $(1)/usr/lib/qmodem-failover/notify.sh

	# init.d 服务
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/src/qmodem-failover.init \
	               $(1)/etc/init.d/qmodem-failover

	# 默认 UCI 配置（升级时 conffiles 机制自动保留用户已有配置）
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) $(PKG_BUILD_DIR)/src/qmodem-failover.config \
	                $(1)/etc/config/qmodem_failover

	# LuCI 控制器
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/controller
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/luasrc/controller/qmodem_failover.lua \
	                $(1)/usr/lib/lua/luci/controller/qmodem_failover.lua

	# LuCI CBI 配置模型
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/model/cbi
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/luasrc/model/cbi/qmodem_failover.lua \
	                $(1)/usr/lib/lua/luci/model/cbi/qmodem_failover.lua

	# 前端 JS
	$(INSTALL_DIR) $(1)/htdocs/luci-static/qmodem_failover
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/htdocs/luci-static/qmodem_failover/status.js \
	                $(1)/htdocs/luci-static/qmodem_failover/status.js

	# i18n 翻译 - 安装到 LuCI 标准路径 /usr/share/luci/i18n/*.lmo
	$(INSTALL_DIR) $(1)/usr/share/luci/i18n
	if [ -f $(PKG_BUILD_DIR)/po/zh-cn/qmodem_failover.zh-cn.lmo ]; then \
		$(INSTALL_DATA) $(PKG_BUILD_DIR)/po/zh-cn/qmodem_failover.zh-cn.lmo \
		                $(1)/usr/share/luci/i18n/qmodem_failover.zh-cn.lmo; \
	fi
endef

# 安装后: 启用服务 + 清 LuCI 缓存
define Package/luci-app-qmodem-failover/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
/etc/init.d/qmodem-failover enable  2>/dev/null || true
/etc/init.d/qmodem-failover start   2>/dev/null || true
rm -f /tmp/luci-indexcache /tmp/luci-modulecache* 2>/dev/null || true
exit 0
endef

# 卸载前: 停止并禁用服务
define Package/luci-app-qmodem-failover/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
/etc/init.d/qmodem-failover stop    2>/dev/null || true
/etc/init.d/qmodem-failover disable 2>/dev/null || true
exit 0
endef

$(eval $(call BuildPackage,luci-app-qmodem-failover))

