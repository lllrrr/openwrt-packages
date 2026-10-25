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
 * 因此这里用原生 DOM + 本项目自有样式重建整套 UI 原语：
 * 按钮 / 标签 / 提示条 / 表单控件 / 弹窗 / 面板 / 浮层 / 通知 / 进度。
 * 无外部依赖、无版本漂移、样式与站点主题一致、修复弹窗失效。
 *
 * 【设计系统】本文件是「控件与弹窗交互体系」的唯一实现处：
 *   · 所有度量引用 style.css 的设计 Token（--nm-ctl-h / --nm-radius-ctl
 *     / --nm-dur / --nm-z-* ...），不出现裸数字；
 *   · 所有弹层共用 overlayShell（焦点圈养 / 焦点还原 / 滚动锁 /
 *     Esc / 遮罩 / onBeforeClose 拦截），形态由 matchMedia 在
 *     PC（居中弹窗、右侧抽屉）与窄屏（底部面板）间切换；
 *   · 页面不要自己拼 dialog / select / switch / toast —— 统一从
 *     这里取，保证跨页面一致的外观、键盘行为与无障碍语义。
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

/* 可聚焦元素选择器：Tab 圈养（弹窗 / 面板共用）。
 * 只用到 tag / .class / [attr] 三类简单形式，任何环境都能解析。 */
var FOCUSABLE =
	'a[href], button:not([disabled]), input:not([disabled]), ' +
	'select:not([disabled]), textarea:not([disabled]), ' +
	'[tabindex]:not([tabindex="-1"])';

/* 执行中态：is-busy + aria-busy。
 * 用于「保存中 / 应用中的开关与按钮」——异步操作期间视觉上明确不可再点，
 * 读屏也能读出 busy。CSS 侧 .nm-switch.is-busy 有滑块呼吸动画。 */
function setBusy(node, on) {
	if (!node) return;
	if (on) {
		node.classList.add('is-busy');
		node.setAttribute('aria-busy', 'true');
	} else {
		node.classList.remove('is-busy');
		node.removeAttribute('aria-busy');
	}
}

/* 控件 id：label[for] 与 aria-describedby 都要求控件有稳定 id。
 * 调用方显式传过 id（opts.id）则沿用，这里只兜底生成。 */
var _ctlSeq = 0;
function controlId(node) {
	if (!node.id)
		node.id = 'nm-ctl-' + (++_ctlSeq);
	return node.id;
}

/* 把一段文案变成与控件显式关联的 <label for>。
 *
 * 「标签与输入框明确关联，不以 placeholder 代替标签」——左右分栏的
 * 设置行（标题在左、控件在右）同样需要它：点击标题即聚焦控件，
 * 读屏逐项导航时报出的是标题，而不是光秃秃一个下拉框。
 * 布局由调用方通过 cls 决定，本函数只负责关联这一件事。 */
function bindLabel(text, node, cls) {
	var lb = el('label', cls || '', text == null ? '' : text);
	lb.setAttribute('for', controlId(node));
	return lb;
}

/* 滚动锁：弹窗 / 面板 / 进度面板打开期间锁住背景滚动。
 * 引用计数：允许弹窗上再开弹窗（确认框套在编辑器上），
 * 只有最外层关闭时才解锁。同时补偿滚动条宽度，
 * 避免上锁瞬间页面因滚动条消失而横向跳动。 */
var _scrollLocks = 0;
var _scrollPrev = { overflow: '', paddingRight: '' };

function lockScroll() {
	if (_scrollLocks++ > 0) return;
	var de = document.documentElement;
	/* 非浏览器环境（单测 DOM 桩）没有 style，直接跳过 */
	if (!de || !de.style) return;
	_scrollPrev.overflow = de.style.overflow || '';
	_scrollPrev.paddingRight = de.style.paddingRight || '';
	var sbw = 0;
	if (typeof window.innerWidth === 'number' && typeof de.clientWidth === 'number')
		sbw = Math.max(0, window.innerWidth - de.clientWidth);
	de.style.overflow = 'hidden';
	if (sbw > 0) de.style.paddingRight = sbw + 'px';
}

function unlockScroll() {
	if (--_scrollLocks > 0) return;
	_scrollLocks = 0;
	var de = document.documentElement;
	if (!de || !de.style) return;
	de.style.overflow = _scrollPrev.overflow;
	de.style.paddingRight = _scrollPrev.paddingRight;
}

/* 窄屏判定：所有弹层形态共用一处 matchMedia，避免各写各的断点。 */
function narrowScreen() {
	return (typeof window.matchMedia === 'function')
		? window.matchMedia('(max-width: 768px)') : null;
}

/* 打开时记录当前焦点，关闭时还原：键盘用户不会「弹窗关了，
 * 焦点掉回文档开头，Tab 从头来一遍」。返回释放函数。
 * 焦点源已被摘除（打开弹窗的那一行刚好被重绘）时跳过还原。 */
function captureFocus() {
	var prev = document.activeElement;
	return function () {
		if (prev && prev !== document.body && prev.isConnected !== false &&
			typeof prev.focus === 'function') {
			try { prev.focus(); } catch (e) { /* 节点已不可聚焦时忽略 */ }
		}
	};
}

