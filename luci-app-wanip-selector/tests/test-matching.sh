#!/bin/sh
# Unit tests for the address matching helpers in usr/sbin/wanip-selector.
# Run from anywhere:  sh tests/test-matching.sh
#
# All addresses below come from the documentation ranges of RFC 5737 and the
# private ranges of RFC 1918, so nothing here points at a real network.
#
# SPDX-License-Identifier: MIT

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
TARGET="$SELF_DIR/../root/usr/sbin/wanip-selector"
[ -f "$TARGET" ] || { echo "cannot find $TARGET"; exit 1; }

TMP=$(mktemp) || exit 1
trap 'rm -f "$TMP"' EXIT

# Pull just the pure helper functions out of the script so we can test them
# without ubus, uci or a live interface.
awk '/^# -+ ip utilities/,/^# -+ runtime/' "$TARGET" | grep -v '^# -\+' > "$TMP"
. "$TMP"

pass=0; fail=0
ck() {
	if [ "$2" = "$3" ]; then
		pass=$((pass + 1)); printf '  ok   %-44s = %s\n' "$1" "$3"
	else
		fail=$((fail + 1)); printf '  FAIL %-44s want=%s got=%s\n' "$1" "$2" "$3"
	fi
}
ckm() { # desc expect ip cidr
	if in_cidr "$3" "$4"; then r=yes; else r=no; fi
	ck "$1" "$2" "$r"
}

echo '--- to_cidr ---'
ck 'cidr passthrough'   '198.51.0.0/16'  "$(to_cidr 198.51.0.0/16)"
ck 'prefix 203.0.113.'  '203.0.113.0/24' "$(to_cidr 203.0.113.)"
ck 'prefix 198.51'      '198.51.0.0/16'  "$(to_cidr 198.51)"
ck 'prefix 198.51.'     '198.51.0.0/16'  "$(to_cidr 198.51.)"
ck 'prefix 10.'         '10.0.0.0/8'     "$(to_cidr 10.)"
ck 'bare host'          '192.0.2.7/32'   "$(to_cidr 192.0.2.7)"

echo '--- in_cidr ---'
ckm 'inside /24'          yes 203.0.113.45   203.0.113.0/24
ckm 'outside /24'         no  203.0.114.45   203.0.113.0/24
ckm 'inside /16'          yes 198.51.100.7   198.51.0.0/16
ckm 'outside /16'         no  198.52.100.7   198.51.0.0/16
ckm 'inside /8'           yes 10.20.30.40    10.0.0.0/8
ckm 'outside /8'          no  11.20.30.40    10.0.0.0/8
ckm 'unrelated address'   no  192.0.2.1      198.51.0.0/16
ckm 'match all /0'        yes 192.0.2.1      0.0.0.0/0
ckm 'lower bound'         yes 198.51.0.0     198.51.0.0/16
ckm 'upper bound'         yes 198.51.255.255 198.51.0.0/16
ckm 'just below'          no  198.50.255.255 198.51.0.0/16
ckm 'just above'          no  198.52.0.0     198.51.0.0/16
ckm 'exact /32'           yes 192.0.2.7      192.0.2.7/32
ckm 'off by one /32'      no  192.0.2.8      192.0.2.7/32
ckm 'top of range'        yes 255.255.255.255 255.255.255.0/24

echo '--- is_ipv4 ---'
for bad in '1.2.3' '1.2.3.4.5' '1.2.3.256' 'abc' '' '1.2.3.x'; do
	if is_ipv4 "$bad"; then ck "reject [$bad]" reject accept
	else ck "reject [$bad]" reject reject; fi
done
if is_ipv4 '0.0.0.0'; then ck 'accept 0.0.0.0' accept accept
else ck 'accept 0.0.0.0' accept reject; fi

echo
echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]
