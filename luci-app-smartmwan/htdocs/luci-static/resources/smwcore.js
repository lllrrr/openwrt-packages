'use strict';
/*
 * smwcore —— 组件系统的公共地基（零 Lua，无第三方依赖）
 *
 * 职责只有「多个组件都要、且必须只有一份」的底层能力：
 *   * layer     —— 弹层层级栈：z-index 统一分配，嵌套弹窗按打开顺序叠放；
 *   * scroll    —— 页面滚动锁：引用计数 + 滚动条宽度补偿（避免开弹窗时页面横跳）；
 *   * focus     —— 焦点陷阱与恢复：模态内 Tab 循环，关闭后焦点回到触发元素；
 *   * place     —— 锚定定位：贴边翻转 + 视口夹取，供 Popover / Tooltip 共用；
 *   * icon      —— 统一 SVG 图标表（不用 Emoji 做功能图标）；
 *   * viewport  —— 断点判断（768 / 1024），以及视口变化订阅；
 *   * css       —— 幂等样式注入（按 id 判重）。
 *
 * 一条纪律：本文件不创建任何业务 DOM，也不认识 smartmwan 的业务概念。
 * 需要业务语义的组件（Dialog/Toast/Form）放在各自的模块里。
 */

var Z_BASE = 2000;      /* LuCI 主题自带的 modal 约 1100，这里从 2000 起，留足间隔 */
var Z_STEP = 10;

/* ---------------- 层级栈 ---------------- */

var layers = [];        /* [{ el, z }]，按打开顺序 */
var scrollLockCount = 0;
var scrollSaved = null;

function pushLayer(el) {
	var z = Z_BASE + layers.length * Z_STEP;
	layers.push({ el: el, z: z });
	el.style.zIndex = String(z);
	return z;
}

function popLayer(el) {
	var i = -1;
	for (var k = 0; k < layers.length; k++)
		if (layers[k].el === el) { i = k; break; }
	if (i < 0)
		return;
	layers.splice(i, 1);
	/* 重排剩余层的 z-index：中间层关掉后不留空洞，否则再开新层可能压不住旧层。 */
	for (var j = 0; j < layers.length; j++)
		layers[j].el.style.zIndex = String(Z_BASE + j * Z_STEP);
}

function topLayer() {
	return layers.length ? layers[layers.length - 1].el : null;
}

/* ---------------- 滚动锁 ---------------- */

function lockScroll() {
	scrollLockCount++;
	if (scrollLockCount > 1)
		return;

	var body = document.body;
	scrollSaved = {
		overflow: body.style.overflow,
		paddingRight: body.style.paddingRight
	};
	var gap = window.innerWidth - document.documentElement.clientWidth;
	body.style.overflow = 'hidden';
	/* 桌面端滚动条消失会让内容横向撑开 15px 左右，用 padding 补回来。 */
	if (gap > 0)
		body.style.paddingRight = gap + 'px';
}

function unlockScroll() {
	if (scrollLockCount === 0)
		return;
	scrollLockCount--;
	if (scrollLockCount > 0)
		return;

	var body = document.body;
	body.style.overflow = scrollSaved ? scrollSaved.overflow : '';
	body.style.paddingRight = scrollSaved ? scrollSaved.paddingRight : '';
	scrollSaved = null;
}

/* ---------------- 焦点 ---------------- */

var FOCUSABLE = 'a[href],button:not([disabled]),input:not([disabled]),select:not([disabled]),' +
	'textarea:not([disabled]),[tabindex]:not([tabindex="-1"])';

function focusables(root) {
	if (root == null || root.querySelectorAll == null)
		return [];
	var list = root.querySelectorAll(FOCUSABLE);
	var out = [];
	for (var i = 0; i < list.length; i++) {
		var el = list[i];
		/* 隐藏元素不可聚焦：offsetParent 为空且不是 fixed 定位时跳过。 */
		if (el.offsetParent === null && el.getClientRects && el.getClientRects().length === 0)
			continue;
		out.push(el);
	}
	return out;
}

