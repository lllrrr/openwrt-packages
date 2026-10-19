#!/bin/sh

# luci-app-shellcrash control backend

CRASHDIR=""
detect_crashdir() {
	if [ -n "$CRASHDIR" ] && [ -d "$CRASHDIR" ]; then
		return 0
	fi
	local uci_dir
	uci_dir=$(uci -q get shellcrash.main.crashdir)
	if [ -n "$uci_dir" ] && [ -d "$uci_dir" ]; then
		CRASHDIR="$uci_dir"
		return 0
	fi
	for d in /etc/ShellCrash /data/ShellCrash /tmp/ShellCrash /root/ShellCrash; do
		if [ -d "$d" ]; then
			CRASHDIR="$d"
			return 0
		fi
	done
	CRASHDIR="/etc/ShellCrash"
}

get_cfg_val() {
	local key="$1"
	local file="$CRASHDIR/configs/ShellCrash.cfg"
	if [ -f "$file" ]; then
		grep -E "^${key}=" "$file" 2>/dev/null | tail -n1 | cut -d'=' -f2- | tr -d '\r'
	fi
}

get_api_info() {
	detect_crashdir
	local uci_port uci_sec
	uci_port=$(uci -q get shellcrash.main.api_port)
	uci_sec=$(uci -q get shellcrash.main.secret)

	API_PORT="$uci_port"
	[ -z "$API_PORT" ] && API_PORT=$(get_cfg_val "db_port")
	[ -z "$API_PORT" ] && API_PORT="9999"

	SECRET="$uci_sec"
	[ -z "$SECRET" ] && SECRET=$(get_cfg_val "secret")

	MIX_PORT=$(uci -q get shellcrash.main.mixed_port)
	[ -z "$MIX_PORT" ] && MIX_PORT=$(get_cfg_val "mix_port")
	[ -z "$MIX_PORT" ] && MIX_PORT="7890"

	REDIR_PORT=$(get_cfg_val "redir_port")
	[ -z "$REDIR_PORT" ] && REDIR_PORT="7892"

	TPROXY_PORT=$(get_cfg_val "tproxy_port")
	[ -z "$TPROXY_PORT" ] && TPROXY_PORT="7893"

	DNS_PORT=$(get_cfg_val "dns_port")
	[ -z "$DNS_PORT" ] && DNS_PORT="1053"
}

