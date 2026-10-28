include $(TOPDIR)/rules.mk

LUCI_TITLE:=Pulse - Lightweight router dashboard
LUCI_DEPENDS:=+luci-base +rpcd-mod-luci +rpcd-mod-file +ucode +ucode-mod-fs +ucode-mod-ubus +ucode-mod-uloop
LUCI_PKGARCH:=all
# SDK csstidy drops @supports rules used by the theme.
LUCI_MINIFY_CSS:=0
PKG_LICENSE:=MIT
PULSE_RELEASE:=1.0.3
PULSE_VERSION?=$(shell $(SHELL) $(CURDIR)/generate-version.sh --resolve $(PULSE_RELEASE))
PKG_VERSION:=$(PULSE_VERSION)
ifeq ($(strip $(PKG_VERSION)),)
  $(error Cannot determine Pulse version; provide PULSE_VERSION or a complete tagged Git checkout)
endif
PKG_RELEASE:=1

define Build/Prepare/luci-app-pulse
	$(SHELL) $(CURDIR)/generate-version.sh --write "$(PKG_VERSION)" $(PKG_BUILD_DIR)/htdocs/luci-static/resources/view/pulse/index.js
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
