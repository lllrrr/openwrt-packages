#!/bin/sh
# Copyright (c) 2026 Eugene Chan
# SPDX-License-Identifier: MIT
#
# Lightweight process supervisor modelled after Passwall2's monitor. It checks
# both the recorded PID and the actual listening socket, then requests one full
# serialized restart so firewall, DNS and policy-routing state remain atomic.

. /usr/share/bypass/utils.sh

READY_FILE=/var/lock/bypass_ready.lock

component_healthy() {
	local name=$1 port=$2 protocol=$3
	process_alive "$name" && [ "$(check_port_exists "$port" "$protocol")" -gt 0 ] 2>/dev/null
}

# The init wrapper creates READY_FILE after app.sh returns successfully. Avoid
# treating this short hand-off interval as a crash.
waited=0
while [ ! -f "$READY_FILE" ] && [ "$waited" -lt 30 ]; do
	[ "$(config_t_get global enabled 0)" = "1" ] || exit 0
	waited=$((waited + 1))
	sleep 1
done
[ -f "$READY_FILE" ] || exit 0

while [ "$(config_t_get global enabled 0)" = "1" ] && [ -f "$READY_FILE" ]; do
	sleep 5
	[ -f "$READY_FILE" ] || exit 0

	failed_name=""
	failed_log=""
	redir_port=$(get_cache_var ACL_GLOBAL_redir_port)
	if [ -z "$redir_port" ] || ! component_healthy bypasscore "$redir_port" tcp; then
		failed_name=bypasscore
		failed_log="$TMP_ACL_PATH/bypasscore.log"
	fi

	if [ -z "$failed_name" ] && [ -s "$TMP_PATH/node_ports" ]; then
		while read -r node port; do
			[ -n "$node" ] && [ -n "$port" ] || continue
			if ! component_healthy "naive_${node}" "$port" tcp; then
				failed_name="NaiveProxy node [$node]"
				failed_log="$TMP_ACL_PATH/nodes/naive_${node}.log"
				break
			fi
		done < "$TMP_PATH/node_ports"
	fi

	if [ -z "$failed_name" ] && [ "$(config_t_get global_dns remote_dns_detour remote)" = "remote" ]; then
		dns_port=$(get_cache_var DNS2SOCKS_PORT)
		if [ -z "$dns_port" ] || ! component_healthy dns2socks "$dns_port" udp; then
			failed_name=dns2socks
			failed_log="$TMP_ACL_PATH/dns2socks.log"
		fi
	fi

	if [ -z "$failed_name" ] && [ "$(config_t_get global dns_redirect 1)" = "1" ]; then
		chinadns_port=$(config_t_get global_dns chinadns_listen_port 10553)
		if ! component_healthy chinadns-ng "$chinadns_port" udp; then
			failed_name=ChinaDNS-NG
			failed_log="$TMP_ACL_PATH/chinadns-ng.log"
		fi
	fi

	[ -n "$failed_name" ] || continue
	log 0 "Process monitor detected an unhealthy %s; scheduling a full restart." "$failed_name"
	log_component_tail "$failed_name" "$failed_log"
	rm -f "$READY_FILE"
	( sleep 1; /etc/init.d/bypass restart >/dev/null 2>&1 ) &
	exit 1
done

exit 0
