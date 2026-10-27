'use strict';
/*
 * smwpopover —— 锚定浮层（Popover）与提示气泡（Tooltip）
 *
 * 两者共用同一套定位引擎（smwcore.place：首选方向放不下就翻转、最后夹进视口），
 * 差异在交互语义：
 *   Popover 是「可操作」的浮层：可以放菜单、筛选器、轻量设置；
 *            打开时会接管焦点但不锁页面焦点（非模态），外部点击与 ESC 关闭；
 *   Tooltip 是「纯说明」的气泡：只读、不接收焦点、不承载关键信息。
 *
 * 为什么必须挂到 body 而不是锚点旁边：LuCI 的卡片/表格普遍有 overflow:hidden
 * 或 overflow-x:auto，浮层放在里面会被裁切。挂 body + 绝对定位 + 层级栈是唯一
 * 能同时满足「不被裁切」与「跟随锚点」的做法。
 *
 * Tooltip 的一条纪律：错误信息、必填说明、关键操作不得只写在 Tooltip 里。
 * 本模块不提供任何「重要信息只放气泡」的用法，字段说明请用 Form.field 的 help。
 */

smwcore.css('smw-overlay-css', L.resource('smartmwan/overlay.css'));

/* ---------------- Popover ---------------- */

var current = null;   /* { anchor, el, close }，同一时刻只允许一个 */

/**
 * 打开浮层。
 * opts: { content, placement:'bottom-start', offset:8, className,
 *         autoFocus:true, onClose(reason) }
 * 返回 { el, close(reason), reposition() }。
 */
function open(anchorEl, opts) {
	opts = opts || {};
	if (current != null)
		current.close('replace');

	var el = E('div', {
		'class': 'smw-popover' + (opts.className ? ' ' + opts.className : ''),
		'role': opts.role || 'dialog',
		'tabindex': '-1'
	}, smwcore.flatten(opts.content));

	document.body.appendChild(el);
	smwcore.pushLayer(el);

	var listeners = new smwcore.Listeners();
	var closed = false;
	var unwatch = null;

	function reposition() {
		if (closed || anchorEl == null || anchorEl.parentNode == null)
			return;
		smwcore.place(anchorEl, el, {
			placement: opts.placement || 'bottom-start',
			offset: opts.offset == null ? 8 : opts.offset
		});
	}

	/* 先放一次位置再显示：避免在左上角闪一帧。 */
	reposition();
	window.requestAnimationFrame(function() { if (!closed) el.classList.add('smw-open'); });

	function close(reason) {
		if (closed)
			return;
		closed = true;
		var hadFocus = el.contains && el.contains(document.activeElement);
		listeners.release();
		if (unwatch) { unwatch(); unwatch = null; }
		smwcore.popLayer(el);
		el.classList.remove('smw-open');
		var node = el;
		window.setTimeout(function() {
			if (node.parentNode) node.parentNode.removeChild(node);
		}, 160);
		if (current != null && current.el === el)
			current = null;
		/* 焦点在浮层里被关掉时，还给锚点，否则焦点会掉到 body 上。 */
		if (hadFocus && anchorEl != null && anchorEl.focus)
			anchorEl.focus();
		if (typeof opts.onClose === 'function')
			opts.onClose(reason || 'program');
	}

	current = { anchor: anchorEl, el: el, close: close };

	/* 外部点击：pointerdown 就关（比 click 早，避免锚点自己的 click 又打开一次）。 */
	listeners.on(document, 'pointerdown', function(ev) {
		if (el.contains(ev.target))
			return;
		if (anchorEl != null && (ev.target === anchorEl || anchorEl.contains(ev.target)))
			return;
		close('outside');
	}, true);

	listeners.on(document, 'keydown', function(ev) {
		if (ev.key !== 'Escape')
			return;
		ev.preventDefault();
		close('esc');
	}, true);

	/* 滚动与缩放都要重定位：浮层挂 body，不跟着锚点动。 */
	unwatch = smwcore.watchViewport(reposition);
	listeners.on(window, 'scroll', reposition, true);

	if (opts.autoFocus !== false) {
		var first = smwcore.focusables(el)[0];
		window.setTimeout(function() {
			if (!closed && first != null) first.focus();
			else if (!closed) el.focus();
		}, 0);
	}

	return { el: el, close: close, reposition: reposition };
}

