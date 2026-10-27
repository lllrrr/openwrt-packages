'use strict';
/*
 * smwoverlay —— 弹层组件：Dialog（居中）/ Drawer（右侧）/ Sheet（底部）/ Confirm
 *
 * 三者共用同一套骨架与生命周期，差异只在「定位与形态」：
 *   Dialog  居中卡片，四档宽度（sm 400 / md 560 / lg 840 / xl 1080），
 *           手机端默认转成底部面板（可用 mobile:'dialog' 保持居中）；
 *   Drawer  右侧滑出，宽度可配（默认 480），手机端全宽；
 *   Sheet   贴底，顶部圆角 + 拖动把手，暴露给移动端快捷操作。
 *
 * 生命周期（一个实例只走一遍，反向可重入都被挡住）：
 *   open → （用户触发关闭）→ beforeClose 守卫 → closing（动画）→ closed（DOM 与监听器清空）
 *
 * 三条硬规则：
 *   1. 关闭路径统一：关闭按钮 / 遮罩 / ESC / 动作按钮 / 代码调用，全部经过
 *      requestClose()，beforeClose 只写一次就能覆盖所有入口；
 *   2. 提交期间一律不可关闭（busy 时遮罩与 ESC 都无效）——半提交状态比
 *      「点了没反应」更难排查；
 *   3. 关闭时必须把「焦点、滚动锁、层级、监听器、定时器」全部还回去，
 *      否则下一个弹层会带着上一个的残留（遮罩叠两层、页面锁死、焦点跑到 body）。
 *
 * 未保存检测的约定：beforeClose 返回 true 表示可以关；返回字符串表示
 * 「有未保存内容」，该字符串会作为二次确认的提示语；返回 false 表示直接拦下。
 * 异步返回同样支持（校验前需要请求后端的场景）。
 */

/* 关闭动画时长与本文件里的等待保持一致；CSS 里对应 --smw-dur-med。
 * 少 20ms 兜底，避免 transitionend 因 reduced-motion 不触发时卡住。 */
var CLOSE_MS = 220;
var DRAG_CLOSE_PX = 120;

var instances = {};     /* id -> controller */

/* ---------------- 公共工具 ---------------- */

function actionButton(a, onClick) {
	var b = smwcore.button(a.label, {
		variant: a.danger ? 'danger' : (a.variant || 'text')
	});
	b.setAttribute('data-smw-value', a.value == null ? a.label : String(a.value));
	b.addEventListener('click', function() { onClick(a, b); });
	return b;
}

function buttonLabel(btn) {
	var span = btn.querySelector ? btn.querySelector('.smw-btn-label') : null;
	return span || btn;
}

/* ---------------- 统一构造 ---------------- */

/**
 * 打开一个弹层。
 * kind: 'dialog' | 'drawer' | 'sheet'
 * 返回 controller（见下方 ctl 的字段），其中 ctl.promise 在关闭时 resolve。
 */
