#!/bin/sh
# Copyright (c) 2026 Eugene Chan
# SPDX-License-Identifier: MIT
#
# rpcd `file.exec` backend for luci-app-bypass. The LuCI JS frontend calls
#   fs.exec('/usr/share/bypass/api.sh', [action, ...args])
# and parses the JSON object printed on stdout. All output is a single JSON
# line so it is trivial to consume with JSON.parse().

. /lib/functions.sh
. /usr/share/libubox/jshn.sh
. ${APP_PATH:-/usr/share/bypass}/utils.sh
# Source app.sh to inherit get_config / gen_bypasscore_config. Guard against the
# dispatcher: setting APP_SOURCED=1 makes app.sh define functions and return
# without running its own start/stop argument handler.
APP_SOURCED=1 . ${APP_PATH:-/usr/share/bypass}/app.sh

emit() {
	json_dump
}

# Extract a bounded, user-facing message from a BypassCore control response.
# curl does not fail on HTTP 4xx/5xx here, so callers must inspect the JSON body
# rather than replacing every control-plane error with one generic diagnosis.
control_error_message() {
	local raw=$1 message
	message=$(printf '%s' "$raw" | jsonfilter -e '@.error.message' 2>/dev/null)
	[ -n "$message" ] || message=$(printf '%s\n' "$raw" | sed -n '1p')
	printf '%.300s' "$message"
}

