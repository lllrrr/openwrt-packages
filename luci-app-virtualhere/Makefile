include $(TOPDIR)/rules.mk

LUCI_TITLE:=LuCI support for VirtualHere
LUCI_DEPENDS:=+luci-base +flock +rpcd-mod-ucode +ucode-mod-fs +ucode-mod-uci +ucode-mod-ubus
PKG_VERSION:=1.1.0
PKG_RELEASE:=3

define Package/luci-app-virtualhere/conffiles
/etc/config/virtualhere
/etc/vhusbd.conf
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