function open(kind, opts) {
	opts = opts || {};

	var id = opts.id || smwcore.uid('smw-' + kind);
	/* 同 id 重复打开：先关旧的那个，避免同 id 两个实例互相覆盖注册表。 */
	if (instances[id] != null)
		instances[id].close(null, 'replace');

	var titleId = id + '-title';
	var descId = id + '-desc';
	var listeners = new smwcore.Listeners();
	var dismiss = opts.dismissible || {};

	var ctl = {
		id: id,
		kind: kind,
		state: 'open',
		busy: false,
		value: undefined,
		reason: null,
		close: null,          /* 在下面赋值，先占位保证 controller 形状稳定 */
		promise: null
	};

	var resolvePromise;
	ctl.promise = new Promise(function(res) { resolvePromise = res; });

	/* —— 遮罩 —— */
	var scrim = E('div', { 'class': 'smw-scrim', 'aria-hidden': 'true' });

	/* —— 面板 —— */
	var panelClass = 'smw-overlay smw-overlay--' + kind + ' smw-size-' + (opts.size || 'md');
	if (opts.className)
		panelClass += ' ' + opts.className;
	if (opts.mobile === 'dialog')
		panelClass += ' smw-keep-dialog';
	if (opts.mobile === 'fullscreen')
		panelClass += ' smw-mobile-full';

	var panel = E('div', {
		'class': panelClass,
		'role': 'dialog',
		'aria-modal': 'true',
		'tabindex': '-1'
	});
	if (opts.title != null)
		panel.setAttribute('aria-labelledby', titleId);
	if (opts.description != null)
		panel.setAttribute('aria-describedby', descId);

	/* —— 头部 —— */
	var heading = E('div', { 'class': 'smw-overlay-heading' });
	if (opts.title != null)
		heading.appendChild(E('h2', { 'class': 'smw-overlay-title', 'id': titleId }, [ opts.title ]));
	if (opts.description != null)
		heading.appendChild(E('p', { 'class': 'smw-overlay-desc', 'id': descId }, [ opts.description ]));

	var head = E('div', { 'class': 'smw-overlay-head' });
	/* 拖动把手只给 Sheet：它是「可下滑关闭」的唯一视觉承诺。 */
	if (kind === 'sheet' && opts.dragHandle !== false)
		head.appendChild(E('div', { 'class': 'smw-overlay-grip', 'aria-hidden': 'true' }));
	head.appendChild(heading);

	var closeBtn = null;
	if (dismiss.button !== false) {
		closeBtn = smwcore.iconButton('close', {
			label: '关闭',
			className: 'smw-overlay-close',
			click: function() { requestClose(null, 'button'); }
		});
		head.appendChild(closeBtn);
	}
	panel.appendChild(head);

	/* —— 内容区：独立滚动 —— */
	/* 注意：flatten 已经返回数组/节点，不能再包一层 [] ——
	 * LuCI 的 E() 不递归展开嵌套数组，多包一层会在页面上显示
	 * "[object HTMLParagraphElement],..."（这个坑本项目踩过两次）。 */
	var body = E('div', { 'class': 'smw-overlay-body' }, smwcore.flatten(opts.body));
	if (opts.body != null)
		panel.appendChild(body);

	/* —— 状态区：提交中 / 成功 / 失败（默认隐藏，有内容才占位） —— */
	var statusText = E('span', { 'class': 'smw-overlay-status-text' });
	var status = E('div', {
		'class': 'smw-overlay-status',
		'role': 'status',
		'aria-live': 'polite',
		'hidden': 'hidden'
	}, [ statusText ]);
	panel.appendChild(status);

	/* —— 底部操作区：固定，不随内容滚动 —— */
	var actionsBox = E('div', { 'class': 'smw-overlay-actions' });
	var foot = E('div', { 'class': 'smw-overlay-foot' });
	if (opts.footer != null)
		foot.appendChild(E('div', { 'class': 'smw-overlay-foot-extra' },
			smwcore.flatten(opts.footer)));
	foot.appendChild(actionsBox);
	if ((opts.actions && opts.actions.length) || opts.footer != null)
		panel.appendChild(foot);

	ctl.el = panel;
	ctl.scrim = scrim;
	ctl.body = body;
	ctl.footer = foot;
	ctl.actions = actionsBox;

	/* —— 挂载 + 层级 + 滚动锁 —— */
	document.body.appendChild(scrim);
	document.body.appendChild(panel);
	smwcore.pushLayer(scrim);
	smwcore.pushLayer(panel);
	smwcore.lockScroll();

	if (kind === 'drawer' && opts.width)
		panel.style.width = (typeof opts.width === 'number' ? opts.width + 'px' : opts.width);

	/* Drawer 从右侧滑入需要先有 mounted 的尺寸，class 由 CSS 的初始状态控制。 */
	window.requestAnimationFrame(function() {
		panel.classList.add('smw-open');
		scrim.classList.add('smw-open');
	});

	/* ———————— 关闭流程 ———————— */

	var released = null;      /* 焦点陷阱的 release */
	var unbindViewport = null;
	var closed = false;

	function teardown() {
		smwcore.popLayer(panel);
		smwcore.popLayer(scrim);
		smwcore.unlockScroll();
		listeners.release();
		if (released) { released(); released = null; }
		if (unbindViewport) { unbindViewport(); unbindViewport = null; }
		if (panel.parentNode) panel.parentNode.removeChild(panel);
		if (scrim.parentNode) scrim.parentNode.removeChild(scrim);
		if (instances[id] === ctl) delete instances[id];
	}

	/** 无条件关闭：动画 → 清理 → resolve。 */
	function forceClose(value, reason) {
		if (closed)
			return;
		closed = true;
		ctl.state = 'closing';
		ctl.value = value;
		ctl.reason = reason || 'program';

		panel.classList.remove('smw-open');
		scrim.classList.remove('smw-open');
		panel.classList.add('smw-closing');
		scrim.classList.add('smw-closing');

		/* 动画结束再摘 DOM：先摘会让关闭动画看不见；同时用定时器兜底，
		 * 因为 prefers-reduced-motion 下 transitionend 不一定触发。 */
		var done = false;
		function finish() {
			if (done) return;
			done = true;
			teardown();
			ctl.state = 'closed';
			if (typeof opts.onClose === 'function') {
				try { opts.onClose(ctl.reason, value); } catch (e) { /* 回调异常不影响清理 */ }
			}
			resolvePromise(value);
		}
		listeners.on(panel, 'transitionend', function(ev) {
			if (ev.target === panel) finish();
		});
		window.setTimeout(finish, CLOSE_MS);
	}

	/**
	 * 用户触发的关闭：先过 beforeClose 守卫。
	 * 守卫返回字符串时，弹一层确认（「放弃未保存的修改？」），确认后才关。
	 */
	function requestClose(value, reason) {
		if (ctl.state !== 'open' || ctl.busy)
			return;
		var verdict = true;
		if (typeof opts.beforeClose === 'function') {
			try { verdict = opts.beforeClose(reason || 'request'); }
			catch (e) { verdict = false; }
		}
		Promise.resolve(verdict).then(function(ok) {
			if (ok === true) {
				forceClose(value, reason);
				return;
			}
			if (typeof ok === 'string' && ok.length) {
				/* 二次确认：本模块内再开一层 Dialog，层级栈天然处理嵌套。 */
				Confirm.show({
					title: '放弃未保存的修改？',
					message: ok,
					confirmText: '放弃修改',
					cancelText: '继续编辑',
					danger: true
				}).then(function(yes) {
					if (yes === true)
						forceClose(value, reason);
				});
			}
		});
	}

	ctl.close = function(value, reason) { forceClose(value, reason || 'program'); };
	ctl.requestClose = requestClose;

	/* ———————— 状态区 ———————— */

	/**
	 * setState('idle'|'loading'|'success'|'error', { message })
	 * 只在需要「不关闭也给出反馈」的场景显示（成功但留在弹窗内、提交失败等）。
	 */
	ctl.setState = function(state, extra) {
		extra = extra || {};
		var msg = extra.message || '';
		if (state === 'idle' || !msg) {
			status.setAttribute('hidden', 'hidden');
			status.className = 'smw-overlay-status';
			statusText.textContent = '';
			return;
		}
		status.removeAttribute('hidden');
		status.className = 'smw-overlay-status smw-is-' + state;
		status.setAttribute('aria-live', state === 'error' ? 'assertive' : 'polite');
		statusText.textContent = msg;
	};

	ctl.setTitle = function(text) {
		var h = panel.querySelector('.smw-overlay-title');
		if (h) h.textContent = text == null ? '' : String(text);
		return ctl;
	};

	/* ———————— 动作按钮与异步提交 ———————— */

	var actionEls = [];

	function setActionsDisabled(disabled) {
		for (var i = 0; i < actionEls.length; i++)
			actionEls[i].disabled = !!disabled;
		if (closeBtn) closeBtn.disabled = !!disabled;
	}

	function setButtonLoading(btn, on, loadingText) {
		var label = buttonLabel(btn);
		if (on) {
			if (btn.getAttribute('data-smw-label') == null)
				btn.setAttribute('data-smw-label', label.textContent);
			if (loadingText)
				label.textContent = loadingText;
			btn.classList.add('spinning');
		} else {
			var orig = btn.getAttribute('data-smw-label');
			if (orig != null) {
				label.textContent = orig;
				btn.removeAttribute('data-smw-label');
			}
			btn.classList.remove('spinning');
		}
	}

	function runAction(a, btn) {
		/* 重复提交保护：busy 期间第二次点击直接丢弃（按钮已 disabled，
		 * 这里再挡一次键盘回车与脚本误触）。 */
		if (ctl.busy)
			return;

		var value = a.value == null ? a.label : a.value;

		if (typeof a.onClick !== 'function') {
			/* 无回调 = 纯选项按钮（选择型 sheet 的常见用法）。 */
			forceClose(value, 'action');
			return;
		}

		ctl.busy = true;
		setActionsDisabled(true);
		if (btn) setButtonLoading(btn, true, a.loadingText);
		ctl.setState('idle');

		var out;
		try {
			out = a.onClick(ctl);
		} catch (e) {
			out = Promise.reject(e);
		}

		Promise.resolve(out).then(function(result) {
			if (result === false) {
				/* 明确的「不关闭」：恢复可操作，不当作错误。 */
				ctl.busy = false;
				setActionsDisabled(false);
				if (btn) setButtonLoading(btn, false);
				return;
			}
			if (a.closeOnSuccess === false) {
				ctl.busy = false;
				setActionsDisabled(false);
				if (btn) setButtonLoading(btn, false);
				ctl.setState('success', {
					message: a.successText || '已完成'
				});
				if (typeof a.onSuccess === 'function')
					a.onSuccess(ctl, result);
				return;
			}
			forceClose(result === undefined ? value : result, 'action');
		}).catch(function(err) {
			/* 失败恢复：按钮回到可点，错误就地显示 —— 用户改完可以再提交，
			 * 不需要关掉弹窗重来。 */
			ctl.busy = false;
			setActionsDisabled(false);
			if (btn) setButtonLoading(btn, false);
			ctl.setState('error', {
				message: a.errorText || (err && err.message) || '操作失败'
			});
		});
	}

	(opts.actions || []).forEach(function(a) {
		var b = actionButton(a, runAction);
		actionEls.push(b);
		actionsBox.appendChild(b);
	});

	/* ———————— 关闭入口 ———————— */

	if (dismiss.scrim !== false) {
		listeners.on(scrim, 'click', function() {
			/* 只响应最上层：嵌套弹窗时点遮罩不应把下面那层也关掉。 */
			if (smwcore.topLayer() === panel)
				requestClose(null, 'scrim');
		});
	} else {
		scrim.classList.add('smw-scrim-static');
	}

	listeners.on(document, 'keydown', function(ev) {
		if (ev.key !== 'Escape')
			return;
		if (smwcore.topLayer() !== panel)
			return;
		ev.preventDefault();
		ev.stopPropagation();
		if (dismiss.esc === false)
			return;
		requestClose(null, 'esc');
	}, true);

	/* ———————— Sheet 下滑关闭 ———————— */

	if (kind === 'sheet' && opts.dragHandle !== false) {
		var dragFrom = null;
		var dragStart = 0;

		listeners.on(head, 'pointerdown', function(ev) {
			/* 鼠标只认左键；触控与手写笔随意。 */
			if (ev.pointerType === 'mouse' && ev.button !== 0)
				return;
			/* 关闭按钮上的按下不算拖动起点。 */
			if (closeBtn && (ev.target === closeBtn || closeBtn.contains(ev.target)))
				return;
			dragFrom = ev.clientY;
			dragStart = Date.now();
			panel.style.transition = 'none';
			try { head.setPointerCapture(ev.pointerId); } catch (e) { /* 老浏览器 */ }
		});

		listeners.on(head, 'pointermove', function(ev) {
			if (dragFrom == null)
				return;
			var dy = Math.max(0, ev.clientY - dragFrom);
			panel.style.transform = 'translateY(' + dy + 'px)';
			panel.classList.add('smw-dragging');
		});

		function endDrag(ev) {
			if (dragFrom == null)
				return;
			var dy = Math.max(0, ev.clientY - dragFrom);
			var elapsed = Math.max(1, Date.now() - dragStart);
			dragFrom = null;
			panel.style.transition = '';
			panel.style.transform = '';
			panel.classList.remove('smw-dragging');
			/* 位移够远，或者甩得够快（>0.5px/ms）都算关闭意图。 */
			if (dy > DRAG_CLOSE_PX || (dy > 40 && dy / elapsed > 0.5))
				requestClose(null, 'drag');
		}

		listeners.on(head, 'pointerup', endDrag);
		listeners.on(head, 'pointercancel', endDrag);
	}

	/* ———————— 键盘避让（虚拟键盘） ———————— */

	if (window.visualViewport && kind !== 'drawer') {
		function onViewport() {
			var vv = window.visualViewport;
			/* 视口明显变矮 = 键盘弹出。面板高度跟着收，输入框不会被盖住。 */
			if (vv.height < window.innerHeight - 80) {
				panel.style.maxHeight = Math.round(vv.height * 0.94) + 'px';
				panel.classList.add('smw-kb-open');
			} else {
				panel.style.maxHeight = '';
				panel.classList.remove('smw-kb-open');
			}
		}
		window.visualViewport.addEventListener('resize', onViewport);
		unbindViewport = function() {
			window.visualViewport.removeEventListener('resize', onViewport);
		};
	}

	/* ———————— 焦点 ———————— */

	/* 初始焦点的优先级：
	 *   1. 调用方指定；
	 *   2. 表单类弹窗 → 第一个输入控件（用户打开就是为了填表）；
	 *   3. 否则 → 第一个动作按钮（确认框里是「取消」，菜单里是第一项）；
	 *   4. 兜底 → 面板本身。
	 * 刻意**不**默认落到右上角的关闭按钮：那是「我要退出」，
	 * 不该成为打开弹窗后的第一落点（回车会直接关掉弹窗）。 */
	var focusTarget = opts.initialFocus ||
		body.querySelector('input:not([type="hidden"]), select, textarea') ||
		actionsBox.querySelector('.smw-btn') ||
		panel;

	released = smwcore.trapFocus(panel, focusTarget);

	/* 长表单里初始焦点可能在折叠之下，滚到可见区。 */
	if (focusTarget && focusTarget.scrollIntoView) {
		try { focusTarget.scrollIntoView({ block: 'nearest' }); } catch (e) { /* 忽略 */ }
	}

	instances[id] = ctl;
	return ctl;
}

