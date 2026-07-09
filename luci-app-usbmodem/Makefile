include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-usbmodem
PKG_VERSION:=1.0.2
PKG_RELEASE:=1

PKG_MAINTAINER:=USB Modem Team
PKG_LICENSE:=GPL-2.0-or-later
PKG_LICENSE_FILES:=LICENSE

LUCI_TITLE:=USB Modem Manager (NCM/ECM/QMI/RNDIS)
LUCI_DEPENDS:=+luci-base +luci-compat +kmod-usb-net +kmod-usb-net-cdc-ncm \
	+kmod-usb-net-cdc-ether +kmod-usb-net-qmi-wwan +kmod-usb-net-rndis \
	+kmod-usb-serial +kmod-usb-serial-option +kmod-usb-serial-wwan \
	+usbutils +jshn +jsonfilter +chat +comgt +uqmi

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature