'use strict';
'require view';
'require rpc';
'require ui';
'require poll';

var callList = rpc.declare({
	object: 'luci.clientblock',
	method: 'list',
	params: ['probe']
});

var callBlock = rpc.declare({
	object: 'luci.clientblock',
	method: 'block',
	params: ['mac', 'host', 'ip']
});

var callUnblock = rpc.declare({
	object: 'luci.clientblock',
	method: 'unblock',
	params: ['mac']
});

var callUnblockAll = rpc.declare({
	object: 'luci.clientblock',
	method: 'unblock_all'
});

var callIpList = rpc.declare({
	object: 'luci.clientblock',
	method: 'iplist'
});

var callIpAdd = rpc.declare({
	object: 'luci.clientblock',
	method: 'ipadd',
	params: ['ip', 'note']
});

var callIpDel = rpc.declare({
	object: 'luci.clientblock',
	method: 'ipdel',
	params: ['ip']
});

var callLogList = rpc.declare({
	object: 'luci.clientblock',
	method: 'loglist',
	params: ['limit']
});

var callLogClear = rpc.declare({
	object: 'luci.clientblock',
	method: 'logclear'
});

var callAutoGet = rpc.declare({
	object: 'luci.clientblock',
	method: 'autoget'
});

var callAutoSet = rpc.declare({
	object: 'luci.clientblock',
	method: 'autoset',
	params: ['enabled', 'threshold', 'window', 'ttl', 'ssh_password', 'ssh_user', 'web_auth']
});

var callScan = rpc.declare({
	object: 'luci.clientblock',
	method: 'scan'
});

var callIpFlush = rpc.declare({
	object: 'luci.clientblock',
	method: 'ipflush'
});

var callRename = rpc.declare({
	object: 'luci.clientblock',
	method: 'rename',
	params: ['mac', 'name']
});