# status -> { running, naive_present, bypasscore_present,
#             use_tables, egress_ifaces, redir_port }
do_status() {
	local BYPASSCORE_FILE NAIVE_BIN DEFAULT_NODE
	local naive_present=0 bypasscore_present=0 running=0 sid outbound node kind
	local selected_nodes="" selected_nodes_count=0 selected_naive_count=0 selected_wireguard_count=0
	BYPASSCORE_FILE=$(first_type "$(config_t_get global bypasscore_file /usr/bin/bypasscore)" bypasscore)
	NAIVE_BIN=$(first_type "$(config_t_get global naive_file /usr/bin/naive)" naive)
	DEFAULT_NODE=$(config_t_get global_rules default_node _direct)
	[ -n "$NAIVE_BIN" ] && naive_present=1
	[ -x "$BYPASSCORE_FILE" ] && bypasscore_present=1
	selected_nodes=$(
		{
			for sid in $(shunt_rule_sections); do
				[ "$(config_n_get "$sid" is_default 0)" = "1" ] && continue
				outbound=$(config_n_get "$sid" outbound)
				[ "$(config_get_type "$outbound")" = "nodes" ] && printf '%s\n' "$outbound"
			done
			[ "$(config_get_type "$DEFAULT_NODE")" = "nodes" ] && printf '%s\n' "$DEFAULT_NODE"
		} | awk 'NF && !seen[$0]++'
	)
	while IFS= read -r node; do
		[ -n "$node" ] || continue
		selected_nodes_count=$((selected_nodes_count + 1))
		kind=$(node_type "$node")
		if [ "$kind" = "wireguard" ]; then
			selected_wireguard_count=$((selected_wireguard_count + 1))
		else
			selected_naive_count=$((selected_naive_count + 1))
		fi
	done <<-EOF
	$selected_nodes
	EOF
	# BypassCore plus the ready marker represent a fully installed firewall/DNS
	# path; structured readiness already covers all configured inbounds.
	[ -f /var/lock/bypass_ready.lock ] && process_alive bypasscore && running=1
	local use_tables egress active_redir_port core_ready=0 core_revision="" core_hash="" core_status
	use_tables=$(get_cache_var USE_TABLES)
	egress=$(get_cache_var EGRESS_IFACES)
	active_redir_port=$(get_cache_var ACL_GLOBAL_redir_port)
	if core_status=$(bypasscore_control_request GET /v1/ready 2>/dev/null); then
		printf '%s' "$core_status" | grep -Eq '"ready"[[:space:]]*:[[:space:]]*true' && core_ready=1
		core_revision=$(printf '%s' "$core_status" | sed -n 's/.*"configRevision"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p')
		core_hash=$(printf '%s' "$core_status" | sed -n 's/.*"configHash"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
	fi
	[ "$core_ready" = "1" ] || running=0

	json_init
	json_add_int running "$running"
	json_add_int naive_present "$naive_present"
	json_add_int bypasscore_present "$bypasscore_present"
	json_add_int core_ready "$core_ready"
	json_add_string core_revision "$core_revision"
	json_add_string core_config_hash "$core_hash"
	json_add_string use_tables "$use_tables"
	json_add_string egress_ifaces "$egress"
	# Retain the old singular key for callers written before per-node egress.
	json_add_string egress_iface "$egress"
	json_add_string redir_port "$active_redir_port"
	json_add_string version "$(cat "$APP_PATH/version" 2>/dev/null)"
	if [ "$(config_get_type "$DEFAULT_NODE")" = "nodes" ]; then
		json_add_string default_node "$DEFAULT_NODE"
	else
		json_add_string default_node "$(printf '%s\n' "$selected_nodes" | awk 'NF { print; exit }')"
	fi
	json_add_int selected_nodes "$selected_nodes_count"
	json_add_int selected_naive_nodes "$selected_naive_count"
	json_add_int selected_wireguard_nodes "$selected_wireguard_count"
	emit
}

# route_test <net:host:port> -> { code, matched, raw }
do_route_test() {
	local dest=$1
	get_config
	json_init
	if [ -z "$dest" ]; then
		json_add_int code -1
		json_add_string error "missing destination"
	elif ! is_bypasscore "$BYPASSCORE_FILE"; then
		json_add_int code -1
		json_add_string error "bypasscore unavailable (set bypasscore_file from https://github.com/kinmeic/BypassCore/releases)"
	else
		local request raw rc
		json_init
		json_add_string destination "$dest"
		request=$(json_dump)
		if process_alive bypasscore && raw=$(bypasscore_control_request POST /v1/route/explain "$request" 2>&1); then
			rc=0
			printf '%s' "$raw" | grep -Eq '"code"[[:space:]]*:' && rc=1
			json_init
			json_add_int code "$rc"
			json_add_string matched "$(printf '%s' "$raw" | sed -n 's/.*"ruleTag"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
			json_add_string raw "$raw"
		else
			json_init
			json_add_int code -1
			json_add_string error "BypassCore is not running or its control socket is unavailable"
		fi
	fi
	emit
}

# observatory -> { code, raw }
do_observe() {
	get_config
	json_init
	if ! is_bypasscore "$BYPASSCORE_FILE"; then
		json_add_int code -1
		json_add_string error "bypasscore unavailable"
	else
		local raw rc
		if process_alive bypasscore && raw=$(bypasscore_control_request GET /v1/observatory 2>&1); then
			rc=0
			printf '%s' "$raw" | grep -Eq '"code"[[:space:]]*:' && rc=1
			json_init
			json_add_int code "$rc"
			json_add_string raw "$raw"
		else
			json_init
			json_add_int code -1
			json_add_string error "BypassCore is not running or its control socket is unavailable"
		fi
	fi
	emit
}

# resolve <domain> -> { code, raw } using the running core DNS snapshot
do_resolve() {
	local domain=$1
	get_config
	json_init
	if [ -z "$domain" ]; then
		json_add_int code -1
		json_add_string error "missing domain"
	elif ! is_bypasscore "$BYPASSCORE_FILE"; then
		json_add_int code -1
		json_add_string error "bypasscore unavailable (set bypasscore_file from https://github.com/kinmeic/BypassCore/releases)"
	else
		local request raw rc
		json_init
		json_add_string domain "$domain"
		request=$(json_dump)
		if process_alive bypasscore && raw=$(bypasscore_control_request POST /v1/dns/resolve "$request" 2>&1); then
			rc=0
			printf '%s' "$raw" | grep -Eq '"code"[[:space:]]*:' && rc=1
			json_init
			json_add_int code "$rc"
			json_add_string raw "$raw"
		else
			json_init
			json_add_int code -1
			json_add_string error "BypassCore is not running or its control socket is unavailable"
		fi
	fi
	emit
}

# node_tcp_probe <node_id> -> { code, latency_ms, raw }
do_node_tcp_probe() {
	local node_id=$1
	json_init
	case "$node_id" in
		''|*[!A-Za-z0-9_-]*)
			json_add_int code -1
			json_add_string error "invalid node"
			emit
			return
			;;
	esac
	if [ "$(config_get_type "$node_id")" != "nodes" ]; then
		json_add_int code -1
		json_add_string error "node not found"
		emit
		return
	fi

	local address port request raw latency rc endpoint BYPASSCORE_FILE type probe_error
	type=$(node_type "$node_id")
	if [ "$type" = "wireguard" ]; then
		# Compatibility for a cached pre-upgrade LuCI page.
		do_node_udp_probe "$node_id"
		return
	fi
	address=$(config_n_get "$node_id" address)
	port=$(config_n_get "$node_id" port)
	case "$port" in ''|*[!0-9]*) port=0 ;; esac
	if [ -z "$address" ] || [ "$port" -lt 1 ] 2>/dev/null || [ "$port" -gt 65535 ] 2>/dev/null; then
		json_add_int code -1
		json_add_string error "node has no address/port"
	else
		BYPASSCORE_FILE=$(config_t_get global bypasscore_file /usr/bin/bypasscore)
		json_init
		json_add_string host "$address"
		json_add_int port "$port"
		json_add_int timeoutMs 3000
		request=$(json_dump)

		# Preserve the original control-plane probe path: the running core owns
		# node-domain DNS policy, while a standalone process would recurse
		# through dnsmasq after dnsmasq has been pointed at BypassCore.
		if process_alive bypasscore && raw=$(bypasscore_control_request POST /v1/network/tcp-probe "$request" 2>&1); then
			rc=0
		else
			endpoint="$(host_for_url "$address"):$port"
			if is_bypasscore "$BYPASSCORE_FILE"; then
				raw=$("$BYPASSCORE_FILE" -tcp-probe "$endpoint" -tcp-probe-timeout 3s -json 2>&1)
				rc=$?
			else
				raw="BypassCore is unavailable"
				rc=1
			fi
		fi
		latency=$(printf '%s' "$raw" | sed -n 's/.*"latencyMs"[[:space:]]*:[[:space:]]*\([0-9][0-9.]*\).*/\1/p')
		[ -n "$latency" ] || rc=1
		[ "$rc" -eq 0 ] 2>/dev/null || \
			probe_error=$(printf '%.300s' "$(printf '%s\n' "$raw" | sed -n '1p' | sed 's/^error:[[:space:]]*//')")
		json_init
		json_add_int code "$rc"
		[ -n "$latency" ] && json_add_string latency_ms "$latency"
		if [ "$rc" -ne 0 ] 2>/dev/null; then
			json_add_string error "TCP connect probe failed${probe_error:+: ${probe_error}}"
		fi
		json_add_string raw "$raw"
	fi
	emit
}

