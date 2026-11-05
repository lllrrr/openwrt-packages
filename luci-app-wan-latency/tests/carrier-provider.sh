#!/bin/sh
set -eu
helper=$1
root=$(mktemp -d /tmp/carrier-test.XXXXXX)
trap 'rm -rf "$root"' EXIT
mkdir -p "$root/tmp/unisoc-modem" "$root/run" "$root/etc/config"
echo 0 > "$root/run/mu300-data-sim-actual"
now=$(date +%s)
cache() { printf '{"ts":%s,"reg":{"stat":%s},"operator":{"plmn":"%s"},"ident":{"iccid":"%s"}}\n' "$1" "$2" "$3" "$4" > "$root/tmp/unisoc-modem/cell.json"; }
wan() { printf '{"up":%s,"uptime":%s}\n' "$1" "$2" > "$root/wan.json"; }
check() { result=$(MONITOR_CARRIER_TEST_ROOT="$root" sh "$helper" sample); [ "$result" = "$1" ] || { echo "Expected $1, got $result" >&2; exit 1; }; }
wan true 1000; cache "$now" 1 46011 card-a; check 3
cache "$now" 1 46000 card-b; check 1
cache "$now" 1 46001 card-c; check 2
cache "$now" 1 46015 card-d; check 4
# The same slot and an old full snapshot must not label a new connection.
wan true 2; cache "$((now-30))" 1 46011 card-a; check 0
wan true 1000; cache "$((now-180))" 1 46011 card-a; check 0
cache "$now" 0 46011 card-a; check 0
wan false 1000; cache "$now" 1 46011 card-a; check 0
wan true 1000; touch "$root/run/unisoc-data-sim-switch"; check 6
rm "$root/run/unisoc-data-sim-switch"
# Manual correction is scoped to this SIM's fingerprint, never just its slot.
fingerprint=$(printf card-a | sha256sum); fingerprint=${fingerprint%% *}
printf "config monitor 'main'\n option sim0 '1'\n option fingerprint0 '%s'\n" "$fingerprint" > "$root/etc/config/monitor_carrier"
cache "$now" 1 46011 card-a; check 1
cache "$now" 1 46011 card-new; check 3
printf 'PASS carrier identity, manual fingerprint, hot swap, stale cache, unplug and transition\n'
