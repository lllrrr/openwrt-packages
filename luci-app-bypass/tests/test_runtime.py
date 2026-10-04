"""Host-side regression tests. No router services or host configuration are touched."""
import base64
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import tempfile
import tarfile
import io
import unittest

REPO = Path(__file__).resolve().parents[1]
RUNTIME = REPO / 'root/usr/share/bypass'
SHELL = os.environ.get('BYPASS_TEST_SHELL', '/bin/sh')


def source(name):
    path = RUNTIME / name
    revision = os.environ.get('BYPASS_TEST_REVISION')
    if revision:
        text = subprocess.check_output(['git', 'show', f'{revision}:{path.relative_to(REPO)}'], cwd=REPO, text=True)
    else:
        text = path.read_text()
    # Stub only imports and dispatch; execute the repository's actual functions.
    text = re.sub(r'^(?:APP_SOURCED=1 )?\. .*$', '', text, flags=re.M)
    if name == 'app.sh':
        text = text.split('if [ "${APP_SOURCED:-0}"')[0]
    if name == 'rule_update.sh':
        text = text.split('case "${1:-update}"')[0]
    if name == 'api.sh':
        text = text.rsplit('\nmain "$@"', 1)[0]
    return text


JSON_HELPER = r'''
import json, pathlib, sys
parts = pathlib.Path(sys.argv[1]).read_bytes().split(b'\0')[:-1]
root = {}; stack = [root]
for i in range(0, len(parts), 3):
    kind, key, val = [v.decode() for v in parts[i:i+3]]
    if kind == 'close': stack.pop(); continue
    value = {} if kind == 'object' else [] if kind == 'array' else int(val) if kind in ('int', 'boolean') else val
    if isinstance(stack[-1], list): stack[-1].append(value)
    else: stack[-1][key] = value
    if kind in ('object', 'array'): stack.append(value)
print(json.dumps(root))
'''


class RuntimeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='bypass-test-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.libs = source('utils.sh') + '\n' + source('app.sh') + '\n' + source('api.sh')
        self.helper = self.root / 'json_helper.py'
        self.helper.write_text(JSON_HELPER)
        self.flock_helper = self.root / 'flock_helper.py'
        self.flock_helper.write_text("import fcntl,sys\nflags=fcntl.LOCK_UN if '-u' in sys.argv else fcntl.LOCK_EX\nif any('n' in a for a in sys.argv[1:-1]): flags |= fcntl.LOCK_NB\nfcntl.flock(int(sys.argv[-1]),flags)\n")
        self.events = self.root / 'json.events'
        self.state = self.root / 'state'
        self.state.mkdir()
        self.prelude = f'''
{self.libs}
TMP_PATH={shlex.quote(str(self.state))}
TMP_PATH2="$TMP_PATH/tmp"
TMP_ACL_PATH="$TMP_PATH/acl"
TMP_BIN_PATH="$TMP_PATH/bin"
TMP_PID_PATH="$TMP_PATH/pids"
BYPASSCORE_CFG="$TMP_PATH/config.json"
APP_PATH={shlex.quote(str(self.root / 'app'))}
LOG_FILE="$TMP_PATH/log"
mkdir -p "$TMP_PATH2" "$TMP_ACL_PATH" "$APP_PATH"
EVENTS={shlex.quote(str(self.events))}
json_init() {{ : > "$EVENTS"; }}
json_event() {{ printf '%s\\000%s\\000%s\\000' "$1" "$2" "$3" >> "$EVENTS"; }}
json_add_object() {{ json_event object "$1" ''; }}
json_add_array() {{ json_event array "$1" ''; }}
json_add_string() {{ json_event string "$1" "$2"; }}
json_add_int() {{ json_event int "$1" "$2"; }}
json_add_boolean() {{ json_event boolean "$1" "$2"; }}
json_close_object() {{ json_event close '' ''; }}
json_close_array() {{ json_event close '' ''; }}
json_dump() {{ {shlex.quote(shutil.which('python3'))} {shlex.quote(str(self.helper))} "$EVENTS"; }}
flock() {{ {shlex.quote(shutil.which('python3'))} {shlex.quote(str(self.flock_helper))} "$@"; }}
log() {{ :; }}
process_alive() {{ return 1; }}
check_port_exists() {{ echo 0; }}
config_t_get() {{ printf '%s\\n' "$3"; }}
config_n_get() {{ printf '%s\\n' "$3"; }}
config_get_type() {{ return 1; }}
uci() {{ :; }}
shunt_rule_sections() {{ :; }}
'''

    def run_shell(self, body, prelude=None, timeout=15):
        script = (self.prelude if prelude is None else prelude) + '\n' + body
        result = subprocess.run([SHELL], input=script, text=True, capture_output=True, timeout=timeout)
        self.assertEqual(result.returncode, 0, result.stderr + '\n' + result.stdout)
        return result.stdout.strip()

    def test_ports_skip_busy_reserved_and_wrap(self):
        output = self.run_shell('''
check_port_exists() { case "$1" in 1088|65535) echo 1 ;; *) echo 0 ;; esac; }
get_new_port 1088 tcp '1089 1090'
get_new_port 65535 tcp '1 2'
get_new_port 65000 tcp
get_new_port 01088 tcp
''')
        self.assertEqual(output.splitlines(), ['1091', '3', '65000', '1089'])

    def test_bypasscore_start_guard_allows_slow_cold_boot(self):
        output = self.run_shell('''
# A cold GeoData load can take more than the former 20-second guard. Simulate
# the core becoming ready on the 21st probe and ensure the finite extended
# timeout accepts it instead of stopping a healthy process.
ticks=0
process_alive() { return 0; }
check_port_exists() { [ "$ticks" -ge 21 ] && echo 1 || echo 0; }
sleep() { ticks=$((ticks + 1)); }
wait_for_listener bypasscore 1041 tcp "$BYPASSCORE_START_TIMEOUT" "$TMP_PATH/bypasscore.log"
printf '%s %s\n' "$BYPASSCORE_START_TIMEOUT" "$ticks"
''')
        self.assertEqual(output, '120 21')

    def test_node_ports_are_unique_and_do_not_take_core_ports(self):
        output = self.run_shell('''
NODE_SOCKS_PORT=1088 REDIR_PORT=1089 BYPASSCORE_DNS_PORT=1091 DEFAULT_NODE=node_b
shunt_rule_sections() { echo rule_a; }
config_n_get() { case "$1.$2" in rule_a.outbound) echo node_a ;; *) echo "$3" ;; esac; }
config_get_type() { case "$1" in node_a|node_b) echo nodes ;; esac; }
check_port_exists() { [ "$1" = 1088 ] && echo 1 || echo 0; }
prepare_selected_nodes || exit 1
cat "$TMP_PATH/node_ports"
''')
        self.assertEqual(output.splitlines(), ['node_a 1090', 'node_b 1092'])

    def test_closed_rules_emit_no_matchers_or_bound_outbound(self):
        self.run_shell('''
NODE_SOCKS_PORT=1088 REDIR_PORT=1041 BYPASSCORE_DNS_PORT=10554 DEFAULT_NODE=_direct
REMOTE_DNS_DETOUR=direct REMOTE_DNS_PROTOCOL=tcp DOMAIN_STRATEGY=AsIs
PROXY_IPV6=0 WRITE_IPSET_DIRECT=0 DOMESTIC_DNS=223.5.5.5
shunt_rule_sections() { printf '%s\\n' closed deleted active; }
config_n_get() {
 case "$1.$2" in
 closed.outbound) echo '' ;; active.outbound) echo _blackhole ;;
 *.domain_list) echo domain:example.com ;; closed.egress_interface) echo wan_missing ;;
 *) echo "$3" ;; esac
}
is_bypasscore() { return 1; }
get_egress_runtime() { return 1; }
gen_bypasscore_config || exit 1
''')
        config = json.loads((self.state / 'config.json').read_text())
        self.assertEqual([r['ruleTag'] for r in config['routing']['rules']], ['active'])
        self.assertEqual([r['tag'] for r in config['outbounds']], ['direct', 'block'])

    def test_ipv4_label_in_hostname_and_bracketed_ipv6(self):
        output = self.run_shell('''
resolveip() { [ "$1" = -4 ] && echo 198.51.100.7 || echo 2001:db8::7; }
resolve_all_ipv4 edge-1.2.3.4.example.com
resolve_all_ipv6 '[2001:db8::8]'
resolve_all_ipv4 '[2001:db8::8]'
resolve_all_ipv6 192.0.2.8
''')
        self.assertEqual(output.splitlines(), ['198.51.100.7', '2001:db8::8'])

    def test_geo_asset_path_with_and_without_trailing_slash(self):
        assets = self.root / 'assets'
        assets.mkdir()
        (assets / 'geoip.dat').write_bytes(b'asset')
        for suffix in ['', '/']:
            output = self.run_shell(f'''
config_t_get() {{ echo {shlex.quote(str(assets) + suffix)}; }}
get_geo_asset_path geoip
''')
            self.assertEqual(output, str(assets / 'geoip.dat'))

    def test_dnsmasq_include_stays_in_configured_directory(self):
        config_dir = self.root / 'dnsmasq.d'
        config_dir.mkdir()
        generated = self.root / 'dnsmasq.conf'
        generated.write_text(f'conf-dir={config_dir}\n')
        # Redirect the one service invocation in this library copy to a stub.
        prelude = self.prelude.replace('/etc/init.d/dnsmasq restart', 'true')
        self.run_shell(f'''
check_port_exists() {{ echo 1; }}
DNS_REDIRECT=1 BYPASSCORE_DNS_PORT=10554
uci() {{ echo 'dhcp.cfg1=dnsmasq'; }}
dnsmasq_generated_config() {{ echo {shlex.quote(str(generated))}; }}
first_type() {{ :; }}
run_dnsmasq_forward || exit 1
''', prelude=prelude)
        self.assertTrue((config_dir / 'dnsmasq-bypass.conf').exists())
        self.assertFalse((self.root / 'dnsmasq-bypass.conf').exists())

    def test_log_rotation_keeps_open_writer_visible(self):
        self.run_shell('''
exec 5>>"$LOG_FILE"
printf 1234567890 >&5
bound_log_file "$LOG_FILE" 8 4
printf AFTER >&5
exec 5>&-
''')
        self.assertEqual((self.state / 'log').read_text(), '7890AFTER')

    def test_daily_loop_schedule(self):
        self.assertEqual(self.run_shell('cron_prefix 8 0:00 24'), '0 0 * * *')
        self.assertEqual(self.run_shell('cron_prefix 8 0:00 25 >/dev/null; [ "$?" = 1 ]'), '')

    def test_scheduled_start_survives_stop(self):
        cron = self.root / 'crontab'
        cron.write_text('0 * * * * unrelated-command\n')
        prelude = self.prelude.replace('/etc/crontabs/root', str(cron)).replace('/etc/init.d/cron restart', 'true')
        self.run_shell('''
remove_owned_crontab_entries() { : > ''' + shlex.quote(str(cron)) + '''; }
config_t_get() {
 case "$1.$2" in global.enabled) echo 1 ;; global_delay.start_week_mode) echo 7 ;;
 global_delay.start_time_mode) echo 8:00 ;; *) echo "$3" ;; esac
}
stop_crontab
''', prelude=prelude)
        self.assertIn('/etc/init.d/bypass start', cron.read_text())
        self.assertNotIn('rule_update.sh', cron.read_text())

    def test_readonly_probes_do_not_rewrite_runtime_mapping(self):
        originals = {'selected_nodes': 'live\n', 'selected_wireguard_nodes': 'live\n', 'node_ports': 'naive_live 1088\n'}
        for name, data in originals.items():
            (self.state / name).write_text(data)
        self.run_shell('''
get_config() { DEFAULT_NODE=live; }
config_get_type() { echo nodes; }
config_n_get() { [ "$2" = node_type ] && echo wireguard || echo "$3"; }
do_node_udp_probe live >/dev/null
do_node_urltest live https://cp.cloudflare.com/ >/dev/null
do_connect_status google https://www.google.com/generate_204 >/dev/null
''')
        for name, data in originals.items():
            self.assertEqual((self.state / name).read_text(), data)

    def test_probe_rejects_http_success_with_unready_body(self):
        self.run_shell('''
bypasscore_control_request() { echo '{"ready":false,"error":{"message":"invalid sets"}}'; }
bypasscore_nftsets_ready; [ "$?" = 1 ] || exit 1
bypasscore_control_request() { echo '{"ready":true}'; }
bypasscore_nftsets_ready || exit 1
''')

    def test_multiline_interface_selection(self):
        hotplug = (REPO / 'root/etc/hotplug.d/iface/98-bypass').read_text()
        funcs = hotplug[hotplug.index('is_managed_iface() {'):hotplug.index('\nschedule_iface_restart()')]
        self.run_shell(funcs + '''
node_egress_ifaces='wan1
wan2
wan3'
rule_direct_ifaces='direct1
direct2'
direct_iface=wan
for INTERFACE in wan1 wan2 wan3 direct1 direct2; do is_managed_iface || exit 1; done
INTERFACE=direct1; is_direct_iface || exit 1
INTERFACE=wan20; is_managed_iface; [ "$?" = 1 ]
''')

    def test_detached_restart_uses_its_own_readiness_path(self):
        monitor = (RUNTIME / 'monitor.sh').read_text()
        worker = monitor.split("restart_script='", 1)[1].split("\n\t'", 1)[0]
        worker = worker.replace('. /usr/share/bypass/utils.sh', '').replace('/var/lock/bypass_ready.lock', str(self.root / 'ready'))
        worker = worker.replace('/etc/init.d/bypass restart', 'fake_restart').replace('/etc/init.d/bypass status', 'true')
        (self.root / 'ready').touch()
        marker = self.root / 'marker'
        self.run_shell(f'''
unset READY_FILE
apk_transaction_active() {{ return 1; }}
config_t_get() {{ echo 1; }}
sleep() {{ :; }}
fake_restart() {{ echo restarted >> "$TMP_PATH/restarts"; }}
set -- {shlex.quote(str(marker))} test
{worker}
''')
        self.assertEqual((self.state / 'restarts').read_text(), 'restarted\n')

    def test_boot_delay_can_be_cancelled(self):
        service = source('service.init')
        self.run_shell('extra_command() { :; }\n' + service + '''
BOOTING_FILE="$TMP_PATH/booting"
touch "$BOOTING_FILE"
uci() { echo 60; }
sleep() { rm -f "$BOOTING_FILE"; }
restart() { echo restarted >> "$TMP_PATH/restarts"; }
boot_func
[ ! -f "$TMP_PATH/restarts" ]
''')

    def test_apk_restart_waits_for_transaction_release(self):
        output = self.run_shell(r'''
checks=0
apk_transaction_active() {
    checks=$((checks + 1))
    [ "$checks" -le 2 ]
}
log() { echo "log:$*"; }
sleep() { echo "sleep:$1"; }
wait_for_apk_transaction
echo "checks=$checks"
''')
        self.assertEqual(output.splitlines(), [
            'log:0 Waiting for the APK package transaction to finish before restarting Bypass.',
            'sleep:2', 'sleep:2', 'checks=3'
        ])

    def test_queued_automatic_restarts_respect_stop_after_lock(self):
        service = source('service.init')
        runner = self.root / 'app-runner'
        runner.write_text('#!/bin/sh\necho "$1" >> "$TMP_PATH/operations"\n')
        runner.chmod(0o700)
        self.run_shell('extra_command() { :; }\n' + service + f'''
export TMP_PATH
APP_FILE={shlex.quote(str(runner))}
BOOTING_FILE="$TMP_PATH/booting"
STOPPED_FILE="$TMP_PATH/stopped"
READY_FILE="$TMP_PATH/ready"
uci() {{ echo 1; }}
unset_lock() {{ :; }}
# Model a manual stop completing while the automatic job waits for the lock.
set_lock() {{ rm -f "$BOOTING_FILE"; touch "$STOPPED_FILE"; }}
touch "$BOOTING_FILE"
restart boot || exit 1
restart recovery || exit 1
[ ! -f "$TMP_PATH/operations" ] || exit 1
[ -f "$STOPPED_FILE" ] || exit 1
# An explicit start is allowed and clears the marker after locking.
update_ready_file() {{ :; }}
start || exit 1
[ ! -f "$STOPPED_FILE" ] || exit 1
[ "$(cat "$TMP_PATH/operations")" = start ]
''')

    def test_upload_chunks_reject_replay_and_deliver_complete_data(self):
        # Host flock need not be installed: deterministic tests don't contend.
        data = base64.b64encode(b'backup' * 4000).decode()
        output = self.run_shell(f'''
flock() {{ return 0; }}
do_restore_backup() {{ printf '%s' "$1" > "$TMP_PATH/restored"; json_init; json_add_int code 0; emit; }}
do_upload backup new 0 {shlex.quote(data[:16384])} 0
''')
        token = json.loads(output)['token']
        result = json.loads(self.run_shell(f'''
flock() {{ return 0; }}
do_upload backup {token} 0 QQ== 0
'''))
        self.assertNotEqual(result['code'], 0)
        result = json.loads(self.run_shell(f'''
flock() {{ return 0; }}
do_restore_backup() {{ printf '%s' "$1" > "$TMP_PATH/restored"; json_init; json_add_int code 0; emit; }}
do_upload backup {token} 16384 {shlex.quote(data[16384:])} 1
'''))
        self.assertEqual(result['code'], 0)
        self.assertEqual((self.state / 'restored').read_text(), data)
        self.assertFalse((self.state / 'backup-upload' / token).exists())

    def test_upload_rejects_traversal_and_oversize(self):
        for body in ["do_upload backup ../../x 0 QQ== 0", "do_upload direct-ip new 262145 QQ== 0", "do_upload backup new 0 'bad!' 0"]:
            self.assertNotEqual(json.loads(self.run_shell(body))['code'], 0)

    def test_stream_preserves_chunk_newlines(self):
        directory = self.state / 'geo-view/result.abcdef'
        directory.mkdir(parents=True)
        data = 'x' * 16383 + '\n' + 'last\n'
        (directory / 'output').write_text(data)
        first = json.loads(self.run_shell('geo_view_read result.abcdef 0'))
        last = json.loads(self.run_shell('geo_view_read result.abcdef 16384'))
        self.assertEqual(first['output'] + last['output'], data)
        self.assertEqual(last['done'], 1)
        self.assertFalse(directory.exists())

    def test_geodata_rollback_holds_lock_and_invalidates_cache(self):
        updates = source('rule_update.sh').replace('/etc/init.d/bypass restart', 'fake_restart')
        self.run_shell(updates + r'''
BAK_DIR="$TMP_PATH/bak"
asset_dir="$TMP_PATH/assets"
mkdir -p "$asset_dir" "$TMP_PATH2/geo_output"
echo old > "$asset_dir/geoip.dat"
echo stale > "$TMP_PATH2/geo_output/cn"
config_t_get() {
 case "$1.$2" in global_rules.v2ray_location_asset) echo "$asset_dir/" ;;
 global.enabled) echo 1 ;; global_rules.geosite_update) echo 0 ;; *) echo "$3" ;; esac
}
set_lock() { locked=1; }
unset_lock() { locked=0; }
download_one() {
 cp "$3" "$UPDATE_ROLLBACK_DIR/$1"
 echo new > "$3"
 GEODATA_CHANGED=" $1"
}
tries=0
fake_restart() {
 [ "$locked" = 1 ] || exit 99
 [ ! -d "$TMP_PATH2/geo_output" ] || exit 98
 tries=$((tries + 1))
 [ "$tries" != 1 ]
}
update_geodata
[ "$?" = 1 ] || exit 1
[ "$(cat "$asset_dir/geoip.dat")" = old ]
''')

    def test_wireguard_firewall_keeps_dhcp_broadcast_direct(self):
        nft = source('nftables.sh').split('# Dispatch.')[0]
        self.run_shell(nft + r'''
INCLUDE_FILE="$TMP_PATH/include"
NFT=nft_fake
nft_fake() { return 0; }
REDIR_PORT=1041 TCP_PROXY_WAY=tproxy TCP_REDIR_PORTS=1:65535
TCP_NO_REDIR_PORTS=disable UDP_NO_REDIR_PORTS=disable
CLIENT_PROXY=1 PROXY_IPV6=1 DNS_REDIRECT=1 ENABLE_GEOVIEW_IP=0
ACCEPT_ICMP=0
mkdir -p "$TMP_PATH2"
echo wg > "$TMP_PATH/selected_wireguard_nodes"
: > "$TMP_PATH/selected_nodes"
nft_apply() { printf '%s' "$1" > "$TMP_PATH/generated.nft"; }
nft_gen_include() { return 0; }
ip() { return 0; }
network_flush_cache() { :; }
network_get_device() { :; }
get_wan_ips() { :; }
get_direct_dns_ipv4() { echo 223.5.5.5; }
nft_start || exit 1
''')
        rules = (self.state / 'generated.nft').read_text()
        self.assertIn('255.255.255.255 udp sport 68 udp dport 67 accept', rules)
        self.assertIn('meta nfproto != ipv4 accept', rules)
        self.assertIn('meta nfproto != ipv6 accept', rules)

    def test_restore_archive_rejects_links_and_extra_members(self):
        for link in [True, False]:
            payload = io.BytesIO()
            with tarfile.open(fileobj=payload, mode='w:gz') as archive:
                member = tarfile.TarInfo('etc/config/bypass')
                if link:
                    member.type = tarfile.SYMTYPE
                    member.linkname = '/tmp/other'
                    archive.addfile(member)
                else:
                    content = b"config global\n"
                    member.size = len(content)
                    archive.addfile(member, io.BytesIO(content))
                    extra = tarfile.TarInfo('../../unexpected')
                    archive.addfile(extra)
            encoded = base64.b64encode(payload.getvalue()).decode()
            result = json.loads(self.run_shell('do_restore_backup ' + shlex.quote(encoded)))
            self.assertNotEqual(result['code'], 0)

    def test_frontend_chunk_transfers_and_error_propagation(self):
        node = shutil.which('node')
        if not node:
            self.skipTest('Node.js is needed for frontend behavior tests')
        script = r'''
const fs = require('fs');
const assert = require('assert');
const _ = s => s;
const view = { extend: value => value };
const calls = [];
const fakeFs = {exec: async (_path, args) => {
    calls.push(args);
    if (args[0] === 'geo_view') {
        const offset = +args[3];
        return {stdout: JSON.stringify({code:0, output: encoded.slice(offset,offset+16384),
            next_offset: Math.min(offset+16384, encoded.length), done: +(offset+16384>=encoded.length)})};
    }
    return {stdout: JSON.stringify({code:0, token:'result.abcdef', next_offset:+args[2]+args[3].length})};
}};
(async () => {
    const text = '# 中文注释\n' + '1.2.3.4\n'.repeat(5000);
    global.encoded = Buffer.from(text).toString('base64');
    const otherText = fs.readFileSync(process.argv[2], 'utf8');
    const basicText = fs.readFileSync(process.argv[1], 'utf8');
    const other = new Function('view','fs','_',otherText.replace('return view.extend(', 'view.extend(')
        + ';return {uploadDirectIp,readDirectIp};')(view,fakeFs,_);
    const basic = new Function('view','fs','_',basicText.replace('return view.extend(', 'view.extend(')
        + ';return {uploadBackup,readBackup};')(view,fakeFs,_);
    await other.uploadDirectIp(encoded);
    assert(calls.length > 1);
    assert(calls.every(args => args[3].length <= 16384));
    calls.length=0;
    const loaded = await other.readDirectIp({code:0,direct_ip_stream:'result.abcdef'});
    assert.strictEqual(loaded.direct_ip,text);
    await basic.uploadBackup(encoded);
    const downloaded = await basic.readBackup({backup_stream:'result.abcdef'});
    assert.strictEqual(downloaded,encoded);
    fakeFs.exec = async () => ({stdout: JSON.stringify({code:-1,error:'failed'})});
    assert.strictEqual((await basic.uploadBackup(encoded)).code,-1);
    await assert.rejects(other.uploadDirectIp(encoded));
})().catch(e => {console.error(e);process.exitCode=1;});
'''
        paths = [REPO / 'htdocs/luci-static/resources/view/bypass' / f for f in ['basic_settings.js', 'other_settings.js']]
        result = subprocess.run([node, '-e', script, *map(str, paths)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_config_accepts_auto_dns_and_normalizes_decimal_bases(self):
        output = self.run_shell(r'''
get_direct_dns_ipv4() { echo 192.0.2.53; }
config_t_get() {
 case "$1.$2" in global.node_socks_port) echo 01088 ;;
 global.naive_egress_table) echo 00100 ;; global.naive_egress_rule_priority) echo 00900 ;;
 *) echo "$3" ;; esac
}
get_config || exit 1
printf '%s %s %s %s' "$DOMESTIC_DNS" "$NODE_SOCKS_PORT" "$NAIVE_EGRESS_TABLE" "$NAIVE_EGRESS_RULE_PRIORITY"
''')
        self.assertEqual(output, '192.0.2.53 1088 100 900')

    def test_log_rpc_response_is_bounded(self):
        (self.state / 'log').write_text('中文日志' * 20000)
        result = json.loads(self.run_shell('do_log_tail 1000'))
        self.assertLessEqual(len(result['log_base64']), 16384)
        self.assertLessEqual(len(base64.b64decode(result['log_base64'])), 12288)

    def test_clear_log_polling_is_empty_and_writer_can_resume(self):
        responses = self.run_shell(r'''
do_log_tail 20
exec 5>>"$LOG_FILE"
printf 'old message\n' >&5
do_clear_log
do_log_tail 20
do_log_tail 20
printf 'new message\n' >&5
do_log_tail 20
exec 5>&-
''').splitlines()
        missing, cleared, empty, polled, resumed = map(json.loads, responses)
        self.assertEqual(missing, {'log': ''})
        self.assertEqual(cleared, {'code': 0})
        self.assertEqual(empty, {'log': ''})
        self.assertEqual(polled, {'log': ''})
        self.assertEqual(base64.b64decode(resumed['log_base64']), b'new message')

    def test_log_rpc_falls_back_when_base64_is_missing(self):
        (self.state / 'log').write_text('diagnostic line\n')
        result = json.loads(self.run_shell('''
tail_bin=$(command -v tail)
tr_bin=$(command -v tr)
mkdir -p "$TMP_PATH/tools"
ln -s "$tail_bin" "$TMP_PATH/tools/tail"
ln -s "$tr_bin" "$TMP_PATH/tools/tr"
PATH="$TMP_PATH/tools"
do_log_tail 20
'''))
        self.assertEqual(result['log'], 'diagnostic line')
        self.assertNotIn('log_base64', result)
        self.assertIn('coreutils-base64', result['error'])

    def test_monitor_recovers_live_naive_with_missing_listener(self):
        monitor = (RUNTIME / 'monitor.sh').read_text()
        loop = monitor[monitor.index('last_failed=""'):]
        output = self.run_shell(r'''
READY_FILE="$TMP_PATH/ready"
touch "$READY_FILE"
echo 'naive_live 1088' > "$TMP_PATH/node_ports"
config_t_get() { echo 1; }
runtime_images_current() { return 0; }
runtime_binary_snapshot() { echo same; }
binary_baseline=same
bypasscore_ready() { return 0; }
process_alive() { return 0; }
check_port_exists() { echo 0; }
schedule_full_restart() { echo recovered; exit 0; }
ticks=0
sleep() { ticks=$((ticks + 1)); [ "$ticks" -le 4 ] || exit 10; }
''' + loop)
        self.assertEqual(output, 'recovered')

    def test_detached_restart_retries_after_failure(self):
        monitor = (RUNTIME / 'monitor.sh').read_text()
        worker = monitor.split("restart_script='", 1)[1].split("\n\t'", 1)[0]
        worker = worker.replace('. /usr/share/bypass/utils.sh', '').replace('/var/lock/bypass_ready.lock', str(self.root / 'ready'))
        worker = worker.replace('/var/lock/bypass_stopped.lock', str(self.root / 'stopped'))
        worker = worker.replace('/etc/init.d/bypass restart', 'fake_restart').replace('/etc/init.d/bypass status', 'true')
        (self.root / 'ready').touch()
        self.run_shell(r'''
apk_transaction_active() { return 1; }
config_t_get() { echo 1; }
sleep() { :; }
attempts=0
fake_restart() {
 attempts=$((attempts + 1))
 echo "$attempts" >> "$TMP_PATH/restarts"
 [ "$attempts" -gt 1 ]
}
set -- "$TMP_PATH/marker" test
''' + worker)
        self.assertEqual((self.state / 'restarts').read_text().splitlines(), ['1', '2'])

    def test_parallel_cache_writes_keep_every_key(self):
        output = self.run_shell(r'''
for key in 1 2 3 4 5 6 7 8 9 10; do
 set_cache_var "KEY_$key" "value $key" &
done
wait
for key in 1 2 3 4 5 6 7 8 9 10; do
 [ "$(get_cache_var "KEY_$key")" = "value $key" ] || exit 1
done
unset_cache_var KEY_5
[ -z "$(get_cache_var KEY_5)" ] || exit 1
[ "$(get_cache_var KEY_6)" = 'value 6' ] || exit 1
wc -l < "$TMP_PATH/var"
''')
        self.assertEqual(output.strip(), '9')

    def test_managed_children_do_not_inherit_operation_lock_fds(self):
        probe = self.root / 'fd-probe.sh'
        probe.write_text('#!/bin/sh\nfor fd in 5 6 7 8 9; do\n if ( : <&"$fd" ) 2>/dev/null; then echo "$fd"; fi\ndone\necho closed\n')
        probe.chmod(0o700)
        output = self.run_shell(r'''
exec 5>/dev/null 6>/dev/null 7>/dev/null 8>/dev/null 9>/dev/null
''' + 'ln_run 0 ' + shlex.quote(str(probe)) + r''' probe "$TMP_PATH/probe.log" || :
wait "$(cat "$TMP_PID_PATH/probe.pid")"
cat "$TMP_PATH/probe.log"
''')
        self.assertEqual(output, 'closed')

    def test_all_shell_javascript_and_json_syntax(self):
        for path in (REPO / 'root').rglob('*'):
            if path.is_file() and path.read_bytes().startswith(b'#!/bin/sh'):
                subprocess.run([SHELL, '-n', str(path)], check=True, capture_output=True)
            if path.suffix == '.json':
                json.loads(path.read_text())
        node = shutil.which('node')
        if node:
            for path in (REPO / 'htdocs').rglob('*.js'):
                # LuCI evaluates modules in a function wrapper; top-level return is valid.
                subprocess.run([node, '-e', "new Function(require('fs').readFileSync(process.argv[1], 'utf8'));", str(path)], check=True, capture_output=True)


if __name__ == '__main__':
    unittest.main()