# node_udp_probe <node_id> -> { code, latency_ms, raw }
# WireGuard is carried over UDP, so its Connect Test verifies the peer
# handshake rather than coupling transport health to an arbitrary TCP server.
do_node_udp_probe() {
	local node_id=$1 request raw latency rc control_error
	json_init
	case "$node_id" in
		''|*[!A-Za-z0-9_-]*)
			json_add_int code -1
			json_add_string error "invalid node"
			emit
			return
			;;
	esac
	if [ "$(config_get_type "$node_id")" != "nodes" ] || [ "$(node_type "$node_id")" != "wireguard" ]; then
		json_add_int code -1
		json_add_string error "WireGuard node not found"
		emit
		return
	fi
	get_config
	prepare_selected_nodes
	if ! grep -Fxq "$node_id" "$TMP_PATH/selected_wireguard_nodes" 2>/dev/null; then
		json_add_int code -1
		json_add_string error "WireGuard node is not selected by an active rule or the Default row"
		emit
		return
	fi
	json_init
	json_add_int timeoutMs 6000
	json_add_string outboundTag "proxy_${node_id}"
	request=$(json_dump)
	if process_alive bypasscore && raw=$(bypasscore_control_request POST /v1/network/handshake-probe "$request" 2>&1); then
		rc=0
	else
		rc=1
	fi
	latency=$(printf '%s' "$raw" | sed -n 's/.*"latencyMs"[[:space:]]*:[[:space:]]*\([0-9][0-9.]*\).*/\1/p')
	[ -n "$latency" ] || rc=1
	[ "$rc" -eq 0 ] 2>/dev/null || control_error=$(control_error_message "$raw")
	json_init
	json_add_int code "$rc"
	[ -n "$latency" ] && json_add_string latency_ms "$latency"
	if [ "$rc" -ne 0 ] 2>/dev/null; then
		json_add_string error "WireGuard UDP handshake failed${control_error:+: ${control_error}}"
	fi
	json_add_string raw "$raw"
	emit
}

# node_urltest <node_id> <probe_url> -> { code, use_time }
# NaiveProxy mirrors passwall2 by using a short-lived SOCKS listener. WireGuard
# is native to the running core, so its test uses the selected outbound directly.
do_node_urltest() {
	local node_id=$1 url_test_url=$2
	json_init
	case "$node_id" in
		''|*[!A-Za-z0-9_-]*)
			json_add_int code -1
			json_add_string error "invalid node"
			emit
			return
			;;
	esac
	if [ "$(config_get_type "$node_id")" != "nodes" ]; then
		json_add_int code -1
		json_add_string error "node not found"
		emit
		return
	fi

	# The selector is intentionally not UCI configuration. Accept only the
	# presets exposed by node_list.js so this root helper cannot become an
	# arbitrary URL fetch primitive.
	case "$url_test_url" in
		https://cp.cloudflare.com/|\
		https://www.gstatic.com/generate_204|\
		https://www.google.com/generate_204|\
		https://www.youtube.com/generate_204|\
		https://connect.rom.miui.com/generate_204|\
		https://connectivitycheck.platform.hicloud.com/generate_204|\
		https://wifi.vivo.com.cn/generate_204) ;;
		*) url_test_url=https://www.google.com/generate_204 ;;
	esac

	local type
	type=$(node_type "$node_id")
	if [ "$type" = "wireguard" ]; then
		local request raw latency control_error rc=1
		get_config
		prepare_selected_nodes
		if ! grep -Fxq "$node_id" "$TMP_PATH/selected_wireguard_nodes" 2>/dev/null; then
			json_add_int code -1
			json_add_string error "WireGuard node is not selected by an active rule or the Default row"
			emit
			return
		fi
		json_init
		json_add_string url "$url_test_url"
		# The first probe may initialize the device and negotiate a handshake.
		# No resolverTag: BypassCore resolves the target through the tested
		# WireGuard outbound first, then through the core DNS chain. Pinning a
		# direct resolver would falsely require the remote DNS to be reachable
		# without the tunnel, contradicting remote_dns_detour=remote.
		json_add_int timeoutMs 10000
		json_add_string outboundTag "proxy_${node_id}"
		request=$(json_dump)
		if process_alive bypasscore && raw=$(bypasscore_control_request POST /v1/network/url-test "$request" 2>&1); then
			latency=$(printf '%s' "$raw" | sed -n 's/.*"latencyMs"[[:space:]]*:[[:space:]]*\([0-9][0-9.]*\).*/\1/p')
			[ -n "$latency" ] && rc=0
		else
			raw="BypassCore is not running or its control socket is unavailable"
		fi
		[ "$rc" -eq 0 ] 2>/dev/null || control_error=$(control_error_message "$raw")
		json_init
		json_add_int code "$rc"
		if [ "$rc" -eq 0 ]; then
			json_add_string use_time "$(printf '%s\n' "$latency" | awk '{printf "%d", $1}')"
		else
			json_add_string error "WireGuard URL test failed${control_error:+: ${control_error}}"
		fi
		json_add_string raw "$raw"
		emit
		return
	fi

	local address port username password protocol
	address=$(config_n_get "$node_id" address)
	port=$(config_n_get "$node_id" port)
	username=$(config_n_get "$node_id" username)
	password=$(config_n_get "$node_id" password)
	protocol=$(config_n_get "$node_id" protocol https)
	if [ -z "$address" ] || [ -z "$port" ]; then
		json_add_int code -1
		json_add_string error "node has no address/port"
		emit
		return
	fi
	local naive_bin
	naive_bin=$(first_type "$(config_t_get global naive_file /usr/bin/naive)" naive)
	if [ -z "$naive_bin" ]; then
		json_add_int code -1
		json_add_string error "naiveproxy not installed"
		emit
		return
	fi
	case "$protocol" in quic) ;; *) protocol=https ;; esac

	# Build a minimal SOCKS config (127.0.0.1 only; no egress pinning).
	local tag="url_test_${node_id}"
	local socks_port
	socks_port=$(get_new_port 48900 tcp)
	local auth=""
	if [ -n "$username$password" ]; then
		username=$(uri_encode_userinfo "$username") || { json_add_int code -1; json_add_string error "bad credentials"; emit; return; }
		password=$(uri_encode_userinfo "$password") || { json_add_int code -1; json_add_string error "bad credentials"; emit; return; }
		auth="${username}:${password}@"
	fi
	local server_host
	server_host=$(host_for_url "$address")

	mkdir -p "$TMP_PATH2"
	local cfg="$TMP_PATH2/${tag}.json" log="$TMP_PATH2/${tag}.log"
	json_init
	json_add_string "listen" "socks://127.0.0.1:${socks_port}"
	json_add_string "proxy" "${protocol}://${auth}${server_host}:${port}"
	json_dump > "$cfg"
	: > "$log"

	ln_run 0 "$naive_bin" "$tag" "$log" "$cfg"
	local use_time="" http_code
	if wait_for_listener "$tag" "$socks_port" tcp 8 "$log"; then
		# % output: "<http_code> <time_total seconds>"
		local out curl_rc
		out=$(curl -o /dev/null -s -I --connect-timeout 3 --max-time 6 \
			-x "socks5h://127.0.0.1:${socks_port}" \
			-w '%{http_code} %{time_total}' "$url_test_url" 2>/dev/null)
		curl_rc=$?
		http_code="${out%% *}"
		if [ "$curl_rc" -eq 0 ] 2>/dev/null; then
			case "$http_code" in ''|0|000) ;;
				*)
					local t="${out#* }"
					use_time=$(echo "$t" | awk '{printf "%d", $1*1000}')
					;;
			esac
		fi
	fi

	# Teardown regardless of outcome.
	local pid
	pid=$(cat "$TMP_PID_PATH/${tag}.pid" 2>/dev/null)
	[ -n "$pid" ] && kill -9 "$pid" >/dev/null 2>&1
	rm -f "$cfg" "$log" "$TMP_PID_PATH/${tag}.pid"

	json_init
	if [ -n "$use_time" ]; then
		json_add_int code 0
		json_add_string use_time "$use_time"
	else
		json_add_int code -1
		json_add_string error "timeout"
	fi
	emit
}

