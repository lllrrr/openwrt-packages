'use strict';
'require view';
'require rpc';
'require ui';
'require poll';

var callList = rpc.declare({
	object: 'luci.languard',
	method: 'list',
	params: ['probe']
});

var callBlock = rpc.declare({
	object: 'luci.languard',
	method: 'block',
	params: ['mac', 'host', 'ip']
});

var callUnblock = rpc.declare({
	object: 'luci.languard',
	method: 'unblock',
	params: ['mac']
});

var callUnblockAll = rpc.declare({
	object: 'luci.languard',
	method: 'unblock_all'
});

var callIpList = rpc.declare({
	object: 'luci.languard',
	method: 'iplist',
	params: ['limit', 'cat']
});

var callSync = rpc.declare({ object: 'luci.languard', method: 'sync' });
var callAppList = rpc.declare({ object: 'luci.languard', method: 'applist' });
var callAppStats = rpc.declare({ object: 'luci.languard', method: 'appstats' });
var callAppImport = rpc.declare({ object: 'luci.languard', method: 'appimport', params: ['text'] });
var callAppDel = rpc.declare({ object: 'luci.languard', method: 'appdel', params: ['id'] });
var callSigList = rpc.declare({ object: 'luci.languard', method: 'siglist', params: ['name'] });
var callDomainHits = rpc.declare({ object: 'luci.languard', method: 'domainhits', params: ['limit'] });
var callDomainLog = rpc.declare({ object: 'luci.languard', method: 'domaintogglelog', params: ['on_'] });
var callSigAdd = rpc.declare({ object: 'luci.languard', method: 'sigadd', params: ['name', 'proto', 'dport', 'host'] });
var callSigDel = rpc.declare({ object: 'luci.languard', method: 'sigdel', params: ['name', 'idx'] });
var callAppReset = rpc.declare({ object: 'luci.languard', method: 'appreset' });
var callSampleStart = rpc.declare({ object: 'luci.languard', method: 'sample_start', params: ['duration'] });
var callSampleStop = rpc.declare({ object: 'luci.languard', method: 'sample_stop' });
var callSampleResult = rpc.declare({ object: 'luci.languard', method: 'sample_result' });
var callSampleSave = rpc.declare({ object: 'luci.languard', method: 'sample_save', params: ['name', 'proto', 'dport', 'prefix', 'cls'] });
var callQosList = rpc.declare({ object: 'luci.languard', method: 'qoslist' });
var callQosAdd = rpc.declare({ object: 'luci.languard', method: 'qosadd', params: ['ip', 'app', 'dscp'] });
var callQosDel = rpc.declare({ object: 'luci.languard', method: 'qosdel', params: ['id'] });
var callDevMerge = rpc.declare({ object: 'luci.languard', method: 'devmerge', params: ['mac', 'into'] });
var callDevUnmerge = rpc.declare({ object: 'luci.languard', method: 'devunmerge', params: ['mac'] });
var callDomainList = rpc.declare({ object: 'luci.languard', method: 'domainlist' });
var callDomainAdd = rpc.declare({ object: 'luci.languard', method: 'domainadd', params: ['name'] });
var callDomainDel = rpc.declare({ object: 'luci.languard', method: 'domaindel', params: ['name'] });
var callDomainToggle = rpc.declare({ object: 'luci.languard', method: 'domaintoggle', params: ['on_'] });

var callProxyList = rpc.declare({ object: 'luci.languard', method: 'proxylist' });
var callProxyAdd = rpc.declare({ object: 'luci.languard', method: 'proxyadd', params: ['ip'] });
var callProxyDel = rpc.declare({ object: 'luci.languard', method: 'proxydel', params: ['ip'] });

var callIpAdd = rpc.declare({
	object: 'luci.languard',
	method: 'ipadd',
	params: ['ip', 'note']
});

var callIpDel = rpc.declare({
	object: 'luci.languard',
	method: 'ipdel',
	params: ['ip']
});

var callDashboard = rpc.declare({ object: 'luci.languard', method: 'dashboard' });
var callTrend = rpc.declare({ object: 'luci.languard', method: 'trend' });
var callPanicState = rpc.declare({ object: 'luci.languard', method: 'panicstate' });
var callPanic = rpc.declare({ object: 'luci.languard', method: 'panic', params: ['on_'] });
var callKnownAdd = rpc.declare({ object: 'luci.languard', method: 'knownadd', params: ['mac'] });
var callKnownList = rpc.declare({ object: 'luci.languard', method: 'knownlist' });
var callWlList = rpc.declare({ object: 'luci.languard', method: 'wllist' });
var callWlAdd = rpc.declare({ object: 'luci.languard', method: 'wladd', params: ['mac'] });
var callWlDel = rpc.declare({ object: 'luci.languard', method: 'wldel', params: ['mac'] });
var callFeedList = rpc.declare({ object: 'luci.languard', method: 'feedlist' });
var callFeedAdd = rpc.declare({ object: 'luci.languard', method: 'feedadd', params: ['name', 'url', 'interval', 'kind', 'cls'] });
var callFeedSet = rpc.declare({ object: 'luci.languard', method: 'feedset', params: ['id', 'interval'] });
var callFeedDel = rpc.declare({ object: 'luci.languard', method: 'feeddel', params: ['id'] });
var callFeedRefresh = rpc.declare({ object: 'luci.languard', method: 'feedrefresh', params: ['id'] });
var callPortPresets = rpc.declare({ object: 'luci.languard', method: 'portpresets' });
var callPortTemplate = rpc.declare({ object: 'luci.languard', method: 'porttemplate', params: ['macs', 'preset'] });
var callExport = rpc.declare({ object: 'luci.languard', method: 'exportconfig' });
var callImport = rpc.declare({ object: 'luci.languard', method: 'importconfig', params: ['payload'] });

var callGroupList = rpc.declare({ object: 'luci.languard', method: 'grouplist' });
var callGroupAdd = rpc.declare({ object: 'luci.languard', method: 'groupadd', params: ['name', 'macs'] });
var callGroupDel = rpc.declare({ object: 'luci.languard', method: 'groupdel', params: ['id'] });
var callGroupSet = rpc.declare({ object: 'luci.languard', method: 'groupset', params: ['id', 'macs'] });
var callCurfew = rpc.declare({ object: 'luci.languard', method: 'curfew', params: ['id', 'minutes'] });
var callPortList = rpc.declare({ object: 'luci.languard', method: 'portlist' });
var callPortAdd = rpc.declare({ object: 'luci.languard', method: 'portadd', params: ['mac', 'proto', 'port', 'note'] });
var callPortDel = rpc.declare({ object: 'luci.languard', method: 'portdel', params: ['id'] });

var callNotifyGet = rpc.declare({ object: 'luci.languard', method: 'notifyget' });
var callNotifyAdd = rpc.declare({ object: 'luci.languard', method: 'notifyadd',
	params: ['type_', 'name', 'url', 'token', 'chat'] });
var callNotifyDel = rpc.declare({ object: 'luci.languard', method: 'notifydel', params: ['id'] });
var callNotifyToggle = rpc.declare({ object: 'luci.languard', method: 'notifytoggle', params: ['id', 'enabled'] });
var callNotifyEvents = rpc.declare({ object: 'luci.languard', method: 'notifyevents', params: ['events'] });
var callNotifyTest = rpc.declare({ object: 'luci.languard', method: 'notifytest', params: ['id'] });

var callSchedList = rpc.declare({
	object: 'luci.languard',
	method: 'schedlist'
});

var callSchedAdd = rpc.declare({
	object: 'luci.languard',
	method: 'schedadd',
	params: ['mac', 'days', 'start', 'stop', 'name']
});

var callSchedDel = rpc.declare({
	object: 'luci.languard',
	method: 'scheddel',
	params: ['id']
});

var callSchedToggle = rpc.declare({
	object: 'luci.languard',
	method: 'schedtoggle',
	params: ['id', 'enabled']
});

var callSelfCheck = rpc.declare({
	object: 'luci.languard',
	method: 'selfcheck'
});

var callLogList = rpc.declare({
	object: 'luci.languard',
	method: 'loglist',
	params: ['limit']
});

var callLogClear = rpc.declare({
	object: 'luci.languard',
	method: 'logclear'
});

var callAutoGet = rpc.declare({
	object: 'luci.languard',
	method: 'autoget'
});

var callAutoSet = rpc.declare({
	object: 'luci.languard',
	method: 'autoset',
	params: ['enabled', 'threshold', 'window', 'ttl', 'ssh_password', 'ssh_user', 'web_auth']
});

var callScan = rpc.declare({
	object: 'luci.languard',
	method: 'scan'
});

var callIpFlush = rpc.declare({
	object: 'luci.languard',
	method: 'ipflush'
});

