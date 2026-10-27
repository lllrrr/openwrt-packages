'use strict';
/*
 * smwfeedback —— 操作反馈与加载态
 *
 *   Toast    右下角（PC）/ 底部（手机）的通知堆叠：四类语义、去重、上限、
 *            错误默认常驻、可带一个操作按钮、支持「进行中 → 完成/失败」的持续状态；
 *   Loading  区域加载遮罩、骨架屏、确定/不确定进度条、按钮加载态。
 *
 * 两条诚实性约束：
 *   1. 进度条只在拿到真实数值时显示确定进度；没有数值一律走不确定动画，
 *      绝不按时间编一个百分比（编出来的 90% 会在 90% 停很久，用户以为卡死）。
 *   2. Toast 只描述「发生了什么」，不描述「应该是什么状态」。成功与否由调用方
 *      按后端回执传入，本模块不做任何推断。
 */

smwcore.css('smw-overlay-css', L.resource('smartmwan/overlay.css'));

/* ---------------- Toast ---------------- */

var MAX_TOASTS = 4;
var DURATION = { success: 4000, info: 4500, warning: 6500, error: 0, progress: 0 };
/* 0 = 不自动关闭（错误必须由用户看过并关掉，闪一下就消失的错误等于没提示）。 */

var toasts = [];        /* [{ id, key, el, type, timer, remain, startedAt }] */
var toastBox = null;
var toastSeq = 0;

var ICON = { success: 'check', error: 'error', warning: 'warn', info: 'info' };

function ensureBox() {
	if (toastBox != null && toastBox.parentNode != null)
		return toastBox;
	toastBox = E('div', {
		'class': 'smw-toasts',
		'role': 'region',
		'aria-live': 'polite',
		'aria-label': '操作通知'
	});
	document.body.appendChild(toastBox);
	return toastBox;
}

function find(key) {
	for (var i = 0; i < toasts.length; i++)
		if (toasts[i].key === key) return toasts[i];
	return null;
}

function removeToast(t, immediate) {
	if (t == null)
		return;
	if (t.timer) { window.clearTimeout(t.timer); t.timer = null; }
	var idx = toasts.indexOf(t);
	if (idx >= 0) toasts.splice(idx, 1);
	if (immediate) {
		if (t.el.parentNode) t.el.parentNode.removeChild(t.el);
		return;
	}
	t.el.classList.add('smw-toast-out');
	window.setTimeout(function() {
		if (t.el.parentNode) t.el.parentNode.removeChild(t.el);
	}, 200);
}

function armTimer(t, duration) {
	if (t.timer) { window.clearTimeout(t.timer); t.timer = null; }
	if (!duration || duration <= 0)
		return;
	t.remain = duration;
	t.startedAt = Date.now();
	t.timer = window.setTimeout(function() { removeToast(t); }, duration);
}

function pauseTimer(t) {
	if (t.timer == null)
		return;
	window.clearTimeout(t.timer);
	t.timer = null;
	if (t.remain && t.startedAt)
		t.remain = Math.max(600, t.remain - (Date.now() - t.startedAt));
}

function resumeTimer(t) {
	if (t.remain && t.timer == null && !t.persistent)
		armTimer(t, t.remain);
}

/**
 * 显示一条通知。
 * opts: { type, message, details[], action:{label,onClick}, duration,
 *         key, id, persistent, dismissible }
 * 返回 { id, el, dismiss(), update(message) }。
 */
