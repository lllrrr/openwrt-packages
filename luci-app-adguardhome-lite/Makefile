# 版本唯一来源：本目录下的 VERSION（正式版写 1.3.5，多轮打包写 1.3.5-2）
# 在 include rules.mk 之前解析，确保 MAKEFILE_LIST 指向本 Makefile
VERSION_FILE:=$(dir $(lastword $(MAKEFILE_LIST)))VERSION
PKG_VERSION:=$(shell awk -F- 'NR==1{print $$1}' $(VERSION_FILE) 2>/dev/null)
PKG_RELEASE:=$(shell awk -F- 'NR==1{print (NF>1?$$2:"1")}' $(VERSION_FILE) 2>/dev/null)
$(if $(PKG_VERSION),,$(error 缺少或无法读取 VERSION 文件：$(VERSION_FILE)))

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-adguardhome-lite
PKG_LICENSE:=GPL-3.0-or-later
PKG_MAINTAINER:=Ozero-top

LUCI_TITLE:=AdGuard Home 管理中心
LUCI_DESCRIPTION:=在路由器上一体化管理 AdGuard Home：一键安装内核、DNS 接管、过滤规则、运行看护与统计
LUCI_DEPENDS:=+luci-base +luci-compat +luci-lib-jsonc +curl +wget-ssl +ca-bundle
LUCI_PKGARCH:=all

CONFLICTS:=luci-app-adguardhome

# 安装后刷新 LuCI 缓存；升级时若配置仍启用则恢复自启并重启
define Package/luci-app-adguardhome-lite/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
mkdir -p /etc/AdGuardHome /usr/bin/AdGuardHome 2>/dev/null
chmod 755 /etc/init.d/adguardhome_lite 2>/dev/null
rm -f /tmp/luci-indexcache /tmp/luci-indexcache.* 2>/dev/null
if [ -x /etc/init.d/adguardhome_lite ] && [ "$$(uci -q get adguardhome_lite.main.enabled 2>/dev/null)" = "1" ]; then
	/etc/init.d/adguardhome_lite enable >/dev/null 2>&1
	/etc/init.d/adguardhome_lite restart >/dev/null 2>&1
fi
exit 0
endef

# 卸载前停止服务并恢复 DNSMasq；恢复失败则中止卸载，避免留下 1745 端口导致断网
define Package/luci-app-adguardhome-lite/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
case "$$1" in upgrade|failed-upgrade) exit 0 ;; esac
if [ -x /etc/init.d/adguardhome_lite ]; then
	/etc/init.d/adguardhome_lite stop >/dev/null 2>&1
fi
if [ -x /usr/share/adguardhome-lite/dns_mode.sh ]; then
	/usr/share/adguardhome-lite/dns_mode.sh revert >/dev/null 2>&1 || {
		echo "AdGuard Home 管理中心：无法恢复 DNSMasq 设置，已中止卸载以保护网络。" >&2
		exit 1
	}
fi
exit 0
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
