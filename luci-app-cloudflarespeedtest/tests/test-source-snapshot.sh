#!/bin/sh

# Variables are used by the extracted shell functions.
# shellcheck disable=SC2034,SC1091

set -eu

ROOT_DIR="$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d /tmp/cloudflarespeedtest-snapshot-test.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/results"
cat > "$TMP_DIR/cdnspeedtest" <<'EOF'
#!/bin/sh
output=''
source_file=''
while [ "$#" -gt 0 ]; do
	case "$1" in
		-o) output="$2"; shift 2 ;;
		-f) source_file="$2"; shift 2 ;;
		*) shift ;;
	esac
done
[ ! -f "$MOCK_FAIL" ] || exit 1
cp "$source_file" "$MOCK_SEEN"
printf '%s\n' '203.0.113.0/24' > "$MOCK_ORIGINAL"
printf '%s\n' 'header' '192.0.2.1,4,4,0,10,40,N/A' > "$output"
EOF
chmod +x "$TMP_DIR/cdnspeedtest"

sed -n '/^function first_result_ip(){/,/^function ip_replace(){/p' \
	"$ROOT_DIR/root/usr/bin/cloudflarespeedtest/cloudflarespeedtest.sh" |
	sed '$d' | sed "s@/usr/bin/cdnspeedtest@$TMP_DIR/cdnspeedtest@g" > "$TMP_DIR/functions.sh"

LOG_FILE="$TMP_DIR/log"
RESULT_DIR="$TMP_DIR/results"
IP_FILE="$RESULT_DIR/result.csv"
RESULT_SOURCE_FILE="$RESULT_DIR/result-source.txt"
IPV4_TXT="$TMP_DIR/builtin-v4"
IPV6_TXT="$TMP_DIR/builtin-v6"
ip_source='custom_file'
custom_ip_file="$TMP_DIR/custom.txt"
custom_allip='0'
speed_limit='0'
custom_url='https://example.org/'
advanced='0'
proxy_mode='none'
MosDNS_enabled='0'
MOCK_ORIGINAL="$custom_ip_file"
MOCK_SEEN="$TMP_DIR/seen.txt"
MOCK_FAIL="$TMP_DIR/fail"
export MOCK_ORIGINAL MOCK_SEEN MOCK_FAIL

echolog() { printf '%s\n' "$*" >> "$LOG_FILE"; }
uci() { return 1; }
appinit() { :; }
prepare_homeproxy() { :; }
prepare_openclash() { :; }
rotate_result_files() { [ ! -f "$IP_FILE" ] || mv "$IP_FILE" "$IP_FILE.1"; }

# The extracted code uses unset optional UCI settings, as on OpenWrt.
set +u
. "$TMP_DIR/functions.sh"
printf '%s\n' '192.0.2.0/24' > "$custom_ip_file"
if ! speed_test; then
	printf '%s\n' 'Expected successful speed test' >&2
	exit 1
fi
printf '%s\n' '192.0.2.0/24' > "$TMP_DIR/expected"
cmp "$TMP_DIR/expected" "$MOCK_SEEN"
cmp "$TMP_DIR/expected" "$RESULT_SOURCE_FILE"
grep -Fqx '203.0.113.0/24' "$custom_ip_file"
cp "$IP_FILE" "$TMP_DIR/previous-result"
cp "$RESULT_SOURCE_FILE" "$TMP_DIR/previous-source"

: > "$MOCK_FAIL"
if speed_test; then
	printf '%s\n' 'Expected failed speed test' >&2
	exit 1
fi
cmp "$IP_FILE" "$TMP_DIR/previous-result"
cmp "$RESULT_SOURCE_FILE" "$TMP_DIR/previous-source"
rm -f "$MOCK_FAIL" "$custom_ip_file"
if speed_test 2>/dev/null; then
	printf '%s\n' 'Expected missing custom list to fail' >&2
	exit 1
fi
cmp "$IP_FILE" "$TMP_DIR/previous-result"
cmp "$RESULT_SOURCE_FILE" "$TMP_DIR/previous-source"

printf '%s\n' 'Speed test source snapshot tests passed'
