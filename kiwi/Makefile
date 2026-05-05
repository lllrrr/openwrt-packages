# SPDX-License-Identifier: GPL-3.0-or-later
#
# Kiwi — 高性能 DNS 转发器（基于 kixdns）
# 方案：下载 qaz69s/kixdns Release 预编译 musl static binary

include $(TOPDIR)/rules.mk
include $(INCLUDE_DIR)/package.mk

PKG_NAME    := kiwi
PKG_VERSION := 0.1.0
PKG_RELEASE := 1

PKG_LICENSE    := GPL-3.0
PKG_MAINTAINER := Pi <pi@example.com>

BINARY_NAME := kixdns-v$(PKG_VERSION)-x86_64-unknown-linux-musl
BINARY_URL  := https://github.com/qaz69s/kixdns/releases/download/v$(PKG_VERSION)/
BINARY_DL   := $(TOPDIR)/dl/$(BINARY_NAME)

define Download/kiwi
  FILE:=$(BINARY_NAME)
  URL:=$(BINARY_URL)
  HASH:=skip
  MIRROR_HASH:=skip
endef
$(eval $(call Download,kiwi))

define Package/kiwi
  SECTION   := net
  CATEGORY  := Network
  SUBMENU   := IP Addresses and Names
  TITLE     := Kiwi DNS 转发器
endef

define Package/kiwi/description
  Kiwi — 高性能 DNS 转发器，使用 Rust (kixdns) 构建。
  支持多上游负载均衡（UDP/TCP/DoH/DoT/DoQ）、
  GeoIP/GeoSite 路由、Pipeline 规则引擎、
  DNS 污染响应过滤、缓存与 Serve Stale（RFC 8767）、
  配置热重载。
endef

define Package/kiwi/conffiles
/etc/config/kiwi
/etc/kiwi/pipeline.json
endef

define Build/Configure
endef

define Build/Compile
	mkdir -p "$(CURDIR)/files/usr/bin"
	cp -f "$(BINARY_DL)" "$(CURDIR)/files/usr/bin/kiwi"
endef

define Package/kiwi/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(CURDIR)/files/usr/bin/kiwi $(1)/usr/bin/kiwi

	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) $(CURDIR)/files/kiwi.init $(1)/etc/init.d/kiwi

	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) $(CURDIR)/files/kiwi.config $(1)/etc/config/kiwi

	$(INSTALL_DIR) $(1)/etc/kiwi
	$(INSTALL_CONF) $(CURDIR)/files/pipeline.json $(1)/etc/kiwi/pipeline.json
endef

define Package/kiwi/postinst
#!/bin/sh
exit 0
endef

define Package/kiwi/prerm
#!/bin/sh
[ -z "$${IPKG_INSTROOT}" ] && {
	[ -x /etc/init.d/kiwi ] && {
		/etc/init.d/kiwi stop    2>/dev/null || true
		/etc/init.d/kiwi disable 2>/dev/null || true
	}
}
exit 0
endef

$(eval $(call BuildPackage,kiwi))
