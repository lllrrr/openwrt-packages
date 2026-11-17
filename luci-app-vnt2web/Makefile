#
# Copyright (C) 2008-2024 The LuCI Team
#
# This is free software, licensed under the Apache License, Version 2.0 .
#

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-vnt2web
PKG_VERSION:=1.0.2
PKG_RELEASE:=1

PKG_LICENSE:=MIT
PKG_MAINTAINER:=VirKing <https://github.com/virkingz>

LUCI_TITLE:=VNT2WEB - OpenWrt 上的 VNT 组网（Web 版）
LUCI_DESCRIPTION:=把 vnt2_web 核心封装成 OpenWrt 服务与 LuCI 界面：设置访问令牌与端口、托管核心进程、按架构在线更新核心、查看日志。组网的添加与启停由 vnt2_web 自带网页完成。
LUCI_DEPENDS:=+luci-base +rpcd +kmod-tun +unzip
LUCI_PKGARCH:=all

# 配置文件：opkg 升级时不覆盖用户改动
define Package/$(PKG_NAME)/conffiles
/etc/config/vnt2web
endef

# 重装/升级前先停服务，避免运行中的核心被替换后留下孤儿进程
define Package/$(PKG_NAME)/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	/etc/init.d/vnt2web stop  >/dev/null 2>&1
	/etc/init.d/vnt2web disable >/dev/null 2>&1
}
exit 0
endef

# 安装后确保脚本可执行（有些归档/Windows 打包会丢可执行位），并启用服务
define Package/$(PKG_NAME)/postinst
#!/bin/sh
chmod 0755 \
	"$${IPKG_INSTROOT}/etc/init.d/vnt2web" \
	"$${IPKG_INSTROOT}/etc/uci-defaults/95-vnt2web" \
	"$${IPKG_INSTROOT}/usr/libexec/rpcd/vnt2web" >/dev/null 2>&1
exit 0
endef

# 卸载时清理：把 /etc 下的数据目录移到 /tmp（软删除）。
# /tmp 是内存盘，重启即清 —— 既不留残留，也给「误卸载」留一次后悔机会。
#
# 注意必须按 $1 区分场景：opkg 升级时也会调用 postrm（参数 upgrade），
# 此时绝不能搬走目录，否则升级瞬间丢配置与核心。
define Package/$(PKG_NAME)/postrm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0

# 升级/重装：保留一切
case "$$1" in
	upgrade) exit 0 ;;
esac

# 停服务并清运行期数据（/tmp 下的，重启本就会清）
if [ -x /etc/init.d/vnt2web ]; then
	/etc/init.d/vnt2web stop >/dev/null 2>&1
	/etc/init.d/vnt2web disable >/dev/null 2>&1
fi
rm -rf /tmp/vnt2web 2>/dev/null

# 把 /etc 下的数据目录搬到 /tmp（软删除，重启即消失，避免 Flash 残留）
# 用时间戳后缀，防止同一会话内重复卸载时互相覆盖。
if [ -d /etc/vnt2web ]; then
	_stash="/tmp/vnt2web-removed-$$$$"
	mv -f /etc/vnt2web "$$_stash" 2>/dev/null || rm -rf /etc/vnt2web 2>/dev/null
	if [ -d "$$_stash" ]; then
		echo "配置与核心已移至 $$_stash（重启后自动清除）。"
		echo "如需立刻彻底清除：rm -rf $$_stash"
	fi
fi

rm -f /tmp/luci-indexcache* 2>/dev/null
rm -rf /tmp/luci-modulecache/ 2>/dev/null
/etc/init.d/rpcd restart >/dev/null 2>&1
exit 0
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
