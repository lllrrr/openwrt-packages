#!/bin/sh

# shellcheck disable=SC2016

set -eu

ROOT_DIR="$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)"
HELPER="${SMARTDNS_HELPER_UNDER_TEST:-$ROOT_DIR/root/usr/bin/cloudflarespeedtest/smartdns.sh}"
TMP_DIR="$(mktemp -d /tmp/cloudflarespeedtest-smartdns-test.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/bin" "$TMP_DIR/etc/smartdns/conf.d"
printf '%s\n' '1' > "$TMP_DIR/enabled"
: > "$TMP_DIR/includes"
: > "$TMP_DIR/reloads"

printf '%s\n' \
	'173.245.48.0/20' \
	'162.159.192.0/21' \
	'162.159.201.0/24' \
	'162.159.237.0/24' \
	'104.17.0.0/16' > "$TMP_DIR/source.txt"

printf '%s\n' \
	'IP 地址,已发送,已接收,丢包率,平均延迟,下载速度 (MB/s),下载测速' \
	'162.159.200.1,4,4,0.00,19.00,31.00,1' \
	'104.17.132.58,4,4,0.00,20.00,30.00,1' \
	'104.17.133.147,4,4,0.00,21.00,29.00,1' \
	'104.17.132.58,4,4,0.00,22.00,28.00,1' \
	'999.1.1.1,4,4,0.00,23.00,27.00,1' \
	'162.159.237.97,4,4,0.00,24.00,26.00,1' > "$TMP_DIR/result.csv"

printf '%s\n' \
	'#!/bin/sh' \
	'state_dir="${MOCK_STATE_DIR:?}"' \
	'[ "$1" = "-q" ] && shift' \
	'command="$1"' \
	'shift' \
	'case "$command" in' \
	'  get)' \
	'    case "$1" in' \
	'      "smartdns.@smartdns[0]") echo smartdns ;;' \
	'      "smartdns.@smartdns[0].enabled") cat "$state_dir/enabled" ;;' \
	'      "smartdns.@smartdns[0].conf_files") [ -s "$state_dir/includes" ] && tr "\\n" " " < "$state_dir/includes" ;;' \
	'      *) exit 1 ;;' \
	'    esac' \
	'    ;;' \
	'  add_list)' \
	'    value="${1#*=}"' \
	'    grep -Fqx "$value" "$state_dir/includes" 2>/dev/null || echo "$value" >> "$state_dir/includes"' \
	'    ;;' \
	'  del_list)' \
	'    value="${1#*=}"' \
	'    grep -Fvx "$value" "$state_dir/includes" > "$state_dir/includes.tmp" || true' \
	'    mv "$state_dir/includes.tmp" "$state_dir/includes"' \
	'    ;;' \
	'  commit) ;;' \
	'  *) exit 1 ;;' \
	'esac' > "$TMP_DIR/bin/uci"

printf '%s\n' \
	'#!/bin/sh' \
	'state_dir="${MOCK_STATE_DIR:?}"' \
	'case "$1" in' \
	'  reload)' \
	'    echo reload >> "$state_dir/reloads"' \
	'    [ ! -f "$state_dir/fail-reload" ] || exit 1' \
	'    : > "$state_dir/running"' \
	'    ;;' \
	'  running) [ -f "$state_dir/running" ] ;;' \
	'  *) exit 1 ;;' \
	'esac' > "$TMP_DIR/bin/smartdns-init"

chmod +x "$TMP_DIR/bin/uci" "$TMP_DIR/bin/smartdns-init"

run_helper() {
	MOCK_STATE_DIR="$TMP_DIR" \
	SMARTDNS_CONFIG_FILE="$TMP_DIR/etc/smartdns/conf.d/cloudflarespeedtest.conf" \
	SMARTDNS_SOURCE_FILE="$TMP_DIR/source.txt" \
	SMARTDNS_INIT="$TMP_DIR/bin/smartdns-init" \
	SMARTDNS_RELOAD_WAIT='0' \
	UCI_BIN="$TMP_DIR/bin/uci" \
		"$HELPER" "$@"
}

assert_contains() {
	grep -Fq "$2" "$1" || {
		printf 'Expected %s to contain: %s\n' "$1" "$2" >&2
		exit 1
	}
}

assert_line_count() {
	actual="$(wc -l < "$1" | tr -d ' ')"
	[ "$actual" = "$2" ] || {
		printf 'Expected %s lines in %s, got %s\n' "$2" "$1" "$actual" >&2
		exit 1
	}
}

run_helper --result-csv "$TMP_DIR/result.csv" --ip-count 3 >/dev/null
CONFIG_FILE="$TMP_DIR/etc/smartdns/conf.d/cloudflarespeedtest.conf"
assert_contains "$CONFIG_FILE" 'ip-rules 104.17.0.0/16 -ip-alias 104.17.132.58,104.17.133.147,162.159.237.97'
assert_contains "$CONFIG_FILE" 'ip-rules 162.159.201.0/24 -ip-alias 104.17.132.58,104.17.133.147,162.159.237.97'
assert_contains "$TMP_DIR/includes" 'cloudflarespeedtest.conf'
assert_line_count "$TMP_DIR/reloads" 1

printf '%s\n' \
	'IP 地址,已发送,已接收,丢包率,平均延迟,下载速度 (MB/s),下载测速' \
	'162.159.200.1,4,4,0.00,19.00,31.00,1' > "$TMP_DIR/excluded-result.csv"
if run_helper --result-csv "$TMP_DIR/excluded-result.csv" >/dev/null; then
	printf '%s\n' 'Expected excluded target to be rejected' >&2
	exit 1
