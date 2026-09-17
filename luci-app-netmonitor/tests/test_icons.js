#!/usr/bin/env node
/*
 * luci-app-netmonitor 前端图标自检
 *
 * 校验三件事：
 *   1. icons.js 导出 24 个动态图标函数，每个在多种输入下都返回结构完整的
 *      单个 <svg> 片段（标签闭合、无 undefined / NaN 泄漏到属性里）。
 *   2. 图标确实随参数变化：同一函数在不同数据下输出字符串必须不同，
 *      防止退回成「永远一样的装饰图标」。
 *   3. 各页面里出现的 icons.xxx() 调用名在 icons.js 中真实存在，
 *      避免出现运行时 undefined is not a function。
 *
 * 用法：node tests/test_icons.js
 * 退出码：0 全部通过；1 存在断言失败。
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const ICONS = path.join(ROOT, 'htdocs', 'luci-static', 'resources', 'netmonitor', 'icons.js');
const VIEWDIR = path.join(ROOT, 'htdocs', 'luci-static', 'resources', 'view', 'netmonitor');

let pass = 0, fail = 0;
const failures = [];

function check(name, cond, detail) {
	if (cond) {
		pass++;
	} else {
		fail++;
		failures.push(name + (detail ? (' :: ' + detail) : ''));
	}
}

/* ---- 构造一个最小的 LuCI 模块运行环境，只提供 Class.extend ---- */
function loadIcons() {
	const src = fs.readFileSync(ICONS, 'utf8');
	const Class = {
		extend: function (props) { return props; },
		isSubclass: function () { return true; }
	};
	/* 模块以 return Class.extend({...}) 结束，因此用 new Function 包一层 */
	const factory = new Function('Class', 'L', '_', src);
	return factory(Class, {}, (s) => s);
}

const icons = loadIcons();

/* ---- 1. 导出完整性 ---- */
const EXPECTED = [
	'dot', 'gradeColor', 'health', 'ping', 'latencyDial', 'latency', 'online',
	'packetLoss', 'highLatency', 'dnsFail', 'regionCN', 'regionGlobal',
	'gradeGauge', 'trend', 'iface', 'service', 'multiTarget', 'successRing',
	'lossRing', 'clock', 'gear', 'database', 'bell', 'dualStack', 'liveBars',
	'responsive'
];

for (const name of EXPECTED)
	check('export:' + name, typeof icons[name] === 'function', 'missing or not a function');

/* ---- 2. 输出结构合法性 ---- */
function assertSvg(label, svg, viewBox) {
	const vb = viewBox || 'viewBox="0 0 120 120"';
	check(label + ':returns-string', typeof svg === 'string', typeof svg);
	if (typeof svg !== 'string') return false;
	check(label + ':single-root', (svg.match(/<svg /g) || []).length === 1 &&
		(svg.match(/<\/svg>/g) || []).length === 1, svg.slice(0, 80));
	check(label + ':no-undefined', svg.indexOf('undefined') < 0, svg.slice(0, 160));
	check(label + ':no-nan', svg.indexOf('NaN') < 0, svg.slice(0, 160));
	check(label + ':has-class', svg.indexOf('class="nm-svg"') >= 0, svg.slice(0, 80));
	check(label + ':has-viewbox', svg.indexOf(vb) >= 0, svg.slice(0, 80));
	return true;
}

/* dot() 是 10x10 的微型状态点，是唯一不使用 120 视口的图标 */
const VIEWBOX_OVERRIDE = { dot: 'viewBox="0 0 10 10"' };

const cases = {
	health: [['good'], ['warning'], ['critical'], ['unknown']],
	ping: [[48, {}], [48, { grade: 'severe' }], [48, { kind: 'dns' }]],
	latencyDial: [[23, 'excellent'], [286, 'severe'], [null, 'unknown']],
	latency: [[23, 'good'], [null, 'down']],
	online: [[40, true], [40, false]],
	packetLoss: [[0], [2.5]],
	highLatency: [[286, 'severe'], [null, 'unknown']],
	dnsFail: [[]],
	regionCN: [[40, {}], [40, { abnormal: 2, total: 3 }], [40, {}, 27]],
	regionGlobal: [[40, {}], [40, { abnormal: 1 }], [40, {}, 126]],
	gradeGauge: [[48, 'good'], [900, 'severe'], [null, 'unknown']],
	trend: [[]],
	iface: [[true], [false]],
	service: [[true], [false]],
	multiTarget: [[], [[{ name: 'Baidu', latency: 23, grade: 'good' }, { name: 'DNS', latency: null, grade: 'down' }]]],
	successRing: [[100], [96.5], [null]],
	lossRing: [[0], [2], [37]],
	clock: [[Math.floor(Date.now() / 1000)], [null]],
	gear: [[]],
	database: [[]],
	bell: [[0], [3], [null]],
	dualStack: [['auto', true, true], ['ipv4', true, false], ['ipv6', false, true]],
	liveBars: [[[23, 48, 126, null]], [[]]],
	responsive: [[]],
	dot: [['good'], ['down']]
};