function show(opts) {
	opts = opts || {};
	var type = opts.type || 'info';
	/* message 允许是节点：视图里的通知常常带一个小列表（变更项、校验问题），
	 * 转成字符串会丢掉结构。节点由 E() 构造，不存在字符串拼 HTML 的风险。 */
	var raw = opts.message;
	var isNode = raw != null && raw.nodeType === 1;
	var message = isNode ? (raw.textContent || '') : (raw == null ? '' : String(raw));
	var key = opts.key || (type + '|' + message);

	/* 去重：同 key 的通知还在屏幕上时，不新建第二条——只把它顶到最上面、
	 * 重置计时并闪一下。短时间连续失败（比如连点三次保存）不该刷屏。 */
	var existed = find(key);
	if (existed != null && !opts.id) {
		existed.el.classList.remove('smw-toast-flash');
		/* 强制重排以便重复触发动画 */
		void existed.el.offsetWidth;
		existed.el.classList.add('smw-toast-flash');
		var textEl = existed.el.querySelector('.smw-toast-text');
		if (textEl) textEl.textContent = message;
		existed.el.classList.remove('smw-toast-out');
		armTimer(existed, opts.duration == null ? DURATION[type] : opts.duration);
		return {
			id: existed.id,
			el: existed.el,
			dismiss: function() { removeToast(existed); },
			update: function(m) { if (textEl) textEl.textContent = m == null ? '' : String(m); }
		};
	}

	ensureBox();

	var id = opts.id || ('toast-' + (++toastSeq));
	var iconName = ICON[type] || 'info';

	var textEl = E('div', { 'class': 'smw-toast-text' }, [ isNode ? raw : message ]);
	var kids = [ E('span', { 'class': 'smw-toast-icon' }, [ smwcore.icon(iconName, 20) ]), textEl ];

	if (opts.details && opts.details.length) {
		kids.push(E('ul', { 'class': 'smw-toast-details' },
			opts.details.map(function(d) { return E('li', {}, [ d ]); })));
	}

	var el = E('div', {
		'class': 'smw-toast smw-toast-' + type,
		'role': type === 'error' ? 'alert' : 'status',
		'data-toast-id': id
	}, kids);

	if (opts.action && opts.action.label) {
		var ab = E('button', {
			'type': 'button',
			'class': 'smw-toast-action',
			'click': function() {
				/* 操作按钮点完即关闭：留着会让人以为还能再点一次。 */
				removeToast(t);
				if (typeof opts.action.onClick === 'function')
					opts.action.onClick();
			}
		}, [ opts.action.label ]);
		el.appendChild(ab);
	}

	var closeBtn = null;
	if (opts.dismissible !== false) {
		closeBtn = E('button', {
			'type': 'button',
			'class': 'smw-toast-close',
			'aria-label': '关闭通知',
			'click': function() { removeToast(t); }
		}, [ smwcore.icon('close', 16) ]);
		el.appendChild(closeBtn);
	}

	var t = {
		id: id,
		key: key,
		el: el,
		type: type,
		timer: null,
		remain: 0,
		startedAt: 0,
		persistent: opts.persistent === true || (opts.duration === 0)
	};

	/* 先插入再看上限：新通知永远在最上面（最新最重要）。 */
	var box = ensureBox();
	box.insertBefore(el, box.firstChild);
	toasts.unshift(t);

	/* 悬停暂停计时：用户正在读的时候不该被计时关掉。 */
	el.addEventListener('mouseenter', function() { pauseTimer(t); });
	el.addEventListener('mouseleave', function() { resumeTimer(t); });

	/* 超出上限：移除最旧的（数组尾部）。progress 型不参与淘汰，
	 * 它代表一个仍在进行的任务，删掉会让用户以为任务消失了。 */
	while (toasts.length > MAX_TOASTS) {
		var victim = null;
		for (var i = toasts.length - 1; i >= 0; i--) {
			if (toasts[i].type !== 'progress') { victim = toasts[i]; break; }
		}
		if (victim == null) break;
		removeToast(victim, true);
	}

	var duration = opts.duration == null
		? (t.persistent ? 0 : DURATION[type])
		: opts.duration;
	if (duration > 0)
		armTimer(t, duration);

	return {
		id: id,
		el: el,
		dismiss: function() { removeToast(t); },
		update: function(m) { textEl.textContent = m == null ? '' : String(m); }
	};
}

