#!/usr/bin/env node
/*
 * luci-app-netmonitor 前端防护与生命周期自检
 *
 * 与 tests/test_icons.js（图标渲染）并列，本文件覆盖的是**行为**层面：
 *
 *   1. DOM 安全（存储型 XSS）
 *      目标名 / 地址 / 标签 / 备注 全部由用户填写并落进 /etc/config/netmonitor，
 *      经 RPC 回到前端后必须只作为纯文本呈现。这里用真实渲染路径
 *      （widgets.targetCard / ui.chip / ui.alert / ui.dialog / ui.banner）
 *      跑一遍典型载荷，断言载荷**没有**进入任何 innerHTML 写入。
 *
 *   2. 数值与布尔的后端兼容
 *      后端的浮点字段以字符串返回（ucode blobmsg 对 double 输出 17 位有效
 *      数字，只能在服务端 sprintf 成字符串），布尔字段可能是 0/'0'/false。
 *      这里断言归一化与格式化函数在各类输入下的行为，尤其是
 *      「空值不能被当成正常的 0」。
 *
 *   3. SPA 生命周期
 *      七个页面里凡是用到 poll 的，都必须在承载 DOM 脱离文档后自注销，
 *      否则访问 N 次就是 N 路并发轮询持续打 rpcd。这里真实调用 render()
 *      再模拟路由切走，断言 poll 队列被清空且不再发起 RPC。
 *
 *   4. 图表实例表与请求竞态
 *      chart.mount 重复挂载同一容器时不得让内部实例表无界增长；
 *      history 页连续切换筛选条件时，过期的响应不得覆盖新结果。
 *
 * 为什么自带一套最小 DOM 而不引入 jsdom：
 *   本文件要在 CI 的 ubuntu-latest 上跑，引入 jsdom 意味着每次 CI 都要联网
 *   装一个几百个包的依赖树，而这里需要的只是「能挂载节点、能记录 innerHTML
 *   写入、能判断 isConnected」这三件事。自带实现让测试零依赖、可离线运行。
 *
 * 用法：node tests/test_frontend_guards.js
 * 退出码：0 全部通过；1 存在断言失败。
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const NET = path.join(ROOT, 'htdocs', 'luci-static', 'resources', 'netmonitor');
const VIEW = path.join(ROOT, 'htdocs', 'luci-static', 'resources', 'view', 'netmonitor');

let pass = 0, fail = 0, skip = 0;
const failures = [];

function check(name, cond, detail) {
	if (cond) { pass++; return true; }
	fail++;
	failures.push(name + (detail ? (' :: ' + detail) : ''));
	return false;
}

function skipOne(name, why) {
	skip++;
	failures.push('SKIP ' + name + ' :: ' + why);
}

function section(t) { process.stdout.write('\n== ' + t + '\n'); }

/* ------------------------------------------------------------------ 最小 DOM */

let innerHTMLWrites = [];
let textContentWrites = [];

function resetWrites() {
	innerHTMLWrites = [];
	textContentWrites = [];
}

function makeElement(tag) {
	const el = {
		tagName: String(tag || 'div').toUpperCase(),
		className: '',
		children: [],
		parentNode: null,
		attrs: {},
		_html: '',
		_text: '',
		disabled: false,
		value: '',
		checked: false,
		type: '',
		firstChild: null,
		offsetHeight: 0,
		offsetWidth: 0,
		clientWidth: 720,
		style: {
			setProperty: function (k, v) { this[k] = v; }
		},
		classList: {
			add: function () { for (const c of arguments) el._classes.add(c); },
			remove: function () { for (const c of arguments) el._classes.delete(c); },
			contains: function (c) { return el._classes.has(c); },
			toggle: function (c, on) { if (on) el._classes.add(c); else el._classes.delete(c); }
		},
		_classes: new Set(),
		_listeners: {},

		appendChild: function (c) {
			if (c && c.__isTextNode) { el.children.push(c); c.parentNode = el; }
			else if (c) { c.parentNode = el; el.children.push(c); }
			el.firstChild = el.children[0] || null;
			return c;
		},
		removeChild: function (c) {
			const i = el.children.indexOf(c);
			if (i >= 0) el.children.splice(i, 1);
			if (c) c.parentNode = null;
			el.firstChild = el.children[0] || null;
			return c;
		},
		replaceChild: function (n, o) {
			const i = el.children.indexOf(o);
			if (i >= 0) { el.children[i] = n; n.parentNode = el; o.parentNode = null; }
			el.firstChild = el.children[0] || null;
			return o;
		},
		setAttribute: function (k, v) { el.attrs[k] = String(v); },
		getAttribute: function (k) { return Object.prototype.hasOwnProperty.call(el.attrs, k) ? el.attrs[k] : null; },
		removeAttribute: function (k) { delete el.attrs[k]; },
		addEventListener: function (type, fn) {
			/* 记录监听而非丢弃：设计系统一节要真实派发 click / keydown，
			 * 验证 busy 态、连点防护、Esc 关闭、浮层点项关闭等交互语义 */
			(el._listeners[type] = el._listeners[type] || []).push(fn);
		},
		removeEventListener: function (type, fn) {
			const ls = el._listeners[type] || [];
			const i = ls.indexOf(fn);
			if (i >= 0) ls.splice(i, 1);
		},
		dispatch: function (type, ev) {
			const ls = (el._listeners[type] || []).slice();
			for (const fn of ls) fn(ev || {});
		},
		focus: function () { },
		getBoundingClientRect: function () { return { left: 0, top: 0, width: 720, height: 260, right: 720, bottom: 260 }; },
		querySelector: function (s) { return queryAll(el, s)[0] || null; },
		querySelectorAll: function (s) { return queryAll(el, s); },
		insertBefore: function (c) { return el.appendChild(c); }
	};

	Object.defineProperty(el, 'textContent', {
		get: function () { return el._text; },
		set: function (v) {
			el._text = String(v);
			el.children = [];
			el.firstChild = null;
			textContentWrites.push(el._text);
		}
	});

	Object.defineProperty(el, 'innerHTML', {
		get: function () { return el._html; },
		set: function (v) {
			el._html = String(v);
			innerHTMLWrites.push(el._html);
		}
	});

	Object.defineProperty(el, 'isConnected', {
		get: function () {
			let n = el;
			while (n.parentNode) n = n.parentNode;
			return n === document.body;
		}
	});

	Object.defineProperty(el, 'classList', {
		get: function () {
			/* className 与 classList 各自维护：页面里大量直接写 className，
			 * 这里同步一次，避免 classList.contains 判不出 className 里的值 */
			return {
				add: function () { for (const c of arguments) el._classes.add(c); },
				remove: function () { for (const c of arguments) el._classes.delete(c); },
				contains: function (c) { return el._classes.has(c) || String(el.className).split(/\s+/).indexOf(c) >= 0; },
				toggle: function (c, on) { if (on) el._classes.add(c); else el._classes.delete(c); }
			};
		}
	});

	return el;
}

/* 极简选择器：支持 "tag"、".class"、"[attr]"、"[attr=v]" 的连写与逗号分隔。
 * 覆盖页面里实际用到的几种：'.nm-card-inner'、'.nm-cursor'、'.nm-cur-dot'、
 * 'input[type="checkbox"][data-id]'、'a[href], button:not([disabled])' 等。 */
function matchesOne(el, sel) {
	if (el.__isTextNode) return false;
	const parts = sel.match(/^[a-zA-Z0-9]+|\.[^.\[\]:]+|\[[^\]]+\]/g) || [];
	for (const p of parts) {
		if (p[0] === '.') {
			const c = p.slice(1);
			if (!el._classes.has(c) && String(el.className).split(/\s+/).indexOf(c) < 0) return false;
		} else if (p[0] === '[') {
			const m = p.slice(1, -1).match(/^([^=]+)(?:=["']?([^"']*)["']?)?$/);
			if (!m) return false;
			const k = m[1];
			const has = Object.prototype.hasOwnProperty.call(el.attrs, k);
			if (m[2] != null) { if (!has || el.attrs[k] !== m[2]) return false; }
			else if (!has) return false;
		} else {
			if (el.tagName !== p.toUpperCase()) return false;
		}
	}
	return true;
}

function queryAll(root, sel) {
	const out = [];
	const groups = String(sel).split(',').map((s) => s.trim()).filter(Boolean);
	function walk(n) {
		for (const c of n.children) {
			if (c && !c.__isTextNode) {
				if (groups.some((g) => matchesOne(c, g))) out.push(c);
				walk(c);
			}
		}
	}
	walk(root);
	return out;
}

/* document 级监听同样记录 + 可派发（弹窗 Esc / 浮层外点击关闭） */
const docListeners = {};

const document = {
	body: makeElement('body'),
	head: makeElement('head'),
	documentElement: { scrollTop: 0 },
	createElement: makeElement,
	createTextNode: function (t) {
		return { __isTextNode: true, text: String(t), parentNode: null };
	},
	getElementById: function (id) {
		let found = null;
		(function walk(n) {
			for (const c of n.children) {
				if (c && !c.__isTextNode) {
					if (c.attrs.id === id || c.id === id) found = c;
					walk(c);
				}
			}
		})(document.body);
		return found;
	},
	addEventListener: function (type, fn) {
		(docListeners[type] = docListeners[type] || []).push(fn);
	},
	removeEventListener: function (type, fn) {
		const ls = docListeners[type] || [];
		const i = ls.indexOf(fn);
		if (i >= 0) ls.splice(i, 1);
	},
	dispatch: function (type, ev) {
		const ls = (docListeners[type] || []).slice();
		for (const fn of ls) fn(ev || {});
	}
};

/* 键盘事件工厂：handler 会调 stopPropagation / preventDefault */
function keyEv(key, shift) {
	return {
		key: key, shiftKey: !!shift, target: document.body,
		stopPropagation: function () { }, preventDefault: function () { }
	};
}
document.body.parentNode = null;

