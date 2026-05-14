# LuCI web interface for Panda DDNS
# 遵循 OpenWrt 25.12 包规范

include $(TOPDIR)/rules.mk

LUCI_TITLE     := Panda DDNS
LUCI_DEPENDS   := +luci-base +panda
LUCI_PKGARCH   := all

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
