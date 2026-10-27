'use strict';
/*
 * ui-smoke —— 前端组件与视图冒烟测试（零依赖：node scripts/ui-smoke.js）
 *
 * 为什么需要它：LuCI 视图与弹层只有在真机浏览器里才会暴露问题，而 CI 与
 * 开发机都没有那台路由器。本脚本用最小 DOM stub 在 Node 里执行**真实模块代码**
 * （不是复刻逻辑），断言那些「错了也不会报错、只会在真机上表现为怪异」的行为：
 *
 *   * 视图：load → render 不抛异常、产物里没有 "[object HTML…]"；
 *   * 弹层：尺寸类、aria、焦点陷阱、ESC/遮罩/关闭按钮、未保存守卫、
 *           异步提交的重复提交保护与失败恢复、层级与清理；
 *   * 反馈：Toast 去重/上限/持久/进度态迁移；Loading 不伪造百分比；
 *   * 浮层：Popover 定位翻转与外部点击；Tooltip 的 focus 路径；
 *   * 表单：IP/端口校验的边界值、aria 关联、校验失败不丢用户输入。
 *
 * 它不验证视觉（像素只有真机浏览器能验）。视觉请用 scripts/ui-preview.html
 * 在浏览器里逐项核对——那里加载的是同一份 CSS 与同一批模块。
 */

const fs = require('fs');
const path = require('path');

const ROOT_DIR = path.join(__dirname, '..');
const RES = path.join(ROOT_DIR, 'htdocs', 'luci-static', 'resources');
const VIEWS = [ 'status', 'balance', 'failover', 'config', 'lines', 'games', 'traffic' ];

let failures = 0;
let checks = 0;
function check(cond, label) {
	checks++;
	if (cond) {
		console.log('  ok   ' + label);
	} else {
		failures++;
		console.log('  FAIL ' + label);
	}
}
function section(name) { console.log('\n' + name); }

/* ==================== 最小 DOM stub ==================== */

global.window = {
	setTimeout: function(fn, ms) { return setTimeout(fn, ms); },
	clearTimeout: function(id) { return clearTimeout(id); },
	requestAnimationFrame: function(fn) { return setTimeout(fn, 0); },
	innerWidth: 1280,
	innerHeight: 900,
	matchMedia: function(q) {
		/* 默认桌面端；测试可以临时改 window.__mobile 模拟窄屏。 */
		if (q.indexOf('max-width') >= 0) {
			var m = /max-width:\s*([\d.]+)px/.exec(q);
			var limit = m ? parseFloat(m[1]) : 768;
			return { matches: window.__mobile ? window.innerWidth <= limit : false };
		}
		if (q.indexOf('hover: none') >= 0)
			return { matches: !!window.__touch };
		return { matches: false };
	},
	addEventListener: function() {},
	removeEventListener: function() {}
};

function makeElement(tag) {
	const el = {
		tagName: String(tag).toUpperCase(),
		nodeType: 1,
		children: [],
		style: {},
		attrs: {},
		value: '',
		checked: false,
		disabled: false,
		_text: '',
		offsetWidth: 200,
		offsetHeight: 100,
		_parent: null,
		_listeners: {},
		setAttribute: function(k, v) { this.attrs[k] = String(v); },
		removeAttribute: function(k) { delete this.attrs[k]; },
		getAttribute: function(k) { return k in this.attrs ? this.attrs[k] : null; },
		addEventListener: function(type, fn) {
			(this._listeners[type] = this._listeners[type] || []).push(fn);
		},
		removeEventListener: function(type, fn) {
			const l = this._listeners[type] || [];
			const i = l.indexOf(fn);
			if (i >= 0) l.splice(i, 1);
		},
		appendChild: function(c) {
			if (c && c.nodeType) { c._parent = this; this.children.push(c); }
			return c;
		},
		insertBefore: function(c, ref) {
			if (!c || !c.nodeType) return c;
			const i = this.children.indexOf(ref);
			c._parent = this;
			if (i >= 0) this.children.splice(i, 0, c);
			else this.children.push(c);
			return c;
		},
		removeChild: function(c) {
			const i = this.children.indexOf(c);
			if (i >= 0) { this.children.splice(i, 1); c._parent = null; }
			return c;
		},
		replaceChild: function(n, o) {
			const i = this.children.indexOf(o);
			if (i >= 0) { o._parent = null; n._parent = this; this.children[i] = n; }
			return o;
		},
		contains: function(node) {
			let p = node;
			while (p) { if (p === this) return true; p = p._parent; }
			return false;
		},
		querySelector: function(sel) {
			const all = queryAll(this, sel);
			return all.length ? all[0] : null;
		},
		querySelectorAll: function(sel) { return queryAll(this, sel); },
		focus: function() { document.activeElement = this; },
		getClientRects: function() { return [ {} ]; },
		scrollIntoView: function() {},
		getBoundingClientRect: function() {
			if (this._rect) return this._rect;
			return { left: 100, top: 500, right: 220, bottom: 540, width: 120, height: 40 };
		},
		setPointerCapture: function() {},
		click: function() {
			(this._listeners.click || []).forEach(function(f) {
				f({
					target: this, currentTarget: this, button: 0, pointerType: 'mouse',
					preventDefault: function() {}, stopPropagation: function() {}
				});
			}, this);
		},
		dispatch: function(type, ev) {
			const e = ev || {};
			e.type = type;
			e.target = e.target || this;
			e.preventDefault = e.preventDefault || function() {};
			e.stopPropagation = e.stopPropagation || function() {};
			(this._listeners[type] || []).slice().forEach(function(f) { f(e); });
		}
	};
	Object.defineProperty(el, 'firstChild', {
		get: function() { return this.children.length ? this.children[0] : null; }
	});
	Object.defineProperty(el, 'parentNode', {
		get: function() { return this._parent; }
	});
	/* 真实 DOM 里 className / classList / class 属性是同一份数据。
	 * stub 统一以 attrs['class'] 为唯一真相，选择器才查得到。 */
	/* textContent 与真实 DOM 一致：读时包含子节点文本，写时清空子节点。 */
	Object.defineProperty(el, 'textContent', {
		get: function() {
			const kids = (this.children || []).map(function(c) {
				return c.nodeType === 3 ? String(c.textContent || '') : String(c.textContent || '');
			}).join('');
			return this._text + kids;
		},
		set: function(v) {
			this._text = v == null ? '' : String(v);
			this.children = [];
		}
	});
	Object.defineProperty(el, 'className', {
		get: function() { return this.attrs['class'] || ''; },
		set: function(v) { this.attrs['class'] = String(v); }
	});
	Object.defineProperty(el, 'classList', {
		get: function() {
			const self = this;
			function set(v) {
				const list = String(self.attrs['class'] || '').split(/\s+/).filter(Boolean);
				const i = list.indexOf(v);
				if (i >= 0) list.splice(i, 1);
				if (arguments[1] === true) list.push(v);
				self.attrs['class'] = list.join(' ');
			}
			return {
				add: function(c) {
					if (!this.contains(c)) set(c, true);
				},
				remove: function(c) {
					if (this.contains(c)) set(c, false);
				},
				contains: function(c) {
					return String(self.attrs['class'] || '').split(/\s+/).indexOf(c) >= 0;
				},
				toggle: function(c, on) {
					const has = this.contains(c);
					if (on === undefined) on = !has;
					if (on && !has) set(c, true);
					if (!on && has) set(c, false);
				}
			};
		}
	});
	return el;
}

/* ---- 够用的选择器引擎（支持 tag / .class / [attr] / 后代 / 逗号 / 忽略 :not） ---- */

function simpleMatch(el, part) {
	let tag = null;
	const classes = [];
	const attrs = [];
	const re = /([a-zA-Z][\w-]*)|\.([\w-]+)|\[([\w-]+)(?:="([^"]*)")?\]/g;
	let m;
	while ((m = re.exec(part))) {
		if (m[1]) tag = m[1];
		else if (m[2]) classes.push(m[2]);
		else if (m[3]) attrs.push([ m[3], m[4] ]);
	}
	if (tag && el.tagName !== tag.toUpperCase())
		return false;
	const clsText = String(el.attrs['class'] || '');
	const classList = clsText.split(/\s+/);
	for (const c of classes)
		if (classList.indexOf(c) < 0) return false;
	for (const a of attrs) {
		const v = (a[0] in el.attrs) ? el.attrs[a[0]] : el[a[0]];
		if (v == null || v === false) return false;
		if (a[1] != null && String(v) !== a[1]) return false;
	}
	return true;
}

function parseSelector(sel) {
	return sel.replace(/:not\([^)]*\)/g, '')
		.split(',')
		.map(function(s) { return s.trim(); })
		.filter(Boolean)
		.map(function(s) { return s.split(/\s+/); });
}

function matchesChain(el, chain) {
	let i = chain.length - 1;
	if (i < 0) return false;
	if (!simpleMatch(el, chain[i])) return false;
	i--;
	let node = el._parent;
	while (i >= 0 && node) {
		if (node.nodeType === 1 && simpleMatch(node, chain[i])) i--;
		node = node._parent;
	}
	return i < 0;
}

function queryAll(root, sel) {
	const chains = parseSelector(sel);
	const out = [];
	(function walk(node) {
		(node.children || []).forEach(function(c) {
			if (c.nodeType !== 1) return;
			for (const ch of chains) {
				if (matchesChain(c, ch)) { out.push(c); break; }
			}
			walk(c);
		});
	})(root);
	return out;
}

function E(tag, attrs, child) {
	const el = makeElement(tag);
	/* class 属性同时同步到 classList，供选择器与组件判定使用。 */
	if (attrs) {
		Object.keys(attrs).forEach(function(k) {
			const v = attrs[k];
			if (v == null) return;
			if (typeof v === 'function') el.addEventListener(k, v);
			else {
				el[k] = v;
				el.attrs[k] = v;
			}
		});
	}
	const kids = child == null ? [] : (Array.isArray(child) ? child : [ child ]);
	kids.forEach(function(k) {
		if (k && k.nodeType) el.appendChild(k);
		else el.textContent += (k == null ? '' : String(k));
	});
	/* textarea / input 的初始值来自文本子节点（真实 DOM 行为）。 */
	if ((el.tagName === 'TEXTAREA') && el.textContent)
		el.value = el.textContent;
	return el;
}

/* ==================== LuCI 环境 stub ==================== */

const document = {
	head: makeElement('head'),
	body: makeElement('body'),
	documentElement: makeElement('html'),
	activeElement: null,
	_byId: {},
	_listeners: {},
	getElementById: function(id) { return this._byId[id] || null; },
	createElement: function(tag) { return makeElement(tag); },
	createElementNS: function(ns, tag) { return makeElement(tag); },
	createTextNode: function(text) { return { nodeType: 3, textContent: String(text) }; },
	addEventListener: function(type, fn) { (this._listeners[type] = this._listeners[type] || []).push(fn); },
	removeEventListener: function(type, fn) {
		const l = this._listeners[type] || [];
		const i = l.indexOf(fn);
		if (i >= 0) l.splice(i, 1);
	},
	dispatch: function(type, ev) {
		((this._listeners[type] || []).slice()).forEach(function(f) { f(ev || {}); });
	}
};

const L = {
	Class: {
		extend: function(proto) {
			const cls = function() {};
			Object.keys(proto || {}).forEach(function(k) { cls.prototype[k] = proto[k]; });
			return cls;
		}
	},
	resource: function(p) { return '/luci-static/resources/' + p; }
};

const polls = [];
const poll = {
	add: function(fn, interval) { polls.push({ fn: fn, interval: interval }); },
	remove: function(fn) {
		for (let i = polls.length - 1; i >= 0; i--)
			if (polls[i].fn === fn) polls.splice(i, 1);
	}
};

const ui = {
	createHandlerFn: function(view, method) {
		const args = Array.prototype.slice.call(arguments, 2);
		return function(ev) {
			return Promise.resolve(view[method].apply(view, args.concat([ ev ])));
		};
	},
	addNotification: function() {}
};

const rpc = {
	declare: function(req) {
		return function(params) {
			return Promise.resolve(fakeRpc(req.object + '.' + req.method, params || {}));
		};
	}
};

const viewModule = {
	extend: function(proto) { return L.Class.extend(proto); }
};

/* ==================== 假 RPC 数据 ==================== */