/**
 * 在 root 内建立焦点陷阱。
 * 返回 release()：解除监听并把焦点还给打开前的元素。
 * initial 为空时聚焦第一个可聚焦元素；root 自身带 tabindex=-1 时作为兜底。
 */
function trapFocus(root, initial) {
	var previous = document.activeElement;

	function onKey(ev) {
		if (ev.key !== 'Tab')
			return;
		var list = focusables(root);
		if (list.length === 0) {
			ev.preventDefault();
			root.focus();
			return;
		}
		var first = list[0];
		var last = list[list.length - 1];
		var active = document.activeElement;
		if (!ev.shiftKey && (active === last || !root.contains(active))) {
			ev.preventDefault();
			first.focus();
		} else if (ev.shiftKey && (active === first || !root.contains(active))) {
			ev.preventDefault();
			last.focus();
		}
	}

	document.addEventListener('keydown', onKey, true);

	var target = initial || focusables(root)[0] || root;
	/* 同步聚焦会让「打开动画还没开始」就滚动页面到元素处，放在下一帧更稳。 */
	window.setTimeout(function() {
		try { target.focus({ preventScroll: true }); } catch (e) { target.focus(); }
	}, 0);

	return function release() {
		document.removeEventListener('keydown', onKey, true);
		if (previous != null && previous.focus != null) {
			try { previous.focus({ preventScroll: true }); } catch (e) { previous.focus(); }
		}
	};
}

/* ---------------- 定位（Popover / Tooltip 共用） ---------------- */

/**
 * 把一个浮层放到锚点旁边。
 * opts: { placement: 'top'|'bottom'|'left'|'right' 加可选 -start/-end,
 *         offset: 8, padding: 8 }
 * 返回实际生效的 placement（可能因翻转与贴合而改变）。
 *
 * 浮层必须已挂到 document 上（需要真实尺寸才能测量）。
 */
function place(anchorEl, floatEl, opts) {
	opts = opts || {};
	var offset = opts.offset == null ? 8 : opts.offset;
	var pad = opts.padding == null ? 8 : opts.padding;
	var want = opts.placement || 'bottom-start';

	var vw = window.innerWidth;
	var vh = window.innerHeight;
	var a = anchorEl.getBoundingClientRect();
	var fw = floatEl.offsetWidth;
	var fh = floatEl.offsetHeight;

	var base = want.split('-')[0];
	var align = want.split('-')[1] || 'center';
	var actual = base;

	function coords(side) {
		var x, y;
		if (side === 'bottom' || side === 'top') {
			y = side === 'bottom' ? a.bottom + offset : a.top - offset - fh;
			if (align === 'start') x = a.left;
			else if (align === 'end') x = a.right - fw;
			else x = a.left + (a.width - fw) / 2;
		} else {
			x = side === 'right' ? a.right + offset : a.left - offset - fw;
			if (align === 'start') y = a.top;
			else if (align === 'end') y = a.bottom - fh;
			else y = a.top + (a.height - fh) / 2;
		}
		return { x: x, y: y };
	}

	var fit = function(side) {
		var c = coords(side);
		return c.x >= pad && c.y >= pad && c.x + fw <= vw - pad && c.y + fh <= vh - pad;
	};

	/* 首选方向放不下就翻到相反方向；都不行就挑溢出更少的一侧。 */
	if (!fit(base)) {
		var opposite = { top: 'bottom', bottom: 'top', left: 'right', right: 'left' }[base];
		if (fit(opposite))
			actual = opposite;
		else {
			var overflow = function(side) {
				var c = coords(side);
				return Math.max(0, pad - c.x) + Math.max(0, pad - c.y) +
					Math.max(0, c.x + fw - (vw - pad)) + Math.max(0, c.y + fh - (vh - pad));
			};
			actual = overflow(base) <= overflow(opposite) ? base : opposite;
		}
	}

	var pos = coords(actual);
	/* 夹取到视口内：宁可贴边，也不要被裁掉一半。 */
	pos.x = Math.max(pad, Math.min(pos.x, vw - fw - pad));
	pos.y = Math.max(pad, Math.min(pos.y, vh - fh - pad));

	floatEl.style.left = Math.round(pos.x) + 'px';
	floatEl.style.top = Math.round(pos.y) + 'px';
	floatEl.setAttribute('data-placement', actual + (align !== 'center' ? '-' + align : ''));
	return actual;
}

