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

	if (str(user) == '')
		user = 'root';

	if (pass == null)
		pass = '';

	return ['sshpass', '-p', str(pass), 'ssh',
		'-o', 'StrictHostKeyChecking=no',
		'-o', 'UserKnownHostsFile=/dev/null',
		'-o', 'ConnectTimeout=' + SSH_TIMEOUT,
		sprintf('%s@%s', str(user), str(server['ip'])),
		cmd];
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

		if (str(s['name']) == str(name) || sid == name)
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

		/* WOL via etherwake (Layer-2 magic packet, no perl). etherwake defaults to
		 * eth0, which on most routers is the WAN port, so the packet must be sent
		 * out the LAN bridge instead. wol_interface selects it: option absent ->
		 * 'br-lan'; option set to an empty string -> fall back to bare etherwake. */
		const ctx = get_cursor();
		ctx.load('serverctl');

		let raw = ctx.get('serverctl', 'defaults', 'wol_interface');
		let iface = (raw == null) ? 'br-lan' : str(raw);
		let argv = (iface != '') ? [ 'etherwake', '-i', iface ] : [ 'etherwake' ];

		push(argv, str(s['mac']));

		return run(argv);
	},

	suspend: function(s) {
		return run(ssh_argv(s, 'systemctl suspend'));
	},

	poweroff: function(s) {
		return run(ssh_argv(s, 'systemctl poweroff'));
	},
};

function execute(action, name) {
	const s = find_server(name);
	const impl = actions[action];

	if (impl == null)
		return { code: 1, output: sprintf('serverctl: unknown action %s\n', str(action)) };

	if (s == null)
		return { code: 1, output: sprintf('serverctl: server not found: %s\n', str(name)) };

	return impl(s);
}

export default { execute, find_server, get_cursor, str };
