# Based on feed/openwrt-shellinabox/Makefile.
include $(TOPDIR)/rules.mk

PKG_NAME:=shellinabox
PKG_VERSION:=2.20
PKG_RELEASE:=1

PKG_SOURCE_PROTO:=git
PKG_SOURCE_URL:=https://github.com/shellinabox/shellinabox.git
PKG_SOURCE_SUBDIR:=$(PKG_NAME)-$(PKG_VERSION)
PKG_SOURCE_VERSION:=98e6eebc6c2026fb126a458c6cb5a2541447258e
PKG_SOURCE:=$(PKG_NAME)-$(PKG_VERSION).tar.gz
PKG_MIRROR_HASH:=6519be6f9ab93a8c6c0474246714cbf4f8866e7eb9ed2495a6999b80c916c354

PKG_FIXUP:=autoreconf
PKG_LICENSE:=GPL-2.0-only
PKG_LICENSE_FILES:=COPYING GPL-2

include $(INCLUDE_DIR)/package.mk

define Package/shellinabox
  SECTION:=net
  CATEGORY:=Network
  TITLE:=a web based terminal emulator
  URL:=https://github.com/shellinabox/shellinabox
  DEPENDS:=+zlib +libopenssl +busybox +@BUSYBOX_CUSTOM +@BUSYBOX_CONFIG_LOGIN
endef

define Package/shellinabox/description
 Shell In A Box implements a web server that can export arbitrary command
 line tools to a web based terminal emulator. The optional LuCI frontend
 starts it on demand in CGI mode instead of using the standalone service.
endef

define Package/shellinabox/conffiles
/etc/shellinabox/
endef

CONFIGURE_ARGS += --disable-utmp --disable-pam --disable-runtime-loading

# In this version HAVE_UTMP_H only includes utmp.h for login_tty().
# Keep utmp accounting disabled; its feature macros remain unset.
TARGET_CPPFLAGS += -DHAVE_UTMP_H=1

define Package/shellinabox/install
	$(INSTALL_DIR) $(1)/usr/sbin $(1)/etc/init.d $(1)/etc/shellinabox
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/shellinaboxd $(1)/usr/sbin
	$(INSTALL_BIN) ./files/shellinaboxd.init $(1)/etc/init.d/shellinaboxd
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/shellinabox/*.css $(1)/etc/shellinabox
endef

$(eval $(call BuildPackage,shellinabox))
