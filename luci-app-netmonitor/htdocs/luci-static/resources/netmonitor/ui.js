/*
 * luci-app-netmonitor 原生 UI 组件层
 *
 * 为什么不再使用 TDesign Web Components
 * -------------------------------------
 * 本项目此前依赖随包分发的 TDesign UMD bundle（tdesign.min.js，7.3 MB），
 * 但实际只用到 t-button / t-tag / t-dialog / t-alert 四个组件。代价是：
 *
 *   1. 包体被撑到 7.4 MB。路由器 flash 紧张，每个标签页都要重新解析
 *      这份 UMD，低端 CPU 上首屏明显卡顿。
 *   2. 随包的 tdesign.css 是**残缺的组件样式表**：578 条 CSS 变量齐全，
 *      但 dialog 相关规则一条都没有（实测 `grep -c dialog` = 0）。
 *      结果 t-dialog 的定位容器 `.t-dialog__ctx` 拿不到任何 display 规则，
 *      组件停留在关闭动画的离开态（实测 display:none + rect 高 0），
 *      编辑弹窗点了毫无反应 —— 这是本项目最严重的功能缺陷。
 *   3. Web Components 的自定义元素契约（属性名、事件名、shadow 可见性）
 *      随版本变化，代码里已经出现多处「实测失效」的补丁注释，维护成本高。
 *
 * 因此这里用原生 DOM + 本项目自有样式重建所需的四个组件：
 * 无外部依赖、无版本漂移、样式与站点主题一致、修复弹窗失效。
 */

/* ---------------------------------------------------------------- 基础工具 */

/* 转义为 HTML 文本。仅在拼接 innerHTML 字符串时使用；
 * 纯文本内容一律走 textContent，无需本函数。 */