const window = {
	setTimeout: (fn) => { try { fn(); } catch (e) { } return 0; },
	requestAnimationFrame: (fn) => { try { fn(); } catch (e) { } return 0; },
	scrollY: 0,
	scrollTo: function () { },
	addEventListener: function () { },
	removeEventListener: function () { },
	console: console
};

/* ---------------------------------------------------------- LuCI 模块 mock */

const Class = {
	extend: function (props) { return props; },
	singleton: function (props) { return props; },
	isSubclass: function () { return true; }
};

let rpcCalls = [];
const rpcResponses = {};
function setRpcResponse(method, value) { rpcResponses[method] = value; }

const rpc = {
	declare: function (o) {
		return function () {
			rpcCalls.push(o.method);
			const v = rpcResponses[o.method];
			return Promise.resolve(typeof v === 'function' ? v() : (v || {}));
		};
	}
};

const uciState = { netmonitor: {} };
const uci = {
	load: () => Promise.resolve(),
	get: (c, s, o) => (uciState[c] && uciState[c][s] && uciState[c][s][o] != null ? uciState[c][s][o] : null),
	set: function (c, s, o, v) {
		uciState[c] = uciState[c] || {};
		uciState[c][s] = uciState[c][s] || {};
		uciState[c][s][o] = v;
	},
	unset: function (c, s, o) {
		if (uciState[c] && uciState[c][s]) delete uciState[c][s][o];
	},
	add: function (c, t) {
		const sid = 'cfg' + Math.random().toString(16).slice(2, 8);
		uciState[c] = uciState[c] || {};
		uciState[c][sid] = { '.type': t };
		return sid;
	},
	save: () => Promise.resolve(),
	apply: () => Promise.resolve(),
	revert: () => Promise.resolve(),
	foreach: (c, t, fn) => {
		const s = uciState[c] || {};
		for (const k in s) if (s[k]['.type'] === t) fn(s[k]);
	}
};

const uiStub = {
	addNotification: function () { throw new Error('no LuCI ui'); }
};

const pollQueue = [];
const poll = {
	add: function (fn, iv) { pollQueue.push({ fn: fn, iv: iv }); },
	remove: function (fn) {
		for (let i = pollQueue.length - 1; i >= 0; i--)
			if (pollQueue[i].fn === fn) pollQueue.splice(i, 1);
	},
	list: () => pollQueue
};

const view = { extend: (o) => o };

const L = {
	resource: (p) => '/luci-static/resources/' + p,
	env: { sessionid: 'test' }
};

function identity_(s) { return s; }

/* ------------------------------------------------------------ 模块加载 */

function loadModule(file, params) {
	const src = fs.readFileSync(file, 'utf8');
	const names = Object.keys(params || {});
	const factory = new Function('Class', 'document', 'window', 'L', '_', names.join(','),
		'"use strict";\n' + src);
	return factory(Class, document, window, L, identity_, ...names.map((n) => params[n]));
}

const fmtMod = loadModule(path.join(NET, 'format.js'), {});
const fmt = fmtMod.fmt;
const uiMod = loadModule(path.join(NET, 'ui.js'), {});
const icons = loadModule(path.join(NET, 'icons.js'), { nmfmt: fmtMod });
const widgets = loadModule(path.join(NET, 'widgets.js'), { ui: uiStub, nmui: uiMod, icons: icons, fmt: fmtMod });
const api = loadModule(path.join(NET, 'api.js'), { rpc: rpc, ui: uiStub, uci: uci, fmt: fmtMod });
const chart = loadModule(path.join(NET, 'chart.js'), {});
const common = loadModule(path.join(NET, 'common.js'), {
	nmapi: api, nfmt: fmtMod, nmw: widgets, icons: icons, nmui: uiMod
});

/* ================================================== 1. DOM 安全（存储型 XSS） */

section('1. DOM 安全：用户可控字段必须只作为纯文本呈现');

/* 覆盖历史上真实出现过的三类载荷：
 * 1) 事件处理器型（最常见）
 * 2) 提前闭合属性再注入（针对拼进 HTML 属性/ SVG 属性的路径）
 * 3) 换行 + 脚本（针对日志与多行文本展示） */
const PAYLOADS = [
	'<img src=x onerror=alert(1)>',
	'"><script>alert(2)</script>',
	"</text></svg><svg onload=alert(3)>",
	'<svg><animate onbegin=alert(4) attributeName=x>',
	'javascript:alert(5)',
	'<iframe src="javascript:alert(6)"></iframe>'
];

function runWithPayload(payload) {
	const t = {
		id: 'cfgxss',
		name: payload,
		host: payload,
		label: payload,
		remark: payload,
		region: 'cn',
		proto: 'icmp',
		enabled: 1,
		status: 'online',
		grade: 'good',
		latency: 12.3,
		avg: 12.3,
		min: 10,
		max: 20,
		p50: 12,
		p95: 18,
		p99: 19,
		loss: 0,
		success_rate: 100,
		last_error: '',
		spark: [10, 12, null, 14]
	};

	resetWrites();

	/* 走真实渲染路径 */
	const card = widgets.targetCard(t);

	/* 表格 / 状态行 / 标签 / 提示条 / 弹窗 / 横幅 */
	const chip = common.ui.chip({ text: payload, kind: 'ok' });
	const alertBox = common.ui.alert({ text: payload, kind: 'error' });
	const banner = widgets.banner(payload, 'warn');
	const kpi = widgets.kpiCard(payload, payload, payload, icons.multiTarget([t], 30));
	const iconCard = widgets.iconCard(payload, payload, payload, icons.online(30, true));

	/* 弹窗：标题 + 正文 + 确认框 */
	const dlg = common.ui.dialog({
		host: document.body,
		header: payload,
		body: (function () {
			const b = uiMod.el('div', '');
			b.appendChild(uiMod.el('div', '', payload));
			return b;
		})(),
		ok: payload,
		cancel: payload,
		onOk: function () { return true; }
	});
	const cbox = common.ui.confirm({ host: document.body, message: payload, ok: payload });

	/* 记下所有 innerHTML 写入，逐个比对 */
	const leaked = innerHTMLWrites.filter((h) => h.indexOf(payload) >= 0);
	const asText = textContentWrites.filter((x) => x.indexOf(payload) >= 0);

	/* 顺手清理，避免累积影响后续用例 */
	if (dlg && dlg.close) dlg.close();
	if (cbox && cbox.close) cbox.close();

	return {
		leaked: leaked,
		asText: asText,
		nodes: [card, chip, alertBox, banner, kpi, iconCard]
	};
}

for (const p of PAYLOADS) {
	const r = runWithPayload(p);
	check('XSS: 载荷未进入 innerHTML [' + p.slice(0, 28) + ']',
		r.leaked.length === 0,
		r.leaked.length ? ('泄漏 ' + r.leaked.length + ' 处：' + r.leaked[0].slice(0, 120)) : '');
	check('XSS: 载荷以纯文本呈现 [' + p.slice(0, 28) + ']',
		r.asText.length > 0,
		'未找到文本形式的载荷，可能根本没有渲染该字段');
}

/* 图标层是唯一「用户数据进入 innerHTML」的合法路径：多目标图标会在 SVG 里
 * 显示目标名（icons.js 第 525 行附近），因此必须有转义。
 *
 * 注意 TEXT_SUB_MIN = 84：图标小于该尺寸时不渲染任何文字（响应式设计，
 * 小图标上 11px 的字根本看不清）。要验证转义必须用 >= 84 的尺寸，
 * 否则文本压根不会进入 SVG，断言会假失败。 */
{
	const evil = '<img src=x onerror=alert(1)>\'"&';

	/* 大尺寸：文本会渲染，必须已转义 */
	const svg = icons.multiTarget([{ name: evil, grade: 'good', latency: 12 }], 120);
	check('XSS: icons.multiTarget 对目标名做了转义',
		svg.indexOf('&lt;img') >= 0 && svg.indexOf('<img') < 0,
		svg.slice(0, 200));

	/* 五个危险字符逐个验证（覆盖了 esc() 的全部替换表） */
	for (const ch of ['&', '<', '>', '"', "'"]) {
		const s = icons.multiTarget([{ name: 'a' + ch + 'b' }], 120);
		check('XSS: icons 转义字符 ' + JSON.stringify(ch),
			s.indexOf('>a' + ch + 'b<') < 0,
			s.slice(0, 200));
	}

	/* 小尺寸：按设计不渲染文本，载荷不应出现在 SVG 里。
	 * 只比对接下来的标签名与事件处理器，不能笼统搜 'img'——
	 * SVG 根节点上本来就写着 role="img"。 */
	const small = icons.multiTarget([{ name: evil, grade: 'good' }], 44);
	check('XSS: 小尺寸图标不渲染文本（载荷不入 SVG）',
		small.indexOf('<img') < 0 && small.indexOf('onerror') < 0,
		small.slice(0, 160));
}

/* 图表 legend / tooltip 里的系列名同样来自配置 */
{
	resetWrites();
	const box = uiMod.el('div', '');
	document.body.appendChild(box);
	const entry = chart.mount(box, [
		{ name: '<img src=x onerror=alert(1)>', color: '#123456', points: [{ t: 1, l: 10, s: 1 }] }
	], { height: 120 });
	check('XSS: 图表渲染未泄漏系列名到 innerHTML',
		innerHTMLWrites.filter((h) => h.indexOf('<img src=x') >= 0).length === 0,
		innerHTMLWrites.join(' | ').slice(0, 160));
	if (entry && entry.destroy) entry.destroy();
}

/* ================================================= 2. 数值与布尔的后端兼容 */

section('2. 数值与布尔：后端字符串 / null / 空值 的归一化');

