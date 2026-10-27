'use strict';
/*
 * smwform —— 表单控件与校验
 *
 * 统一的一件事：字段的「标签 / 说明 / 错误」三行结构与 aria 关联。
 * 任何控件（原生 input 或自绘 select）只要放进 field()，就自动获得：
 *   <label for> 可点聚焦、aria-describedby 指向说明、aria-invalid + role=alert 的错误行。
 *
 * 校验的边界写死在这里：**前端校验只为即时反馈，不构成安全边界**。
 * 后端仍然对每个字段做同样的校验（schema 层），前端通过不代表内核接受。
 *
 * 诚实性约定：校验失败时不清空、不重置用户已填内容 —— 把用户输入丢掉的表单，
 * 用户会以为是自己填错了，而不是校验器太严。
 */

'require smwpopover';

smwcore.css('smw-overlay-css', L.resource('smartmwan/overlay.css'));

var seq = 0;

/* ---------------- 校验器 ---------------- */

/** IPv4：四段 0-255，不允许多余前导零（`01` 这类写法在不同工具里含义不一致）。 */
function isIPv4(s) {
	if (typeof s !== 'string' || s.length === 0)
		return false;
	var parts = s.split('.');
	if (parts.length !== 4)
		return false;
	for (var i = 0; i < 4; i++) {
		var p = parts[i];
		if (!/^\d{1,3}$/.test(p))
			return false;
		if (p.length > 1 && p.charAt(0) === '0')
			return false;
		if (parseInt(p, 10) > 255)
			return false;
	}
	return true;
}

/**
 * IPv6：支持 `::` 压缩（至多一处）与末尾内嵌 IPv4。
 * 不追求覆盖 RFC 4291 的全部边角（如 zone id `%eth0`），这类写法在
 * 本插件的字段里没有业务含义，直接判为不合法更安全。
 */
function isIPv6(s) {
	if (typeof s !== 'string' || s.length === 0 || s.length > 45)
		return false;
	if (s.indexOf(':::') >= 0)
		return false;

	var head = s;
	var embeddedV4 = 0;

	if (s.indexOf('.') >= 0) {
		var cut = s.lastIndexOf(':');
		if (cut < 0)
			return false;
		var v4 = s.slice(cut + 1);
		if (!isIPv4(v4))
			return false;
		head = s.slice(0, cut + 1);
		embeddedV4 = 2;
	}

	function countGroups(str) {
		if (!str)
			return 0;
		var gs = str.split(':');
		while (gs.length && gs[gs.length - 1] === '')
			gs.pop();
		for (var i = 0; i < gs.length; i++) {
			if (!/^[0-9a-fA-F]{1,4}$/.test(gs[i]))
				return -1;
		}
		return gs.length;
	}

	var halves = head.split('::');
	if (halves.length > 2)
		return false;

	var left = countGroups(halves[0]);
	var right = halves.length === 2 ? countGroups(halves[1]) : 0;
	if (left < 0 || right < 0)
		return false;

	var total = left + right + embeddedV4;
	if (halves.length === 2)
		return total < 8;      /* `::` 至少要压缩掉一组 */
	return total === 8;
}

/** 端口：1-65535；range 为真时接受 `8080-8090` 且要求起止有序。 */
function isPort(s, range) {
	if (typeof s !== 'string' || !s.length)
		return false;
	if (range) {
		var m = /^(\d{1,5})-(\d{1,5})$/.exec(s);
		if (m) {
			var a = parseInt(m[1], 10);
			var b = parseInt(m[2], 10);
			return a >= 1 && b <= 65535 && a <= b;
		}
	}
	if (!/^\d{1,5}$/.test(s))
		return false;
	var n = parseInt(s, 10);
	return n >= 1 && n <= 65535;
}

/** 整数区间校验器工厂。 */
function intBetween(min, max) {
	return function(v) {
		if (v === '' || v == null)
			return null;
		if (!/^-?\d+$/.test(String(v)))
			return '必须为整数';
		var n = parseInt(v, 10);
		if (n < min || n > max)
			return '取值范围 ' + min + '–' + max;
		return null;
	};
}

