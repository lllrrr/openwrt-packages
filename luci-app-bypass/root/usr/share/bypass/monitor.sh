#!/bin/sh
# Copyright (c) 2026 Eugene Chan
# SPDX-License-Identifier: MIT
#
# Runtime watcher modelled after Passwall2's monitor. BypassCore's structured
# readiness covers all of its listeners, while helpers use PID checks. It also
# watches the installed BypassCore and NaiveProxy executables so a package
# upgrade cannot leave an old, unlinked process running indefinitely.

. /usr/share/bypass/utils.sh

READY_FILE=/var/lock/bypass_ready.lock

# The init wrapper creates READY_FILE after app.sh returns successfully. Avoid
# treating this short hand-off interval as a crash.
waited=0
while [ ! -f "$READY_FILE" ] && [ "$waited" -lt 30 ]; do
	[ "$(config_t_get global enabled 0)" = "1" ] || exit 0
	waited=$((waited + 1))
	sleep 1
done
[ -f "$READY_FILE" ] || exit 0

runtime_binary_snapshot() {
	local bypasscore_file naive_file
	bypasscore_file=$(first_type "$(config_t_get global bypasscore_file /usr/bin/bypasscore)" bypasscore)
	naive_file=$(first_type "$(config_t_get global naive_file /usr/bin/naive)" naive)
	printf 'bypasscore=%s\nnaive=%s\n' \
		"$(binary_fingerprint "$bypasscore_file" 2>/dev/null)" \
		"$(binary_fingerprint "$naive_file" 2>/dev/null)"
}

runtime_images_current() {
	local bypasscore_file naive_file node port
	bypasscore_file=$(first_type "$(config_t_get global bypasscore_file /usr/bin/bypasscore)" bypasscore)
	naive_file=$(first_type "$(config_t_get global naive_file /usr/bin/naive)" naive)
	process_image_current bypasscore "$bypasscore_file" || return 1
	if [ -s "$TMP_PATH/node_ports" ]; then
		while read -r node port; do
			[ -n "$node" ] && [ -n "$port" ] || continue
			process_image_current "naive_${node}" "$naive_file" || return 1
		done < "$TMP_PATH/node_ports"
	fi
	return 0
}

schedule_full_restart() {
	local reason=$1
	rm -f "$READY_FILE"
	# Run the delayed restart from a fresh shell whose command line does not
	# contain TMP_BIN_PATH. stop() intentionally kills every managed helper
	# matching that path, which would otherwise kill this reporter mid-restart.
	nohup /bin/sh -c '
		sleep 2
		if /etc/init.d/bypass restart >/dev/null 2>&1; then
			. /usr/share/bypass/utils.sh
			log 0 "Bypass restart completed after %s." "$1"
		else
			. /usr/share/bypass/utils.sh
			log 0 "Bypass restart failed after %s; check component logs." "$1"
		fi
	' bypass-restart "$reason" >/dev/null 2>&1 &
	exit 0
}

binary_baseline=$(runtime_binary_snapshot)
binary_candidate=""
binary_change_count=0
image_mismatch_count=0

last_failed=""
failure_count=0
while [ "$(config_t_get global enabled 0)" = "1" ] && [ -f "$READY_FILE" ]; do
	# Passwall2 deliberately uses a long supervision interval. Fifteen seconds
	# keeps recovery reasonably quick while avoiding a busy five-second probe.
	sleep 15
	[ -f "$READY_FILE" ] || exit 0

	# Comparing installed files alone can miss an upgrade when this monitor is
	# itself restarted after opkg/apk has already replaced the path. Compare the
	# active native process images with the installed inodes as an independent
	# signal. Require two probes so a multi-package transaction can settle.
	if runtime_images_current; then
		image_mismatch_count=0
	else
		image_mismatch_count=$((image_mismatch_count + 1))
		if [ "$image_mismatch_count" -ge 2 ]; then
			log 0 "A running BypassCore or NaiveProxy image differs from the installed executable; scheduling a full restart."
			schedule_full_restart "a runtime executable update"
		fi
	fi

	# opkg/apk may replace more than one file in a transaction. Require the new
	# snapshot to remain unchanged for two probes before restarting, which avoids
	# racing a partially installed dependency set. A missing executable is part
	# of the snapshot as well and therefore fails closed after the transaction
	# settles instead of silently retaining the old process.
	binary_current=$(runtime_binary_snapshot)
	if [ "$binary_current" != "$binary_baseline" ]; then
		if [ "$binary_current" = "$binary_candidate" ]; then
			binary_change_count=$((binary_change_count + 1))
		else
			binary_candidate=$binary_current
			binary_change_count=1
		fi
		if [ "$binary_change_count" -ge 2 ]; then
			log 0 "Runtime executable update detected; scheduling a full restart."
			schedule_full_restart "a runtime executable update"
		fi
	else
		binary_candidate=""
		binary_change_count=0
	fi

	# The user-facing daemon switch controls crash/health recovery only. Binary
	# update detection above remains active so package upgrades always activate
	# the newly installed core and helper versions.
	[ "$(config_t_get global_delay start_daemon 1)" = "1" ] || continue

	failed_name=""
	failed_process=""
	failed_log=""
	if ! process_alive bypasscore || ! bypasscore_ready; then
		failed_name=bypasscore
		failed_process=bypasscore
		failed_log="$TMP_ACL_PATH/bypasscore.log"
	fi

	if [ -z "$failed_name" ] && [ -s "$TMP_PATH/node_ports" ]; then
		while read -r node port; do
			[ -n "$node" ] && [ -n "$port" ] || continue
			if ! process_alive "naive_${node}"; then
				failed_name="NaiveProxy node [$node]"
				failed_process="naive_${node}"
				failed_log="$TMP_ACL_PATH/nodes/naive_${node}.log"
				break
			fi
		done < "$TMP_PATH/node_ports"
	fi

	if [ -z "$failed_name" ]; then
		last_failed=""
		failure_count=0
		continue
	fi

	# A dead child is definitive. A live process can be temporarily absent from
	# /proc/net during listener reconfiguration or a slow router snapshot, so
	# require three consecutive failures (about 45 seconds), similar in spirit
	# to Passwall2's conservative 58-second monitor loop.
	if [ "$failed_process" = "$last_failed" ]; then
		failure_count=$((failure_count + 1))
	else
		last_failed=$failed_process
		failure_count=1
	fi
	process_alive "$failed_process" || failure_count=3
	[ "$failure_count" -ge 3 ] || continue
	log 0 "Process monitor detected an unhealthy %s; scheduling a full restart." "$failed_name"
	log_component_tail "$failed_name" "$failed_log"
	schedule_full_restart "an unhealthy $failed_name"
done

exit 0