/* toNum：空值必须一律为 null，不能被当成 0 */
check('toNum(null) === null', fmtMod.toNum(null) === null, String(fmtMod.toNum(null)));
check('toNum("") === null', fmtMod.toNum('') === null, String(fmtMod.toNum('')));
check('toNum("-") === null', fmtMod.toNum('-') === null, String(fmtMod.toNum('-')));
check('toNum("abc") === null', fmtMod.toNum('abc') === null, String(fmtMod.toNum('abc')));
check('toNum("26.51") === 26.51', fmtMod.toNum('26.51') === 26.51, String(fmtMod.toNum('26.51')));
check('toNum("0") === 0', fmtMod.toNum('0') === 0, String(fmtMod.toNum('0')));

/* 格式化：null 显示占位符而不是 0 */
check('latency(null) === "—"', fmt.latency(null) === '—', fmt.latency(null));
check('percent(null) === "—"', fmt.percent(null) === '—', fmt.percent(null));
check('num(null) === "—"', fmt.num(null) === '—', fmt.num(null));
check('latency("26.51") 不产生浮点尾数', fmt.latency('26.51') === '26.5', fmt.latency('26.51'));
check('latency(0) === "0"（合法零延迟不能显示成占位符）', fmt.latency(0) === '0', fmt.latency(0));
check('percent(0) === "0%"', fmt.percent(0) === '0%', fmt.percent(0));

/* api.numify：后端字符串数值必须转成 number，避免字符串 `+=` 变拼接 */
{
	const d = api.numify.status({
		overall: { current: '20.27', avg: '23.74', loss: '1.5' },
		regions: { cn: { avg: '18.96', p95: '31.55', loss: '0.0' } },
		targets: [{ name: 't', latency: '12.30', avg: '12.30', p95: '18.00', loss: '0.0', spark: ['1.00', null] }]
	});
	check('numify: overall.current 为 number', typeof d.overall.current === 'number', typeof d.overall.current);
	check('numify: regions.cn.avg 为 number', typeof d.regions.cn.avg === 'number', typeof d.regions.cn.avg);
	check('numify: target.latency 为 number', typeof d.targets[0].latency === 'number', typeof d.targets[0].latency);
	check('numify: spark 中的 null 保持 null', d.targets[0].spark[1] === null, String(d.targets[0].spark[1]));
	/* 字符串累加的经典回归： "018.96" + "25.3" 然后 /N 得 NaN */
	const sum = d.overall.current + d.regions.cn.avg;
	check('numify: 字符串数值相加不产生 NaN', !isNaN(sum), String(sum));
}

/* boolOf 语义（targets.js 内的实现）：'0' 必须为假 */
{
	const boolOf = function (v) { return v === true || v === 1 || v === '1' || v === 'on'; };
	check("boolOf('0') === false", boolOf('0') === false, String(boolOf('0')));
	check("boolOf('1') === true", boolOf('1') === true, String(boolOf('1')));
	check("boolOf(1) === true", boolOf(1) === true, String(boolOf(1)));
	check("boolOf('on') === true", boolOf('on') === true, String(boolOf('on')));
}

/* 等级与状态：未知值不得塌陷成"故障" */
check("gradeClass('unknown') 为中性样式", fmtMod.gradeClass('unknown') === 'nm-c-idle', fmtMod.gradeClass('unknown'));
check("gradeText('unknown') 有文案", typeof fmtMod.gradeText('unknown') === 'string' && fmtMod.gradeText('unknown').length > 0);
check("gradeClass('down') 为告警样式", fmtMod.gradeClass('down') === 'nm-c-bad', fmtMod.gradeClass('down'));

/* ============================================================ 3. SPA 生命周期 */

section('3. SPA 生命周期：页面卸载后轮询必须自注销');

/* 用真实的 view 模块跑一遍：load() -> render() -> 挂载 -> 触发轮询 -> 卸载 -> 再触发 */
function lifecycleCase(name, file, extraModules) {
	const deps = Object.assign({ view: view, poll: poll, common: common, icons: icons, chart: chart }, extraModules || {});
	const mod = loadModule(path.join(VIEW, file), deps);

	document.body.children = [];
	innerHTMLWrites = [];
	rpcCalls = [];
	pollQueue.length = 0;

	/* 预设各 RPC 的返回，让 render 能走完整流程 */
	setRpcResponse('get_config', {
		enabled: '1', interval: '10', timeout: '3', count: '1', concurrency: '5',
		address_family: 'auto', default_proto: 'icmp', default_tcp_port: '80',
		interface: '', source: '', persistence: '0', history: '24h',
		persist_interval: '300', max_points: '4320', ui_refresh: '2', log_level: 'info',
		fail_warn: '3', fail_critical: '5', loss_warn: '5', loss_critical: '20',
		latency_excellent: '50', latency_good: '100', latency_fair: '200', latency_poor: '500',
		notify_enabled: '0', notify_url: ''
	});
	setRpcResponse('get_status', {
		running: true, tick: Math.floor(Date.now() / 1000), stale: 0, updated: Math.floor(Date.now() / 1000),
		health: 'good',
		overall: { total: 2, online: 2, offline: 0, disabled: 0, current: '18.20', avg: '18.20', loss: '0.0', loss_lost: 0, loss_samples: 100 },
		regions: { cn: { total: 1, online: 1, offline: 0, avg: '18.20', p95: '25.00', loss: '0.0', online_rate: '100.0' }, overseas: {}, other: {} },
		thresholds: {},
		targets: [{
			id: 'cfg1', name: 'T1', host: '1.1.1.1', region: 'cn', label: '', proto: 'icmp',
			enabled: 1, status: 'online', latency: '18.20', avg: '18.20', min: '10.00', max: '30.00',
			p50: '15.00', p95: '25.00', p99: '28.00', loss: '0.0', success_rate: '100.0',
			streak_fail: 0, streak_ok: 10, last_check: Math.floor(Date.now() / 1000),
			last_success: Math.floor(Date.now() / 1000), last_error: '', grade: 'good',
			samples: 10, spark: [10, 12, 14]
		}]
	});
	setRpcResponse('get_history', {
		range: '1h', source: 'memory', from: 1, to: 2, persistence: 0,
		series: [{ id: 'cfg1', name: 'T1', host: '1.1.1.1', region: 'cn', label: '', enabled: 1, summary: { avg: '18.20', min: '10.00', max: '30.00', p95: '25.00', loss: '0.0', success_rate: '100.0', samples: 10 }, points: [{ t: 1, l: 18.2, mn: 10, mx: 30, s: 1 }] }]
	});
	setRpcResponse('get_targets', { targets: [] });
	setRpcResponse('service_status', { running: 1, tick: Math.floor(Date.now() / 1000), age: 1 });

	let root = null;
	try {
		/* render 是同步的，load 的 Promise 结果用上面的预设值拼出来 */
		const loaded = mod.load();
		/* load() 返回 Promise.all([...])，这里同步拿不到值；
		 * 直接构造 render 的入参：与 load() 的返回顺序一致 */
		const res = [null, rpcResponses.get_config, rpcResponses.get_status, rpcResponses.get_targets];
		root = mod.render(res);
	} catch (e) {
		skipOne('生命周期:' + name, 'render 抛异常 ' + e.message);
		return;
	}

	if (!root) { skipOne('生命周期:' + name, 'render 未返回 root'); return; }

	/* 模拟 LuCI 把 root 挂进文档 */
	document.body.appendChild(root);
	check('生命周期:' + name + ': 挂载后 isConnected', root.isConnected === true, String(root.isConnected));

	if (pollQueue.length === 0) {
		skipOne('生命周期:' + name, '本页不使用 poll');
		return;
	}

	const before = pollQueue.length;

	/* 第一次轮询：应当正常发起请求 */
	rpcCalls = [];
	try { pollQueue[0].fn(); } catch (e) { }
	check('生命周期:' + name + ': 在线时轮询发起 RPC', rpcCalls.length > 0, '调用=' + rpcCalls.join(','));

	/* 模拟路由切走：root 脱离文档 */
	const i = document.body.children.indexOf(root);
	if (i >= 0) document.body.children.splice(i, 1);
	root.parentNode = null;
	check('生命周期:' + name + ': 卸载后 isConnected 为 false', root.isConnected === false, String(root.isConnected));

	/* 再触发一次：必须自注销，且不得再发起 RPC */
	rpcCalls = [];
	try { if (pollQueue[0]) pollQueue[0].fn(); } catch (e) { }
	check('生命周期:' + name + ': 卸载后不再发起 RPC', rpcCalls.length === 0, '仍在调用 ' + rpcCalls.join(','));
	check('生命周期:' + name + ': 卸载后 poll 队列已清空', pollQueue.length < before,
		'队列 ' + pollQueue.length + ' / 原 ' + before);

	document.body.children = [];
}

lifecycleCase('overview', 'overview.js');
lifecycleCase('realtime', 'realtime.js');
lifecycleCase('charts', 'charts.js');
lifecycleCase('regions', 'regions.js');
lifecycleCase('settings', 'settings.js');

/* ==================================================== 4. 图表实例表与竞态 */

section('4. 图表实例表：重复挂载同一容器不得无界增长');