function closeAll() {
	if (current != null)
		current.close('program');
}

/* ---------------- Tooltip ---------------- */

var tipEl = null;
var tipTimer = null;
var tipHideTimer = null;
var tipOwner = null;

function ensureTip() {
	if (tipEl != null && tipEl.parentNode != null)
		return tipEl;
	tipEl = E('div', { 'class': 'smw-tooltip', 'role': 'tooltip', 'id': 'smw-tooltip' });
	document.body.appendChild(tipEl);
	return tipEl;
}

function hideTip(immediate) {
	if (tipHideTimer) { window.clearTimeout(tipHideTimer); tipHideTimer = null; }
	if (tipTimer) { window.clearTimeout(tipTimer); tipTimer = null; }
	var el = tipEl;
	tipOwner = null;
	if (el == null)
		return;
	function doHide() {
		el.classList.remove('smw-open');
		window.setTimeout(function() {
			if (el.parentNode && !el.classList.contains('smw-open'))
				el.parentNode.removeChild(el);
		}, 160);
	}
	if (immediate) doHide();
	else tipHideTimer = window.setTimeout(doHide, 120);
}

function showTip(anchorEl, content, placement) {
	ensureTip();
	if (tipTimer) { window.clearTimeout(tipTimer); tipTimer = null; }
	if (tipHideTimer) { window.clearTimeout(tipHideTimer); tipHideTimer = null; }

	tipEl.textContent = content == null ? '' : String(content);
	if (!tipEl.parentNode)
		document.body.appendChild(tipEl);
	smwcore.place(anchorEl, tipEl, { placement: placement || 'top', offset: 8 });
	tipEl.classList.add('smw-open');
	tipOwner = anchorEl;
	anchorEl.setAttribute('aria-describedby', 'smw-tooltip');
}

/**
 * 给元素挂说明气泡。返回 detach()。
 * opts: { placement:'top', delay:500 }
 *
 * 触屏设备没有 hover：改成「点一下显示，点外部或再点一下收起」，
 * 并阻止这次点击继续冒泡（避免同时触发按钮动作）。
 */
function attach(anchorEl, content, opts) {
	opts = opts || {};
	if (anchorEl == null || !anchorEl.addEventListener)
		return function() {};

	var delay = opts.delay == null ? 500 : opts.delay;
	var touch = smwcore.isTouch();

	function onEnter() {
		if (tipTimer) window.clearTimeout(tipTimer);
		tipTimer = window.setTimeout(function() { showTip(anchorEl, content, opts.placement); }, delay);
	}
	function onLeave() {
		if (tipTimer) { window.clearTimeout(tipTimer); tipTimer = null; }
		if (tipOwner === anchorEl) hideTip(false);
	}
	function onFocus() {
		/* 键盘聚焦立即显示：等 500ms 再出现会让读屏与键盘用户以为没有提示。 */
		showTip(anchorEl, content, opts.placement);
	}
	function onBlur() {
		if (tipOwner === anchorEl) hideTip(false);
	}
	function onTap(ev) {
		ev.preventDefault();
		ev.stopPropagation();
		if (tipOwner === anchorEl) { hideTip(true); return; }
		showTip(anchorEl, content, opts.placement);
	}

	if (touch) {
		anchorEl.addEventListener('click', onTap);
	} else {
		anchorEl.addEventListener('mouseenter', onEnter);
		anchorEl.addEventListener('mouseleave', onLeave);
		anchorEl.addEventListener('focus', onFocus);
		anchorEl.addEventListener('blur', onBlur);
	}

	return function detach() {
		anchorEl.removeEventListener('click', onTap);
		anchorEl.removeEventListener('mouseenter', onEnter);
		anchorEl.removeEventListener('mouseleave', onLeave);
		anchorEl.removeEventListener('focus', onFocus);
		anchorEl.removeEventListener('blur', onBlur);
		anchorEl.removeAttribute('aria-describedby');
		if (tipOwner === anchorEl) hideTip(true);
	};
}

/* 滚动时收起气泡：气泡是 fixed 定位，不跟随内容滚动，留着会指错对象。 */
document.addEventListener('scroll', function() {
	if (tipOwner != null) hideTip(true);
}, true);

return {
	Popover: { open: open, close: closeAll, closeCurrent: function() { closeAll(); } },
	Tooltip: { attach: attach, hide: hideTip }
};