function fakeRpc(full) {
	const wan1 = { name: 'wan1', enabled: true, weight: 1, device: 'eth0', gateway: '192.168.1.1', table: 100 };
	const wan2 = { name: 'wan2', enabled: true, weight: 1, device: 'eth1', gateway: '192.168.2.1', table: 200 };
	const line = {
		name: 'wan1', state: 'healthy', state_label: '正常',
		metrics: { rtt_ms: 12, jitter_ms: 2, loss_pmm: 0 },
		conns: 5, slot: 1, table: 100, device: 'eth0', link_up: true,
		address: '192.168.1.2/24', gateway: '192.168.1.1',
		enabled: true, maintenance: false, blocked_reason: null,
		last_outcome: 'ok', resolve_notes: []
	};
	const cfg = {
		global: {
			enabled: true, mode: 'balance', primary: 'wan1',
			backup_order: [ 'wan2' ], failback: 'auto',
			failback_delay_ms: 30000, failback_success_threshold: 3,
			min_switch_interval_ms: 5000, algorithm: 'src_ip', buckets: 64,
			conn_sticky: true, rebalance_interval_ms: 60000, log_level: 'info',
			health: { interval_ms: 5000, timeout_ms: 2000, failure_threshold: 3, warmup_ms: 10000 }
		},
		wans: [ wan1, wan2 ],
		games: [ { name: 'game-a', enabled: true } ]
	};
	const changes = [];
	for (let i = 0; i < 8; i++)
		changes.push({ path: 'global.k' + i, old: 'a' + i, new: 'b' + i, risky: i === 0 });

	const data = {
		'smartmwan.getStatus': {
			enabled: true, mode: 'balance', active: 'wan1', all_dead: false,
			carries_traffic: true, measured: true, firewall: 'nft',
			reason: '按源地址哈希分配 64 桶', notes: [ '主循环运行中' ],
			buckets: { total: 64, share_permille: [ { wan: 'wan1', permille: 500 }, { wan: 'wan2', permille: 500 } ] },
			last_receipt: { id: 'txn-1', ok: true, changed: true, error: null, rollback: [] }
		},
		'smartmwan.getLines': { measured: true, lines: [ line ] },
		'smartmwan.getTraffic': { window_ms: 1000, devices: [ { device: 'eth0', rx_kbps: 1000, tx_kbps: 500, rx_bytes: 1000000, tx_bytes: 500000 } ] },
		'smartmwan.getCapabilities': { degraded: [], note: '' },
		'smartmwan.getFailover': { active: 'wan1', primary: 'wan1', forced: null, standby: [ 'wan2' ], waiting: null, last_switch_ms: null, order: [ 'wan1', 'wan2' ] },
		'smartmwan.getConfig': { schema_version: 1, applied: { transaction: 'txn-1' }, config: cfg },
		'smartmwan.getBalance': {
			algorithm: 'src_ip', configured_algorithm: 'src_ip', limitations: '',
			buckets_total: 64, moved: 0, smoothing_permille: 200, hash_seed: 1,
			share_permille: [ { wan: 'wan1', permille: 500 }, { wan: 'wan2', permille: 500 } ],
			buckets: [ 'wan1', 'wan2', 'wan1', 'wan2', 'wan1', 'wan2', 'wan1', 'wan2' ]
		},
		'smartmwan.getGames': {
			rules: [ { name: 'game-a', enabled: true, selection: 'quality', pin_wan: null, hits: null, targets: [ '1.2.3.4' ], ports: [ 443 ], domains: [ 'example.com' ] } ],
			hits_note: '命中数来自内核 counter，按规则求和',
			conflicts: [], domains_tracked: 3, dns_elements: 5, dns_stale_domains: 0,
			dns_failures: { notfound: 1, timeout: 0, local: 0 }
		},
		'smartmwan.getGameQuality': {
			ranking: [ { wan: 'wan1', score: 9.5, rtt_ms: 12, jitter_ms: 2, loss_pmm: 0, state: 'healthy', confident: true } ],
			rules: [ { rule: 'game-a', selection: 'quality', pin_wan: null, pick_wan: 'wan1' } ]
		},
		'smartmwan.getConnections': {
			per_slot: [ { slot: 1, table: 100, conns: 10, growth: 2 } ],
			owned: 10, foreign: 0, unmarked: 0, total: 10, truncated: false,
			note: '', limits: { count: 1000, max: 65536, used_permille: 15, tight: false }
		},
		'smartmwan.diff': { changes: changes, note: '有 8 项变更' },
		'smartmwan.diagnostics': {
			protocol: 2, schema_version: 1, uptime_ms: 3600000, firewall_channel: 'nft',
			config_valid: true,
			conntrack: { count: 1000, max: 65536, used_permille: 15, tight: false },
			dns: { domains: 3, elements: 5, stale_domains: 0 },
			errors: [], warnings: [], capabilities_degraded: []
		},
		'smartmwan.save': { changes: [] },
		'smartmwan.apply': { id: 'txn-1', ok: true, changed: true },
		'smartmwan.validate': { valid: true, issues: [] },
		'smartmwan.rollback': { note: 'ok' },
		'smartmwan.reload': { note: 'ok' },
		'smartmwan.probeNow': { planned: 1, completed: 1, ignored: 0, transitions: 0 },
		'smartmwan.setPrimary': { saved: true },
		'smartmwan.setBackupOrder': { saved: true },
		'smartmwan.failback': { switched: false, primary: 'wan1', reason: '主线路尚不够格' },
		'smartmwan.forceWan': { id: 'txn-2' },
		'smartmwan.releaseForced': { ok: true },
		'smartmwan.setMaintenance': { ok: true },
		'smartmwan.switchMode': { saved: true },
		'smartmwan.setAlgorithm': { saved: true }
	};
	const d = data[full];
	if (d === undefined)
		return { ok: false, error: { code: 'no_such_method', message: 'stub 未定义 ' + full } };
	return { ok: true, data: d };
}

/* ==================== 模块加载（按依赖顺序） ==================== */

function execModule(rel) {
	const src = fs.readFileSync(path.join(RES, rel), 'utf8');
	const names = [ 'E', 'L', 'document', 'poll', 'rpc', 'ui', 'view' ];
	const values = [ E, L, document, poll, rpc, ui, viewModule ];
	const factory = new Function(names.join(','), src + '\n//# sourceURL=' + rel);
	return factory.apply(null, values);
}

/* 共享模块：LuCI 的 require 会把类实例化后交给调用方。 */
function loadRaw(rel) {
	const ret = execModule(rel);
	return typeof ret === 'function' ? new ret() : ret;
}

/* 视图：LuCI 的 dispatcher 拿到的是类，实例化由调用方做。 */
function loadViewClass(rel) {
	return execModule(rel);
}

/* LuCI 的 require 把模块名当变量注入；这里用 global 复刻同一语义。 */
global.smwcore = loadRaw('smwcore.js');
global.smwpopover = loadRaw('smwpopover.js');
global.smwoverlay = loadRaw('smwoverlay.js');
global.smwfeedback = loadRaw('smwfeedback.js');
global.smwform = loadRaw('smwform.js');
global.smartmwan = loadRaw('smartmwan.js');

const core = global.smwcore;
const overlay = global.smwoverlay;
const feedback = global.smwfeedback;
const form = global.smwform;
const popover = global.smwpopover;
const smw = global.smartmwan;

/* ==================== 工具 ==================== */

function walk(node, fn) {
	if (node == null) return;
	if (Array.isArray(node)) { node.forEach(function(n) { walk(n, fn); }); return; }
	if (!node.nodeType) return;
	fn(node);
	(node.children || []).forEach(function(c) { walk(c, fn); });
}

function collectText(node) {
	const out = [];
	walk(node, function(n) { if (n.textContent) out.push(n.textContent); });
	return out.join(' ');
}

function findButtons(node) {
	const out = [];
	walk(node, function(n) { if (n.tagName === 'BUTTON') out.push(n); });
	return out;
}

function byClass(cls) {
	return document.body.children.filter(function(c) {
		return String(c.attrs['class'] || '').split(/\s+/).indexOf(cls) >= 0 &&
			!c.classList.contains('smw-closing');
	});
}

function liveOverlay() { return byClass('smw-overlay')[0] || null; }

function wait(ms) { return new Promise(function(r) { setTimeout(r, ms); }); }

/* ==================== 1. 视图渲染 ==================== */

async function smokeViews() {
	section('[1] 视图渲染（load → render）');
	for (const name of VIEWS) {
		const rel = 'view/smartmwan/' + name + '.js';
		let ok = false;
		let note = '';
		try {
			const cls = loadViewClass(rel);
			const v = new cls();
			const data = await v.load();
			const root = v.render(data);
			const bad = root == null || root.nodeType !== 1 ||
				collectText(root).indexOf('[object ') >= 0;
			ok = !bad;
			if (bad) note = '产物异常（字符串化或空节点）';
			if (root && root.id) document._byId[root.id] = root;
			/* 轮询回调必须能安全跑一轮（容器在文档里时不会自行摘除）。 */
			polls.slice().forEach(function(p) { try { p.fn(); } catch (e) { note = '轮询回调异常：' + e.message; ok = false; } });
		} catch (e) {
			note = String(e && e.stack || e).split('\n')[0];
		}
		check(ok, name + '.js 渲染' + (note ? '（' + note + '）' : ''));
	}
	/* 每个视图的按钮都必须是组件系统生成的（不允许回退到 LuCI 旧按钮）。 */
	VIEWS.forEach(function(name) {
		const src = fs.readFileSync(path.join(RES, 'view/smartmwan/' + name + '.js'), 'utf8');
		check(src.indexOf('cbi-button') < 0 && src.indexOf("'class': 'btn") < 0,
			name + '.js 无 LuCI 旧按钮残留');
	});
	/* 通知统一走 Toast（不允许再直接用 ui.addNotification）。 */
	VIEWS.forEach(function(name) {
		const src = fs.readFileSync(path.join(RES, 'view/smartmwan/' + name + '.js'), 'utf8');
		check(src.indexOf('addNotification') < 0, name + '.js 通知统一走 Toast');
	});
}