/* ---------------- 字段容器 ---------------- */

/**
 * 字段：标签 + 控件 + 说明 + 错误行。
 * opts: { label, control, help, required, validate, id, hint }
 * 返回控制器：{ el, input, setError(msg), clearError(), value(), validate() }
 */
function field(opts) {
	opts = opts || {};
	var input = opts.control;
	/* 常见笔误：把 password()/switch()/radio() 的返回值（{el, input}）直接当控件传。
	 * 让报错说清楚，比在 appendChild 那里收一句 "parameter 1 is not of type Node" 强。 */
	if (input == null || !input.nodeType)
		throw new Error('Form.field: control 必须是 DOM 节点；' +
			'password()/switch()/radio()/checkbox()/search() 返回的是 {el, input}，请取 .el');
	var id = opts.id || (input && input.id) || ('smw-f-' + (++seq));
	if (input != null)
		input.id = id;

	var helpId = helpIdOf(id);
	var errId = id + '-err';

	var labelEl = null;
	if (opts.label != null) {
		labelEl = E('label', { 'class': 'smw-field-label', 'for': id }, [
			opts.label,
			opts.required ? E('span', { 'class': 'smw-required', 'aria-hidden': 'true' }, [ '*' ]) : ''
		]);
		if (opts.required)
			labelEl.setAttribute('data-required', '1');
	}

	var helpEl = null;
	if (opts.help != null) {
		helpEl = E('p', { 'class': 'smw-field-help', 'id': helpId }, [ opts.help ]);
	}

	var errEl = E('p', { 'class': 'smw-field-error', 'id': errId, 'role': 'alert', 'hidden': 'hidden' });

	var el = E('div', { 'class': 'smw-field' });
	if (labelEl) el.appendChild(labelEl);
	el.appendChild(input);
	if (helpEl) el.appendChild(helpEl);
	el.appendChild(errEl);

	/* 建立 aria 关联：说明与错误都挂到控件上，读屏才能念出来。 */
	var described = [];
	if (helpEl) described.push(helpId);
	described.push(errId);
	if (input != null && input.setAttribute)
		input.setAttribute('aria-describedby', described.join(' '));
	if (opts.required && input != null && input.setAttribute)
		input.setAttribute('aria-required', 'true');

	var self = {
		el: el,
		input: input,
		id: id,
		setError: function(msg) {
			if (msg) {
				el.classList.add('smw-field-invalid');
				errEl.removeAttribute('hidden');
				errEl.textContent = msg;
				if (input != null && input.setAttribute)
					input.setAttribute('aria-invalid', 'true');
			} else {
				self.clearError();
			}
			return self;
		},
		clearError: function() {
			el.classList.remove('smw-field-invalid');
			errEl.setAttribute('hidden', 'hidden');
			errEl.textContent = '';
			if (input != null && input.removeAttribute)
				input.removeAttribute('aria-invalid');
			return self;
		},
		value: function() {
			if (input == null)
				return '';
			if (input.type === 'checkbox')
				return input.checked;
			return input.value;
		},
		validate: function() {
			if (typeof opts.validate !== 'function') {
				self.clearError();
				return true;
			}
			var msg = opts.validate(self.value());
			if (msg) {
				self.setError(msg);
				return false;
			}
			self.clearError();
			return true;
		}
	};

	/* 失焦校验一次、输入时清掉旧错误：不打断输入，但离开字段时给出结论。 */
	if (typeof opts.validate === 'function' && input != null && input.addEventListener) {
		input.addEventListener('blur', function() { self.validate(); });
		input.addEventListener('input', function() {
			if (el.classList.contains('smw-field-invalid'))
				self.clearError();
		});
	}

	return self;
}

function helpIdOf(id) {
	return id + '-help';
}

/* ---------------- 基础控件 ---------------- */

function baseInput(attrs) {
	return E('input', attrs);
}