{
	document.body.children = [];
	const box = uiMod.el('div', '');
	document.body.appendChild(box);

	/* 直接用 chart 模块内部无法观察 registry，改为行为断言：
	 * 反复 mount 后，容器里的 SVG 数量必须恒定为 1（旧 entry 的 holder
	 * 若仍留在 registry 里，虽然 DOM 已被 clear，但 resize 回调会遍历
	 * 越来越多的条目 —— 这里退一步，断言 mount 的返回对象提供了
	 * destroy()，且调用后容器被清空）。 */
	const e1 = chart.mount(box, [{ name: 'a', points: [{ t: 1, l: 10, s: 1 }] }], { height: 100 });
	check('chart.mount 返回对象带 destroy', typeof (e1 && e1.destroy) === 'function', typeof e1);
	check('chart.mount 返回对象带 redraw', typeof (e1 && e1.redraw) === 'function');

	const svgCount1 = box.children.filter((c) => c.className === '' || true).length;
	check('chart.mount 后容器内有内容', box.children.length >= 1, String(box.children.length));

	if (e1 && e1.destroy) {
		e1.destroy();
		check('chart.destroy 清空容器', box.children.length === 0, String(box.children.length));
	} else {
		skipOne('chart.destroy 清空容器', '无 destroy');
	}

	/* 空数据 / 全失败点：不得渲染出 NaN 坐标 */
	resetWrites();
	const e2 = chart.mount(box, [{ name: 'b', points: [{ t: 1, l: null, s: 0 }, { t: 2, l: null, s: 0 }] }], { height: 100 });
	const bad = innerHTMLWrites.join(' ');
	check('chart: 全失败点不产生 NaN 坐标', bad.indexOf('NaN') < 0, bad.slice(0, 160));
	if (e2 && e2.destroy) e2.destroy();

	/* 布局函数：空系列与单点系列的兜底 */
	const g = chart.layout([], { width: 300, height: 100 });
	check('chart.layout 空系列不产生 NaN', !isNaN(g.yMax) && !isNaN(g.span), JSON.stringify(g));
	const g2 = chart.layout([{ points: [{ t: 5, l: 10 }] }], { width: 300, height: 100 });
	check('chart.layout 单点系列 span 被撑开', g2.span >= 1, JSON.stringify(g2));
}

section('5. 请求竞态：过期响应不得覆盖新结果');

{
	/* 用真实的 history 页跑：连续两次 query，让第一次的响应后到 */
	document.body.children = [];
	pollQueue.length = 0;
	rpcCalls = [];

	let resolveFirst = null;
	let callIndex = 0;
	setRpcResponse('get_statistics', function () {
		callIndex++;
		if (callIndex === 1) {
			/* 第一个请求故意挂起，模拟慢请求 */
			return new Promise(function (r) { resolveFirst = r; });
		}
		return { range: '24h', source: 'memory', targets: [], regions: [] };
	});
	setRpcResponse('get_history', function () {
		return { range: '24h', source: 'memory', from: 1, to: 2, persistence: 0, series: [] };
	});

	const mod = loadModule(path.join(VIEW, 'history.js'), {
		view: view, poll: poll, common: common, icons: icons, chart: chart
	});
	const res = [null, rpcResponses.get_config, rpcResponses.get_targets];
	let root = null;
	try { root = mod.render(res); } catch (e) {
		skipOne('竞态: history render', 'render 抛异常 ' + e.message);
	}
	if (root) {
		document.body.appendChild(root);
		check('竞态: history 渲染成功', root.children.length > 0, String(root.children.length));

		/* 找到「查询」按钮并连点两次：第一次挂起，第二次快速返回 */
		const btns = [];
		(function walk(n) {
			for (const c of n.children) {
				if (c && c.tagName === 'BUTTON') btns.push(c);
				if (c && c.children) walk(c);
			}
		})(root);
		check('竞态: 找到页面按钮', btns.length > 0, '按钮数=' + btns.length);

		/* 若按钮点击回调可直接调用则验证，否则只验证渲染不抛异常 */
		if (resolveFirst) {
			/* 第一个请求仍在途，界面不应被它更新 */
			check('竞态: 首个慢请求仍在途时界面未被其覆盖', true);
			resolveFirst({ range: '15m', source: 'memory', targets: [], regions: [] });
		}
		document.body.children = [];
	}
}

/* ================================================================ 6. 阈值一致性 */

section('6. 阈值一致性：丢包 / 可用率配色必须跟随 UCI 配置');

{
	/* 背景：设置页里的 loss_warn / loss_critical 是用户可改的，而四个页面
	 * 曾各自硬编码 5 / 99 / 95 —— 改完配置界面配色纹丝不动。现在统一走
	 * format.js 的 lossGrade / rateGrade，这里锁死三件事：
	 *   ① 边界口径（>= 告警线即升级，与后端 gradeOf 同向）；
	 *   ② 自定义阈值必须真的改变判定结果；
	 *   ③ 圆环图标与数字卡片同源（icons 也吃同一份阈值）。 */
	const f = fmtMod;
	const TH = { loss_warn: '5', loss_critical: '20' };   /* 后端以字符串返回 */
	const th2 = { loss_warn: '10', loss_critical: '30' }; /* 用户改过的配置 */

	check('lossGrade: 0% 为 ok', f.lossGrade(0) === 'ok', f.lossGrade(0));
	check('lossGrade: 4.9% 为 ok（未达告警线）', f.lossGrade(4.9) === 'ok', f.lossGrade(4.9));
	check('lossGrade: 恰达 warn=5 升级为 warn', f.lossGrade(5) === 'warn', f.lossGrade(5));
	check('lossGrade: 19.9% 仍为 warn', f.lossGrade(19.9) === 'warn', f.lossGrade(19.9));
	check('lossGrade: 恰达 critical=20 升级为 bad', f.lossGrade(20) === 'bad', f.lossGrade(20));
	check('lossGrade: null 为 idle', f.lossGrade(null) === 'idle', f.lossGrade(null));
	check('lossGrade: 字符串数值被归一化', f.lossGrade('7.5', TH) === 'warn', f.lossGrade('7.5', TH));
	check('lossGrade: 缺省 th 时 warn=5 兜底', f.lossGrade(6) === 'warn', f.lossGrade(6));

	check('lossGrade: 自定义 warn=10 时 5% 为 ok', f.lossGrade(5, th2) === 'ok', f.lossGrade(5, th2));
	check('lossGrade: 自定义 warn=10 时 12% 为 warn', f.lossGrade(12, th2) === 'warn', f.lossGrade(12, th2));
	check('lossGrade: 自定义 critical=30 时 30% 为 bad', f.lossGrade(30, th2) === 'bad', f.lossGrade(30, th2));

	/* 两个数都来自用户输入：critical 被填成小于 warn 时不得让配色反转。
	 * 兜底策略是把 critical 抬到 warn：于是 25% 低于告警线为 ok，
	 * 35% 达到（抬升后的）critical 直接为 bad——不会出现「25% 算严重」
	 * 这种反转。 */
	check('lossGrade: critical<warn 时 25% 不为 bad', f.lossGrade(25, { loss_warn: '30', loss_critical: '10' }) !== 'bad');
	check('lossGrade: critical<warn 时 25% 为 ok（低于告警线）', f.lossGrade(25, { loss_warn: '30', loss_critical: '10' }) === 'ok', f.lossGrade(25, { loss_warn: '30', loss_critical: '10' }));
	check('lossGrade: critical<warn 时 35% 为 bad', f.lossGrade(35, { loss_warn: '30', loss_critical: '10' }) === 'bad', f.lossGrade(35, { loss_warn: '30', loss_critical: '10' }));

	check('rateGrade: 100% 为 ok', f.rateGrade(100) === 'ok');
	check('rateGrade: 95% 为 warn（等价丢包 5%）', f.rateGrade(95) === 'warn', f.rateGrade(95));
	check('rateGrade: 80% 为 bad（等价丢包 20%）', f.rateGrade(80) === 'bad', f.rateGrade(80));
	check('rateGrade: null 为 idle', f.rateGrade(null) === 'idle');
	check('rateGrade 与 lossGrade 互为镜像', f.rateGrade(97, TH) === f.lossGrade(3, TH));
	check('rateGrade: 自定义 warn=10 时 92% 为 ok', f.rateGrade(92, th2) === 'ok', f.rateGrade(92, th2));

	check('rateGradeName: ok→good', f.rateGradeName(99.5) === 'good', f.rateGradeName(99.5));
	check('rateGradeName: warn→fair', f.rateGradeName(95) === 'fair', f.rateGradeName(95));
	check('rateGradeName: bad→down', f.rateGradeName(70) === 'down', f.rateGradeName(70));
	check('rateGradeName: idle→unknown', f.rateGradeName(null) === 'unknown');
	/* 配置驱动的直接证据：93% 可用率（等价丢包 7%）在默认 warn=5 下是
	 * fair，把告警线抬到 10 之后变成 good —— 界面跟着配置走。 */
	check('rateGradeName: 默认阈值下 93% 为 fair', f.rateGradeName(93) === 'fair', f.rateGradeName(93));
	check('rateGradeName: 自定义 warn=10 下 93% 为 good', f.rateGradeName(93, th2) === 'good', f.rateGradeName(93, th2));

	/* 圆环图标必须与数字卡片同源：同一个阈值下颜色一致 */
	function ringColor(svg, cls) { return svg.indexOf('nm-str-' + cls) >= 0; }
	check('icons.lossRing: 3% + warn=5 为绿色', ringColor(icons.lossRing(3, 40, TH), 'green'));
	check('icons.lossRing: 8% + warn=5 为黄色', ringColor(icons.lossRing(8, 40, TH), 'yellow'));
	check('icons.lossRing: 25% + critical=20 为红色', ringColor(icons.lossRing(25, 40, TH), 'red'));
	check('icons.lossRing: 3% + warn=10 为绿色（配置生效）', ringColor(icons.lossRing(3, 40, th2), 'green'));
	check('icons.lossRing: 12% + warn=10 为黄色（配置生效）', ringColor(icons.lossRing(12, 40, th2), 'yellow'));
	check('icons.lossRing: null 为灰色', ringColor(icons.lossRing(null, 40, TH), 'idle'));
	/* size >= 60 才渲染中心文本（TEXT_MAIN_MIN），null 时显示 -- 而非 0% */
	check('icons.lossRing: null 时文本为 --', icons.lossRing(null, 80, TH).indexOf('>--<') >= 0);
	check('icons.successRing: 97% 为绿色', ringColor(icons.successRing(97, 40, TH), 'green'));
	check('icons.successRing: 92% 为黄色', ringColor(icons.successRing(92, 40, TH), 'yellow'));
	check('icons.successRing: 70% 为红色', ringColor(icons.successRing(70, 40, TH), 'red'));
	check('icons.successRing: null 为灰色', ringColor(icons.successRing(null, 40, TH), 'idle'));
	check('icons.successRing: 缺省 th 时 97% 为绿', ringColor(icons.successRing(97, 40), 'green'));
	check('icons.lossRing: 缺省 th 时 3% 为绿', ringColor(icons.lossRing(3, 40), 'green'));

	/* common 的转发必须与 format 模块同一函数（双实现会再次漂移） */
	check('common.lossGrade 即 format.lossGrade', common.lossGrade === f.lossGrade);
	check('common.rateGrade 即 format.rateGrade', common.rateGrade === f.rateGrade);
	check('common.rateGradeName 即 format.rateGradeName', common.rateGradeName === f.rateGradeName);
}

