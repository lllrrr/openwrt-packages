# Komari Agent — 服务器监控探针
# Go 源码编译，golang-package.mk 自动适配目标架构

include $(TOPDIR)/rules.mk

PKG_NAME    := komari
PKG_VERSION := 1.1.93
PKG_RELEASE := 1

# codeload tar.gz — repo 名 komari-agent ≠ PKG_NAME komari
PKG_SOURCE:=komari-agent-$(PKG_VERSION).tar.gz
PKG_SOURCE_URL:=https://codeload.github.com/komari-monitor/komari-agent/tar.gz/$(PKG_VERSION)?
PKG_HASH:=89831e468f3297ad2d4268587a717b1ea99dcc0530dea1bb26d605aada29f80d
PKG_BUILD_DIR:=$(BUILD_DIR)/komari-agent-$(PKG_VERSION)

PKG_MAINTAINER := Komari <https://github.com/komari-monitor/komari-agent>
PKG_LICENSE    := GPL-3.0-or-later

# Go 编译依赖
PKG_BUILD_DEPENDS:=golang/host
PKG_BUILD_PARALLEL:=1
PKG_BUILD_FLAGS:=no-mips16

GO_PKG:=github.com/komari-monitor/komari-agent
GO_PKG_LDFLAGS_X:=\
	$(GO_PKG)/update.CurrentVersion=$(PKG_VERSION)

include $(INCLUDE_DIR)/package.mk
include $(TOPDIR)/feeds/packages/lang/golang/golang-package.mk

define Package/komari
  SECTION   := net
  CATEGORY  := Network
  SUBMENU   := Web Servers/Proxies
  TITLE     := Komari Agent（服务器监控探针）
  DEPENDS   := $(GO_ARCH_DEPENDS)
endef

define Package/komari/description
  Komari 轻量化自托管服务器监控探针。

  安装后将自动上报系统状态至远程 Komari 面板。
  支持 WebSocket/WSS、GPU 监控、Cloudflare Access。
endef

define Package/komari/install
	$(call GoPackage/Package/Install/Bin,$(PKG_INSTALL_DIR))
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_INSTALL_DIR)/usr/bin/komari-agent $(1)/usr/bin/

	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/komari.init $(1)/etc/init.d/komari

	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/komari.uci $(1)/etc/config/komari
endef

define Package/komari/postinst
#!/bin/sh
[ -z "$${IPKG_INSTROOT}" ] && [ -x /etc/init.d/komari ] && \
	/etc/init.d/komari enable 2>/dev/null || true
exit 0
endef

define Package/komari/prerm
#!/bin/sh
[ -z "$${IPKG_INSTROOT}" ] && [ -x /etc/init.d/komari ] && {
	/etc/init.d/komari stop    2>/dev/null || true
	/etc/init.d/komari disable 2>/dev/null || true
}
exit 0
endef

$(eval $(call BuildPackage,komari))