/** 文本输入。 */
function text(opts) {
	opts = opts || {};
	var el = baseInput({
		'type': 'text',
		'class': 'smw-input',
		'value': opts.value == null ? '' : String(opts.value),
		'placeholder': opts.placeholder || null,
		'autocomplete': opts.autocomplete || 'off',
		'spellcheck': opts.spellcheck || 'false',
		'inputmode': opts.inputmode || null,
		'maxlength': opts.maxlength == null ? null : String(opts.maxlength),
		'disabled': opts.disabled ? 'disabled' : null,
		'readonly': opts.readonly ? 'readonly' : null,
		'name': opts.name || null,
		'input': opts.oninput || null,
		'change': opts.onchange || null
	});
	return el;
}

/**
 * 密码输入：带「显示 / 隐藏」按钮。
 * 切换按钮必须有 aria-pressed 与 aria-label，且保持输入框焦点（不能点一下就把键盘收了）。
 */
function password(opts) {
	opts = opts || {};
	var input = baseInput({
		'type': 'password',
		'class': 'smw-input smw-input-with-affix',
		'value': opts.value == null ? '' : String(opts.value),
		'placeholder': opts.placeholder || null,
		'autocomplete': opts.autocomplete || 'current-password',
		'disabled': opts.disabled ? 'disabled' : null,
		'input': opts.oninput || null,
		'change': opts.onchange || null
	});

	var shown = false;
	var toggle = smwcore.iconButton('eye', {
		label: '显示密码',
		className: 'smw-input-affix-btn',
		click: function(ev) {
			ev.preventDefault();
			shown = !shown;
			input.type = shown ? 'text' : 'password';
			toggle.setAttribute('aria-pressed', shown ? 'true' : 'false');
			toggle.setAttribute('aria-label', shown ? '隐藏密码' : '显示密码');
			var ic = toggle.querySelector('.smw-icon');
			if (ic && ic.parentNode) {
				toggle.removeChild(ic);
				toggle.appendChild(smwcore.icon(shown ? 'eyeoff' : 'eye', 20));
			}
			input.focus();
		}
	});

	var wrap = E('div', { 'class': 'smw-input-wrap' }, [ input, toggle ]);
	return { el: wrap, input: input };
}

/** 数字输入：min/max/step 直接透传，浏览器先挡一道，后端仍然校验。 */
function number(opts) {
	opts = opts || {};
	return baseInput({
		'type': 'number',
		'class': 'smw-input',
		'value': opts.value == null ? '' : String(opts.value),
		'min': opts.min == null ? null : String(opts.min),
		'max': opts.max == null ? null : String(opts.max),
		'step': opts.step == null ? null : String(opts.step),
		'placeholder': opts.placeholder || null,
		'disabled': opts.disabled ? 'disabled' : null,
		'readonly': opts.readonly ? 'readonly' : null,
		'name': opts.name || null,
		'input': opts.oninput || null,
		'change': opts.onchange || null
	});
}

/** IP 输入：inputmode 用 decimal 让手机出数字键盘（v6 的 a-f 少数场景仍可切回）。 */
function ip(opts) {
	opts = opts || {};
	var el = text({
		value: opts.value,
		placeholder: opts.placeholder || (opts.version === 4 ? '192.168.1.1' : '192.168.1.1 或 fd00::1'),
		inputmode: 'text',
		autocomplete: 'off',
		disabled: opts.disabled,
		oninput: opts.oninput,
		onchange: opts.onchange
	});
	el.classList.add('smw-input-mono');
	el.setAttribute('data-ip-version', opts.version === 4 ? '4' : (opts.version === 6 ? '6' : 'any'));
	return el;
}

/** 端口输入（range 为真时接受 `80-90` 区间）。 */
function port(opts) {
	opts = opts || {};
	var el = text({
		value: opts.value,
		placeholder: opts.placeholder || (opts.range ? '443 或 8000-8100' : '443'),
		inputmode: 'numeric',
		oninput: opts.oninput,
		onchange: opts.onchange
	});
	el.classList.add('smw-input-mono');
	return el;
}