fi
assert_contains "$CONFIG_FILE" 'ip-rules 104.17.0.0/16 -ip-alias 104.17.132.58,104.17.133.147,162.159.237.97'
assert_line_count "$TMP_DIR/reloads" 1

run_helper --result-csv "$TMP_DIR/result.csv" --ip-count 3 >/dev/null
assert_line_count "$TMP_DIR/reloads" 1

printf '%s\n' '104.16.0.0/13' >> "$TMP_DIR/source.txt"
run_helper --result-csv "$TMP_DIR/result.csv" --ip-count 3 >/dev/null
assert_line_count "$TMP_DIR/reloads" 2

cp "$CONFIG_FILE" "$TMP_DIR/known-good.conf"
printf '%s\n' \
	'IP 地址,已发送,已接收,丢包率,平均延迟,下载速度 (MB/s),下载测速' \
	'104.17.1.1,4,4,0.00,10.00,40.00,1' > "$TMP_DIR/new-result.csv"
: > "$TMP_DIR/fail-reload"
if run_helper --result-csv "$TMP_DIR/new-result.csv" --ip-count 1 >/dev/null; then
	printf '%s\n' 'Expected failed SmartDNS reload' >&2
	exit 1
fi
cmp -s "$CONFIG_FILE" "$TMP_DIR/known-good.conf" || {
	printf '%s\n' 'SmartDNS config was not restored after reload failure' >&2
	exit 1
}
rm -f "$TMP_DIR/fail-reload"

run_helper --disable >/dev/null
[ ! -e "$CONFIG_FILE" ] || {
	printf '%s\n' 'Managed SmartDNS config was not removed' >&2
	exit 1
}
[ ! -s "$TMP_DIR/includes" ] || {
	printf '%s\n' 'Managed SmartDNS include was not removed' >&2
	exit 1
}

printf '%s\n' '# User-managed SmartDNS rules' > "$CONFIG_FILE"
printf '%s\n' 'cloudflarespeedtest.conf' > "$TMP_DIR/includes"
run_helper --disable >/dev/null
assert_contains "$CONFIG_FILE" '# User-managed SmartDNS rules'
assert_contains "$TMP_DIR/includes" 'cloudflarespeedtest.conf'
if run_helper --result-csv "$TMP_DIR/result.csv" --ip-count 3 >/dev/null; then
	printf '%s\n' 'Expected unmanaged SmartDNS file protection to reject update' >&2
	exit 1
fi
assert_contains "$CONFIG_FILE" '# User-managed SmartDNS rules'

rm -f "$CONFIG_FILE"
: > "$TMP_DIR/includes"
printf '%s\n' \
	'104.17.0.0/16' \
	'162.159.201.1/32' > "$TMP_DIR/source.txt"
printf '%s\n' \
	'IP 地址,已发送,已接收,丢包率,平均延迟,下载速度 (MB/s),地区码' \
	'104.16.255.255,4,4,0,10,40,N/A' \
	'104.17.0.0,4,4,0,11,39,N/A' \
	'104.17.255.255,4,4,0,12,38,N/A' \
	'104.18.0.0,4,4,0,13,37,N/A' \
	'162.159.201.2,4,4,0,14,36,N/A' \
	'162.159.201.1,4,4,0,15,35,N/A' > "$TMP_DIR/boundaries.csv"
run_helper --result-csv "$TMP_DIR/boundaries.csv" --ip-count 10 >/dev/null
assert_contains "$CONFIG_FILE" 'ip-rules 104.17.0.0/16 -ip-alias 104.17.0.0,104.17.255.255,162.159.201.1'
assert_contains "$CONFIG_FILE" 'ip-rules 162.159.201.1/32 -ip-alias 104.17.0.0,104.17.255.255,162.159.201.1'
cp "$CONFIG_FILE" "$TMP_DIR/known-good.conf"
printf '%s\n' '104.17.0.0/33' > "$TMP_DIR/source.txt"
if run_helper --result-csv "$TMP_DIR/boundaries.csv" >/dev/null; then
	printf '%s\n' 'Expected invalid source range to be rejected' >&2
	exit 1
fi
cmp -s "$CONFIG_FILE" "$TMP_DIR/known-good.conf" || {
	printf '%s\n' 'Invalid source range changed the SmartDNS config' >&2
	exit 1
}

printf '%s\n' '192.0.2.0/24' '198.51.100.9' > "$TMP_DIR/custom-source.txt"
printf '%s\n' \
	'IP 地址,已发送,已接收,丢包率,平均延迟,下载速度 (MB/s),地区码' \
	'192.0.2.1,4,4,0,10,40,N/A' \
	'198.51.100.9,4,4,0,11,39,N/A' > "$TMP_DIR/custom-result.csv"
run_helper --result-csv "$TMP_DIR/custom-result.csv" --source-file "$TMP_DIR/custom-source.txt" >/dev/null
assert_contains "$CONFIG_FILE" 'ip-rules 192.0.2.0/24 -ip-alias 192.0.2.1,198.51.100.9'
assert_contains "$CONFIG_FILE" 'ip-rules 198.51.100.9 -ip-alias 192.0.2.1,198.51.100.9'
cp "$CONFIG_FILE" "$TMP_DIR/known-good.conf"
printf '%s\n' '203.0.113.0/24' > "$TMP_DIR/custom-source.txt"
cmp -s "$CONFIG_FILE" "$TMP_DIR/known-good.conf" || {
	printf '%s\n' 'Changing the source file changed the installed SmartDNS snapshot' >&2
	exit 1
}

printf '%s\n' 'SmartDNS integration tests passed'