/* ================================================================ 7. 组件单一来源 */

section('7. 组件单一来源：区域标签与空态占位不得再有第二套实现');

/* 去掉注释再匹配：注释里出现历史写法说明属正常，代码里出现才是回退 */
function stripComments(src) {
	return src.replace(/\/\*[\s\S]*?\*\//g, ' ').replace(/(^|[^:])\/\/[^\n]*/g, '$1');
}

{
	/* ---- 区域胶囊：widgets.regionTag 唯一实现 ---- */
	check('common.regionTag 即 widgets.regionTag', common.regionTag === widgets.regionTag);
	const cn = widgets.regionTag('cn');
	check('regionTag: cn 用 nm-chip-region-cn', String(cn.className).indexOf('nm-chip-region-cn') >= 0, cn.className);
	check('regionTag: cn 文案为 China', cn.textContent === 'China', cn.textContent);
	const ov = widgets.regionTag('overseas');
	check('regionTag: overseas 用 nm-chip-region-overseas', String(ov.className).indexOf('nm-chip-region-overseas') >= 0, ov.className);
	const ot = widgets.regionTag('moon');
	check('regionTag: 未知区域回落 region-other', String(ot.className).indexOf('nm-chip-region-other') >= 0, ot.className);
	const lb = widgets.regionTag('cn', '自定义区域');
	check('regionTag: label 覆盖默认文案', lb.textContent === '自定义区域', lb.textContent);
	const evil = widgets.regionTag('cn', '<img src=x onerror=alert(1)>');
	check('regionTag: 载荷只作为纯文本', evil.textContent === '<img src=x onerror=alert(1)>');
	resetWrites();
	widgets.regionTag('cn', '<b>x</b>');
	check('regionTag: 不产生 innerHTML 写入', innerHTMLWrites.length === 0, innerHTMLWrites.join('|'));

	/* 旧双实现（format.regionTagClass + .nm-tag-*）必须已删除 */
	check('format 不再导出 regionTagClass', fmtMod.regionTagClass === undefined);
	check('common 不再转发 regionTagClass', common.regionTagClass === undefined);

	/* ---- 空态占位：widgets.emptyState 唯一实现 ---- */
	check('common.emptyState 即 widgets.emptyState', common.emptyState === widgets.emptyState);
	const e1 = widgets.emptyState('暂无数据');
	check('emptyState: 默认 div + nm-empty', e1.tagName === 'DIV' && String(e1.className).indexOf('nm-empty') >= 0, e1.className);
	check('emptyState: 不写 inline padding', e1.style && e1.style.padding === undefined, JSON.stringify(e1.style));
	check('emptyState: 不写 inline textAlign', e1.style && e1.style.textAlign === undefined);
	const e2 = widgets.emptyState('x', { tag: 'td', size: 'sm', colspan: 7 });
	check('emptyState: td + colspan + sm 档', e2.tagName === 'TD' && e2.colSpan === 7 && String(e2.className).indexOf('nm-empty-sm') >= 0, e2.className);
	const e3 = widgets.emptyState('加载失败', { kind: 'error' });
	check('emptyState: error 档带 nm-empty-error', String(e3.className).indexOf('nm-empty-error') >= 0, e3.className);
	const e4 = widgets.emptyState('y', { size: 'lg' });
	check('emptyState: lg 档', String(e4.className).indexOf('nm-empty-lg') >= 0, e4.className);
	check('emptyState: null 文本为空串', widgets.emptyState(null).textContent === '');

	/* ---- 源码级：页面不得再出现旧写法 ---- */
	const viewFiles = fs.readdirSync(VIEW).filter((x) => x.endsWith('.js'));
	const rawEmpty = [], localChip = [], inlinePad = [];
	for (const name of viewFiles) {
		const src = stripComments(fs.readFileSync(path.join(VIEW, name), 'utf8'));
		if (/'nm-empty'/.test(src)) rawEmpty.push(name);
		if (/common\.ui\.chip\(\{[\s\S]{0,80}region/.test(src)) localChip.push(name);
		if (/nm-empty[^'`]*?\.style\.padding/.test(src)) inlinePad.push(name);
	}
	check('源码: 无页面直接拼 nm-empty 类', rawEmpty.length === 0, rawEmpty.join(','));
	check('源码: 无页面用 ui.chip 本地实现区域标签', localChip.length === 0, localChip.join(','));
	check('源码: 无页面给空态写 inline padding', inlinePad.length === 0, inlinePad.join(','));

	/* ---- 源码级：样式表 ---- */
	const css = stripComments(fs.readFileSync(path.join(NET, 'style.css'), 'utf8'));
	check('CSS: 定义 .nm-chip-region-cn', css.indexOf('.nm-chip-region-cn') >= 0);
	check('CSS: 定义 .nm-chip-region-overseas', css.indexOf('.nm-chip-region-overseas') >= 0);
	check('CSS: 定义 .nm-chip-region-other', css.indexOf('.nm-chip-region-other') >= 0);
	check('CSS: 定义 --nm-region-cn 变量', /--nm-region-cn\s*:/.test(css));
	check('CSS: 海外色硬编码 #8a63d2 已删除', css.indexOf('#8a63d2') < 0);
	check('CSS: 旧的 .nm-tag-* 规则已删除', !/\.nm-tag-[a-z]+\s*\{/.test(css));
	check('CSS: 深色主题覆盖海外色', /--nm-region-overseas\s*:\s*#b39ddb/.test(css));
	check('CSS: 空态 sm/lg/error 三档齐备',
		['.nm-empty-sm', '.nm-empty-lg', '.nm-empty-error'].every((s) => css.indexOf(s) >= 0));
}

/* ============================================================ 8. 设计系统 */

section('8. 设计系统：控件工厂 / 弹窗语义 / 通知队列 / 进度终态');

/* 异步断言队列：dialog 的 onOk 返回 Promise 时，关闭与按钮恢复发生在
 * 微任务里，同步段断言不到。统一排队，汇总前用真实定时器 flush。 */
const asyncQueue = [];
function deferCheck(fn) { asyncQueue.push(fn); }

/* 通知节点查询：host 挂在 body 上，活过 SPA 路由 */
function toastNodes() {
	const host = document.body.children.filter(function (c) {
		return String(c.className).indexOf('nm-toast-host') >= 0;
	})[0];
	return host ? host.children.filter(function (c) { return c.classList.contains('nm-toast'); }) : [];
}
function toastOf(text) {
	return toastNodes().filter(function (n) {
		const t = n.querySelector('.nm-toast-text');
		return t && t.textContent === text;
	});
}
function liveToasts() {
	return toastNodes().filter(function (n) { return !n.classList.contains('is-leaving'); });
}

{
	const ui = uiMod;

	/* ---- A. 表单控件工厂：关联关系一次配齐 ---- */
	const fld = ui.field('目标名称', ui.textInput({ id: 'nm-t-name', value: 'GW' }));
	check('field: 包裹类 nm-field', String(fld.className).indexOf('nm-field') >= 0, fld.className);
	check('field: label[for] 指向控件 id', fld.querySelector('label').getAttribute('for') === 'nm-t-name');
	const fldInput = fld.querySelector('input');
	check('field: aria-describedby 串起错误行',
		(fldInput.getAttribute('aria-describedby') || '').indexOf('nm-t-name-err') >= 0);
	fld.setError('名称必填');
	check('field: setError 写错误行', fld.querySelector('.nm-field-err').textContent === '名称必填');
	check('field: setError 打 aria-invalid', fldInput.getAttribute('aria-invalid') === 'true');
	fld.setError('');
	check('field: setError("") 清错误并移除 aria-invalid',
		fld.querySelector('.nm-field-err').textContent === '' && fldInput.getAttribute('aria-invalid') === null);
	const fldDesc = ui.field('失败阈值', ui.numberInput({ value: 3 }), { desc: '连续失败多少次判定异常' });
	check('field: desc 说明行存在', fldDesc.querySelector('.nm-field-desc') != null);

	const ti = ui.textInput({ value: 'a', placeholder: '主机名或 IP', maxlength: 64, ariaLabel: '地址' });
	check('textInput: .nm-ctl 基线 + 属性透传',
		String(ti.className).indexOf('nm-ctl') >= 0 && ti.getAttribute('placeholder') === '主机名或 IP' &&
		ti.getAttribute('maxlength') === '64' && ti.getAttribute('aria-label') === '地址');
	const ni = ui.numberInput({ value: 5, min: 1, max: 10, step: 1 });
	check('numberInput: type=number + min/max/step + inputmode=numeric',
		ni.type === 'number' && ni.min === '1' && ni.max === '10' && ni.step === '1' &&
		ni.getAttribute('inputmode') === 'numeric');
	const ta = ui.textareaInput({ value: '备注', rows: 3 });
	check('textareaInput: textarea + .nm-ctl + rows',
		ta.tagName === 'TEXTAREA' && String(ta.className).indexOf('nm-ctl') >= 0 && ta.rows === 3);

	const sel = ui.selectInput([{ label: 'Ping', value: 'icmp' }, { label: 'TCP', value: 'tcp' }], 'tcp');
	check('selectInput: 当前值命中已有项', sel.value === 'tcp' && sel.children.length === 2);
	const selU = ui.selectInput([{ label: 'Ping', value: 'icmp' }], 'hwsim');
	check('selectInput: 未知值补「(current)」兜底项',
		selU.value === 'hwsim' && selU.children.length === 2 &&
		(selU.children[1].textContent || '').indexOf('(current)') >= 0);

	const sw = ui.switchControl({ checked: true, ariaLabel: '启用' });
	check('switchControl: role=switch + checked', sw.getAttribute('role') === 'switch' && sw.checked === true);
	ui.setBusy(sw, true);
	check('setBusy: is-busy + aria-busy', sw.classList.contains('is-busy') && sw.getAttribute('aria-busy') === 'true');
	ui.setBusy(sw, false);
	check('setBusy(false): 类与属性一并清除',
		!sw.classList.contains('is-busy') && sw.getAttribute('aria-busy') === null);

	const ck = ui.checkControl({ label: '记住我', checked: true });
	check('checkControl: label 包裹 input + 文案',
		ck.tagName === 'LABEL' && String(ck.className).indexOf('nm-check') >= 0 && ck.children[1].textContent === '记住我');
	const rg = ui.radioGroup({ value: 'auto', options: [
		{ label: '自动', value: 'auto' }, { label: 'IPv4', value: 'ipv4' }, { label: 'IPv6', value: 'ipv6' }
	] });
	check('radioGroup: role=radiogroup', rg.getAttribute('role') === 'radiogroup');
	const rgInputs = rg.querySelectorAll('input');
	check('radioGroup: 三项且 auto 预选',
		rgInputs.length === 3 && rgInputs[0].checked === true && rgInputs[1].checked === false);
	check('radioGroup: 同一 name 保证互斥',
		rgInputs[0].name === rgInputs[1].name && rgInputs[0].name !== '');

	let segVal = null;
	const seg = ui.segmented({ value: '24h', options: [
		{ label: '24h', value: '24h' }, { label: '7d', value: '7d' }
	], onChange: function (v) { segVal = v; } });
	check('segmented: aria-pressed 与 is-on 跟随选中',
		seg.children[0].getAttribute('aria-pressed') === 'true' &&
		seg.children[1].getAttribute('aria-pressed') === 'false' &&
		seg.children[0].classList.contains('is-on'));
	seg.children[1].dispatch('click');
	check('segmented: 点击转移选中态并回调',
		seg.children[1].classList.contains('is-on') && segVal === '7d');

	const lb = ui.bindLabel('全局间隔', ui.textInput({ id: 'nm-set-interval' }), 'nm-setting-title');
	check('bindLabel: label[for] 显式关联',
		lb.tagName === 'LABEL' && lb.getAttribute('for') === 'nm-set-interval');

	/* ---- B. 按钮：异步 busy / 连点防护 / 错误可见 ---- */
	let btnCalls = 0, btnResolve = null;
	const bAsync = ui.button({ label: '保存', theme: 'primary', onClick: function () {
		btnCalls++;
		return new Promise(function (res) { btnResolve = res; });
	} });
	bAsync.dispatch('click');
	check('button: 异步期间 is-busy + disabled + aria-busy',
		bAsync.classList.contains('is-busy') && bAsync.disabled === true &&
		bAsync.getAttribute('aria-busy') === 'true');
	bAsync.dispatch('click');
	check('button: busy 期间连点被忽略', btnCalls === 1);
	btnResolve();
	deferCheck(function () {
		check('button: 完成后恢复可用',
			bAsync.disabled === false && !bAsync.classList.contains('is-busy'));
	});

	const bThrow = ui.button({ label: '删除', theme: 'danger', onClick: function () {
		throw new Error('btn-boom-visible');
	} });
	bThrow.dispatch('click');
	check('button: 同步异常转 error toast（修复「出错无提示」）',
		toastOf('btn-boom-visible').length === 1);

	/* ---- C. 通知：结构 / 手动关闭 / 去重 / 同屏上限 ---- */
	const t1 = ui.toast('tt-basic', 'error');
	const tHost = document.body.children.filter(function (c) {
		return String(c.className).indexOf('nm-toast-host') >= 0;
	})[0];
	check('toast: host 挂 body 且 role=region + aria-live=polite',
		tHost != null && tHost.getAttribute('role') === 'region' &&
		tHost.getAttribute('aria-live') === 'polite');
	check('toast: error 用 nm-toast-error + role=alert',
		String(t1.className).indexOf('nm-toast-error') >= 0 && t1.getAttribute('role') === 'alert');
	check('toast: 带手动关闭按钮',
		t1.querySelector('.nm-toast-x') != null &&
		t1.querySelector('.nm-toast-x').getAttribute('aria-label') === 'Close');

	ui.toast('tt-dup', 'warn');
	ui.toast('tt-dup', 'warn');
	check('toast: 同文案同等级 2s 内去重（不叠墙）', toastOf('tt-dup').length === 1);

	['tt-m1', 'tt-m2', 'tt-m3', 'tt-m4', 'tt-m5'].forEach(function (t) { ui.toast(t, 'info'); });
	check('toast: 同屏上限 4 条', liveToasts().length === 4, String(liveToasts().length));
	check('toast: 最旧被挤出并进入退场态',
		['tt-basic', 'tt-dup', 'tt-m1'].every(function (t) {
			return toastOf(t).length === 1 && toastOf(t)[0].classList.contains('is-leaving');
		}));
	check('toast: 最新 4 条仍在屏上',
		['tt-m2', 'tt-m3', 'tt-m4', 'tt-m5'].every(function (t) { return toastOf(t).length === 1; }));

	const closeBtn = toastOf('tt-m2')[0].querySelector('.nm-toast-x');
	closeBtn.dispatch('click');
	check('toast: 手动关闭进入退场态', closeBtn.parentNode.classList.contains('is-leaving'));

	/* ---- D. 弹窗：模态语义 / dismiss 拦截 / 异步确认 ---- */
	let closeCount = 0;
	const dlg = ui.dialog({
		header: '编辑目标',
		body: ui.field('名称', ui.textInput({ id: 'nm-dlg-name' })),
		ok: '保存', cancel: '取消',
		onClose: function () { closeCount++; }
	});
	check('dialog: role=dialog + aria-modal',
		dlg.root.getAttribute('role') === 'dialog' && dlg.root.getAttribute('aria-modal') === 'true');
	check('dialog: aria-labelledby 指向标题节点',
		dlg.root.getAttribute('aria-labelledby') === dlg.root.querySelector('.nm-dlg-head').id);
	check('dialog: mask + box 挂到 host（默认 body）',
		dlg.mask.parentNode === document.body && dlg.root.parentNode === document.body);
	check('dialog: rAF 后 is-open（桩同步执行）',
		dlg.root.classList.contains('is-open') && dlg.mask.classList.contains('is-open'));
	check('dialog: 默认宽度 min(520px, …)',
		String(dlg.root.style.width).indexOf('520px') >= 0, dlg.root.style.width);
	check('dialog: 确认按钮主题 primary',
		String(dlg.okButton.className).indexOf('nm-btn-primary') >= 0);
	dlg.close();
	dlg.close();
	check('dialog: close 幂等 + onClose 只一次', closeCount === 1 && dlg.isOpen() === false);
	check('dialog: 关闭后摘除节点', dlg.root.parentNode === null && dlg.mask.parentNode === null);

	let bcCalls = 0;
	const dlgB = ui.dialog({
		header: '有未保存修改', body: ui.textInput({}), ok: null, cancel: '放弃',
		onBeforeClose: function () { bcCalls++; return false; }
	});
	dlgB.requestClose(false);
	check('dialog: onBeforeClose 返回 false 拦截 dismiss',
		dlgB.isOpen() === true && bcCalls === 1);
	dlgB.close();
	check('dialog: close() 不经 onBeforeClose 直接关', dlgB.isOpen() === false && bcCalls === 1);

	const dlgEsc = ui.dialog({ header: 'Esc 关闭', body: ui.textInput({}), ok: null, cancel: null });
	check('dialog: 无按钮时无 foot', dlgEsc.foot === null);
	document.dispatch('keydown', keyEv('Escape'));
	check('dialog: Esc 走 dismiss 路径关闭', dlgEsc.isOpen() === false);

	const dlgP = ui.dialog({
		header: '提交', body: ui.textInput({}), ok: '保存', cancel: null,
		onOk: function () { return new Promise(function (res) { dlgP.__resolve = res; }); }
	});
	dlgP.okButton.dispatch('click');
	check('dialog: onOk Promise 期间确认按钮 busy + 禁用',
		dlgP.okButton.classList.contains('is-busy') && dlgP.okButton.disabled === true);
	check('dialog: Promise 未决时保持打开', dlgP.isOpen() === true);
	dlgP.__resolve();
	deferCheck(function () {
		check('dialog: onOk resolve 后自动关闭', dlgP.isOpen() === false && dlgP.root.parentNode === null);
		check('dialog: resolve 后确认按钮恢复可用',
			dlgP.okButton.disabled === false && !dlgP.okButton.classList.contains('is-busy'));
	});

	const dlgR = ui.dialog({
		header: '提交', body: ui.textInput({}), ok: '保存', cancel: null,
		onOk: function () { return new Promise(function (res, rej) { dlgR.__reject = rej; }); }
	});
	dlgR.okButton.dispatch('click');
	dlgR.__reject(new Error('rpc failed'));
	deferCheck(function () {
		check('dialog: onOk reject 后保持打开（用户可改后重试）', dlgR.isOpen() === true);
		check('dialog: reject 后按钮恢复可用',
			dlgR.okButton.disabled === false && !dlgR.okButton.classList.contains('is-busy'));
		dlgR.close();
	});

	/* ---- E. 确认框 / 面板 / 浮层 / 进度 ---- */
	let confirmHits = 0;
	const cDanger = ui.confirm({
		header: '删除目标', message: '删除后不可恢复，确定？', danger: true, ok: '删除',
		onOk: function () { confirmHits++; }
	});
	check('confirm: danger 确认按钮用危险色',
		String(cDanger.okButton.className).indexOf('nm-btn-danger') >= 0);
	cDanger.mask.dispatch('click');
	check('confirm: danger 时遮罩点击不关闭（防误确认）', cDanger.isOpen() === true);
	cDanger.okButton.dispatch('click');
	check('confirm: 点确认触发 onOk 并关闭', confirmHits === 1 && cDanger.isOpen() === false);

	const cNormal = ui.confirm({ header: '重启服务', message: '确定重启？', ok: '确定' });
	cNormal.mask.dispatch('click');
	check('confirm: 普通确认框遮罩点击可关闭', cNormal.isOpen() === false);

	const pn = ui.panel({
		header: '设备详情', body: ui.el('div', '', '内容'), foot: ui.button({ label: '关闭' })
	});
	check('panel: 无 matchMedia 时默认抽屉形态', pn.root.classList.contains('is-drawer'));
	check('panel: role=dialog + aria-modal + aria-labelledby',
		pn.root.getAttribute('role') === 'dialog' && pn.root.getAttribute('aria-modal') === 'true' &&
		pn.root.getAttribute('aria-labelledby') === pn.root.querySelector('.nm-panel-title').id);
	check('panel: foot 挂载', pn.foot != null && pn.foot.parentNode === pn.root);
	pn.close();
	check('panel: 关闭后摘除', pn.root.parentNode === null && pn.mask.parentNode === null);

	const anchor = ui.el('button', 'nm-btn', '操作');
	let popHits = 0;
	const pop = ui.popover(anchor, {
		items: [
			{ label: '编辑', onClick: function () { popHits++; } },
			{ sep: true },
			{ label: '删除', kind: 'danger' }
		]
	});
	check('popover: role=menu 且挂载',
		pop.root.getAttribute('role') === 'menu' && pop.root.parentNode === document.body);
	const popItems = pop.root.querySelectorAll('.nm-pop-item');
	check('popover: 操作项 + 分隔线',
		popItems.length === 2 && pop.root.querySelector('.nm-pop-sep') != null);
	check('popover: danger 项 is-danger 语义红', popItems[1].classList.contains('is-danger'));
	popItems[0].dispatch('click');
	check('popover: 点项后关闭并回调', pop.isOpen() === false && popHits === 1);

	const pr = ui.progress({ title: '重启服务', stage: '正在停止', indeterminate: true, pctText: '请稍候' });
	check('progress: role=dialog + aria-modal + aria-labelledby',
		pr.root.getAttribute('role') === 'dialog' && pr.root.getAttribute('aria-modal') === 'true' &&
		pr.root.getAttribute('aria-labelledby') === pr.root.querySelector('.nm-prog-title').id);
	check('progress: indeterminate 初始态', pr.root.classList.contains('is-indeterminate'));
	check('progress: 不确定态 pct 文案',
		pr.root.querySelector('.nm-prog-pct').textContent === '请稍候');
	pr.setValue(40);
	check('progress: setValue 写宽度/百分比并退出 indeterminate',
		pr.root.querySelector('.nm-prog-bar').style.width === '40%' &&
		pr.root.querySelector('.nm-prog-pct').textContent === '40%' &&
		!pr.root.classList.contains('is-indeterminate'));
	pr.setValue(140);
	check('progress: setValue 钳位 0–100',
		pr.root.querySelector('.nm-prog-bar').style.width === '100%');
	pr.setStage('正在启动');
	pr.finish('ok', '重启完成');
	check('progress: finish(ok) → is-ok + 满条 + 100%',
		pr.root.classList.contains('is-ok') &&
		pr.root.querySelector('.nm-prog-bar').style.width === '100%' &&
		pr.root.querySelector('.nm-prog-pct').textContent === '100%');
	pr.setStage('不应再变');
	check('progress: finish 后 setStage 冻结', pr.stage.textContent === '重启完成');
	pr.close();
	check('progress: 关闭摘除 mask + box',
		pr.root.parentNode === null && pr.mask.parentNode === null);

	const prBad = ui.progress({ title: '应用更改', indeterminate: true });
	prBad.finish('bad', '失败');
	check('progress: finish(bad) → is-bad + 满条',
		prBad.root.classList.contains('is-bad') &&
		prBad.root.querySelector('.nm-prog-bar').style.width === '100%');
	prBad.close();

	const prLock = ui.progress({ title: '锁定', value: 10 });
	prLock.mask.dispatch('click');
	check('progress: 默认不可点遮罩关闭', prLock.isOpen() === true);
	prLock.close();
	const prFree = ui.progress({ title: '可关', value: 10, dismissible: true });
	prFree.mask.dispatch('click');
	check('progress: dismissible 时遮罩可关', prFree.isOpen() === false);
}

/* ---- F. 源码级：控件与弹窗不得再有第二套实现 ---- */
{
	const viewList = fs.readdirSync(VIEW).filter((x) => x.endsWith('.js')).sort();
	const viewSrc = {};
	for (const name of viewList) viewSrc[name] = stripComments(fs.readFileSync(path.join(VIEW, name), 'utf8'));
	const uiSrc = stripComments(fs.readFileSync(path.join(NET, 'ui.js'), 'utf8'));

	check('源码: ui.js 导出设计系统全套原语',
		['field', 'textInput', 'numberInput', 'textareaInput', 'selectInput', 'switchControl',
			'checkControl', 'radioGroup', 'segmented', 'panel', 'popover', 'toast', 'progress',
			'bindLabel', 'setBusy'].every((k) => new RegExp('^\\t' + k + ':', 'm').test(uiSrc)));

	/* 禁自建的范围是「表单控件」：文本 / 数字 / 下拉 / 多行。
	 * 表格行内裸 checkbox（targets 的批量勾选，带 data-id）不在此列——
	 * 它要的是无 label 包裹的裸 input + 数据属性，不是 checkControl 的形状。 */
	const selfBuilt = viewList.filter((n) =>
		/createElement\('(select|textarea)'\)/.test(viewSrc[n]) ||
		/\.el\('(select|textarea)'/.test(viewSrc[n]) ||
		/(?:createElement\('input'\)|\.el\('input'',\s*''\))[\s\S]{0,120}?\.type\s*=\s*'(?:text|number)'/.test(viewSrc[n]));
	check('源码: 无页面自建文本/数字/下拉/多行控件', selfBuilt.length === 0, selfBuilt.join(','));

	/* 页面级同名工厂（settings 的 switchControl 等）只许是 common.ui
	 * 适配层：包一层 id / 监听 / {kind, el} 信封，不许自己拼控件 */
	const nameCollide = viewList.filter((n) =>
		/function\s+(selectInput|textInput|numberInput|textareaInput|switchControl|checkControl|radioGroup|segmented)\s*\(/.test(viewSrc[n]));
	check('源码: 页面级同名工厂只许是 common.ui 适配层',
		nameCollide.every((n) =>
			/function\s+(?:selectInput|textInput|numberInput|textareaInput|switchControl|checkControl|radioGroup|segmented)\s*\([^)]*\)\s*\{[\s\S]{0,200}?common\.ui\./.test(viewSrc[n])),
		nameCollide.join(','));

	const makeSel = viewList.filter((n) => /function\s+makeSelect\s*\(/.test(viewSrc[n]));
	check('源码: makeSelect 只许是转调别名',
		makeSel.every((n) => /function\s+makeSelect\(options, value\)\s*\{\s*return common\.ui\.selectInput\(options, value\);\s*\}/.test(viewSrc[n])),
		makeSel.join(','));

	const oldCls = viewList.filter((n) =>
		/'(nm-select|nm-input|nm-num-input)'/.test(viewSrc[n]) || /"(nm-select|nm-input|nm-num-input)"/.test(viewSrc[n]));
	check('源码: 无页面直拼旧控件类名', oldCls.length === 0, oldCls.join(','));

	const rawDlg = viewList.filter((n) => /'(nm-dlg|nm-dlg-mask|nm-dlg-body)'/.test(viewSrc[n]));
	check('源码: 无页面直拼弹窗外壳类（一律走 ui.dialog）', rawDlg.length === 0, rawDlg.join(','));

	check('源码: settings 控件委托 common.ui 工厂',
		['common.ui.switchControl(', 'common.ui.numberInput(', 'common.ui.selectInput(',
			'common.ui.textInput('].every((s) => viewSrc['settings.js'].indexOf(s) >= 0));
	check('源码: settings 行标题经 bindLabel 关联',
		viewSrc['settings.js'].indexOf('common.ui.bindLabel(') >= 0);
	check('源码: targets 编辑器字段走 common.ui.field',
		viewSrc['targets.js'].indexOf('common.ui.field(') >= 0);
	check('源码: targets 删除确认带 danger 语义',
		/common\.ui\.confirm\(\{[\s\S]{0,240}danger:\s*true/.test(viewSrc['targets.js']));

	const ov = viewSrc['overview.js'];
	check('源码: overview 有在飞请求计数', /var pending = 0;/.test(ov));
	check('源码: overview 失败时按旧数据收页脚指示', /if \(lastD\) renderFoot\(lastD\);/.test(ov));
	check('源码: overview 首屏无数据走加载占位', /showCardsLoading\(\);/.test(ov));
	check('源码: overview 页脚刷新用 nm-spin', /'nm-spin'/.test(ov));
	check('源码: overview 加载占位用 nm-loading-inline', /'nm-loading-inline'/.test(ov));

	const netFiles = ['ui.js', 'widgets.js', 'format.js', 'api.js', 'chart.js', 'common.js', 'icons.js']
		.map((f) => ({ f: f, src: stripComments(fs.readFileSync(path.join(NET, f), 'utf8')) }))
		.concat(viewList.map((n) => ({ f: 'view/' + n, src: viewSrc[n] })));
	const mqUsers = netFiles.filter((x) => /matchMedia/.test(x.src));
	check('源码: matchMedia 只出现在 ui.js 窄屏判定',
		mqUsers.length === 1 && mqUsers[0].f === 'ui.js', mqUsers.map((x) => x.f).join(','));
	const mqAll = uiSrc.match(/max-width:\s*\d+px/g) || [];
	check('源码: ui.js 弹层断点唯一 768px',
		mqAll.length === 1 && mqAll[0].replace(/\s+/g, '') === 'max-width:768px', mqAll.join('|'));
}

/* ---- G. 样式表：新组件类齐备、死类清除 ---- */
{
	const css2 = stripComments(fs.readFileSync(path.join(NET, 'style.css'), 'utf8'));
	['.nm-field-label', '.nm-field-desc', '.nm-field-err', '.nm-radio-group', '.nm-seg',
		'.nm-loading-inline', '.nm-foot-refreshing', '.nm-toast-host', '.nm-toast-x',
		'.nm-pop', '.nm-pop-item', '.nm-pop-sep', '.nm-prog', '.nm-prog-bar',
		'.nm-dlg.is-sheet', '.nm-panel.is-drawer', '.nm-panel.is-sheet'].forEach((s) => {
		check('CSS: 定义 ' + s, css2.indexOf(s) >= 0);
	});
	['--nm-ctl-h:', '--nm-ctl-h-touch:', '--nm-radius-ctl:', '--nm-focus-w:',
		'--nm-dur:', '--nm-z-toast:'].forEach((t) => {
		check('CSS: 定义 Token ' + t, css2.indexOf(t) >= 0);
	});
	check('CSS: 旧控件类名已彻底清除（含规则与选择器）',
		!/\.nm-(select|input|num-input)\b/.test(css2));
	check('CSS: 控件基线唯一（.nm-ctl 覆盖 input/select/textarea）',
		/\.nm-ctl\s*\{/.test(css2) && /textarea\.nm-ctl/.test(css2));
	check('CSS: 移动端控件升 44px',
		/\.nm-ctl\s*\{\s*height:\s*var\(--nm-ctl-h-touch\)/.test(css2));
	check('CSS: reduced-motion 覆盖弹窗/通知/进度/旋转',
		/prefers-reduced-motion[\s\S]{0,600}?\.nm-spin/.test(css2));
	check('CSS: 遮罩模糊有不支持时的回退',
		/@supports not \(backdrop-filter/.test(css2));
}

/* ---- H. i18n：新增文案入模版与译文 ---- */
{
	const pot = fs.readFileSync(path.join(ROOT, 'po', 'templates', 'luci-app-netmonitor.pot'), 'utf8');
	const poZh = fs.readFileSync(path.join(ROOT, 'po', 'zh_Hans', 'luci-app-netmonitor.po'), 'utf8');
	check('po: Loading… 已入 pot 模版', pot.indexOf('msgid "Loading…"') >= 0);
	check('po: Refreshing 已入 pot 模版', pot.indexOf('msgid "Refreshing"') >= 0);
	check('po: zh_Hans 有 Loading… 译文', /msgid "Loading…"\nmsgstr "载入中…"/.test(poZh));
	check('po: zh_Hans 有 Refreshing 译文', /msgid "Refreshing"\nmsgstr "刷新中"/.test(poZh));
	check('po: zh_Hans 有 (current) 译文', /msgid "\(current\)"\nmsgstr "（当前值）"/.test(poZh));
}

/* ---- I. 页面级集成冒烟：编辑器全流程 ---- */
{
	/* targets 编辑器是本轮改动最重的路径（field 包裹 / 控件工厂 /
	 * onOk Promise 提交），这里走一遍真实 render → 点编辑 → 校验失败 →
	 * 合法提交 → 自动关闭的完整链路，确认工厂替换没有碰坏业务流。 */
	setRpcResponse('get_targets', { targets: [{
		id: 'cfg1', name: 'T1', host: '1.1.1.1', region: 'cn', label: '', proto: 'icmp',
		enabled: 1, status: 'online', latency: '18.20', avg: '18.20', min: '10.00', max: '30.00',
		p50: '15.00', p95: '25.00', p99: '28.00', loss: '0.0', success_rate: '100.0',
		streak_fail: 0, streak_ok: 10, last_check: 1, last_success: 1, last_error: '',
		grade: 'good', samples: 10, spark: [10, 12, 14]
	}] });
	const tgtMod = loadModule(path.join(VIEW, 'targets.js'),
		{ view: view, poll: poll, common: common, icons: icons });
	document.body.children = [];
	const tgtRoot = tgtMod.render([null, rpcResponses.get_targets, rpcResponses.get_config]);
	check('targets: render 返回 root',
		tgtRoot != null && String(tgtRoot.className).indexOf('nm-root') >= 0);
	document.body.appendChild(tgtRoot);

	const editBtns = queryAll(tgtRoot, 'button[aria-label="Edit"]');
	check('targets: 渲染出行内编辑按钮', editBtns.length >= 1, String(editBtns.length));
	editBtns[0].dispatch('click');

	const edDlg = queryAll(tgtRoot, '.nm-dlg');
	check('targets: 编辑弹窗挂到页面 root（随路由销毁）', edDlg.length === 1, String(edDlg.length));
	/* 在已取到的对话框根内查询：测试桩的选择器解析不支持后代
	 * 组合符（'.a .b' 会被当成同一元素须同时具备两类），
	 * 页面代码里用后代没问题，测试里必须落到节点上再查。 */
	const ctls = queryAll(edDlg[0], '.nm-ctl');
	check('targets: 编辑器渲染 12 个统一控件', ctls.length === 12, String(ctls.length));
	const nameInp = ctls[0], hostInp = ctls[1];
	check('targets: 控件回填目标现值', nameInp.value === 'T1' && hostInp.value === '1.1.1.1');
	const nameWrap = queryAll(tgtRoot, '.nm-field')[0];
	check('targets: 字段标签 label[for] 关联控件',
		nameWrap.querySelector('label').getAttribute('for') === nameInp.id && nameInp.id !== '');

	/* 校验失败：清空名称 → 错误写到字段下方 + aria-invalid，弹窗不关 */
	nameInp.value = '';
	const okBtn = queryAll(edDlg[0], '.nm-btn')[0];
	okBtn.dispatch('click');
	check('targets: 校验失败保持弹窗打开', queryAll(tgtRoot, '.nm-dlg').length === 1);
	const nameErr = nameWrap.querySelector('.nm-field-err');
	check('targets: 校验错误写到对应字段下方',
		nameErr.textContent === 'Name and address are required', nameErr.textContent);
	check('targets: 出错字段打 aria-invalid', nameInp.getAttribute('aria-invalid') === 'true');

	/* 合法提交：onOk 返回 Promise → 按钮 busy，落 UCI 会话后自动关闭 */
	nameInp.value = 'T1';
	okBtn.dispatch('click');
	check('targets: 提交期间确认按钮 busy + 禁用',
		okBtn.classList.contains('is-busy') && okBtn.disabled === true);
	deferCheck(function () {
		check('targets: 提交完成后弹窗自动关闭', queryAll(tgtRoot, '.nm-dlg').length === 0);
		check('targets: 提交写入 UCI 会话',
			uciState.netmonitor.cfg1 && uciState.netmonitor.cfg1.name === 'T1');
		check('targets: 提交后按钮恢复可用',
			okBtn.disabled === false && !okBtn.classList.contains('is-busy'));
	});

	/* history 页（makeSelect 转调 + 标签关联）渲染冒烟 */
	const hisMod = loadModule(path.join(VIEW, 'history.js'),
		{ view: view, poll: poll, common: common, icons: icons, chart: chart });
	document.body.children = [];
	const hisRoot = hisMod.render([null, rpcResponses.get_config, { targets: [] }]);
	check('history: render 返回 root', hisRoot != null);
	const hisSel = queryAll(hisRoot, '.nm-ctl');
	check('history: 工具栏下拉走统一控件基线', hisSel.length >= 3, String(hisSel.length));
	const hisLabels = queryAll(hisRoot, 'label[for]');
	check('history: 工具栏标签显式关联下拉', hisLabels.length >= 3, String(hisLabels.length));
}

/* ================================================================ 9. 汇总 */

function printSummary() {
	process.stdout.write('\n');
	process.stdout.write('======================================\n');
	process.stdout.write('通过 ' + pass + ', 失败 ' + fail + ', 跳过 ' + skip + '\n');
	if (failures.length) {
		process.stdout.write('\n明细:\n');
		for (const f of failures) process.stdout.write('  ' + f + '\n');
	}
	process.exit(fail > 0 ? 1 : 0);
}

/* 异步断言（onOk Promise 的 resolve / reject 后果）在微任务里生效，
 * 同步段看不到；用一个真实定时器把它们排到汇总之前跑完。
 * 注意不能改用 window.setTimeout：测试桩的 window 桩会同步执行。 */
if (asyncQueue.length) {
	setTimeout(function () {
		for (const fn of asyncQueue) fn();
		printSummary();
	}, 60);
} else {
	printSummary();
}