/** 搜索输入：带清除按钮，输入即触发 oninput（用于本地过滤，不发请求）。 */
function search(opts) {
	opts = opts || {};
	var input = text({
		value: opts.value,
		placeholder: opts.placeholder || '搜索…',
		oninput: opts.oninput,
		onchange: opts.onchange
	});
	input.setAttribute('type', 'search');
	input.classList.add('smw-input-with-affix');

	var clear = smwcore.iconButton('close', {
		label: '清除',
		className: 'smw-input-affix-btn smw-input-affix-clear',
		click: function() {
			input.value = '';
			input.focus();
			if (typeof opts.oninput === 'function')
				opts.oninput({ target: input });
			else if (typeof opts.onchange === 'function')
				opts.onchange({ target: input });
		}
	});

	return { el: E('div', { 'class': 'smw-input-wrap' }, [ input, clear ]), input: input };
}

function textarea(opts) {
	opts = opts || {};
	return E('textarea', {
		'class': 'smw-textarea',
		'rows': String(opts.rows || 5),
		'placeholder': opts.placeholder || null,
		'spellcheck': 'false',
		'disabled': opts.disabled ? 'disabled' : null,
		'readonly': opts.readonly ? 'readonly' : null,
		'input': opts.oninput || null,
		'change': opts.onchange || null
	}, [ opts.value == null ? '' : String(opts.value) ]);
}

/** 原生下拉：选项多或需要分组时仍是最可靠的选择（移动端自带选择器）。 */
function select(opts) {
	opts = opts || {};
	var el = E('select', {
		'class': 'smw-select',
		'disabled': opts.disabled ? 'disabled' : null,
		'change': opts.onchange ? function(ev) { opts.onchange(ev.target.value, ev); } : null
	}, (opts.options || []).map(function(o) {
		return E('option', {
			'value': o.value,
			'selected': (o.value === opts.value) ? 'selected' : null,
			'disabled': o.disabled ? 'disabled' : null
		}, [ o.label ]);
	}));
	return el;
}

/**
 * 搜索式下拉：选项超过十来个时，原生 select 翻起来太费劲。
 * 触发按钮 + 浮层面板（由 smwpopover 提供定位与外部点击关闭），
 * 支持输入过滤、上下键移动、Enter 选中、ESC 关闭。
 */