/* ---------------- 图标 ---------------- */

/* 统一 24x24 viewBox、stroke 绘制、currentColor 取色。
 * 只收「功能图标」；语义靠文字，不靠图标单独表意。 */
var ICONS = {
	close: 'M6 6l12 12M18 6L6 18',
	check: 'M5 12.5l4.5 4.5L19 7',
	error: 'M12 3a9 9 0 100 18 9 9 0 000-18zM12 8v5M12 16.5v.5',
	warn: 'M12 3.5L21 19H3l9-15.5zM12 9v4.5M12 16.5v.5',
	info: 'M12 3a9 9 0 100 18 9 9 0 000-18zM12 11v5.5M12 7.6v.5',
	search: 'M10.5 4a6.5 6.5 0 104.1 11.5L20 21M10.5 4a6.5 6.5 0 010 13',
	chevron: 'M7 10l5 5 5-5',
	eye: 'M2.5 12S6 5.5 12 5.5 21.5 12 21.5 12 18 18.5 12 18.5 2.5 12 2.5 12zM12 9a3 3 0 100 6 3 3 0 000-6z',
	eyeoff: 'M4 4l16 16M9.9 5.9A9.6 9.6 0 0112 5.5c6 0 9.5 6.5 9.5 6.5a17 17 0 01-3 3.7M6.2 8.4A17 17 0 002.5 12S6 18.5 12 18.5c1 0 1.9-.2 2.7-.5',
	refresh: 'M20 12a8 8 0 11-2.3-5.6M20 4v4h-4',
	plus: 'M12 5v14M5 12h14',
	trash: 'M4 7h16M9 7V4.5h6V7M6.5 7l1 13h9l1-13'
};

/**
 * 生成 SVG 图标节点。
 * size 为 CSS 像素（默认 20）；title 存在时加 <title> 供读屏（否则视为装饰性）。
 */
function icon(name, size, title) {
	var d = ICONS[name];
	var ns = 'http://www.w3.org/2000/svg';
	var svg = document.createElementNS(ns, 'svg');
	svg.setAttribute('viewBox', '0 0 24 24');
	svg.setAttribute('width', String(size || 20));
	svg.setAttribute('height', String(size || 20));
	svg.setAttribute('fill', 'none');
	svg.setAttribute('stroke', 'currentColor');
	svg.setAttribute('stroke-width', '1.8');
	svg.setAttribute('stroke-linecap', 'round');
	svg.setAttribute('stroke-linejoin', 'round');
	svg.setAttribute('class', 'smw-icon');
	if (title) {
		svg.setAttribute('role', 'img');
		var t = document.createElementNS(ns, 'title');
		t.textContent = title;
		svg.appendChild(t);
	} else {
		svg.setAttribute('aria-hidden', 'true');
		svg.setAttribute('focusable', 'false');
	}
	if (d) {
		var p = document.createElementNS(ns, 'path');
		p.setAttribute('d', d);
		svg.appendChild(p);
	}
	return svg;
}

/* ---------------- 视口 ---------------- */

function isMobile() {
	return window.matchMedia ? window.matchMedia('(max-width: 767.98px)').matches
		: window.innerWidth < 768;
}

function isTablet() {
	return !isMobile() && window.innerWidth < 1024;
}

function isTouch() {
	return window.matchMedia ? window.matchMedia('(hover: none)').matches : false;
}

/* 断点与视口变化订阅（返回取消函数）。resize 用 rAF 节流。 */
function watchViewport(fn) {
	var pending = false;
	function onResize() {
		if (pending)
			return;
		pending = true;
		window.requestAnimationFrame(function() {
			pending = false;
			fn();
		});
	}
	window.addEventListener('resize', onResize);
	window.addEventListener('orientationchange', onResize);
	return function() {
		window.removeEventListener('resize', onResize);
		window.removeEventListener('orientationchange', onResize);
	};
}