cmd_status() {
	detect_crashdir
	get_api_info

	local installed="false"
	if [ -f "$CRASHDIR/init.sh" ] || [ -f "$CRASHDIR/start.sh" ]; then
		installed="true"
	fi

	local pid=""
	if [ "$installed" = "true" ]; then
		pid=$(pidof CrashCore 2>/dev/null | awk '{print $NF}')
	fi

	local running="false"
	local mem_mb="0.00 MB"
	local uptime_s=""
	local uptime_str="0s"

	if [ -n "$pid" ] && [ -d "/proc/$pid" ]; then
		running="true"
		local rss_kb
		rss_kb=$(grep -s VmRSS "/proc/$pid/status" | awk '{print $2}')
		if [ -n "$rss_kb" ]; then
			mem_mb=$(awk -v k="$rss_kb" 'BEGIN { printf "%.2f MB", k / 1024 }')
		fi
		# Calculate uptime from stat start_time
		if [ -f "/proc/uptime" ] && [ -f "/proc/$pid/stat" ]; then
			local sys_up pid_ticks hertz
			sys_up=$(cut -d' ' -f1 /proc/uptime | cut -d'.' -f1)
			pid_ticks=$(cut -d' ' -f22 "/proc/$pid/stat")
			hertz=100
			if [ -n "$sys_up" ] && [ -n "$pid_ticks" ]; then
				local start_sec=$((pid_ticks / hertz))
				local run_sec=$((sys_up - start_sec))
				if [ "$run_sec" -gt 0 ]; then
					local days=$((run_sec / 86400))
					local hrs=$(((run_sec % 86400) / 3600))
					local mins=$(((run_sec % 3600) / 60))
					local secs=$((run_sec % 60))
					if [ "$days" -gt 0 ]; then
						uptime_str="${days}d ${hrs}h ${mins}m"
					elif [ "$hrs" -gt 0 ]; then
						uptime_str="${hrs}h ${mins}m"
					elif [ "$mins" -gt 0 ]; then
						uptime_str="${mins}m ${secs}s"
					else
						uptime_str="${secs}s"
					fi
				fi
			fi
		fi
	fi

	# Core info
	local core_name core_type core_ver
	core_name=$(get_cfg_val "crashcore")
	[ -z "$core_name" ] && core_name="meta"
	case "$core_name" in
		meta|mihomo) core_type="Mihomo / Clash.Meta" ;;
		singbox*) core_type="Sing-Box" ;;
		clash) core_type="Clash OpenSource" ;;
		*) core_type="$core_name" ;;
	esac

	if [ -x "$CRASHDIR/CrashCore" ]; then
		core_ver=$("$CRASHDIR/CrashCore" -v 2>&1 | head -n1)
	elif [ -x "$CRASHDIR/bin/CrashCore" ]; then
		core_ver=$("$CRASHDIR/bin/CrashCore" -v 2>&1 | head -n1)
	else
		core_ver="未知版本"
	fi

	# ShellCrash script version
	local sc_ver="未知"
	if [ -f "$CRASHDIR/version" ]; then
		sc_ver=$(cat "$CRASHDIR/version" | tr -d '\r\n')
	fi

	# Autostart status
	local autostart="false"
	if [ -f /etc/init.d/shellcrash ]; then
		if /etc/init.d/shellcrash enabled 2>/dev/null; then
			autostart="true"
		fi
	fi

	# Mode
	local redir_mod
	redir_mod=$(get_cfg_val "redir_mod")
	[ -z "$redir_mod" ] && redir_mod="Redir"

	# API OK check
	local api_ok="false"
	if [ "$running" = "true" ]; then
		local auth_hdr=""
		[ -n "$SECRET" ] && auth_hdr="Authorization: Bearer $SECRET"
		if curl -s -f -m 2 -H "$auth_hdr" "http://127.0.0.1:$API_PORT/version" >/dev/null 2>&1; then
			api_ok="true"
		fi
	fi

	# Panel installed
	local panel_core="false" panel_local="false"
	[ -d "$CRASHDIR/bin/dashboard" ] || [ -d "$CRASHDIR/ui" ] && panel_core="true"
	[ -d "/www/zashboard" ] || [ -d "/www/metacubexd" ] || [ -d "/www/yacd" ] && panel_local="true"

	local arch
	arch=$(uname -m)

	cat <<EOF
{
  "installed": $installed,
  "running": $running,
  "pid": "${pid:-0}",
  "mem_mb": "$mem_mb",
  "uptime": "$uptime_str",
  "crashdir": "$CRASHDIR",
  "core": "$core_name",
  "core_type": "$core_type",
  "core_version": "$core_ver",
  "shellcrash_ver": "$sc_ver",
  "autostart": $autostart,
  "run_mode": "$redir_mod",
  "api_port": $API_PORT,
  "api_ok": $api_ok,
  "mix_port": $MIX_PORT,
  "redir_port": $REDIR_PORT,
  "tproxy_port": $TPROXY_PORT,
  "dns_port": $DNS_PORT,
  "secret": "$SECRET",
  "panel_core_installed": $panel_core,
  "panel_local_installed": $panel_local,
  "arch": "$arch"
}
EOF
}

cmd_start() {
	detect_crashdir
	if [ -x /etc/init.d/shellcrash ]; then
		/etc/init.d/shellcrash start >/dev/null 2>&1
	elif [ -x "$CRASHDIR/start.sh" ]; then
		sh "$CRASHDIR/start.sh" start >/dev/null 2>&1
	else
		echo '{"success": false, "message": "ShellCrash not installed"}'
		return 1
	fi
	sleep 1
	echo '{"success": true}'
}

cmd_stop() {
	detect_crashdir
	if [ -x /etc/init.d/shellcrash ]; then
		/etc/init.d/shellcrash stop >/dev/null 2>&1
	elif [ -x "$CRASHDIR/start.sh" ]; then
		sh "$CRASHDIR/start.sh" stop >/dev/null 2>&1
	fi
	killall CrashCore mihomo clash-meta sing-box clash >/dev/null 2>&1
	sleep 1
	echo '{"success": true}'
}

cmd_restart() {
	cmd_stop >/dev/null 2>&1
	sleep 1
	cmd_start
}

cmd_reload() {
	detect_crashdir
	get_api_info
	local auth_hdr=""
	[ -n "$SECRET" ] && auth_hdr="Authorization: Bearer $SECRET"
	local res
	res=$(curl -s -m 5 -X PUT -H "$auth_hdr" -H "Content-Type: application/json" -d '{"path": ""}' "http://127.0.0.1:$API_PORT/configs?force=true" 2>&1)
	if [ $? -eq 0 ]; then
		echo '{"success": true}'
	else
		echo "{\"success\": false, \"message\": \"$res\"}"
	fi
}

