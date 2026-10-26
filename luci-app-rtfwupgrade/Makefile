include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-rtfwupgrade
PKG_VERSION:=0.2.0_alpha2
PKG_RELEASE:=1

PKG_LICENSE:=GPL-2.0-or-later
PKG_MAINTAINER:=Shuery-Shuai <2463253700@qq.com>

LUCI_TITLE:=LuCI app for router firmware updates
LUCI_DESCRIPTION:=Detects and downloads available ImmortalWrt/OpenWrt firmware \
 updates for the running device by comparing official build metadata \
 (BUILD_ID / OPENWRT_BUILD_DATE) against a configured release source.
# digest 用于校验镜像 sha256；curl 需要 ca-bundle 才能访问 https 源站。
LUCI_DEPENDS:=+luci-base +rpcd +rpcd-mod-ucode +curl +ucode-mod-digest +ca-bundle
LUCI_PKGARCH:=all

define Package/luci-app-rtfwupgrade/conffiles
/etc/config/rtfwupgrade
endef

# 安装/升级后拉起开机闭环服务。
# opkg/apk 对 init 脚本只 enable 不 start，而升级场景（PKG_UPGRADE=1）根本不会启动它；
# 若用户曾手工 disable，enable 也不会被自动恢复 —— 缺了这一步，「刷写后重启才能确认结果」
# 的闭环就只剩重启那半截，flash-pending 会一直挂着。
# 装进 rootfs 镜像时（IPKG_INSTROOT 非空）不能动宿主 init，判断方式与 postrm 一致。
define Package/luci-app-rtfwupgrade/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	# 两个 || true 是刻意的：包本身已经装好，init 起不来（rc.d 权限、uci 尚未迁移完、
	# 或设备此刻正忙）不该让 opkg/apk 回滚整个安装，用户之后可以手动
	# /etc/init.d/rtfwupgrade enable && start 补上。
	/etc/init.d/rtfwupgrade enable >/dev/null 2>&1 || true
	/etc/init.d/rtfwupgrade start >/dev/null 2>&1 || true
}
exit 0
endef

# 卸载时移除自动写入的 crontab 受管块，避免残留任务调用已删除的 CLI。
# 刷写状态文件也在这里清：它放在 /etc 才会跨重启存活，卸载后不该留成孤儿。
define Package/luci-app-rtfwupgrade/postrm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	[ -f /etc/crontabs/root ] && sed -i '/^# BEGIN rtfwupgrade (managed block, do not edit)$$/,/^# END rtfwupgrade$$/d' /etc/crontabs/root
	rm -f /etc/crontabs/root.rtfwupgrade.bak
	rm -f /tmp/rtfwupgrade.last.json
	rm -rf /tmp/rtfwupgrade
	# 刷写状态文件在 /etc（跨重启存活），卸载后不该留下一个没人认领的 flash-pending
	rm -f /etc/rtfwupgrade.flash.json
	/etc/init.d/cron restart >/dev/null 2>&1 || true
}
exit 0
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