function searchSelect(opts) {
	opts = opts || {};
	var options = (opts.options || []).slice();
	var value = opts.value;
	var listId = smwcore.uid('smw-ss');

	var labelEl = E('span', { 'class': 'smw-select-btn-label' });
	var trigger = E('button', {
		'type': 'button',
		'class': 'smw-select-btn',
		'aria-haspopup': 'listbox',
		'aria-expanded': 'false',
		'aria-controls': listId,
		'disabled': opts.disabled ? 'disabled' : null
	}, [ labelEl, smwcore.icon('chevron', 18) ]);

	var input = E('input', {
		'type': 'search',
		'class': 'smw-input',
		'placeholder': '筛选…',
		'autocomplete': 'off'
	});

	var list = E('div', {
		'class': 'smw-select-list',
		'role': 'listbox',
		'id': listId
	});

	var pop = null;
	var active = -1;
	var visible = [];

	function labelOf(v) {
		for (var i = 0; i < options.length; i++)
			if (options[i].value === v)
				return options[i].label;
		return opts.placeholder || '请选择';
	}

	function syncLabel() {
		labelEl.textContent = labelOf(value);
		trigger.classList.toggle('smw-select-btn-empty', value == null || value === '');
	}

	function render(filter) {
		var q = (filter || '').toLowerCase();
		visible = options.filter(function(o) {
			return !q || String(o.label).toLowerCase().indexOf(q) >= 0 ||
				String(o.value).toLowerCase().indexOf(q) >= 0;
		});
		while (list.firstChild) list.removeChild(list.firstChild);
		if (visible.length === 0) {
			list.appendChild(E('div', { 'class': 'smw-select-empty' }, [ '没有匹配项' ]));
			return;
		}
		visible.forEach(function(o, i) {
			var row = E('button', {
				'type': 'button',
				'class': 'smw-select-option' + (o.value === value ? ' smw-selected' : '') +
					(i === active ? ' smw-active' : ''),
				'role': 'option',
				'aria-selected': o.value === value ? 'true' : 'false',
				'click': function() { pick(o.value); }
			}, [ o.label ]);
			row.setAttribute('data-index', String(i));
			list.appendChild(row);
		});
	}

	function move(delta) {
		if (!visible.length)
			return;
		active = (active + delta + visible.length) % visible.length;
		var rows = list.querySelectorAll('.smw-select-option');
		for (var i = 0; i < rows.length; i++)
			rows[i].classList.toggle('smw-active', i === active);
		if (rows[active] && rows[active].scrollIntoView)
			rows[active].scrollIntoView({ block: 'nearest' });
	}

	function pick(v) {
		value = v;
		syncLabel();
		if (pop) { pop.close(); pop = null; }
		trigger.focus();
		if (typeof opts.onchange === 'function')
			opts.onchange(v);
	}

	function openPanel() {
		if (pop != null || opts.disabled)
			return;
		active = Math.max(0, visible.findIndex ? visible.findIndex(function(o) { return o.value === value; })
			: indexOfValue(visible, value));
		render('');
		trigger.setAttribute('aria-expanded', 'true');
		pop = smwpopover.Popover.open(trigger, {
			content: E('div', { 'class': 'smw-select-panel' }, [ input, list ]),
			placement: 'bottom-start',
			className: 'smw-popover-plain',
			onClose: function() {
				trigger.setAttribute('aria-expanded', 'false');
				pop = null;
			}
		});
		input.value = '';
		input.focus();
	}

	function indexOfValue(arr, v) {
		for (var i = 0; i < arr.length; i++)
			if (arr[i].value === v) return i;
		return 0;
	}

	trigger.addEventListener('click', function(ev) {
		ev.preventDefault();
		if (pop) { pop.close(); return; }
		openPanel();
	});

	trigger.addEventListener('keydown', function(ev) {
		if (ev.key === 'ArrowDown' || ev.key === 'Enter' || ev.key === ' ') {
			ev.preventDefault();
			openPanel();
		}
	});

	input.addEventListener('input', function() {
		active = 0;
		render(input.value);
	});

	input.addEventListener('keydown', function(ev) {
		if (ev.key === 'ArrowDown') { ev.preventDefault(); move(1); }
		else if (ev.key === 'ArrowUp') { ev.preventDefault(); move(-1); }
		else if (ev.key === 'Enter') {
			ev.preventDefault();
			if (visible[active]) pick(visible[active].value);
		}
	});

	syncLabel();

	var wrap = E('div', { 'class': 'smw-select-wrap' }, [ trigger ]);
	return { el: wrap, trigger: trigger, value: function() { return value; }, set: function(v) { value = v; syncLabel(); } };
}

/** 单选组：原生 radio 保留键盘语义（方向键切换），只换外观。 */
function radio(opts) {
	opts = opts || {};
	var name = opts.name || ('smw-r-' + (++seq));
	var group = E('div', { 'class': 'smw-radio-group', 'role': 'radiogroup' }, (opts.options || []).map(function(o, i) {
		var id = name + '-' + i;
		var input = E('input', {
			'type': 'radio',
			'class': 'smw-radio',
			'name': name,
			'id': id,
			'value': o.value,
			'checked': o.value === opts.value ? 'checked' : null,
			'disabled': o.disabled ? 'disabled' : null,
			'change': opts.onchange ? function() { opts.onchange(o.value); } : null
		});
		return E('label', { 'class': 'smw-radio-item', 'for': id }, [
			input,
			E('span', { 'class': 'smw-radio-label' }, [ o.label ]),
			o.help ? E('span', { 'class': 'smw-radio-help' }, [ o.help ]) : ''
		]);
	}));
	return { el: group, name: name };
}

/** 单个复选框：用于表单里的布尔项（视觉与开关区分：checkbox 是「选中/未选」，
 * switch 是「开关一个功能」，两者语义不同，不要混用）。 */
