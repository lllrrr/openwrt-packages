#!/bin/sh
# luci-app-tasks shared helpers.
# POSIX sh only: /bin/sh on OpenWrt is BusyBox ash.

TASKS_CONFIG=tasks
TASKS_DIR=/etc/tasks
TASKS_LOG=$TASKS_DIR/tasks.log
TASKS_STARTUP=$TASKS_DIR/startup.sh
TASKS_CRON=/etc/crontabs/root
TASKS_MARK=luci-app-tasks
TASKS_LOG_LIMIT=500

# Read a UCI option, falling back to a default when it is unset.
# tasks_cfg <section> <option> [default]
tasks_cfg() {
	local value

	value=$(uci -q get "$TASKS_CONFIG.$1.$2" 2>/dev/null)
	[ -n "$value" ] || value=$3
	printf '%s' "$value"
}

# Clamp an integer option to [min, max]; non-numeric values become <default>.
# tasks_int <value> <min> <max> <default>
tasks_int() {
	local value=$1

	case "$value" in
		''|*[!0-9-]*)
			printf '%s' "$4"
			return 0
			;;
		-*)
			# Negative numbers are meaningless here; clamp to the minimum.
			printf '%s' "$2"
			return 0
			;;
		*[!0-9]*)
			printf '%s' "$4"
			return 0
			;;
	esac

	# Strip leading zeroes so arithmetic never treats the value as octal.
	value=$(printf '%s' "$value" | sed 's/^0*//')
	[ -n "$value" ] || value=0
	value=$((value + 0))

	[ "$value" -lt "$2" ] && value=$2
	[ "$value" -gt "$3" ] && value=$3
	printf '%s' "$value"
}

# Only allow the weekday presets emitted by the web UI.
# tasks_weekday <value> -> prints a safe cron weekday field
tasks_weekday() {
	case "$1" in
		''|*[!0-6,-]*)
			printf '*'
			;;
		*)
			printf '%s' "$1"
			;;
	esac
}

# Translate the friendly schedule options into a cron time expression.
# tasks_cron_expr <mode> <hour> <minute> <weekday> <monthday> <imin> <ihour>
tasks_cron_expr() {
	local mode=$1 hour=$2 minute=$3 weekday=$4 monthday=$5 imin=$6 ihour=$7

	case "$mode" in
		daily)
			printf '%s %s * * *' "$minute" "$hour"
			;;
		weekly)
			printf '%s %s * * %s' "$minute" "$hour" "$weekday"
			;;
		monthly)
			printf '%s %s %s * *' "$minute" "$hour" "$monthday"
			;;
		hourly)
			printf '%s * * * *' "$minute"
			;;
		interval_minutes)
			printf '*/%s * * * *' "$imin"
			;;
		interval_hours)
			printf '%s */%s * * *' "$minute" "$ihour"
			;;
		*)
			return 1
			;;
	esac
}

# A UCI section name must be safe to embed in generated shell code.
tasks_valid_section() {
	case "$1" in
		''|*[!A-Za-z0-9_-]*)
			return 1
			;;
	esac

	return 0
}

# An init.d service name must not escape /etc/init.d.
tasks_valid_service() {
	case "$1" in
		''|*[!A-Za-z0-9._-]*)
			return 1
			;;
	esac

	return 0
}

# --- Internet access control ------------------------------------------------

# Validate a 24 hour clock value in HH:MM form.
# tasks_valid_time <HH:MM>
tasks_valid_time() {
	case "$1" in
		[0-2][0-9]:[0-5][0-9])
			[ "${1%%:*}" -le 23 ]
			return $?
			;;
	esac

	return 1
}

# Convert a validated HH:MM value into minutes since midnight.
# tasks_time_minutes <HH:MM>
tasks_time_minutes() {
	local hh=${1%%:*} mm=${1##*:}

	hh=$(printf '%s' "$hh" | sed 's/^0*//')
	mm=$(printf '%s' "$mm" | sed 's/^0*//')
	[ -n "$hh" ] || hh=0
	[ -n "$mm" ] || mm=0

	printf '%s' $((hh * 60 + mm))
}

# Return success when <now> lies in the inclusive window <start>..<end>.
# Equal start and end mean "the whole day", matching the timecontrol model.
# tasks_in_window <start> <end> <now>
tasks_in_window() {
	local start end now

	start=$(tasks_time_minutes "$1")
	end=$(tasks_time_minutes "$2")
	now=$(tasks_time_minutes "$3")

	if [ "$start" -eq "$end" ]; then
		return 0
	elif [ "$start" -lt "$end" ]; then
		[ "$now" -ge "$start" ] && [ "$now" -le "$end" ] && return 0
	else
		{ [ "$now" -ge "$start" ] || [ "$now" -le "$end" ]; } && return 0
	fi

	return 1
}

# Only allow the weekday presets emitted by the web UI. `*` means every day,
# `0` is Sunday (the same numbering as cron). Anything else degrades to `*`;
# each comma separated item must be one digit, so "12" is not treated as
# "1 and 2".
# tasks_week_field <value>
tasks_week_field() {
	local list=$1 rest item

	case "$list" in
		''|'*')
			printf '*'
			return 0
			;;
	esac

	rest=$list

	while [ -n "$rest" ]; do
		case "$rest" in
			*,*)
				item=${rest%%,*}
				rest=${rest#*,}
				;;
			*)
				item=$rest
				rest=''
				;;
		esac

		case "$item" in
			[0-6]) ;;
			*)
				printf '*'
				return 0
				;;
		esac
	done

	printf '%s' "$list"
}

