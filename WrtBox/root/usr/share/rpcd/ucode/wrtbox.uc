'use strict';

let fs = require('fs');
let uci = require('uci');
let ubus = require('ubus').connect();

const PROFILES_DIR = '/etc/wrtbox/profiles';
const ACTIVE_CONF = '/etc/wrtbox/active.json';
const TASK_STATE = '/tmp/wrtbox_core_task.json';
const TASK_LOCK = '/tmp/wrtbox_core_update.lock';
const TASK_LOG = '/tmp/log/wrtbox-tasks.log';

function shellQuote(s) {
	return "'" + replace(s || '', "'", "'\\''") + "'";
}

function validId(id) {
	return type(id) == 'string' && match(id, /^[a-zA-Z0-9_-]{1,64}$/) != null;
}

function runCmd(cmd) {
	let p = fs.popen(cmd, 'r');
	let out = p ? p.read('all') : '';
	let rc = p ? p.close() : 1;
	return { rc: rc, out: out };
}

function getMainOpt(cursor, key, def) {
	let v = cursor.get('wrtbox', 'main', key);
	return (v !== null && v !== '') ? v : def;
}

function getCorePath(cursor) {
	return getMainOpt(cursor, 'core_path', '/usr/libexec/wrtbox/sing-box');
}

function inspectJsonFile(path) {
	let res = runCmd('/usr/libexec/wrtbox/sub-manager.uc inspect ' + shellQuote(path) + ' 2>/dev/null');
	if (res.rc == 0 && res.out) {
		try {
			let d = json(res.out);
			if (d && d.ok) return d.summary;
		} catch (e) {}
	}
	return null;
}

