#
# Copyright (C) 2017-2020
#
# This is free software, licensed under the GNU General Public License v2.
#

include $(TOPDIR)/rules.mk

PKG_NAME:=qbittorrent-nox-static
PKG_VERSION:=5.2.3
PKG_RELEASE:=3

PKG_FULL_VERSION:=5.2.3_v2.0.15

STRIP:=true

ifeq ($(ARCH),i386)
	PKG_ARCH:=x86
	PKG_HASH:=2f88e65f1ccab263057bf8caa6f83632507293d89755bc2f84f158d21f651e77
endif

ifeq ($(ARCH),x86_64)
	PKG_ARCH:=x86_64
	PKG_HASH:=eab445f0e7adfca8e33afcd5724cdfd76a09e610d914bec25e8788efbb4e55e2
endif

ifeq ($(ARCH),aarch64)
	PKG_ARCH:=aarch64
	PKG_HASH:=335fb2d8038f4b66a444f5645300a98abb2fcebaccf74baf5b30b48c8106082d
endif

ifeq ($(ARCH),arm)
	PKG_ARCH:=armv7
	PKG_HASH:=dcded437908c363693b6ea1df287c528a14f35adc1854d908da58109708e5058
endif

include $(INCLUDE_DIR)/package.mk

define Package/qbittorrent-nox-static
	SECTION:=net
	CATEGORY:=Network
	DEPENDS:=@(arm||aarch64||i386||x86_64)
	SUBMENU:=BitTorrent
	TITLE:=bittorrent client programmed in C++ / Qt
	URL:=https://github.com/userdocs/qbittorrent-nox-static
	PROVIDES:=qBittorrent
endef

define Package/qbittorrent-nox-static/description
  The qbittorrent-nox-static project is a bash build script that compiles
  a static qbittorrent-nox binary using the latest available dependencies
  from their source. These statically linked binaries can run on any
  matching CPU architecture and are not OS specific.

  See: https://github.com/userdocs/qbittorrent-nox-static
endef

define Download/qbittorrent-nox-static
	URL:=https://github.com/userdocs/qbittorrent-nox-static/releases/download/release-$(PKG_FULL_VERSION)
	URL_FILE:=$(PKG_ARCH)-qbittorrent-nox
	FILE:=qbittorrent-nox-$(PKG_ARCH)-$(PKG_FULL_VERSION)
	HASH:=$(PKG_HASH)
endef

define Package/qbittorrent-nox-static/conffiles
/etc/config/qbittorrent
endef

define Build/Compile
endef

define Package/qbittorrent-nox-static/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(DL_DIR)/qbittorrent-nox-$(PKG_ARCH)-$(PKG_FULL_VERSION) $(1)/usr/bin/qbittorrent-nox

	$(INSTALL_DIR) $(1)/etc/config $(1)/etc/init.d $(1)/usr/share/qbittorrent
	$(INSTALL_BIN) ./files/qbittorrent.init $(1)/etc/init.d/qbittorrent
	$(INSTALL_CONF) ./files/qbittorrent.config $(1)/etc/config/qbittorrent
	$(INSTALL_CONF) ./files/qBittorrent.conf.example $(1)/usr/share/qbittorrent/qBittorrent.conf.example
endef

$(eval $(call Download,qbittorrent-nox-static))
$(eval $(call BuildPackage,qbittorrent-nox-static))

