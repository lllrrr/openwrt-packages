#!/bin/sh
# sheep-ctrl.sh -- sync UCI config to JSON (called from sheep.init start_service)

readonly CONF_DIR="/etc/shadowsocks-rust"
readonly CONF_FILE="$CONF_DIR/config.json"

# JSON-escape: backslash then double-quote
json_esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# Sync /etc/config/sheep to /etc/shadowsocks-rust/config.json
# 直接用 uci -q get 读值，避免 procd 环境下 config_load 读不全（密码为空）的问题
sync_config() {
	local server server_port password method timeout fast_open mode plugin plugin_opts

	server="$(uci -q get sheep.server.server)";           server="${server:-0.0.0.0}"
	server_port="$(uci -q get sheep.server.server_port)"; server_port="${server_port:-8388}"
	password="$(uci -q get sheep.server.password)"
	method="$(uci -q get sheep.server.method)";           method="${method:-aes-256-gcm}"
	timeout="$(uci -q get sheep.server.timeout)";         timeout="${timeout:-300}"
	fast_open="$(uci -q get sheep.server.fast_open)";     fast_open="${fast_open:-0}"
	mode="$(uci -q get sheep.server.mode)";               mode="${mode:-tcp_and_udp}"
	plugin="$(uci -q get sheep.server.plugin)"
	plugin_opts="$(uci -q get sheep.server.plugin_opts)"

	# Convert fast_open 0/1 to JSON boolean
	local fo="false"
	[ "$fast_open" = "1" ] && fo="true"

	# Build JSON config (escape string values to prevent JSON injection)
	local e_password e_plugin e_plugin_opts
	e_password="$(json_esc "$password")"
	e_plugin="$(json_esc "$plugin")"
	e_plugin_opts="$(json_esc "$plugin_opts")"

	local json
	json="{\"server\":\"${server}\",\"server_port\":${server_port},\"password\":\"${e_password}\",\"method\":\"${method}\",\"timeout\":${timeout},\"fast_open\":${fo},\"mode\":\"${mode}\""
	[ -n "$plugin" ] && json="${json},\"plugin\":\"${e_plugin}\""
	[ -n "$plugin" ] && [ -n "$plugin_opts" ] && json="${json},\"plugin_opts\":\"${e_plugin_opts}\""
	json="${json}}"

	mkdir -p "$CONF_DIR"
	printf '%s\n' "$json" > "$CONF_FILE"
}

case "$1" in
	sync_config) sync_config ;;
esac
