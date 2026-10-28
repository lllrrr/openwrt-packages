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

var callDashboard = rpc.declare({ object: 'luci.clientblock', method: 'dashboard' });
var callTrend = rpc.declare({ object: 'luci.clientblock', method: 'trend' });
var callPanicState = rpc.declare({ object: 'luci.clientblock', method: 'panicstate' });
var callPanic = rpc.declare({ object: 'luci.clientblock', method: 'panic', params: ['on_'] });
var callKnownAdd = rpc.declare({ object: 'luci.clientblock', method: 'knownadd', params: ['mac'] });
var callKnownList = rpc.declare({ object: 'luci.clientblock', method: 'knownlist' });
var callWlList = rpc.declare({ object: 'luci.clientblock', method: 'wllist' });
var callWlAdd = rpc.declare({ object: 'luci.clientblock', method: 'wladd', params: ['mac'] });
var callWlDel = rpc.declare({ object: 'luci.clientblock', method: 'wldel', params: ['mac'] });
var callFeedList = rpc.declare({ object: 'luci.clientblock', method: 'feedlist' });
var callFeedAdd = rpc.declare({ object: 'luci.clientblock', method: 'feedadd', params: ['name', 'url'] });
var callFeedDel = rpc.declare({ object: 'luci.clientblock', method: 'feeddel', params: ['id'] });
var callFeedRefresh = rpc.declare({ object: 'luci.clientblock', method: 'feedrefresh', params: ['id'] });
var callPortPresets = rpc.declare({ object: 'luci.clientblock', method: 'portpresets' });
var callPortTemplate = rpc.declare({ object: 'luci.clientblock', method: 'porttemplate', params: ['macs', 'preset'] });
var callExport = rpc.declare({ object: 'luci.clientblock', method: 'exportconfig' });
var callImport = rpc.declare({ object: 'luci.clientblock', method: 'importconfig', params: ['payload'] });

var callGroupList = rpc.declare({ object: 'luci.clientblock', method: 'grouplist' });
var callGroupAdd = rpc.declare({ object: 'luci.clientblock', method: 'groupadd', params: ['name', 'macs'] });
var callGroupDel = rpc.declare({ object: 'luci.clientblock', method: 'groupdel', params: ['id'] });
var callGroupSet = rpc.declare({ object: 'luci.clientblock', method: 'groupset', params: ['id', 'macs'] });
var callCurfew = rpc.declare({ object: 'luci.clientblock', method: 'curfew', params: ['id', 'minutes'] });
var callPortList = rpc.declare({ object: 'luci.clientblock', method: 'portlist' });
var callPortAdd = rpc.declare({ object: 'luci.clientblock', method: 'portadd', params: ['mac', 'proto', 'port', 'note'] });
var callPortDel = rpc.declare({ object: 'luci.clientblock', method: 'portdel', params: ['id'] });

var callNotifyGet = rpc.declare({ object: 'luci.clientblock', method: 'notifyget' });
var callNotifyAdd = rpc.declare({ object: 'luci.clientblock', method: 'notifyadd',
	params: ['type_', 'name', 'url', 'token', 'chat'] });
var callNotifyDel = rpc.declare({ object: 'luci.clientblock', method: 'notifydel', params: ['id'] });
var callNotifyToggle = rpc.declare({ object: 'luci.clientblock', method: 'notifytoggle', params: ['id', 'enabled'] });
var callNotifyEvents = rpc.declare({ object: 'luci.clientblock', method: 'notifyevents', params: ['events'] });
var callNotifyTest = rpc.declare({ object: 'luci.clientblock', method: 'notifytest', params: ['id'] });

var callSchedList = rpc.declare({
	object: 'luci.clientblock',
	method: 'schedlist'
});

var callSchedAdd = rpc.declare({
	object: 'luci.clientblock',
	method: 'schedadd',
	params: ['mac', 'days', 'start', 'stop', 'name']
});

var callSchedDel = rpc.declare({
	object: 'luci.clientblock',
	method: 'scheddel',
	params: ['id']
});

var callSchedToggle = rpc.declare({
	object: 'luci.clientblock',
	method: 'schedtoggle',
	params: ['id', 'enabled']
});

