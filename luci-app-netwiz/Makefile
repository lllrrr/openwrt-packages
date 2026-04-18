include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-netwiz
PKG_VERSION:=1.0.1
PKG_RELEASE:=1

LUCI_TITLE:=NetWiz - Exclusive Safe Network Wizard
LUCI_DEPENDS:=+luci-base +rpcd-mod-luci
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

# --- 安装后自动执行初始化脚本 ---
define Package/luci-app-netwiz/postinst
#!/bin/sh
# 1. 强行吸走 Windows 的隐藏回车符 (防止 bad interpreter 报错)
sed -i 's/\r$$//g' $${IPKG_INSTROOT}/usr/libexec/rpcd/netwiz >/dev/null 2>&1

# 2. 强行赋予最高可执行权限
chmod +x $${IPKG_INSTROOT}/usr/libexec/rpcd/netwiz >/dev/null 2>&1

# 3. 如果是在真实路由器上安装 (非源码云编译阶段)，则自动重启 rpcd 服务挂载总线
if [ -z "$${IPKG_INSTROOT}" ]; then
	/etc/init.d/rpcd restart >/dev/null 2>&1
fi
exit 0
endef
# --------------------------------------------------

# call BuildPackage - OpenWrt buildroot signature
