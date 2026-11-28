#!/bin/sh
# AdGuard Home 管理中心 - 旧版残留检测与清理
# 用法：
#   legacy_cleanup.sh scan    输出 JSON 清单，不修改系统
#   legacy_cleanup.sh clean   备份后清理旧插件文件与旧内核
#
# 说明：
# - 只处理旧版 luci-app-adguardhome 的文件与旧内核，不删除当前插件内核；
# - 不删除 /etc/AdGuardHome.yaml 与 /etc/AdGuardHome/（用户配置与统计）；
# - 所有被删文件先复制到 /etc/adguardhome_lite/legacy-backup-<时间戳>/。

OLD_APPS="luci-app-adguardhome luci-i18n-adguardhome-zh-cn"
OLD_FILES="/usr/lib/lua/luci/controller/adguardhome.lua
/usr/lib/lua/luci/model/cbi/adguardhome.lua
/usr/lib/lua/luci/view/adguardhome
/www/luci-static/resources/view/adguardhome
/usr/share/luci/menu.d/luci-app-adguardhome.json
/usr/share/rpcd/acl.d/luci-app-adguardhome.json
/etc/init.d/adguardhome"
OLD_KERNELS="/usr/bin/AdGuardHome /usr/sbin/AdGuardHome"
# opkg 升级时会把旧 conffile 存成 <包名>-opkg。这些文件没有任何代码引用，
# 却常被误当成当前配置手动编辑，且不会随卸载删除。
OLD_CONF_RESIDUE="/etc/config/adguardhome_lite-opkg /etc/config/adguardhome-opkg"
BACKUP_ROOT="/etc/adguardhome_lite"

json_escape() {
	printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

pkg_installed() {
	if command -v opkg >/dev/null 2>&1; then
		opkg list-installed "$1" 2>/dev/null | grep -q "^$1 "
		return $?
	fi
	if command -v apk >/dev/null 2>&1; then
		apk info -e "$1" >/dev/null 2>&1
		return $?
	fi
	return 1
}

pkg_remove() {
	if command -v opkg >/dev/null 2>&1; then
		opkg remove --force-depends "$1" >/dev/null 2>&1
	elif command -v apk >/dev/null 2>&1; then
		apk del "$1" >/dev/null 2>&1
	fi
}

scan() {
	local count=0 items=""
	add_item() {
		local kind="$1" name="$2" path="$3" note="$4"
		count=$((count + 1))
		[ -n "$items" ] && items="$items,"
		items="$items{\"kind\":\"$kind\",\"name\":\"$(json_escape "$name")\",\"path\":\"$(json_escape "$path")\",\"note\":\"$(json_escape "$note")\"}"
	}

	local p
	for p in $OLD_APPS; do
		if pkg_installed "$p"; then
			add_item "package" "$p" "$p" "已安装旧插件包，会随清理卸载"
		fi
	done

	if [ -f /etc/init.d/adguardhome ]; then
		add_item "service" "旧版启动脚本" "/etc/init.d/adguardhome" "将被停止、禁用并删除"
	fi

	local f
	for f in $OLD_FILES; do
		[ -e "$f" ] || continue
		case "$f" in
			/etc/init.d/adguardhome) continue ;;
		esac
		add_item "luci" "旧版 LuCI 文件" "$f" "将被删除，先备份"
	done

	local k
	for k in $OLD_KERNELS; do
		[ -f "$k" ] || continue
		add_item "kernel" "旧内核文件" "$k" "将移动到备份目录"
	done

	local c
	for c in $OLD_CONF_RESIDUE; do
		[ -f "$c" ] || continue
		add_item "conffile" "旧配置模板残留" "$c" "opkg 升级遗留，未被任何代码使用，可安全备份后删除"
	done

	printf '{"ok":true,"count":%s,"items":[%s]}\n' "$count" "$items"
}

clean() {
	local ts bk removed=0 svc_stopped=0
	ts=$(date +%Y%m%d%H%M%S)
	bk="$BACKUP_ROOT/legacy-backup-$ts"

	# 停止旧服务，避免占用 53 端口或覆盖 DNSMasq 配置
	if [ -x /etc/init.d/adguardhome ]; then
		/etc/init.d/adguardhome stop >/dev/null 2>&1
		/etc/init.d/adguardhome disable >/dev/null 2>&1
		svc_stopped=1
	fi

	mkdir -p "$bk" 2>/dev/null

	local p
	for p in $OLD_APPS; do
		if pkg_installed "$p"; then
			pkg_remove "$p"
			removed=$((removed + 1))
		fi
	done

	local f
	for f in $OLD_FILES; do
		[ -e "$f" ] || continue
		mkdir -p "$bk$(dirname "$f")" 2>/dev/null
		cp -a "$f" "$bk$f" >/dev/null 2>&1
		rm -rf "$f"
		removed=$((removed + 1))
	done

	local k
	for k in $OLD_KERNELS; do
		[ -f "$k" ] || continue
		mkdir -p "$bk$(dirname "$k")" 2>/dev/null
		mv "$k" "$bk$k" >/dev/null 2>&1
		removed=$((removed + 1))
	done

	# 旧 conffile 残留：只备份后删除，绝不改动当前 /etc/config/adguardhome_lite
	local c
	for c in $OLD_CONF_RESIDUE; do
		[ -f "$c" ] || continue
		mkdir -p "$bk$(dirname "$c")" 2>/dev/null
		cp -a "$c" "$bk$c" >/dev/null 2>&1
		rm -f "$c"
		removed=$((removed + 1))
	done

	# 旧服务停止后恢复 DNSMasq，避免残留的端口/上游配置
	if [ "$svc_stopped" = "1" ]; then
		/etc/init.d/dnsmasq restart >/dev/null 2>&1
	fi

	rm -f /tmp/luci-indexcache /tmp/luci-indexcache.* 2>/dev/null
	rm -rf /tmp/luci-modulecache 2>/dev/null
	logger -t adguardhome_lite "legacy cleanup: removed=$removed backup=$bk" 2>/dev/null

	printf '{"ok":true,"removed":%s,"backup":"%s"}\n' "$removed" "$(json_escape "$bk")"
}

case "$1" in
	scan) scan ;;
	clean) clean ;;
	*) printf '{"ok":false,"error":"usage: legacy_cleanup.sh scan|clean"}\n' ;;
esac
