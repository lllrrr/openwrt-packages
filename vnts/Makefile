include $(TOPDIR)/rules.mk

PKG_NAME:=vnts
PKG_VERSION:=1.2.12

ifeq ($(ARCH),mipsel)
	APP_ARCH:=mipsel-unknown-linux-musl
endif
ifeq ($(ARCH),mips)
	APP_ARCH:=mips-unknown-linux-musl
endif
ifeq ($(ARCH),arm)
	APP_ARCH:=arm-unknown-linux-musleabi
endif
ifeq ($(BOARD),kirkwood)
	APP_ARCH:=arm-unknown-linux-musleabi
endif
ifeq ($(ARCH),armv7)
	APP_ARCH:=armv7-unknown-linux-musleabi
endif
ifeq ($(ARCH),aarch64)
	APP_ARCH:=aarch64-unknown-linux-musl
endif
ifeq ($(ARCH),arm64)
	APP_ARCH:=aarch64-unknown-linux-musl
endif
ifeq ($(ARCH),armv8)
	APP_ARCH:=aarch64-unknown-linux-musl
endif
ifeq ($(ARCH),i386)
	PKG_VERSION:=1.2.11
	APP_ARCH:=i686-unknown-linux-musl
endif
ifeq ($(ARCH),x86_64)
	APP_ARCH:=x86_64-unknown-linux-musl
endif

PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)-$(PKG_VERSION)

include $(INCLUDE_DIR)/package.mk

define Package/$(PKG_NAME)
	SECTION:=net
	CATEGORY:=Network
	TITLE:=An efficient VPN 
	DEPENDS:=@(i386||x86_64||arm||aarch64||mipsel||mips)
	URL:=https://github.com/vnt-dev/vnts
endef

define Package/$(PKG_NAME)/description
  简便高效的异地组网、内网穿透工具（服务端）
endef

define Build/Prepare
	[ "$(ARCH)" = "i386" ] && [ ! -f $(PKG_BUILD_DIR)/$(PKG_NAME)-$(APP_ARCH).tar.gz ] && wget https://github.com/vnt-dev/vnts/releases/download/$(PKG_VERSION)/$(PKG_NAME)-$(APP_ARCH)-$(PKG_VERSION).tar.gz -O $(PKG_NAME)-$(APP_ARCH).tar.gz || true
	[ "$(ARCH)" != "i386" ] && [ ! -f $(PKG_BUILD_DIR)/$(PKG_NAME)-$(APP_ARCH).tar.gz ] && wget https://github.com/vnt-dev/vnts/releases/download/v$(PKG_VERSION)/$(PKG_NAME)-$(APP_ARCH)-v$(PKG_VERSION).tar.gz -O $(PKG_NAME)-$(APP_ARCH).tar.gz || true
	tar -xzvf $(PKG_NAME)-$(APP_ARCH).tar.gz -C $(PKG_BUILD_DIR)
endef

define Build/Compile
endef

define Package/$(PKG_NAME)/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/vnts $(1)/usr/bin/vnts
endef

$(eval $(call BuildPackage,$(PKG_NAME)))
