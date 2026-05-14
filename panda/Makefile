# Panda DDNS — 动态 DNS 后端守护进程
# 遵循 OpenWrt 25.12 包规范

include $(TOPDIR)/rules.mk

PKG_NAME    := panda
PKG_VERSION := 1.0.0
PKG_RELEASE := 1

PKG_MAINTAINER := Your Name <you@example.com>
PKG_LICENSE    := GPL-3.0-or-later

include $(INCLUDE_DIR)/package.mk

define Package/panda
  SECTION   := net
  CATEGORY  := Network
  SUBMENU   := Web Servers/Proxies
  TITLE     := Panda DDNS（动态 DNS 守护进程）
  DEPENDS   := +python3
endef

define Package/panda/description
  Panda DDNS 动态 DNS 更新守护进程。

  支持 Cloudflare、DNSPod、阿里云、华为云、No-IP、DuckDNS、百度云。
  从 /etc/config/panda 读取 UCI 配置，按设定间隔自动更新 DNS 记录。
endef

define Build/Compile
	true
endef

define Package/panda/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./files/panda-ddns $(1)/usr/bin/

	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/panda.init $(1)/etc/init.d/panda

	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/panda.uci $(1)/etc/config/panda

	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/99-panda $(1)/etc/uci-defaults/
endef

define Package/panda/postinst
#!/bin/sh
[ -z "$${IPKG_INSTROOT}" ] && [ -x /etc/init.d/panda ] && \
	/etc/init.d/panda enable 2>/dev/null || true
exit 0
endef

define Package/panda/prerm
#!/bin/sh
[ -z "$${IPKG_INSTROOT}" ] && [ -x /etc/init.d/panda ] && {
	/etc/init.d/panda stop    2>/dev/null || true
	/etc/init.d/panda disable 2>/dev/null || true
}
exit 0
endef

$(eval $(call BuildPackage,panda))
