'use strict';

import { popen } from 'fs';
import { cursor } from 'uci';

const SSH_TIMEOUT = '5';

function str(v) {
	if (v == null)
		return '';

	return '' + v;
}

function shellquote(s) {
	return "'" + replace(str(s), "'", "'\\''") + "'";
}

function get_cursor() {
	const confdir = getenv('SERVERCTL_CONFDIR');
	const deltadir = getenv('SERVERCTL_DELTADIR');

	if (confdir != null)
		return deltadir == null ? cursor(confdir) : cursor(confdir, deltadir);

	return cursor();
}

function run(argv) {
	const fd = popen(join(' ', map(argv, shellquote)) + ' 2>&1');

	if (fd == null)
		return { code: -1, output: 'serverctl: failed to spawn command\n' };

	const out = fd.read('all');

	return { code: fd.close(), output: (out == null) ? '' : out };
}

function ssh_argv(server, cmd) {
	let user = server['user'];
	let pass = server['password'];
	let port = str(server['ssh_port']);

	if (str(user) == '')
		user = 'root';

	if (pass == null)
		pass = '';

	let host = str(server['ip']);

	/* IPv6 地址须以方括号包裹方能被 ssh 正确解析。
	 * index() 未命中时旧版 ucode 返回 null、新版(2025-07 后)返回 -1，两种语义都兼容 */
	const colon = index(host, ':');

	if (colon != null && colon >= 0)
		host = '[' + host + ']';

	let argv = ['sshpass', '-p', str(pass), 'ssh',
		'-o', 'StrictHostKeyChecking=no',
		'-o', 'UserKnownHostsFile=/dev/null',
		'-o', 'ConnectTimeout=' + SSH_TIMEOUT];

	/* 非标准 SSH 端口：条目设置了 ssh_port 才附加 -p，缺省/置空沿用 ssh 默认(22)，
	 * 保证未配置端口的旧条目命令行一字不变 */
	if (port != '')
		push(argv, '-p', port);

	push(argv, sprintf('%s@%s', str(user), host));
	push(argv, cmd);

	return argv;
}

function is_windows(s) {
	return str(s['os_type']) == 'windows';
}

function find_server(name) {
	const ctx = get_cursor();
	const all = ctx.get_all('serverctl');

	if (all == null)
		return null;

	for (let sid in all) {
		const s = all[sid];

		if (s['.type'] != 'server')
			continue;

		if (str(name) != '' && (str(s['name']) == str(name) || sid == name))
			return s;
	}

	return null;
}

const actions = {
	ping: function(s) {
		return run(['ping', '-c', '3', '-W', '2', str(s['ip'])]);
	},

	sshtest: function(s) {
		return run(ssh_argv(s, 'echo serverctl: ssh login ok'));
	},

	wake: function(s) {
		if (str(s['mac']) == '')
			return { code: 1, output: 'serverctl: mac address missing\n' };

		/* WOL via etherwake (Layer-2 magic packet, no perl). wol_interface selects
		 * the interface the magic packet is sent out of; missing/empty -> 'eth0'.
		 * Note: libuci treats an empty value as a deleted option (uci_set('')
		 * calls uci_delete), so "explicitly empty" is indistinguishable from
		 * "absent" and both fall back to 'eth0'. */
		const ctx = get_cursor();
		ctx.load('serverctl');

		let raw = ctx.get('serverctl', 'defaults', 'wol_interface');
		let iface = str(raw);

		if (iface == '')
			iface = 'eth0';

		return run(['etherwake', '-i', iface, str(s['mac'])]);
	},

	suspend: function(s) {
		/* Windows: rundll32 SetSuspendState(0,1,0) requests sleep (S3/S0ix).
		 * Caveat: with hibernation enabled (powercfg /h on) Windows falls
		 * back to hibernation; see README for details. */
		if (is_windows(s))
			return run(ssh_argv(s, 'rundll32.exe powrprof.dll,SetSuspendState 0,1,0'));

		/* --ignore-inhibitors: remote apps (package managers, nfsd, etc.) may
		 * hold logind block inhibitor locks; an explicit user action wins. */
		return run(ssh_argv(s, 'systemctl suspend --ignore-inhibitors'));
	},

	poweroff: function(s) {
		if (is_windows(s))
			return run(ssh_argv(s, 'shutdown /s /t 0'));

		return run(ssh_argv(s, 'systemctl poweroff'));
	},
};

function execute(action, name) {
	const impl = actions[action];

	if (impl == null)
		return { code: 1, output: sprintf('serverctl: unknown action %s\n', str(action)) };

	/* 空名会字符串匹配到缺失 name 字段的条目，须先行拒绝 */
	if (str(name) == '')
		return { code: 1, output: 'serverctl: server name must not be empty\n' };

	const s = find_server(name);

	if (s == null)
		return { code: 1, output: sprintf('serverctl: server not found: %s\n', str(name)) };

	return impl(s);
}

export default { execute, find_server, get_cursor, str };