var STYLE = `
/* All colours come from the LuCI theme so light/dark switch automatically.
   Fonts likewise: var(--font-sans) for prose, var(--font-mono) for data. */
.cb-wrap { width: 100%; }
.cb-toolbar { display: flex; flex-wrap: wrap; gap: .5rem; align-items: center; margin-bottom: 1rem; }
.cb-toolbar input[type=text] { flex: 1 1 14rem; min-width: 10rem; padding: .4rem .6rem; }
.cb-count { font-size: .875rem; color: var(--text-muted); margin-left: auto; }

/* ---- tables ---- */
.cb-table { width: 100%; border-collapse: separate; border-spacing: 0; font-size: .875rem; }
.cb-table th, .cb-table td { padding: .45rem .6rem; text-align: left;
	border-bottom: 1px solid var(--hairline); vertical-align: middle; }
.cb-table th { font-weight: 600; color: var(--text-muted); white-space: nowrap; }
.cb-table tr.cb-blocked td { background: var(--danger-surface); }
.cb-table tr.cb-offline td { color: var(--text-muted); }
.cb-table td.cb-mono, .cb-table th.cb-mono { font-family: var(--font-mono); }
.cb-empty { text-align: center; padding: 2rem 0; color: var(--text-muted); }

/* ---- badges ---- */
.cb-badge { display: inline-block; padding: .08rem .5rem; border-radius: .7rem;
	font-size: .75rem; font-weight: 600; line-height: 1.5; white-space: nowrap; }
.cb-badge-on { background: var(--success-surface); color: var(--success); }
.cb-badge-off { background: var(--hover-faint); color: var(--text-muted); }
.cb-badge-blocked { background: var(--danger-surface); color: var(--danger); }
.cb-tag { display: inline-block; padding: 0 .4rem; border-radius: .25rem;
	font-size: .7rem; font-family: var(--font-mono); letter-spacing: .02em;
	background: var(--hover-faint); color: var(--text-muted); }
.cb-drop { font-size: .75rem; color: var(--text-muted); white-space: nowrap; }

/* ---- buttons ---- */
.cb-btn { padding: .28rem .7rem; border-radius: .35rem; border: 1px solid var(--hairline);
	background: transparent; color: inherit; cursor: pointer; font-size: .8rem; white-space: nowrap; }
.cb-btn:hover { background: var(--hover-faint); }
.cb-btn:focus-visible { outline: 2px solid var(--focus-ring); outline-offset: 1px; }
.cb-btn[disabled] { opacity: .45; cursor: default; }
.cb-btn-danger { border-color: var(--danger); color: var(--danger); }
.cb-btn-danger:hover { background: var(--danger-surface); }
.cb-btn-ok { border-color: var(--success); color: var(--success); }
.cb-btn-ok:hover { background: var(--success-surface); }
.cb-btn-primary { border-color: var(--brand); color: var(--brand); font-weight: 600; }
.cb-btn-primary:hover { background: var(--brand-subtle); }

/* ---- tabs ---- */
.cb-tabs { display: flex; gap: .25rem; border-bottom: 1px solid var(--hairline); margin-bottom: 1rem; }
.cb-tab { padding: .5rem 1rem; cursor: pointer; border: 1px solid transparent; border-bottom: none;
	border-radius: .35rem .35rem 0 0; background: transparent; color: var(--text-muted);
	font-size: .875rem; margin-bottom: -1px; }
.cb-tab:hover { color: var(--text); background: var(--hover-faint); }
.cb-tab.active { color: var(--text); border-color: var(--hairline);
	background: var(--surface); font-weight: 600; }
.cb-pane { display: none; }
.cb-pane.active { display: block; }

/* ---- ip form ---- */
.cb-ipform { display: flex; flex-wrap: wrap; gap: .5rem; align-items: center; margin-bottom: 1rem; }
.cb-ipform input[type=text] { padding: .4rem .6rem; border-radius: .3rem;
	border: 1px solid var(--hairline); background: transparent; color: inherit; }
.cb-ipform input[type=text]:focus { outline: none; border-color: var(--brand); }
.cb-ipform input.cb-ip { flex: 0 0 16rem; font-family: var(--font-mono); }
.cb-ipform input.cb-note { flex: 1 1 12rem; min-width: 8rem; }
.cb-fam { font-size: .7rem; color: var(--text-subtle); font-family: var(--font-mono); }
.cb-src { display: inline-block; padding: 0 .4rem; border-radius: .7rem; font-size: .7rem; font-weight: 600; }
.cb-src-auto { background: var(--danger-surface); color: var(--danger); }
.cb-src-watchdog { background: var(--info-surface); color: var(--info); }

/* ---- cards ---- */
.cb-card { border: 1px solid var(--hairline); border-radius: .55rem;
	background: var(--surface); margin-bottom: 1rem; overflow: hidden; }
.cb-card-head { display: flex; align-items: center; gap: .6rem; padding: .65rem .9rem;
	font-weight: 600; font-size: .9rem; border-bottom: 1px solid var(--hairline);
	background: var(--surface-sunken); }
.cb-card-head .cb-dot { width: .5rem; height: .5rem; border-radius: 50%;
	background: var(--brand); flex: 0 0 auto; }
.cb-card-body { padding: .85rem .9rem; }
.cb-card-hint { font-size: .76rem; color: var(--text-muted); line-height: 1.5; }

/* ---- toggle ---- */
.cb-switch { position: relative; display: inline-flex; align-items: center; gap: .5rem;
	cursor: pointer; user-select: none; }
.cb-switch input { position: absolute; opacity: 0; width: 0; height: 0; }
.cb-switch .cb-track { width: 2.4rem; height: 1.3rem; border-radius: 1rem;
	background: var(--text-subtle); transition: background .18s ease; flex: 0 0 auto; position: relative; }
.cb-switch .cb-track::after { content: ''; position: absolute; top: .15rem; left: .15rem;
	width: 1rem; height: 1rem; border-radius: 50%; background: var(--bg);
	transition: transform .18s ease; }
.cb-switch input:checked + .cb-track { background: var(--success); }
.cb-switch input:checked + .cb-track::after { transform: translateX(1.1rem); }
.cb-switch input:focus-visible + .cb-track { outline: 2px solid var(--focus-ring); outline-offset: 2px; }

/* ---- trigger chips ---- */
.cb-triggers { display: flex; flex-wrap: wrap; gap: .5rem; margin-top: .2rem; }
.cb-chip { display: inline-flex; align-items: center; gap: .4rem; padding: .38rem .7rem;
	border: 1px solid var(--hairline); border-radius: 2rem; cursor: pointer;
	font-size: .8rem; background: transparent; transition: all .15s ease; user-select: none; }
.cb-chip:hover { background: var(--hover-faint); }
.cb-chip input { margin: 0; cursor: pointer; }
.cb-chip.on { border-color: var(--success); background: var(--success-surface); font-weight: 600; }
.cb-chip .cb-chip-code { font-family: var(--font-mono); font-size: .7rem; color: var(--text-subtle); }
.cb-chip.on .cb-chip-code { color: var(--text-muted); }

/* ---- fields ---- */
.cb-fields { display: flex; flex-wrap: wrap; gap: 1.1rem; align-items: flex-end; margin-top: .9rem; }
.cb-field { display: flex; flex-direction: column; gap: .25rem; }
.cb-field > span { font-size: .74rem; color: var(--text-muted); }
.cb-field input { width: 6rem; padding: .35rem .5rem; border-radius: .3rem;
	border: 1px solid var(--hairline); background: transparent; color: inherit; font-size: .875rem; }
.cb-field input:focus { outline: none; border-color: var(--brand); }
.cb-actions { display: flex; gap: .5rem; margin-left: auto; }

/* ---- login log ---- */
.cb-log-filters { display: flex; flex-wrap: wrap; gap: .45rem; align-items: center; margin-bottom: .85rem; }
.cb-log-filters input[type=text] { flex: 1 1 14rem; min-width: 9rem; padding: .38rem .6rem;
	border-radius: .3rem; border: 1px solid var(--hairline); background: transparent; color: inherit; }
.cb-log-filters input[type=text]:focus { outline: none; border-color: var(--brand); }
.cb-log-filters select { padding: .38rem .5rem; border-radius: .3rem; color: inherit;
	border: 1px solid var(--hairline); background: var(--surface); }
.cb-log { font-size: .875rem; }
.cb-log thead th { position: sticky; top: 0; z-index: 2; background: var(--surface-sunken); }
.cb-log tbody td { vertical-align: top; }
.cb-log td.cb-t, .cb-log td.cb-ip { font-family: var(--font-mono); white-space: nowrap; }
.cb-log td.cb-u { font-weight: 600; }
.cb-log td.cb-detail { color: var(--text-muted); }

/* result / source / auth badges */
.cb-res { display: inline-block; padding: .05rem .5rem; border-radius: .6rem;
	font-size: .75rem; font-weight: 600; white-space: nowrap; }
.cb-res-ok { background: var(--success-surface); color: var(--success); }
.cb-res-fail { background: var(--danger-surface); color: var(--danger); }
.cb-res-end { background: var(--hover-faint); color: var(--text-muted); }
.cb-src-ssh { background: var(--info-surface); color: var(--info); }
.cb-src-web { background: var(--brand-subtle); color: var(--brand); }
.cb-auth { display: inline-block; padding: .02rem .45rem; border-radius: .6rem;
	font-size: .72rem; font-family: var(--font-mono); border: 1px solid currentColor; }
.cb-auth-pubkey { color: var(--success); }
.cb-auth-password { color: var(--warning); }
.cb-auth-na { color: var(--text-subtle); border-color: var(--hairline); }

/* left status rail */
.cb-log tbody tr td:first-child { border-left: 3px solid transparent; }
.cb-log tbody tr.r-ok td:first-child { border-left-color: var(--success); }
.cb-log tbody tr.r-fail td:first-child { border-left-color: var(--danger); }
.cb-log tbody tr.r-end td:first-child { border-left-color: var(--text-subtle); }

/* day separator */
.cb-log tr.cb-day td { padding: .7rem .6rem .3rem; font-size: .75rem; font-weight: 600;
	color: var(--text-muted); border-bottom: 1px solid var(--hairline); border-left: none; }
.cb-log tr.cb-day td em { font-style: normal; color: var(--brand); }

/* new-record flash */
@keyframes cb-flash { from { background: var(--info-surface); } to { background: transparent; } }
.cb-log tbody tr.cb-new td { animation: cb-flash 1.6s ease-out 1; }
`;