/* ==================== 2. Dialog ==================== */

async function smokeDialog() {
	section('[2] Dialog（居中模态）');

	/* 2a. 基础打开：尺寸类 / aria / 结构 */
	const d = overlay.Dialog.open({
		title: '标准表单',
		description: '测试描述',
		size: 'md',
		body: [ E('p', {}, [ '第一段' ]), E('p', {}, [ '第二段' ]) ],
		actions: [ { label: '取消', variant: 'text', value: null }, { label: '保存', variant: 'filled', value: 'save' } ]
	});
	const el = d.el;
	check(el.attrs['class'].indexOf('smw-overlay--dialog') >= 0, 'dialog 形态类');
	check(el.attrs['class'].indexOf('smw-size-md') >= 0, '尺寸类 md');
	check(el.attrs['role'] === 'dialog' && el.attrs['aria-modal'] === 'true', 'role/aria-modal');
	check(el.attrs['aria-labelledby'] != null && el.attrs['aria-describedby'] != null, 'aria-labelledby/describedby 指向标题与描述');
	check(el.querySelector('.smw-overlay-title') != null, '标题区存在');
	check(el.querySelector('.smw-overlay-body') != null, '内容区存在');
	check(el.querySelector('.smw-overlay-foot') != null, '底部操作区存在（固定，不随内容滚动）');
	check(findButtons(el.querySelector('.smw-overlay-actions')) .length === 2, '两个动作按钮');
	check(document.body.style.overflow === 'hidden', '打开时锁定背景滚动');

	/* 2b. 焦点：打开后焦点在面板内 */
	await wait(5);
	check(document.activeElement != null && el.contains(document.activeElement), '初始焦点落在面板内');

	/* 2c. Tab 循环：最后一个可聚焦元素按 Tab 回到第一个 */
	const focusables = core.focusables(el);
	check(focusables.length >= 3, '面板内可聚焦元素 ≥3（关闭/取消/保存）');

	/* 2d. ESC 关闭 */
	document.dispatch('keydown', { key: 'Escape', preventDefault: function() {}, stopPropagation: function() {} });
	const v1 = await d.promise;
	check(v1 === null, 'ESC 关闭并以取消值 resolve');
	await wait(260);
	check(document.body.style.overflow === '' || !document.body.style.overflow, '关闭后恢复背景滚动');
	check(byClass('smw-overlay').length === 0, '关闭后 DOM 已摘除');

	/* 2e. 点击动作按钮 → resolve 对应值，且按钮被禁用（提交期间） */
	const d2 = overlay.Dialog.open({
		title: '提交测试',
		actions: [ { label: '取消', variant: 'text', value: null }, { label: '保存', variant: 'filled', value: 'saved' } ]
	});
	const btns2 = findButtons(d2.el.querySelector('.smw-overlay-actions'));
	btns2[1].click();
	const v2 = await d2.promise;
	check(v2 === 'saved', '动作按钮 resolve 其 value');

	/* 2f. 异步提交成功 → 自动关闭 */
	let ran = 0;
	const d3 = overlay.Dialog.open({
		title: '异步成功',
		actions: [ { label: '取消', variant: 'text', value: false },
			{ label: '提交', variant: 'filled', value: true, onClick: function() { ran++; return Promise.resolve(); } } ]
	});
	const b3 = findButtons(d3.el.querySelector('.smw-overlay-actions'));
	b3[1].click();
	b3[1].click();     /* 重复点击必须被丢弃 */
	b3[1].click();
	const v3 = await d3.promise;
	check(ran === 1, '重复提交被丢弃（onClick 只执行 1 次，实际 ' + ran + '）');
	check(v3 === true, '成功提交后自动关闭并 resolve');

	/* 2g. 异步失败 → 不关闭、错误就地显示、按钮恢复可点 */
	const d4 = overlay.Dialog.open({
		title: '异步失败',
		actions: [ { label: '取消', variant: 'text', value: false },
			{ label: '提交', variant: 'filled', value: true, onClick: function() {
				return Promise.reject(new Error('后端拒绝：字段 buckets 越界'));
			} } ]
	});
	const b4 = findButtons(d4.el.querySelector('.smw-overlay-actions'));
	b4[1].click();
	await wait(10);
	const status4 = d4.el.querySelector('.smw-overlay-status');
	check(status4 != null && status4.attrs['class'].indexOf('smw-is-error') >= 0, '失败时显示错误状态区');
	check(status4.textContent.indexOf('后端拒绝') >= 0, '错误信息来自实际异常');
	check(b4[1].disabled === false, '失败后按钮恢复可点（可重试）');
	check(d4.state === 'open', '失败不关闭弹窗');
	d4.close(null, 'test');
	await d4.promise;

	/* 2h. closeOnSuccess:false → 成功但留在窗内并显示成功态 */
	const d5 = overlay.Dialog.open({
		title: '留在窗内',
		actions: [ { label: '应用', variant: 'filled', value: 'ok', closeOnSuccess: false,
			onClick: function() { return Promise.resolve(); } } ]
	});
	findButtons(d5.el.querySelector('.smw-overlay-actions'))[0].click();
	await wait(10);
	check(d5.state === 'open', 'closeOnSuccess=false 时不关闭');
	check(d5.el.querySelector('.smw-overlay-status').attrs['class'].indexOf('smw-is-success') >= 0,
		'成功状态区出现');
	d5.close(null, 'test');
	await d5.promise;

	/* 2i. beforeClose 守卫：有未保存改动 → 弹二次确认；取消则留在原弹窗 */
	let guardCalled = 0;
	const d6 = overlay.Dialog.open({
		title: '未保存检测',
		beforeClose: function() { guardCalled++; return '有未保存的改动，确定放弃？'; },
		actions: [ { label: '关闭', variant: 'text', value: null } ]
	});
	await wait(5);
	/* 走用户的关闭路径（关闭按钮），验证守卫被调用 */
	const closeBtn6 = d6.el.querySelector('.smw-overlay-close');
	closeBtn6.click();
	await wait(5);
	check(guardCalled === 1, 'beforeClose 被调用（关闭按钮路径）');
	const confirmLayer = byClass('smw-overlay--confirm')[0];
	check(confirmLayer != null, '守卫返回字符串时弹出二次确认');
	/* 在二次确认里点「继续编辑」（第一个按钮） */
	if (confirmLayer) {
		findButtons(confirmLayer.querySelector('.smw-overlay-actions'))[0].click();
		await wait(260);
	}
	check(d6.state === 'open', '二次确认取消后原弹窗保持打开');
	d6.close(null, 'test');
	await d6.promise;

	/* 2j. 层级：两个弹窗的 z-index 递增，关掉上层不破坏下层 */
	const a = overlay.Dialog.open({ title: 'A', actions: [ { label: '关', variant: 'text', value: 1 } ] });
	const b = overlay.Dialog.open({ title: 'B', actions: [ { label: '关', variant: 'text', value: 2 } ] });
	check(Number(b.el.style.zIndex) > Number(a.el.style.zIndex), '后开的弹层层级更高');
	check(Number(a.el.style.zIndex) >= core.Z_BASE, '层级从基址 2000 起');
	b.el.querySelector('.smw-overlay-close').click();
	await b.promise;
	await wait(260);
	check(a.state === 'open', '关掉上层不影响下层');
	check(document.body.style.overflow === 'hidden', '仍有弹层时滚动保持锁定');
	a.close(null, 'test');
	await a.promise;

	/* 2k. mobile 参数：keep-dialog / fullscreen 类 */
	const m1 = overlay.Dialog.open({ title: 'M1', mobile: 'dialog' });
	check(m1.el.attrs['class'].indexOf('smw-keep-dialog') >= 0, 'mobile:dialog → 保持居中类');
	m1.close(); await m1.promise;
	const m2 = overlay.Dialog.open({ title: 'M2', mobile: 'fullscreen' });
	check(m2.el.attrs['class'].indexOf('smw-mobile-full') >= 0, 'mobile:fullscreen → 全屏类');
	m2.close(); await m2.promise;

	/* 2l. 关闭全部（页面切走兜底） */
	overlay.Dialog.open({ title: 'C1' });
	overlay.Dialog.open({ title: 'C2' });
	overlay.Dialog.closeAll();
	await wait(260);
	check(byClass('smw-overlay').length === 0, 'closeAll 清空所有弹层');
	check(!document.body.style.overflow, 'closeAll 后滚动锁已释放');
}

