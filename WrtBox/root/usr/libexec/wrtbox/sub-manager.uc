#!/usr/bin/ucode
'use strict';

let fs = require('fs');
let uci = require('uci');

const PROFILES_DIR = '/etc/wrtbox/profiles';
const ACTIVE_CONF = '/etc/wrtbox/active.json';
const BACKUP_CONF = '/etc/wrtbox/active.json.bak';
const TASK_LOG = '/tmp/log/wrtbox-tasks.log';

function shellQuote(s) {
	return "'" + replace(s || '', "'", "'\\''") + "'";
}

function logTask(msg) {
	system(['mkdir', '-p', '/tmp/log']);
	let st = fs.stat(TASK_LOG);
	if (st && st.size > 524288) {
		system(['/bin/sh', '-c', 'tail -n 300 ' + shellQuote(TASK_LOG) + ' > ' + shellQuote(TASK_LOG + '.tmp') + ' && mv -f ' + shellQuote(TASK_LOG + '.tmp') + ' ' + shellQuote(TASK_LOG)]);
	}
	let p = fs.popen('date "+%Y-%m-%d %H:%M:%S"', 'r');
	let now = p ? trim(p.read('all')) : '';
	if (p) p.close();
	let fp = fs.open(TASK_LOG, 'a');
	if (fp) {
		fp.write(sprintf('[%s] [sub] %s\n', now, msg));
		fp.close();
	}
}

function validId(id) {
	return type(id) == 'string' && match(id, /^[a-zA-Z0-9_-]{1,64}$/) != null;
}

function getMainOption(cursor, key, def) {
	let v = cursor.get('wrtbox', 'main', key);
	return (v !== null && v !== '') ? v : def;
}

function stripJsonComments(str) {
	if (type(str) != 'string') return '';
	let out = [];
	let i = 0;
	let n = length(str);
	let inStr = false;
	let esc = false;

	while (i < n) {
		let ch = substr(str, i, 1);
		let next = (i + 1 < n) ? substr(str, i + 1, 1) : '';
		if (inStr) {
			push(out, ch);
			if (esc) {
				esc = false;
			} else if (ch == '\\') {
				esc = true;
			} else if (ch == '"') {
				inStr = false;
			}
			i++;
		} else {
			if (ch == '"') {
				inStr = true;
				push(out, ch);
				i++;
			} else if (ch == '/' && next == '/') {
				i += 2;
				while (i < n && substr(str, i, 1) != '\n') i++;
			} else if (ch == '/' && next == '*') {
				i += 2;
				while (i + 1 < n && !(substr(str, i, 1) == '*' && substr(str, i + 1, 1) == '/')) i++;
				i += 2;
			} else {
				push(out, ch);
				i++;
			}
		}
	}
	return join('', out);
}

function parseJsonFlexible(raw) {
	try {
		return json(raw);
	} catch (e) {
		return json(stripJsonComments(raw));
	}
}