return {
	'luci.wrtbox': {
		get_status: {
			call: function() {
				let cursor = uci.cursor();
				let corePath = getCorePath(cursor);
				let coreExists = fs.access(corePath, 'x');
				let coreVersion = '';
				if (coreExists) {
					let vr = runCmd(shellQuote(corePath) + ' version 2>/dev/null');
					let m = match(vr.out, /sing-box version\s+([^\s\n]+)/);
					if (m) coreVersion = m[1];
				}

				let archRes = runCmd('/usr/libexec/wrtbox/core-manager.sh arch 2>/dev/null');
				let arch = trim(archRes.out || '');

				let svc = ubus.call('service', 'list', { name: 'wrtbox' });
				let running = false;
				let pid = null;
				let memoryKb = null;

				if (svc && svc.wrtbox && svc.wrtbox.instances && svc.wrtbox.instances.wrtbox) {
					let inst = svc.wrtbox.instances.wrtbox;
					running = !!inst.running;
					pid = inst.pid || null;
					if (running && pid) {
						let statusTxt = fs.readfile(sprintf('/proc/%d/status', int(pid)));
						if (statusTxt) {
							let mm = match(statusTxt, /VmRSS:\s+(\d+)\s+kB/);
							if (mm) memoryKb = int(mm[1]);
						}
					}
				}

				let activeId = getMainOpt(cursor, 'active_profile', '');
				let activeName = activeId != '' ? (cursor.get('wrtbox', activeId, 'name') || activeId) : '';
				let activeSummary = null;
				if (fs.stat(ACTIVE_CONF)) {
					activeSummary = inspectJsonFile(ACTIVE_CONF);
				} else if (activeId != '' && validId(activeId)) {
					let pf = sprintf('%s/%s.json', PROFILES_DIR, activeId);
					if (fs.stat(pf)) activeSummary = inspectJsonFile(pf);
				}

				// Check free space on core parent dir
				let dirCmd = 'df -k ' + shellQuote(replace(corePath, /\/[^\/]+$/, '') || '/') + ' 2>/dev/null | awk \'NR==2{print $4}\'';
				let dfRes = runCmd(dirCmd);
				let freeKb = int(trim(dfRes.out || '0'));

				return {
					enabled: getMainOpt(cursor, 'enabled', '0') == '1',
					running: running,
					pid: pid,
					memory_kb: memoryKb,
					core_path: corePath,
					core_exists: coreExists,
					core_version: coreVersion,
					core_tag: getMainOpt(cursor, 'core_version', ''),
					core_channel: getMainOpt(cursor, 'core_channel', 'stable'),
					cdn_enabled: getMainOpt(cursor, 'cdn_enabled', '1') == '1',
					cdn_url: getMainOpt(cursor, 'cdn_url', 'https://ghfast.top/'),
					arch: arch,
					free_kb: freeKb,
					active_profile: activeId,
					active_profile_name: activeName,
					active_summary: activeSummary
				};
			}
		},

		service_action: {
			args: { action: '' },
			call: function(req) {
				let act = req.args.action;
				if (index(['start', 'stop', 'restart', 'reload'], act) < 0) {
					return { ok: false, error: 'Invalid service action' };
				}
				if (act == 'start' || act == 'restart') {
					let cursor = uci.cursor();
					if (getMainOpt(cursor, 'enabled', '0') != '1') {
						cursor.set('wrtbox', 'main', 'enabled', '1');
						cursor.commit('wrtbox');
					}
				} else if (act == 'stop') {
					let cursor = uci.cursor();
					cursor.set('wrtbox', 'main', 'enabled', '0');
					cursor.commit('wrtbox');
				}
				let rc = system(['/etc/init.d/wrtbox', act]);
				return { ok: rc == 0, rc: rc };
			}
		},

		check_core_update: {
			args: { channel: '' },
			call: function(req) {
				let cursor = uci.cursor();
				let ch = req.args.channel || getMainOpt(cursor, 'core_channel', 'stable');
				if (index(['stable', 'prerelease'], ch) < 0) ch = 'stable';
				let res = runCmd('/usr/libexec/wrtbox/core-manager.sh check ' + shellQuote(ch) + ' 2>/dev/null');
				try {
					return json(res.out);
				} catch (e) {
					return { ok: false, error: 'Failed to parse release check response' };
				}
			}
		},

		install_core: {
			args: { channel: '', tag: '' },
			call: function(req) {
				let cursor = uci.cursor();
				let ch = req.args.channel || getMainOpt(cursor, 'core_channel', 'stable');
				if (index(['stable', 'prerelease'], ch) < 0) ch = 'stable';
				let tag = req.args.tag || '';
				if (tag != '' && !match(tag, /^[a-zA-Z0-9._-]+$/)) {
					return { ok: false, error: 'Invalid tag format' };
				}

				if (fs.stat(TASK_LOCK)) {
					let oldPid = trim(fs.readfile(TASK_LOCK) || '');
					if (oldPid != '' && fs.stat('/proc/' + oldPid)) {
						return { ok: false, error: 'Core update task is already running' };
					}
				}

				let cmd = '/usr/libexec/wrtbox/core-manager.sh install ' + shellQuote(ch) + ' ' + shellQuote(tag) + ' >/dev/null 2>&1 &';
				system(['/bin/sh', '-c', cmd]);
				return { ok: true, started: true };
			}
		},

		uninstall_core: {
			call: function() {
				let res = runCmd('/usr/libexec/wrtbox/core-manager.sh uninstall 2>/dev/null');
				try {
					return json(res.out);
				} catch (e) {
					return { ok: false, error: res.out || 'Uninstall failed' };
				}
			}
		},

		get_core_task: {
			call: function() {
				let raw = fs.readfile(TASK_STATE);
				let state = { status: 'idle', progress: 0, message: '' };
				if (raw) {
					try { state = json(raw); } catch (e) {}
				}
				let running = false;
				if (fs.stat(TASK_LOCK)) {
					let pid = trim(fs.readfile(TASK_LOCK) || '');
					if (pid != '' && fs.stat('/proc/' + pid)) running = true;
				}
				if (state.status == 'running' && !running) {
					state.status = 'idle';
				}
				return state;
			}
		},

		test_cdn: {
			args: { url: '' },
			call: function(req) {
				let u = trim(req.args.url || '');
				if (u != '' && !match(u, /^https?:\/\/[^\s'"]+$/)) {
					u = '';
				}
				let res = runCmd('/usr/libexec/wrtbox/core-manager.sh test_cdn ' + shellQuote(u) + ' 2>/dev/null');
				try {
					return json(res.out);
				} catch (e) {
					return { ok: false, error: 'CDN test failed' };
				}
			}
		},

		save_cdn: {
			args: { enabled: '', url: '' },
			call: function(req) {
				let enabled = (req.args.enabled == '1' || req.args.enabled == 'true') ? '1' : '0';
				let url = trim(req.args.url || '');
				if (enabled == '1' && url != '' && !match(url, /^https?:\/\/[^\s'"]+$/)) {
					return { ok: false, error: 'Invalid CDN URL format' };
				}
				let cursor = uci.cursor();
				cursor.set('wrtbox', 'main', 'cdn_enabled', enabled);
				if (url != '') cursor.set('wrtbox', 'main', 'cdn_url', url);
				cursor.commit('wrtbox');
				return { ok: true, enabled: enabled == '1', url: url };
			}
		},

		list_profiles: {
			call: function() {
				let cursor = uci.cursor();
				let activeId = getMainOpt(cursor, 'active_profile', '');
				let list = [];
				cursor.foreach('wrtbox', 'profile', (s) => {
					let id = s['.name'];
					let filePath = sprintf('%s/%s.json', PROFILES_DIR, id);
					let st = fs.stat(filePath);
					let summary = st ? inspectJsonFile(filePath) : null;
					push(list, {
						id: id,
						name: s.name || id,
						type: s.type || 'local',
						url: s.url || '',
						updated_at: s.updated_at || '',
						size: st ? st.size : 0,
						exists: st != null,
						active: id == activeId,
						summary: summary
					});
				});
				return {
					ok: true,
					active_profile: activeId,
					profiles: list,
					sub_settings: {
						auto_update: getMainOpt(cursor, 'sub_auto_update', '0') == '1',
						cron: getMainOpt(cursor, 'sub_update_cron', '0 5 * * *'),
						user_agent: getMainOpt(cursor, 'sub_user_agent', 'sing-box')
					}
				};
			}
		},

		get_profile_content: {
			args: { id: '' },
			call: function(req) {
				let id = req.args.id;
				if (!validId(id)) return { ok: false, error: 'Invalid profile ID' };
				let filePath = sprintf('%s/%s.json', PROFILES_DIR, id);
				let content = fs.readfile(filePath);
				if (content === null) return { ok: false, error: 'Profile file not found' };
				return { ok: true, id: id, content: content };
			}
		},

		save_profile: {
			args: { id: '', name: '', type: '', url: '', content: '' },
			call: function(req) {
				let id = req.args.id;
				if (!id || id == '') {
					id = sprintf('p_%x', time());
				}
				if (!validId(id)) return { ok: false, error: 'Profile ID must be alphanumeric/underscore/hyphen' };

				let pType = req.args.type || 'local';
				if (index(['local', 'subscription'], pType) < 0) {
					return { ok: false, error: 'Invalid profile type' };
				}

				let name = trim(req.args.name || id);
				let url = trim(req.args.url || '');
				let content = req.args.content || '';

				if (pType == 'subscription') {
					if (!match(url, /^https?:\/\//)) {
						return { ok: false, error: 'Subscription URL must start with http:// or https://' };
					}
				}

				if (content != '') {
					try {
						let obj = json(content);
						if (type(obj) != 'object') return { ok: false, error: 'JSON root must be an object' };
					} catch (e) {
						return { ok: false, error: 'Invalid JSON syntax: ' + e };
					}
				} else if (pType == 'local') {
					let existing = fs.stat(sprintf('%s/%s.json', PROFILES_DIR, id));
					if (!existing) return { ok: false, error: 'JSON content cannot be empty for local profile' };
				}

				let cursor = uci.cursor();
				cursor.set('wrtbox', id, 'profile');
				cursor.set('wrtbox', id, 'name', name);
				cursor.set('wrtbox', id, 'type', pType);
				if (pType == 'subscription') {
					cursor.set('wrtbox', id, 'url', url);
				} else {
					cursor.delete('wrtbox', id, 'url');
				}

				if (content != '') {
					system(['mkdir', '-p', PROFILES_DIR]);
					let dest = sprintf('%s/%s.json', PROFILES_DIR, id);
					fs.writefile(dest, content);
					let dr = runCmd('date "+%Y-%m-%d %H:%M:%S"');
					cursor.set('wrtbox', id, 'updated_at', trim(dr.out || ''));
				}
				cursor.commit('wrtbox');

				// If active profile content was updated, re-prepare and reload safely
				let activeId = getMainOpt(cursor, 'active_profile', '');
				let reloaded = false;
				if (content != '' && activeId == id) {
					let prep = runCmd('/usr/libexec/wrtbox/sub-manager.uc prepare ' + shellQuote(id));
					if (prep.rc != 0) {
						let err = prep.out;
						try { err = json(prep.out).error; } catch (e) {}
						return { ok: false, id: id, error: 'Saved, but active validation failed: ' + err };
					}
					let svc = ubus.call('service', 'list', { name: 'wrtbox' });
					if (svc && svc.wrtbox && svc.wrtbox.instances && svc.wrtbox.instances.wrtbox && svc.wrtbox.instances.wrtbox.running) {
						system(['/etc/init.d/wrtbox', 'reload']);
						reloaded = true;
					}
				}

				return { ok: true, id: id, reloaded: reloaded };
			}
		},

		delete_profile: {
			args: { id: '' },
			call: function(req) {
				let id = req.args.id;
				if (!validId(id)) return { ok: false, error: 'Invalid profile ID' };
				let cursor = uci.cursor();
				let activeId = getMainOpt(cursor, 'active_profile', '');
				if (activeId == id) {
					cursor.set('wrtbox', 'main', 'active_profile', '');
				}
				cursor.delete('wrtbox', id);
				cursor.commit('wrtbox');
				fs.unlink(sprintf('%s/%s.json', PROFILES_DIR, id));
				return { ok: true };
			}
		},

		activate_profile: {
			args: { id: '' },
			call: function(req) {
				let id = req.args.id;
				if (!validId(id)) return { ok: false, error: 'Invalid profile ID' };
				let res = runCmd('/usr/libexec/wrtbox/sub-manager.uc prepare ' + shellQuote(id));
				let parsed;
				try {
					parsed = json(res.out);
				} catch (e) {
					return { ok: false, error: res.out || 'Failed to prepare profile' };
				}
				if (!parsed.ok) return parsed;

				let cursor = uci.cursor();
				let enabled = getMainOpt(cursor, 'enabled', '0') == '1';
				let svc = ubus.call('service', 'list', { name: 'wrtbox' });
				let running = !!(svc && svc.wrtbox && svc.wrtbox.instances && svc.wrtbox.instances.wrtbox && svc.wrtbox.instances.wrtbox.running);

				if (running) {
					system(['/etc/init.d/wrtbox', 'reload']);
					parsed.reloaded = true;
				} else if (enabled) {
					system(['/etc/init.d/wrtbox', 'start']);
					parsed.started = true;
				}
				return parsed;
			}
		},

		update_subscription: {
			args: { id: '' },
			call: function(req) {
				let id = req.args.id;
				if (id == '__all__') {
					let res = runCmd('/usr/libexec/wrtbox/sub-manager.uc fetch_all');
					try { return json(res.out); } catch (e) { return { ok: false, error: res.out || 'Fetch all failed' }; }
				}
				if (!validId(id)) return { ok: false, error: 'Invalid profile ID' };
				let res = runCmd('/usr/libexec/wrtbox/sub-manager.uc fetch ' + shellQuote(id));
				try { return json(res.out); } catch (e) { return { ok: false, error: res.out || 'Fetch failed' }; }
			}
		},

		save_sub_settings: {
			args: { auto_update: '', cron: '', user_agent: '' },
			call: function(req) {
				let autoUpdate = (req.args.auto_update == '1' || req.args.auto_update == 'true') ? '1' : '0';
				let cron = trim(req.args.cron || '0 5 * * *');
				let ua = trim(req.args.user_agent || 'sing-box');
				if (cron == '') cron = '0 5 * * *';
				if (!match(cron, /^\S+(\s+\S+){4}$/)) {
					return { ok: false, error: 'Invalid cron expression (must have 5 fields)' };
				}
				if (ua == '') ua = 'sing-box';
				ua = replace(ua, /[\r\n\t]/g, '');

				let cursor = uci.cursor();
				cursor.set('wrtbox', 'main', 'sub_auto_update', autoUpdate);
				cursor.set('wrtbox', 'main', 'sub_update_cron', cron);
				cursor.set('wrtbox', 'main', 'sub_user_agent', ua);
				cursor.commit('wrtbox');
				system(['/usr/libexec/wrtbox/cron-task.sh', 'sync']);

				return {
					ok: true,
					sub_settings: {
						auto_update: autoUpdate == '1',
						cron: cron,
						user_agent: ua
					}
				};
			}
		},

		get_logs: {
			args: { type: '' },
			call: function(req) {
				let t = req.args.type || 'service';
				if (t == 'tasks') {
					let txt = fs.readfile(TASK_LOG) || '';
					let lines = split(txt, '\n');
					if (length(lines) > 300) {
						lines = slice(lines, length(lines) - 300);
					}
					return { ok: true, content: join('\n', lines) };
				}
				let res = runCmd("logread -l 500 2>/dev/null | grep -E 'wrtbox|sing-box' | tail -n 250");
				return { ok: true, content: res.out || '' };
			}
		},

		clear_logs: {
			args: { type: '' },
			call: function(req) {
				let t = req.args.type || 'tasks';
				if (t == 'tasks') {
					fs.writefile(TASK_LOG, '');
					return { ok: true };
				}
				return { ok: false, error: 'System logread ring buffer cannot be selectively cleared' };
			}
		},

		sync_cron: {
			call: function() {
				let rc = system(['/usr/libexec/wrtbox/cron-task.sh', 'sync']);
				return { ok: rc == 0 };
			}
		}
	}
};