var Toast = {
	show: show,
	success: function(message, opts) { return show(Object.assign({ type: 'success', message: message }, opts || {})); },
	error: function(message, opts) { return show(Object.assign({ type: 'error', message: message }, opts || {})); },
	warning: function(message, opts) { return show(Object.assign({ type: 'warning', message: message }, opts || {})); },
	info: function(message, opts) { return show(Object.assign({ type: 'info', message: message }, opts || {})); },

	dismiss: function(id) {
		for (var i = 0; i < toasts.length; i++)
			if (toasts[i].id === id) { removeToast(toasts[i]); return true; }
		return false;
	},
	clear: function() {
		toasts.slice().forEach(function(t) { removeToast(t, true); });
	},

	/**
	 * 长时间任务的持续反馈：先给一条「进行中」，完成后原地变成成功/失败。
	 * 返回 { id, update(msg), done(msg), fail(msg) }。
	 * done() 会转成普通通知并按 success 的时长自动关闭；fail() 常驻。
	 */
	progress: function(opts) {
		opts = opts || {};
		var key = opts.key || ('progress|' + (opts.message || ''));
		var textEl = null;
		var handle = show({
			type: 'progress',
			message: opts.message || '处理中…',
			key: key,
			persistent: true,
			dismissible: false
		});
		textEl = handle.el.querySelector('.smw-toast-text');

		function morph(type, message) {
			handle.el.className = 'smw-toast smw-toast-' + type;
			handle.el.setAttribute('role', type === 'error' ? 'alert' : 'status');
			var ic = handle.el.querySelector('.smw-toast-icon');
			if (ic) {
				while (ic.firstChild) ic.removeChild(ic.firstChild);
				ic.appendChild(smwcore.icon(ICON[type] || 'info', 20));
			}
			if (textEl) textEl.textContent = message == null ? '' : String(message);
			/* 转成完成态后补一个关闭按钮：进行中时不给关，避免用户以为取消了任务。 */
			if (!handle.el.querySelector('.smw-toast-close')) {
				handle.el.appendChild(E('button', {
					'type': 'button',
					'class': 'smw-toast-close',
					'aria-label': '关闭通知',
					'click': function() {
						var t = find(key);
						if (t) removeToast(t);
					}
				}, [ smwcore.icon('close', 16) ]));
			}
			var t = find(key);
			if (t) {
				t.type = type;
				t.persistent = type === 'error';
				if (type !== 'error') armTimer(t, DURATION.success);
			}
		}

		return {
			id: handle.id,
			update: function(m) { if (textEl) textEl.textContent = m == null ? '' : String(m); },
			done: function(m) { morph('success', m || '已完成'); },
			fail: function(m) { morph('error', m || '任务失败'); }
		};
	}
};

/* ---------------- Loading / Progress ---------------- */

/**
 * 区域加载遮罩：盖住 target（需要 target 自身可定位，本函数会补 position）。
 * 返回 { done(), fail(msg), el }。fail 会把遮罩换成错误提示并保留，
 * 让「加载失败」不是一片空白。
 */
function region(target, opts) {
	opts = opts || {};
	if (target == null)
		return { done: function() {}, fail: function() {}, el: null };

	var cs = window.getComputedStyle ? window.getComputedStyle(target) : null;
	if (cs && cs.position === 'static')
		target.style.position = 'relative';

	var textEl = E('div', { 'class': 'smw-loading-text' }, [ opts.text || '加载中…' ]);
	var el = E('div', { 'class': 'smw-loading-region', 'role': 'status', 'aria-live': 'polite' }, [
		E('span', { 'class': 'smw-spinner', 'aria-hidden': 'true' }),
		textEl
	]);

	target.appendChild(el);
	try { target.setAttribute('aria-busy', 'true'); } catch (e) { /* 忽略 */ }

	var finished = false;
	function clear() {
		if (finished) return;
		finished = true;
		if (el.parentNode) el.parentNode.removeChild(el);
		try { target.removeAttribute('aria-busy'); } catch (e) { /* 忽略 */ }
	}

	return {
		el: el,
		update: function(msg) { textEl.textContent = msg == null ? '' : String(msg); },
		done: clear,
		fail: function(msg) {
			if (finished) return;
			finished = true;
			el.className = 'smw-loading-region smw-is-error';
			while (el.firstChild) el.removeChild(el.firstChild);
			el.appendChild(smwcore.icon('error', 20));
			el.appendChild(E('div', { 'class': 'smw-loading-text' }, [ msg || '加载失败' ]));
			el.appendChild(E('button', {
				'type': 'button',
				'class': 'smw-btn smw-btn-text',
				'click': function() {
					if (el.parentNode) el.parentNode.removeChild(el);
					try { target.removeAttribute('aria-busy'); } catch (e) { /* 忽略 */ }
					if (typeof opts.onRetry === 'function') opts.onRetry();
				}
			}, [ E('span', { 'class': 'smw-btn-label' }, [ '重试' ]) ]));
		}
	};
}