function inspectConfigObj(cfg) {
	let modes = [];
	let tunIfaces = [];
	let clashHost = '';
	let clashPort = null;
	let clashSecret = '';
	let clashUi = '';
	let apiHost = '';
	let apiPort = null;
	let apiSecret = '';
	let apiDashboard = false;
	let ruleSets = 0;
	let outboundsCount = 0;

	if (type(cfg) != 'object') {
		return {
			modes: [],
			tun_interfaces: [],
			clash_host: '',
			clash_port: null,
			clash_secret: '',
			clash_ui: '',
			api_host: '',
			api_port: null,
			api_secret: '',
			api_dashboard: false,
			rule_sets: 0,
			outbounds: 0
		};
	}

	if (type(cfg.inbounds) == 'array') {
		for (let ib in cfg.inbounds) {
			if (type(ib) != 'object') continue;
			let t = ib.type || 'unknown';
			let desc = t;
			if (t == 'tun') {
				let iface = ib.interface_name || 'tun0';
				push(tunIfaces, iface);
				desc = sprintf('tun (%s)', iface);
			} else if (ib.listen_port) {
				desc = sprintf('%s (:%d)', t, int(ib.listen_port));
			}
			if (index(modes, desc) < 0) push(modes, desc);
		}
	}

	if (type(cfg.outbounds) == 'array') {
		outboundsCount = length(cfg.outbounds);
	}

	if (type(cfg.route) == 'object' && type(cfg.route.rule_set) == 'array') {
		ruleSets = length(cfg.route.rule_set);
	}

	if (type(cfg.services) == 'array') {
		for (let srv in cfg.services) {
			if (type(srv) != 'object') continue;
			if (srv.type == 'api') {
				if (type(srv.listen) == 'string') apiHost = trim(srv.listen);
				apiPort = srv.listen_port ? int(srv.listen_port) : 9191;
				if (type(srv.secret) == 'string') apiSecret = srv.secret;
				if (type(srv.dashboard) == 'object') {
					apiDashboard = srv.dashboard.enabled !== false;
				}
				break;
			}
		}
	}

	if (type(cfg.experimental) == 'object' && type(cfg.experimental.clash_api) == 'object') {
		let ca = cfg.experimental.clash_api;
		if (type(ca.external_controller) == 'string' && ca.external_controller != '') {
			let ec = trim(ca.external_controller);
			ec = replace(ec, /^https?:\/\//, '');
			ec = replace(ec, /\/.*$/, '');
			let m = match(ec, /^(.*):(\d+)$/);
			if (m) {
				clashHost = trim(m[1]);
				clashPort = int(m[2]);
			} else if (match(ec, /^\d+$/)) {
				clashPort = int(ec);
			}
		}
		if (type(ca.secret) == 'string') clashSecret = ca.secret;
		if (type(ca.external_ui) == 'string') clashUi = ca.external_ui;
	}

	return {
		modes: modes,
		tun_interfaces: tunIfaces,
		clash_host: clashHost,
		clash_port: clashPort,
		clash_secret: clashSecret,
		clash_ui: clashUi,
		api_host: apiHost,
		api_port: apiPort,
		api_secret: apiSecret,
		api_dashboard: apiDashboard,
		rule_sets: ruleSets,
		outbounds: outboundsCount
	};
}

function checkWithCore(corePath, filePath) {
	let st = fs.stat(corePath);
	if (!st) {
		return { ok: true, skipped_core_check: true, note: 'Core binary not installed yet; JSON syntax verified only.' };
	}
	let cmd = shellQuote(corePath) + ' check -c ' + shellQuote(filePath) + ' 2>&1';
	let p = fs.popen(cmd, 'r');
	let out = p ? trim(p.read('all')) : '';
	let rc = p ? p.close() : 1;
	if (rc == 0) {
		return { ok: true, skipped_core_check: false };
	}
	return { ok: false, error: out != '' ? out : 'sing-box check failed' };
}

function prepareProfile(id) {
	if (!validId(id)) return { ok: false, error: 'Invalid profile ID' };
	let cursor = uci.cursor();
	let srcPath = sprintf('%s/%s.json', PROFILES_DIR, id);
	let raw = fs.readfile(srcPath);
	if (raw === null) {
		return { ok: false, error: 'Profile file not found: ' + srcPath };
	}

	let cfg;
	try {
		cfg = parseJsonFlexible(raw);
	} catch (e) {
		return { ok: false, error: 'Invalid JSON syntax: ' + e };
	}

	if (type(cfg) != 'object') {
		return { ok: false, error: 'Configuration root must be a JSON object' };
	}

	let summary = inspectConfigObj(cfg);
	let corePath = getMainOption(cursor, 'core_path', '/usr/libexec/wrtbox/sing-box');
	let candidate = '/tmp/wrtbox_candidate.json';
	let chk;

	if (!summary.api_port && !summary.clash_port) {
		let origRaw = sprintf('%.2J\n', cfg);
		if (type(cfg.services) != 'array') cfg.services = [];
		push(cfg.services, {
			type: 'api',
			tag: 'api-service',
			listen: '0.0.0.0',
			listen_port: 9191,
			dashboard: {
				enabled: true,
				path: 'ui',
				update_interval: '1d'
			}
		});
		fs.writefile(candidate, sprintf('%.2J\n', cfg));
		chk = checkWithCore(corePath, candidate);
		if (chk.ok) {
			summary = inspectConfigObj(cfg);
		} else {
			cfg = parseJsonFlexible(origRaw);
			fs.writefile(candidate, origRaw);
			chk = checkWithCore(corePath, candidate);
		}
	} else {
		fs.writefile(candidate, sprintf('%.2J\n', cfg));
		chk = checkWithCore(corePath, candidate);
	}

	if (!chk.ok) {
		fs.unlink(candidate);
		logTask(sprintf('Validation failed for profile "%s": %s', id, chk.error));
		return { ok: false, error: chk.error };
	}

	system(['mkdir', '-p', '/etc/wrtbox']);
	if (fs.stat(ACTIVE_CONF)) {
		system(['cp', '-f', ACTIVE_CONF, BACKUP_CONF]);
	}
	fs.writefile(ACTIVE_CONF, sprintf('%.2J\n', cfg));
	fs.unlink(candidate);

	cursor.set('wrtbox', 'main', 'active_profile', id);
	cursor.commit('wrtbox');

	logTask(sprintf('Prepared active configuration from profile "%s" (modes: %s)', id, join(', ', summary.modes)));
	return {
		ok: true,
		profile_id: id,
		summary: summary,
		skipped_core_check: chk.skipped_core_check
	};
}

function fetchSubscription(id) {
	if (!validId(id)) return { ok: false, error: 'Invalid profile ID' };
	let cursor = uci.cursor();
	let url = cursor.get('wrtbox', id, 'url');
	let name = cursor.get('wrtbox', id, 'name') || id;
	if (!url || !match(url, /^https?:\/\//)) {
		return { ok: false, error: 'Invalid or missing subscription URL' };
	}

	let ua = getMainOption(cursor, 'sub_user_agent', 'sing-box');
	let tmpDl = sprintf('/tmp/wrtbox_sub_%s.json', id);

	logTask(sprintf('Updating subscription "%s" (%s)...', name, url));

	let rc = system(['curl', '-fsSL', '--connect-timeout', '15', '--max-time', '60', '-A', ua, '-o', tmpDl, url]);
	if (rc != 0) {
		fs.unlink(tmpDl);
		let msg = sprintf('Failed to download subscription "%s" (curl exit %d)', name, rc);
		logTask('ERROR: ' + msg);
		return { ok: false, error: msg };
	}

	let raw = fs.readfile(tmpDl);
	fs.unlink(tmpDl);
	if (raw === null || trim(raw) == '') {
		return { ok: false, error: 'Downloaded subscription is empty' };
	}

	let parsed;
	try {
		parsed = parseJsonFlexible(raw);
	} catch (e) {
		let msg = sprintf('Subscription "%s" is not valid sing-box JSON: %s', name, e);
		logTask('ERROR: ' + msg);
		return { ok: false, error: msg };
	}

	if (type(parsed) != 'object' || (type(parsed.outbounds) != 'array' && type(parsed.inbounds) != 'array')) {
		let msg = sprintf('Subscription "%s" JSON does not look like a sing-box configuration (missing inbounds/outbounds)', name);
		logTask('ERROR: ' + msg);
		return { ok: false, error: msg };
	}

	let corePath = getMainOption(cursor, 'core_path', '/usr/libexec/wrtbox/sing-box');
	let tmpCheck = sprintf('/tmp/wrtbox_sub_chk_%s.json', id);
	fs.writefile(tmpCheck, raw);
	let chk = checkWithCore(corePath, tmpCheck);
	fs.unlink(tmpCheck);

	if (!chk.ok) {
		let msg = sprintf('Subscription "%s" failed sing-box check: %s', name, chk.error);
		logTask('ERROR: ' + msg);
		return { ok: false, error: msg };
	}

	system(['mkdir', '-p', PROFILES_DIR]);
	let destPath = sprintf('%s/%s.json', PROFILES_DIR, id);
	fs.writefile(destPath, raw);

	let p = fs.popen('date "+%Y-%m-%d %H:%M:%S"', 'r');
	let now = p ? trim(p.read('all')) : '';
	if (p) p.close();
	cursor.set('wrtbox', id, 'updated_at', now);
	cursor.commit('wrtbox');

	let activeId = cursor.get('wrtbox', 'main', 'active_profile');
	let reloaded = false;
	if (activeId == id) {
		let prep = prepareProfile(id);
		if (!prep.ok) return prep;
		let pSvc = fs.popen('ubus -S call service list \'{"name":"wrtbox"}\' 2>/dev/null', 'r');
		let outSvc = pSvc ? pSvc.read('all') : '';
		if (pSvc) pSvc.close();
		if (index(outSvc, '"running":true') >= 0) {
			system(['/etc/init.d/wrtbox', 'reload']);
			reloaded = true;
			logTask(sprintf('Hot-reloaded service with updated subscription "%s"', name));
		}
	}

	let summary = inspectConfigObj(parsed);
	logTask(sprintf('Subscription "%s" updated successfully', name));
	return { ok: true, profile_id: id, updated_at: now, reloaded: reloaded, summary: summary };
}

function fetchAllSubscriptions() {
	let cursor = uci.cursor();
	let ids = [];
	cursor.foreach('wrtbox', 'profile', (s) => {
		if (s.type == 'subscription' && s.url) {
			push(ids, s['.name']);
		}
	});

	let results = [];
	let okCount = 0;
	let failCount = 0;
	for (let id in ids) {
		let res = fetchSubscription(id);
		push(results, res);
		if (res.ok) okCount++;
		else failCount++;
	}

	return { ok: failCount == 0, total: length(ids), succeeded: okCount, failed: failCount, results: results };
}

let action = ARGV[0];

if (action == 'inspect') {
	let file = ARGV[1] || ACTIVE_CONF;
	let raw = fs.readfile(file);
	if (raw === null) {
		printf('%J\n', { ok: false, error: 'File not found' });
		exit(1);
	}
	try {
		let cfg = parseJsonFlexible(raw);
		printf('%J\n', { ok: true, summary: inspectConfigObj(cfg) });
	} catch (e) {
		printf('%J\n', { ok: false, error: 'Invalid JSON: ' + e });
		exit(1);
	}
} else if (action == 'prepare') {
	let res = prepareProfile(ARGV[1]);
	printf('%J\n', res);
	exit(res.ok ? 0 : 1);
} else if (action == 'fetch') {
	let res = fetchSubscription(ARGV[1]);
	printf('%J\n', res);
	exit(res.ok ? 0 : 1);
} else if (action == 'fetch_all') {
	let res = fetchAllSubscriptions();
	printf('%J\n', res);
	exit(res.ok ? 0 : 1);
} else {
	printf('%J\n', { ok: false, error: 'Usage: sub-manager.uc {inspect|prepare|fetch|fetch_all} [arg]' });
	exit(1);
}
