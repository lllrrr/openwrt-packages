#!/bin/sh
# Subscribe cron management script for sxray
# Called from init.d/sxray start_service or manually

APPNAME="sxray"
SUBSCRIBE_SCRIPT="/usr/share/sxray/subscribe.lua"
CRONTAB_FILE="/etc/crontabs/root"

# Clean sxray subscribe entries from crontab
clean_subscribe_crontab() {
	[ -f "$CRONTAB_FILE" ] || return
	sed -i "/$(echo "lua ${SUBSCRIBE_SCRIPT}" | sed 's#\/#\\\/#g')/d" "$CRONTAB_FILE" 2>/dev/null
}

# Setup cron entries for subscriptions with auto_update enabled
setup_subscribe_crontab() {
	clean_subscribe_crontab

	local TMP_SUB_PATH="/tmp/${APPNAME}_sub_crontabs"
	mkdir -p "$TMP_SUB_PATH"

	# Iterate all subscribe_list entries
	for item in $(uci show ${APPNAME} 2>/dev/null | grep "=subscribe_list" | cut -d '.' -sf 2 | cut -d '=' -sf 1); do
		local auto_update=$(uci -q get ${APPNAME}.${item}.auto_update)
		if [ "$auto_update" = "1" ]; then
			local cfgid=$(uci show ${APPNAME}.${item} 2>/dev/null | head -n 1 | cut -d '.' -sf 2 | cut -d '=' -sf 1)
			local remark=$(uci -q get ${APPNAME}.${item}.remark)
			local week_update=$(uci -q get ${APPNAME}.${item}.week_update)
			local time_update=$(uci -q get ${APPNAME}.${item}.time_update)
			local interval_update=$(uci -q get ${APPNAME}.${item}.interval_update)

			if [ -n "$week_update" ] && [ -n "$cfgid" ]; then
				echo "$cfgid" >> "${TMP_SUB_PATH}/${week_update}_${time_update}_${interval_update}"
			fi
		fi
	done

	if [ -d "$TMP_SUB_PATH" ]; then
		for name in $(ls "$TMP_SUB_PATH" 2>/dev/null); do
			local week_update=$(echo "$name" | awk -F '_' '{print $1}')
			local time_update=$(echo "$name" | awk -F '_' '{print $2}')
			local interval_update=$(echo "$name" | awk -F '_' '{print $3}')
			local cfgids=$(echo -n $(cat "${TMP_SUB_PATH}/${name}") | sed 's# #,#g')

			if [ "$week_update" = "8" ]; then
				# Loop mode: every N hours
				local hours="${interval_update:-2}"
				echo "0 */${hours} * * * lua ${SUBSCRIBE_SCRIPT} start ${cfgids} cron > /dev/null 2>&1 &" >> "$CRONTAB_FILE"
			else
				# Weekly/daily mode
				local t="0 ${time_update} * * ${week_update}"
				[ "$week_update" = "7" ] && t="0 ${time_update} * * *"
				echo "$t lua ${SUBSCRIBE_SCRIPT} start ${cfgids} cron > /dev/null 2>&1 &" >> "$CRONTAB_FILE"
			fi
		done
		rm -rf "$TMP_SUB_PATH"
	fi
}

# Handle boot update: subscribe on first start after boot
handle_boot_update() {
	local BOOT_FLAG="/tmp/${APPNAME}_boot_subscribe_done"
	[ -f "$BOOT_FLAG" ] && return

	for item in $(uci show ${APPNAME} 2>/dev/null | grep "=subscribe_list" | cut -d '.' -sf 2 | cut -d '=' -sf 1); do
		local boot_update=$(uci -q get ${APPNAME}.${item}.boot_update)
		if [ "$boot_update" = "1" ]; then
			local cfgid=$(uci show ${APPNAME}.${item} 2>/dev/null | head -n 1 | cut -d '.' -sf 2 | cut -d '=' -sf 1)
			if [ -n "$cfgid" ]; then
				lua ${SUBSCRIBE_SCRIPT} start ${cfgid} manual > /dev/null 2>&1 &
			fi
		fi
	done
	touch "$BOOT_FLAG"
}

case "${1}" in
	clean)
		clean_subscribe_crontab
		;;
	setup)
		setup_subscribe_crontab
		;;
	boot)
		handle_boot_update
		;;
	*)
		setup_subscribe_crontab
		handle_boot_update
		;;
esac