/* ---------------- 通用视觉零件 ---------------- */

/**
 * MD3 按钮。variant：filled（主）/ tonal（次）/ outlined / text / danger / text-danger。
 * 放在 core 里是因为弹层与页面共用同一套按钮，且弹层不能反向依赖 smartmwan.js
 * （会形成模块环）。click 里用 ui.createHandlerFn 时，禁用与 spinning 由 LuCI 管。
 */
function button(label, opts) {
	opts = opts || {};
	return E('button', {
		'type': 'button',
		'class': 'smw-btn smw-btn-' + (opts.variant || 'filled'),
		'click': opts.click || null
	}, [ E('span', { 'class': 'smw-btn-label' }, [ label ]) ]);
}

/** 图标按钮（关闭、显示密码等）。label 必填：它同时是 aria-label 与 title。 */
function iconButton(name, opts) {
	opts = opts || {};
	var b = E('button', {
		'type': 'button',
		'class': 'smw-icon-btn' + (opts.className ? ' ' + opts.className : ''),
		'aria-label': opts.label || '',
		'title': opts.title || opts.label || ''
	}, [ icon(name, opts.size || 20) ]);
	if (opts.click)
		b.addEventListener('click', opts.click);
	return b;
}

/* ---------------- 其它 ---------------- */

var seq = 0;
function uid(prefix) {
	seq++;
	return (prefix || 'smw') + '-' + seq;
}

var injected = {};
/** 幂等注入样式表：同一 id 只插一次，避免每个组件重复加 <link>。 */
function css(id, href) {
	if (injected[id] || document.getElementById(id) != null)
		return;
	injected[id] = true;
	var link = document.createElement('link');
	link.id = id;
	link.rel = 'stylesheet';
	link.type = 'text/css';
	link.href = href;
	document.head.appendChild(link);
}

/** 把「节点 / 字符串 / 数组（可嵌套）」规整成 E() 认识的单层 children。
 * LuCI 的 E() 不递归展开嵌套数组，嵌套会变成 "[object HTMLDivElement],..."。 */
function flatten(node) {
	if (node == null)
		return '';
	if (!Array.isArray(node))
		return node;
	var out = [];
	node.forEach(function(n) {
		if (Array.isArray(n))
			out = out.concat(flatten(n));
		else if (n != null)
			out.push(n);
	});
	return out;
}

/** 统一的安全文本节点：任何来自 RPC / 后端错误 / 用户输入的内容都走这里，
 * 绝不拼 innerHTML（本模块全项目不出现 innerHTML 赋值）。 */
function text(value) {
	return document.createTextNode(value == null ? '' : String(value));
}

/** 事件监听的一次性登记表：组件关闭时统一解绑，避免漏掉某个监听器。 */
function Listeners() {
	this.items = [];
}
Listeners.prototype.on = function(target, type, fn, opts) {
	if (target == null || target.addEventListener == null)
		return this;
	target.addEventListener(type, fn, opts);
	this.items.push([ target, type, fn, opts ]);
	return this;
};
Listeners.prototype.release = function() {
	for (var i = 0; i < this.items.length; i++) {
		var it = this.items[i];
		try { it[0].removeEventListener(it[1], it[2], it[3]); } catch (e) { /* 节点可能已移除 */ }
	}
	this.items = [];
};

return {
	Z_BASE: Z_BASE,
	pushLayer: pushLayer,
	popLayer: popLayer,
	topLayer: topLayer,
	lockScroll: lockScroll,
	unlockScroll: unlockScroll,
	trapFocus: trapFocus,
	focusables: focusables,
	place: place,
	icon: icon,
	iconButton: iconButton,
	button: button,
	isMobile: isMobile,
	isTablet: isTablet,
	isTouch: isTouch,
	watchViewport: watchViewport,
	uid: uid,
	css: css,
	flatten: flatten,
	text: text,
	Listeners: Listeners
};
