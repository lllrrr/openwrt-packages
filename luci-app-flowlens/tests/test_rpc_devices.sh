#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
RPC_SCRIPT="$ROOT_DIR/root/usr/libexec/rpcd/luci.flowlens"
WORK_DIR="$(mktemp -d)"

cleanup() {
	rm -rf "$WORK_DIR"
}
trap cleanup EXIT

mkdir -p "$WORK_DIR/state"
mkdir -p "$WORK_DIR/bin"
NOW="$(TZ=UTC node -e "console.log(Math.floor(Date.parse('2026-05-31T12:00:00Z') / 1000))")"
PREV_NOW=$((NOW - 10))

cat > "$WORK_DIR/bin/ip" <<'EOF'
#!/bin/sh
if [ "$1" = "neigh" ] && [ "$2" = "show" ]; then
	cat "$FLOWLENS_IP_NEIGH_FIXTURE"
fi
EOF
chmod +x "$WORK_DIR/bin/ip"

cat > "$WORK_DIR/dhcp.leases" <<'EOF'
1900000000 aa:bb:cc:dd:ee:01 192.168.5.11 studio-laptop 01:aa:bb:cc:dd:ee:01
1900000000 aa:bb:cc:dd:ee:02 192.168.5.12 media-box 01:aa:bb:cc:dd:ee:02
EOF

cat > "$WORK_DIR/arp" <<'EOF'
IP address       HW type     Flags       HW address            Mask     Device
192.168.5.11     0x1         0x2         aa:bb:cc:dd:ee:01     *        br-lan
192.168.5.50     0x1         0x2         aa:bb:cc:dd:ee:03     *        br-lan
EOF

cat > "$WORK_DIR/neigh" <<'EOF'
192.168.5.130 dev br-lan lladdr aa:bb:cc:dd:ee:01 STALE
240e:3b2:3e81:1a90:f481:8375:7a37:55a3 dev br-lan lladdr aa:bb:cc:dd:ee:01 REACHABLE
fd56:2f5a:882c:0:c24:4573:4d83:e36d dev br-lan lladdr aa:bb:cc:dd:ee:01 DELAY
fe80::405:5641:82d:5a7f dev br-lan lladdr aa:bb:cc:dd:ee:01 STALE
fe80::1234:5678:abcd:ef01 dev br-lan lladdr aa:bb:cc:dd:ee:03 REACHABLE
EOF

cat > "$WORK_DIR/nlbw.csv" <<'EOF'
mac conns rx_bytes rx_pkts tx_bytes tx_pkts
aa:bb:cc:dd:ee:01 3 11240 10 5620 5
aa:bb:cc:dd:ee:02 1 2048 2 1024 1
aa:bb:cc:dd:ee:03 0 100 1 50 1
EOF

cat > "$WORK_DIR/conntrack" <<'EOF'
ipv4 2 tcp 6 431999 ESTABLISHED src=192.168.5.11 dst=8.8.8.8 sport=41000 dport=443 packets=10 bytes=2500 src=8.8.8.8 dst=203.0.113.8 sport=443 dport=41000 packets=12 bytes=4000 [ASSURED] mark=0 use=1
EOF

cat > "$WORK_DIR/state/rates.state" <<EOF
aa:bb:cc:dd:ee:01|1000|500|$PREV_NOW
aa:bb:cc:dd:ee:02|0|0|$PREV_NOW
EOF

cat > "$WORK_DIR/state/live.state" <<EOF
aa:bb:cc:dd:ee:01|2000|1000|$PREV_NOW
aa:bb:cc:dd:ee:02|0|0|$PREV_NOW
EOF

cat > "$WORK_DIR/state/devices.cache" <<EOF
aa:bb:cc:dd:ee:01|fe80::1c82:53bb:c103:db90|studio-laptop|$PREV_NOW|192.168.5.130|fe80::1c82:53bb:c103:db90 240e:3b2:3e81:1a90:old:old:old:old
EOF

