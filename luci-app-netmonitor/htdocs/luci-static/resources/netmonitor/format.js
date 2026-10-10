/*
 * luci-app-netmonitor 格式化与语义映射层
 *
 * 职责边界（本模块是**纯函数层**）：
 *   数值 → 展示字符串（toNum / num / latency / percent / clockOf / dateTimeOf / ago）
 *   状态码 → CSS 类名 / 展示文案（gradeClass / gradeText / dotClass / region* / errorText）
 *   后端英文报错 → 可翻译文案（localizeError）
 *
 * 刻意不 require rpc / ui / uci，也不碰 DOM —— 因此可以被任意模块安全依赖，
 * 不会出现「为了拿一个 percent() 而把整个 RPC 层拖进来」的反向耦合。
 * 唯一的外部输入是 LuCI 注入的 _()；它缺失时文案退化为英文原文，结构不受影响。
 *
 * 本模块从 common.js 拆出（common.js 曾把 RPC、UCI、格式化、DOM 组件
 * 混在一个 809 行的文件里，改任何一类职责都要动同一个文件）。
 */

'use strict';

/* ------------------------------------------------ 后端错误文案本地化
 *
 * rpcd 的 ucode 插件运行在 rpcd 进程里，没有 LuCI 的 i18n 运行时，因此后端
 * 只能用 err('invalid host') 这样的英文串回报。这里在前端唯一的出口 call()
 * 上做一次「英文原文 → 可翻译文案」的映射，各页面拿到的 e.message 就已经是
 * 本地化后的文本，不必每个调用点各写一遍。
 *
 * 映射表覆盖 root/usr/share/rpcd/ucode/luci.netmonitor 里全部 err() 字面量；
 * 没命中的串原样透出，便于定位后端新增但尚未登记的报错。 */
var BACKEND_MSG = {
	'invalid arguments': 'Invalid arguments',
	'invalid id': 'Invalid ID',
	'invalid ids': 'Invalid target selection',
	'invalid name': 'Invalid name',
	'invalid host': 'Invalid host',
	'invalid region': 'Invalid region',
	'invalid label': 'Invalid label',
	'invalid proto': 'Invalid protocol',
	'invalid family': 'Invalid address family',
	'invalid interface': 'Invalid interface',
	'invalid source': 'Invalid source address',
	'invalid remark': 'Invalid remark',
	'invalid direction': 'Invalid direction',
	'target not found': 'Target not found',
	'target id already exists': 'Target already exists',
	'cannot create section': 'Cannot create configuration section',
	'already at boundary': 'Already at the boundary'
};

/* 带参数的报错：后端拼成 'invalid value for <键名>'。
 * 用显式 prefix 而不是正则，是为了让 po/gen_po.py 能静态解析出这条
 * 前缀，从而把拼接式报错一并纳入漂移审计（正则字面量解析不出前缀）。 */
var BACKEND_MSG_ARG = [
	{ prefix: 'invalid value for ', msg: 'Invalid value for %s' }
];

function localizeError(msg) {
	var s = (msg == null) ? '' : String(msg);
	if (BACKEND_MSG[s])
		return _(BACKEND_MSG[s]);
	for (var i = 0; i < BACKEND_MSG_ARG.length; i++) {
		var p = BACKEND_MSG_ARG[i].prefix;
		if (s.indexOf(p) === 0)
			return _(BACKEND_MSG_ARG[i].msg).replace('%s', s.slice(p.length));
	}
	return s;
}

/* ------------------------------------------------------------ 数值格式化 */

function toNum(v) {
	if (v == null || v === '')
		return null;
	var n = parseFloat(v);
	return isNaN(n) ? null : n;
}

function num(v, digits) {
	var n = toNum(v);
	if (n == null) return '—';
	var p = Math.pow(10, digits == null ? 1 : digits);
	return String(Math.round(n * p) / p);
}

function latency(v) {
	var n = toNum(v);
	if (n == null) return '—';
	if (n >= 100) return String(Math.round(n));
	return String(Math.round(n * 10) / 10);
}

