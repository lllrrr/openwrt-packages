#!/bin/sh
# Manage OpenWrt crontab tasks for WRTBox core & subscription auto-updates

CRON_FILE="/etc/crontabs/root"

sync_cron() {
	mkdir -p /etc/crontabs
	touch "$CRON_FILE"

	local tmp_cron="/tmp/wrtbox_cron_$$"
	grep -v '# wrtbox-auto-' "$CRON_FILE" > "$tmp_cron" 2>/dev/null || true

	local core_auto core_expr core_chan sub_auto sub_expr
	core_auto="$(uci -q get wrtbox.main.core_auto_update)"
	core_expr="$(uci -q get wrtbox.main.core_update_cron)"
	core_chan="$(uci -q get wrtbox.main.core_channel)"
	sub_auto="$(uci -q get wrtbox.main.sub_auto_update)"
	sub_expr="$(uci -q get wrtbox.main.sub_update_cron)"

	if [ "$core_auto" = "1" ] && [ -n "$core_expr" ]; then
		printf '%s /usr/libexec/wrtbox/core-manager.sh install %s >/dev/null 2>&1 # wrtbox-auto-core\n' \
			"$core_expr" "${core_chan:-stable}" >> "$tmp_cron"
	fi

	if [ "$sub_auto" = "1" ] && [ -n "$sub_expr" ]; then
		printf '%s /usr/libexec/wrtbox/sub-manager.uc fetch_all >/dev/null 2>&1 # wrtbox-auto-sub\n' \
			"$sub_expr" >> "$tmp_cron"
	fi

	mv -f "$tmp_cron" "$CRON_FILE"
	/etc/init.d/cron reload >/dev/null 2>&1 || /etc/init.d/cron restart >/dev/null 2>&1 || true
}

remove_cron() {
	[ -f "$CRON_FILE" ] || return 0
	local tmp_cron="/tmp/wrtbox_cron_$$"
	grep -v '# wrtbox-auto-' "$CRON_FILE" > "$tmp_cron" 2>/dev/null || true
	mv -f "$tmp_cron" "$CRON_FILE"
	/etc/init.d/cron reload >/dev/null 2>&1 || true
}

case "$1" in
	sync)
		sync_cron
		;;
	remove)
		remove_cron
		;;
	*)
		echo "Usage: $0 {sync|remove}" >&2
		exit 1
		;;
esac