/* ---------------- 对外组件 ---------------- */

var Dialog = {
	/**
	 * 居中模态。手机端默认转底部面板，保证拇指够得到按钮。
	 * opts.size: sm | md | lg | xl；opts.mobile: 'auto'|'dialog'|'fullscreen'
	 */
	open: function(opts) {
		return open('dialog', opts);
	},
	close: function(id, value) {
		if (instances[id] != null)
			instances[id].close(value == null ? null : value, 'program');
		return instances[id] == null;
	},
	/** 关闭所有（页面切走时兜底清理，避免残留遮罩）。 */
	closeAll: function() {
		Object.keys(instances).forEach(function(id) {
			instances[id].close(null, 'page');
		});
	},
	isOpen: function(id) { return instances[id] != null; }
};

var Drawer = {
	/**
	 * 右侧抽屉。PC 宽度默认 480，手机端全屏。
	 * opts.width: number|string；复杂内容可以给 560。
	 */
	open: function(opts) {
		return open('drawer', opts);
	},
	close: function(id, value) {
		if (instances[id] != null)
			instances[id].close(value == null ? null : value, 'program');
		return instances[id] == null;
	}
};

var Sheet = {
	/**
	 * 底部面板。actions 里不给 onClick 时，点击即关闭并以 value resolve
	 * （「菜单式」用法）；给 onClick 时走异步提交逻辑。
	 */
	open: function(opts) {
		return open('sheet', opts);
	},
	close: function(id, value) {
		if (instances[id] != null)
			instances[id].close(value == null ? null : value, 'program');
		return instances[id] == null;
	}
};