# tasks_week_allowed <comma separated days|*> <weekday 0..6>
tasks_week_allowed() {
	local list=$1 day=$2

	list=$(tasks_week_field "$list")

	[ "$list" = "*" ] && return 0

	case ",$list," in
		*",$day,"*)
			return 0
			;;
	esac

	return 1
}

# tasks_valid_ipv4 <address>
tasks_valid_ipv4() {
	local ip=$1 octet oldifs count

	case "$ip" in
		''|*[!0-9.]*)
			return 1
			;;
	esac

	oldifs=$IFS
	IFS=.
	set -- $ip
	IFS=$oldifs

	[ $# -eq 4 ] || return 1

	for octet in "$@"; do
		case "$octet" in
			''|*[!0-9]*)
				return 1
				;;
		esac

		count=${#octet}
		[ "$count" -le 3 ] || return 1

		octet=$(printf '%s' "$octet" | sed 's/^0*//')
		[ -n "$octet" ] || octet=0
		[ "$octet" -le 255 ] || return 1
	done

	return 0
}

# Print the kind of a firewall target, or fail if it is not supported.
# Supported: MAC address, IPv4 address and IPv4 CIDR prefix.
# tasks_target_kind <target> -> mac | ipv4
tasks_target_kind() {
	local value=$1 ip mask

	[ -n "$value" ] || return 1

	if printf '%s' "$value" |
			grep -qE '^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$'; then
		printf 'mac'
		return 0
	fi

	case "$value" in
		*/*)
			ip=${value%/*}
			mask=${value#*/}

			case "$mask" in
				''|*[!0-9]*)
					return 1
					;;
			esac

			[ "$mask" -le 32 ] || return 1
			tasks_valid_ipv4 "$ip" || return 1
			;;
		*)
			tasks_valid_ipv4 "$value" || return 1
			;;
	esac

	printf 'ipv4'
	return 0
}

# Trim whitespace and canonicalise MAC addresses to lower case.
# tasks_normalize_target <target>
tasks_normalize_target() {
	local value

	value=$(printf '%s' "$1" | tr -d '[:space:]')

	case "$value" in
		*:*)
			printf '%s' "$value" | tr 'A-F' 'a-f'
			;;
		*)
			printf '%s' "$value"
			;;
	esac
}

# List the access_device UCI sections, one per line.
tasks_access_sections() {
	uci -q show tasks 2>/dev/null |
		sed -n 's/^tasks\.\([A-Za-z0-9_-]*\)=access_device$/\1/p'
}

# Return success when at least one enabled access device has a target.
tasks_access_has_devices() {
	local section

	for section in $(tasks_access_sections); do
		tasks_valid_section "$section" || continue
		[ "$(tasks_cfg "$section" enabled 0)" = "1" ] || continue
		[ -n "$(tasks_cfg "$section" target '')" ] || continue
		return 0
	done

	return 1
}

tasks_cron_count() {
	local count=0

	[ -f "$TASKS_CRON" ] && count=$(grep -c "$TASKS_MARK" "$TASKS_CRON" 2>/dev/null)
	[ -n "$count" ] || count=0
	printf '%s' "$count"
}

# tasks_log <source> <message>
tasks_log() {
	mkdir -p "$TASKS_DIR" 2>/dev/null
	printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2" >>"$TASKS_LOG"
	chmod 600 "$TASKS_LOG" 2>/dev/null
	tasks_log_limit
}

# Keep the log bounded so it cannot grow forever on flash.
tasks_log_limit() {
	local count

	[ -f "$TASKS_LOG" ] || return 0
	count=$(wc -l <"$TASKS_LOG" 2>/dev/null)
	[ -n "$count" ] || count=0
	count=$((count + 0))

	if [ "$count" -gt "$TASKS_LOG_LIMIT" ]; then
		tail -n "$TASKS_LOG_LIMIT" "$TASKS_LOG" >"$TASKS_LOG.tmp.$$" 2>/dev/null &&
			mv "$TASKS_LOG.tmp.$$" "$TASKS_LOG"
	fi
}
