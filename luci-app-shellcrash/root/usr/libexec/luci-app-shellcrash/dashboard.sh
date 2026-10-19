#!/bin/sh

# Dashboard installation and status helper for luci-app-shellcrash

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
	for d in /etc/ShellCrash /data/ShellCrash /tmp/ShellCrash; do
		if [ -d "$d" ]; then
			CRASHDIR="$d"
			return 0
		fi
	done
	CRASHDIR="/etc/ShellCrash"
}

cmd_status() {
	detect_crashdir
	local core_inst="false" core_type="" core_path=""
	local local_inst="false" local_type="" local_path=""

	if [ -f "$CRASHDIR/bin/dashboard/index.html" ] || [ -f "$CRASHDIR/ui/index.html" ]; then
		core_inst="true"
		core_path="$CRASHDIR/bin/dashboard"
		[ ! -d "$core_path" ] && core_path="$CRASHDIR/ui"
		if grep -q -i "zashboard" "$core_path/index.html" 2>/dev/null; then
			core_type="zashboard"
		elif grep -q -i "metacubexd" "$core_path/index.html" 2>/dev/null; then
			core_type="metacubexd"
		else
			core_type="yacd"
		fi
	fi

	for d in /www/zashboard /www/metacubexd /www/yacd /www/dashboard; do
		if [ -f "$d/index.html" ]; then
			local_inst="true"
			local_path="$d"
			local_type="$(basename "$d")"
			break
		fi
	done

	cat <<EOF
{
  "core_installed": $core_inst,
  "core_type": "$core_type",
  "core_path": "$core_path",
  "local_installed": $local_inst,
  "local_type": "$local_type",
  "local_path": "$local_path"
}
EOF
}

cmd_install() {
	detect_crashdir
	local target="$1" # "core" or "local"
	local dtype="$2"  # "zashboard", "metacubexd", "yacd"
	[ -z "$dtype" ] && dtype="zashboard"

	local url=""
	case "$dtype" in
		zashboard)
			url="https://github.com/Zephyruso/zashboard/releases/latest/download/dist.zip"
			;;
		metacubexd)
			url="https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.zip"
			;;
		yacd)
			url="https://github.com/haishanh/yacd/archive/gh-pages.zip"
			;;
	esac

	local dest=""
	if [ "$target" = "core" ]; then
		dest="$CRASHDIR/bin/dashboard"
	else
		dest="/www/$dtype"
	fi

	mkdir -p /tmp/dashboard_install "$dest"
	local zipfile="/tmp/dashboard_install/dist.zip"
	
	# Download with retry
	curl -s -L -m 60 "$url" -o "$zipfile"
	if [ $? -ne 0 ] || [ ! -s "$zipfile" ]; then
		rm -rf /tmp/dashboard_install
		echo '{"success": false, "message": "Failed to download dashboard package"}'
		return 1
	fi

	unzip -o -q "$zipfile" -d /tmp/dashboard_install/
	rm -f "$zipfile"

	# Move extracted content
	if [ -f /tmp/dashboard_install/index.html ]; then
		cp -rf /tmp/dashboard_install/* "$dest/"
	elif [ -d /tmp/dashboard_install/dist ]; then
		cp -rf /tmp/dashboard_install/dist/* "$dest/"
	else
		local sub
		sub=$(find /tmp/dashboard_install -maxdepth 2 -name "index.html" | head -n1)
		if [ -n "$sub" ]; then
			cp -rf "$(dirname "$sub")"/* "$dest/"
		fi
	fi

	rm -rf /tmp/dashboard_install
	echo '{"success": true}'
}

cmd_uninstall() {
	detect_crashdir
	local target="$1"
	if [ "$target" = "core" ]; then
		rm -rf "$CRASHDIR/bin/dashboard" "$CRASHDIR/ui"
	elif [ "$target" = "local" ]; then
		rm -rf /www/zashboard /www/metacubexd /www/yacd /www/dashboard
	fi
	echo '{"success": true}'
}

case "$1" in
	status) cmd_status ;;
	install) cmd_install "$2" "$3" ;;
	uninstall) cmd_uninstall "$2" ;;
	*)
		echo "Usage: $0 {status|install [core|local] [type]|uninstall [core|local]}"
		exit 1
		;;
esac