cmd_enable() {
	if [ -x /etc/init.d/shellcrash ]; then
		/etc/init.d/shellcrash enable >/dev/null 2>&1
		echo '{"success": true}'
	else
		echo '{"success": false, "message": "init script not found"}'
	fi
}

cmd_disable() {
	if [ -x /etc/init.d/shellcrash ]; then
		/etc/init.d/shellcrash disable >/dev/null 2>&1
		echo '{"success": true}'
	else
		echo '{"success": false, "message": "init script not found"}'
	fi
}

cmd_install() {
	detect_crashdir
	mkdir -p "$CRASHDIR"
	if [ -f "/usr/share/shellcrash/ShellCrash.tar.gz" ]; then
		tar -zxf /usr/share/shellcrash/ShellCrash.tar.gz -C "$CRASHDIR/" >/dev/null 2>&1
		if [ -f "$CRASHDIR/init.sh" ]; then
			CRASHDIR="$CRASHDIR" sh "$CRASHDIR/init.sh" >/dev/null 2>&1
			if [ ! -f /etc/init.d/shellcrash ] && [ -f "$CRASHDIR/starts/shellcrash.procd" ]; then
				cp -f "$CRASHDIR/starts/shellcrash.procd" /etc/init.d/shellcrash
				chmod 755 /etc/init.d/shellcrash
			fi
			echo '{"success": true, "message": "Offline installation completed successfully"}'
			return 0
		fi
	fi
	echo '{"success": false, "message": "Installation package not found"}'
	return 1
}

cmd_ping() {
	get_api_info
	local targets
	targets=$(uci -q get shellcrash.main.ping_targets)
	[ -z "$targets" ] && targets="百度|https://www.baidu.com/ 谷歌|https://www.google.com/generate_204 GitHub|https://github.com/ YouTube|https://www.youtube.com/"

	printf '{"results": ['
	local first=1
	for item in $targets; do
		local name url
		name=$(echo "$item" | cut -d'|' -f1)
		url=$(echo "$item" | cut -d'|' -f2)
		[ -z "$url" ] && continue

		local proxy_arg=""
		case "$url" in
			*baidu.com*) proxy_arg="" ;;
			*) proxy_arg="-x http://127.0.0.1:$MIX_PORT" ;;
		esac

		local latency_ms
		latency_ms=$(curl -s -o /dev/null $proxy_arg -w "%{time_total}" -m 3 "$url" 2>/dev/null)
		local delay="-1"
		if [ -n "$latency_ms" ]; then
			delay=$(awk -v t="$latency_ms" 'BEGIN { printf "%d", t * 1000 }')
			[ "$delay" -le 0 ] && delay="-1"
		fi

		[ "$first" = "0" ] && printf ','
		first=0
		printf '{"name": "%s", "url": "%s", "delay": %s}' "$name" "$url" "$delay"
	done
	printf ']}\n'
}

cmd_kernel_get() {
	get_api_info
	local auth_hdr=""
	[ -n "$SECRET" ] && auth_hdr="Authorization: Bearer $SECRET"
	curl -s -m 3 -H "$auth_hdr" "http://127.0.0.1:$API_PORT/configs" 2>/dev/null || echo '{}'
}

cmd_patch_api() {
	local data="$1"
	get_api_info
	local auth_hdr=""
	[ -n "$SECRET" ] && auth_hdr="Authorization: Bearer $SECRET"
	curl -s -m 3 -X PATCH -H "$auth_hdr" -H "Content-Type: application/json" -d "$data" "http://127.0.0.1:$API_PORT/configs" >/dev/null 2>&1
	echo '{"success": true}'
}

cmd_sub_get() {
	detect_crashdir
	local cfg="$CRASHDIR/configs/providers.cfg"
	if [ ! -f "$cfg" ]; then
		echo '{"subscriptions": []}'
		return 0
	fi
	printf '{"subscriptions": ['
	local first=1
	while IFS= read -r line || [ -n "$line" ]; do
		line=$(echo "$line" | tr -d '\r' | sed 's/^[ \t]*//')
		case "$line" in
			\#*|"") continue ;;
		esac
		local name url interval
		name=$(echo "$line" | cut -d'#' -f1)
		url=$(echo "$line" | cut -d'#' -f2)
		interval=$(echo "$line" | cut -d'#' -f3)
		[ -z "$name" ] && continue

		[ "$first" = "0" ] && printf ','
		first=0
		printf '{"name": "%s", "url": "%s", "interval": "%s"}' "$name" "$url" "$interval"
	done < "$cfg"
	printf ']}\n'
}

