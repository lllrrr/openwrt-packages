'use strict';
'require baseclass';
'require rpc';

// 视图共用的底座:所有 RPC 声明、样式表、格式化函数。
// 它们原本散落在 3600 行的视图文件里,每个新页面都得重新找一遍。

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
var callAppStats = rpc.declare({ object: 'luci.languard', method: 'appstats', params: [ 'range' ] });
var callBlockAudit = rpc.declare({ object: 'luci.languard', method: 'blockaudit', params: [ 'limit' ] });
var callFix = rpc.declare({ object: 'luci.languard', method: 'fix', params: [ 'id' ] });
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
var callExportFile = rpc.declare({ object: 'luci.languard', method: 'exportfile' });
var callImportFile = rpc.declare({ object: 'luci.languard', method: 'importfile', params: [ 'name' ] });
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
.cb-input { width: 100%; box-sizing: border-box; padding: .35rem .6rem; border-radius: .35rem;
	border: 1px solid var(--hairline); background: transparent; color: inherit; font-size: .85rem; }
.cb-geo { display: inline-block; padding: 0 .4rem; border-radius: .25rem; font-size: .7rem;
	font-weight: 600; letter-spacing: .04em; line-height: 1.5; white-space: nowrap;
	background: var(--accent); color: #fff; opacity: .9; }
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
.cb-range { padding: .15rem .45rem; font-size: .72rem; }
.cb-input { width: 100%; box-sizing: border-box; padding: .35rem .6rem; border-radius: .35rem;
	border: 1px solid var(--hairline); background: transparent; color: inherit; font-size: .85rem; }
.cb-tag { display: inline-block; padding: 0 .35rem; margin-right: .3rem; border-radius: .25rem;
	border: 1px solid var(--hairline); font-size: .68rem; line-height: 1.4; opacity: .8; white-space: nowrap; }
.cb-tag-node { border-color: var(--focus-ring); }
.cb-range-on { background: var(--hover-faint); border-color: var(--focus-ring); }
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
/* 宽屏居中 + 统一节奏:所有间距走一个变量,避免各处 magic number */
:root { --gap: .75rem; }
.cb-pane { display: none; max-width: 72rem; margin-inline: auto; }
.cb-card + .cb-card { margin-top: var(--gap); }

/* 数值列对齐:字节计数不对齐是目前最明显的"没打磨"感 */
.cb-table td[style*="text-align:right"], .cb-num { font-variant-numeric: tabular-nums; }

/* 大表更紧凑,小卡保持松快 */
.cb-dense td { padding-block: .3rem; font-size: .85rem; }

/* 概览主卡:九张卡等权重等于没有入口,第一张放大做视觉落点 */
.cb-card-hero .cb-num { font-size: 1.9rem; line-height: 1.1; font-weight: 600; }

/* tab 告警点:健康有问题时不用点开就知道 */
.cb-tab { position: relative; }
.cb-tab[data-alert]::after {
	content: ''; position: absolute; top: .3rem; right: .3rem;
	width: .45rem; height: .45rem; border-radius: 50%; background: var(--danger);
}

/* 骨架屏:首拉未回时先占位,空表不再像"坏了" */
.cb-skel { height: .8rem; border-radius: 4px; background: var(--surface-2);
	animation: cb-pulse 1.2s ease-in-out infinite; }
@keyframes cb-pulse { 50% { opacity: .45; } }

/* 状态条:请求失败时出现,平时不占位 */
.cb-strip { margin: 0 0 var(--gap); padding: .4rem .7rem; border-radius: .35rem;
	background: var(--danger-surface); color: var(--danger); font-size: .8rem; }
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
.cb-fail-item { font-size: .8rem; color: var(--danger); display: flex; align-items: center;
	justify-content: space-between; gap: .5rem; }

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
.cb-appchip { display: inline-block; padding: .04rem .45rem; border-radius: .6rem;
	border: 1px solid; font-size: .74rem; margin: 0 .25rem .2rem 0; white-space: nowrap; }
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

// an app rendered as a coloured chip; the same name always gets the same hue.
// Clicking one filters the view: the others fade so the selection reads at a
// glance even in a dense list.
var APP_FILTER = null;
var APP_CHIP_CLICK = null;

// 统一的失败上报。空 catch 曾让两个 bug 潜伏数周:一次 RPC 失败被吞掉,
// 界面只是显示成"没有数据",看起来像后端坏了。
var _failCount = 0;
function fail(e) {
	_failCount++;
	try { console.warn('languard: request failed', e); } catch (_) {}
	var bar = document.getElementById('cb-status-strip');
	if (bar) {
		bar.hidden = false;
		bar.textContent = _failCount + ' ' + 'request(s) failed — see console';
	}
	return null;
}

// 视图持有自己的筛选状态,通过这里同步给 appChip;
// 直接跨模块给变量赋值在严格模式下会抛 ReferenceError。
function setAppFilter(name, onClick) {
	APP_FILTER = name || null;
	APP_CHIP_CLICK = onClick || null;
}

function appChip(name, text) {
	var h = appHue(name);
	var dim = APP_FILTER && APP_FILTER !== name;
	return E('span', {
		'class': 'cb-appchip',
		'title': name,
		'style': 'color:hsl(' + h + ',75%,72%);border-color:hsl(' + h + ',55%,45%);' +
			'background:hsl(' + h + ',50%,22%);cursor:pointer' +
			(dim ? ';opacity:.22;filter:grayscale(1)' : '')
		+ (APP_FILTER === name ? ';box-shadow:0 0 0 2px hsl(' + h + ',70%,55%)' : ''),
		'click': function (ev) {
			ev.stopPropagation();
			if (APP_CHIP_CLICK) APP_CHIP_CLICK(name);
		}
	}, text || name);
}

// a stable colour per app name, so the eye can follow one app down the list
function appHue(name) {
	var h = 0;
	for (var i = 0; i < name.length; i++)
		h = (h * 31 + name.charCodeAt(i)) % 360;
	return h;
}

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

// LuCI 的模块必须是构造函数:裸对象会触发
// "factory yields invalid constructor"。
return baseclass.extend({
	STYLE: STYLE,
	callList: callList,
	callBlock: callBlock,
	callUnblock: callUnblock,
	callUnblockAll: callUnblockAll,
	callIpList: callIpList,
	callSync: callSync,
	callAppList: callAppList,
	callAppStats: callAppStats,
	callBlockAudit: callBlockAudit,
	callFix: callFix,
	callAppImport: callAppImport,
	callAppDel: callAppDel,
	callSigList: callSigList,
	callDomainHits: callDomainHits,
	callDomainLog: callDomainLog,
	callSigAdd: callSigAdd,
	callSigDel: callSigDel,
	callAppReset: callAppReset,
	callSampleStart: callSampleStart,
	callSampleStop: callSampleStop,
	callSampleResult: callSampleResult,
	callSampleSave: callSampleSave,
	callQosList: callQosList,
	callQosAdd: callQosAdd,
	callQosDel: callQosDel,
	callDevMerge: callDevMerge,
	callDevUnmerge: callDevUnmerge,
	callDomainList: callDomainList,
	callDomainAdd: callDomainAdd,
	callDomainDel: callDomainDel,
	callDomainToggle: callDomainToggle,
	callProxyList: callProxyList,
	callProxyAdd: callProxyAdd,
	callProxyDel: callProxyDel,
	callIpAdd: callIpAdd,
	callIpDel: callIpDel,
	callDashboard: callDashboard,
	callTrend: callTrend,
	callPanicState: callPanicState,
	callPanic: callPanic,
	callKnownAdd: callKnownAdd,
	callKnownList: callKnownList,
	callWlList: callWlList,
	callWlAdd: callWlAdd,
	callWlDel: callWlDel,
	callFeedList: callFeedList,
	callFeedAdd: callFeedAdd,
	callFeedSet: callFeedSet,
	callFeedDel: callFeedDel,
	callFeedRefresh: callFeedRefresh,
	callPortPresets: callPortPresets,
	callPortTemplate: callPortTemplate,
	callExport: callExport,
	callExportFile: callExportFile,
	callImportFile: callImportFile,
	callImport: callImport,
	callGroupList: callGroupList,
	callGroupAdd: callGroupAdd,
	callGroupDel: callGroupDel,
	callGroupSet: callGroupSet,
	callCurfew: callCurfew,
	callPortList: callPortList,
	callPortAdd: callPortAdd,
	callPortDel: callPortDel,
	callNotifyGet: callNotifyGet,
	callNotifyAdd: callNotifyAdd,
	callNotifyDel: callNotifyDel,
	callNotifyToggle: callNotifyToggle,
	callNotifyEvents: callNotifyEvents,
	callNotifyTest: callNotifyTest,
	callSchedList: callSchedList,
	callSchedAdd: callSchedAdd,
	callSchedDel: callSchedDel,
	callSchedToggle: callSchedToggle,
	callSelfCheck: callSelfCheck,
	callLogList: callLogList,
	callLogClear: callLogClear,
	callAutoGet: callAutoGet,
	callAutoSet: callAutoSet,
	callScan: callScan,
	callIpFlush: callIpFlush,
	callRename: callRename,
	fmtBytes: fmtBytes,
	fmtGeo: fmtGeo,
	setAppFilter: setAppFilter,
	fail: fail,
	appChip: appChip,
	appHue: appHue,
	catMeta: catMeta,
	typeLabel: typeLabel,
	fmtTime: fmtTime
});