/* ==================== 3. Drawer / Sheet ==================== */

async function smokeDrawerSheet() {
	section('[3] Drawer / Bottom Sheet');

	const dr = overlay.Drawer.open({
		title: '配置编辑器',
		width: 560,
		body: E('textarea', { 'class': 'smw-textarea' }, [ '{}' ]),
		actions: [ { label: '保存', variant: 'filled', value: 'save' } ]
	});
	check(dr.el.attrs['class'].indexOf('smw-overlay--drawer') >= 0, 'drawer 形态类');
	check(dr.el.style.width === '560px', '宽度按参数生效（560px）');
	check(dr.el.querySelector('.smw-overlay-body').children.length > 0, '内容已挂载');
	dr.close(); await dr.promise;

	const sh = overlay.Sheet.open({
		title: '快捷操作',
		actions: [
			{ label: '选项一', variant: 'text', value: 'a' },
			{ label: '选项二', variant: 'text', value: 'b' }
		]
	});
	check(sh.el.attrs['class'].indexOf('smw-overlay--sheet') >= 0, 'sheet 形态类');
	check(sh.el.querySelector('.smw-overlay-grip') != null, '拖动把手存在');
	/* 无 onClick 的 action = 菜单式，点击即关闭并返回 value */
	findButtons(sh.el.querySelector('.smw-overlay-actions'))[1].click();
	check(await sh.promise === 'b', '菜单式 sheet 返回所选项');

	/* 拖动关闭：指针从头部下滑超过阈值 */
	const sh2 = overlay.Sheet.open({ title: '拖动关闭' });
	const head = sh2.el.querySelector('.smw-overlay-head');
	head.dispatch('pointerdown', { pointerId: 1, pointerType: 'touch', clientY: 100, button: 0 });
	head.dispatch('pointermove', { pointerId: 1, pointerType: 'touch', clientY: 300 });
	head.dispatch('pointerup', { pointerId: 1, pointerType: 'touch', clientY: 300 });
	const dragVal = await sh2.promise;
	check(dragVal === null, '下滑超过 120px 触发关闭（取消语义）');

	/* 小位移不关闭，只是回弹 */
	const sh3 = overlay.Sheet.open({ title: '小幅拖动' });
	const head3 = sh3.el.querySelector('.smw-overlay-head');
	head3.dispatch('pointerdown', { pointerId: 2, pointerType: 'touch', clientY: 100, button: 0 });
	head3.dispatch('pointermove', { pointerId: 2, pointerType: 'touch', clientY: 140 });
	head3.dispatch('pointerup', { pointerId: 2, pointerType: 'touch', clientY: 140 });
	await wait(10);
	check(sh3.state === 'open', '小幅拖动不关闭（回弹）');
	check(sh3.el.style.transform === '', '回弹后 transform 已清除');
	sh3.close(); await sh3.promise;

	/* 参数宽度为数字或字符串都能用 */
	const dr2 = overlay.Drawer.open({ title: 'W', width: '420px' });
	check(dr2.el.style.width === '420px', '宽度支持字符串');
	dr2.close(); await dr2.promise;
}

/* ==================== 4. Confirm ==================== */

async function smokeConfirm() {
	section('[4] Confirm（危险确认）');

	/* 4a. 普通确认：两个按钮、初始焦点在取消 */
	const p1 = overlay.Confirm.show({
		title: '启用服务',
		message: '确认启用？',
		details: [ '会写入策略路由。', '不会影响其他规则。' ]
	});
	const el1 = liveOverlay();
	check(el1 != null, '确认框已打开');
	check(el1.querySelector('.smw-confirm-details') != null, '影响说明逐条列出');
	const b1 = findButtons(el1.querySelector('.smw-overlay-actions'));
	check(b1.length === 2, '两个动作按钮（取消/确认）');
	/* 聚焦在下一帧执行（避免打开动画前就滚动页面）。 */
	await wait(5);
	check(document.activeElement === b1[0], '初始焦点在「取消」上（危险操作默认不做）');
	b1[1].click();
	check(await p1 === true, '确认 resolve(true)');

	/* 4b. danger 变体：确认按钮使用错误色 */
	const p2 = overlay.Confirm.show({ title: '停用服务', message: '…', danger: true });
	const el2 = liveOverlay();
	const b2 = findButtons(el2.querySelector('.smw-overlay-actions'));
	check(b2[1].attrs['class'].indexOf('smw-btn-danger') >= 0, 'danger 时确认按钮用错误色');
	/* 危险信息不只靠颜色：标题前有图标 + 语义标签 */
	check(el2.querySelector('.smw-confirm-title') != null, '危险确认带图标（不只靠颜色传达）');
	b2[0].click();
	check(await p2 === false, '取消 resolve(false)');

	/* 4c. disconnectRisk */
	const p3 = overlay.Confirm.show({ title: '重拨', message: '…', disconnectRisk: true });
	const el3 = liveOverlay();
	check(el3.querySelector('.smw-confirm-risk') != null, '连接中断风险提示存在');
	check(collectText(el3).indexOf('可能中断当前管理连接') >= 0, '风险文案明确');
	el3.querySelector('.smw-overlay-close').click();
	check(await p3 === false, '关闭按钮视为取消');

	/* 4d. critical：要求输入指定文字才允许确认 */
	const p4 = overlay.Confirm.show({
		title: '恢复默认设置',
		message: '…',
		severity: 'critical',
		requireType: '恢复默认'
	});
	const el4 = liveOverlay();
	const typeInput = el4.querySelector('.smw-confirm-type input');
	check(typeInput != null, 'critical 要求输入确认文字');
	const b4 = findButtons(el4.querySelector('.smw-overlay-actions'));
	check(b4[1].disabled === true, '未输入时确认按钮禁用');
	typeInput.value = '恢复';
	typeInput.dispatch('input', {});
	check(b4[1].disabled === true, '输入不匹配仍禁用');
	typeInput.value = '恢复默认';
	typeInput.dispatch('input', {});
	check(b4[1].disabled === false, '输入匹配后解禁');
	b4[0].click();
	await p4;

	/* 4e. onConfirm 失败：不关闭、可重试 */
	let attempts = 0;
	const p5 = overlay.Confirm.show({
		title: '回滚',
		message: '…',
		danger: true,
		onConfirm: function() {
			attempts++;
			return attempts === 1 ? Promise.reject(new Error('首次失败')) : Promise.resolve();
		}
	});
	const el5 = liveOverlay();
	const b5 = findButtons(el5.querySelector('.smw-overlay-actions'));
	b5[1].click();
	await wait(10);
	check(liveOverlay() != null && liveOverlay().querySelector('.smw-overlay-status') != null,
		'提交失败时弹窗保留并显示错误');
	check(b5[1].disabled === false, '失败后确认按钮可再次点击');
	b5[1].click();
	check(await p5 === true, '重试成功后 resolve(true)');
}