var callRename = rpc.declare({
	object: 'luci.languard',
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
.cb-src-all { background: var(--surface-2, rgba(128,128,128,.18)); color: inherit; }
.cb-src-feed { background: var(--info-surface); color: var(--info); }
.cb-src-manual { background: var(--success-surface, rgba(0,160,80,.15)); color: var(--success, #0a0); }
.cb-src-sched { background: var(--warning-surface, rgba(200,140,0,.18)); color: var(--warning, #b80); }
.cb-src-panic { background: var(--danger-surface); color: var(--danger); }
.cb-ipcats { display: flex; flex-wrap: wrap; gap: .35rem; margin: .1rem 0 .7rem; }
.cb-catchip { display: inline-flex; align-items: center; padding: .18rem .5rem .18rem .3rem;
	border: 1px solid var(--border, rgba(128,128,128,.3)); border-radius: .45rem;
	background: transparent; color: inherit; cursor: pointer; font-size: .78rem; }
.cb-catchip:hover { border-color: var(--brand); }
.cb-catchip-on { border-color: var(--brand); box-shadow: inset 0 0 0 1px var(--brand); }
.cb-catchip-zero { opacity: .45; }
.cb-subhead { margin: 1.1rem 0 .4rem; font-weight: 600; font-size: .9rem; }
.cb-note { font-size: .78rem; opacity: .65; margin: .1rem 0 .5rem; line-height: 1.5; }
.cb-proxylist { display: flex; flex-wrap: wrap; gap: .4rem; margin-bottom: .5rem; min-height: 1.4rem; }
.cb-proxychip { display: inline-flex; align-items: center; gap: .3rem; padding: .12rem .2rem .12rem .5rem;
	border: 1px solid var(--border, rgba(128,128,128,.35)); border-radius: .4rem; font-size: .8rem; }
.cb-proxyx { background: none; border: none; color: inherit; opacity: .5; cursor: pointer;
	font-size: 1rem; line-height: 1; padding: 0 .3rem; }
.cb-proxyx:hover { opacity: 1; color: var(--danger); }
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

/* ---- loading skeleton ---- */
.cb-tablewrap { width: 100%; overflow-x: auto; -webkit-overflow-scrolling: touch; }
.cb-import { width: 100%; box-sizing: border-box; font-family: var(--font-mono);
	font-size: .78rem; padding: .5rem; border-radius: .3rem; resize: vertical;
	border: 1px solid var(--hairline); background: var(--surface-sunken); color: inherit; }
.cb-sel { padding: .25rem .4rem; border-radius: .3rem; border: 1px solid var(--hairline);
	background: var(--surface-sunken); color: inherit; font-size: .8rem;
	/* without this the native popup is drawn in the OS light palette */
	color-scheme: dark; }
.cb-sel option { background: var(--surface-sunken); color: inherit; }
@media (max-width: 768px) { .cb-log .cb-date { display: none; } }
.cb-skel { pointer-events: none; }
.cb-skel-line { display: block; height: .9rem; border-radius: .3rem;
	background: linear-gradient(90deg, var(--hairline) 25%, rgba(128,128,128,.16) 37%, var(--hairline) 63%);
	background-size: 400% 100%; animation: cb-shimmer 1.3s ease infinite; }
@keyframes cb-shimmer { 0% { background-position: 100% 50% } 100% { background-position: 0 50% } }

/* ---- narrow screens ---- */
@media (max-width: 768px) {
	.cb-tabs { flex-wrap: nowrap; overflow-x: auto; -webkit-overflow-scrolling: touch;
		scrollbar-width: none; margin-bottom: .7rem; }
	.cb-tabs::-webkit-scrollbar { display: none; }
	.cb-tab { flex: 0 0 auto; padding: .45rem .7rem; font-size: .85rem; }
	.cb-stats { grid-template-columns: repeat(2, 1fr); gap: .5rem; }
	.cb-stat { padding: .6rem .7rem; }
	.cb-stat .cb-n { font-size: 1.3rem; }
	.cb-dash-row { flex-direction: column; gap: .05rem; padding: .4rem 0; }
	.cb-dash-row .cb-k { min-width: 0; font-size: .78rem; }
	.cb-card-body { padding: .65rem .7rem; overflow-x: auto; -webkit-overflow-scrolling: touch; }
	.cb-table { font-size: .8rem; }
	.cb-table th, .cb-table td { padding: .4rem .45rem; }
	.cb-hide-sm { display: none !important; }
	.cb-vendor { display: none; }
	.cb-table { width: 100%; }
	.cb-table th, .cb-table td { white-space: normal; word-break: break-word; }
	.cb-table td:last-child { white-space: nowrap; }
	.cb-badge, .cb-src, .cb-tag { white-space: nowrap; }
	.cb-ipform input.cb-ip { flex: 1 1 100%; }
	.cb-toolbar { gap: .35rem; }
	.cb-catchip { font-size: .72rem; padding: .14rem .4rem .14rem .25rem; }
	.cb-proxyx { padding: 0 .5rem; }
	.cb-fields { gap: .7rem; }
	.cb-actions { flex-wrap: wrap; gap: .4rem; }
	.cb-actions input[type=text] { flex: 1 1 100%; max-width: none !important; }
	.cb-actions .cb-btn { flex: 1 1 auto; }
	.cb-check, .cb-proxychip { max-width: 100%; }
	.cb-check { grid-template-columns: 1.2rem 1fr; gap: .15rem .5rem; }
	.cb-check .cb-val { grid-column: 2; word-break: break-word; }
	.cb-check .cb-hint { grid-column: 2; }
	.cb-wrap h2 { font-size: 1.15rem; margin: .5rem 0; }
}

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

var IP_CATS = [
	{ key: '',         label: _('All'),           cls: 'cb-src-all' },
	{ key: 'feed',     label: _('Subscription'),  cls: 'cb-src-feed' },
	{ key: 'ssh',      label: _('SSH brute force'), cls: 'cb-src-auto' },
	{ key: 'web',      label: _('Web brute force'), cls: 'cb-src-web' },
	{ key: 'auto',     label: _('Automatic'),     cls: 'cb-src-auto' },
	{ key: 'manual',   label: _('Manual'),        cls: 'cb-src-manual' },
	{ key: 'schedule', label: _('Scheduled'),     cls: 'cb-src-sched' },
	{ key: 'panic',    label: _('Panic'),         cls: 'cb-src-panic' },
	{ key: 'import',   label: _('Imported'),      cls: 'cb-src-watchdog' },
	{ key: 'other',    label: _('Other'),         cls: 'cb-src-manual' }
];

function catMeta(key) {
	for (var i = 0; i < IP_CATS.length; i++)
		if (IP_CATS[i].key === key) return IP_CATS[i];
	return IP_CATS[IP_CATS.length - 1];
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
		// Nothing is fetched here. The shell paints immediately and each
		// section fills itself as its own call returns, so a slow iplist
		// (100 KB+ once a subscription is loaded) no longer blocks the page.
		return Promise.resolve({});
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

		if (!this.dash) {
			// still loading: keep the layout stable instead of flashing dashes
			box.appendChild(E('div', { 'class': 'cb-stats' },
				[ 0, 1, 2, 3, 4, 5 ].map(function () {
					return E('div', { 'class': 'cb-stat cb-skel' }, [
						E('div', { 'class': 'cb-skel-line', 'style': 'width:45%;height:1.3rem' }),
						E('div', { 'class': 'cb-skel-line', 'style': 'width:70%;margin-top:.35rem' })
					]);
				})));
			return;
		}

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

		if (d.arp_recent && d.arp_recent.length) {
			box.appendChild(E('div', { 'class': 'cb-card' }, [
				E('div', { 'class': 'cb-card-head' }, [
					E('span', { 'class': 'cb-dot', 'style': 'background:var(--danger)' }),
					E('span', {}, _('MAC conflicts'))
				]),
				E('div', { 'class': 'cb-card-body' }, E('div', { 'class': 'cb-dash-rows' },
					d.arp_recent.slice(-6).reverse().map(function (ev) {
						return E('div', { 'class': 'cb-dash-row' }, [
							E('span', { 'class': 'cb-k' }, (ev.severity === 'gateway'
								? _('gateway') : _('conflict')) + ' · ' + fmtTime(ev.ts)),
							E('span', { 'class': 'cb-v', 'style': 'color:var(--danger)' },
								ev.ip + '  ' + ev.was + ' → ' + ev.now)
						]);
					})))
			]));
		}

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
				E('span', { 'class': 'cb-dot', 'style': d.panic_on ? 'background:var(--danger)' : null }),
				E('span', {}, _('Protection')),
				d.panic_on
					? E('span', { 'class': 'cb-src cb-src-panic', 'style': 'margin-left:auto' },
						_('blocking new devices only'))
					: ''
			]),
			E('div', { 'class': 'cb-card-body' }, E('div', { 'class': 'cb-dash-rows' }, [
				row(_('Automatic protection'), d.auto_enabled
					? (_('on') + ' · ' + (d.threshold || '-') + ' / ' + (d.window || '-') + 's')
					: _('off')),
				row(_('Blocked addresses from auto-block'), (d.ips_auto || 0)),
				row(_('Schedule rules'), (d.schedules || 0) + ' (' + (d.schedules_active || 0) + ' ' + _('active now') + ')'),
				row(_('Trusted devices'), d.trusted || 0),
				row(_('New devices awaiting review'), d.pending || 0),
				row(_('MAC changes, last 24 hours'),
					(d.arp_24h || 0) + (d.arp_24h ? '' : '')),
				row(_('Groups'), d.groups || 0),
				row(_('Port restrictions'), d.ports || 0),
				row(_('Notification channels'), d.channels || 0),
				row(_('Logins today'), (d.logins_ok_today || 0) + ' ' + _('ok') + ' · ' + (d.logins_fail_today || 0) + ' ' + _('failed')),
				row(_('Failures in last 24h'), d.logins_fail_24h || 0),
				E('div', { 'class': 'cb-dash-row' }, [
					E('span', { 'class': 'cb-k' }, _('Current mode')),
					E('span', {
						'class': 'cb-v',
						'style': d.panic_on ? 'color:var(--danger)' : 'color:var(--success)'
					}, d.panic_on
						? _('blocking new devices only') +
						  (d.panic_since ? ' · ' + _('since') + ' ' + fmtTime(d.panic_since) : '')
						: _('normal'))
				]),
				E('div', { 'class': 'cb-actions', 'style': 'margin-top:.8rem' }, [
					d.panic_on
						? E('button', { 'class': 'cb-btn cb-btn-primary',
							'click': function (ev) { self.handlePanic(false, ev); } }, _('Back to normal'))
						: E('button', { 'class': 'cb-btn cb-btn-danger',
							'click': function (ev) { self.handlePanic(true, ev); } }, _('Block new devices only'))
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
				wrap.appendChild(E('div', { 'class': 'cb-actions', 'style': 'margin-top:.7rem' }, [
					E('button', { 'class': 'cb-btn cb-btn-primary',
						'click': function (ev) { self.refreshDash(); } }, _('Refresh')),
					!d.health_ok ? E('button', { 'class': 'cb-btn',
						'click': function (ev) { self.handleSync(ev); } }, _('Sync to kernel')) : ''
				]));
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

	// The browser sends the file straight to a small CGI, which writes it to
	// /tmp; the feed then points at that path with file://, so nothing has to
	// be served over the network or typed by hand.
	handleFeedUpload: function (ev) {
		var self = this;
		var input = document.getElementById('cb-feed-file');
		var f = input && input.files && input.files[0];
		if (!f) { ui.addNotification(null, E('p', {}, _('Pick a file first')), 'warning'); return; }
		var kind = (document.getElementById('cb-feed-kind') || {}).value || 'ip';
		var name = (document.getElementById('cb-feed-name') || {}).value || f.name;
		var btn = ev.currentTarget;
		btn.disabled = true;
		return fetch('/cgi-bin/lg-upload?name=' + encodeURIComponent(f.name), {
			method: 'POST', body: f, credentials: 'same-origin'
		}).then(function (r) { return r.json(); }).then(function (res) {
			if (!res || !res.path) throw new Error(_('Upload failed'));
			return callFeedAdd(name, 'file://' + res.path, '', kind, '');
		}).then(function (res) {
			if (res && res.success === false) throw new Error(res.error || _('Failed'));
			input.value = '';
			return self.refreshFeeds();
		}).catch(function (e) {
			ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error');
		}).finally(function () { btn.disabled = false; });
	},

	handleFeedAdd: function (ev) {
		var self = this;
		var n = (document.getElementById('cb-feed-name') || {}).value || '';
		var u = (document.getElementById('cb-feed-url') || {}).value || '';
		var k = (document.getElementById('cb-feed-kind') || {}).value || 'ip';
		if (!u) { ui.addNotification(null, E('p', {}, _('List URL is required')), 'warning'); return; }
		var btn = ev.currentTarget; btn.disabled = true;
		return callFeedAdd(n, u, '', k, '').then(function (res) {
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
			tbody.appendChild(E('tr', {}, E('td', { 'colspan': 7, 'class': 'cb-empty' },
				_('No subscriptions yet'))));
			return;
		}
		var INTERVALS = [
			{ v: 0,      l: _('manual') },
			{ v: 3600,   l: _('hourly') },
			{ v: 21600,  l: _('every 6 hours') },
			{ v: 86400,  l: _('daily') },
			{ v: 604800, l: _('weekly') }
		];

		list.forEach(function (f) {
			var cur = Number(f.interval) || 0;
			var sel = E('select', {
				'class': 'cb-sel',
				'change': function (ev) {
					var v = ev.target.value;
					callFeedSet(f.id, v).then(function () { self.renderFeeds(); })
						.catch(function (e) {
							ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error');
						});
				}
			}, INTERVALS.map(function (o) {
				return E('option', { 'value': o.v, 'selected': cur === o.v ? 'selected' : null }, o.l);
			}));

			tbody.appendChild(E('tr', {}, [
				E('td', { 'class': 'cb-u' }, [
					f.name || '',
					f.last_error
						? E('div', { 'class': 'cb-drop', 'title': f.last_error, 'style': 'color:var(--danger)' },
							_('last fetch failed'))
						: '',
					f.truncated
						? E('div', { 'class': 'cb-drop', 'style': 'color:var(--warning)',
							'title': _('only the first entries of a large list are imported') },
							_('truncated to') + ' ' + (f.imported || 0) + ' / ' + (f.total || 0))
						: ''
				]),
				E('td', { 'class': 'cb-hide-sm' }, f.kind || 'ip'),
				E('td', { 'class': 'cb-hide-sm' }, (f.kind === 'domain') ? _('domain blocking')
					: (f.kind === 'app') ? _('app recognition') : _('address blocking')),
				E('td', { 'class': 'cb-t' }, String(f.imported || 0)),
				E('td', {}, sel),
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

	refreshDomains: function () {
		var self = this;
		return callDomainList().then(function (res) {
			self.domains = (res && res.domains) || [];
			self.domainCount = (res && res.count) || 0;
			self.domainsEnabled = !!(res && res.enabled);
			self.renderDomains();
		}).catch(function () {});
	},

	renderDomains: function () {
		var box = document.getElementById('cb-domain-list');
		if (!box) return;
		var self = this;
		while (box.firstChild) box.removeChild(box.firstChild);

		var en = document.getElementById('cb-domain-enabled');
		if (en) en.checked = this.domainsEnabled !== false;

		var cnt = document.getElementById('cb-domain-count');
		if (cnt) cnt.textContent = (this.domainCount || 0) + ' ' + _('domains');

		var list = this.domains || [];
		if (!list.length) {
			box.appendChild(E('span', { 'class': 'cb-note' }, _('None configured')));
			return;
		}
		list.slice(0, 200).forEach(function (d) {
			box.appendChild(E('span', { 'class': 'cb-proxychip' }, [
				E('span', { 'class': 'cb-mono' }, d.domain),
				E('button', {
					'class': 'cb-proxyx', 'title': _('Remove'),
					'click': function () {
						return callDomainDel(d.domain).then(function () { return self.refreshDomains(); });
					}
				}, '\u00d7')
			]));
		});
		if (list.length > 200)
			box.appendChild(E('span', { 'class': 'cb-note' }, '+ ' + (this.domainCount - 200)));
	},

	handleDomainAdd: function (ev) {
		var self = this;
		var el = document.getElementById('cb-domain-input');
		if (!el) return;
		var name = (el.value || '').trim();
		if (!name) { el.focus(); return; }
		var btn = ev.currentTarget;
		btn.disabled = true;
		return callDomainAdd(name).then(function (res) {
			if (res && res.success === false) throw new Error(res.error || _('Failed'));
			el.value = '';
			return self.refreshDomains();
		}).catch(function (e) {
			ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error');
		}).finally(function () { btn.disabled = false; });
	},

	handleDomainToggle: function (on) {
		var self = this;
		return callDomainToggle(on ? '1' : '0').then(function () {
			return self.refreshDomains();
		}).catch(function (e) {
			ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error');
		});
	},

	refreshApps: function () {
		var self = this;
		return callAppList().then(function (res) {
			self.apps = (res && res.apps) || [];
			var cnt = document.getElementById('cb-app-count');
			if (cnt) cnt.textContent = self.apps.length + ' ' + _('apps');
			var sel = document.getElementById('cb-sig-app');
			if (sel) delete sel.dataset.filled;
		}).catch(function () {});
	},

	refreshAppStats: function () {
		var self = this;
		return Promise.all([ callAppList(), callAppStats() ]).then(function (r) {
			self.apps = (r[0] && r[0].apps) || [];
			self.appStats = r[1] || {};
			self.renderAppStats();
			var cnt = document.getElementById('cb-app-count');
			if (cnt) cnt.textContent = self.apps.length + ' ' + _('apps');
			var sel = document.getElementById('cb-sig-app');
			if (sel) delete sel.dataset.filled;
			var day = document.getElementById('cb-app-day');
			if (day) day.textContent = self.appStats.day || '';
		}).catch(function () {});
	},

	renderAppStats: function () {
		var tbody = document.getElementById('cb-app-tbody');
		if (!tbody) return;
		while (tbody.firstChild) tbody.removeChild(tbody.firstChild);

		var self = this;
		var list = (this.appStats && this.appStats.apps) || [];
		if (!list.length) {
			tbody.appendChild(E('tr', {}, E('td', { 'colspan': 4, 'class': 'cb-empty' },
				_('No traffic attributed yet'))));
			this.renderAppDevices();
			return;
		}
		list.slice(0, 50).forEach(function (a) {
			var meta = null;
			(self.apps || []).forEach(function (x) { if (x.name === a.name) meta = x; });
			var active = self.appFilter === a.name;
			tbody.appendChild(E('tr', {
				'style': 'cursor:pointer' + (active ? ';background:var(--brand-subtle)' : ''),
				'click': function () {
					self.appFilter = active ? null : a.name;
					self.renderAppStats();
				}
			}, [
				E('td', { 'class': 'cb-u' }, [
					a.name,
					(meta && meta.generic)
						? E('span', { 'class': 'cb-src cb-src-manual', 'style': 'margin-left:.35rem',
							'title': _('a broad vendor category, not a single app') }, _('broad'))
						: '',
					a.low > 0
						? E('span', { 'class': 'cb-src cb-src-panic', 'style': 'margin-left:.35rem',
							'title': _('part of this was matched by port only, without checking the packet') },
							_('port match'))
						: ''
				]),
				E('td', { 'class': 'cb-hide-sm' }, meta ? (meta.class || '') : ''),
				E('td', { 'class': 'cb-hide-sm cb-t' }, meta ? String(meta.sigs) : ''),
				E('td', { 'style': 'text-align:right;font-family:var(--font-mono)' }, fmtBytes(a.bytes))
			]));
		});
		this.renderAppDevices();
	},

	renderAppDevices: function () {
		var box = document.getElementById('cb-app-dev');
		if (!box) return;
		var self = this;
		while (box.firstChild) box.removeChild(box.firstChild);

		var devs = (this.appStats && this.appStats.dev) || [];
		var filter = this.appFilter;

		if (filter) {
			box.appendChild(E('div', { 'class': 'cb-dash-row' }, [
				E('span', { 'class': 'cb-k' }, _('Devices using') + ' ' + filter),
				E('button', { 'class': 'cb-btn', 'style': 'margin-left:auto',
					'click': function () { self.appFilter = null; self.renderAppStats(); } },
					_('Show all'))
			]));
			var users = [];
			devs.forEach(function (d) {
				(d.apps || []).forEach(function (x) {
					if (x.name === filter) users.push({ dev: d, bytes: x.bytes });
				});
			});
			users.sort(function (a, b) { return b.bytes - a.bytes; });
			if (!users.length) {
				box.appendChild(E('span', { 'class': 'cb-note' }, _('None')));
				return;
			}
			users.forEach(function (u) {
				box.appendChild(E('div', { 'class': 'cb-dash-row' }, [
					E('span', { 'class': 'cb-k' }, (u.dev.name || u.dev.ip) + ' · ' + u.dev.ip),
					E('span', { 'class': 'cb-v' }, fmtBytes(u.bytes))
				]));
			});
			return;
		}

		if (!devs.length) {
			box.appendChild(E('span', { 'class': 'cb-note' }, _('None')));
			return;
		}
		devs.slice(0, 20).forEach(function (d) {
			box.appendChild(E('div', { 'class': 'cb-dash-row' }, [
				E('span', { 'class': 'cb-k' }, [
					(d.name || d.ip),
					E('span', { 'class': 'cb-drop' }, '  ' + d.ip)
				]),
				E('span', { 'class': 'cb-v' }, d.apps.slice(0, 3).map(function (x) {
					return x.name + ' ' + fmtBytes(x.bytes);
				}).join(' · '))
			]));
		});
	},

	refreshSample: function () {
		var self = this;
		return callSampleResult().then(function (res) {
			self.sample = res || {};
			self.renderSample();
			if (res && res.running) {
				if (!self.sampleTimer) {
					self.sampleTimer = window.setInterval(function () { self.refreshSample(); }, 3000);
				}
			} else if (self.sampleTimer) {
				window.clearInterval(self.sampleTimer);
				self.sampleTimer = null;
			}
		}).catch(function () {});
	},

	renderSample: function () {
		var tbody = document.getElementById('cb-sample-tbody');
		if (!tbody) return;
		var self = this;
		while (tbody.firstChild) tbody.removeChild(tbody.firstChild);

		var running = !!(this.sample && this.sample.running);
		var pkts = (this.sample && this.sample.packets) || 0;
		var started = (this.sample && this.sample.started) || 0;
		var dur = (this.sample && this.sample.duration) || 0;
		var left = running && started && dur ? Math.max(0, dur - (Math.floor(Date.now() / 1000) - started)) : 0;

		var st = document.getElementById('cb-sample-state');
		if (st) st.textContent = running ? _('capturing') : (pkts ? _('stopped') : '');

		// the state has to be unmistakable: a dot, the remaining time, and the
		// button that would do nothing is disabled
		var live = document.getElementById('cb-sample-live');
		if (live) {
			while (live.firstChild) live.removeChild(live.firstChild);
			if (running) {
				live.appendChild(E('span', {
					'class': 'cb-res cb-health-ok', 'style': 'margin-right:.35rem' },
					'● ' + _('capturing') + ' · ' + pkts + ' ' + _('packets') +
					(left ? ' · ' + left + 's' : '')));
			} else if (pkts) {
				live.appendChild(E('span', { 'class': 'cb-drop' },
					'○ ' + _('stopped') + ' · ' + pkts + ' ' + _('packets')));
			} else {
				live.appendChild(E('span', { 'class': 'cb-drop' }, '○ ' + _('not sampling')));
			}
		}
		var sb = document.getElementById('cb-sample-start');
		if (sb) sb.disabled = running;
		var tb = document.getElementById('cb-sample-stop');
		if (tb) tb.disabled = !running;

		var groups = (this.sample && this.sample.groups) || [];
		if (!groups.length) {
			tbody.appendChild(E('tr', {}, E('td', { 'colspan': 7, 'class': 'cb-empty' },
				_('No capture yet'))));
			return;
		}
		groups.forEach(function (g) {
			tbody.appendChild(E('tr', {}, [
				E('td', { 'class': 'cb-mono' }, g.proto),
				E('td', { 'class': 'cb-mono' }, String(g.dport)),
				E('td', { 'class': 'cb-mono', 'style': 'font-size:.75rem' }, g.prefix),
				E('td', { 'class': 'cb-hide-sm cb-t' }, String(g.count)),
				E('td', { 'class': 'cb-hide-sm', 'style': 'font-size:.75rem' }, (g.dsts || []).slice(0, 2).join(' ')),
				E('td', { 'style': 'text-align:right' },
					E('button', { 'class': 'cb-btn',
						'click': function () {
							var name = prompt(_('Name this app'), '');
							if (!name) return;
							callSampleSave(name, g.proto, String(g.dport), g.prefix, 'game')
								.then(function () { return self.refreshAppStats(); })
								.catch(function (e) {
									ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error');
								});
						} }, _('Save as signature')))
			]));
		});
	},

	handleSampleStart: function (ev) {
		var self = this;
		var dur = (document.getElementById('cb-sample-dur') || {}).value || '60';
		return callSampleStart(dur).then(function () {
			return self.refreshSample();
		}).catch(function (e) {
			ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error');
		});
	},

	handleSampleStop: function (ev) {
		var self = this;
		return callSampleStop().then(function () { return self.refreshSample(); })
			.catch(function () {});
	},

	refreshQos: function () {
		var self = this;
		return callQosList().then(function (res) {
			self.qos = (res && res.rules) || [];
			self.renderQos();
		}).catch(function () {});
	},

	renderQos: function () {
		var self = this;
		var tbody = document.getElementById('cb-qos-tbody');
		if (!tbody) return;
		while (tbody.firstChild) tbody.removeChild(tbody.firstChild);

		// device picker
		var dev = document.getElementById('cb-qos-dev');
		if (dev && !dev.dataset.filled) {
			dev.appendChild(E('option', { 'value': '' }, _('All devices')));
			(this.devices || []).forEach(function (d) {
				if (!d.ip) return;
				dev.appendChild(E('option', { 'value': d.ip },
					(d.host || d.mac) + ' · ' + d.ip));
			});
			dev.dataset.filled = '1';
		}
		var appSel = document.getElementById('cb-qos-app');
		if (appSel && !appSel.dataset.filled) {
			appSel.appendChild(E('option', { 'value': '' }, _('All apps')));
			(this.apps || []).forEach(function (a) {
				appSel.appendChild(E('option', { 'value': a.name }, a.name));
			});
			appSel.dataset.filled = '1';
		}

		var list = this.qos || [];
		if (!list.length) {
			tbody.appendChild(E('tr', {}, E('td', { 'colspan': 7, 'class': 'cb-empty' },
				_('No rate rules yet'))));
			return;
		}
		list.forEach(function (r) {
			tbody.appendChild(E('tr', {}, [
				E('td', {}, r.ip || _('All devices')),
				E('td', { 'class': 'cb-u' }, r.app || _('All apps')),
				E('td', { 'class': 'cb-mono' },
					r.action === 'block'
						? E('span', { 'class': 'cb-src cb-src-panic' }, _('blocked'))
						: r.dscp),
				E('td', { 'class': 'cb-hide-sm cb-t' }, String(r.ips || 0)),
				E('td', { 'style': 'text-align:right' },
					E('button', { 'class': 'cb-btn cb-btn-danger',
						'click': function () {
							callQosDel(r.id).then(function () { return self.refreshQos(); });
						} }, _('Delete')))
			]));
		});
	},

	handleQosAdd: function (ev) {
		var self = this;
		var ip = (document.getElementById('cb-qos-dev') || {}).value || '';
		var app = (document.getElementById('cb-qos-app') || {}).value || '';
		var dscp = (document.getElementById('cb-qos-dscp') || {}).value || 'cs1';
		if (!ip && !app) {
			ui.addNotification(null, E('p', {}, _('Pick a device, an app, or both')), 'warning');
			return;
		}
		var btn = ev.currentTarget;
		btn.disabled = true;
		return callQosAdd(ip, app, dscp).then(function () {
			return self.refreshQos();
		}).catch(function (e) {
			ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error');
		}).finally(function () { btn.disabled = false; });
	},

	refreshDomainHits: function () {
		var self = this;
		return callDomainHits(40).then(function (res) {
			self.dh = res || {};
			var st = document.getElementById('cb-dh-state');
			if (st) st.textContent = self.dh.enabled
				? (self.dh.count || 0) + ' ' + _('hits')
				: _('logging off');
			var tb = document.getElementById('cb-dh-tbody');
			if (!tb) return;
			while (tb.firstChild) tb.removeChild(tb.firstChild);
			var hits = (self.dh.hits || []);
			if (!hits.length) {
				tb.appendChild(E('tr', {}, E('td', { 'colspan': 2, 'class': 'cb-empty' },
					self.dh.enabled ? _('No blocked domain was queried yet') : _('Enable DNS logging to see hits'))));
				return;
			}
			hits.forEach(function (h) {
				tb.appendChild(E('tr', {}, [
					E('td', { 'class': 'cb-mono' }, h.domain),
					E('td', { 'class': 'cb-mono' }, h.ip)
				]));
			});
		}).catch(function () {});
	},

	handleDomainLog: function (ev) {
		var self = this;
		var on = !(this.dh && this.dh.enabled);
		return callDomainLog(on ? '1' : '0').then(function () {
			return self.refreshDomainHits();
		}).catch(function (e) {
			ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error');
		});
	},

	handleAppUrlImport: function (ev) {
		var self = this;
		var url = (document.getElementById('cb-app-url') || {}).value || '';
		var name = (document.getElementById('cb-app-urlname') || {}).value || '';
		if (!url.trim()) return;
		if (!name.trim()) {
			ui.addNotification(null, E('p', {}, _('Give the app a name first')), 'warning');
			return;
		}
		var btn = ev.currentTarget;
		btn.disabled = true;
		return callFeedAdd(name.trim(), url.trim(), '', 'app', 'other').then(function (res) {
			if (res && res.success === false) throw new Error(res.error || _('Failed'));
			document.getElementById('cb-app-url').value = '';
			document.getElementById('cb-app-urlname').value = '';
			return self.refreshAppStats();
		}).catch(function (e) {
			ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error');
		}).finally(function () { btn.disabled = false; });
	},

	loadSigs: function (name) {
		var self = this;
		var sel = document.getElementById('cb-sig-app');
		if (sel && !sel.dataset.filled) {
			sel.appendChild(E('option', { 'value': '' }, _('Pick an app')));
			(this.apps || []).forEach(function (a) {
				sel.appendChild(E('option', { 'value': a.name }, a.name));
			});
			sel.dataset.filled = '1';
			if (name) sel.value = name;
		}
		if (!name) return;
		return callSigList(name).then(function (res) {
			self.sigs = (res && res.sigs) || [];
			self.sigApp = name;
			self.renderSigs();
		}).catch(function () {});
	},

	renderSigs: function () {
		var tbody = document.getElementById('cb-sig-tbody');
		if (!tbody) return;
		var self = this;
		while (tbody.firstChild) tbody.removeChild(tbody.firstChild);
		var cnt = document.getElementById('cb-sig-count');
		if (cnt) cnt.textContent = (this.sigs || []).length + ' ' + _('signatures');
		if (!(this.sigs || []).length) {
			tbody.appendChild(E('tr', {}, E('td', { 'colspan': 5, 'class': 'cb-empty' }, _('None'))));
			return;
		}
		this.sigs.forEach(function (sg) {
			tbody.appendChild(E('tr', {}, [
				E('td', { 'class': 'cb-mono' }, sg.proto || '-'),
				E('td', { 'class': 'cb-mono' }, sg.dport || '-'),
				E('td', { 'class': 'cb-mono' }, sg.host || '-'),
				E('td', { 'class': 'cb-mono', 'style': 'font-size:.72rem' }, sg.dict || '-'),
				E('td', { 'style': 'text-align:right' },
					E('button', { 'class': 'cb-btn cb-btn-danger', 'style': 'padding:.05rem .5rem',
						'click': function () {
							callSigDel(self.sigApp, sg.idx).then(function () {
								return self.loadSigs(self.sigApp);
							});
						} }, _('Delete')))
			]));
		});
	},

	handleAppImport: function (ev) {
		var self = this;
		var ta = document.getElementById('cb-app-import');
		if (!ta || !ta.value.trim()) { if (ta) ta.focus(); return; }
		var btn = ev.currentTarget;
		btn.disabled = true;
		return callAppImport(ta.value).then(function (res) {
			if (res && res.success === false) throw new Error(res.error || _('Failed'));
			ta.value = '';
			ui.addNotification(null, E('p', {},
				_('Imported') + ' ' + (res.added || 0) + ' · ' + _('total') + ' ' + (res.total || 0)), 'info');
			return self.refreshAppStats();
		}).catch(function (e) {
			ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error');
		}).finally(function () { btn.disabled = false; });
	},

	handleAppReset: function (ev) {
		var self = this;
		if (!confirm(_('Reset the traffic counters?'))) return;
		var btn = ev.currentTarget;
		btn.disabled = true;
		return callAppReset().then(function () { return self.refreshAppStats(); })
			.catch(function () {})
			.finally(function () { btn.disabled = false; });
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
			tbody.appendChild(E('tr', {}, E('td', { 'colspan': 7, 'class': 'cb-empty' },
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

	// Rebuild the two kernel sets from saved state. This only touches set
	// elements, so it is safe to run while the LAN is busy.
	handleSync: function (ev) {
		var self = this;
		var btn = ev && ev.currentTarget;
		if (btn) btn.disabled = true;
		return callSync().then(function () {
			ui.addNotification(null, E('p', {}, _('Kernel set rebuilt from saved state')), 'info');
			return Promise.all([ self.refreshHealth(), self.refreshDash() ]);
		}).catch(function (e) {
			ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error');
		}).finally(function () { if (btn) btn.disabled = false; });
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

		var self = this;
		var FIXABLE = { nftset: 1, rulesfile: 1, nfthook: 1 };

		list.forEach(function (c) {
			var bad = !c.ok;
			var extra = [];
			if (bad && c.hint) extra.push(E('span', { 'class': 'cb-hint' }, c.hint));
			if (bad && FIXABLE[c.id]) {
				extra.push(E('span', { 'class': 'cb-hint' },
					E('button', {
						'class': 'cb-btn cb-btn-primary',
						'style': 'font-size:.75rem;padding:.1rem .55rem',
						'click': function (ev) { self.handleSync(ev); }
					}, _('Fix now'))));
			}
			box.appendChild(E('div', { 'class': 'cb-check' + (bad ? ' bad' : '') }, [
				E('span', { 'class': 'cb-mark ' + (bad ? 'bad' : 'ok') }, bad ? '\u2715' : '\u2713'),
				E('span', { 'class': 'cb-name' }, names[c.id] || c.id),
				E('span', { 'class': 'cb-val' }, c.detail || '')
			].concat(extra)));
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
				E('td', { 'class': 'cb-t' }, (function () {
					// the day separator already carries the date; on a phone the
					// column only needs the clock
					var ft = fmtTime(e.ts), sp = ft.indexOf(' ');
					if (sp < 0) return ft;
					return [ E('span', { 'class': 'cb-date' }, ft.slice(0, sp)), ' ', ft.slice(sp + 1) ];
				})()),
				E('td', {}, resBadge),
				E('td', {}, srcBadge),
				E('td', { 'class': 'cb-hide-sm' }, authBadge),
				E('td', { 'class': 'cb-ip' }, [
					e.ip || '-',
					e.host ? E('span', { 'class': 'cb-drop' }, ' ' + e.host) : ''
				]),
				E('td', { 'class': 'cb-u cb-hide-sm' }, e.user || '-'),
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

		box.appendChild(E('div', { 'class': 'cb-subhead' }, _('Trusted proxies')));
		box.appendChild(E('p', { 'class': 'cb-note' },
			_('A reverse proxy in front of the LAN makes every request look like it came from the proxy itself. Addresses listed here are never blocked, and when a log line names one of them as the source, the real client is read from X-Forwarded-For / X-Real-IP instead.')));
		box.appendChild(E('div', { 'class': 'cb-proxylist', 'id': 'cb-proxy-list' }, []));
		box.appendChild(E('div', { 'class': 'cb-actions' }, [
			E('input', {
				'type': 'text', 'id': 'cb-proxy-input', 'class': 'cb-input',
				'placeholder': '192.168.1.5',
				'style': 'max-width:14rem'
			}),
			E('button', { 'class': 'cb-btn cb-btn-primary',
				'click': function (ev) { self.handleProxyAdd(ev); } }, _('Add')),
			E('button', { 'class': 'cb-btn',
				'click': function () {
					var el = document.getElementById('cb-proxy-input');
					if (el) el.value = '192.168.1.5';
				} }, _('Use router address'))
		]));

	},

	refreshProxies: function () {
		var self = this;
		var box = document.getElementById('cb-proxy-list');
		if (!box) return;
		return callProxyList().then(function (res) {
			var list = (res && res.proxies) || [];
			while (box.firstChild) box.removeChild(box.firstChild);
			if (!list.length) {
				box.appendChild(E('span', { 'class': 'cb-note' }, _('None configured')));
				return;
			}
			list.forEach(function (p) {
				box.appendChild(E('span', { 'class': 'cb-proxychip' }, [
					E('span', { 'class': 'cb-mono' }, p.ip),
					E('button', {
						'class': 'cb-proxyx',
						'title': _('Remove'),
						'click': function () {
							return callProxyDel(p.ip).then(function () {
								return self.refreshProxies();
							});
						}
					}, '\u00d7')
				]));
			});
		}).catch(function () {});
	},

	handleProxyAdd: function (ev) {
		var self = this;
		var el = document.getElementById('cb-proxy-input');
		if (!el) return;
		var ip = (el.value || '').trim();
		if (!ip) { el.focus(); return; }
		var btn = ev.currentTarget;
		btn.disabled = true;
		return callProxyAdd(ip).then(function (res) {
			if (res && res.success === false)
				throw new Error(res.error || _('Failed'));
			el.value = '';
			return self.refreshProxies();
		}).catch(function (e) {
			ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error');
		}).finally(function () {
			btn.disabled = false;
		});
	},

	refreshIps: function () {
		var self = this;
		return callIpList(0, this.ipCat || '').then(function (res) {
			self.ips = (res && res.ips) || [];
			self.ipCount = (res && res.count) || 0;
			self.ipMatched = (res && res.matched) || 0;
			self.ipCats = (res && res.categories) || [];
			self.renderIpChips();
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

	renderIpChips: function () {
		var box = document.getElementById('cb-ip-cats');
		if (!box) return;
		var self = this;
		while (box.firstChild) box.removeChild(box.firstChild);

		var counts = { '': this.ipCount || 0 };
		(this.ipCats || []).forEach(function (c) { counts[c.key] = c.count; });

		IP_CATS.forEach(function (c) {
			var n = counts[c.key];
			// keep the full taxonomy visible so it is discoverable; "other" is
			// the catch-all and only appears when something landed in it
			if (c.key === 'other' && !n) return;
			var on = (self.ipCat || '') === c.key;
			box.appendChild(E('button', {
				'class': 'cb-catchip' + (on ? ' cb-catchip-on' : '') + (n ? '' : ' cb-catchip-zero'),
				'click': function () {
					self.ipCat = c.key;
					self.refreshIps();
				}
			}, [
				E('span', { 'class': 'cb-src ' + c.cls, 'style': 'margin-right:.35rem' }, c.label),
				E('span', {}, String(n || 0))
			]));
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
			if (this.ipCat && !q) {
				emptyCell.appendChild(document.createTextNode(
					_('No entries in this category')));
				tbody.appendChild(E('tr', {}, emptyCell));
				var cnt0 = document.getElementById('cb-ip-count');
				if (cnt0) cnt0.textContent = '0 / ' + (this.ipCount || 0) + ' ' + _('blocked');
				return;
			}
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
				].concat((function () {
					var c = catMeta(r.category);
					var text = (r.category === 'feed' && r.feed_name) ? r.feed_name : c.label;
					return [ ' ', E('span', { 'class': 'cb-src ' + c.cls, 'title': c.label }, text) ];
				})())),
				E('td', { 'class': 'cb-hide-sm', 'style': 'font-size:.8rem;opacity:.85' }, fmtGeo(r.geo) || E('span', { 'class': 'cb-drop' }, '-')),
				E('td', {}, r.note || ''),
				E('td', { 'class': 'cb-drop cb-hide-sm' }, (r.drop_packets || 0) + ' pkt / ' + fmtBytes(r.drop_bytes)),
				E('td', { 'class': 'cb-drop' }, fmtTime(r.since)),
				E('td', { 'style': 'text-align:right' },
					E('button', {
						'class': 'cb-btn cb-btn-ok',
						'click': function (ev) { self.handleIpDel(r.ip, ev); }
					}, _('Unblock')))
			]));
		});

		var cnt = document.getElementById('cb-ip-count');
		if (cnt) {
			var matched = this.ipCat ? (this.ipMatched || 0) : (this.ipCount || 0);
			var txt = (this.ipCat ? matched + ' / ' + (this.ipCount || 0) : matched) + ' ' + _('blocked');
			if (matched > list.length)
				txt += ' · ' + _('showing first') + ' ' + list.length;
			cnt.textContent = txt;
		}
	},

	// One tab may own several panes (Settings groups protection, notifications,
	// health and backup).
	tabPanes: {
		overview: [ 'dash' ],
		devices: [ 'devices' ],
		apps: [ 'apps' ],
		ips: [ 'ips', 'sched' ],
		feeds: [ 'feeds' ],
		settings: [ 'auto', 'notify', 'health', 'backup', 'logs' ]
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
		['overview', 'devices', 'apps', 'ips', 'feeds', 'settings'].forEach(function (t) {
			var btn = document.getElementById('cb-tab-' + t);
			if (btn) btn.classList.toggle('active', t === name);
		});
		if (name === 'overview') return this.refreshDash();
		if (name === 'devices') {
			var selfD = this;
			return Promise.all([ this.refresh(), callList('0') ]).then(function (r) {
				selfD.devices = (r[1] && r[1].devices) || selfD.devices || [];
				return Promise.all([ selfD.refreshApps(), selfD.refreshQos() ]);
			});
		}
		if (name === 'ips') return Promise.all([ this.refreshIps(), this.refreshDomains(),
			this.refreshSched(), this.refreshGroups(), this.refreshPorts() ]);
		if (name === 'apps') {
			var selfA = this;
			return Promise.all([ this.refreshApps(), this.refreshAppStats(), callList('0'), this.refreshSample(), this.refreshDomainHits() ])
				.then(function (r) {
					selfA.devices = (r[2] && r[2].devices) || selfA.devices || [];
					return selfA.refreshQos();
				});
		}
		if (name === 'feeds') return this.refreshFeeds();
		if (name === 'settings') {
			var self2 = this;
			return Promise.all([ this.refreshAuto(), this.refreshNotify(), this.refreshHealth() ])
				.then(function () { return self2.refreshProxies(); });
		}
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
			var conflictBadge = d.conflict
				? E('span', {
					'class': 'cb-src cb-src-panic', 'style': 'margin-left:.35rem',
					'title': _('this address is also claimed by') + ' ' + d.conflict
				}, _('IP conflict'))
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

			// a container or VM on the same box answers with its own generated
			// MAC; offer to fold it into the physical device
			var mergeBtn = (d.local_mac && d.conflict)
				? E('button', {
					'class': 'cb-btn', 'style': 'margin-right:.3rem',
					'title': _('this interface belongs to another device'),
					'click': function () {
						callDevMerge(d.mac, d.conflict).then(function () {
							return self.refresh();
						}).catch(function (e) {
							ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error');
						});
					}
				}, _('Merge into') + ' ' + d.conflict)
				: '';

			var aliasNote = (d.aliases && d.aliases.length)
				? E('div', { 'class': 'cb-drop', 'style': 'margin-top:.15rem' }, [
					d.aliases.length + ' ' + _('merged interface(s)'),
					E('button', {
						'class': 'cb-proxyx', 'title': _('Undo merge'),
						'click': function () {
							callDevUnmerge(d.aliases[0]).then(function () { return self.refresh(); })
								.catch(function () {});
						}
					}, '\u00d7')
				])
				: '';

			tbody.appendChild(E('tr', { 'class': d.blocked ? 'cb-blocked' : (d.online ? '' : 'cb-offline') }, [
				E('td', {}, [ stateBadge, newBadge, conflictBadge ]),
				E('td', {}, [
					nameCell,
					(d.vendor || d.device_type)
						? E('div', { 'class': 'cb-drop cb-vendor', 'title': (d.vendor || '') + ' · ' + typeLabel(d.device_type) },
							(d.vendor || _('unknown vendor')) + ' · ' + typeLabel(d.device_type))
						: '',
					aliasNote
				]),
				E('td', { 'class': 'cb-mono' }, d.ip || '-'),
				E('td', { 'class': 'cb-mono cb-hide-sm' }, d.mac),
				E('td', { 'class': 'cb-drop cb-hide-sm' }, d.first_seen
					? ((d.first_assumed ? '≈ ' : '') + fmtTime(d.first_seen))
					: '-'),
				E('td', { 'class': 'cb-hide-sm' }, d.blocked ? [ dropText, E('br'), E('span', { 'class': 'cb-drop' }, fmtTime(d.blocked_at)) ] : ''),
				E('td', { 'style': 'text-align:right;white-space:nowrap' }, [ mergeBtn, trustBtn, action ])
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
E('div', { 'class': 'cb-card' }, [
				E('div', { 'class': 'cb-card-head' }, [
					E('span', { 'class': 'cb-dot' }), E('span', {}, _('Rate rules'))
				]),
				E('div', { 'class': 'cb-card-body' }, [
					E('p', { 'class': 'cb-note' },
						_('Sets a DSCP class on matching traffic; qosmate turns that into an hfsc class. Choosing block drops the traffic outright, which also works for proxied apps because the drop happens before Clash can pick the packet up. Leave the device empty to cover every device.')),
					E('div', { 'class': 'cb-actions', 'style': 'margin-bottom:.6rem' }, [
						E('select', { 'id': 'cb-qos-dev', 'class': 'cb-sel' }, []),
						E('select', { 'id': 'cb-qos-app', 'class': 'cb-sel' }, []),
						E('select', { 'id': 'cb-qos-dscp', 'class': 'cb-sel' }, [
							E('option', { 'value': 'cs1' }, _('lowest (cs1)')),
							E('option', { 'value': 'af11' }, _('low (af11)')),
							E('option', { 'value': 'cs0' }, _('normal (cs0)')),
							E('option', { 'value': 'cs4' }, _('high (cs4)')),
							E('option', { 'value': 'ef' }, _('highest (ef)')),
							E('option', { 'value': 'block' }, _('block entirely'))
						]),
						E('button', { 'class': 'cb-btn cb-btn-primary',
							'click': function (ev) { self.handleQosAdd(ev); } }, _('Add rule'))
					]),
					E('div', { 'class': 'cb-tablewrap' }, [
						E('table', { 'class': 'cb-table' }, [
							E('thead', {}, E('tr', {}, [
								E('th', {}, _('Device')),
								E('th', {}, _('App')),
								E('th', {}, _('Class')),
								E('th', { 'class': 'cb-hide-sm' }, _('Addresses')),
								E('th', { 'style': 'text-align:right' }, _('Action'))
							])),
							E('tbody', { 'id': 'cb-qos-tbody' })
						])
					])
				])
			]),
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
					E('th', { 'class': 'cb-hide-sm' }, _('MAC')),
					E('th', { 'class': 'cb-hide-sm' }, _('First seen')),
					E('th', { 'class': 'cb-hide-sm' }, _('Dropped')),
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
			,
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
			E('div', { 'class': 'cb-ipcats', 'id': 'cb-ip-cats' }, []),
			E('div', { 'class': 'cb-toolbar' }, [
				ipSearch,
				E('span', { 'class': 'cb-count', 'id': 'cb-ip-count' }, '')
			]),
			E('table', { 'class': 'cb-table' }, [
				E('thead', {}, E('tr', {}, [
					E('th', {}, _('Address')),
					E('th', { 'class': 'cb-hide-sm' }, _('Region')),
					E('th', {}, _('Note')),
					E('th', {}, _('Dropped')),
					E('th', {}, _('Since')),
					E('th', { 'style': 'text-align:right' }, _('Action'))
				])),
				E('tbody', { 'id': 'cb-ip-tbody' })
			]),
			E('div', { 'class': 'cb-card', 'style': 'margin-top:1rem' }, [
				E('div', { 'class': 'cb-card-head' }, [
					E('span', { 'class': 'cb-dot' }),
					E('span', {}, _('Domain blocking')),
					E('span', { 'class': 'cb-count', 'id': 'cb-domain-count', 'style': 'margin-left:auto' }, '')
				]),
				E('div', { 'class': 'cb-card-body' }, [
					E('p', { 'class': 'cb-note' },
						_('Domains are answered with 0.0.0.0 and :: by dnsmasq, so the whole LAN is covered without touching the firewall. Feed entries that are hostnames land here instead of the address list.')),
					E('div', { 'class': 'cb-actions', 'style': 'margin-bottom:.6rem' }, [
						E('input', { 'type': 'text', 'id': 'cb-domain-input', 'class': 'cb-input',
							'placeholder': 'ads.example.com', 'style': 'max-width:16rem' }),
						E('button', { 'class': 'cb-btn cb-btn-primary',
							'click': function (ev) { self.handleDomainAdd(ev); } }, _('Block domain')),
						E('label', { 'class': 'cb-chip', 'style': 'margin:0' }, [
							E('input', { 'type': 'checkbox', 'id': 'cb-domain-enabled',
								'change': function (ev) { self.handleDomainToggle(ev.target.checked); } }),
							E('span', {}, _('enabled'))
						])
					]),
					E('div', { 'class': 'cb-proxylist', 'id': 'cb-domain-list' }, [])
				])
			])
		]);

		var feedsPane = E('div', {
			'class': 'cb-pane',
			'id': 'cb-pane-feeds'
		}, [
			E('p', { 'style': 'opacity:.75;margin:.25rem 0 1rem' },
				_('Lists pulled from the internet. Each one declares what it feeds: an IP list becomes blocked addresses, a domain list becomes DNS blocks, an app list becomes the signatures used to recognise an app.')),
			E('div', { 'class': 'cb-note', 'style': 'margin:0 0 1rem;line-height:1.7' }, [
				E('div', {}, _('IP list') + ' — ' + _('one address or CIDR per line; # comments, CSV columns and Spamhaus ; tails are tolerated')),
				E('div', {}, _('Domain list') + ' — ' + _('one hostname per line; # comments ignored')),
				E('div', {}, _('App signatures') + ' — ' + _('OAF format v3.0: id name:[proto;sport;dport;host;request;dict]')),
				E('div', {}, _('Geosite bundle') + ' — ' + _('a v2ray .dat file holding every category at once; routing categories are skipped'))
			]),
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
						E('label', {}, [ E('span', {}, _('Type')),
							E('select', { 'id': 'cb-feed-kind', 'class': 'cb-sel' }, [
								E('option', { 'value': 'ip' }, _('IP list')),
								E('option', { 'value': 'domain' }, _('Domain list')),
								E('option', { 'value': 'app' }, _('App signatures')),
								E('option', { 'value': 'geosite' }, _('Geosite bundle'))
							]) ]),
						E('label', {}, [ E('span', {}, _('List URL')),
							E('input', { 'type': 'text', 'id': 'cb-feed-url', 'placeholder': 'https://host/list.netset',
								'style': 'width:18rem;padding:.35rem .5rem;border-radius:.3rem;border:1px solid var(--hairline);background:var(--surface-sunken);color:inherit' }) ]),
						E('button', { 'class': 'cb-btn',
							'click': function (ev) { self.handleFeedAdd(ev); } }, _('Add feed')),
						E('input', { 'type': 'file', 'id': 'cb-feed-file', 'style': 'max-width:14rem' }),
						E('button', { 'class': 'cb-btn',
							'click': function (ev) { self.handleFeedUpload(ev); } }, _('Upload file'))
					]),
					E('div', { 'class': 'cb-tablewrap' }, [
						E('table', { 'class': 'cb-table' }, [
							E('thead', {}, E('tr', {}, [
								E('th', {}, _('Name')), E('th', { 'class': 'cb-hide-sm' }, _('Type')),
							E('th', { 'class': 'cb-hide-sm' }, _('Feeds into')), E('th', {}, _('Imported')),
								E('th', {}, _('Refresh')), E('th', {}, _('Last fetch')),
								E('th', { 'style': 'text-align:right' }, _('Action'))
							])),
							E('tbody', { 'id': 'cb-feed-tbody' })
						])
					])
				])
			])
		]);

		var appsPane = E('div', {
			'class': 'cb-pane',
			'id': 'cb-pane-apps'
		}, [
			E('p', { 'style': 'opacity:.75;margin:.25rem 0 1rem' },
				_('Traffic attributed to applications. Proxied flows are named by the hostname Clash reports; everything else is matched from the router flow table by port or address range.')),
			E('div', { 'class': 'cb-card' }, [
				E('div', { 'class': 'cb-card-head' }, [
					E('span', { 'class': 'cb-dot' }),
					E('span', {}, _('Traffic by app')),
					E('span', { 'class': 'cb-count', 'id': 'cb-app-day', 'style': 'margin-left:auto' }, '')
				]),
				E('div', { 'class': 'cb-card-body' }, [
					E('div', { 'class': 'cb-tablewrap' }, [
						E('table', { 'class': 'cb-table' }, [
							E('thead', {}, E('tr', {}, [
								E('th', {}, _('App')),
								E('th', { 'class': 'cb-hide-sm' }, _('Class')),
								E('th', { 'class': 'cb-hide-sm' }, _('Rules')),
								E('th', { 'style': 'text-align:right' }, _('Traffic'))
							])),
							E('tbody', { 'id': 'cb-app-tbody' })
						])
					]),
					E('div', { 'class': 'cb-actions', 'style': 'margin-top:.7rem' }, [
						E('button', { 'class': 'cb-btn', 'click': function (ev) { self.refreshAppStats(ev); } }, _('Refresh')),
						E('button', { 'class': 'cb-btn cb-btn-danger', 'click': function (ev) { self.handleAppReset(ev); } }, _('Reset counters'))
					])
				])
			]),
			E('div', { 'class': 'cb-card' }, [
				E('div', { 'class': 'cb-card-head' }, [
					E('span', { 'class': 'cb-dot' }), E('span', {}, _('Blocked domains')),
					E('span', { 'class': 'cb-count', 'id': 'cb-dh-state', 'style': 'margin-left:auto' }, '')
				]),
				E('div', { 'class': 'cb-card-body' }, [
					E('div', { 'class': 'cb-actions', 'style': 'margin-bottom:.5rem' }, [
						E('button', { 'class': 'cb-btn',
							'click': function (ev) { self.handleDomainLog(ev); } }, _('Enable DNS logging')),
						E('span', { 'class': 'cb-note' },
							_('Hits are only visible in dnsmasq\'s query log, which records one line per query.'))
					]),
					E('div', { 'class': 'cb-tablewrap' }, [
						E('table', { 'class': 'cb-table' }, [
							E('thead', {}, E('tr', {}, [
								E('th', {}, _('Domain')),
								E('th', {}, _('Device'))
							])),
							E('tbody', { 'id': 'cb-dh-tbody' })
						])
					])
				])
			]),
			E('div', { 'class': 'cb-card' }, [
				E('div', { 'class': 'cb-card-head' }, [
					E('span', { 'class': 'cb-dot' }), E('span', {}, _('By device'))
				]),
				E('div', { 'class': 'cb-card-body' }, E('div', { 'id': 'cb-app-dev', 'class': 'cb-dash-rows' }))
			]),
			E('div', { 'class': 'cb-card' }, [
				E('div', { 'class': 'cb-card-head' }, [
					E('span', { 'class': 'cb-dot' }), E('span', {}, _('Signature library'))
				]),
				E('div', { 'class': 'cb-card-body' }, [
					E('p', { 'class': 'cb-note' },
						_('Paste a feature library (OAF format v3.0) to import it. Entries are matched by hostname, address range or a distinctive port; signatures that only name port 80/443 are skipped because they would claim the whole web.')),
					E('textarea', {
						'id': 'cb-app-import', 'class': 'cb-import',
						'rows': '6', 'placeholder': '#class game 2 游戏\n2001 王者荣耀:[tcp;;6000-9000;;;]'
					}),
					E('div', { 'class': 'cb-actions', 'style': 'margin-top:.6rem' }, [
						E('button', { 'class': 'cb-btn cb-btn-primary',
							'click': function (ev) { self.handleAppImport(ev); } }, _('Import')),
						E('span', { 'class': 'cb-count', 'id': 'cb-app-count' }, '')
					]),
					E('div', { 'class': 'cb-actions', 'style': 'margin:.6rem 0' }, [
						E('input', { 'type': 'text', 'id': 'cb-app-url', 'class': 'cb-input',
							'placeholder': 'https://raw.githubusercontent.com/v2fly/domain-list-community/master/data/bilibili',
							'style': 'flex:1 1 18rem' }),
						E('input', { 'type': 'text', 'id': 'cb-app-urlname', 'class': 'cb-input',
							'placeholder': _('app name'), 'style': 'max-width:10rem' }),
						E('button', { 'class': 'cb-btn cb-btn-primary',
							'click': function (ev) { self.handleAppUrlImport(ev); } }, _('Add from URL'))
					]),
					E('div', { 'class': 'cb-actions', 'style': 'margin-bottom:.5rem' }, [
						E('select', { 'id': 'cb-sig-app', 'class': 'cb-sel',
							'change': function (ev) { self.loadSigs(ev.target.value); } }, []),
						E('span', { 'class': 'cb-count', 'id': 'cb-sig-count' }, '')
					]),
					E('div', { 'class': 'cb-tablewrap' }, [
						E('table', { 'class': 'cb-table' }, [
							E('thead', {}, E('tr', {}, [
								E('th', {}, _('Proto')),
								E('th', {}, _('Port')),
								E('th', {}, _('Host')),
								E('th', {}, _('Fingerprint')),
								E('th', { 'style': 'text-align:right' }, _('Action'))
							])),
							E('tbody', { 'id': 'cb-sig-tbody' })
						])
					])
				])
			]),
			
			E('div', { 'class': 'cb-card' }, [
				E('div', { 'class': 'cb-card-head' }, [
					E('span', { 'class': 'cb-dot' }), E('span', {}, _('Sample traffic')),
					E('span', { 'class': 'cb-count', 'id': 'cb-sample-state', 'style': 'margin-left:auto' }, '')
				]),
				E('div', { 'class': 'cb-card-body' }, [
					E('p', { 'class': 'cb-note' },
						_('Game signatures are not published anywhere, so record them: start a capture, play, then save the flow that appears. Flows are grouped by port and by the first four bytes of the payload.')),
					E('div', { 'class': 'cb-actions', 'style': 'margin-bottom:.6rem' }, [
						E('select', { 'id': 'cb-sample-dur', 'class': 'cb-sel' }, [
							E('option', { 'value': '30' }, '30 s'),
							E('option', { 'value': '60', 'selected': 'selected' }, '60 s'),
							E('option', { 'value': '120' }, '120 s')
						]),
						E('button', { 'class': 'cb-btn cb-btn-primary', 'id': 'cb-sample-start',
							'click': function (ev) { self.handleSampleStart(ev); } }, _('Start sampling')),
						E('button', { 'class': 'cb-btn', 'id': 'cb-sample-stop',
							'click': function (ev) { self.handleSampleStop(ev); } }, _('Stop')),
						E('span', { 'id': 'cb-sample-live', 'style': 'align-self:center;font-size:.8rem' }, '')
					]),
					E('div', { 'class': 'cb-tablewrap' }, [
						E('table', { 'class': 'cb-table' }, [
							E('thead', {}, E('tr', {}, [
								E('th', {}, _('Proto')),
								E('th', {}, _('Port')),
								E('th', {}, _('First bytes')),
								E('th', { 'class': 'cb-hide-sm' }, _('Hits')),
								E('th', { 'class': 'cb-hide-sm' }, _('Peer')),
								E('th', { 'style': 'text-align:right' }, _('Action'))
							])),
							E('tbody', { 'id': 'cb-sample-tbody' })
						])
					])
				])
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
			E('div', { 'class': 'cb-tablewrap' }, [
				E('table', { 'class': 'cb-table cb-log' }, [
					E('thead', {}, E('tr', {}, [
						E('th', {}, _('Time')),
						E('th', {}, _('Result')),
						E('th', {}, _('Source')),
						E('th', { 'class': 'cb-hide-sm' }, _('Auth')),
						E('th', {}, _('IP')),
						E('th', { 'class': 'cb-hide-sm' }, _('User')),
						E('th', {}, _('Detail'))
					])),
					E('tbody', { 'id': 'cb-log-tbody' })
				])
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
					'click': function (ev) { self.refreshHealth(); } }, _('Re-run')),
				E('button', { 'class': 'cb-btn',
					'click': function (ev) { self.handleSync(ev); } }, _('Sync to kernel'))
			]),
			E('div', { 'class': 'cb-checks', 'id': 'cb-health-body' })
		]);

		var root = E('div', { 'class': 'cb-wrap' }, [
			E('style', {}, STYLE),
			E('h2', {}, _('LAN Guard')),
			E('div', { 'class': 'cb-tabs' }, [
				tabBtn('overview', _('Overview')),
				tabBtn('devices', _('Devices')),
				tabBtn('apps', _('Traffic')),
				tabBtn('ips', _('Policy')),
				tabBtn('feeds', _('Feeds')),
				tabBtn('settings', _('Settings'))
			]),
			dashPane,
			devicesPane,
			ipsPane,
			appsPane,
			feedsPane,
			autoPane,
			backupPane,
			logsPane,
			schedPane,
			notifyPane,
			healthPane
		]);

		window.setTimeout(function () {
			// skeletons first so the page is never blank
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

			// the visible tab streams in; the device list is prefetched right
			// after so switching to it is instant, while the two heavy panes
			// (addresses, log) stay lazy until they are opened
			self.refreshDash().then(function () {
				window.setTimeout(function () { self.refresh(); }, 30);
			});
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
