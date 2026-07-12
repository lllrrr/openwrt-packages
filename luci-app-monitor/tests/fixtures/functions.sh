#!/bin/sh

config_load() {
	return 0
}

fixture_value() {
	case "$1.$2" in
		global.enabled) printf '%s' "${TEST_ENABLED:-1}" ;;
		global.interval) printf '%s' "${TEST_INTERVAL:-10}" ;;
		global.timeout) printf '%s' "${TEST_TIMEOUT:-2}" ;;
		global.failure_threshold) printf '%s' "${TEST_FAILURE_THRESHOLD:-3}" ;;
		global.recovery_threshold) printf '%s' "${TEST_RECOVERY_THRESHOLD:-2}" ;;
		global.quorum) printf '%s' "${TEST_QUORUM:-2}" ;;
		global.history_days) printf '%s' "${TEST_HISTORY_DAYS:-30}" ;;
		target_icmp.enabled) printf '1' ;;
		target_icmp.name) printf 'Test ICMP' ;;
		target_icmp.type) printf 'icmp' ;;
		target_icmp.address) printf '198.51.100.1' ;;
		target_icmp.family) printf 'ipv4' ;;
		target_icmp.timeout) printf '2' ;;
		target_http.enabled) printf '1' ;;
		target_http.name) printf 'Test HTTP' ;;
		target_http.type) printf 'http' ;;
		target_http.address) printf '%s' "${TEST_HTTP_ADDRESS:-https://example.test/generate_204}" ;;
		target_http.family) printf 'auto' ;;
		target_http.timeout) printf '2' ;;
		target_http.expected_codes) printf '%s' "${TEST_EXPECTED_CODES:-200-399}" ;;
		target_extra_*.enabled) printf '1' ;;
		target_extra_*.name) printf 'Extra %s' "${1#target_extra_}" ;;
		target_extra_*.type) printf 'icmp' ;;
		target_extra_*.address) printf '192.0.2.%s' "${1#target_extra_}" ;;
		target_extra_*.family) printf 'ipv4' ;;
		target_extra_*.timeout) printf '1' ;;
		*) return 1 ;;
	esac
}

config_get() {
	local destination="$1" section="$2" option="$3" fallback="${4:-}" value
	value="$(fixture_value "$section" "$option")" || value="$fallback"
	eval "$destination=\$value"
}

config_get_bool() {
	config_get "$@"
}

config_foreach() {
	local callback="$1" type="$2" extra i=1
	[ "$type" = 'target' ] || return 0
	[ "${TEST_NO_TARGETS:-0}" = '1' ] && return 0
	"$callback" target_icmp
	"$callback" target_http
	extra="${TEST_EXTRA_TARGETS:-0}"
	case "$extra" in ''|*[!0-9]*) extra=0 ;; esac
	while [ "$i" -le "$extra" ]; do
		"$callback" "target_extra_$i"
		i=$((i + 1))
	done
}