/* ---------------- Confirm ---------------- */

var SEVERITY = {
	normal: { variant: 'filled', icon: 'info' },
	danger: { variant: 'danger', icon: 'warn' },
	critical: { variant: 'danger', icon: 'warn' }
};

var Confirm = {
	/**
	 * 危险/重要操作确认。resolve(true) 表示用户确认，其余一律视为取消。
	 *
	 * opts:
	 *   title          标题
	 *   message        一句话说明「做什么」
	 *   details[]      影响与恢复方式（逐条列出，不要塞进 message）
	 *   severity       'normal' | 'danger' | 'critical'
	 *   danger         旧参数，等价于 severity:'danger'
	 *   requireType    要求用户原样输入的文本（critical 的二次确认）
	 *   disconnectRisk 提示「可能中断当前管理连接」
	 *   confirmText / cancelText
	 *   onConfirm      async 提交函数；提供时确认按钮在提交期间禁用，
	 *                  失败就地显示错误且不关闭（可重试）
	 */
	show: function(opts) {
		opts = opts || {};
		var severity = opts.severity || (opts.danger ? 'danger' : 'normal');
		var look = SEVERITY[severity] || SEVERITY.normal;
		var requireType = opts.requireType;
		var typeInput = null;
		var confirmBtn = null;

		var kids = [];
		if (opts.message != null)
			kids.push(E('p', { 'class': 'smw-confirm-msg' }, [ opts.message ]));

		if (opts.details && opts.details.length) {
			kids.push(E('ul', { 'class': 'smw-confirm-details' },
				opts.details.map(function(d) { return E('li', {}, [ d ]); })));
		}

		if (opts.disconnectRisk) {
			kids.push(E('div', { 'class': 'smw-confirm-risk' }, [
				smwcore.icon('warn', 18),
				E('span', {}, [
					'此操作可能中断当前管理连接。若页面失去响应，请等待约 30 秒后重新连接设备。'
				])
			]));
		}

		if (requireType) {
			var inputId = smwcore.uid('smw-confirm-type');
			var label = E('label', { 'class': 'smw-confirm-type-label', 'for': inputId }, [
				'请输入 ', E('code', {}, [ requireType ]), ' 以确认本次操作'
			]);
			typeInput = E('input', {
				'type': 'text',
				'class': 'smw-input',
				'id': inputId,
				'autocomplete': 'off',
				'spellcheck': 'false',
				'placeholder': requireType
			});
			kids.push(E('div', { 'class': 'smw-confirm-type' }, [ label, typeInput ]));
		}

		var ctl = Dialog.open({
			title: opts.title || '确认操作',
			size: 'sm',
			/* 确认框在手机上保持居中：底部面板会把「危险按钮」推到屏幕最下方，
			 * 反而更容易误触。窄屏用 92vw 适配。 */
			mobile: 'dialog',
			className: 'smw-overlay--confirm',
			body: kids,
			initialFocus: typeInput || undefined,
			actions: [
				{ label: opts.cancelText || '取消', variant: 'text', value: false },
				{
					label: opts.confirmText || '确认',
					variant: look.variant,
					value: true,
					loadingText: opts.loadingText || '处理中…',
					onClick: opts.onConfirm ? function(c) { return opts.onConfirm(c); } : null
				}
			]
		});

		/* 标题前的语义图标：危险等级不只靠颜色传达（形状 + 文字标签）。 */
		var titleEl = ctl.el.querySelector('.smw-overlay-title');
		if (titleEl != null) {
			var wrap = E('span', { 'class': 'smw-confirm-title' }, [
				smwcore.icon(look.icon, 20),
				E('span', {}, [ opts.title || '确认操作' ])
			]);
			titleEl.textContent = '';
			titleEl.appendChild(wrap);
		}

		var btns = ctl.el.querySelectorAll ? ctl.el.querySelectorAll('.smw-overlay-actions .smw-btn') : [];

		/* critical：输入文本匹配后才允许确认。 */
		if (requireType && typeInput) {
			confirmBtn = btns.length ? btns[btns.length - 1] : null;
			if (confirmBtn) {
				confirmBtn.disabled = true;
				typeInput.addEventListener('input', function() {
					confirmBtn.disabled = typeInput.value !== requireType;
				});
			}
		}

		/* 对外契约：Confirm 只有 true / false 两种结果。
		 * null（取消、ESC、点遮罩、点关闭）统一折叠为 false，
		 * 调用方写 `if (!ok) return;` 就够了，不必区分三种「没同意」。 */
		return ctl.promise.then(function(v) { return v === true; });
	}
};

return {
	open: open,
	Dialog: Dialog,
	Drawer: Drawer,
	Sheet: Sheet,
	Confirm: Confirm,
	instances: instances
};