# wireguard_keypair / wireguard_psk -> key material generated by BypassCore.
# Keeping Curve25519 operations in the core avoids browser-dependent crypto
# implementations and guarantees the same encoding accepted by the runtime.
do_wireguard_keypair() {
	local raw secret public rc=0
	BYPASSCORE_FILE=$(config_t_get global bypasscore_file /usr/bin/bypasscore)
	if ! is_bypasscore "$BYPASSCORE_FILE"; then
		rc=1
	else
		raw=$("$BYPASSCORE_FILE" -wireguard-generate-keypair -json 2>/dev/null) || rc=$?
	fi
	[ "$rc" -eq 0 ] 2>/dev/null && json_load "$raw" 2>/dev/null || rc=1
	if [ "$rc" -eq 0 ] 2>/dev/null; then
		json_get_var secret secretKey
		json_get_var public publicKey
		[ -n "$secret" ] && [ -n "$public" ] || rc=1
	fi
	json_init
	json_add_int code "$rc"
	if [ "$rc" -eq 0 ] 2>/dev/null; then
		json_add_string secretKey "$secret"
		json_add_string publicKey "$public"
	else
		json_add_string error "BypassCore WireGuard key generation is unavailable"
	fi
	emit
}

do_wireguard_psk() {
	local raw key rc=0
	BYPASSCORE_FILE=$(config_t_get global bypasscore_file /usr/bin/bypasscore)
	if ! is_bypasscore "$BYPASSCORE_FILE"; then
		rc=1
	else
		raw=$("$BYPASSCORE_FILE" -wireguard-generate-psk -json 2>/dev/null) || rc=$?
	fi
	[ "$rc" -eq 0 ] 2>/dev/null && json_load "$raw" 2>/dev/null || rc=1
	if [ "$rc" -eq 0 ] 2>/dev/null; then
		json_get_var key preSharedKey
		[ -n "$key" ] || rc=1
	fi
	json_init
	json_add_int code "$rc"
	if [ "$rc" -eq 0 ] 2>/dev/null; then
		json_add_string preSharedKey "$key"
	else
		json_add_string error "BypassCore WireGuard preshared key generation is unavailable"
	fi
	emit
}

# config_preview -> { config }  (regenerate + cat)
do_config_preview() {
	get_config
	local gen_rc=0 content="" active_config="$BYPASSCORE_CFG"
	BYPASSCORE_CFG="${TMP_PATH}/bypasscore/preview.json"
	rm -f "$BYPASSCORE_CFG"
	gen_bypasscore_config >/dev/null 2>&1 || gen_rc=$?
	[ "$gen_rc" = "0" ] && [ -s "$BYPASSCORE_CFG" ] && content=$(cat "$BYPASSCORE_CFG")
	rm -f "$BYPASSCORE_CFG"
	BYPASSCORE_CFG=$active_config
	json_init
	if [ "$gen_rc" = "0" ] && [ -n "$content" ]; then
		# Escape into a JSON string via jshn.
		json_add_string config "$content"
	else
		json_add_string config ""
		json_add_string error "config not generated"
	fi
	emit
}

# rule_update -> { code, msg }
do_rule_update() {
	json_init
	if [ -x "$APP_PATH/rule_update.sh" ]; then
		local out
		out=$("$APP_PATH/rule_update.sh" 2>&1)
		json_add_int code $?
		json_add_string msg "$out"
	else
		json_add_int code -1
		json_add_string error "rule_update.sh missing"
	fi
	emit
}