var callSelfCheck = rpc.declare({
	object: 'luci.clientblock',
	method: 'selfcheck'
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

/* ---- dashboard ---- */
.cb-stats { display: grid; grid-template-columns: repeat(auto-fit, minmax(10.5rem, 1fr));
	gap: .7rem; margin-bottom: 1rem; }
.cb-stat { border: 1px solid var(--hairline); border-radius: .55rem;
	padding: .75rem .9rem; background: var(--surface); }
.cb-stat .cb-n { font-size: 1.55rem; font-weight: 700; line-height: 1.15;
	font-family: var(--font-mono); font-variant-numeric: tabular-nums; }
.cb-stat .cb-l { font-size: .75rem; color: var(--text-muted); margin-top: .15rem; }
.cb-stat.accent .cb-n { color: var(--brand); }
.cb-stat.ok .cb-n { color: var(--success); }
.cb-stat.warn .cb-n { color: var(--danger); }
.cb-dash-rows { display: grid; gap: 0; }
.cb-dash-row { display: flex; gap: .6rem; align-items: baseline; font-size: .85rem;
	padding: .34rem 0; border-bottom: 1px solid var(--hairline); }
.cb-dash-row:last-child { border-bottom: none; }
.cb-dash-row .cb-k { min-width: 10rem; color: var(--text-muted); }
.cb-dash-row .cb-v { font-weight: 600; font-family: var(--font-mono); font-size: .82rem; }
.cb-fail-list { margin-top: .6rem; display: grid; gap: .3rem; }
.cb-fail-item { font-size: .8rem; color: var(--danger); }

/* ---- trend chart ---- */
.cb-trend { display: flex; gap: 2px; align-items: flex-end; height: 4.5rem;
	padding: .5rem .2rem 0; border-bottom: 1px solid var(--hairline); }
.cb-trend .cb-bar { flex: 1; min-height: 2px; border-radius: 2px 2px 0 0;
	background: var(--hover-faint); }
.cb-trend .cb-bar.has { background: var(--danger); opacity: .85; }
.cb-trend-legend { display: flex; justify-content: space-between; font-size: .7rem;
	color: var(--text-subtle); margin-top: .25rem; }
.cb-trusted { background: var(--info-surface); color: var(--info); }
.cb-vendor { max-width: 20rem; overflow: hidden; text-overflow: ellipsis;
	white-space: nowrap; margin-top: .1rem; }

/* ---- schedule ---- */
.cb-sched-form { display: flex; flex-wrap: wrap; gap: .55rem; align-items: flex-end;
	padding: .8rem .9rem; border: 1px solid var(--hairline); border-radius: .55rem;
	background: var(--surface); margin-bottom: 1rem; }
.cb-sched-form label { display: flex; flex-direction: column; gap: .25rem; }
.cb-sched-form label > span { font-size: .74rem; color: var(--text-muted); }
.cb-sched-form select, .cb-sched-form input[type=time] {
	padding: .35rem .5rem; border-radius: .3rem; border: 1px solid var(--hairline);
	background: var(--surface-sunken); color: inherit; font-size: .85rem; }
.cb-days { display: flex; gap: .25rem; }
.cb-dchip { width: 1.9rem; height: 1.9rem; display: flex; align-items: center; justify-content: center;
	border: 1px solid var(--hairline); border-radius: .3rem; cursor: pointer;
	font-size: .78rem; user-select: none; color: var(--text-muted); }
.cb-dchip.on { background: var(--brand-subtle); border-color: var(--brand); color: var(--text); font-weight: 600; }
.cb-sched-on { background: var(--danger-surface); color: var(--danger); }
.cb-sched-idle { background: var(--hover-faint); color: var(--text-muted); }

/* ---- health ---- */
.cb-health-head { display: flex; align-items: center; gap: .6rem; margin-bottom: .9rem; }
.cb-health-ok { background: var(--success-surface); color: var(--success); }
.cb-health-bad { background: var(--danger-surface); color: var(--danger); }
.cb-checks { display: grid; gap: .45rem; }
.cb-check { display: grid; grid-template-columns: 1.2rem 12rem 1fr; gap: .6rem;
	align-items: baseline; padding: .45rem .6rem; border-radius: .35rem;
	background: var(--surface-sunken); font-size: .85rem; }
.cb-check.bad { background: var(--danger-surface); }
.cb-check .cb-mark { font-weight: 700; text-align: center; }
.cb-check .cb-mark.ok { color: var(--success); }
.cb-check .cb-mark.bad { color: var(--danger); }
.cb-check .cb-name { font-weight: 600; }
.cb-check .cb-val { color: var(--text-muted); font-family: var(--font-mono); font-size: .8rem; }
.cb-check .cb-hint { grid-column: 2 / 4; color: var(--danger); font-size: .78rem; }

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

function typeLabel(t) {
	var m = {
		phone: _('phone'), tablet: _('tablet'), computer: _('computer'),
		tv: _('TV'), camera: _('camera'), speaker: _('speaker'),
		printer: _('printer'), console: _('console'), network: _('network gear'),
		server: _('server'), iot: _('smart device'), wearable: _('wearable'),
		apple: _('Apple device'), unknown: _('unknown')
	};
	return m[t] || _('unknown');
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
		return Promise.all([ callList('1'), callIpList(), callAutoGet(), callLogList('500'), callSchedList() ])
			.then(function (r) {
			var dev = r[0] || {}, ips = r[1] || {}, auto = r[2] || {}, logs = r[3] || {}, sc = r[4] || {};
			dev.ips = ips.ips || [];
			dev.ip_count = ips.count || 0;
			dev.auto = auto;
			dev.logs = logs.entries || [];
			dev.sched = sc.rules || [];
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

	refreshNotify: function () {
		var self = this;
		return callNotifyGet().then(function (res) {
			self.notify = res || {};
			self.renderNotify();
		}).catch(function () { self.renderNotify(); });
	},

	handleNotifyAdd: function (ev) {
		var self = this;
		var g = function (id) { var e = document.getElementById(id); return e ? e.value : ''; };
		var type = g('cb-nt-type');
		var btn = ev.currentTarget;
		btn.disabled = true;
		return callNotifyAdd(type, g('cb-nt-name'), g('cb-nt-url'), g('cb-nt-token'), g('cb-nt-chat'))
			.then(function (res) {
				if (res && res.success === false) throw new Error(res.error || _('Failed'));
				return self.refreshNotify();
			}).catch(function (e) {
				ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error');
			}).finally(function () { btn.disabled = false; });
	},

	handleNotifyDel: function (id, ev) {
		var self = this;
		ev.currentTarget.disabled = true;
		return callNotifyDel(id).then(function () { return self.refreshNotify(); })
			.catch(function (e) { ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error'); });
	},

	handleNotifyToggle: function (ch, ev) {
		var self = this;
		return callNotifyToggle(ch.id, ch.enabled ? '0' : '1')
			.then(function () { return self.refreshNotify(); });
	},

	handleNotifyTest: function (ch, ev) {
		var self = this;
		var btn = ev.currentTarget;
		btn.disabled = true;
		return callNotifyTest(ch.id).then(function (res) {
			if (res && res.success === false) throw new Error(res.error || _('Send failed'));
			ui.addNotification(null, E('p', {}, _('Test message sent')), 'info');
		}).catch(function (e) {
			ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error');
		}).finally(function () { btn.disabled = false; });
	},

	handleNotifyEvents: function (ev) {
		var self = this;
		var picked = [];
		document.querySelectorAll('#cb-nt-events .cb-dchip.on').forEach(function (d) {
			picked.push(d.getAttribute('data-event'));
		});
		return callNotifyEvents(picked.join(',')).then(function () {
			ui.addNotification(null, E('p', {}, _('Saved')), 'info');
			return self.refreshNotify();
		}).catch(function (e) {
			ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error');
		});
	},

	renderNotify: function () {
		var tbody = document.getElementById('cb-nt-tbody');
		if (!tbody) return;
		while (tbody.firstChild) tbody.removeChild(tbody.firstChild);

		var self = this;
		var n = this.notify || {};
		var list = n.channels || [];

		if (!list.length) {
			tbody.appendChild(E('tr', {}, E('td', { 'colspan': 4, 'class': 'cb-empty' },
				_('No notification channels yet'))));
		}

		list.forEach(function (c) {
			var target = c.type === 'telegram'
				? ('chat ' + (c.chat || '?'))
				: (c.url || '');
			tbody.appendChild(E('tr', {}, [
				E('td', {}, E('span', { 'class': 'cb-res ' + (c.enabled ? 'cb-health-ok' : 'cb-sched-idle') },
					c.type)),
				E('td', { 'class': 'cb-u' }, c.name || ''),
				E('td', { 'class': 'cb-val', 'style': 'font-size:.78rem;color:var(--text-muted)' },
					String(target).slice(0, 48)),
				E('td', { 'style': 'text-align:right;white-space:nowrap' }, [
					E('button', { 'class': 'cb-btn', 'style': 'margin-right:.3rem',
						'click': function (ev) { self.handleNotifyTest(c, ev); } }, _('Test')),
					E('button', { 'class': 'cb-btn', 'style': 'margin-right:.3rem',
						'click': function (ev) { self.handleNotifyToggle(c, ev); } },
						c.enabled ? _('Pause') : _('Resume')),
					E('button', { 'class': 'cb-btn cb-btn-danger',
						'click': function (ev) { self.handleNotifyDel(c.id, ev); } }, _('Delete'))
				])
			]));
		});

		// event chips
		var evBox = document.getElementById('cb-nt-events');
		if (evBox) {
			while (evBox.firstChild) evBox.removeChild(evBox.firstChild);
			var labels = { auto_block: _('Auto block'), new_device: _('New device'), expire: _('Block expired') };
			(n.event_names || []).forEach(function (e) {
				var on = n.events && n.events[e];
				evBox.appendChild(E('div', { 'class': 'cb-dchip' + (on ? ' on' : ''), 'data-event': e,
					'style': 'width:auto;padding:0 .6rem',
					'click': function (ev) { ev.currentTarget.classList.toggle('on'); } }, labels[e] || e));
			});
		}
	},

	refreshDash: function () {
		var self = this;
		return Promise.all([ callDashboard(), callTrend() ]).then(function (r) {
			self.dash = r[0] || {};
			self.trend = r[1] || {};
			self.renderDash();
		}).catch(function () { self.renderDash(); });
	},

	renderDash: function () {
		var box = document.getElementById('cb-dash-body');
		if (!box) return;
		while (box.firstChild) box.removeChild(box.firstChild);

		var d = this.dash || {};
		var self = this;
		function card(n, label, cls) {
			return E('div', { 'class': 'cb-stat' + (cls ? ' ' + cls : '') }, [
				E('div', { 'class': 'cb-n' }, String(n == null ? '-' : n)),
				E('div', { 'class': 'cb-l' }, label)
			]);
		}
		function row(k, v) {
			return E('div', { 'class': 'cb-dash-row' }, [
				E('span', { 'class': 'cb-k' }, k),
				E('span', { 'class': 'cb-v' }, String(v))
			]);
		}

		box.appendChild(E('div', { 'class': 'cb-stats' }, [
			card(d.devices_online, _('Devices online'), 'ok'),
			card(d.devices_blocked, _('Devices blocked'), d.devices_blocked ? 'warn' : ''),
			card(d.ips_blocked, _('Blocked IPs'), d.ips_blocked ? 'accent' : ''),
			card(d.logins_fail_today, _('Login failures today'), d.logins_fail_today ? 'warn' : '')
		]));

		box.appendChild(E('div', { 'class': 'cb-card' }, [
			E('div', { 'class': 'cb-card-head' }, [
				E('span', { 'class': 'cb-dot' }), E('span', {}, _('Login failures, last 24 hours'))
			]),
			E('div', { 'class': 'cb-card-body' }, [
				E('div', { 'class': 'cb-trend', 'id': 'cb-trend' }),
				E('div', { 'class': 'cb-trend-legend' }, [
					E('span', {}, '-24h'),
					E('span', {}, _('now'))
				])
			])
		]));

		box.appendChild(E('div', { 'class': 'cb-card' }, [
			E('div', { 'class': 'cb-card-head' }, [
				E('span', { 'class': 'cb-dot' }), E('span', {}, _('Protection'))
			]),
			E('div', { 'class': 'cb-card-body' }, E('div', { 'class': 'cb-dash-rows' }, [
				row(_('Automatic protection'), d.auto_enabled
					? (_('on') + ' · ' + (d.threshold || '-') + ' / ' + (d.window || '-') + 's')
					: _('off')),
				row(_('Blocked addresses from auto-block'), (d.ips_auto || 0)),
				row(_('Schedule rules'), (d.schedules || 0) + ' (' + (d.schedules_active || 0) + ' ' + _('active now') + ')'),
				row(_('Trusted devices'), d.trusted || 0),
				row(_('New devices awaiting review'), d.pending || 0),
				row(_('Groups'), d.groups || 0),
				row(_('Port restrictions'), d.ports || 0),
				row(_('Notification channels'), d.channels || 0),
				row(_('Logins today'), (d.logins_ok_today || 0) + ' ' + _('ok') + ' · ' + (d.logins_fail_today || 0) + ' ' + _('failed')),
				row(_('Failures in last 24h'), d.logins_fail_24h || 0),
				E('div', { 'style': 'margin-top:.8rem;display:flex;gap:.5rem;flex-wrap:wrap' }, [
					E('button', { 'class': 'cb-btn cb-btn-danger',
						'click': function (ev) { self.handlePanic(true, ev); } }, _('Block new devices only')),
					E('button', { 'class': 'cb-btn',
						'click': function (ev) { self.handlePanic(false, ev); } }, _('Release'))
				])
			]))
		]));

		var healthCard = E('div', { 'class': 'cb-card' }, [
			E('div', { 'class': 'cb-card-head' }, [
				E('span', { 'class': 'cb-dot' }), E('span', {}, _('Health'))
			]),
			E('div', { 'class': 'cb-card-body' }, (function () {
				var wrap = E('div', {});
				wrap.appendChild(E('span', { 'class': 'cb-res ' + (d.health_ok ? 'cb-health-ok' : 'cb-health-bad') },
					d.health_ok ? _('all checks passed') : _('attention needed')));
				if (!d.health_ok && (d.health_failing || []).length) {
					var list = E('div', { 'class': 'cb-fail-list' });
					d.health_failing.forEach(function (c) {
						list.appendChild(E('div', { 'class': 'cb-fail-item' }, '✕ ' + (c.detail || c.id)));
					});
					wrap.appendChild(list);
				}
				wrap.appendChild(E('div', { 'style': 'margin-top:.7rem' },
					E('button', { 'class': 'cb-btn cb-btn-primary',
						'click': function (ev) { self.refreshDash(); } }, _('Refresh'))));
				return wrap;
			})())
		]);
		box.appendChild(healthCard);

		if ((d.recent || []).length) {
			var rl = E('div', { 'class': 'cb-dash-rows' });
			d.recent.forEach(function (e) {
				var label = e.result === 'success' ? _('login ok')
					: (e.result === 'failure' ? _('login failed') : _('session closed'));
				rl.appendChild(E('div', { 'class': 'cb-dash-row' }, [
					E('span', { 'class': 'cb-k' }, fmtTime(e.ts)),
					E('span', { 'class': 'cb-v' }, (e.kind || '') + ' · ' + label)
				]));
			});
			box.appendChild(E('div', { 'class': 'cb-card' }, [
				E('div', { 'class': 'cb-card-head' }, [
					E('span', { 'class': 'cb-dot' }), E('span', {}, _('Recent activity'))
				]),
				E('div', { 'class': 'cb-card-body' }, rl)
			]));
		}

		// the chart markup is rebuilt above, so paint it now
		self.renderTrend();
	},

	refreshFeeds: function () {
		var self = this;
		return callFeedList().then(function (res) {
			self.feeds = (res && res.feeds) || [];
			self.renderFeeds();
		}).catch(function () { self.renderFeeds(); });
	},

	handleFeedAdd: function (ev) {
		var self = this;
		var n = (document.getElementById('cb-feed-name') || {}).value || '';
		var u = (document.getElementById('cb-feed-url') || {}).value || '';
		if (!u) { ui.addNotification(null, E('p', {}, _('List URL is required')), 'warning'); return; }
		var btn = ev.currentTarget; btn.disabled = true;
		return callFeedAdd(n, u).then(function (res) {
			if (res && res.success === false) throw new Error(res.error || _('Failed'));
			document.getElementById('cb-feed-url').value = '';
			return self.refreshFeeds();
		}).catch(function (e) {
			ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error');
		}).finally(function () { btn.disabled = false; });
	},

	handleFeedRefresh: function (f, ev) {
		var self = this;
		var btn = ev.currentTarget;
		btn.disabled = true; btn.textContent = _('Fetching…');
		return callFeedRefresh(f.id).then(function (res) {
			if (res && res.success === false) throw new Error(res.error || _('Failed'));
			ui.addNotification(null, E('p', {}, _('Imported') + ' ' + (res.added || 0) + ', ' + _('removed') + ' ' + (res.removed || 0)), 'info');
			return Promise.all([ self.refreshFeeds(), self.refreshIps() ]);
		}).catch(function (e) {
			ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error');
		}).finally(function () { btn.disabled = false; btn.textContent = _('Fetch'); });
	},

	handleFeedDel: function (f, ev) {
		var self = this;
		ev.currentTarget.disabled = true;
		return callFeedDel(f.id).then(function () { return Promise.all([ self.refreshFeeds(), self.refreshIps() ]); })
			.catch(function (e) { ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error'); });
	},

	renderFeeds: function () {
		var tbody = document.getElementById('cb-feed-tbody');
		if (!tbody) return;
		while (tbody.firstChild) tbody.removeChild(tbody.firstChild);
		var self = this;
		var list = this.feeds || [];
		if (!list.length) {
			tbody.appendChild(E('tr', {}, E('td', { 'colspan': 4, 'class': 'cb-empty' },
				_('No subscriptions yet'))));
			return;
		}
		list.forEach(function (f) {
			tbody.appendChild(E('tr', {}, [
				E('td', { 'class': 'cb-u' }, f.name || ''),
				E('td', { 'class': 'cb-t' }, String(f.imported || 0)),
				E('td', { 'style': 'font-size:.78rem;color:var(--text-muted)' },
					f.last ? fmtTime(f.last) : _('never')),
				E('td', { 'style': 'text-align:right;white-space:nowrap' }, [
					E('button', { 'class': 'cb-btn', 'style': 'margin-right:.3rem',
						'click': function (ev) { self.handleFeedRefresh(f, ev); } }, _('Fetch')),
					E('button', { 'class': 'cb-btn cb-btn-danger',
						'click': function (ev) { self.handleFeedDel(f, ev); } }, _('Delete'))
				])
			]));
		});
	},

	refreshTrend: function () {
		var self = this;
		return callTrend().then(function (res) {
			self.trend = res || {};
			self.renderTrend();
		}).catch(function () {});
	},

	renderTrend: function () {
		var box = document.getElementById('cb-trend');
		if (!box) return;
		while (box.firstChild) box.removeChild(box.firstChild);
		var h = (this.trend && this.trend.hourly) || [];
		if (!h.length) return;
		var max = 1;
		h.forEach(function (p) { if (p.fail > max) max = p.fail; });
		h.forEach(function (p) {
			var pct = Math.max(2, Math.round((p.fail / max) * 100));
			box.appendChild(E('div', {
				'class': 'cb-bar' + (p.fail ? ' has' : ''),
				'style': 'height:' + pct + '%',
				'title': (24 - p.ago) + 'h ago · ' + p.fail + ' ' + _('failures') + ' / ' + p.ok + ' ' + _('ok')
			}));
		});
	},

	handlePanic: function (on, ev) {
		var self = this;
		var btn = ev.currentTarget;
		btn.disabled = true;
		return callPanic(on ? '1' : '0').then(function (res) {
			if (res && res.success === false) throw new Error(res.error || _('Failed'));
			ui.addNotification(null, E('p', {}, on
				? _('Locked down') + ' · ' + (res.blocked || 0) + ' ' + _('devices')
				: _('Lockdown released')), 'info');
			return Promise.all([ self.refreshDash(), self.refresh() ]);
		}).catch(function (e) {
			ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error');
		}).finally(function () { btn.disabled = false; });
	},

	handleAccept: function (dev, ev) {
		var self = this;
		var btn = ev.currentTarget;
		btn.disabled = true;
		return callKnownAdd(dev.mac).then(function (res) {
			if (res && res.success === false) throw new Error(res.error || _('Failed'));
			ui.addNotification(null, E('p', {}, _('Device accepted')), 'info');
			return self.refresh();
		}).catch(function (e) {
			ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error');
		}).finally(function () { btn.disabled = false; });
	},

	handleTrust: function (dev, ev) {
		var self = this;
		var btn = ev.currentTarget;
		btn.disabled = true;
		var call = dev.trusted ? callWlDel : callWlAdd;
		return call(dev.mac).then(function (res) {
			if (res && res.success === false) throw new Error(res.error || _('Failed'));
			return self.refresh();
		}).catch(function (e) {
			ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error');
		}).finally(function () { btn.disabled = false; });
	},

	handleExport: function (ev) {
		var btn = ev.currentTarget; btn.disabled = true;
		return callExport().then(function (res) {
			var ta = document.getElementById('cb-backup-text');
			if (ta) ta.value = JSON.stringify(res, null, 1);
			ui.addNotification(null, E('p', {}, _('Backup written to the box below')), 'info');
		}).catch(function (e) {
			ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error');
		}).finally(function () { btn.disabled = false; });
	},

	handleImport: function (ev) {
		var self = this;
		var ta = document.getElementById('cb-backup-text');
		var payload = ta ? ta.value.trim() : '';
		if (!payload) { ui.addNotification(null, E('p', {}, _('Paste a backup first')), 'warning'); return; }
		if (!confirm(_('Replace all lists and rules with this backup?'))) return;
		var btn = ev.currentTarget; btn.disabled = true;
		return callImport(payload).then(function (res) {
			if (res && res.success === false) throw new Error(res.error || _('Failed'));
			ui.addNotification(null, E('p', {}, _('Restored') + ' ' + (res.imported || 0) + ' ' + _('sections')), 'info');
			return Promise.all([ self.refresh(), self.refreshIps(), self.refreshDash() ]);
		}).catch(function (e) {
			ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error');
		}).finally(function () { btn.disabled = false; });
	},

	handlePortPreset: function (ev) {
		var self = this;
		var mac = (document.getElementById('cb-port-mac') || {}).value || '';
		var preset = (document.getElementById('cb-port-preset') || {}).value || 'iot';
		if (!mac) { ui.addNotification(null, E('p', {}, _('Pick a device')), 'warning'); return; }
		var btn = ev.currentTarget; btn.disabled = true;
		return callPortTemplate(mac, preset).then(function (res) {
			if (res && res.success === false) throw new Error(res.error || _('Failed'));
			ui.addNotification(null, E('p', {}, _('Added') + ' ' + (res.added || 0) + ' ' + _('rules')), 'info');
			return self.refreshPorts();
		}).catch(function (e) {
			ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error');
		}).finally(function () { btn.disabled = false; });
	},

	refreshPorts: function () {
		var self = this;
		return callPortList().then(function (res) {
			self.ports = (res && res.rules) || [];
			self.renderPorts();
		}).catch(function () { self.renderPorts(); });
	},

	refreshGroups: function () {
		var self = this;
		return callGroupList().then(function (res) {
			self.groups = (res && res.groups) || [];
			self.renderGroups();
		}).catch(function () { self.renderGroups(); });
	},

	handlePortAdd: function (ev) {
		var self = this;
		var mac = (document.getElementById('cb-port-mac') || {}).value || '';
		var proto = (document.getElementById('cb-port-proto') || {}).value || 'tcp';
		var port = (document.getElementById('cb-port-num') || {}).value || '';
		var note = (document.getElementById('cb-port-note') || {}).value || '';
		if (!mac) { ui.addNotification(null, E('p', {}, _('Pick a device')), 'warning'); return; }
		var btn = ev.currentTarget; btn.disabled = true;
		return callPortAdd(mac, proto, port, note).then(function (res) {
			if (res && res.success === false) throw new Error(res.error || _('Failed'));
			return self.refreshPorts();
		}).catch(function (e) {
			ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error');
		}).finally(function () { btn.disabled = false; });
	},

	handlePortDel: function (id, ev) {
		var self = this;
		ev.currentTarget.disabled = true;
		return callPortDel(id).then(function () { return self.refreshPorts(); })
			.catch(function (e) { ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error'); });
	},

	renderPorts: function () {
		var tbody = document.getElementById('cb-port-tbody');
		if (!tbody) return;
		while (tbody.firstChild) tbody.removeChild(tbody.firstChild);
		var self = this;

		var sel = document.getElementById('cb-port-mac');
		if (sel) {
			var keep = sel.value;
			while (sel.firstChild) sel.removeChild(sel.firstChild);
			(this.devices || []).forEach(function (d) {
				sel.appendChild(E('option', { 'value': d.mac }, (d.host || d.mac) + (d.ip ? '  ' + d.ip : '')));
			});
			if (keep) sel.value = keep;
		}

		var list = this.ports || [];
		if (!list.length) {
			tbody.appendChild(E('tr', {}, E('td', { 'colspan': 4, 'class': 'cb-empty' },
				_('No port restrictions yet'))));
			return;
		}
		list.forEach(function (r) {
			tbody.appendChild(E('tr', {}, [
				E('td', { 'class': 'cb-u' }, r.host || r.mac),
				E('td', { 'class': 'cb-t' }, r.proto + '/' + r.port),
				E('td', { 'style': 'font-size:.78rem;color:var(--text-muted)' }, r.note || ''),
				E('td', { 'style': 'text-align:right' },
					E('button', { 'class': 'cb-btn cb-btn-danger',
						'click': function (ev) { self.handlePortDel(r.id, ev); } }, _('Delete')))
			]));
		});
	},

	handleGroupAdd: function (ev) {
		var self = this;
		var el = document.getElementById('cb-group-name');
		var name = el ? el.value : '';
		if (!name) return;
		var btn = ev.currentTarget; btn.disabled = true;
		return callGroupAdd(name, '').then(function (res) {
			if (res && res.success === false) throw new Error(res.error || _('Failed'));
			if (el) el.value = '';
			return self.refreshGroups();
		}).catch(function (e) {
			ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error');
		}).finally(function () { btn.disabled = false; });
	},

	handleGroupDel: function (id, ev) {
		var self = this;
		ev.currentTarget.disabled = true;
		return callGroupDel(id).then(function () { return self.refreshGroups(); })
			.catch(function (e) { ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error'); });
	},

	handleCurfew: function (g, ev) {
		var self = this;
		var btn = ev.currentTarget; btn.disabled = true;
		return callCurfew(g.id, '0').then(function (res) {
			if (res && res.success === false) throw new Error(res.error || _('Failed'));
			ui.addNotification(null, E('p', {} , _('Curfew applied to') + ' ' + (res.blocked || 0) + ' ' + _('devices')), 'info');
			return self.refresh();
		}).catch(function (e) {
			ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error');
		}).finally(function () { btn.disabled = false; });
	},

	renderGroups: function () {
		var box = document.getElementById('cb-sched-groups');
		if (!box) return;
		while (box.firstChild) box.removeChild(box.firstChild);
		var self = this;
		var list = this.groups || [];
		if (!list.length) {
			box.appendChild(E('div', { 'class': 'cb-empty' }, _('No groups yet')));
			return;
		}
		list.forEach(function (g) {
			var pick = E('select', { 'multiple': 'multiple', 'size': '3',
				'style': 'min-width:16rem;font-size:.78rem;padding:.2rem;border-radius:.3rem;border:1px solid var(--hairline);background:var(--surface-sunken);color:inherit' });
			(self.devices || []).forEach(function (d) {
				var sel = (g.macs || []).indexOf(d.mac) !== -1;
				pick.appendChild(E('option', { 'value': d.mac, 'selected': sel ? 'selected' : null },
					(d.host || d.mac)));
			});
			box.appendChild(E('div', { 'style': 'display:flex;gap:.6rem;align-items:flex-start;flex-wrap:wrap;padding:.5rem 0;border-bottom:1px solid var(--hairline)' }, [
				E('div', { 'style': 'min-width:9rem' }, [
					E('div', { 'class': 'cb-u' }, g.name),
					E('div', { 'class': 'cb-drop' }, (g.count || 0) + ' ' + _('devices'))
				]),
				pick,
				E('div', { 'style': 'display:flex;gap:.35rem' }, [
					E('button', { 'class': 'cb-btn', 'click': function () {
						var macs = [];
						Array.prototype.forEach.call(pick.options, function (o) { if (o.selected) macs.push(o.value); });
						callGroupSet(g.id, macs.join(',')).then(function () { return self.refreshGroups(); })
							.catch(function (e) { ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error'); });
					} }, _('Save')),
					E('button', { 'class': 'cb-btn cb-btn-primary',
						'click': function (ev) { self.handleCurfew(g, ev); } }, _('Curfew')),
					E('button', { 'class': 'cb-btn cb-btn-danger',
						'click': function (ev) { self.handleGroupDel(g.id, ev); } }, _('Delete'))
				])
			]));
		});
	},

	refreshSched: function () {
		var self = this;
		return callSchedList().then(function (res) {
			self.sched = (res && res.rules) || [];
			self.renderSched();
		}).catch(function () { self.renderSched(); });
	},

	handleSchedAdd: function (ev) {
		var self = this;
		var sel = document.getElementById('cb-sched-mac');
		var st = document.getElementById('cb-sched-start');
		var sp = document.getElementById('cb-sched-stop');
		if (!sel || !sel.value) { ui.addNotification(null, E('p', {}, _('Pick a device')), 'warning'); return; }
		var days = [];
		document.querySelectorAll('#cb-sched-days .cb-dchip.on').forEach(function (d) {
			days.push(parseInt(d.getAttribute('data-day'), 10));
		});
		if (!days.length) { ui.addNotification(null, E('p', {}, _('Pick at least one day')), 'warning'); return; }
		if (!st.value || !sp.value) { ui.addNotification(null, E('p', {}, _('Set both times')), 'warning'); return; }
		if (st.value === sp.value) { ui.addNotification(null, E('p', {}, _('Start and end must differ')), 'warning'); return; }

		var btn = ev.currentTarget;
		btn.disabled = true;
		return callSchedAdd(sel.value, days.join(','), st.value, sp.value, sel.options[sel.selectedIndex].text)
			.then(function (res) {
				if (res && res.success === false) throw new Error(res.error || _('Failed'));
				self.sched = (res && res.rules) || [];
				self.renderSched();
				return self.refresh();
			}).catch(function (e) {
				ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error');
			}).finally(function () { btn.disabled = false; });
	},

	handleSchedDel: function (id, ev) {
		var self = this;
		var btn = ev.currentTarget;
		btn.disabled = true;
		return callSchedDel(id).then(function (res) {
			self.sched = (res && res.rules) || [];
			self.renderSched();
			return self.refresh();
		}).catch(function (e) {
			ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error');
		});
	},

	handleSchedToggle: function (rule, ev) {
		var self = this;
		return callSchedToggle(rule.id, rule.enabled ? '0' : '1').then(function (res) {
			self.sched = (res && res.rules) || [];
			self.renderSched();
			return self.refresh();
		}).catch(function (e) {
			ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error');
		});
	},

	renderSched: function () {
		var tbody = document.getElementById('cb-sched-tbody');
		if (!tbody) return;
		while (tbody.firstChild) tbody.removeChild(tbody.firstChild);

		var self = this;
		var names = [_('Sun'), _('Mon'), _('Tue'), _('Wed'), _('Thu'), _('Fri'), _('Sat')];
		var list = this.sched || [];

		// device picker options
		var sel = document.getElementById('cb-sched-mac');
		if (sel) {
			var keep = sel.value;
			while (sel.firstChild) sel.removeChild(sel.firstChild);
			(this.devices || []).slice().sort(function (a, b) {
				return String(a.host || a.ip || '').localeCompare(String(b.host || b.ip || ''));
			}).forEach(function (d) {
				sel.appendChild(E('option', { 'value': d.mac },
					(d.host || d.mac) + (d.ip ? '  ' + d.ip : '')));
			});
			if (keep) sel.value = keep;
		}

		if (!list.length) {
			tbody.appendChild(E('tr', {}, E('td', { 'colspan': 5, 'class': 'cb-empty' },
				_('No schedule rules yet'))));
			return;
		}

		list.forEach(function (r) {
			var dayTxt = (r.days || []).map(function (d) { return names[d] || d; }).join(' ');
			tbody.appendChild(E('tr', {}, [
				E('td', { 'class': 'cb-u' }, r.name || r.mac),
				E('td', { 'style': 'font-size:.8rem' }, dayTxt),
				E('td', { 'class': 'cb-t' }, (r.start || '') + ' - ' + (r.stop || '')),
				E('td', {}, E('span', { 'class': 'cb-res ' + (r.active ? 'cb-sched-on' : 'cb-sched-idle') },
					r.active ? _('blocking now') : (r.enabled ? _('scheduled') : _('disabled')))),
				E('td', { 'style': 'text-align:right;white-space:nowrap' }, [
					E('button', { 'class': 'cb-btn', 'style': 'margin-right:.35rem',
						'click': function (ev) { self.handleSchedToggle(r, ev); } },
						r.enabled ? _('Pause') : _('Resume')),
					E('button', { 'class': 'cb-btn cb-btn-danger',
						'click': function (ev) { self.handleSchedDel(r.id, ev); } }, _('Delete'))
				])
			]));
		});
	},

	refreshHealth: function () {
		var self = this;
		return callSelfCheck().then(function (res) {
			self.health = res || {};
			self.renderHealth();
		}).catch(function (e) {
			self.health = { ok: false, checks: [], error: e && e.message };
			self.renderHealth();
		});
	},

	renderHealth: function () {
		var box = document.getElementById('cb-health-body');
		if (!box) return;
		while (box.firstChild) box.removeChild(box.firstChild);

		var h = this.health || {};
		var names = {
			watcher: _('Service process'),
			logread: _('Log stream'),
			rulesfile: _('Generated rules'),
			nftset: _('Kernel IP set'),
			nfthook: _('Firewall rules'),
			geodb: _('Region database'),
			state: _('State storage'),
			autoprot: _('Automatic protection')
		};

		var head = document.getElementById('cb-health-head');
		if (head) {
			while (head.firstChild) head.removeChild(head.firstChild);
			head.appendChild(E('span', {
				'class': 'cb-res ' + (h.ok ? 'cb-health-ok' : 'cb-health-bad')
			}, h.ok ? _('all checks passed') : _('attention needed')));
			if (h.error) head.appendChild(E('span', { 'class': 'cb-drop' }, h.error));
		}

		var list = h.checks || [];
		if (!list.length) {
			box.appendChild(E('div', { 'class': 'cb-empty' }, _('No results yet')));
			return;
		}

		list.forEach(function (c) {
			var bad = !c.ok;
			box.appendChild(E('div', { 'class': 'cb-check' + (bad ? ' bad' : '') }, [
				E('span', { 'class': 'cb-mark ' + (bad ? 'bad' : 'ok') }, bad ? '\u2715' : '\u2713'),
				E('span', { 'class': 'cb-name' }, names[c.id] || c.id),
				E('span', { 'class': 'cb-val' }, c.detail || '')
			].concat(bad && c.hint ? [ E('span', { 'class': 'cb-hint' }, c.hint) ] : [])));
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

	// One tab may own several panes (Settings groups protection, notifications,
	// health and backup).
	tabPanes: {
		overview: [ 'dash' ],
		devices: [ 'devices' ],
		ips: [ 'ips' ],
		logs: [ 'logs' ],
		policy: [ 'sched' ],
		settings: [ 'auto', 'notify', 'health', 'backup' ]
	},

	switchTab: function (name) {
		this.tab = name;
		var self = this;
		var all = [];
		Object.keys(this.tabPanes).forEach(function (k) { all = all.concat(self.tabPanes[k]); });
		var mine = this.tabPanes[name] || [];
		all.forEach(function (p) {
			var el = document.getElementById('cb-pane-' + p);
			if (el) el.classList.toggle('active', mine.indexOf(p) !== -1);
		});
		['overview', 'devices', 'ips', 'logs', 'policy', 'settings'].forEach(function (t) {
			var btn = document.getElementById('cb-tab-' + t);
			if (btn) btn.classList.toggle('active', t === name);
		});
		if (name === 'overview') return this.refreshDash();
		if (name === 'ips') return Promise.all([ this.refreshIps(), this.refreshFeeds() ]);
		if (name === 'logs') return this.refreshLogs();
		if (name === 'policy') return Promise.all([ this.refreshSched(), this.refreshGroups(), this.refreshPorts() ]);
		if (name === 'settings') return Promise.all([ this.refreshAuto(), this.refreshNotify(), this.refreshHealth() ]);
	},

	renderTable: function () {
		var tbody = document.getElementById('cb-tbody');
		if (!tbody) return;
		while (tbody.firstChild) tbody.removeChild(tbody.firstChild);

		var rows = this.filterRows() || [];
		var self = this;

		if (!rows.length) {
			tbody.appendChild(E('tr', {}, E('td', { 'colspan': 7, 'class': 'cb-empty' },
				_('No devices match the filter'))));
		}

		rows.forEach(function (d) {
			var newBadge = d.is_new
				? E('span', { 'class': 'cb-res cb-sched-on', 'style': 'margin-left:.35rem' }, _('new'))
				: '';

			var stateBadge = d.blocked
				? E('span', { 'class': 'cb-badge cb-badge-blocked' }, _('Blocked'))
				: (d.online
					? E('span', { 'class': 'cb-badge cb-badge-on' }, _('Online'))
					: E('span', { 'class': 'cb-badge cb-badge-off' }, _('Offline')));

			var trustBtn = d.is_new
				? E('button', {
					'class': 'cb-btn cb-btn-primary',
					'style': 'margin-right:.3rem',
					'title': _('Accept this device as known'),
					'click': function (ev) { self.handleAccept(d, ev); }
				}, _('Allow'))
				: '';

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
				E('td', {}, [ stateBadge, newBadge ]),
				E('td', {}, [
					nameCell,
					(d.vendor || d.device_type)
						? E('div', { 'class': 'cb-drop cb-vendor', 'title': (d.vendor || '') + ' · ' + typeLabel(d.device_type) },
							(d.vendor || _('unknown vendor')) + ' · ' + typeLabel(d.device_type))
						: ''
				]),
				E('td', { 'class': 'cb-mono' }, d.ip || '-'),
				E('td', { 'class': 'cb-mono' }, d.mac),
				E('td', { 'class': 'cb-drop' }, d.first_seen
					? ((d.first_assumed ? '≈ ' : '') + fmtTime(d.first_seen))
					: '-'),
				E('td', {}, d.blocked ? [ dropText, E('br'), E('span', { 'class': 'cb-drop' }, fmtTime(d.blocked_at)) ] : ''),
				E('td', { 'style': 'text-align:right;white-space:nowrap' }, [ trustBtn, action ])
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
		this.sched = (data && data.sched) || [];
		this.logQuery = '';
		this.logKind = 'all';
		this.logResult = 'all';
		this.query = '';
		this.ipQuery = '';
		this.tab = 'overview';
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
				'class': 'cb-tab' + (name === 'overview' ? ' active' : ''),
				'id': 'cb-tab-' + name,
				'click': function () { self.switchTab(name); }
			}, label);
		};

		var autoPane = E('div', {
			'class': 'cb-pane',
			'id': 'cb-pane-auto'
		}, [
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
			])
		]);

		var backupPane = E('div', {
			'class': 'cb-pane',
			'id': 'cb-pane-backup'
		}, [
			E('div', { 'class': 'cb-card' }, [
				E('div', { 'class': 'cb-card-head' }, [
					E('span', { 'class': 'cb-dot' }),
					E('span', {}, _('Backup and restore'))
				]),
				E('div', { 'class': 'cb-card-body' }, [
					E('div', { 'class': 'cb-card-hint', 'style': 'margin-bottom:.7rem' },
						_('Exports every list and rule as JSON: blocked devices and addresses, names, schedules, groups, ports, whitelist, feeds and protection settings.')),
					E('div', { 'style': 'display:flex;gap:.5rem;flex-wrap:wrap' }, [
						E('button', { 'class': 'cb-btn cb-btn-primary',
							'click': function (ev) { self.handleExport(ev); } }, _('Export')),
						E('button', { 'class': 'cb-btn',
							'click': function (ev) { self.handleImport(ev); } }, _('Import'))
					]),
					E('textarea', {
						'id': 'cb-backup-text',
						'style': 'width:100%;height:9rem;margin-top:.7rem;font-family:var(--font-mono);font-size:.75rem;' +
							'padding:.5rem;border-radius:.3rem;border:1px solid var(--hairline);background:var(--surface-sunken);color:inherit',
						'placeholder': _('Paste a backup here, then press Import')
					})
				])
			])
		]);

		var dashPane = E('div', {
			'class': 'cb-pane active',
			'id': 'cb-pane-dash'
		}, [
			E('p', { 'style': 'opacity:.75;margin:.25rem 0 1rem' },
				_('Overview only. No device addresses are shown here; open the Devices tab for the full inventory.')),
			E('div', { 'id': 'cb-dash-body' })
		]);

		var devicesPane = E('div', {
			'class': 'cb-pane',
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
					E('th', {}, _('First seen')),
					E('th', {}, _('Dropped')),
					E('th', { 'style': 'text-align:right' }, _('Action'))
				])),
				E('tbody', { 'id': 'cb-tbody' })
			]),
			E('div', { 'class': 'cb-card', 'style': 'margin-top:1.2rem' }, [
				E('div', { 'class': 'cb-card-head' }, [
					E('span', { 'class': 'cb-dot' }),
					E('span', {}, _('Port restrictions'))
				]),
				E('div', { 'class': 'cb-card-body' }, [
					E('div', { 'class': 'cb-card-hint', 'style': 'margin-bottom:.7rem' },
						_('Let a device use the internet but block specific local services, e.g. keep IoT off SMB/445 or telnet.')),
					E('div', { 'class': 'cb-sched-form', 'style': 'padding:0;border:none;background:none;margin-bottom:.8rem' }, [
						E('label', {}, [ E('span', {}, _('Device')),
							E('select', { 'id': 'cb-port-mac', 'style': 'min-width:14rem' }) ]),
						E('label', {}, [ E('span', {}, _('Protocol')),
							E('select', { 'id': 'cb-port-proto' }, [
								E('option', { 'value': 'tcp' }, 'tcp'),
								E('option', { 'value': 'udp' }, 'udp') ]) ]),
						E('label', {}, [ E('span', {}, _('Port')),
							E('input', { 'type': 'number', 'id': 'cb-port-num', 'min': '1', 'max': '65535', 'value': '445',
								'style': 'width:6rem;padding:.35rem .5rem;border-radius:.3rem;border:1px solid var(--hairline);background:var(--surface-sunken);color:inherit' }) ]),
						E('label', {}, [ E('span', {}, _('Note')),
							E('input', { 'type': 'text', 'id': 'cb-port-note', 'placeholder': _('optional'),
								'style': 'width:10rem;padding:.35rem .5rem;border-radius:.3rem;border:1px solid var(--hairline);background:var(--surface-sunken);color:inherit' }) ]),
						E('label', {}, [ E('span', {}, _('Preset')),
							E('select', { 'id': 'cb-port-preset' }, [
								E('option', { 'value': 'iot' }, 'IoT'),
								E('option', { 'value': 'smb' }, 'SMB'),
								E('option', { 'value': 'remote' }, 'Remote')
							]) ]),
						E('button', { 'class': 'cb-btn cb-btn-primary',
							'click': function (ev) { self.handlePortAdd(ev); } }, _('Block port')),
						E('button', { 'class': 'cb-btn',
							'click': function (ev) { self.handlePortPreset(ev); } }, _('Apply preset'))
					]),
					E('table', { 'class': 'cb-table' }, [
						E('thead', {}, E('tr', {}, [
							E('th', {}, _('Device')), E('th', {}, _('Port')),
							E('th', {}, _('Note')), E('th', { 'style': 'text-align:right' }, _('Action'))
						])),
						E('tbody', { 'id': 'cb-port-tbody' })
					])
				])
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
					E('span', {}, _('Blocklist subscriptions'))
				]),
				E('div', { 'class': 'cb-card-body' }, [
					E('div', { 'class': 'cb-card-hint', 'style': 'margin-bottom:.7rem' },
						_('Pull public blocklists on demand and merge them here. Entries are tagged with their feed so removing the feed also removes them.')),
					E('div', { 'class': 'cb-sched-form', 'style': 'padding:0;border:none;background:none;margin-bottom:.6rem' }, [
						E('label', {}, [ E('span', {}, _('Name')),
							E('input', { 'type': 'text', 'id': 'cb-feed-name', 'placeholder': _('optional'),
								'style': 'width:9rem;padding:.35rem .5rem;border-radius:.3rem;border:1px solid var(--hairline);background:var(--surface-sunken);color:inherit' }) ]),
						E('label', {}, [ E('span', {}, _('List URL')),
							E('input', { 'type': 'text', 'id': 'cb-feed-url', 'placeholder': 'https://host/list.netset',
								'style': 'width:18rem;padding:.35rem .5rem;border-radius:.3rem;border:1px solid var(--hairline);background:var(--surface-sunken);color:inherit' }) ]),
						E('button', { 'class': 'cb-btn',
							'click': function (ev) { self.handleFeedAdd(ev); } }, _('Add feed'))
					]),
					E('table', { 'class': 'cb-table' }, [
						E('thead', {}, E('tr', {}, [
							E('th', {}, _('Name')), E('th', {}, _('Imported')),
							E('th', {}, _('Last fetch')), E('th', { 'style': 'text-align:right' }, _('Action'))
						])),
						E('tbody', { 'id': 'cb-feed-tbody' })
					])
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

		var schedPane = E('div', {
			'class': 'cb-pane',
			'id': 'cb-pane-sched'
		}, [
			E('p', { 'style': 'opacity:.75;margin:.25rem 0 1rem' },
				_('Block a device on a weekly schedule. A window that ends before it starts crosses midnight, and its days refer to the day the window begins.')),
			E('div', { 'class': 'cb-sched-form' }, [
				E('label', {}, [
					E('span', {}, _('Device')),
					E('select', { 'id': 'cb-sched-mac', 'style': 'min-width:14rem' })
				]),
				E('label', {}, [
					E('span', {}, _('Days')),
					E('div', { 'class': 'cb-days', 'id': 'cb-sched-days' },
						['S','M','T','W','T','F','S'].map(function (ch, i) {
							return E('div', { 'class': 'cb-dchip', 'data-day': String(i),
								'click': function (ev) { ev.currentTarget.classList.toggle('on'); } }, ch);
						}))
				]),
				E('label', {}, [
					E('span', {}, _('From')),
					E('input', { 'type': 'time', 'id': 'cb-sched-start', 'value': '21:00' })
				]),
				E('label', {}, [
					E('span', {}, _('To')),
					E('input', { 'type': 'time', 'id': 'cb-sched-stop', 'value': '07:00' })
				]),
				E('button', { 'class': 'cb-btn cb-btn-primary',
					'click': function (ev) { self.handleSchedAdd(ev); } }, _('Add rule'))
			]),
			E('table', { 'class': 'cb-table' }, [
				E('thead', {}, E('tr', {}, [
					E('th', {}, _('Device')),
					E('th', {}, _('Days')),
					E('th', {}, _('Window')),
					E('th', {}, _('Status')),
					E('th', { 'style': 'text-align:right' }, _('Action'))
				])),
				E('tbody', { 'id': 'cb-sched-tbody' })
			]),
			E('div', { 'class': 'cb-card', 'style': 'margin-top:1.2rem' }, [
				E('div', { 'class': 'cb-card-head' }, [
					E('span', { 'class': 'cb-dot' }),
					E('span', {}, _('Groups and curfew'))
				]),
				E('div', { 'class': 'cb-card-body' }, [
					E('div', { 'class': 'cb-card-hint', 'style': 'margin-bottom:.7rem' },
						_('Group devices (family / kids / IoT) and block them all at once. Curfew blocks the group until 08:00.')),
					E('div', { 'class': 'cb-sched-form', 'style': 'padding:0;border:none;background:none;margin-bottom:.6rem' }, [
						E('label', {}, [ E('span', {}, _('New group')),
							E('input', { 'type': 'text', 'id': 'cb-group-name', 'placeholder': _('e.g. Kids'),
								'style': 'width:12rem;padding:.35rem .5rem;border-radius:.3rem;border:1px solid var(--hairline);background:var(--surface-sunken);color:inherit' }) ]),
						E('button', { 'class': 'cb-btn',
							'click': function (ev) { self.handleGroupAdd(ev); } }, _('Add group'))
					]),
					E('div', { 'id': 'cb-sched-groups' })
				])
			])
		]);

		var notifyPane = E('div', {
			'class': 'cb-pane',
			'id': 'cb-pane-notify'
		}, [
			E('p', { 'style': 'opacity:.75;margin:.25rem 0 1rem' },
				_('Send a message when something happens. Every channel is tried independently; a broken one never blocks the action.')),
			E('div', { 'class': 'cb-sched-form' }, [
				E('label', {}, [ E('span', {}, _('Type')),
					E('select', { 'id': 'cb-nt-type' }, [
						E('option', { 'value': 'telegram' }, 'Telegram'),
						E('option', { 'value': 'bark' }, 'Bark'),
						E('option', { 'value': 'webhook' }, _('Webhook'))
					]) ]),
				E('label', {}, [ E('span', {}, _('Name')),
					E('input', { 'type': 'text', 'id': 'cb-nt-name', 'placeholder': _('optional'),
						'style': 'width:9rem;padding:.35rem .5rem;border-radius:.3rem;border:1px solid var(--hairline);background:var(--surface-sunken);color:inherit' }) ]),
				E('label', {}, [ E('span', {}, _('URL (bark / webhook)')),
					E('input', { 'type': 'text', 'id': 'cb-nt-url', 'placeholder': 'https://api.day.app/KEY',
						'style': 'width:16rem;padding:.35rem .5rem;border-radius:.3rem;border:1px solid var(--hairline);background:var(--surface-sunken);color:inherit' }) ]),
				E('label', {}, [ E('span', {}, _('Bot token (telegram)')),
					E('input', { 'type': 'text', 'id': 'cb-nt-token',
						'style': 'width:12rem;padding:.35rem .5rem;border-radius:.3rem;border:1px solid var(--hairline);background:var(--surface-sunken);color:inherit' }) ]),
				E('label', {}, [ E('span', {}, _('Chat ID (telegram)')),
					E('input', { 'type': 'text', 'id': 'cb-nt-chat',
						'style': 'width:8rem;padding:.35rem .5rem;border-radius:.3rem;border:1px solid var(--hairline);background:var(--surface-sunken);color:inherit' }) ]),
				E('button', { 'class': 'cb-btn cb-btn-primary',
					'click': function (ev) { self.handleNotifyAdd(ev); } }, _('Add channel'))
			]),
			E('div', { 'style': 'margin:.2rem 0 .5rem;font-size:.8rem;color:var(--text-muted)' }, _('Notify me when:')),
			E('div', { 'class': 'cb-days', 'id': 'cb-nt-events', 'style': 'margin-bottom:1rem' }),
			E('button', { 'class': 'cb-btn', 'style': 'margin-bottom:1rem',
				'click': function (ev) { self.handleNotifyEvents(ev); } }, _('Save events')),
			E('table', { 'class': 'cb-table' }, [
				E('thead', {}, E('tr', {}, [
					E('th', {}, _('Type')), E('th', {}, _('Name')),
					E('th', {}, _('Target')), E('th', { 'style': 'text-align:right' }, _('Action'))
				])),
				E('tbody', { 'id': 'cb-nt-tbody' })
			])
		]);

		var healthPane = E('div', {
			'class': 'cb-pane',
			'id': 'cb-pane-health'
		}, [
			E('p', { 'style': 'opacity:.75;margin:.25rem 0 1rem' },
				_('Live checks on the parts that silently fail: the watcher process, the log stream it reads, and whether saved state actually reached the kernel.')),
			E('div', { 'class': 'cb-health-head' }, [
				E('span', { 'id': 'cb-health-head', 'style': 'display:flex;gap:.5rem;align-items:center' }),
				E('button', { 'class': 'cb-btn', 'style': 'margin-left:auto',
					'click': function (ev) { self.refreshHealth(); } }, _('Re-run'))
			]),
			E('div', { 'class': 'cb-checks', 'id': 'cb-health-body' })
		]);

		var root = E('div', { 'class': 'cb-wrap' }, [
			E('style', {}, STYLE),
			E('h2', {}, _('Client Access Control')),
			E('div', { 'class': 'cb-tabs' }, [
				tabBtn('overview', _('Overview')),
				tabBtn('devices', _('Devices')),
				tabBtn('ips', _('Addresses')),
				tabBtn('logs', _('Log')),
				tabBtn('policy', _('Policy')),
				tabBtn('settings', _('Settings'))
			]),
			dashPane,
			devicesPane,
			ipsPane,
			autoPane,
			backupPane,
			logsPane,
			schedPane,
			notifyPane,
			healthPane
		]);

		window.setTimeout(function () {
			self.renderDash();
			self.renderTable();
			self.renderAuto();
			self.renderLogs();
			self.renderSched();
			self.renderNotify();
			self.renderPorts();
			self.renderGroups();
			self.renderFeeds();
			self.renderTrend();
		}, 0);

		poll.add(function () {
			// a hidden tab has no business polling
			if (document.hidden) return;
			if (self.tab === 'overview') return self.refreshDash();
			if (self.tab === 'ips') return self.refreshIps();
			if (self.tab === 'logs') return self.refreshLogs();
			if (self.tab === 'policy') return self.refreshSched();
			if (self.tab === 'settings') return self.refreshNotify();

			return self.refresh();
		}, 10);

		return root;
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
