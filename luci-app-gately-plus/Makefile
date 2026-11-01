include $(TOPDIR)/rules.mk

LUCI_TITLE:=LuCI app for Gately (Plus)
LUCI_DEPENDS:=+luci-base +curl
LUCI_PKGARCH:=all

PKG_NAME:=luci-app-gately-plus
PKG_VERSION:=2.0.3
PKG_RELEASE:=1
PKG_PO_VERSION:=$(PKG_VERSION)

LUCI_MINIFY_JS:=0
LUCI_MINIFY_CSS:=0

define Build/Prepare/$(PKG_NAME)
	$(SED) "s/^var GATELY_ASSET_VERSION = '[^']*';/var GATELY_ASSET_VERSION = '$(PKG_VERSION)-r$(PKG_RELEASE)';/" $(PKG_BUILD_DIR)/htdocs/luci-static/resources/gately-plus/common.js
endef

include $(TOPDIR)/feeds/luci/luci.mk

define Package/$(PKG_NAME)/conffiles
/etc/config/gately_plus
endef

define Package/$(PKG_NAME)/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
INITD=/etc/init.d
UPGRADE_MARKER=/tmp/gately-plus-luci-app-upgrade

# 从旧包 luci-app-gately（1.2.0 及更早，含官方同名包）迁移配置：
# 旧配置里的 section 名也是 gately，整份复制即可直接沿用
if [ ! -f /etc/config/gately_plus ] && [ -f /etc/config/gately ]; then
	cp /etc/config/gately /etc/config/gately_plus
fi

# 1.1.8 起移除「使用系统代理」选项，清掉旧版本遗留的 uci 配置
if uci -q get gately_plus.gately.use_system_proxy >/dev/null 2>&1; then
	uci -q delete gately_plus.gately.use_system_proxy
	uci -q commit gately_plus
fi

# 旧包的服务名与本包不同，两者会争抢同一个 gately 二进制与端口
if [ -f "$${INITD}/gately" ] && [ -f "$${INITD}/gately-plus" ]; then
	echo ""
	echo "NOTE: 检测到旧版 luci-app-gately 仍在。本包已改名为 luci-app-gately-plus，"
	echo "      两者会争抢同一个 gately 进程与端口，建议执行："
	echo "        opkg remove luci-app-gately      # 或 apk del luci-app-gately"
	echo "      （若那是 Gately 官方的同名插件，卸载后不影响本包单独使用）"
	echo ""
fi

if [ "$${PKG_UPGRADE}" = "1" ] || [ -e "$${UPGRADE_MARKER}" ]; then
	rm -f "$${UPGRADE_MARKER}"
else
	/usr/libexec/gately-plus-package.sh restore >/dev/null 2>&1 || true
	$${INITD}/gately-plus enable >/dev/null 2>&1 || true
	( setsid "$${INITD}/gately-plus" start </dev/null >/dev/null 2>&1 & )
fi
$${INITD}/rpcd reload >/dev/null 2>&1 || true
rm -rf /tmp/luci-*
exit 0
endef

define Package/$(PKG_NAME)/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
/usr/libexec/gately-plus-package.sh uninstall "$$@" >/dev/null 2>&1 || true
rm -rf /tmp/luci-*
exit 0
endef

define Package/$(PKG_NAME)/postrm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
PURGE_LIST=/tmp/gately-plus-luci-app-purge
KEEP_FILE=/tmp/gately-plus-luci-app-keep
if [ -f "$${PURGE_LIST}" ]; then
	while IFS= read -r path; do
		case "$${path}" in
			/*)
				case "$${path}" in
					/|/etc|/etc/config|/usr|/usr/bin|/usr/sbin|/bin|/sbin|/var|/tmp|/root|/home) continue ;;
					*'/../'*|*'/..'|*'/./'*|*'/.'|*//*|*[!A-Za-z0-9_./-]*) continue ;;
				esac
				rm -rf "$${path}"
				;;
		esac
	done < "$${PURGE_LIST}"
	rm -f "$${PURGE_LIST}"
fi
# 卸载不删用户数据：二进制与数据目录由 prerm 记录在 KEEP_FILE，这里只做提示
if [ -f "$${KEEP_FILE}" ]; then
	echo ""
	echo "luci-app-gately-plus 已卸载。下列内容按设计保留，未删除："
	while IFS= read -r keep; do
		[ -n "$${keep}" ] && echo "  $${keep}"
	done < "$${KEEP_FILE}"
	echo "  /etc/config/gately_plus"
	echo "如需彻底清理，请自行删除以上路径。"
	echo ""
	rm -f "$${KEEP_FILE}"
fi
/etc/init.d/rpcd reload >/dev/null 2>&1 || true
rm -rf /tmp/luci-*
exit 0
endef

$(eval $(call BuildPackage,$(PKG_NAME)))