# log_tail [n] -> { log }
do_log_tail() {
	local n=${1:-200}
	json_init
	if [ -s "$LOG_FILE" ]; then
		json_add_string log "$(tail -n "$n" "$LOG_FILE" 2>/dev/null)"
	else
		json_add_string log ""
		json_add_string error "no log yet"
	fi
	emit
}

# clear_log
do_clear_log() {
	: > "$LOG_FILE"
	json_init
	json_add_int code 0
	emit
}

do_clear_nftset() {
	local nft_bin rc=0 set error=""
	nft_bin=$(first_type /usr/sbin/nft nft)
	if [ -z "$nft_bin" ]; then
		rc=1
		error="nft not found"
	fi
	if [ "$rc" = "0" ]; then
		# Flush only rule-result sets. Resolver and node-address whitelists are
		# safety state and must not disappear while the service is live.
		for set in bypass_direct_dns bypass_direct_dns6; do
			"$nft_bin" flush set inet bypass "$set" 2>/dev/null || true
		done
		# A successful probe refreshes kernel set metadata and invalidates the
		# core writer's TTL dedupe state, allowing later DNS answers to repopulate
		# elements removed by this operation.
		if process_alive bypasscore && \
		   ! bypasscore_control_request POST /v1/dns/nftsets/probe "" >/dev/null 2>&1; then
			rc=1
			error="BypassCore NFTSet resynchronization failed"
		fi
	fi
	json_init
	json_add_int code "$rc"
	if [ "$rc" = "0" ]; then
		json_add_string msg "NFTSet cleared"
	else
		json_add_string error "$error"
	fi
	emit
}

# interfaces -> { interfaces: ["wan","wan1",...] } (for the egress dropdowns)
do_interfaces() {
	json_init
	json_add_array interfaces
	local iface interfaces
	interfaces=$(uci -q show network 2>/dev/null | sed -n 's/^network\.\([^.=]*\)=interface$/\1/p')
	interfaces="${interfaces}
$(ubus call network.interface dump 2>/dev/null | jsonfilter -e '@.interface[*].interface' 2>/dev/null)"
	for iface in $(printf '%s\n' "$interfaces" | awk 'NF && !seen[$0]++' | sort); do
		[ -n "$iface" ] && [ "$iface" != "loopback" ] && json_add_string '' "$iface"
	done
	json_close_array
	emit
}

# connect_status <type> <url> -> { ping_type:"curl", use_time:N } | { status:0 }
# Router OUTPUT traffic is intentionally not transparently redirected. Test
# foreign sites through the effective Default node: NaiveProxy uses its SOCKS
# listener, while WireGuard uses the running native outbound control probe.
do_connect_status() {
	local type=$1 url=$2
	local out code use_time node node_kind socks_port request raw error
	case "$type" in baidu|google|github) ;; *) type="" ;; esac
	[ -n "$type" ] && [ -n "$url" ] || { json_init; json_add_int status 0; emit; return; }
	get_config
	if [ "$type" = "baidu" ]; then
		out=$(curl -s -o /dev/null -w '%{time_total}' --connect-timeout 3 --max-time 8 "$url" 2>/dev/null)
		code=$?
	else
		prepare_selected_nodes
		node=$(default_proxy_node)
		node_kind=$(node_type "$node")
		if [ -z "$node" ]; then
			code=1
			out=""
			error="No active outbound node"
		elif [ "$node_kind" = "wireguard" ]; then
			json_init
			json_add_string url "$url"
			json_add_int timeoutMs 12000
			json_add_string outboundTag "proxy_${node}"
			request=$(json_dump)
			if process_alive bypasscore && raw=$(bypasscore_control_request POST /v1/network/url-test "$request" 2>&1); then
				out=$(printf '%s' "$raw" | sed -n 's/.*"latencyMs"[[:space:]]*:[[:space:]]*\([0-9][0-9.]*\).*/\1/p')
				if [ -n "$out" ]; then
					code=0
					# URL-test latency is already milliseconds.
					use_time=$(printf '%s\n' "$out" | awk '{printf "%d", $1}')
				else
					code=1
					error=$(control_error_message "$raw")
				fi
			else
				code=1
				error="BypassCore is not running or its control socket is unavailable"
			fi
		else
			socks_port=$(node_socks_port "$node")
			if [ -z "$socks_port" ] || [ "$(check_port_exists "$socks_port" tcp)" -le 0 ] 2>/dev/null; then
				code=1
				out=""
				error="NaiveProxy SOCKS listener is unavailable"
			else
				out=$(curl -s -o /dev/null -w '%{time_total}' --socks5-hostname "127.0.0.1:${socks_port}" \
					--connect-timeout 5 --max-time 12 "$url" 2>/dev/null)
				code=$?
			fi
		fi
	fi
	if [ "$type" = "baidu" ] || [ "${node_kind:-naiveproxy}" = "naiveproxy" ]; then
		use_time=$(echo "$out" | awk '{printf "%d", $1*1000}')
	fi
	json_init
	if [ "$code" = "0" ] && [ -n "$use_time" ]; then
		json_add_string ping_type "curl"
		json_add_int use_time "$use_time"
	else
		json_add_int status 0
		[ -n "$error" ] && json_add_string error "$error"
	fi
	emit
}

# geo_view <action> <value> -> { code, output }
# Wraps the geoview binary for the Geo View page.
#   lookup  (domain/IP → geo rule list)
#   extract (geoip:cc / geosite:name → member list)
#   list    (enumerate every entry name in geoip.dat and geosite.dat)
# Mirrors passwall2's controller geo_view() invocation:
#   lookup:  geoview -type <geoip|geosite> -action lookup  -input <dat> -value <q> -lowmem=true
#   extract: geoview -type <geoip|geosite> -action extract -input <dat> -list  <c> -lowmem=true
#   list:    geoview -type <geoip|geosite> -action extract -input <dat>           -lowmem=true