function percent(v, digits) {
	var n = toNum(v);
	if (n == null) return '—';
	var p = Math.pow(10, digits == null ? 1 : digits);
	return (Math.round(n * p) / p) + '%';
}

function pad2(x) { return (x < 10 ? '0' : '') + x; }

function clockOf(ts) {
	if (!ts) return '—';
	var d = new Date(ts * 1000);
	return pad2(d.getHours()) + ':' + pad2(d.getMinutes()) + ':' + pad2(d.getSeconds());
}

function dateTimeOf(ts) {
	if (!ts) return '—';
	var d = new Date(ts * 1000);
	return (d.getMonth() + 1) + '/' + d.getDate() + ' ' + pad2(d.getHours()) + ':' + pad2(d.getMinutes());
}

function ago(ts) {
	if (!ts) return _('Never checked');
	var d = Math.floor(Date.now() / 1000) - ts;
	if (d < 0) d = 0;
	if (d < 5) return _('Just now');
	if (d < 60) return _('%d seconds ago').replace('%d', d);
	if (d < 3600) return _('%d minutes ago').replace('%d', Math.floor(d / 60));
	if (d < 86400) return _('%d hours ago').replace('%d', Math.floor(d / 3600));
	return _('%d days ago').replace('%d', Math.floor(d / 86400));
}

/* ---------------------------------------------------------------- 等级 */

var GRADE_CLASS = {
	excellent: 'ok',
	good: 'ok',
	fair: 'warn',
	poor: 'poor',
	severe: 'bad',
	down: 'bad',
	disabled: 'idle',
	unknown: 'idle'
};

var GRADE_TEXT = {
	excellent: 'Excellent',
	good: 'Good',
	fair: 'Fair',
	poor: 'Poor',
	severe: 'Severe',
	down: 'Offline',
	disabled: 'Disabled',
	unknown: 'Unknown'
};

function gradeClass(g) {
	return 'nm-c-' + (GRADE_CLASS[g] || 'idle');
}

function gradeText(g) {
	return _(GRADE_TEXT[g] || 'Unknown');
}

function dotClass(g) {
	return 'nm-dot nm-dot-' + (GRADE_CLASS[g] || 'idle');
}

function regionText(r) {
	if (r === 'cn') return _('China');
	if (r === 'overseas') return _('Overseas');
	return _('Other');
}

function regionTagClass(r) {
	if (r === 'cn') return 'nm-tag nm-tag-cn';
	if (r === 'overseas') return 'nm-tag nm-tag-overseas';
	return 'nm-tag nm-tag-other';
}

function errorText(e) {
	switch (e) {
		case 'timeout': return _('Timeout');
		case 'dns': return _('DNS resolve failed');
		case 'unreachable': return _('Network unreachable');
		case 'invalid': return _('Invalid target');
		case 'error': return _('Check failed');
	}
	return '';
}

/* LuCI 的模块加载器要求每个模块导出一个 Class（Class.isSubclass 校验）。 */
return Class.extend({
	__name__: 'NetMonitor.format',

	/* 分组命名空间：与旧 common.fmt 的调用形式保持逐字一致，
	 * 页面里的 common.fmt.latency(...) 无需改动即可切到本模块。 */
	fmt: {
		num: num,
		latency: latency,
		percent: percent,
		clock: clockOf,
		dateTime: dateTimeOf,
		ago: ago
	},

	/* 顶层直出：供 api.js / widgets.js 等模块直接取用，
	 * 省掉 fmt.fmt.xxx 这种叠床架屋的写法。 */
	toNum: toNum,
	num: num,
	latency: latency,
	percent: percent,
	pad2: pad2,
	clockOf: clockOf,
	dateTimeOf: dateTimeOf,
	ago: ago,

	gradeClass: gradeClass,
	gradeText: gradeText,
	dotClass: dotClass,
	regionText: regionText,
	regionTagClass: regionTagClass,
	errorText: errorText,
	localizeError: localizeError
});