OUTPUT="$(
	TZ=UTC \
	PATH="$WORK_DIR/bin:$PATH" \
	FLOWLENS_STATE_DIR="$WORK_DIR/state" \
	FLOWLENS_LEASES_FILE="$WORK_DIR/dhcp.leases" \
	FLOWLENS_ARP_FILE="$WORK_DIR/arp" \
	FLOWLENS_IP_NEIGH_FIXTURE="$WORK_DIR/neigh" \
	FLOWLENS_NLBW_FIXTURE="$WORK_DIR/nlbw.csv" \
	FLOWLENS_CONNTRACK_FIXTURE="$WORK_DIR/conntrack" \
	FLOWLENS_NOW="$NOW" \
		"$RPC_SCRIPT" call devices
)"

WORK_DIR="$WORK_DIR" FLOWLENS_JSON="$OUTPUT" node <<'NODE'
const assert = require('assert');

const data = JSON.parse(process.env.FLOWLENS_JSON);
assert(Array.isArray(data.devices), 'devices must be an array');
assert.strictEqual(data.devices.length, 3, 'DHCP and live neighbour devices are returned');

const byMac = new Map(data.devices.map(device => [device.mac, device]));
const laptop = byMac.get('aa:bb:cc:dd:ee:01');
const mediaBox = byMac.get('aa:bb:cc:dd:ee:02');
const fallbackDevice = byMac.get('aa:bb:cc:dd:ee:03');

assert(laptop, 'online laptop is present');
assert(mediaBox, 'offline media box is present');
assert(fallbackDevice, 'device without DHCP is present');
assert.strictEqual(laptop.name, 'studio-laptop');
assert.strictEqual(laptop.ip, '192.168.5.11');
assert.deepStrictEqual(laptop.ipv4, ['192.168.5.11']);
assert.deepStrictEqual(laptop.ipv6, ['240e:3b2:3e81:1a90:f481:8375:7a37:55a3']);
assert(laptop.history_ipv4.includes('192.168.5.130'), 'STALE IPv4 neighbour is only historical');
assert(laptop.history_ipv6.includes('fe80::405:5641:82d:5a7f'), 'link-local IPv6 is only historical');
assert(laptop.history_ipv6.includes('fd56:2f5a:882c:0:c24:4573:4d83:e36d'), 'non-primary useful IPv6 is in history');
assert(!laptop.ipv4.includes('192.168.5.130'), 'DHCP IPv4 wins over neighbour/cache IPv4');
assert(!laptop.ipv6.some(ip => ip.startsWith('fe80:')), 'link-local IPv6 is hidden from main display');
assert.strictEqual(laptop.online, true);
assert.strictEqual(laptop.down_bps, 200);
assert.strictEqual(laptop.up_bps, 150);
assert.strictEqual(mediaBox.online, false);
assert.strictEqual(mediaBox.ip, '192.168.5.12');
assert.deepStrictEqual(mediaBox.ipv4, ['192.168.5.12']);
assert.deepStrictEqual(mediaBox.ipv6, []);
assert.strictEqual(mediaBox.down_bps, 0);
assert.strictEqual(mediaBox.up_bps, 0);
assert.strictEqual(fallbackDevice.ip, '192.168.5.50');
assert.deepStrictEqual(fallbackDevice.ipv4, ['192.168.5.50']);
assert.deepStrictEqual(fallbackDevice.ipv6, []);
assert(fallbackDevice.history_ipv6.includes('fe80::1234:5678:abcd:ef01'));
assert.strictEqual(fallbackDevice.online, true);
assert.strictEqual(data.summary.online, 2);
assert.strictEqual(data.summary.offline, 1);
assert.strictEqual(data.summary.down_bps, 200);
assert.strictEqual(data.summary.up_bps, 150);
assert.strictEqual(data.meta.rate_source, 'conntrack + nlbwmon');
assert.strictEqual(data.meta.period_start, '2026-05-01');
assert.strictEqual(data.meta.period_end, '2026-05-31');
assert.strictEqual(data.meta.period_label, '2026-05-01 - 2026-05-31');

const cacheLines = require('fs').readFileSync(`${process.env.WORK_DIR}/state/devices.cache`, 'utf8').trim().split('\n');
const cacheLaptop = cacheLines.find(line => line.startsWith('aa:bb:cc:dd:ee:01|'));
assert.strictEqual(cacheLaptop.split('|').length, 4, 'cache stores only mac, last main ip, name and last_seen');
assert(cacheLaptop.includes('|192.168.5.11|'), 'cache persists only the last main IP for the laptop');
NODE

echo "ok - flowlens rpc devices contract"