# Print shunt-rule section IDs containing a GeoData lookup result. This mirrors
# passwall2 controller's get_rules(): compare the part after geosite:/geoip:
# and ignore commented lines.
geo_rules_for_value() {
	local search=$1 geo_type=$2 sid list line main
	search=$(printf '%s' "$search" | tr '[:upper:]' '[:lower:]')
	for sid in $(shunt_rule_sections); do
		[ "$(config_n_get "$sid" is_default 0)" = "1" ] && continue
		if [ "$geo_type" = "geoip" ]; then
			list=$(config_n_get "$sid" ip_list)
		else
			list=$(config_n_get "$sid" domain_list)
		fi
		while IFS= read -r line; do
			line=$(printf '%s' "$line" | tr -d '\r' | tr '[:upper:]' '[:lower:]')
			[ -n "$line" ] || continue
			case "$line" in *'#'*) continue ;; esac
			case "$line" in *:*) main=${line#*:} ;; *) main=$line ;; esac
			if [ "$geo_type" = "geoip" ] && { echo "$search" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$|:'; }; then
				case "$main" in *"$search"*) echo "$sid"; break ;; esac
			elif [ "$main" = "$search" ]; then
				echo "$sid"
				break
			fi
		done <<-EOF
		$list
		EOF
	done
}

# Report the effective TCP/443 outbound and its OpenWrt/runtime interface for a
# Geo View lookup. BypassCore remains authoritative for rule priority; UCI and
# netifd then translate its outbound tag into the interface actually used.
geo_lookup_egress() {
	local target=$1 request raw tag node sid logical="" label device devices="" devices_label="" iface mapped=""
	get_config
	case "$target" in *:*) target="[$target]" ;; esac
	json_init
	json_add_string destination "tcp:${target}:443"
	request=$(json_dump)
	if ! process_alive bypasscore || ! raw=$(bypasscore_control_request POST /v1/route/explain "$request" 2>/dev/null); then
		printf '%s\n' "Egress interface: unavailable (BypassCore control plane is not running)"
		return
	fi
	tag=$(printf '%s\n' "$raw" | sed -n 's/.*"outboundTag"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
	case "$tag" in
		block)
			printf '%s\n' "Outbound: Block" "Egress interface: none (blocked)"
			return
			;;
		proxy_*)
			node=${tag#proxy_}
			label=$(config_n_get "$node" remarks "$node")
			logical=$(node_egress_interface "$node")
			if [ "$(node_type "$node")" = "wireguard" ]; then
				printf '%s\n' "Outbound: WireGuard node [$label]"
			else
				printf '%s\n' "Outbound: NaiveProxy node [$label]"
			fi
			;;
		direct_*)
			sid=${tag#direct_}
			logical=$(config_n_get "$sid" egress_interface)
			printf '%s\n' "Outbound: Direct"
			;;
		direct)
			logical=$(config_t_get global_rules direct_egress_interface)
			printf '%s\n' "Outbound: Direct"
			;;
		*)
			printf '%s\n' "Egress interface: unavailable (no routing decision)"
			return
			;;
	esac

	if [ -n "$logical" ]; then
		if get_egress_runtime "$logical"; then
			printf '%s\n' "Egress interface: ${logical} (${EGRESS_DEVICE})"
		else
			printf '%s\n' "Egress interface: ${logical} (currently unavailable)"
		fi
		return
	fi

	devices=$(
		{ ip -o -4 route show default; ip -o -6 route show default; } 2>/dev/null |
			awk '{ for (i=1; i<=NF; i++) if ($i == "dev") print $(i+1) }' |
			awk 'NF && !seen[$0]++'
	)
	network_flush_cache 2>/dev/null
	for device in $devices; do
		mapped=""
		for iface in $(uci -q show network 2>/dev/null | sed -n 's/^network\.\([^.=]*\)=interface$/\1/p'); do
			network_get_device mapped "$iface" 2>/dev/null
			[ "$mapped" = "$device" ] && break
			mapped=""
		done
		label="${mapped:+$iface -> }$device"
		devices_label="${devices_label:+$devices_label, }$label"
	done
	printf '%s\n' "Egress interface: system default${devices_label:+ ($devices_label)}"
}

do_geo_view() {
	local action=$1 value=$2
	local bin geoip_path geosite_path
	bin=$(first_type "$(config_t_get global_app geoview_file /usr/bin/geoview)" geoview)
	geoip_path=$(get_geo_asset_path geoip)
	geosite_path=$(get_geo_asset_path geosite)
	json_init
	if [ -z "$bin" ]; then
		json_add_int code -1
		json_add_string error "geoview binary not found"
		emit
		return
	fi
	if [ -z "$action" ] || { [ "$action" != "list" ] && [ -z "$value" ]; }; then
		json_add_int code -1
		json_add_string error "missing action or value"
		emit
		return
	fi

	local geo_type file_path out rc route_info
	if [ "$action" = "lookup" ]; then
		# IP → geoip; anything else → geosite.
		value=$(strip_host_brackets "$value")
		case "$value" in
			*:*) geo_type="geoip"; file_path="$geoip_path" ;;
			*)
				if echo "$value" | grep -qE "^([0-9]{1,3}[\.]){3}[0-9]{1,3}$"; then
					geo_type="geoip"
					file_path="$geoip_path"
				else
					geo_type="geosite"
					file_path="$geosite_path"
				fi
				;;
		esac
		out=$("$bin" -type "$geo_type" -action lookup -input "$file_path" -value "$value" -lowmem=true 2>&1)
		rc=$?
		if [ "$rc" = "0" ] && [ -n "$out" ]; then
			local tmp line rules
			tmp=$(mktemp -d 2>/dev/null)
			if [ -n "$tmp" ]; then
				printf '%s\n' "$out" | awk '{ print tolower($0) }' | while IFS= read -r line; do
					[ -n "$line" ] || continue
					printf '%s:%s\n' "$geo_type" "$line" >> "$tmp/output"
					geo_rules_for_value "$line" "$geo_type" >> "$tmp/rules"
				done
				geo_rules_for_value "$value" "$geo_type" >> "$tmp/rules"
				rules=$(awk '!seen[$0]++' "$tmp/rules" 2>/dev/null)
				out=$(cat "$tmp/output" 2>/dev/null)
				if [ -n "$rules" ]; then
					out="${out}
