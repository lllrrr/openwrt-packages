#
# Copyright (C) 2017-2020
#
# This is free software, licensed under the GNU General Public License v2.
#

include $(TOPDIR)/rules.mk

PKG_NAME:=qbittorrent-nox-static
PKG_VERSION:=5.1.4
PKG_RELEASE:=2

PKG_FULL_VERSION:=5.1.4_v2.0.12

STRIP:=true

ifeq ($(ARCH),i386)
	PKG_ARCH:=x86
	PKG_HASH:=fa66fff86f6f7024ba666992720794bf7ae85f82e5322f0a53f3e060838f890c
endif

ifeq ($(ARCH),x86_64)
	PKG_ARCH:=x86_64
	PKG_HASH:=b434cc72b7b998855035210e6396dde5dbd544a335a7bd83ca87ffd781276522
endif

ifeq ($(ARCH),aarch64)
	PKG_ARCH:=aarch64
	PKG_HASH:=5a83e8047e2b6b3fcbe9cd7fde4b5a48352033e469d167fae907166273f87915
endif

ifeq ($(ARCH),arm)
	PKG_ARCH:=armv7
	PKG_HASH:=87c38f075b58f769f6d4271cee66249b7f6803fc3ac88477679bf1bc532f41eb
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