for (const fn of Object.keys(cases)) {
	for (const args of cases[fn]) {
		const label = fn + '(' + args.map((a) => JSON.stringify(a)).join(',') + ')';
		assertSvg(label, icons[fn].apply(null, args), VIEWBOX_OVERRIDE[fn]);
	}
}

/* ---- 3. 图标必须随数据变化（防止退化为装饰） ---- */
const differing = [
	['health', ['good'], ['critical']],
	['latencyDial', [23, 'excellent'], [286, 'severe']],
	['latencyDial', [23, 'good'], [null, 'unknown']],
	['packetLoss', [0], [5]],
	['successRing', [100], [50]],
	['lossRing', [0], [30]],
	['online', [40, true], [40, false]],
	['service', [true], [false]],
	['bell', [0], [3]],
	['dualStack', ['ipv4', true, true], ['ipv6', true, true]],
	['clock', [1700000000], [1700099999]],
	['regionCN', [40, { abnormal: 0 }], [40, { abnormal: 2 }]],
	['multiTarget', [[]], [[{ name: 'x', latency: 1, grade: 'good' }]]]
];

for (const [fn, a, b] of differing) {
	const sa = icons[fn].apply(null, a);
	const sb = icons[fn].apply(null, b);
	check('varies:' + fn, sa !== sb,
		'identical output for ' + JSON.stringify(a) + ' vs ' + JSON.stringify(b));
}

/* ---- 3b. 数据语义：有数据时不得输出占位符，无数据时不得伪造数值 ---- */
{
	/* 84px 以上才绘制目标名，此处用大尺寸验证取值逻辑本身 */
	const withAvg = icons.multiTarget([{ name: 'Baidu', avg: 34.2 }], 96);
	check('multiTarget:uses-avg-when-no-latency',
		withAvg.indexOf('34ms') >= 0 && withAvg.indexOf('--') < 0, withAvg.slice(0, 200));

	const noData = icons.multiTarget([{ name: 'Baidu' }], 96);
	check('multiTarget:no-fake-value',
		noData.indexOf('--') < 0 && noData.indexOf('0ms') < 0, noData.slice(0, 200));

	const disabled = icons.multiTarget([{ name: 'X', enabled: false }], 60);
	check('multiTarget:disabled-is-idle', disabled.indexOf('nm-fill-idle') >= 0, disabled.slice(0, 200));

	const enabled = icons.multiTarget([{ name: 'Y', enabled: true }], 60);
	check('multiTarget:enabled-is-neutral-accent',
		enabled.indexOf('nm-fill-accent') >= 0, enabled.slice(0, 200));

	/* 尺寸阈值：小尺寸不绘制文字，避免出现 4px 高的不可读文字 */
	check('multiTarget:small-size-drops-text',
		icons.multiTarget([{ name: 'Baidu', avg: 34 }], 60).indexOf('<text') < 0);
	check('latencyDial:small-size-keeps-value-drops-unit',
		icons.latencyDial(41, 'good', 52).indexOf('>41<') >= 0 &&
		icons.latencyDial(41, 'good', 52).indexOf('>ms<') < 0);
	check('dualStack:small-size-drops-labels',
		icons.dualStack('auto', true, true, 58).indexOf('IPv4') < 0);
	check('bell:small-size-drops-count',
		icons.bell(2, 64).indexOf('<text') < 0);

	/* 延迟为 null 时，延迟表盘必须显示 '--'，而圆环必须退化为 0 长度虚线 */
	check('latencyDial:null-shows-placeholder',
		icons.latencyDial(null, 'unknown', 64).indexOf('--') >= 0);
	check('lossRing:zero-length-arc',
		icons.lossRing(0, 64).indexOf('stroke-dasharray:0.0') >= 0,
		icons.lossRing(0, 64).slice(0, 240));
}

/* ---- 4. 页面调用的图标名必须存在 ---- */
const viewFiles = fs.readdirSync(VIEWDIR).filter((f) => f.endsWith('.js'));
for (const vf of viewFiles) {
	const src = fs.readFileSync(path.join(VIEWDIR, vf), 'utf8');
	const used = new Set();
	const re = /\bicons\.([A-Za-z_][A-Za-z0-9_]*)\s*\(/g;
	let m;
	while ((m = re.exec(src)) !== null) used.add(m[1]);
	for (const name of used)
		check('view:' + vf + ':icons.' + name, typeof icons[name] === 'function', 'not exported');
	check('view:' + vf + ':uses-icons', used.size > 0, 'page does not use any dynamic icon');
}

/* ---- 输出 ---- */
console.log('dynamic SVG icons selftest');
console.log('  files   : icons.js + ' + viewFiles.length + ' views');
console.log('  passed  : ' + pass);
console.log('  failed  : ' + fail);
if (fail) {
	console.log('\nfailures:');
	for (const f of failures) console.log('  - ' + f);
	process.exitCode = 1;
} else {
	console.log('\nall assertions passed');
}