--------------------
Rules containing this value:
${rules}"
				fi
				rm -rf "$tmp"
			fi
		fi
		if [ "$rc" = "0" ]; then
			route_info=$(geo_lookup_egress "$value")
			out="${out}${out:+
}--------------------
Routing decision for TCP/443:
${route_info}"
		fi
	elif [ "$action" = "extract" ]; then
		# Parse geoip:<list> or geosite:<list>.
		case "$value" in
			geoip:*)
				geo_type="geoip"
				file_path="$geoip_path"
				value="${value#geoip:}"
				;;
			geosite:*)
				geo_type="geosite"
				file_path="$geosite_path"
				value="${value#geosite:}"
				;;
			*)
				json_add_int code -1
				json_add_string error "format: geoip:cn or geosite:gfw"
				emit
				return
				;;
		esac
		out=$("$bin" -type "$geo_type" -action extract -input "$file_path" -list "$value" -lowmem=true 2>&1)
		rc=$?
	elif [ "$action" = "list" ]; then
		# Enumerate every entry name in both geoip.dat and geosite.dat.
		# geoview with -action extract and no -list prints "Available codes:" + names.
		local geo_codes site_codes
		if [ -n "$geoip_path" ] && [ -f "$geoip_path" ]; then
			geo_codes=$("$bin" -type geoip -action extract -input "$geoip_path" -lowmem=true 2>/dev/null \
				| sed -e '1{/^Available codes:$/d;}' -e '/^$/d' -e 's/^/geoip:/')
		fi
		if [ -n "$geosite_path" ] && [ -f "$geosite_path" ]; then
			site_codes=$("$bin" -type geosite -action extract -input "$geosite_path" -lowmem=true 2>/dev/null \
				| sed -e '1{/^Available codes:$/d;}' -e '/^$/d' -e 's/^/geosite:/')
		fi
		out=$(
			[ -n "$geo_codes" ] && printf '%s\n' "$geo_codes"
			[ -n "$site_codes" ] && printf '%s\n' "$site_codes"
		)
		[ -n "$out" ] && rc=0 || rc=1
	else
		json_add_int code -1
		json_add_string error "unknown action: $action"
		emit
		return
	fi

	# The optional routing lookup above also uses jshn, so begin a fresh response.
	json_init
	json_add_int code "${rc:-1}"
	json_add_string output "$out"
	emit
}

# create_backup -> { code, backup }  (backup = base64-encoded tar.gz of /etc/config/bypass)
# Mirrors passwall2's backup feature (single config file, no server config).
do_create_backup() {
	local tmp tarball b64
	tmp=$(mktemp -d 2>/dev/null) || { json_init; json_add_int code -1; json_add_string error "mktemp failed"; emit; return; }
	tarball="$tmp/bypass-backup.tar.gz"
	if tar -C / -czf "$tarball" etc/config/bypass 2>/dev/null; then
		b64=$(base64 "$tarball" 2>/dev/null | tr -d '\n')
		json_init
		json_add_int code 0
		json_add_string backup "$b64"
		json_add_string filename "bypass-$(date +%y%m%d%H%M)-backup.tar.gz"
	else
		json_init
		json_add_int code -1
		json_add_string error "tar failed"
	fi
	emit
	rm -rf "$tmp"
}

# restore_backup <base64> -> { code }
# Receives a base64-encoded tar.gz, decodes, extracts over /etc/config/bypass.
do_restore_backup() {
	local b64=$1 tmp tarball
	[ -z "$b64" ] && { json_init; json_add_int code -1; json_add_string error "missing backup data"; emit; return; }
	tmp=$(mktemp -d 2>/dev/null) || { json_init; json_add_int code -1; json_add_string error "mktemp failed"; emit; return; }
	tarball="$tmp/restore.tar.gz"
	echo "$b64" | base64 -d > "$tarball" 2>/dev/null
	local members
	members=$(tar -tzf "$tarball" 2>/dev/null) || members=""
	if [ "$members" = "etc/config/bypass" ] || [ "$members" = "./etc/config/bypass" ]; then
		mkdir -p "$tmp/extract"
		tar -C "$tmp/extract" -xzf "$tarball" "$members" 2>/dev/null
		if [ -s "$tmp/extract/${members#./}" ] && uci -q -c "$tmp/extract/etc/config" show bypass >/dev/null 2>&1; then
			cp -f "$tmp/extract/${members#./}" /etc/config/bypass
			chmod 600 /etc/config/bypass 2>/dev/null
			json_init
			json_add_int code 0
			json_add_string msg "restored; restart bypass to apply"
		else
			json_init
			json_add_int code -1
			json_add_string error "backup does not contain a valid config"
		fi
	else
		json_init
		json_add_int code -1
		json_add_string error "invalid backup archive"
	fi
	emit
	rm -rf "$tmp"
}

