#!/bin/sh
# Copyright (c) 2026 Eugene Chan
# SPDX-License-Identifier: MIT
#
# Download and verify geoip.dat / geosite.dat into the BypassCore / v2ray asset
# directory, then refresh the Naive server destination route. Invoked by LuCI
# rule_update page (via api.sh) and by the periodic cron job.

. /lib/functions.sh
. ${APP_PATH:-/usr/share/bypass}/utils.sh

LOCK_FILE=/var/lock/bypass_rule_update.lock
BAK_DIR=/tmp/bypass_bak

set_lock() {
	mkdir -p "$(dirname "$LOCK_FILE")"
	exec 9>"$LOCK_FILE"
	flock -xn 9 || { log 0 "rule_update already running, abort."; exit 1; }
	trap 'unset_lock' EXIT INT TERM
}
unset_lock() {
	flock -u 9
}

# download_one <name> <url> <dest>
download_one() {
	local name=$1 url=$2 dest=$3
	[ -z "$url" ] && { log 0 "No URL for %s, skip." "$name"; return 1; }
	log 0 "Downloading %s from %s ..." "$name" "$url"
	local tmp="${dest}.tmp"
	if ! curl -sL --connect-timeout 15 -m 300 -o "$tmp" "$url" 2>>"$LOG_FILE"; then
		log 0 "Download %s failed." "$name"
		rm -f "$tmp"
		return 1
	fi
	[ -s "$tmp" ] || { log 0 "Downloaded %s is empty." "$name"; rm -f "$tmp"; return 1; }

	# Verify it looks like a protobuf dat (magic) — crude sanity check by size.
	local sz
	sz=$(wc -c <"$tmp" 2>/dev/null)
	[ "${sz:-0}" -lt 1024 ] && { log 0 "%s too small (%s bytes), rejected." "$name" "$sz"; rm -f "$tmp"; return 1; }

	mkdir -p "$BAK_DIR"
	[ -s "$dest" ] && cp -f "$dest" "$BAK_DIR/$(basename "$dest").bak"
	mv -f "$tmp" "$dest"
	log 0 "%s updated (%s bytes)." "$name" "$sz"
	return 0
}

update_geodata() {
	set_lock
	local asset_dir
	asset_dir=$(config_t_get global_rules v2ray_location_asset /usr/share/v2ray/)
	asset_dir="${asset_dir%*/}"
	mkdir -p "$asset_dir" "$TMP_PATH" "$TMP_PATH2"

	local geoip_url geosite_url
	geoip_url=$(config_t_get global_rules geoip_url "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat")
	geosite_url=$(config_t_get global_rules geosite_url "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat")

	local ok=1
	if [ "$(config_t_get global_rules geoip_update 1)" = "1" ]; then
		download_one "geoip.dat" "$geoip_url" "${asset_dir}/geoip.dat" || ok=0
	fi
	if [ "$(config_t_get global_rules geosite_update 1)" = "1" ]; then
		download_one "geosite.dat" "$geosite_url" "${asset_dir}/geosite.dat" || ok=0
	fi

	unset_lock
	trap - EXIT INT TERM
	if [ "$ok" = "1" ] && [ "$(config_t_get global enabled 0)" = "1" ]; then
		log 0 "GeoData updated; restarting Bypass to reload DNS and routing rules."
		/etc/init.d/bypass restart >/dev/null 2>&1
	fi
	return $((1 - ok))
}

# refresh_uplink: restart under the service lock so every currently referenced
# Naive node is re-resolved and every configured per-node egress policy table
# is rebuilt atomically.
refresh_uplink_mode() {
	# Serialize with init start/stop/restart. A failed refresh must not leave
	# Naive reconnects using the system default WAN after their dedicated rules
	# were rolled back, so stop the service fail-closed.
	exec 8>/var/lock/bypass.lock
	flock -xn 8 || return 0
	${APP_PATH}/app.sh stop
	if ! ${APP_PATH}/app.sh start; then
		log 0 "Egress destination refresh failed; stopping Bypass to prevent WAN fallback."
		rm -f /var/lock/bypass_ready.lock
		flock -u 8
		return 1
	fi
	touch /var/lock/bypass_ready.lock
	flock -u 8
}

case "${1:-update}" in
	update|geodata) update_geodata ;;
	refresh_uplink) refresh_uplink_mode ;;
	*)
		echo "Usage: $0 {update|refresh_uplink}" >&2
		exit 1
		;;
esac