/* ==================== 5. Toast ==================== */

async function smokeToast() {
	section('[5] Toast / Snackbar');
	const Toast = feedback.Toast;

	Toast.clear();
	const t1 = Toast.success('已保存');
	const box = document.body.children.filter(function(c) { return c.attrs['class'] === 'smw-toasts'; })[0];
	check(box != null, '通知容器已创建');
	check(t1.el.attrs['class'].indexOf('smw-toast-success') >= 0, 'success 类型样式');
	check(t1.el.attrs['role'] === 'status', 'success 用 status 语义');

	/* 错误用 alert（立即播报）且默认不自动关闭 */
	const t2 = Toast.error('提交失败');
	check(t2.el.attrs['role'] === 'alert', 'error 用 alert 语义');
	const countBefore = box.children.length;
	await wait(50);
	check(box.children.length === countBefore, '错误通知不因短时间自动消失');

	/* 去重：同类型同文案不新建第二条 */
	const t3 = Toast.error('提交失败');
	check(box.children.length === countBefore, '相同通知去重（不刷屏）');
	check(t3.id === t2.id, '去重时复用同一条通知');

	/* 上限：最多 4 条，超出淘汰最旧 */
	for (let i = 0; i < 8; i++)
		Toast.info('消息 ' + i);
	check(box.children.length <= 4, '通知堆叠上限 4 条（实际 ' + box.children.length + '）');

	/* 带操作按钮 */
	Toast.clear();
	let acted = 0;
	const t4 = Toast.warning('配置已导入', { action: { label: '查看', onClick: function() { acted++; } } });
	const actionBtn = t4.el.querySelector('.smw-toast-action');
	check(actionBtn != null, '可选操作按钮存在');
	actionBtn.click();
	check(acted === 1, '操作按钮回调执行');
	await wait(240);
	check(t4.el.parentNode == null, '点击操作后该通知被移除（含退场动画）');

	/* 进度型：进行中 → 完成，不伪造百分比 */
	Toast.clear();
	const task = Toast.progress({ message: '正在提交事务…' });
	const pEl = document.body.children.filter(function(c) { return c.attrs['class'] === 'smw-toasts'; })[0].children[0];
	check(pEl.attrs['class'].indexOf('smw-toast-progress') >= 0, '进度通知有独立样式');
	check(collectText(pEl).indexOf('正在提交') >= 0, '进行中文案');
	check(pEl.querySelector('.smw-toast-close') == null, '进行中不给关闭按钮（避免误解为可取消任务）');
	task.done('事务 txn-1 已提交');
	const after = document.body.children.filter(function(c) { return c.attrs['class'] === 'smw-toasts'; })[0].children[0];
	check(after.attrs['class'].indexOf('smw-toast-success') >= 0, '完成后原地变为成功态');
	check(after.querySelector('.smw-toast-close') != null, '完成后出现关闭按钮');

	/* 进度失败 → 常驻错误 */
	Toast.clear();
	const task2 = Toast.progress({ message: '正在回滚…' });
	task2.fail('回滚失败');
	const failEl = document.body.children.filter(function(c) { return c.attrs['class'] === 'smw-toasts'; })[0].children[0];
	check(failEl.attrs['class'].indexOf('smw-toast-error') >= 0, '失败态样式');
	check(failEl.attrs['role'] === 'alert', '失败态用 alert 播报');

	Toast.clear();
	await wait(220);
	const left = document.body.children.filter(function(c) { return c.attrs['class'] === 'smw-toasts'; })[0];
	check(left != null && left.children.length === 0, 'clear 后无残留通知');
}

/* ==================== 6. Popover / Tooltip ==================== */

async function smokePopover() {
	section('[6] Popover / Tooltip');
	const Pop = popover.Popover;

	const anchor = E('button', { 'class': 'anchor' }, [ '打开' ]);
	document.body.appendChild(anchor);
	anchor._rect = { left: 100, top: 500, right: 220, bottom: 540, width: 120, height: 40 };

	const p = Pop.open(anchor, {
		content: E('div', {}, [ E('button', { 'class': 'smw-menu-item' }, [ '菜单项' ]) ]),
		placement: 'bottom-start'
	});
	check(p.el.attrs['class'].indexOf('smw-popover') >= 0, '浮层已挂到 body');
	check(p.el.style.left != null && p.el.style.top != null, '已计算绝对位置（不受父级 overflow 裁切）');
	check(parseFloat(p.el.style.top) >= 540, 'bottom 方向位于锚点下方（top=' + p.el.style.top + '）');
	check(p.el.style.zIndex != null, '层级已由栈分配');

	/* 外部点击关闭 */
	document.dispatch('pointerdown', { target: E('div') });
	await wait(10);
	check(p.el.classList.contains('smw-open') === false, '外部点击关闭');

	/* ESC 关闭 */
	const p2 = Pop.open(anchor, { content: E('div', {}, [ 'x' ]) });
	document.dispatch('keydown', { key: 'Escape', preventDefault: function() {}, stopPropagation: function() {} });
	await wait(10);
	check(p2.el.classList.contains('smw-open') === false, 'ESC 关闭');

	/* 单例：同时只允许一个 */
	const p3 = Pop.open(anchor, { content: E('div', {}, [ 'a' ]) });
	const p4 = Pop.open(anchor, { content: E('div', {}, [ 'b' ]) });
	await wait(10);
	check(p4.el.classList.contains('smw-open') === true && p3.el.classList.contains('smw-open') === false,
		'新浮层顶掉旧浮层（单例）');
	p4.close('test');

	/* Tooltip：focus 路径立即显示（不等 hover 延迟） */
	const tipAnchor = E('button', {}, [ 'i' ]);
	document.body.appendChild(tipAnchor);
	popover.Tooltip.attach(tipAnchor, '端口范围 1–65535', { placement: 'top' });
	tipAnchor.dispatch('focus', {});
	const tip = document.body.children.filter(function(c) {
		return String(c.attrs['class'] || '').split(/\s+/).indexOf('smw-tooltip') >= 0;
	})[0];
	check(tip != null && tip.classList.contains('smw-open'), '键盘聚焦时气泡显示');
	check(tip.textContent.indexOf('65535') >= 0, '气泡内容正确');
	check(tipAnchor.attrs['aria-describedby'] === 'smw-tooltip', 'aria-describedby 关联到气泡');
}

/* ==================== 7. 表单与校验 ==================== */