function fmtBytes(n) {
	if (!n) return '0';
	var u = [ 'B', 'KB', 'MB', 'GB', 'TB' ], i = 0;
	while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
	return (i === 0 ? n : n.toFixed(1)) + ' ' + u[i];
}

function fmtGeo(geo) {
	if (!geo) return '';
	var p = String(geo).split('|');
	var parts = [];
	var seen = {};
	for (var i = 0; i < 4; i++) {
		var v = (p[i] || '').trim();
		if (!v || v === '0' || v === 'Reserved' || v === 'reserved') continue;
		if (seen[v]) continue;
		seen[v] = 1;
		parts.push(v);
	}
	var cc = (p[4] || '').trim();
	if (cc && cc !== '0') parts.push(cc);
	return parts.join(' · ');
}

function fmtTime(ts) {
	if (!ts) return '';
	var d = new Date(ts * 1000);
	function p(x) { return (x < 10 ? '0' : '') + x; }
	return d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate()) +
		' ' + p(d.getHours()) + ':' + p(d.getMinutes());
}

return view.extend({
	load: function () {
		return Promise.all([ callList('1'), callIpList(), callAutoGet(), callLogList('500') ]).then(function (r) {
			var dev = r[0] || {}, ips = r[1] || {}, auto = r[2] || {}, logs = r[3] || {};
			dev.ips = ips.ips || [];
			dev.ip_count = ips.count || 0;
			dev.auto = auto;
			dev.logs = logs.entries || [];
			return dev;
		});
	},

	handleBlock: function (dev, ev) {
		var btn = ev.currentTarget;
		btn.disabled = true;
		btn.textContent = _('Blocking…');
		return callBlock(dev.mac, dev.host || '', dev.ip || '').then(function (res) {
			if (!res || res.success === false)
				throw new Error((res && res.error) || _('Failed'));
			ui.addNotification(null, E('p', {}, _('Blocked') + ' ' + (dev.host || dev.mac)), 'info');
			return this.refresh();
		}.bind(this)).catch(function (e) {
			ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error');
			return this.refresh();
		}.bind(this));
	},

	handleUnblock: function (dev, ev) {
		var btn = ev.currentTarget;
		btn.disabled = true;
		btn.textContent = _('Unblocking…');
		return callUnblock(dev.mac).then(function (res) {
			if (!res || res.success === false)
				throw new Error((res && res.error) || _('Failed'));
			ui.addNotification(null, E('p', {}, _('Unblocked') + ' ' + (dev.host || dev.mac)), 'info');
			return this.refresh();
		}.bind(this)).catch(function (e) {
			ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error');
			return this.refresh();
		}.bind(this));
	},

	handleUnblockAll: function (ev) {
		if (!confirm(_('Unblock all devices?')))
			return;
		var btn = ev.currentTarget;
		btn.disabled = true;
		return callUnblockAll().then(function () {
			ui.addNotification(null, E('p', {}, _('All devices unblocked')), 'info');
			return this.refresh();
		}.bind(this)).catch(function (e) {
			ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error');
			return this.refresh();
		}.bind(this));
	},

	handleRename: function (dev) {
		var self = this;
		var name = prompt(_('Device name'), dev.host || '');
		if (name === null) return;
		return callRename(dev.mac, name).then(function (res) {
			if (res && res.success === false)
				throw new Error(res.error || _('Failed'));
			return self.refresh();
		}).catch(function (e) {
			ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error');
			return self.refresh();
		});
	},

	handleProbe: function (ev) {
		var btn = ev.currentTarget;
		btn.disabled = true;
		btn.textContent = _('Scanning…');
		return callList('1').then(function (res) {
			this.devices = (res && res.devices) || [];
			this.blockedCount = (res && res.blocked_count) || 0;
			this.renderTable();
		}.bind(this)).catch(function (e) {
			ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error');
		}).finally(function () {
			btn.disabled = false;
			btn.textContent = _('Rescan devices');
		});
	},

	refresh: function () {
		var self = this;
		return callList('1').then(function (res) {
			self.devices = (res && res.devices) || [];
			self.blockedCount = (res && res.blocked_count) || 0;
			self.renderTable();
		}).catch(function () {}).then(function () {
			self.renderTable();
		});
	},

	filterRows: function () {
		var q = (this.query || '').toLowerCase().trim();
		if (!q) return this.devices;
		return this.devices.filter(function (d) {
			return (d.host || '').toLowerCase().indexOf(q) !== -1 ||
				(d.ip || '').indexOf(q) !== -1 ||
				(d.mac || '').toLowerCase().indexOf(q) !== -1;
		});
	},

	refreshLogs: function () {
		var self = this;
		return callLogList('500').then(function (res) {
			var next = (res && res.entries) || [];
			var prev = self.logs || [];
			// Only touch the DOM when the head changed, so the flash animation
			// on new rows is not restarted by every poll.
			var head = function (a) {
				return a.length ? [ a[0].ts, a[0].ip, a[0].kind, a[0].result ].join('|') : '';
			};
			if (head(prev) === head(next) && prev.length === next.length) {
				return;
			}
			// remember which entries are new so they can be highlighted
			var prevKeys = {};
			prev.forEach(function (e) { prevKeys[e.ts + '|' + e.ip + '|' + e.kind + '|' + e.result] = 1; });
			self.newKeys = {};
			next.forEach(function (e) {
				var k = e.ts + '|' + e.ip + '|' + e.kind + '|' + e.result;
				if (!prevKeys[k]) self.newKeys[k] = 1;
			});
			self.logs = next;
			self.renderLogs();
		}).catch(function () {});
	},

	handleLogClear: function (ev) {
		var self = this;
		if (!confirm(_('Clear the login log?'))) return;
		var btn = ev.currentTarget;
		btn.disabled = true;
		return callLogClear().then(function () {
			self.logs = [];
			self.newKeys = {};
			self.renderLogs();
			ui.addNotification(null, E('p', {}, _('Log cleared')), 'info');
		}).catch(function (e) {
			ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error');
		}).finally(function () {
			btn.disabled = false;
		});
	},

	logDayLabel: function (ts) {
		var d = new Date(ts * 1000);
		var now = new Date();
		var same = function (a, b) {
			return a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth()
				&& a.getDate() === b.getDate();
		};
		var y = new Date(now.getTime() - 86400000);
		function p(x) { return (x < 10 ? '0' : '') + x; }
		if (same(d, now)) return { label: _('Today'), key: 'today' };
		if (same(d, y)) return { label: _('Yesterday'), key: 'yday' };
		return { label: d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate()),
		         key: 'd' + d.getFullYear() + p(d.getMonth() + 1) + p(d.getDate()) };
	},

	logResultClass: function (r) {
		if (r === 'success') return 'r-ok';
		if (r === 'failure') return 'r-fail';
		return 'r-end';
	},

	// ssh_password / ssh_user -> SSH, web / web_auth -> LuCI
	logSource: function (kind) {
		if (!kind) return null;
		if (kind.indexOf('ssh') === 0) return { label: 'SSH', cls: 'cb-src-ssh' };
		if (kind.indexOf('web') === 0) return { label: 'LuCI', cls: 'cb-src-web' };
		return null;
	},

	// only auth=... details carry a method
	logAuth: function (detail) {
		var m = (detail || '').match(/^auth=(\w+)$/);
		return m ? m[1] : null;
	},

	renderLogs: function () {
		var tbody = document.getElementById('cb-log-tbody');
		if (!tbody) return;
		while (tbody.firstChild) tbody.removeChild(tbody.firstChild);

		var self = this;
		var all = this.logs || [];
		var q = (this.logQuery || '').toLowerCase().trim();
		var kindF = this.logKind || 'all';
		var resF = this.logResult || 'all';
		var newKeys = this.newKeys || {};

		var list = all.filter(function (e) {
			if (kindF !== 'all') {
				if (kindF === 'ssh') { if (String(e.kind).indexOf('ssh') !== 0) return false; }
				else if (kindF === 'web') { if (String(e.kind).indexOf('web') !== 0) return false; }
				else if (e.kind !== kindF) return false;
			}
			if (resF === 'ok' && e.result !== 'success') return false;
			if (resF === 'fail' && e.result !== 'failure') return false;
			if (resF === 'end' && e.result !== 'disconnect') return false;
			if (q) {
				var hay = [ e.ip, e.user, e.detail, e.host ].join(' ').toLowerCase();
				if (hay.indexOf(q) === -1) return false;
			}
			return true;
		});

		if (!list.length) {
			tbody.appendChild(E('tr', {}, E('td', { 'colspan': 7, 'class': 'cb-empty' },
				all.length ? _('No entries match the filter') : _('No login activity recorded yet'))));
		}

		var lastDay = null;
		list.forEach(function (e) {
			var day = self.logDayLabel(e.ts);
			if (day.key !== lastDay) {
				lastDay = day.key;
				tbody.appendChild(E('tr', { 'class': 'cb-day' }, E('td', { 'colspan': 7 },
					day.key === 'today' || day.key === 'yday'
						? E('span', {}, E('em', {}, day.label), ' ', fmtTime(e.ts).split(' ')[0])
						: day.label)));
			}

			var resLabel = e.result === 'success' ? 'success'
				: (e.result === 'failure' ? 'failure' : 'closed');
			var resBadge = E('span', { 'class': 'cb-res cb-res-' +
				(e.result === 'success' ? 'ok' : (e.result === 'failure' ? 'fail' : 'end')) }, resLabel);

			var src = self.logSource(e.kind);
			var srcBadge = src
				? E('span', { 'class': 'cb-res ' + src.cls }, src.label)
				: E('span', { 'class': 'cb-drop' }, '-');

			var auth = self.logAuth(e.detail);
			var authBadge = auth
				? E('span', { 'class': 'cb-auth cb-auth-' + auth }, auth)
				: E('span', { 'class': 'cb-auth cb-auth-na' }, 'n/a');

			// the auth method is its own column now; drop it from the detail text
			var reason = String(e.detail || '').replace(/^auth=\w+\s*/, '').trim();

			var cc = e.geo ? String(e.geo).split('|')[4] : '';
			var geoCell = e.geo
				? E('span', { 'class': 'cb-tag', 'title': fmtGeo(e.geo) }, cc || '?')
				: '';

			var key = e.ts + '|' + e.ip + '|' + e.kind + '|' + e.result;
			var cls = self.logResultClass(e.result) + (newKeys[key] ? ' cb-new' : '');

			tbody.appendChild(E('tr', { 'class': cls }, [
				E('td', { 'class': 'cb-t' }, fmtTime(e.ts)),
				E('td', {}, resBadge),
				E('td', {}, srcBadge),
				E('td', {}, authBadge),
				E('td', { 'class': 'cb-ip' }, [
					e.ip || '-',
					e.host ? E('span', { 'class': 'cb-drop' }, ' ' + e.host) : ''
				]),
				E('td', { 'class': 'cb-u' }, e.user || '-'),
				E('td', { 'class': 'cb-detail' }, reason || geoCell
					? [ geoCell, geoCell && reason ? ' ' : '', reason ]
					: '')
			]));
		});

		var cnt = document.getElementById('cb-log-count');
		if (cnt) cnt.textContent = list.length + ' / ' + all.length + ' ' + _('entries');
	},

	refreshAuto: function () {
		var self = this;
		return callAutoGet().then(function (res) {
			self.auto = res || {};
			self.renderAuto();
		}).catch(function () {});
	},

	handleAutoToggle: function (ev) {
		var self = this;
		var on = ev.target.checked;
		return callAutoSet(on, this.auto.threshold, this.auto.window, this.auto.ttl)
			.then(function (res) {
				self.auto = res || self.auto;
				ui.addNotification(null, E('p', {},
					on ? _('Automatic blocking enabled') : _('Automatic blocking disabled')), 'info');
			}).catch(function (e) {
				ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error');
			});
	},

	handleAutoSave: function (ev) {
		var self = this;
		var t = document.getElementById('cb-auto-threshold');
		var w = document.getElementById('cb-auto-window');
		var l = document.getElementById('cb-auto-ttl');
		function trig(key) {
			var el = document.getElementById('cb-trig-' + key);
			return el && el.checked ? '1' : '0';
		}
		var btn = ev.currentTarget;
		btn.disabled = true;
		return callAutoSet(
				self.auto.enabled ? '1' : '0',
				t ? t.value : '', w ? w.value : '', l ? l.value : '',
				trig('ssh_password'), trig('ssh_user'), trig('web_auth'))
			.then(function (res) {
				if (res && res.success === false) throw new Error(res.error || _('Failed'));
				self.auto = res || self.auto;
				self.renderAuto();
				ui.addNotification(null, E('p', {}, _('Settings saved')), 'info');
			}).catch(function (e) {
				ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error');
			}).finally(function () {
				btn.disabled = false;
			});
	},

	handleScanNow: function (ev) {
		var self = this;
		var btn = ev.currentTarget;
		btn.disabled = true;
		return callScan().then(function (res) {
			var banned = (res && res.banned) || [];
			ui.addNotification(null, E('p', {}, banned.length
				? _('Blocked') + ' ' + banned.length + ': ' + banned.join(', ')
				: _('No new offenders')), 'info');
			return self.refreshIps();
		}).catch(function (e) {
			ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error');
		}).finally(function () {
			btn.disabled = false;
		});
	},

	renderAuto: function () {
		var box = document.getElementById('cb-auto-body');
		if (!box) return;
		while (box.firstChild) box.removeChild(box.firstChild);

		var a = this.auto || {};
		var self = this;
		var on = !!a.enabled;

		box.appendChild(E('label', { 'class': 'cb-switch' }, [
			E('input', {
				'type': 'checkbox',
				'checked': on ? 'checked' : null,
				'change': function (ev) { self.handleAutoToggle(ev); }
			}),
			E('span', { 'class': 'cb-track' }),
			E('span', {}, on ? _('Protection on') : _('Protection off'))
		]));

		var kinds = [
			{ key: 'ssh_password', label: _('SSH password failure'), code: 'Bad password / Max auth tries' },
			{ key: 'ssh_user',     label: _('SSH unknown user'),     code: 'nonexistent user' },
			{ key: 'web_auth',     label: _('LuCI login failure'),   code: 'failed login' }
		];
		var chips = E('div', { 'class': 'cb-triggers', 'id': 'cb-trigger-group' });
		kinds.forEach(function (k) {
			var checked = a[k.key] !== false;
			chips.appendChild(E('label', { 'class': 'cb-chip' + (checked ? ' on' : '') }, [
				E('input', {
					'type': 'checkbox',
					'id': 'cb-trig-' + k.key,
					'checked': checked ? 'checked' : null,
					'change': function (ev) {
						ev.target.parentNode.classList.toggle('on', ev.target.checked);
					}
				}),
				E('span', {}, k.label),
				E('span', { 'class': 'cb-chip-code' }, k.code)
			]));
		});

		box.appendChild(chips);
		box.appendChild(E('div', { 'class': 'cb-fields' }, [
			E('label', { 'class': 'cb-field' }, [
				E('span', {}, _('Trigger after')),
				E('input', { 'type': 'number', 'id': 'cb-auto-threshold', 'min': '1', 'max': '100',
					'value': a.threshold || 5 })
			]),
			E('label', { 'class': 'cb-field' }, [
				E('span', {}, _('Within (seconds)')),
				E('input', { 'type': 'number', 'id': 'cb-auto-window', 'min': '60', 'max': '86400',
					'value': a.window || 600 })
			]),
			E('label', { 'class': 'cb-field' }, [
				E('span', {}, _('Expire after (0 = never)')),
				E('input', { 'type': 'number', 'id': 'cb-auto-ttl', 'min': '0', 'max': '2592000',
					'value': a.ttl === 0 ? 0 : (a.ttl || 86400) })
			]),
			E('div', { 'class': 'cb-actions' }, [
				E('button', { 'class': 'cb-btn cb-btn-primary',
					'click': function (ev) { self.handleAutoSave(ev); } }, _('Save')),
				E('button', { 'class': 'cb-btn',
					'click': function (ev) { self.handleScanNow(ev); } }, _('Scan now'))
			])
		]));
	},

	refreshIps: function () {
		var self = this;
		return callIpList().then(function (res) {
			self.ips = (res && res.ips) || [];
			self.ipCount = (res && res.count) || 0;
			self.renderIps();
		}).catch(function () {
			self.renderIps();
		});
	},

	handleIpAdd: function (ev) {
		var self = this;
		var ipEl = document.getElementById('cb-ip-input');
		var noteEl = document.getElementById('cb-ip-note');
		if (!ipEl) return;
		var ip = (ipEl.value || '').trim();
		if (!ip) {
			ipEl.focus();
			return;
		}
		var btn = ev.currentTarget;
		btn.disabled = true;
		return callIpAdd(ip, (noteEl && noteEl.value) || '').then(function (res) {
			if (res && res.success === false)
				throw new Error(res.error || _('Failed'));
			ipEl.value = '';
			if (noteEl) noteEl.value = '';
			return self.refreshIps();
		}).catch(function (e) {
			ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error');
		}).finally(function () {
			btn.disabled = false;
		});
	},

	handleIpDel: function (ip, ev) {
		var self = this;
		var btn = ev.currentTarget;
		btn.disabled = true;
		return callIpDel(ip).then(function (res) {
			if (res && res.success === false)
				throw new Error(res.error || _('Failed'));
			return self.refreshIps();
		}).catch(function (e) {
			ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error');
			return self.refreshIps();
		});
	},

	handleIpFlush: function (ev) {
		var self = this;
		if (!confirm(_('Remove all blocked IPs?')))
			return;
		var btn = ev.currentTarget;
		btn.disabled = true;
		return callIpFlush().then(function () {
			return self.refreshIps();
		}).catch(function (e) {
			ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error');
			return self.refreshIps();
		});
	},

	renderIps: function () {
		var tbody = document.getElementById('cb-ip-tbody');
		if (!tbody) return;
		while (tbody.firstChild) tbody.removeChild(tbody.firstChild);

		var list = this.ips || [];
		var self = this;
		var q = (this.ipQuery || '').toLowerCase().trim();
		if (q)
			list = list.filter(function (r) {
				return (r.ip || '').toLowerCase().indexOf(q) !== -1 ||
					(r.note || '').toLowerCase().indexOf(q) !== -1;
			});

		if (!list.length) {
			var emptyCell = E('td', { 'colspan': 6, 'class': 'cb-empty' });
			if (q) {
				emptyCell.appendChild(document.createTextNode(_('No entries match the filter')));
			} else {
				emptyCell.appendChild(E('div', { 'style': 'font-weight:600;margin-bottom:.35rem' },
					_('No blocked IPs yet')));
				emptyCell.appendChild(E('div', {},
					_('Type an address above and press Block IP. Single addresses and CIDR ranges both work.')));
				emptyCell.appendChild(E('div', { 'style': 'margin-top:.9rem' },
					E('button', {
						'style': 'font-size:.78rem;padding:.15rem .5rem;opacity:.55;cursor:pointer;background:none;border:none;color:inherit;text-decoration:underline',
						'click': function () {
							var el = document.getElementById('cb-ip-input');
							if (el) el.focus();
						}
					}, _('Jump to the input field'))));
			}
			tbody.appendChild(E('tr', {}, emptyCell));
		}

		list.forEach(function (r) {
			tbody.appendChild(E('tr', {}, [
				E('td', { 'style': 'white-space:nowrap' }, [
					r.ip,
					' ',
					E('span', { 'class': 'cb-fam' }, '(IPv' + (r.family === 'ipv6' ? '6' : '4') + ')')
				].concat(
					r.source === 'auto'
						? [ ' ', E('span', { 'class': 'cb-src cb-src-auto' }, 'auto') ]
						: (r.source === 'watchdog'
							? [ ' ', E('span', { 'class': 'cb-src cb-src-watchdog' }, 'imported') ]
							: [])
				)),
				E('td', { 'style': 'font-size:.8rem;opacity:.85' }, fmtGeo(r.geo) || E('span', { 'class': 'cb-drop' }, '-')),
				E('td', {}, r.note || ''),
				E('td', { 'class': 'cb-drop' }, (r.drop_packets || 0) + ' pkt / ' + fmtBytes(r.drop_bytes)),
				E('td', { 'class': 'cb-drop' }, fmtTime(r.since)),
				E('td', { 'style': 'text-align:right' },
					E('button', {
						'class': 'cb-btn cb-btn-ok',
						'click': function (ev) { self.handleIpDel(r.ip, ev); }
					}, _('Unblock')))
			]));
		});

		var cnt = document.getElementById('cb-ip-count');
		if (cnt)
			cnt.textContent = (this.ipCount || 0) + ' ' + _('blocked');
	},

	switchTab: function (name) {
		this.tab = name;
		['devices', 'ips', 'logs'].forEach(function (t) {
			var pane = document.getElementById('cb-pane-' + t);
			var btn = document.getElementById('cb-tab-' + t);
			if (pane) pane.classList.toggle('active', t === name);
			if (btn) btn.classList.toggle('active', t === name);
		});
		if (name === 'ips') return this.refreshIps();
		if (name === 'logs') return this.refreshLogs();
	},

	renderTable: function () {
		var tbody = document.getElementById('cb-tbody');
		if (!tbody) return;
		while (tbody.firstChild) tbody.removeChild(tbody.firstChild);

		var rows = this.filterRows() || [];
		var self = this;

		if (!rows.length) {
			tbody.appendChild(E('tr', {}, E('td', { 'colspan': 6, 'class': 'cb-empty' },
				_('No devices match the filter'))));
		}

		rows.forEach(function (d) {
			var stateBadge = d.blocked
				? E('span', { 'class': 'cb-badge cb-badge-blocked' }, _('Blocked'))
				: (d.online
					? E('span', { 'class': 'cb-badge cb-badge-on' }, _('Online'))
					: E('span', { 'class': 'cb-badge cb-badge-off' }, _('Offline')));

			var action;
			if (d.blocked) {
				action = E('button', {
					'class': 'cb-btn cb-btn-ok',
					'click': function (ev) { self.handleUnblock(d, ev); }
				}, _('Unblock'));
			} else {
				action = E('button', {
					'class': 'cb-btn cb-btn-danger',
					'click': function (ev) { self.handleBlock(d, ev); }
				}, _('Block'));
			}

			var dropText = d.blocked
				? E('span', { 'class': 'cb-drop' },
					(d.drop_packets || 0) + ' pkt / ' + fmtBytes(d.drop_bytes))
				: '';

			var nameCell = d.blocked
				? E('a', {
					'href': '#',
					'title': _('Rename'),
					'style': 'color:inherit;text-decoration:none;border-bottom:1px dotted currentColor',
					'click': function (ev) {
						ev.preventDefault();
						self.handleRename(d);
					}
				}, d.host || _('(unnamed)'))
				: (d.host || E('span', { 'class': 'cb-mono' }, _('(unnamed)')));

			tbody.appendChild(E('tr', { 'class': d.blocked ? 'cb-blocked' : (d.online ? '' : 'cb-offline') }, [
				E('td', {}, stateBadge),
				E('td', {}, nameCell),
				E('td', { 'class': 'cb-mono' }, d.ip || '-'),
				E('td', { 'class': 'cb-mono' }, d.mac),
				E('td', {}, d.blocked ? [ dropText, E('br'), E('span', { 'class': 'cb-drop' }, fmtTime(d.blocked_at)) ] : ''),
				E('td', { 'style': 'text-align:right' }, action)
			]));
		});

		var cnt = document.getElementById('cb-count');
		if (cnt)
			cnt.textContent = (this.devices || []).length + ' ' + _('devices') + ', ' +
				(this.blockedCount || 0) + ' ' + _('blocked');
	},

	render: function (data) {
		this.devices = (data && data.devices) || [];
		this.blockedCount = (data && data.blocked_count) || 0;
		this.ips = (data && data.ips) || [];
		this.ipCount = (data && data.ip_count) || 0;
		this.auto = (data && data.auto) || {};
		this.logs = (data && data.logs) || [];
		this.logQuery = '';
		this.logKind = 'all';
		this.logResult = 'all';
		this.query = '';
		this.ipQuery = '';
		this.tab = 'devices';
		var self = this;

		var search = E('input', {
			'type': 'text',
			'placeholder': _('Filter by name, IP or MAC'),
			'value': this.query || '',
			'input': function (ev) {
				self.query = ev.target.value;
				self.renderTable();
			}
		});

		var rescanBtn = E('button', { 'class': 'cb-btn', 'click': function (ev) { self.handleProbe(ev); } },
			_('Rescan devices'));
		var unblockAllBtn = E('button', { 'class': 'cb-btn', 'click': function (ev) { self.handleUnblockAll(ev); } },
			_('Unblock all'));

		var ipSearch = E('input', {
			'type': 'text',
			'placeholder': _('Filter by IP or note'),
			'input': function (ev) {
				self.ipQuery = ev.target.value;
				self.renderIps();
			}
		});

		var ipInput = E('input', {
			'type': 'text',
			'class': 'cb-ip',
			'id': 'cb-ip-input',
			'placeholder': '1.2.3.4  /  1.2.3.0/24  /  2001:db8::1',
			'keydown': function (ev) { if (ev.key === 'Enter') self.handleIpAdd(ev); }
		});
		var ipNote = E('input', {
			'type': 'text',
			'class': 'cb-note',
			'id': 'cb-ip-note',
			'placeholder': _('Note (optional)'),
			'keydown': function (ev) { if (ev.key === 'Enter') self.handleIpAdd(ev); }
		});

		var tabBtn = function (name, label) {
			return E('button', {
				'class': 'cb-tab' + (name === 'devices' ? ' active' : ''),
				'id': 'cb-tab-' + name,
				'click': function () { self.switchTab(name); }
			}, label);
		};

		var devicesPane = E('div', {
			'class': 'cb-pane active',
			'id': 'cb-pane-devices'
		}, [
			E('p', { 'style': 'opacity:.75;margin:.25rem 0 1rem' },
				_('Blocked devices lose all traffic through this router: Internet, DNS, DHCP and gateway services. Their packets are dropped at every interface.')),
			E('div', { 'class': 'cb-toolbar' }, [
				search,
				rescanBtn,
				unblockAllBtn,
				E('span', { 'class': 'cb-count', 'id': 'cb-count' }, '')
			]),
			E('table', { 'class': 'cb-table' }, [
				E('thead', {}, E('tr', {}, [
					E('th', {}, _('Status')),
					E('th', {}, _('Name')),
					E('th', {}, _('IP')),
					E('th', {}, _('MAC')),
					E('th', {}, _('Dropped')),
					E('th', { 'style': 'text-align:right' }, _('Action'))
				])),
				E('tbody', { 'id': 'cb-tbody' })
			])
		]);

		var ipsPane = E('div', {
			'class': 'cb-pane',
			'id': 'cb-pane-ips'
		}, [
			E('p', { 'style': 'opacity:.75;margin:.25rem 0 1rem' },
				_('Blocked addresses cannot be reached from your LAN, and cannot reach it. Both directions are dropped. CIDR ranges are supported.')),
			E('div', { 'class': 'cb-card' }, [
				E('div', { 'class': 'cb-card-head' }, [
					E('span', { 'class': 'cb-dot' }),
					E('span', {}, _('Automatic protection'))
				]),
				E('div', { 'class': 'cb-card-body' }, [
					E('div', { 'class': 'cb-auto-body', 'id': 'cb-auto-body' }),
					E('div', { 'class': 'cb-card-hint', 'style': 'margin-top:.75rem' },
						_('A source is blocked once it produces the selected failures often enough within the window. Detection is live, not polled.'))
				])
			]),
			E('div', { 'style': 'display:flex;gap:.35rem;flex-wrap:wrap;margin-bottom:.6rem' }, [
				E('span', { 'style': 'font-size:.8rem;opacity:.6;align-self:center' }, _('Quick fill:')),
				E('button', {
					'class': 'cb-btn', 'style': 'font-size:.75rem;padding:.15rem .5rem',
					'click': function () { document.getElementById('cb-ip-input').value = '1.1.1.1'; }
				}, '1.1.1.1'),
				E('button', {
					'class': 'cb-btn', 'style': 'font-size:.75rem;padding:.15rem .5rem',
					'click': function () { document.getElementById('cb-ip-input').value = '8.8.8.8'; }
				}, '8.8.8.8'),
				E('button', {
					'class': 'cb-btn', 'style': 'font-size:.75rem;padding:.15rem .5rem',
					'click': function () { document.getElementById('cb-ip-input').value = '1.2.3.0/24'; document.getElementById('cb-ip-input').focus(); }
				}, '1.2.3.0/24')
			]),
			E('div', { 'class': 'cb-ipform' }, [
				ipInput,
				ipNote,
				E('button', { 'class': 'cb-btn', 'click': function (ev) { self.handleIpAdd(ev); } }, _('Block IP')),
				E('button', { 'class': 'cb-btn cb-btn-danger', 'click': function (ev) { self.handleIpFlush(ev); } }, _('Unblock all'))
			]),
			E('div', { 'class': 'cb-toolbar' }, [
				ipSearch,
				E('span', { 'class': 'cb-count', 'id': 'cb-ip-count' }, '')
			]),
			E('table', { 'class': 'cb-table' }, [
				E('thead', {}, E('tr', {}, [
					E('th', {}, _('Address')),
					E('th', {}, _('Region')),
					E('th', {}, _('Note')),
					E('th', {}, _('Dropped')),
					E('th', {}, _('Since')),
					E('th', { 'style': 'text-align:right' }, _('Action'))
				])),
				E('tbody', { 'id': 'cb-ip-tbody' })
			])
		]);

		var logsPane = E('div', {
			'class': 'cb-pane',
			'id': 'cb-pane-logs'
		}, [
			E('p', { 'style': 'opacity:.75;margin:.25rem 0 1rem' },
				_('Every successful and failed login through SSH or LuCI, newest first. Kept in memory-backed storage, capped at 500 entries.')),
			E('div', { 'class': 'cb-log-filters' }, [
				E('input', {
					'type': 'text',
					'placeholder': _('Filter by IP, user or detail'),
					'input': function (ev) { self.logQuery = ev.target.value; self.renderLogs(); }
				}),
				E('select', {
					'change': function (ev) { self.logKind = ev.target.value; self.renderLogs(); }
				}, [
					E('option', { 'value': 'all' }, _('All sources')),
					E('option', { 'value': 'ssh' }, 'SSH'),
					E('option', { 'value': 'web' }, 'LuCI')
				]),
				E('select', {
					'change': function (ev) { self.logResult = ev.target.value; self.renderLogs(); }
				}, [
					E('option', { 'value': 'all' }, _('All results')),
					E('option', { 'value': 'ok' }, _('Success only')),
					E('option', { 'value': 'fail' }, _('Failures only'))
				]),
				E('span', { 'class': 'cb-count', 'id': 'cb-log-count' }, ''),
				E('button', { 'class': 'cb-btn cb-btn-danger',
					'click': function (ev) { self.handleLogClear(ev); } }, _('Clear log'))
			]),
			E('table', { 'class': 'cb-table cb-log' }, [
				E('thead', {}, E('tr', {}, [
					E('th', {}, _('Time')),
					E('th', {}, _('Result')),
					E('th', {}, _('Source')),
					E('th', {}, _('Auth')),
					E('th', {}, _('IP')),
					E('th', {}, _('User')),
					E('th', {}, _('Detail'))
				])),
				E('tbody', { 'id': 'cb-log-tbody' })
			])
		]);

		var root = E('div', { 'class': 'cb-wrap' }, [
			E('style', {}, STYLE),
			E('h2', {}, _('Client Access Control')),
			E('div', { 'class': 'cb-tabs' }, [
				tabBtn('devices', _('Devices')),
				tabBtn('ips', _('External IPs')),
				tabBtn('logs', _('Login log'))
			]),
			devicesPane,
			ipsPane,
			logsPane
		]);

		window.setTimeout(function () {
			self.renderTable();
			self.renderAuto();
			self.renderLogs();
		}, 0);

		poll.add(function () {
			// a hidden tab has no business polling
			if (document.hidden) return;
			if (self.tab === 'ips') return self.refreshIps();
			if (self.tab === 'logs') return self.refreshLogs();
			return self.refresh();
		}, 10);

		return root;
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