function esc(s) {
	return String(s == null ? '' : s)
		.replace(/&/g, '&amp;')
		.replace(/</g, '&lt;')
		.replace(/>/g, '&gt;')
		.replace(/"/g, '&quot;')
		.replace(/'/g, '&#39;');
}

function el(tag, cls, text) {
	var e = document.createElement(tag);
	if (cls) e.className = cls;
	/* 第三个参数是**纯文本**：走 textContent 而不是 innerHTML。
	 * 页面里大量展示用户自填的 name / host / label / remark，
	 * 用 innerHTML 拼接等于给了存储型 XSS —— LuCI 会话等价于 root 权限。
	 * 需要 HTML 时用 elHtml()。 */
	if (text != null) e.textContent = String(text);
	return e;
}

/* 需要插入 HTML 时显式使用本函数，让「哪里有 innerHTML」一目了然。 */
function elHtml(tag, cls, html) {
	var e = document.createElement(tag);
	if (cls) e.className = cls;
	if (html != null) e.innerHTML = String(html);
	return e;
}

function setDisabled(node, on) {
	if (!node) return;
	/* 统一在这里处理禁用态：targets.js 曾为「必须 removeAttribute 才能解禁」
	 * 写过一段注释，但那其实是原生 <button> 的语义。自定义元素的
	 * disabled 反射行为并无可靠保证，这里直接切 .disabled 属性 + class，
	 * 对我们自己的 <button> 与任何未来的自定义元素都成立。 */
	if (on) {
		node.setAttribute('disabled', 'disabled');
		node.classList.add('is-disabled');
		if ('disabled' in node) node.disabled = true;
	} else {
		node.removeAttribute('disabled');
		node.classList.remove('is-disabled');
		if ('disabled' in node) node.disabled = false;
	}
}

/* ---------------------------------------------------------------- 按钮 */

/*
 * 按钮工厂。
 * opts: { label, theme, variant, size, icon, onClick, disabled, title }
 *   theme  : 'primary' | 'default' | 'danger' | 'warning'
 *   variant: 'outline' | 'text'（默认 outline）
 *   icon   : SVG 字符串，作为前置图标
 *   onClick: () => any|Promise。Promise 期间自动禁用按钮，
 *            结束后恢复；失败时弹错误提示并保留按钮可用。
 *
 * 错误处理集中在这里：此前每个调用点都各写一遍
 * setAttribute('disabled') → .then → .catch → removeAttribute，
 * 重复三份且容易漏掉「失败后不解禁」。
 */
function button(opts) {
	opts = opts || {};
	var theme = opts.theme || 'default';
	var variant = (opts.variant == null) ? 'outline' : opts.variant;

	var b = document.createElement('button');
	b.type = 'button';
	b.className = 'nm-btn nm-btn-' + theme +
		(variant === 'outline' ? ' nm-btn-outline' : '') +
		(variant === 'text' ? ' nm-btn-text' : '') +
		(opts.size ? ' nm-btn-' + opts.size : '');
	if (opts.title) b.title = String(opts.title);

	if (opts.icon)
		b.appendChild(elHtml('span', 'nm-btn-icon', opts.icon));
	b.appendChild(el('span', 'nm-btn-label', opts.label == null ? '' : opts.label));

	if (typeof opts.onClick === 'function') {
		b.addEventListener('click', function () {
			/* 已在请求中则忽略连点，避免并发写同一份配置 */
			if (b.classList.contains('is-busy')) return;
			var r;
			try {
				r = opts.onClick();
			} catch (e) {
				notify(String((e && e.message) || e), 'error');
				return;
			}
			if (!r || typeof r.then !== 'function') return;
			b.classList.add('is-busy');
			setDisabled(b, true);
			r.then(function () { /* 成功不额外提示，由调用点决定 */ })
				.catch(function (e) {
					notify(String((e && e.message) || e), 'error');
				})
				.then(function () {
					b.classList.remove('is-busy');
					setDisabled(b, false);
				});
		});
	}

	setDisabled(b, !!opts.disabled);
	return b;
}

/* 仅图标的方形小按钮（表格操作列用） */
function iconButton(opts) {
	opts = opts || {};
	var b = button({
		label: opts.label == null ? '' : opts.label,
		theme: opts.theme || 'default',
		variant: 'text',
		size: 'sm',
		icon: opts.icon,
		title: opts.title,
		disabled: opts.disabled,
		onClick: opts.onClick
	});
	if (opts.ariaLabel) b.setAttribute('aria-label', String(opts.ariaLabel));
	return b;
}

/* ---------------------------------------------------------------- 标签 */

/*
 * 状态标签。opts: { text, kind, title }
 *   kind: 'ok' | 'warn' | 'bad' | 'idle' | 'info'
 * 替代 t-tag：渲染为 <span class="nm-chip">，样式与等级体系一致。
 */
function chip(opts) {
	opts = opts || {};
	var c = el('span', 'nm-chip nm-chip-' + (opts.kind || 'idle'), opts.text == null ? '' : opts.text);
	if (opts.title) c.title = String(opts.title);
	return c;
}

/* ---------------------------------------------------------------- 提示条 */

/*
 * 横幅提示。opts: { text, kind, icon }
 *   kind: 'info' | 'warning' | 'error' | 'success'
 * 替代 t-alert。
 */
function alertBox(opts) {
	opts = opts || {};
	var kind = opts.kind || 'info';
	var a = el('div', 'nm-alert nm-alert-' + kind);
	a.setAttribute('role', kind === 'error' ? 'alert' : 'status');
	if (opts.icon)
		a.appendChild(elHtml('span', 'nm-alert-icon', opts.icon));
	else
		a.appendChild(el('span', 'nm-alert-dot'));
	a.appendChild(el('span', 'nm-alert-text', opts.text == null ? '' : opts.text));
	return a;
}

/* ---------------------------------------------------------------- 弹窗 */

/*
 * 通用弹窗。替换 t-dialog，也是本次重构的重点。
 *
 * opts: { header, body(HTMLElement), width, ok, cancel, danger, onOk }
 *   body  : HTMLElement，作为弹窗内容区（调用方自备样式）
 *   ok    : 按钮文案；不传则不渲染确认按钮
 *   cancel: 按钮文案，默认「取消」
 *   onOk  : () => any|Promise。返回 false 阻止关闭（用于表单校验失败）
 *
 * 关闭出口统一为 close()，并保证幂等：ESC、取消、遮罩点击、确定按钮
 * 四条路径都走它，且 close 后必定解除 keydown 监听并摘除节点。
 *
 * 相对 t-dialog 的三处关键修正：
 *   1. 挂载点由 document.body 改为调用方传入的 host（默认 document.body）。
 *      挂在 body 上时，LuCI 的 SPA 路由切换只替换 view 容器、不碰 body，
 *      弹窗会带着遮罩永久残留，新页面被完全盖住只能刷 F5。
 *      传入 root 则随路由一起销毁。
 *   2. 显示状态由 class 驱动（.is-open），不再依赖组件内部的动画状态机。
 *      之前的 t-dialog 正是在这里失效：visible=true 没触发进入动画，
 *      组件停在关闭动画的 leave 态，容器 display:none、高度 0。
 *   3. ESC 关闭由本组件自己处理，不依赖第三方组件的 uid 栈。
 */
function dialog(opts) {
	opts = opts || {};
	var host = opts.host || document.body;

	var mask = el('div', 'nm-dlg-mask');
	var box = el('div', 'nm-dlg');
	box.setAttribute('role', 'dialog');
	box.setAttribute('aria-modal', 'true');

	if (opts.width)
		box.style.width = String(opts.width);
	else
		box.style.width = 'min(520px, calc(100vw - 32px))';

	/* 头部 */
	var head = el('div', 'nm-dlg-head');
	var titleId = 'nm-dlg-title-' + (dialog._seq = (dialog._seq || 0) + 1);
	head.appendChild(el('div', 'nm-dlg-title', opts.header == null ? '' : opts.header));
	head.id = titleId;
	box.setAttribute('aria-labelledby', titleId);
	var btnX = el('button', 'nm-dlg-close', '×');
	btnX.type = 'button';
	/* 读屏播报用：与弹窗其他按钮文案一致走 i18n，不硬编码英文 */
	btnX.setAttribute('aria-label', _('Close'));
	head.appendChild(btnX);
	box.appendChild(head);

	/* 内容 */
	var bodyWrap = el('div', 'nm-dlg-body');
	if (opts.body)
		bodyWrap.appendChild(opts.body);
	box.appendChild(bodyWrap);

	/* 底部 */
	var closed = false;
	var releaseFocus = null;
	var hostEl = null;

	function close(result) {
		if (closed) return;
		closed = true;
		if (releaseFocus) {
			releaseFocus();
			releaseFocus = null;
		}
		document.removeEventListener('keydown', onKey, true);
		box.classList.remove('is-open');
		mask.classList.remove('is-open');
		hostEl = null;
		if (box.parentNode) box.parentNode.removeChild(box);
		if (mask.parentNode) mask.parentNode.removeChild(mask);
		if (typeof opts.onClose === 'function') opts.onClose(result);
	}

	function onKey(e) {
		if (!box.isConnected) return;
		if (e.key === 'Escape') {
			e.stopPropagation();
			e.preventDefault();
			close(false);
			return;
		}
		if (e.key !== 'Tab') return;
		/* Tab 循环限制在弹窗内，避免焦点跑到背后页面 */
		var f = box.querySelectorAll(
			'a[href], button:not([disabled]), input:not([disabled]), ' +
			'select:not([disabled]), textarea:not([disabled]), ' +
			'[tabindex]:not([tabindex="-1"])'
		);
		if (!f.length) return;
		var first = f[0], last = f[f.length - 1];
		if (e.shiftKey && document.activeElement === first) {
			e.preventDefault();
			last.focus();
		} else if (!e.shiftKey && document.activeElement === last) {
			e.preventDefault();
			first.focus();
		}
	}

	var foot = null;
	if (opts.ok || opts.cancel !== null) {
		foot = el('div', 'nm-dlg-foot');
		if (opts.ok) {
			foot.appendChild(button({
				label: opts.ok,
				theme: opts.danger ? 'danger' : 'primary',
				onClick: function () {
					var r = (typeof opts.onOk === 'function') ? opts.onOk() : true;
					/* onOk 返回 false 表示校验未通过，保持弹窗打开 */
					if (r === false) return;
					if (r && typeof r.then === 'function') {
						r.then(function () { close(true); }, function () { /* 错误由调用方展示 */ });
						return;
					}
					close(true);
				}
			}));
		}
		if (opts.cancel !== null) {
			foot.appendChild(button({
				label: opts.cancel == null ? _('Cancel') : opts.cancel,
				theme: 'default',
				onClick: function () { close(false); }
			}));
		}
		box.appendChild(foot);
	}

	btnX.addEventListener('click', function () { close(false); });
	mask.addEventListener('click', function () { close(false); });
	document.addEventListener('keydown', onKey, true);

	host.appendChild(mask);
	host.appendChild(box);

	/* 下一帧再加 is-open：与 display:none 的初始态之间插入一次样式重算，
	 * 进场过渡才会正常触发。 */
	window.requestAnimationFrame(function () {
		mask.classList.add('is-open');
		box.classList.add('is-open');
	});

	/* 焦点落点：优先弹窗内第一个可聚焦控件，否则弹窗容器本身 */
	var focusTarget = box.querySelector(
		'input:not([type=hidden]):not([disabled]), select:not([disabled]), textarea:not([disabled])'
	);
	window.setTimeout(function () {
		try { (focusTarget || box).focus(); } catch (e) { /* 容器无 tabindex 时跳过 */ }
	}, 30);

	return {
		root: box,
		body: bodyWrap,
		foot: foot,
		close: close,
		isOpen: function () { return !closed; }
	};
}

/* 确认框：在 dialog 之上的一层薄封装，语义即「肯定 / 否定」。
 * 取代此前基于 window.confirm 与 t-dialog 混用的两套实现。
 *
 * onOk: 仅在用户点了确认按钮时调用（取消 / ESC / 遮罩点击均不调用）。
 * 调用方把真正的副作用（删除目标等）放在 onOk 里，不要放在外层 Promise 链上，
 * 否则用户点「取消」也会执行。
 */
function confirmBox(opts) {
	opts = opts || {};
	var body = el('div', 'nm-confirm-body', opts.message == null ? '' : opts.message);
	return dialog({
		host: opts.host,
		header: opts.header == null ? _('Confirm') : opts.header,
		body: body,
		width: 'min(420px, calc(100vw - 32px))',
		ok: opts.ok == null ? _('OK') : opts.ok,
		cancel: opts.cancel == null ? _('Cancel') : opts.cancel,
		danger: !!opts.danger,
		onOk: function () {
			if (typeof opts.onOk === 'function') opts.onOk();
			return true;
		}
	});
}

return Class.extend({
	__name__: 'NetMonitor.ui',

	el: el,
	elHtml: elHtml,
	esc: esc,
	setDisabled: setDisabled,
	button: button,
	iconButton: iconButton,
	chip: chip,
	alert: alertBox,
	dialog: dialog,
	confirm: confirmBox
});