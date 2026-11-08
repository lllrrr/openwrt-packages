# Author: mingxiaoyu (fengying0347@163.com)
#
# Licensed to the public under the GNU General Public License v3.
#

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-cfpick

LUCI_TITLE:=CFPick - Cloudflare IP optimizer for OpenWrt
# The standalone engine (cfpick) is a stdlib-only Python program; these
# are the OpenWrt sub-packages that provide the modules it imports.
LUCI_DEPENDS:=+curl +ca-bundle +python3-light +python3-urllib +python3-codecs +python3-openssl +python3-email
LUCI_PKGARCH:=all
PKG_VERSION:=1.0.15
PKG_RELEASE:=0
PKG_LICENSE:=AGPL-3.0
PKG_MAINTAINER:=<https://github.com/urbanescavenger/CFPick>

define Package/$(PKG_NAME)/conffiles
/etc/config/cfpick
endef

# The standalone engine is maintained once in debian/ (the Debian/Ubuntu
# implementation) and copied into the package tree at build time; nothing is
# duplicated in git.  These hooks MUST be defined before including luci.mk:
# BuildPackage expands `$(call Build/Prepare/$(LUCI_NAME))` while luci.mk is
# being included, so a hook defined after it is silently ignored (the package
# then builds without /usr/lib/cfpick).
define StandaloneEnginePrepare
	$(INSTALL_DIR) $(PKG_BUILD_DIR)/root/usr/lib/cfpick
	$(CP) -R $(CURDIR)/debian/cfpick $(PKG_BUILD_DIR)/root/usr/lib/cfpick/
	# No web/ assets: the OpenWrt app uses the operations console for its UI.
	$(CP) -R $(CURDIR)/debian/data $(PKG_BUILD_DIR)/root/usr/lib/cfpick/
endef

define Build/Prepare/luci-app-cfpick
$(StandaloneEnginePrepare)
endef

# Also support building the git checkout directly (directory name is the
# repository name, not the package name).
define Build/Prepare/$(notdir $(CURDIR))
$(StandaloneEnginePrepare)
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
