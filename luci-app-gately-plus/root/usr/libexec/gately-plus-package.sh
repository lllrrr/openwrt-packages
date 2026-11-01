#!/bin/sh
BACKUP_FILE=/tmp/gately-plus-luci-app-backup.tar.gz
UPGRADE_MARKER=/tmp/gately-plus-luci-app-upgrade
PURGE_LIST=/tmp/gately-plus-luci-app-purge
KEEP_FILE=/tmp/gately-plus-luci-app-keep
DEFAULT_BIN=/usr/bin/gately
DEFAULT_DATA=/etc/gately

uci_get() {
	local value
	value="$(uci -q get "gately_plus.gately.$1" 2>/dev/null)"
	if [ -n "$value" ]; then
		printf '%s' "$value"
	else
		printf '%s' "$2"
	fi
}

safe_path() {
	local path="$1"
	case "$path" in
		/*) ;;
		*) return 1 ;;
	esac
	while [ "$path" != "/" ] && [ "${path%/}" != "$path" ]; do
		path="${path%/}"
	done
	case "$path" in
		/|/etc|/etc/config|/usr|/usr/bin|/usr/sbin|/bin|/sbin|/var|/tmp|/root|/home) return 1 ;;
		*'/../'*|*'/..'|*'/./'*|*'/.'|*//*|*[!A-Za-z0-9_./-]*) return 1 ;;
	esac
	printf '%s' "$path"
}

safe_data_path() {
	local path
	path="$(safe_path "$1")" || return 1
	[ "$path" != "/etc/config/gately_plus" ] || return 1
	printf '%s' "$path"
}

safe_binary_path() {
	local path
	path="$(safe_path "$1")" || return 1
	[ ! -d "$path" ] || return 1
	printf '%s' "$path"
}

pkg_upgrading() {
	local pid="$$" depth=0 args
	[ "${PKG_UPGRADE:-0}" = "1" ] && return 0
	case " $* " in
		*" upgrade "*) return 0 ;;
	esac
	while [ "$depth" -lt 16 ]; do
		case "$pid" in
			''|*[!0-9]*|0|1) return 1 ;;
		esac
		args="$(tr '\000' ' ' <"/proc/$pid/cmdline" 2>/dev/null)"
		case "${args%% *}" in
			opkg|*/opkg) case " $args " in *" install "*|*" upgrade "*) return 0 ;; esac ;;
			apk|*/apk) case " $args " in *" add "*|*" upgrade "*|*" fix "*) return 0 ;; esac ;;
		esac
		pid="$(sed -n 's/^PPid:[[:space:]]*//p' "/proc/$pid/status" 2>/dev/null)"
		depth=$((depth + 1))
	done
	return 1
}

purge_cron() {
	local cron=/etc/crontabs/root init=/etc/init.d/cron
	grep -q 'luci-app-gately-plus-autoupdate' "$cron" 2>/dev/null || return 0
	sed -i '/luci-app-gately-plus-autoupdate/d' "$cron" 2>/dev/null || return 1
	[ -x "$init" ] && "$init" restart >/dev/null 2>&1 || true
}

# 只清理包管理器残留的临时文件。
# 二进制、数据目录、/etc/config/gately_plus 一律保留 —— 卸载插件不等于删用户数据。
write_purge_list() {
	{
		printf '%s\n' \
			/tmp/.uci/gately_plus \
			/etc/config/gately_plus-opkg \
			/etc/config/gately_plus.apk-new
	} >"$PURGE_LIST"
}

uninstall_package() {
	local bin_path data_path init=/etc/init.d/gately-plus
	rm -f "$PURGE_LIST" "$BACKUP_FILE"
	if pkg_upgrading "$@"; then
		: >"$UPGRADE_MARKER"
		return 0
	fi
	rm -f "$UPGRADE_MARKER"
	bin_path="$(safe_binary_path "$(uci_get binpath "$DEFAULT_BIN")")" || bin_path=''
	data_path="$(safe_data_path "$(uci_get configdir "$DEFAULT_DATA")")" || data_path=''
	if [ -x "$init" ]; then
		"$init" stop >/dev/null 2>&1 || true
		"$init" disable >/dev/null 2>&1 || true
	fi
	purge_cron || true
	uci -q commit gately_plus >/dev/null 2>&1 || true
	# 注意：这里不打包备份、也不交给 postrm 删除。
	# 卸载后重新安装时，原二进制与数据目录仍在，配置直接可用。
	write_purge_list
	{
		[ -n "$bin_path" ] && printf '%s\n' "$bin_path"
		[ -n "$data_path" ] && printf '%s\n' "$data_path"
	} >"$KEEP_FILE"
}

restore_backup() {
	local members member
	[ -f "$BACKUP_FILE" ] && [ -O "$BACKUP_FILE" ] || return 0
	members="$(tar -tzf "$BACKUP_FILE" 2>/dev/null)" || return 1
	for member in $members; do
		case "$member" in
			/*|./*|*/./*|*/.|../*|*/../*|*/..|*//* ) return 1 ;;
		esac
	done
	if tar -xzf "$BACKUP_FILE" -C / 2>/dev/null; then
		uci -q commit gately_plus >/dev/null 2>&1 || true
		rm -f "$BACKUP_FILE"
	fi
}

case "${1:-}" in
	restore) restore_backup ;;
	uninstall) shift; uninstall_package "$@" ;;
	*) exit 2 ;;
esac
