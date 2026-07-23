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
GEODATA_CHANGED=0

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
	if ! curl -fsSL --connect-timeout 15 -m 300 -o "$tmp" "$url" 2>>"$LOG_FILE"; then
		log 0 "Download %s failed." "$name"
		rm -f "$tmp"
		return 1
	fi
	[ -s "$tmp" ] || { log 0 "Downloaded %s is empty." "$name"; rm -f "$tmp"; return 1; }

	# Verify it looks like a protobuf dat (magic) — crude sanity check by size.
	local sz
	sz=$(wc -c <"$tmp" 2>/dev/null)
	[ "${sz:-0}" -lt 1024 ] && { log 0 "%s too small (%s bytes), rejected." "$name" "$sz"; rm -f "$tmp"; return 1; }
	if head -c 512 "$tmp" 2>/dev/null | grep -aiqE '<(!doctype|html)|bad gateway|access denied'; then
		log 0 "Downloaded %s is an HTML/proxy error response, rejected." "$name"
		rm -f "$tmp"
		return 1
	fi
	# A proxy/CDN error page can be larger than 1 KiB. When geoview is present,
	# parse the temporary protobuf before replacing the working asset.
	local validator geo_type
	validator=$(first_type "$(config_t_get global_app geoview_file /usr/bin/geoview)" geoview)
	geo_type=${name%.dat}
	if [ -n "$validator" ] && ! "$validator" -type "$geo_type" -action extract -input "$tmp" -lowmem=true >/dev/null 2>&1; then
		log 0 "Downloaded %s is not valid GeoData, rejected." "$name"
		rm -f "$tmp"
		return 1
	fi
	if [ -s "$dest" ] && cmp -s "$tmp" "$dest"; then
		log 1 "%s is already current; no service restart is needed." "$name"
		rm -f "$tmp"
		return 0
	fi

	mkdir -p "$BAK_DIR"
	[ -s "$dest" ] && cp -f "$dest" "$BAK_DIR/$(basename "$dest").bak"
	mv -f "$tmp" "$dest"
	GEODATA_CHANGED=1
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
	if [ "$GEODATA_CHANGED" = "1" ] && [ "$(config_t_get global enabled 0)" = "1" ]; then
		log 0 "GeoData changed; restarting Bypass to reload the validated files."
		/etc/init.d/bypass restart >/dev/null 2>&1 || {
			log 0 "Bypass failed to restart after the GeoData update."
			return 1
		}
	fi
	return $((1 - ok))
}

# Return success only when an interface-bound node's address pinned at startup
# is no longer present in DNS. System-default nodes need no destination policy
# rule and therefore do not need periodic restarts.
uplink_refresh_needed() {
	[ -s "$TMP_PATH/selected_naive_nodes" ] || return 1
	local node iface default_iface address pinned current="$TMP_PATH/uplink-current.$$" resolve_ok
	default_iface=$(config_t_get global_rules default_naive_interface)
	while read -r node; do
		[ -n "$node" ] || continue
		iface=$(config_n_get "$node" egress_interface)
		[ -n "$iface" ] || iface=$default_iface
		[ -n "$iface" ] || continue
		address=$(config_n_get "$node" address)
		pinned=$(cat "$TMP_PATH/naive_resolve.${node}" 2>/dev/null)
		# Literal server IPs do not use a resolver pin and cannot rotate.
		[ -n "$pinned" ] || continue
		: > "$current"
		resolve_all_ipv4 "$address" >> "$current"
		resolve_all_ipv6 "$address" >> "$current"
		resolve_ok=0
		[ -s "$current" ] && resolve_ok=1
		if [ "$resolve_ok" = "0" ]; then
			# Preserve the healthy existing tunnel on a transient resolver outage.
			log 1 "Could not refresh Naive node [%s] DNS; keeping its current pinned address." "$node"
			rm -f "$current"
			continue
		fi
		if ! grep -Fxq "$pinned" "$current"; then
			log 0 "Naive node [%s] address changed; refreshing its egress route and process." "$node"
			rm -f "$current"
			return 0
		fi
	done < "$TMP_PATH/selected_naive_nodes"
	rm -f "$current"
	return 1
}

# refresh_uplink: perform a serialized full refresh only after the conditional
# check above. BypassCore, Naive SOCKS and firewall/DNS state remain atomic.
refresh_uplink_mode() {
	[ -f /var/lock/bypass_ready.lock ] || return 0
	[ "$(config_t_get global enabled 0)" = "1" ] || return 0
	uplink_refresh_needed || return 0
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
	local redir_port
	redir_port=$(get_cache_var ACL_GLOBAL_redir_port)
	if [ "$(config_t_get global enabled 0)" = "1" ] && process_alive bypasscore && \
	   [ -n "$redir_port" ] && [ "$(check_port_exists "$redir_port" tcp)" -gt 0 ] 2>/dev/null; then
		touch /var/lock/bypass_ready.lock
	else
		rm -f /var/lock/bypass_ready.lock
		log 0 "Egress destination refresh did not produce a healthy BypassCore listener."
		flock -u 8
		return 1
	fi
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