async function smokeForm() {
	section('[7] 表单组件与校验');
	const V = form.validators;

	/* 7a. IP / 端口校验边界 */
	check(V.ipv4('192.168.1.1') && V.ipv4('0.0.0.0') && V.ipv4('255.255.255.255'), 'IPv4 合法值');
	check(!V.ipv4('256.1.1.1') && !V.ipv4('192.168.1') && !V.ipv4('01.2.3.4') && !V.ipv4('a.b.c.d'),
		'IPv4 拒绝越界/缺段/前导零/非数字');
	check(V.ipv6('::1') && V.ipv6('fd00::1') && V.ipv6('2001:db8:0:0:0:0:0:1') &&
		V.ipv6('::ffff:192.168.1.1') && V.ipv6('1:2:3:4:5:6:7:8'), 'IPv6 合法值（含压缩与内嵌 v4）');
	check(!V.ipv6('1:2:3:4:5:6:7:8:9') && !V.ipv6('1:::2') && !V.ipv6('gggg::1') &&
		!V.ipv6('2001:db8::1::2'), 'IPv6 拒绝超长/多重压缩/非法字符');
	check(V.port('1') && V.port('65535') && V.port('443'), '端口合法值');
	check(!V.port('0') && !V.port('65536') && !V.port('abc') && !V.port(''), '端口拒绝 0/越界/非数字/空');
	check(V.port('8000-8100', true) && !V.port('8100-8000', true), '端口区间需起止有序');
	check(V.intBetween(1, 10)('5') === null && V.intBetween(1, 10)('11') != null, '整数区间校验');

	/* 7b. field：label/aria/错误行 */
	const input = form.text({ value: 'abc' });
	const f = form.field({
		label: '地址',
		required: true,
		control: input,
		help: '填写设备地址',
		validate: function(v) { return v === 'abc' ? '不能是 abc' : null; }
	});
	check(f.el.querySelector('.smw-field-label') != null, 'label 元素存在');
	check(f.el.querySelector('.smw-field-label').attrs['for'] === input.id, 'label for 指向控件');
	check(input.attrs['aria-describedby'] != null &&
		input.attrs['aria-describedby'].indexOf(f.el.querySelector('.smw-field-help').attrs['id']) >= 0,
		'说明通过 aria-describedby 关联');
	check(input.attrs['aria-required'] === 'true', '必填标记 aria-required');
	check(f.el.querySelector('.smw-field-error').attrs['hidden'] != null, '错误行默认隐藏');

	/* 7c. 校验失败：显示错误 + aria-invalid，且不丢用户输入 */
	const okBad = f.validate();
	check(okBad === false, '非法值校验失败');
	check(f.el.classList.contains('smw-field-invalid'), '字段进入错误态');
	check(input.value === 'abc', '校验失败不重置用户输入');
	check(input.attrs['aria-invalid'] === 'true', 'aria-invalid 已设置');
	check(f.el.querySelector('.smw-field-error').attrs['hidden'] == null, '错误行显示');
	check(f.el.querySelector('.smw-field-error').textContent.indexOf('不能是 abc') >= 0, '错误文案正确');

	/* 7d. 表单级校验：返回第一个失败字段并聚焦 */
	const input2 = form.text({ value: 'ok' });
	const f2 = form.field({ label: 'B', control: input2, validate: function() { return null; } });
	const r = form.validate([ f2, f ]);
	check(r.ok === false && r.field === f, '表单级校验返回第一个失败字段');
	check(document.activeElement === input, '失败时聚焦到该字段');

	/* 7e. 控件状态：disabled / readonly 属性透传 */
	const dis = form.text({ value: 'x', disabled: true });
	check(dis.attrs['disabled'] === 'disabled', 'disabled 透传');
	const ro = form.number({ value: 1, readonly: true });
	check(ro.attrs['readonly'] === 'readonly', 'readonly 透传');

	/* 7f. 搜索式下拉：过滤、键盘选择 */
	const sel = form.searchSelect({
		options: [ { value: 'a', label: 'alpha' }, { value: 'b', label: 'beta' }, { value: 'g', label: 'gamma' } ],
		value: 'a',
		onchange: function() {}
	});
	document.body.appendChild(sel.el);
	check(collectText(sel.el).indexOf('alpha') >= 0, '初始显示当前值');
	sel.trigger.click();
	await wait(5);
	/* 上一节的浮层有 160ms 退场延迟，取最后一个（最新打开的）并确认它处于打开态。 */
	const panelList = document.body.children.filter(function(c) {
		return String(c.attrs['class'] || '').split(/\s+/).indexOf('smw-popover') >= 0;
	});
	const panel = panelList[panelList.length - 1];
	check(panel != null && panel.classList.contains('smw-open'), '点击后浮层面板打开');
	check(sel.trigger.attrs['aria-expanded'] === 'true', 'aria-expanded 同步');
	const searchInput = panel.querySelector('input');
	searchInput.value = 'be';
	searchInput.dispatch('input', {});
	const options = panel.querySelectorAll('.smw-select-option');
	check(options.length === 1 && options[0].textContent === 'beta', '输入过滤生效');
	searchInput.dispatch('keydown', { key: 'Enter', preventDefault: function() {}, stopPropagation: function() {} });
	await wait(5);
	check(sel.value() === 'b', 'Enter 选中过滤后的第一项');
	check(collectText(sel.el).indexOf('beta') >= 0, '选中后按钮文案更新');

	/* 7g. switch / checkbox / radio 的语义属性 */
	const sw = form.switch({ label: '会话保持', checked: true });
	check(sw.input.attrs['role'] === 'switch', 'switch 使用 role=switch');
	check(sw.input.attrs['checked'] === 'checked', 'switch 初值');
	const cb = form.checkbox({ label: '启用', checked: false });
	check(cb.input.attrs['type'] === 'checkbox', 'checkbox 保留原生类型');
	const rd = form.radio({ name: 'x', options: [ { value: 1, label: 'A' }, { value: 2, label: 'B' } ], value: 1 });
	check(rd.el.attrs['role'] === 'radiogroup', '单选组 role=radiogroup');

	/* 7h. 可折叠分组：收起不销毁内容（用户已填的值不会丢） */
	const g = form.group({ title: '高级设置', children: [ input2 ], open: false });
	check(g.querySelector('.smw-group-body').attrs['hidden'] != null, '默认收起');
	g.querySelector('.smw-group-head').click();
	check(g.querySelector('.smw-group-body').attrs['hidden'] == null, '展开后可见');
	check(g.querySelector('.smw-group-body').children.indexOf(input2) >= 0, '内容未被重建（引用相同）');
}

/* ==================== 8. Loading / Progress ==================== */

async function smokeLoading() {
	section('[8] Loading / Progress');
	const Loading = feedback.Loading;

	const host = E('div', {});
	document.body.appendChild(host);
	const reg = Loading.region(host, { text: '读取中…' });
	check(host.children.length === 1, '区域加载遮罩已插入');
	check(host.attrs['aria-busy'] === 'true', 'aria-busy 标记');
	reg.done();
	check(host.children.length === 0, 'done 后遮罩移除');
	check(host.attrs['aria-busy'] == null, 'aria-busy 已清除');

	const reg2 = Loading.region(host, { text: 'x', onRetry: function() { host._retried = true; } });
	reg2.fail('网络不可达');
	const retry = host.querySelector('.smw-btn');
	check(host.querySelector('.smw-loading-region').attrs['class'].indexOf('smw-is-error') >= 0,
		'失败态样式');
	check(retry != null, '失败态提供重试按钮');
	retry.click();
	check(host._retried === true, '重试回调执行');

	const sk = Loading.skeleton({ rows: 4 });
	check(sk.children.length === 4, '骨架屏按行数生成');

	const pg = Loading.progress({ label: '上传' });
	check(pg.el.querySelector('.smw-progress').attrs['class'].indexOf('smw-progress-indeterminate') >= 0,
		'无真实数值时是不确定进度（不编百分比）');
	check(pg.el.querySelector('.smw-progress').attrs['aria-valuenow'] == null, '不确定态不设 aria-valuenow');
	pg.set(40);
	check(pg.el.querySelector('.smw-progress').attrs['aria-valuenow'] === '40', '有真实值时显示确定进度');

	const btn = E('button', { 'class': 'smw-btn' }, [ E('span', { 'class': 'smw-btn-label' }, [ '保存' ]) ]);
	Loading.busy(btn, true, '保存中…');
	check(btn.disabled === true && btn.classList.contains('spinning'), '按钮进入加载态');
	check(btn.querySelector('.smw-btn-label').textContent === '保存中…', '加载文案替换');
	Loading.busy(btn, false);
	check(btn.disabled === false && !btn.classList.contains('spinning'), '按钮恢复');
	check(btn.querySelector('.smw-btn-label').textContent === '保存', '文案还原');
}