# reset_config -> { code }
# Restore factory defaults: stop the service, copy 0_default_config, clear log.
do_reset_config() {
	json_init
	if [ -n "${IPKG_INSTROOT}" ]; then
		json_add_int code -1
		json_add_string error "reset is unavailable during package installation"
	elif /etc/init.d/bypass stop >/dev/null 2>&1 && \
	     cp -f /usr/share/bypass/0_default_config /etc/config/bypass 2>/dev/null && \
	     cp -f /usr/share/bypass/0_default_direct_ip /usr/share/bypass/direct_ip 2>/dev/null; then
		chmod 600 /etc/config/bypass 2>/dev/null
		: > /tmp/log/bypass.log 2>/dev/null
		# Do not reload rpcd inside its own file.exec request: doing so can
		# truncate this JSON response in exactly the same way as opkg upgrades.
		json_add_int code 0
	else
		json_add_int code -1
		json_add_string error "failed to restore the factory configuration"
	fi
	emit
}

# get_direct_ip / set_direct_ip <base64>
# Keep the editable Passwall2-style direct list outside UCI. nft --check is the
# authoritative validator for literal IPv4/IPv6 prefixes; geoip:CODE entries
# are expanded by nftables.sh when the service starts.
do_get_direct_ip() {
	json_init
	json_add_int code 0
	json_add_string direct_ip "$(cat /usr/share/bypass/direct_ip 2>/dev/null)"
	emit
}

do_set_direct_ip() {
	local encoded=$1 tmp input rules line v4="" v6="" nft_bin table saved=0
	json_init
	[ ${#encoded} -le 262144 ] 2>/dev/null || {
		json_add_int code -1
		json_add_string error "Direct IP List is too large"
		emit
		return
	}
	tmp=$(mktemp -d 2>/dev/null) || {
		json_add_int code -1
		json_add_string error "mktemp failed"
		emit
		return
	}
	input="$tmp/direct_ip"
	rules="$tmp/validate.nft"
	if ! printf '%s' "$encoded" | base64 -d > "$input" 2>/dev/null; then
		json_add_int code -1
		json_add_string error "invalid Direct IP data"
		emit
		rm -rf "$tmp"
		return
	fi
	sed -i 's/\r$//' "$input"
	while IFS= read -r line || [ -n "$line" ]; do
		line=$(printf '%s' "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
		case "$line" in
			''|'#'*) continue ;;
			geoip:*)
				echo "$line" | grep -qE '^geoip:[A-Za-z0-9_-]+$' || {
					json_add_int code -1
					json_add_string error "invalid Direct IP entry: $line"
					emit
					rm -rf "$tmp"
					return
				}
				continue
				;;
			*:*) v6="${v6:+$v6, }$line" ;;
			*) v4="${v4:+$v4, }$line" ;;
		esac
	done < "$input"
	table="bypass_validate_$$"
	cat > "$rules" <<-EOF
	table inet $table {
		set direct4 { type ipv4_addr; flags interval; auto-merge; elements = { $v4 } }
		set direct6 { type ipv6_addr; flags interval; auto-merge; elements = { $v6 } }
	}
	EOF
	nft_bin=$(first_type /usr/sbin/nft nft)
	if [ -z "$nft_bin" ] || ! "$nft_bin" --check -f "$rules" >/dev/null 2>&1; then
		json_add_int code -1
		json_add_string error "Direct IP List contains an invalid IP address or CIDR"
	else
		# Normalize line endings but retain comments and ordering exactly.
		cp -f "$input" /usr/share/bypass/direct_ip
		chmod 644 /usr/share/bypass/direct_ip 2>/dev/null
		json_add_int code 0
		saved=1
	fi
	emit
	rm -rf "$tmp"
	if [ "$saved" = "1" ] && [ "$(uci -q get bypass.@global[0].enabled)" = "1" ]; then
		( sleep 1; /etc/init.d/bypass restart ) >/dev/null 2>&1 &
	fi
}

usage() {
	echo "Usage: $0 {status|route_test|observe|resolve|node_tcp_probe|node_udp_probe|node_urltest|wireguard_keypair|wireguard_psk|config_preview|rule_update|log_tail|clear_log|clear_nftset|interfaces|connect_status|geo_view|create_backup|restore_backup|reset_config|get_direct_ip|set_direct_ip} [args]" >&2
}

main() {
	local action=$1
	shift
	case "$action" in
		status)         do_status ;;
		route_test)     do_route_test "$1" ;;
		observe)        do_observe ;;
		resolve)        do_resolve "$1" ;;
		node_tcp_probe) do_node_tcp_probe "$1" ;;
		node_udp_probe) do_node_udp_probe "$1" ;;
		node_urltest)   do_node_urltest "$1" "$2" ;;
		wireguard_keypair) do_wireguard_keypair ;;
		wireguard_psk) do_wireguard_psk ;;
		config_preview) do_config_preview ;;
		rule_update)    do_rule_update ;;
		log_tail)       do_log_tail "$1" ;;
		clear_log)      do_clear_log ;;
		clear_nftset)   do_clear_nftset ;;
		interfaces)     do_interfaces ;;
		connect_status) do_connect_status "$1" "$2" ;;
		geo_view)       do_geo_view "$1" "$2" ;;
		create_backup)  do_create_backup ;;
		restore_backup) do_restore_backup "$1" ;;
		reset_config)   do_reset_config ;;
		get_direct_ip)  do_get_direct_ip ;;
		set_direct_ip)  do_set_direct_ip "$1" ;;
		*) usage; exit 1 ;;
	esac
}

main "$@"