/*
 * 模态外壳：dialog() 与 panel() 共用的骨架。
 * 弹层共有的模态语义全部收在这里，形态差异由调用方注入：
 *   o.box / o.mask   形态容器与遮罩（调用方已加好形态类名）
 *   o.host           挂载点（默认 document.body）
 *   o.mq / o.syncForm 窄屏形态监听（可省略）
 *   o.maskClose      遮罩点击是否触发 dismiss，默认 true
 *   o.onBeforeClose  dismiss 路径的拦截钩子（未保存确认）
 *   o.onClose        真正关闭后的回调
 *   o.focusSel       初始焦点选择器，找不到则聚焦容器本身
 * 返回 { close, requestClose, isOpen }。
 */
function overlayShell(o) {
	var box = o.box, mask = o.mask, host = o.host || document.body;
	var closed = false;
	var releaseFocus = null;

	function close(result) {
		if (closed) return;
		closed = true;
		if (releaseFocus) {
			releaseFocus();
			releaseFocus = null;
		}
		document.removeEventListener('keydown', onKey, true);
		if (o.mq && typeof o.mq.removeEventListener === 'function' && o.syncForm)
			o.mq.removeEventListener('change', o.syncForm);
		box.classList.remove('is-open');
		mask.classList.remove('is-open');
		unlockScroll();
		if (box.parentNode) box.parentNode.removeChild(box);
		if (mask.parentNode) mask.parentNode.removeChild(mask);
		if (typeof o.onClose === 'function') o.onClose(result);
	}

	/* dismiss 路径（ESC / 遮罩 / 关闭按钮 / 取消按钮）的统一出口：
	 * onBeforeClose 可以拦一道（「有未保存修改，确定丢弃？」），
	 * 返回 false 或 resolve(false) 都不关，其余情况才真正 close。 */
	function requestClose(result) {
		if (closed) return;
		if (typeof o.onBeforeClose === 'function') {
			var r;
			try {
				r = o.onBeforeClose(result);
			} catch (e) {
				close(result);
				return;
			}
			if (r === false) return;
			if (r && typeof r.then === 'function') {
				r.then(function (ok) {
					if (ok !== false) close(result);
				}, function () {
					close(result);
				});
				return;
			}
		}
		close(result);
	}

	function onKey(e) {
		if (!box.isConnected) return;
		if (e.key === 'Escape') {
			e.stopPropagation();
			e.preventDefault();
			requestClose(false);
			return;
		}
		if (e.key !== 'Tab') return;
		/* Tab 循环限制在弹窗内，避免焦点跑到背后页面。
		 * 每次按键实时查询：弹窗内容可能是异步填充的，不做缓存。 */
		var f = box.querySelectorAll(FOCUSABLE);
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

	document.addEventListener('keydown', onKey, true);
	if (o.maskClose !== false)
		mask.addEventListener('click', function () { requestClose(false); });

	lockScroll();
	host.appendChild(mask);
	host.appendChild(box);
	releaseFocus = captureFocus();

	/* 下一帧再加 is-open：与 display:none 的初始态之间插入一次样式重算，
	 * 进场过渡才会正常触发。 */
	window.requestAnimationFrame(function () {
		mask.classList.add('is-open');
		box.classList.add('is-open');
	});

	window.setTimeout(function () {
		try {
			var t = (o.focusSel && box.querySelector(o.focusSel)) || box;
			t.focus();
		} catch (e) { /* 容器无 tabindex 时跳过 */ }
	}, 30);

	return {
		close: close,
		requestClose: requestClose,
		isOpen: function () { return !closed; }
	};
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
	/* 可见文案是符号（↑ / ↓ / ×）时，用 aria-label 给出可读的无障碍名称。
	 * targets 的行内操作一直传这个参数，此前只有 iconButton 处理、
	 * button 静默丢弃——五个行内按钮的全部可访问名称只剩一个箭头字符。 */
	if (opts.ariaLabel) b.setAttribute('aria-label', String(opts.ariaLabel));

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
				/* 错误提示走本模块的 toast：此前这里调用的是一个
				 * 从未定义的全局 notify，按钮出错时用户看不到任何提示 */
				toast(String((e && e.message) || e), 'error');
				return;
			}
			if (!r || typeof r.then !== 'function') return;
			/* busy 态统一走 setBusy：is-busy + aria-busy 一起给，
			 * 读屏能读出「执行中」而不只是视觉上变灰 */
			setBusy(b, true);
			setDisabled(b, true);
			r.then(function () { /* 成功不额外提示，由调用点决定 */ })
				.catch(function (e) {
					toast(String((e && e.message) || e), 'error');
				})
				.then(function () {
					setBusy(b, false);
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

/* ---------------------------------------------------------------- 表单控件 */

/*
 * 字段包裹：<label for> + 控件 + 说明 + 错误行，一次配齐关联关系。
 * 取代各页面自己拼 label / 自己命名 id / 自己摆错误文案的写法
 * （targets.js 编辑器里那份本地 field() 即由此取代）。
 *
 * opts: { desc }
 *   desc: 控件下方的补充说明（同样经 aria-describedby 关联）
 *
 * 返回的包裹节点上挂着一个 setError(msg) 方法：
 *   setError('')      清空错误、移除 aria-invalid
 *   setError('必填')  写入错误行、控件打上 aria-invalid="true"
 * 错误行经 aria-describedby 与控件关联，读屏聚焦控件时会播报；
 * 边框 + 聚焦环 + 文字三处同时变化，不只靠颜色区分。
 *
 * 左右分栏的长表单行（设置页）不需要本函数：用 bindLabel 把行标题
 * 变成 <label for> 即可，布局沿用页面既有结构。
 */
function field(labelText, node, opts) {
	opts = opts || {};
	var f = el('div', 'nm-field');

	var id = controlId(node);
	var lb = el('label', 'nm-field-label', labelText == null ? '' : labelText);
	lb.setAttribute('for', id);
	f.appendChild(lb);
	f.appendChild(node);

	var described = [];
	if (opts.desc) {
		var d = el('div', 'nm-field-desc', opts.desc);
		d.id = id + '-desc';
		described.push(d.id);
		f.appendChild(d);
	}
	var err = el('div', 'nm-field-err', '');
	err.id = id + '-err';
	described.push(err.id);
	f.appendChild(err);
	node.setAttribute('aria-describedby', described.join(' '));

	f.setError = function (msg) {
		err.textContent = (msg == null || msg === '') ? '' : String(msg);
		if (msg) node.setAttribute('aria-invalid', 'true');
		else node.removeAttribute('aria-invalid');
	};
	return f;
}

/*
 * 文本输入框。.nm-ctl 基线：40px 高（移动端 44px）、聚焦环、
 * 禁用态、错误态一次定义齐。
 * opts: { value, placeholder, maxlength, pattern, inputmode, autocomplete,
 *         spellcheck, ariaLabel, disabled, width, id, type }
 */
function textInput(opts) {
	opts = opts || {};
	var i = el('input', 'nm-ctl');
	i.type = opts.type || 'text';
	if (opts.id) i.id = String(opts.id);
	if (opts.value != null) i.value = String(opts.value);
	if (opts.placeholder) i.setAttribute('placeholder', String(opts.placeholder));
	if (opts.maxlength != null) i.setAttribute('maxlength', String(opts.maxlength));
	if (opts.pattern) i.setAttribute('pattern', String(opts.pattern));
	if (opts.inputmode) i.setAttribute('inputmode', String(opts.inputmode));
	if (opts.autocomplete) i.setAttribute('autocomplete', String(opts.autocomplete));
	if (opts.spellcheck === false) i.setAttribute('spellcheck', 'false');
	if (opts.ariaLabel) i.setAttribute('aria-label', String(opts.ariaLabel));
	if (opts.width) i.style.width = String(opts.width);
	if (opts.disabled) setDisabled(i, true);
	return i;
}

/* 数字输入框。注意 min/max 只是原生校验提示，用户键入越界值
 * 不会被拦下，读取时仍要显式钳位（参见 targets.js 的 intOf）。 */
function numberInput(opts) {
	opts = opts || {};
	var n = textInput({
		type: 'number',
		id: opts.id,
		value: opts.value,
		placeholder: opts.placeholder,
		ariaLabel: opts.ariaLabel,
		disabled: opts.disabled,
		width: opts.width
	});
	if (opts.min != null) n.min = String(opts.min);
	if (opts.max != null) n.max = String(opts.max);
	if (opts.step != null) n.step = String(opts.step);
	/* 手机上弹起纯数字键盘而不是全键盘 */
	n.setAttribute('inputmode', opts.inputmode || 'numeric');
	return n;
}

/* 多行文本（备注 / 描述）。opts 同 textInput，另支持 rows。 */
function textareaInput(opts) {
	opts = opts || {};
	var t = el('textarea', 'nm-ctl');
	if (opts.id) t.id = String(opts.id);
	if (opts.value != null) t.value = String(opts.value);
	if (opts.placeholder) t.setAttribute('placeholder', String(opts.placeholder));
	if (opts.maxlength != null) t.setAttribute('maxlength', String(opts.maxlength));
	if (opts.rows != null) t.rows = opts.rows;
	if (opts.ariaLabel) t.setAttribute('aria-label', String(opts.ariaLabel));
	if (opts.disabled) setDisabled(t, true);
	return t;
}

/*
 * 下拉框（.nm-ctl 基线）。
 * options: [{ label, value, disabled }]
 * 当前值不在选项里时（旧配置 / 后端新增了选项）补一个「当前值」兜底项，
 * 否则 select.value 赋值落空，界面显示空白而实际值未变——
 * 五个页面各写一遍的这个兜底，收敛到这一处。
 */
function selectInput(options, value, opts) {
	opts = opts || {};
	var sel = el('select', 'nm-ctl');
	if (opts.id) sel.id = String(opts.id);
	var cur = (value == null) ? '' : String(value);
	var found = false;
	(options || []).forEach(function (o) {
		var opt = el('option', '', o.label == null ? '' : o.label);
		opt.value = (o.value == null) ? '' : String(o.value);
		if (o.disabled) opt.disabled = true;
		sel.appendChild(opt);
		if (opt.value === cur) found = true;
	});
	if (!found && cur !== '') {
		var optCur = el('option', '', cur + ' ' + _('(current)'));
		optCur.value = cur;
		sel.appendChild(optCur);
	}
	sel.value = cur;
	if (opts.ariaLabel) sel.setAttribute('aria-label', String(opts.ariaLabel));
	if (opts.disabled) setDisabled(sel, true);
	return sel;
}

/*
 * 开关：44×26 圆角轨道 + 圆形滑块，四态齐备。
 *   on / off      checked（原生 checkbox 保留 Space 键切换与表单语义）
 *   busy          setBusy(node, true) → is-busy + aria-busy（滑块呼吸）
 *   disabled      setDisabled
 * role="switch"：读屏播报「开关」而非「复选框」，与视觉语义一致。
 */
function switchControl(opts) {
	opts = opts || {};
	var sw = el('input', 'nm-switch');
	sw.type = 'checkbox';
	sw.setAttribute('role', 'switch');
	if (opts.id) sw.id = String(opts.id);
	sw.checked = !!opts.checked;
	if (opts.ariaLabel) sw.setAttribute('aria-label', String(opts.ariaLabel));
	if (opts.disabled) setDisabled(sw, true);
	return sw;
}

/* 勾选框 / 单选框：label 包住 input + 文本，点击文字即切换。
 * 返回 label 节点；原生 label.control 属性即取到内部 input。 */
function checkControl(opts) {
	opts = opts || {};
	var lb = el('label', 'nm-check');
	var cb = el('input', '');
	cb.type = (opts.type === 'radio') ? 'radio' : 'checkbox';
	if (opts.name) cb.name = String(opts.name);
	if (opts.value != null) cb.value = String(opts.value);
	cb.checked = !!opts.checked;
	if (opts.ariaLabel) cb.setAttribute('aria-label', String(opts.ariaLabel));
	lb.appendChild(cb);
	lb.appendChild(el('span', '', opts.label == null ? '' : opts.label));
	if (opts.disabled) setDisabled(cb, true);
	return lb;
}

/* 单选组：同一 name 的方向键切换由浏览器保证，这里只负责装配与取值。 */
function radioGroup(opts) {
	opts = opts || {};
	var name = opts.name || ('nm-radio-' + (++_ctlSeq));
	var box = el('div', 'nm-radio-group');
	box.setAttribute('role', 'radiogroup');
	if (opts.ariaLabel) box.setAttribute('aria-label', String(opts.ariaLabel));
	(opts.options || []).forEach(function (o) {
		box.appendChild(checkControl({
			type: 'radio',
			name: name,
			label: o.label,
			value: o.value,
			checked: String(o.value) === String(opts.value),
			disabled: !!o.disabled
		}));
	});
	box.addEventListener('change', function () {
		var sel = box.querySelector('input:checked');
		if (typeof opts.onChange === 'function')
			opts.onChange(sel ? sel.value : null);
	});
	return box;
}

/* 分段控制：2–5 个互斥选项全部可见、一步切换，比下拉少一次点按。
 * 用 button[aria-pressed] 而不是 input[radio]：分段控制的视觉是
 * 「一组按钮」而不是「一排圆点」，且便于放图标。 */
function segmented(opts) {
	opts = opts || {};
	var box = el('div', 'nm-seg');
	box.setAttribute('role', 'group');
	if (opts.ariaLabel) box.setAttribute('aria-label', String(opts.ariaLabel));
	var items = [];
	(opts.options || []).forEach(function (o) {
		var b = el('button', 'nm-seg-item', o.label == null ? '' : o.label);
		b.type = 'button';
		var on = String(o.value) === String(opts.value);
		if (on) b.classList.add('is-on');
		b.setAttribute('aria-pressed', String(on));
		if (o.disabled || opts.disabled) setDisabled(b, true);
		b.addEventListener('click', function () {
			if (opts.disabled || o.disabled) return;
			items.forEach(function (it) {
				var cur = (it.value === o.value);
				it.btn.classList.toggle('is-on', cur);
				it.btn.setAttribute('aria-pressed', String(cur));
			});
			if (typeof opts.onChange === 'function') opts.onChange(o.value);
		});
		items.push({ value: o.value, btn: b });
		box.appendChild(b);
	});
	return box;
}

/* ---------------------------------------------------------------- 弹窗 */

/*
 * 通用弹窗。替换 t-dialog，也是本次重构的重点。
 *
 * opts: { header, body(HTMLElement), width, ok, cancel, danger, onOk,
 *         onBeforeClose, maskClose, host }
 *   body  : HTMLElement，作为弹窗内容区（调用方自备样式）
 *   ok    : 按钮文案；不传则不渲染确认按钮
 *   cancel: 按钮文案，默认「取消」
 *   onOk  : () => any|Promise。返回 false 阻止关闭（表单校验失败）；
 *           返回 Promise 时确认按钮自动进入 busy + 禁用态
 *           （连点不再重复提交），resolve 后关闭，reject 时保持打开、
 *           错误由调用方展示。
 *   onBeforeClose: (result) => any|Promise。取消 / ESC / 遮罩三条
 *           dismiss 路径关闭前调用；返回 false 阻止关闭
 *           （「有未保存修改，确定丢弃？」就挂这里）。
 *   maskClose: 点击遮罩是否触发 dismiss，默认 true；
 *           危险确认框（confirmBox danger）默认 false——
 *           误点遮罩等于误确认破坏性操作，不可接受。
 *   host  : 挂载点，默认 document.body。传页面 root 可随路由销毁。
 *
 * 关闭出口统一为 close()，并保证幂等：ESC、取消、遮罩、确认按钮
 * 四条路径都走它，且 close 后必定解除 keydown 监听、还原焦点、
 * 解锁背景滚动并摘除节点。
 *
 * 窄屏（<=768px）自动切底部面板形态（.is-sheet）：内容排列、滚动与
 * 操作区在两种形态下是不同结构，不是把 PC 框缩小了事。形态由
 * matchMedia 判定，视口变化时跟随切换。
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

	/* 窄屏底部形态：matchMedia 判定，视口变化时跟随切换 */
	var mq = narrowScreen();
	function syncForm() {
		if (mq) box.classList.toggle('is-sheet', !!mq.matches);
	}
	syncForm();
	if (mq && typeof mq.addEventListener === 'function')
		mq.addEventListener('change', syncForm);

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
	var foot = null;
	var okBtn = null;
	if (opts.ok || opts.cancel !== null) {
		foot = el('div', 'nm-dlg-foot');
		if (opts.ok) {
			okBtn = button({
				label: opts.ok,
				theme: opts.danger ? 'danger' : 'primary',
				onClick: function () {
					/* 异步提交中忽略连点：onOk 返回 Promise 期间按钮
					 * 已 busy + disabled，这里是双保险 */
					if (okBtn.classList.contains('is-busy')) return;
					var r = (typeof opts.onOk === 'function') ? opts.onOk() : true;
					/* onOk 返回 false 表示校验未通过，保持弹窗打开 */
					if (r === false) return;
					if (r && typeof r.then === 'function') {
						/* 按钮 busy：整段提交期间不可再点，成功才关闭，
						 * 失败保持打开让用户改了重试（按钮恢复可用） */
						setBusy(okBtn, true);
						setDisabled(okBtn, true);
						r.then(function () { shell.close(true); },
							function () { /* 错误由调用方展示 */ })
							.then(function () {
								setBusy(okBtn, false);
								setDisabled(okBtn, false);
							});
						return;
					}
					shell.close(true);
				}
			});
			foot.appendChild(okBtn);
		}
		if (opts.cancel !== null) {
			foot.appendChild(button({
				label: opts.cancel == null ? _('Cancel') : opts.cancel,
				theme: 'default',
				onClick: function () { shell.requestClose(false); }
			}));
		}
		box.appendChild(foot);
	}

	btnX.addEventListener('click', function () { shell.requestClose(false); });

	var shell = overlayShell({
		box: box,
		mask: mask,
		host: host,
		mq: mq,
		syncForm: syncForm,
		maskClose: opts.maskClose,
		onBeforeClose: opts.onBeforeClose,
		onClose: opts.onClose,
		focusSel: 'input:not([type=hidden]):not([disabled]), select:not([disabled]), textarea:not([disabled])'
	});

	return {
		root: box,
		mask: mask,
		body: bodyWrap,
		foot: foot,
		okButton: okBtn,
		close: shell.close,
		requestClose: shell.requestClose,
		isOpen: shell.isOpen
	};
}

/* 确认框：在 dialog 之上的一层薄封装，语义即「肯定 / 否定」。
 * 取代此前基于 window.confirm 与 t-dialog 混用的两套实现。
 *
 * onOk: 仅在用户点了确认按钮时调用（取消 / ESC / 遮罩点击均不调用）。
 * 调用方把真正的副作用（删除目标等）放在 onOk 里，不要放在外层 Promise 链上，
 * 否则用户点「取消」也会执行。
 *
 * danger: true 时确认按钮用危险色，且遮罩点击默认不再关闭
 * （只保留取消 / 关闭按钮 / ESC 三条明确退出路径）。
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
		maskClose: opts.maskClose != null ? !!opts.maskClose : !opts.danger,
		onOk: function () {
			if (typeof opts.onOk === 'function') opts.onOk();
			return true;
		},
		onBeforeClose: opts.onBeforeClose,
		onClose: opts.onClose
	});
}

/* ---------------------------------------------------------------- 面板 */

/*
 * 抽屉 / 底部面板：设备详情、复杂配置等「重内容、需要保留背景上下文」
 * 的场景。与 dialog 的区别：不整体置灰阻断，允许更宽的内容。
 *
 * opts: { header, body(HTMLElement), foot(HTMLElement), width, host,
 *         maskClose, onBeforeClose, onClose }
 *   width: PC 抽屉宽度，默认 min(520px, 94vw)（400–560 区间）
 *   foot : HTMLElement，操作区（按钮组）
 *
 * 形态由 matchMedia 决定：PC 右侧滑入（.is-drawer），窄屏底部面板
 * （.is-sheet，含安全区内边距与链式滚动抑制）。模态语义（焦点圈养 /
 * Esc / 遮罩 / 滚动锁 / 焦点还原）与 dialog 共用 overlayShell。
 */
function panel(opts) {
	opts = opts || {};
	var host = opts.host || document.body;

	var mask = el('div', 'nm-dlg-mask');
	var box = el('div', 'nm-panel');

	/* 形态：PC 右侧抽屉 / 窄屏底部面板 */
	var mq = narrowScreen();
	function syncForm() {
		if (!mq) return;
		var sheet = !!mq.matches;
		box.classList.toggle('is-sheet', sheet);
		box.classList.toggle('is-drawer', !sheet);
	}
	syncForm();
	if (!mq) box.classList.add('is-drawer');
	if (mq && typeof mq.addEventListener === 'function')
		mq.addEventListener('change', syncForm);

	if (opts.width)
		box.style.width = String(opts.width);
	else
		box.style.width = 'min(520px, 94vw)';

	box.setAttribute('role', 'dialog');
	box.setAttribute('aria-modal', 'true');

	/* 头部 */
	var head = el('div', 'nm-panel-head');
	var titleId = 'nm-panel-title-' + (panel._seq = (panel._seq || 0) + 1);
	var title = el('div', 'nm-panel-title', opts.header == null ? '' : opts.header);
	title.id = titleId;
	head.appendChild(title);
	box.setAttribute('aria-labelledby', titleId);
	var btnX = el('button', 'nm-dlg-close', '×');
	btnX.type = 'button';
	btnX.setAttribute('aria-label', _('Close'));
	head.appendChild(btnX);
	box.appendChild(head);

	/* 内容（可滚动，overscroll-behavior 抑制穿透） */
	var bodyWrap = el('div', 'nm-panel-body');
	if (opts.body) bodyWrap.appendChild(opts.body);
	box.appendChild(bodyWrap);

	/* 操作区 */
	var foot = null;
	if (opts.foot) {
		foot = el('div', 'nm-panel-foot');
		foot.appendChild(opts.foot);
		box.appendChild(foot);
	}

	btnX.addEventListener('click', function () { shell.requestClose(false); });

	var shell = overlayShell({
		box: box,
		mask: mask,
		host: host,
		mq: mq,
		syncForm: syncForm,
		maskClose: opts.maskClose,
		onBeforeClose: opts.onBeforeClose,
		onClose: opts.onClose,
		focusSel: 'input:not([type=hidden]):not([disabled]), select:not([disabled]), textarea:not([disabled])'
	});

	return {
		root: box,
		mask: mask,
		body: bodyWrap,
		foot: foot,
		close: shell.close,
		requestClose: shell.requestClose,
		isOpen: shell.isOpen
	};
}

/* ---------------------------------------------------------------- 浮层 */

/*
 * 悬浮菜单：锚点 + 一组操作项，自动选择展开方向。
 *
 * opts: { title, items, host, prefer, ariaLabel }
 *   items: [{ label, kind: 'danger', disabled, onClick }]，
 *          { sep: true } 插入分隔线；危险项用语义红并与普通项分组。
 *   prefer: 'bottom'（默认） | 'top' | 'right' | 'left'
 *
 * 方向不是写死的 CSS 类：挂载后实测锚点与浮层各自的 rect，
 * 空间不足自动翻到对侧（下方不够翻上方、右侧不够翻左侧）。
 * 关闭：Esc / 点击浮层外 / 点任一操作项。
 */
function popover(anchor, opts) {
	opts = opts || {};
	var host = opts.host || document.body;

	var pop = el('div', 'nm-pop');
	pop.setAttribute('role', 'menu');
	if (opts.ariaLabel) pop.setAttribute('aria-label', String(opts.ariaLabel));

	if (opts.title)
		pop.appendChild(el('div', 'nm-pop-title', opts.title));

	var items = [];
	(opts.items || []).forEach(function (o) {
		if (o.sep) {
			pop.appendChild(el('div', 'nm-pop-sep'));
			return;
		}
		var b = el('button', 'nm-pop-item' + (o.kind === 'danger' ? ' is-danger' : ''),
			o.label == null ? '' : o.label);
		b.type = 'button';
		b.setAttribute('role', 'menuitem');
		if (o.disabled) setDisabled(b, true);
		b.addEventListener('click', function () {
			if (o.disabled) return;
			close();
			if (typeof o.onClick === 'function') o.onClick();
		});
		items.push(b);
		pop.appendChild(b);
	});

	var closed = false;
	var releaseFocus = null;

	function onDocKey(e) {
		if (e.key !== 'Escape') return;
		e.stopPropagation();
		e.preventDefault();
		close();
	}
	function onDocDown(e) {
		/* 点在锚点或浮层内都不关 */
		var t = e.target;
		if (!t) return;
		if (typeof pop.contains === 'function' && pop.contains(t)) return;
		if (anchor && typeof anchor.contains === 'function' && anchor.contains(t)) return;
		close();
	}

	function close() {
		if (closed) return;
		closed = true;
		document.removeEventListener('keydown', onDocKey, true);
		document.removeEventListener('mousedown', onDocDown, true);
		if (releaseFocus) {
			releaseFocus();
			releaseFocus = null;
		}
		if (pop.parentNode) pop.parentNode.removeChild(pop);
	}

	host.appendChild(pop);
	releaseFocus = captureFocus();
	placePopover(pop, anchor, opts.prefer || 'bottom');
	document.addEventListener('keydown', onDocKey, true);
	document.addEventListener('mousedown', onDocDown, true);

	window.setTimeout(function () {
		try { (items[0] || pop).focus(); } catch (e) { /* 无 tabindex 时跳过 */ }
	}, 30);

	return {
		root: pop,
		close: close,
		isOpen: function () { return !closed; }
	};
}

/* 浮层定位：实测 rect 后决定方向，空间不足自动翻转。 */
function placePopover(pop, anchor, prefer) {
	var ar = (anchor && typeof anchor.getBoundingClientRect === 'function')
		? anchor.getBoundingClientRect()
		: { left: 0, top: 0, right: 0, bottom: 0, width: 0, height: 0 };
	var pr = (typeof pop.getBoundingClientRect === 'function')
		? pop.getBoundingClientRect()
		: { width: 160, height: 80 };
	var vw = (typeof window.innerWidth === 'number') ? window.innerWidth : 0;
	var vh = (typeof window.innerHeight === 'number') ? window.innerHeight : 0;
	var gap = 6;
	var top = 0, left = 0;

	if (prefer === 'right' || prefer === 'left') {
		var toRight = (prefer === 'right');
		if (toRight && ar.right + gap + pr.width > vw && ar.left - gap - pr.width > 0)
			toRight = false;
		if (!toRight && ar.left - gap - pr.width < 0 && ar.right + gap + pr.width < vw)
			toRight = true;
		left = toRight ? (ar.right + gap) : (ar.left - gap - pr.width);
		top = ar.top;
		if (top + pr.height > vh) top = Math.max(0, vh - pr.height);
	} else {
		var toBottom = (prefer !== 'top');
		if (toBottom && ar.bottom + gap + pr.height > vh && ar.top - gap - pr.height > 0)
			toBottom = false;
		if (!toBottom && ar.top - gap - pr.height < 0 && ar.bottom + gap + pr.height < vh)
			toBottom = true;
		top = toBottom ? (ar.bottom + gap) : (ar.top - gap - pr.height);
		left = ar.left;
		if (left + pr.width > vw) left = Math.max(0, vw - pr.width);
	}

	pop.style.position = 'fixed';
	pop.style.left = Math.round(left) + 'px';
	pop.style.top = Math.round(top) + 'px';
}

/* ---------------------------------------------------------------- 通知 */

/*
 * 轻通知：PC 右上角、移动端底部 Snackbar，四级语义。
 * kind: 'info' | 'success' | 'warn' | 'error'（warning 归并到 warn）。
 *
 * 三条硬规则：
 *   1. 队列去重：同文案 + 同等级 2 秒内重复出现，只刷新既有那条的
 *      计时，不叠出第二面墙（轮询失败会每轮都触发，不处理直接刷屏）。
 *   2. 同屏上限 4 条：超出时最旧的一条立刻退场，保证最新消息可见。
 *   3. 手动关闭：每条都带 ×；错误类停留更久。
 *
 * 挂在 document.body 上：LuCI 的 SPA 路由切换只替换 view 容器，
 * 「保存成功」不该因为切个页就消失。
 *
 * 取代 widgets.js 里基于 LuCI ui.addNotification + 未定义全局 E 的
 * 旧实现——那条路径实际永远走 catch 落 console，用户根本看不到提示。
 */
var TOAST_DEDUP_MS = 2000;
var TOAST_MAX = 4;
var TOAST_TTL = { info: 3200, success: 3200, warn: 4200, error: 5200 };

var _toastHost = null;
var _toastLive = {};

function toastHostEl() {
	if (!_toastHost || !_toastHost.isConnected) {
		_toastHost = el('div', 'nm-toast-host');
		_toastHost.setAttribute('role', 'region');
		/* aria-live：新通知自动播报，不抢焦点 */
		_toastHost.setAttribute('aria-live', 'polite');
		document.body.appendChild(_toastHost);
	}
	return _toastHost;
}

function toast(msg, kind, opts) {
	opts = opts || {};
	var k = (kind === 'success' || kind === 'warn' || kind === 'error') ? kind : 'info';
	var text = (msg == null) ? '' : String(msg);
	var host = toastHostEl();

	/* 去重：刷新既有通知的计时而不是新开一条 */
	var key = k + '|' + text;
	var live = _toastLive[key];
	if (live) {
		if (live.timer) clearTimeout(live.timer);
		scheduleDismiss(key);
		return live.node;
	}

	var node = el('div', 'nm-toast nm-toast-' + k);
	node.setAttribute('role', k === 'error' ? 'alert' : 'status');
	node.appendChild(el('span', 'nm-toast-dot'));
	node.appendChild(el('div', 'nm-toast-text', text));
	var btnX = el('button', 'nm-toast-x', '×');
	btnX.type = 'button';
	btnX.setAttribute('aria-label', _('Close'));
	btnX.addEventListener('click', function () { dismissToast(key); });
	node.appendChild(btnX);
	host.appendChild(node);

	_toastLive[key] = { node: node, timer: null };

	/* 同屏上限：挤出最旧的一条 */
	var keys = Object.keys(_toastLive);
	while (keys.length > TOAST_MAX) {
		dismissToast(keys[0]);
		keys = Object.keys(_toastLive);
	}

	scheduleDismiss(key);
	return node;
}

function scheduleDismiss(key) {
	var entry = _toastLive[key];
	if (!entry) return;
	var k = key.split('|')[0];
	var ttl = (typeof TOAST_TTL[k] === 'number') ? TOAST_TTL[k] : TOAST_TTL.info;
	/* 用全局 setTimeout 而非 window.setTimeout：单测的 window 桩会
	 * 同步执行回调，那会让通知一创建就被立刻销毁，无法断言结构 */
	entry.timer = setTimeout(function () { dismissToast(key); }, ttl);
}

function dismissToast(key) {
	var entry = _toastLive[key];
	if (!entry) return;
	if (entry.timer) clearTimeout(entry.timer);
	delete _toastLive[key];
	var node = entry.node;
	if (!node || !node.parentNode) return;
	node.classList.add('is-leaving');
	setTimeout(function () {
		if (node.parentNode) node.parentNode.removeChild(node);
	}, 160); /* 退场动画时长，与 --nm-dur-fast 对齐 */
}

/* ---------------------------------------------------------------- 进度 */

/*
 * 模态进度面板：服务重启、批量应用更改这类「确实需要阻止其他交互」
 * 的操作。轻量的按钮内加载态请用 setBusy，不要动不动弹这个。
 *
 * opts: { title, stage, host, dismissible, indeterminate, value, pctText }
 *   dismissible: false（默认）时遮罩与 Esc 都不能关——进度没走完
 *           就关掉，用户不知道后台还在干什么。
 *   indeterminate: 不确定进度（条纹往复）。
 *
 * 禁假进度：indeterminate 只用于「确实不知道总进度」的场景；
 * determinate 的百分比必须来自真实进度回调 setValue()，
 * 不许拿定时器演动画——那是欺骗用户。
 *
 * 返回 { setStage, setValue, setIndeterminate, finish, addAction,
 *        close, isOpen }。finish('ok'|'bad', text) 落终态。
 */
function progress(opts) {
	opts = opts || {};
	var host = opts.host || document.body;

	var mask = el('div', 'nm-prog-mask');
	var box = el('div', 'nm-prog');
	var titleId = 'nm-prog-title-' + (progress._seq = (progress._seq || 0) + 1);
	box.setAttribute('role', 'dialog');
	box.setAttribute('aria-modal', 'true');
	box.setAttribute('aria-labelledby', titleId);

	var title = el('div', 'nm-prog-title', opts.title == null ? '' : opts.title);
	title.id = titleId;
	box.appendChild(title);

	var stage = el('div', 'nm-prog-stage', opts.stage == null ? '' : opts.stage);
	box.appendChild(stage);

	var track = el('div', 'nm-prog-track');
	var bar = el('div', 'nm-prog-bar');
	track.appendChild(bar);
	box.appendChild(track);

	var pct = el('div', 'nm-prog-pct', '');
	box.appendChild(pct);

	var acts = el('div', 'nm-prog-acts');
	box.appendChild(acts);

	var closed = false;
	var finished = false;

	function close() {
		if (closed) return;
		closed = true;
		document.removeEventListener('keydown', onKey, true);
		unlockScroll();
		mask.classList.remove('is-open');
		if (box.parentNode) box.parentNode.removeChild(box);
		if (mask.parentNode) mask.parentNode.removeChild(mask);
	}

	function onKey(e) {
		if (e.key !== 'Escape' || !opts.dismissible) return;
		e.stopPropagation();
		e.preventDefault();
		close();
	}

	function setStage(text) {
		if (finished) return;
		stage.textContent = text == null ? '' : String(text);
	}

	function setValue(v) {
		if (finished) return;
		box.classList.remove('is-indeterminate');
		var n = Math.max(0, Math.min(100, Number(v) || 0));
		bar.style.width = n + '%';
		pct.textContent = Math.round(n) + '%';
	}

	function setIndeterminate(text) {
		if (finished) return;
		box.classList.add('is-indeterminate');
		bar.style.width = '';
		pct.textContent = text == null ? '' : String(text);
	}

	/* 终态：ok / bad，颜色 + 文案 + 满条三重区分 */
	function finish(state, text) {
		finished = true;
		box.classList.remove('is-indeterminate');
		if (state === 'ok') {
			box.classList.add('is-ok');
			bar.style.width = '100%';
			pct.textContent = '100%';
		} else if (state === 'bad') {
			box.classList.add('is-bad');
			bar.style.width = '100%';
		}
		if (text != null) stage.textContent = String(text);
	}

	function addAction(label, fn, theme) {
		var b = button({
			label: label,
			theme: theme || 'default',
			onClick: function () {
				var r = fn();
				if (r && typeof r.then === 'function') {
					setBusy(b, true);
					setDisabled(b, true);
					r.catch(function (e) { toast(String((e && e.message) || e), 'error'); })
						.then(function () { setBusy(b, false); setDisabled(b, false); });
				}
			}
		});
		acts.appendChild(b);
		return b;
	}

	mask.addEventListener('click', function () {
		if (opts.dismissible) close();
	});
	document.addEventListener('keydown', onKey, true);
	lockScroll();
	host.appendChild(mask);
	host.appendChild(box);
	window.requestAnimationFrame(function () { mask.classList.add('is-open'); });

	if (opts.indeterminate) setIndeterminate(opts.pctText);
	else if (opts.value != null) setValue(opts.value);

	return {
		root: box,
		mask: mask,
		stage: stage,
		setStage: setStage,
		setValue: setValue,
		setIndeterminate: setIndeterminate,
		finish: finish,
		addAction: addAction,
		close: close,
		isOpen: function () { return !closed; }
	};
}

return Class.extend({
	__name__: 'NetMonitor.ui',

	/* ---- 基础工具 ---- */
	el: el,
	elHtml: elHtml,
	esc: esc,
	setDisabled: setDisabled,
	setBusy: setBusy,
	bindLabel: bindLabel,

	/* ---- 按钮 / 标签 / 提示条 ---- */
	button: button,
	iconButton: iconButton,
	chip: chip,
	alert: alertBox,

	/* ---- 表单控件（.nm-ctl / .nm-switch / .nm-check / .nm-seg 基线） ---- */
	field: field,
	textInput: textInput,
	numberInput: numberInput,
	textareaInput: textareaInput,
	selectInput: selectInput,
	switchControl: switchControl,
	checkControl: checkControl,
	radioGroup: radioGroup,
	segmented: segmented,

	/* ---- 弹窗 / 面板 / 浮层 / 通知 / 进度 ---- */
	dialog: dialog,
	confirm: confirmBox,
	panel: panel,
	popover: popover,
	toast: toast,
	progress: progress
});