include $(TOPDIR)/rules.mk

PKG_NAME:=iptv-tool
PKG_VERSION:=2.0.11
PKG_RELEASE:=1

PKG_SOURCE:=iptv-tool-v$(PKG_VERSION).tar.gz
PKG_SOURCE_URL:=https://github.com/super321/iptv-tool/archive/refs/tags/v$(PKG_VERSION).tar.gz?
PKG_HASH:=a4bc813dc7f73d68ea062cb6cbc79e73e2f8728adfffb708c5cde5f4c1383599

PKG_LICENSE:=AGPL-3.0-only
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=blueveryday

PKG_BUILD_DEPENDS:=golang/host
PKG_BUILD_PARALLEL:=1
PKG_BUILD_FLAGS:=no-mips16

GO_PKG:=github.com/super321/iptv-tool
GO_PKG_BUILD_PKG:=$(GO_PKG)/cmd/iptv-server
GO_PKG_LDFLAGS:=-s -w
GO_PKG_LDFLAGS_X:=$(GO_PKG)/internal/version.Version=v$(PKG_VERSION)

include $(INCLUDE_DIR)/package.mk
include $(TOPDIR)/feeds/packages/lang/golang/golang-package.mk

define Package/iptv-tool
  SECTION:=multimedia
  CATEGORY:=Multimedia
  TITLE:=IPTV Tool server (live source / EPG aggregation)
  URL:=https://github.com/super321/iptv-tool
  DEPENDS:=@(aarch64||arm||x86_64||i386||riscv64) +ca-bundle
endef

define Package/iptv-tool/description
  Aggregates IPTV live sources and EPG, and publishes M3U/TXT/XMLTV
  subscriptions with a built-in web UI (default port 8023).
endef

define Package/iptv-tool/conffiles
/etc/config/iptv-tool
endef

define Build/Prepare
	$(call Build/Prepare/Default)
	$(SED) 's|^module iptv-tool-v2|module $(GO_PKG)|' $(PKG_BUILD_DIR)/go.mod
	find $(PKG_BUILD_DIR) -name '*.go' -exec $(SED) 's|"iptv-tool-v2/|"$(GO_PKG)/|g' {} +
endef

define Build/Compile
	cd $(PKG_BUILD_DIR)/web && \
	if [ -f package-lock.json ]; then npm ci --no-audit --no-fund; \
	else npm install --no-audit --no-fund; fi && \
	npm run build
	$(call GoPackage/Build/Compile)
endef

define Package/iptv-tool/install
	$(call GoPackage/Package/Install/Bin,$(1))
	$(INSTALL_DIR) $(1)/etc/init.d $(1)/etc/config
	$(INSTALL_BIN) ./files/iptv-tool.init $(1)/etc/init.d/iptv-tool
	$(INSTALL_CONF) ./files/iptv-tool.config $(1)/etc/config/iptv-tool
endef

$(eval $(call GoBinPackage,iptv-tool))
$(eval $(call BuildPackage,iptv-tool))