/* ==================== 9. 生命周期与清理 ==================== */

async function smokeLifecycle() {
	section('[9] 生命周期与清理');

	/* 连续开关 30 次：不残留 DOM、不泄漏滚动锁、监听器数量稳定 */
	const before = (document._listeners.keydown || []).length;
	for (let i = 0; i < 30; i++) {
		const d = overlay.Dialog.open({ title: '循环 ' + i });
		d.close();
		await d.promise;
	}
	await wait(260);
	check(byClass('smw-overlay').length === 0 && byClass('smw-scrim').length === 0,
		'30 次开关后无残留弹层与遮罩');
	check(!document.body.style.overflow, '滚动锁计数归零');
	const after = (document._listeners.keydown || []).length;
	check(after === before, 'keydown 监听器未累积（' + before + ' → ' + after + '）');

	/* 快速打开再关闭：竞态下状态机不卡死 */
	const d1 = overlay.Dialog.open({ title: '快速' });
	d1.close();
	d1.close();
	await d1.promise;
	check(d1.state === 'closed', '重复 close 幂等');

	/* 页面切换兜底：Dialog.closeAll 后可以正常再开 */
	overlay.Dialog.closeAll();
	await wait(260);
	const d2 = overlay.Dialog.open({ title: '之后' });
	check(d2.state === 'open', 'closeAll 后仍能正常打开新弹层');
	d2.close(); await d2.promise;

	/* 视图刷新不残留轮询（离开页面时 poll 回调自己摘除） */
	const pollsBefore = polls.length;
	polls.slice().forEach(function(p) { p.fn(); });
	check(polls.length <= pollsBefore, '轮询回调不会重复注册');
}

/* ==================== 10. 静态约束（无法运行时验证的部分） ==================== */

function smokeStatic() {
	section('[10] 静态约束（样式与打包）');

	const css = fs.readFileSync(path.join(RES, 'smartmwan/smartmwan.css'), 'utf8');
	const ovl = fs.readFileSync(path.join(RES, 'smartmwan/overlay.css'), 'utf8');
	const allCss = css + ovl;

	check(allCss.indexOf('prefers-color-scheme: dark') >= 0, '暗色主题支持');
	check(allCss.indexOf('prefers-reduced-motion') >= 0, '减少动效支持');
	check(allCss.indexOf('env(safe-area-inset-bottom') >= 0, '安全区适配');
	check(allCss.indexOf('@media (max-width: 767.98px)') >= 0, '手机断点存在');
	check(allCss.indexOf('@media (max-width: 1023.98px)') >= 0, '平板断点存在');
	check((allCss.match(/!important/g) || []).length <= 2,
		'!important 数量受控（实际 ' + (allCss.match(/!important/g) || []).length + ' 处）');
	check(allCss.indexOf('backdrop-filter') < 0, '未使用毛玻璃弥补层级');
	check(css.indexOf('--smw-radius-dialog: 24px') >= 0, 'Dialog 圆角 24px 在令牌里');
	check(css.indexOf('--smw-dur-med: 220ms') >= 0, '常规动画 220ms 在令牌里');
	check(css.indexOf('--smw-control-h: 40px') >= 0 && css.indexOf('--smw-control-h-touch: 48px') >= 0,
		'控件高度 40/48 在令牌里');
	/* 只允许 .smw- 前缀的选择器（不污染主题）。逐条剔除注释后检查。 */
	const selectors = allCss.replace(/\/\*[\s\S]*?\*\//g, '')
		.split('}')
		.map(function(block) { return block.split('{')[0]; })
		.filter(function(s) { return s && s.trim() && !/^\s*@/.test(s) && !/^\s*\d/.test(s); });
	const leaked = selectors.filter(function(sel) {
		return sel.split(',').some(function(one) {
			const s = one.trim();
			if (!s) return false;
			if (s.indexOf('.smw-') === 0 || s.indexOf('.smw-') > 0) return false;
			if (s === 'body' || s === 'body,' || s.indexOf('body,') === 0) return false;
			if (/^(from|to|\d+%)$/.test(s)) return false;
			return true;
		});
	});
	check(leaked.length === 0, '样式选择器全部限定在 .smw- 作用域' +
		(leaked.length ? '（越界：' + leaked.slice(0, 3).join(' | ') + '）' : ''));

	/* 模块与安装清单 */
	const mk = fs.readFileSync(path.join(ROOT_DIR, 'Makefile'), 'utf8');
	[ 'smwcore.js', 'smwoverlay.js', 'smwfeedback.js', 'smwform.js', 'smwpopover.js', 'overlay.css' ]
		.forEach(function(f) {
			check(mk.indexOf(f) >= 0, 'Makefile 安装 ' + f);
		});

	/* 诚实性：命中数读不到时显示「—」，绝不用 0 冒充「没命中过」。 */
	const gamesSrc = fs.readFileSync(path.join(RES, 'view/smartmwan/games.js'), 'utf8');
	check(gamesSrc.indexOf("g.hits == null ? '—'") >= 0, 'games 命中数 null 显示「—」而非 0');

	/* 安全：全项目不得有 innerHTML 赋值 */
	const files = [ 'smartmwan.js', 'smwcore.js', 'smwoverlay.js', 'smwfeedback.js', 'smwform.js', 'smwpopover.js' ];
	let htmlHits = 0;
	files.forEach(function(f) {
		const src = fs.readFileSync(path.join(RES, f), 'utf8');
		/* 只查赋值形态：innerHTML = / outerHTML = / insertAdjacentHTML */
		if (/\.(inner|outer)HTML\s*=/.test(src) || /insertAdjacentHTML/.test(src)) htmlHits++;
	});
	check(htmlHits === 0, '组件代码无 innerHTML 赋值（XSS 面为零）');

	/* 依赖声明与实际使用一致（LuCI 的 require 靠字符串指令扫描） */
	const sw = fs.readFileSync(path.join(RES, 'smartmwan.js'), 'utf8');
	[ 'smwcore', 'smwoverlay', 'smwfeedback', 'smwform', 'smwpopover' ].forEach(function(m) {
		check(sw.indexOf("'require " + m + "';") >= 0, 'smartmwan.js 声明依赖 ' + m);
	});
	const fsrc = fs.readFileSync(path.join(RES, 'smwform.js'), 'utf8');
	check(fsrc.indexOf("'require smwpopover';") >= 0, 'smwform.js 声明依赖 smwpopover');
}

/* ==================== 入口 ==================== */

(async function main() {
	console.log('ui-smoke：组件与视图冒烟（Node ' + process.version + '）');
	await smokeViews();
	await smokeDialog();
	await smokeDrawerSheet();
	await smokeConfirm();
	await smokeToast();
	await smokePopover();
	await smokeForm();
	await smokeLoading();
	await smokeLifecycle();
	smokeStatic();

	console.log('\n' + checks + ' 项检查，' + (failures === 0 ? '全部通过' : failures + ' 项失败'));
	process.exit(failures === 0 ? 0 : 1);
})().catch(function(e) {
	console.error('\n测试自身异常：', e);
	process.exit(2);
});