cmd_sub_update() {
	detect_crashdir
	if [ -x "$CRASHDIR/scripts/menus/providers.sh" ]; then
		sh "$CRASHDIR/scripts/menus/providers.sh" update >/dev/null 2>&1
		echo '{"success": true}'
	elif [ -x "$CRASHDIR/start.sh" ]; then
		sh "$CRASHDIR/start.sh" init >/dev/null 2>&1
		echo '{"success": true}'
	else
		echo '{"success": false, "message": "ShellCrash scripts not found"}'
	fi
}

cmd_cfg_read() {
	detect_crashdir
	local cfg="$CRASHDIR/configs/ShellCrash.cfg"
	if [ -f "$cfg" ]; then
		cat "$cfg"
	else
		echo "# ShellCrash.cfg not found"
	fi
}

cmd_cfg_write() {
	detect_crashdir
	local cfg="$CRASHDIR/configs/ShellCrash.cfg"
	mkdir -p "$CRASHDIR/configs"
	if [ -f "$cfg" ]; then
		cp "$cfg" "$cfg.bak"
	fi
	cat > "$cfg"
	echo '{"success": true}'
}

cmd_cfg_restore() {
	detect_crashdir
	local cfg="$CRASHDIR/configs/ShellCrash.cfg"
	if [ -f "$cfg.bak" ]; then
		cp "$cfg.bak" "$cfg"
		echo '{"success": true}'
	else
		echo '{"success": false, "message": "Backup file not found"}'
	fi
}

cmd_logs() {
	detect_crashdir
	local lines="$1"
	[ -z "$lines" ] && lines=$(uci -q get shellcrash.main.log_lines)
	[ -z "$lines" ] && lines="200"

	for logf in "$CRASHDIR/debug.log" "/tmp/ShellCrash/debug.log" "$CRASHDIR/yamls/clash.log"; do
		if [ -f "$logf" ]; then
			tail -n "$lines" "$logf"
			return 0
		fi
	done

	# Fallback to logread
	logread -e shellcrash -l "$lines" 2>/dev/null || echo "暂无运行日志"
}

case "$1" in
	status) cmd_status ;;
	start) cmd_start ;;
	stop) cmd_stop ;;
	restart) cmd_restart ;;
	reload) cmd_reload ;;
	enable) cmd_enable ;;
	disable) cmd_disable ;;
	install) cmd_install ;;
	ping) cmd_ping ;;
	kernel-get) cmd_kernel_get ;;
	mode-rule) cmd_patch_api '{"mode":"Rule"}' ;;
	mode-global) cmd_patch_api '{"mode":"Global"}' ;;
	mode-direct) cmd_patch_api '{"mode":"Direct"}' ;;
	log-silent) cmd_patch_api '{"log-level":"silent"}' ;;
	log-error) cmd_patch_api '{"log-level":"error"}' ;;
	log-warning) cmd_patch_api '{"log-level":"warning"}' ;;
	log-info) cmd_patch_api '{"log-level":"info"}' ;;
	log-debug) cmd_patch_api '{"log-level":"debug"}' ;;
	allow-lan-on) cmd_patch_api '{"allow-lan":true}' ;;
	allow-lan-off) cmd_patch_api '{"allow-lan":false}' ;;
	ipv6-on) cmd_patch_api '{"ipv6":true}' ;;
	ipv6-off) cmd_patch_api '{"ipv6":false}' ;;
	tcp-concurrent-on) cmd_patch_api '{"tcp-concurrent":true}' ;;
	tcp-concurrent-off) cmd_patch_api '{"tcp-concurrent":false}' ;;
	sub-get) cmd_sub_get ;;
	sub-update) cmd_sub_update ;;
	cfg-read) cmd_cfg_read ;;
	cfg-write) cmd_cfg_write ;;
	cfg-restore) cmd_cfg_restore ;;
	logs) cmd_logs "$2" ;;
	*)
		echo "Usage: $0 {status|start|stop|restart|reload|enable|disable|install|ping|kernel-get|mode-*|log-*|allow-lan-*|ipv6-*|sub-*|cfg-*|logs}"
		exit 1
		;;
esac
