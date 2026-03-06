# SPDX-License-Identifier: MIT
#
# Copyright (C) 2021-2026 LIKE2000-ART
# This is free software, licensed under the MIT License.
#

include $(TOPDIR)/rules.mk

PKG_NAME:=picoclaw
PKG_VERSION:=0.1.2
PKG_RELEASE:=1

PKG_SOURCE_PROTO:=git
PKG_SOURCE_URL:=https://github.com/sipeed/picoclaw.git
PKG_SOURCE_VERSION:=main
PKG_MIRROR_HASH:=skip

PKG_LICENSE:=MIT
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=LIKE2000-ART

PKG_BUILD_DEPENDS:=golang/host
PKG_BUILD_PARALLEL:=1
PKG_USE_MIPS16:=0
PKG_BUILD_FLAGS:=no-mips16

GO_PKG:=github.com/sipeed/picoclaw
GO_PKG_BUILD_PKG:=github.com/sipeed/picoclaw/cmd/picoclaw
GO_PKG_TAGS:=stdjson
GO_PKG_LDFLAGS:=-s -w \
	-X '$(GO_PKG_BUILD_PKG)/internal.version=$(PKG_VERSION)' \
	-X '$(GO_PKG_BUILD_PKG)/internal.gitCommit=git/$(PKG_SOURCE_VERSION)' \
	-X '$(GO_PKG_BUILD_PKG)/internal.buildTime=$(shell date +%FT%T%z)' \
	-X '$(GO_PKG_BUILD_PKG)/internal.goVersion=$(shell $(STAGING_DIR_HOSTPKG)/bin/go version | sed "s/go version //")'

include $(INCLUDE_DIR)/package.mk
include $(TOPDIR)/feeds/packages/lang/golang/golang-package.mk

define Package/picoclaw
  TITLE:=PicoClaw - Ultra-Efficient AI Assistant
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=Web Servers/Proxies
  URL:=https://github.com/sipeed/picoclaw
  DEPENDS:=$(GO_ARCH_DEPENDS) +ca-bundle
endef

define Package/picoclaw/description
  PicoClaw is an ultra-lightweight personal AI Assistant built in Go.
  Runs on minimal hardware with less than 10MB RAM.
  Tiny, Fast, and Deployable anywhere — automate the mundane, unleash your creativity.
endef

define Build/Prepare
	$(call Build/Prepare/Default)
	$(CP) $(PKG_BUILD_DIR)/workspace $(PKG_BUILD_DIR)/cmd/picoclaw/internal/onboard/workspace
	# Patch upstream to respect PICOCLAW_HOME rather than always using UserHomeDir
	$(SED) 's|home, _ := os.UserHomeDir()|home := os.Getenv("PICOCLAW_HOME")\n\tif home == "" {\n\t\thome, _ = os.UserHomeDir()\n\t\thome = filepath.Join(home, ".picoclaw")\n\t}\n\treturn filepath.Join(home, "config.json")|' $(PKG_BUILD_DIR)/cmd/picoclaw/internal/helpers.go
	$(SED) 's|return filepath.Join(home, ".picoclaw", "config.json")||' $(PKG_BUILD_DIR)/cmd/picoclaw/internal/helpers.go
endef

define Package/picoclaw/install
	$(call GoPackage/Package/Install/Bin,$(1))

	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) $(CURDIR)/files/picoclaw.init $(1)/etc/init.d/picoclaw
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) $(CURDIR)/files/picoclaw.uci-default $(1)/etc/uci-defaults/picoclaw
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) $(CURDIR)/files/picoclaw.conf $(1)/etc/config/picoclaw
	$(INSTALL_DIR) $(1)/etc/picoclaw
	$(INSTALL_DIR) $(1)/usr/share/picoclaw
	$(INSTALL_DATA) $(CURDIR)/files/picoclaw-config.json $(1)/usr/share/picoclaw/picoclaw-config.json
endef

define Package/picoclaw/prerm
#!/bin/sh
# Stop service before removal
/etc/init.d/picoclaw stop 2>/dev/null
/etc/init.d/picoclaw disable 2>/dev/null
exit 0
endef

define Package/picoclaw/postrm
#!/bin/sh
# Clean up all residual files after removal
rm -f /etc/config/picoclaw
rm -f /etc/config/picoclaw-opkg
rm -rf /etc/picoclaw
rm -f /var/log/picoclaw.log
rm -rf /usr/share/picoclaw
rm -f /root/.picoclaw 2>/dev/null
rm -f /.picoclaw 2>/dev/null
exit 0
endef

define Package/picoclaw/conffiles
/etc/config/picoclaw
/etc/picoclaw/config.json
endef

$(eval $(call GoBinPackage,picoclaw))
$(eval $(call BuildPackage,picoclaw))
