#!/usr/bin/env ucode
// luci-app-trusted - managed session back end.
//
// Called by the CGI wrapper (/www/cgi-bin/luci) when a whitelisted client has
// no session yet or its cached one expired.  Prints a fresh rpcd session id
// that carries the same grants a "root" password login would produce.
//
// The whitelist is re-checked here against /etc/config/trusted rather than
// trusting the caller: this script is the only place that mints a privileged
// session, so it must not rely on an earlier decision.

'use strict';

import { readfile, glob } from 'fs';
import { connect } from 'ubus';
import { cursor } from 'uci';

const TRUSTED_CONFIG = '/etc/config/trusted';
const ACL_DIRS = [ '/usr/share/rpcd/acl.d', '/usr/share/acl.d' ];
const DEFAULT_SESSION_TIMEOUT = 3600;

function fail(msg) {
	if (length(msg))
		warn(sprintf('trusted: %s\n', msg));

	exit(1);
}

// ---------------------------------------------------------------- config ---

function trusted_config() {
	let c = cursor();
	c.load('trusted');

	let s = c.get_all('trusted', 'global') ?? {};
	let entries = s.ipaddr;

	if (type(entries) == 'string')
		entries = [ entries ];
	else if (type(entries) != 'array')
		entries = [];

	return { enabled: (s.enabled == '1'), entries: entries };
}

// ------------------------------------------------------------- IP matching ---

function ip_to_int(ip) {
	let m = match(ip, /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/);

	if (!m)
		return null;

	let a = [ +m[1], +m[2], +m[3], +m[4] ];

	for (let o in a)
		if (o > 255)
			return null;

	return a[0] * 16777216 + a[1] * 65536 + a[2] * 256 + a[3];
}

function entry_matches(ip, entry) {
	entry = trim(entry);

	if (!length(entry))
		return false;

	let i = ip_to_int(ip);

	if (i == null)
		return false;

	let parts = split(entry, '/');
	let net = ip_to_int(trim(parts[0]));

	if (net == null)
		return false;

	let bits = 32;

	if (length(parts) > 1) {
		bits = +trim(parts[1]);

		// A non-numeric or out-of-range prefix must not silently degrade to
		// a /32 (which would trust a single, possibly wrong address).
		if (!(bits >= 0) || bits > 32)
			return false;
	}

	let block = 1;

	for (let b = 0; b < 32 - bits; b++)
		block = block * 2;

	return (i - (i % block)) == (net - (net % block));
}

function ip_trusted(ip) {
	if (ip == null || !length(ip))
		return false;

	if (ip == '127.0.0.1' || ip == '::1')
		return true;

	let cfg = trusted_config();

	if (!cfg.enabled)
		return false;

	for (let e in cfg.entries)
		if (entry_matches(ip, e))
			return true;

	return false;
}

// --------------------------------------------------------------- sessions ---

// Every ACL group declared by an installed package.  Granting read+write on
// all of them makes the session equivalent to a full admin login.
function acl_groups() {
	let groups = [];

	for (let dir in ACL_DIRS) {
		for (let f in glob(dir + '/*.json')) {
			try {
				let data = json(readfile(f));

				if (type(data) != 'object')
					continue;

				for (let name, spec in data) {
					if (type(spec) != 'object')
						continue;

					if (type(spec.read) == 'object' || type(spec.write) == 'object')
						push(groups, name);
				}
			}
			catch (e) {}
		}
	}

	return groups;
}

function session_timeout() {
	try {
		let c = cursor();
		c.load('luci');

		return +c.get('luci', 'sauth', 'sessiontime') || DEFAULT_SESSION_TIMEOUT;
	}
	catch (e) {
		return DEFAULT_SESSION_TIMEOUT;
	}
}

function randomid(num_bytes) {
	try {
		let f = require('fs').open('/dev/urandom', 'r');
		let data = f.read(num_bytes);
		f.close();

		if (data == null || length(data) != num_bytes)
			return null;

		return hexenc(data);
	}
	catch (e) {
		return null;
	}
}

function create_session(u) {
	let timeout = session_timeout();

	if (timeout <= 0)
		timeout = DEFAULT_SESSION_TIMEOUT;

	let sid = u.call('session', 'create', { timeout: timeout })?.ubus_rpc_session;

	if (type(sid) != 'string' || !length(sid))
		return null;

	let token = randomid(16);

	if (token == null)
		return null;

	u.call('session', 'set', {
		ubus_rpc_session: sid,
		values: { token: token, username: 'root' }
	});

	let objs = [];

	for (let g in acl_groups()) {
		push(objs, [ g, 'read' ]);
		push(objs, [ g, 'write' ]);
	}

	u.call('session', 'grant', { ubus_rpc_session: sid, scope: 'access-group', objects: objs });
	u.call('session', 'grant', { ubus_rpc_session: sid, scope: 'ubus', objects: [ [ '*', '*' ] ] });
	u.call('session', 'grant', { ubus_rpc_session: sid, scope: 'uci', objects: [ [ '*', '*' ] ] });
	u.call('session', 'grant', { ubus_rpc_session: sid, scope: 'file', objects: [ [ '*', '*' ] ] });

	return sid;
}

// -------------------------------------------------------------------- main ---

let ip = getenv('TRUSTED_IP') ?? getenv('REMOTE_ADDR') ?? '';

if (!ip_trusted(ip))
	fail(sprintf('refusing to mint a session for %s', ip));

let u = connect();

if (u == null)
	fail('cannot connect to ubus');

let sid = create_session(u);

if (sid == null)
	fail('cannot create session');

print(sid);
