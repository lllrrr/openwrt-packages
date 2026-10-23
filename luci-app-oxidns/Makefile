include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-oxidns
PKG_VERSION:=1.1
PKG_RELEASE:=3

PKG_LICENSE:=GPL-3.0-or-later
PKG_MAINTAINER:=Sven Shi <isvenshi@gmail.com>

LUCI_TITLE:=LuCI support for OxiDNS
LUCI_DEPENDS:=+luci-base +rpcd +jsonfilter +uclient-fetch +ca-bundle
LUCI_PKGARCH:=all

define Package/luci-app-oxidns/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT:-}" ] && exit 0
rm -f /tmp/luci-indexcache* 2>/dev/null || true
rm -rf /tmp/luci-modulecache/* 2>/dev/null || true
if [ -d /www/luci-static/resources/view/oxidns ]; then
	find /www/luci-static/resources/view/oxidns -type f -name '*.js' -exec touch {} + 2>/dev/null || true
fi
if [ -x /etc/init.d/rpcd ]; then
	/etc/init.d/rpcd restart >/dev/null 2>&1 || true
fi
# 0.1.4-r1 把 learn-reset 脚本从 /usr/bin 挪到了 /usr/libexec/oxidns，旧 cron 块里的
# 路径要跟着改，否则定时重置只会在 cron 日志里静默失败。
#
# 这段必须写在这里：发版走官方 SDK（.github/workflows/build-packages.yml 用
# gh-action-sdk），它的 postinst 只来自本文件的 define 块，不读
# scripts/build-luci-package.sh 里的任何东西。它原先只写在那个脚本的 heredoc 里，
# 于是线上安装从来没有跑过这段迁移 —— 本地造包解出来核对也永远核不到。
if [ -f /etc/crontabs/root ] && [ -x /usr/libexec/oxidns/learn-reset.sh ]; then
	sed -i 's#/usr/bin/oxidns-learn-reset\.sh#/usr/libexec/oxidns/learn-reset.sh#g' /etc/crontabs/root 2>/dev/null || true
	if [ -x /etc/init.d/cron ]; then
		/etc/init.d/cron restart >/dev/null 2>&1 || true
	fi
fi
# 0.1.5-r6 修 DNS 劫持漏掉 IPv6。
#
# fw4 对「没有 family」的 redirect 按 IPv4 兜底（fw4.uc 的 parse_redirect：
# "for backwards compatibility, treat unspecified family as IPv4 unless user
# explicitly requested any (0)"），所以 0.1.5-r5 及更早写下的 oxidns_hijack*
# 段只劫持了 IPv4，IPv6 的 :53 查询原样放行。这里就地补 family=any。
#
# 只认我们自己打的 name 标记；只在 family 确实为空时补 —— 用户手工指定的 ipv4
# 有他自己的理由，不动。幂等，可以反复跑。
if command -v uci >/dev/null 2>&1; then
	hijack_changed=0
	for hijack_sect in oxidns_hijack oxidns_hijack_udp oxidns_hijack_tcp; do
		[ "$$(uci -q get "firewall.$$hijack_sect.name" 2>/dev/null || true)" = "oxidns-dns-hijack" ] || continue
		[ -n "$$(uci -q get "firewall.$$hijack_sect.family" 2>/dev/null || true)" ] && continue
		if uci -q set "firewall.$$hijack_sect.family=any"; then
			hijack_changed=1
		fi
	done
	if [ "$$hijack_changed" = "1" ] && uci -q commit firewall; then
		if [ -x /etc/init.d/firewall ]; then
			/etc/init.d/firewall reload >/dev/null 2>&1 || true
		fi
	fi
fi
exit 0
endef

define Package/luci-app-oxidns/postrm
#!/bin/sh
[ -n "$${IPKG_INSTROOT:-}" ] && exit 0
rm -f /tmp/luci-indexcache* 2>/dev/null || true
rm -rf /tmp/luci-modulecache/* 2>/dev/null || true
if [ -x /etc/init.d/rpcd ]; then
	/etc/init.d/rpcd restart >/dev/null 2>&1 || true
fi
exit 0
endef

# 翻译包（luci-i18n-oxidns-*）的版本号。
#
# luci.mk 默认拿 PKG_PO_VERSION 给翻译包定版，它由「最后一次改动 po/ 的提交」推导而来
# （形如 26.263.19088~0985e71，见 luci.mk 里的 findrev），与 PKG_VERSION/PKG_RELEASE 无关。
# 不钉住的话，同一个 Release 里应用包叫 luci-app-oxidns-0.1.4-r4.apk、翻译包却叫
# luci-i18n-oxidns-zh-cn-26.263.19088~0985e71.apk，用户按 Release 说明拼不出后者。
# luci.mk 里该变量是 `PKG_PO_VERSION?=`（可覆盖），这里显式钉成与应用包同一版本。
PKG_PO_VERSION:=$(PKG_VERSION)-r$(PKG_RELEASE)

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