/** 骨架屏：rows 行灰条。纯装饰，对读屏隐藏（真实内容加载后替换掉它）。 */
function skeleton(opts) {
	opts = opts || {};
	var rows = opts.rows || 3;
	var kids = [];
	for (var i = 0; i < rows; i++)
		kids.push(E('div', { 'class': 'smw-skeleton-line' + (i === rows - 1 ? ' smw-skeleton-short' : '') }));
	return E('div', {
		'class': 'smw-skeleton',
		'aria-hidden': 'true',
		'data-lines': String(rows)
	}, kids);
}

/**
 * 进度条。value 为 null 时是不确定进度（没有真实数值就绝不画确定值）。
 * 返回 { el, set(value), indeterminate(), label(text) }。
 * max 默认 100。
 */
function progress(opts) {
	opts = opts || {};
	var max = opts.max || 100;
	var labelEl = E('div', { 'class': 'smw-progress-label' }, [ opts.label || '' ]);
	var bar = E('div', { 'class': 'smw-progress-bar' });
	var track = E('div', {
		'class': 'smw-progress' + (opts.value == null ? ' smw-progress-indeterminate' : ''),
		'role': 'progressbar',
		'aria-valuemin': '0',
		'aria-valuemax': String(max)
	}, [ bar ]);
	var el = E('div', { 'class': 'smw-progress-wrap' }, [ labelEl, track ]);

	function set(value) {
		if (value == null) {
			track.classList.add('smw-progress-indeterminate');
			track.removeAttribute('aria-valuenow');
			bar.style.width = '';
			return;
		}
		var pct = Math.max(0, Math.min(100, (value / max) * 100));
		track.classList.remove('smw-progress-indeterminate');
		track.setAttribute('aria-valuenow', String(value));
		bar.style.width = pct + '%';
	}

	if (opts.value != null) set(opts.value);

	return {
		el: el,
		set: set,
		indeterminate: function() { set(null); },
		label: function(t) { labelEl.textContent = t == null ? '' : String(t); }
	};
}

/**
 * 按钮加载态。与 LuCI 的 ui.createHandlerFn 共存：
 * 它会加 .spinning；这里补 disabled 与可选的文字替换，结束时原样还原。
 */
function busy(btn, on, label) {
	if (btn == null)
		return;
	var labelEl = btn.querySelector ? btn.querySelector('.smw-btn-label') : null;
	if (on) {
		if (btn.getAttribute('data-smw-busy') === '1')
			return;
		btn.setAttribute('data-smw-busy', '1');
		btn.disabled = true;
		btn.classList.add('spinning');
		if (labelEl != null && label) {
			btn.setAttribute('data-smw-label', labelEl.textContent);
			labelEl.textContent = label;
		}
	} else {
		btn.removeAttribute('data-smw-busy');
		btn.disabled = false;
		btn.classList.remove('spinning');
		if (labelEl != null && btn.getAttribute('data-smw-label') != null) {
			labelEl.textContent = btn.getAttribute('data-smw-label');
			btn.removeAttribute('data-smw-label');
		}
	}
}

return {
	Toast: Toast,
	Loading: {
		region: region,
		skeleton: skeleton,
		progress: progress,
		busy: busy
	}
};
