# LuCI web interface for Komari Monitor Agent
# 遵循 OpenWrt 25.12 包规范

include $(TOPDIR)/rules.mk

LUCI_TITLE     := Komari
LUCI_DEPENDS   := +luci-base +komari
LUCI_PKGARCH   := all

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