function checkbox(opts) {
	opts = opts || {};
	var id = opts.id || ('smw-c-' + (++seq));
	var input = E('input', {
		'type': 'checkbox',
		'class': 'smw-checkbox',
		'id': id,
		'checked': opts.checked ? 'checked' : null,
		'disabled': opts.disabled ? 'disabled' : null,
		'change': opts.onchange ? function(ev) { opts.onchange(ev.target.checked); } : null
	});
	var el = E('div', { 'class': 'smw-check-row' }, [
		input,
		E('label', { 'class': 'smw-check-label', 'for': id }, [ opts.label || '' ]),
		opts.help ? E('p', { 'class': 'smw-check-help' }, [ opts.help ]) : ''
	]);
	return { el: el, input: input };
}

/** 开关：用于「开启/关闭某个功能」。 */
function toggle(opts) {
	opts = opts || {};
	var id = opts.id || ('smw-s-' + (++seq));
	var input = E('input', {
		'type': 'checkbox',
		'class': 'smw-switch',
		'id': id,
		'role': 'switch',
		'checked': opts.checked ? 'checked' : null,
		'disabled': opts.disabled ? 'disabled' : null,
		'change': opts.onchange ? function(ev) { opts.onchange(ev.target.checked); } : null
	});
	if (opts.checked)
		input.setAttribute('aria-checked', 'true');
	var el = E('div', { 'class': 'smw-switch-row' }, [
		input,
		E('div', { 'class': 'smw-switch-text' }, [
			E('label', { 'class': 'smw-switch-label', 'for': id }, [ opts.label || '' ]),
			opts.help ? E('p', { 'class': 'smw-switch-help' }, [ opts.help ]) : ''
		])
	]);
	return { el: el, input: input };
}

/**
 * 可折叠分组（「高级设置」这一类）。
 * 默认收起时不渲染内容？—— 渲染但用 hidden 隐藏，保持 DOM 稳定，
 * 避免展开时重建控件丢掉用户已填的值。
 */
function group(opts) {
	opts = opts || {};
	var bodyId = smwcore.uid('smw-g');
	var open = opts.open !== false;
	var expanded = open;

	var chevron = smwcore.icon('chevron', 18);
	var head = E('button', {
		'type': 'button',
		'class': 'smw-group-head',
		'aria-expanded': expanded ? 'true' : 'false',
		'aria-controls': bodyId
	}, [ E('span', { 'class': 'smw-group-title' }, [ opts.title || '' ]), chevron ]);
	if (opts.description)
		head.appendChild(E('span', { 'class': 'smw-group-desc' }, [ opts.description ]));

	/* 同 overlay 的教训：flatten 已返回数组，不能再包 []，
	 * 否则分组内容会变成 "[object HTMLInputElement],..."。 */
	var body = E('div', { 'class': 'smw-group-body', 'id': bodyId }, smwcore.flatten(opts.children));
	if (!expanded)
		body.setAttribute('hidden', 'hidden');

	head.addEventListener('click', function() {
		expanded = !expanded;
		head.setAttribute('aria-expanded', expanded ? 'true' : 'false');
		if (expanded)
			body.removeAttribute('hidden');
		else
			body.setAttribute('hidden', 'hidden');
		chevron.classList.toggle('smw-chevron-open', expanded);
	});
	chevron.classList.toggle('smw-chevron-open', expanded);

	return E('section', { 'class': 'smw-group' + (expanded ? ' smw-group-open' : '') }, [ head, body ]);
}

/**
 * 表单级校验：按顺序校验，返回第一个错误并聚焦该字段。
 * 返回 { ok, field, message }。
 */
function validate(fields) {
	for (var i = 0; i < (fields || []).length; i++) {
		var f = fields[i];
		if (f == null || typeof f.validate !== 'function')
			continue;
		if (!f.validate()) {
			if (f.input && f.input.focus)
				f.input.focus();
			return { ok: false, field: f, message: '请检查标红的字段' };
		}
	}
	return { ok: true };
}

return {
	field: field,
	text: text,
	password: password,
	number: number,
	ip: ip,
	port: port,
	search: search,
	textarea: textarea,
	select: select,
	searchSelect: searchSelect,
	radio: radio,
	checkbox: checkbox,
	switch: toggle,
	group: group,
	validate: validate,
	validators: {
		ipv4: isIPv4,
		ipv6: isIPv6,
		port: isPort,
		intBetween: intBetween
	}
};
