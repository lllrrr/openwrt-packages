/*
 * 目标管理页面：新增 / 编辑 / 删除 / 启用 / 禁用 / 上下移动 / 复制 / 批量操作
 *
 * UI 结构：工具栏按钮与行内操作用 ui.button()（原生 <button>），
 * 协议 / 区域标记用 ui.chip()，编辑弹窗用 ui.dialog()。
 * 不再依赖 TDesign Web Components —— 原 <t-dialog> 因随包样式表残缺
 * （无 dialog 定位规则）而停在 display:none 状态，导致编辑功能完全失效，
 * 详见 netmonitor/ui.js 文件头。
 *
 * 明细表格保留 .nm-table 平面结构：本表含动态 SVG / 开关 / 按钮混合单元格，
 * 手写结构比通用表格组件更可控。
 *
 * 表格流与卡片流共用同一份数据与同一组操作函数，两者靠 CSS 断点切换显示，
 * 因此手机上「批量启用 / 编辑 / 删除」都无需横拖表格即可触达。
 */

'use strict';
'require view';
'require netmonitor.common as common';
'require netmonitor.icons as icons';

return view.extend({
	load: function() {
		common.css();
		return Promise.all([
			common.loadI18n(),
			common.api.getTargets(),
			common.api.getConfig()
		]);
	},

	render: function(res) {
		common.css();

		var targets = ((res && res[1]) || {}).targets || [];
		var cfg = (res && res[2]) || {};
		var checked = {};

		/* 编辑弹窗单例守卫：快速双击「新增目标」时避免叠出两个弹窗。
		 * 两个弹窗各自持有 document 级 keydown 监听，一次 ESC 会把两层
		 * 一起关掉，剩下的监听器成为孤儿。 */
		var editorOpen = false;

		var root = common.el('div', 'nm-root');
		var page = common.el('div', 'nm-page');
		root.appendChild(page);

		/* ------------------------------------------------------------ 工具栏 */

		var bar = common.tcard();
		var row = common.el('div', 'nm-row nm-row-toolbar');
		page.appendChild(bar);
		bar.appendChild(row);

		function toolBtn(opts) {
			return common.ui.button({
				label: opts.label,
				theme: opts.primary ? 'primary' : 'default',
				icon: opts.icon,
				title: opts.title,
				disabled: opts.disabled,
				onClick: function () {
					var p = opts.onClick();
					if (!p || typeof p.then !== 'function') return p;
					/* 成功后刷新列表；失败由 ui.button 统一提示并解禁 */
					return p.then(function (r) { return reload().then(function () { return r; }); });
				}
			});
		}

		var icoAdd = '<svg width="15" height="15" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true">' +
			'<path d="M8 2a1 1 0 0 1 1 1v4h4a1 1 0 1 1 0 2H9v4a1 1 0 1 1-2 0V9H3a1 1 0 0 1 0-2h4V3a1 1 0 0 1 1-1z"/></svg>';
		var icoOk = '<svg width="15" height="15" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true">' +
			'<path d="M13.485 1.929a1 1 0 0 1 1.414 1.414L6.343 11.899 1.1 6.657a1 1 0 0 1 1.414-1.414l3.829 3.829 7.142-7.143z"/></svg>';
		var icoOff = '<svg width="15" height="15" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true">' +
			'<circle cx="8" cy="8" r="6" stroke="currentColor" stroke-width="2" fill="none"/>' +
			'<line x1="3.5" y1="3.5" x2="12.5" y2="12.5" stroke="currentColor" stroke-width="2"/></svg>';
		var icoRefresh = '<svg width="15" height="15" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true">' +
			'<path fill-rule="evenodd" d="M8 3c-1.552 0-2.94.707-3.857 1.818a.5.5 0 1 1-.771-.636A6.002 6.002 0 0 1 13.917 7H12.9A5.002 5.002 0 0 0 8 3zM3.1 9a5.002 5.002 0 0 0 8.9 4.182.5.5 0 1 1 .771.636A6.002 6.002 0 0 1 2.083 9H3.1z"/></svg>';

		var btnEnable, btnDisable;

		row.appendChild(toolBtn({
			label: _('Add target'),
			primary: true,
			icon: icoAdd,
			onClick: function () { openEditor(null); return Promise.resolve(); }
		}));

		btnEnable = toolBtn({
			label: _('Enable selected'),
			icon: icoOk,
			disabled: true,
			onClick: function () { return common.api.batchTargets(selectedIds(), true); }
		});
		btnDisable = toolBtn({
			label: _('Disable selected'),
			icon: icoOff,
			disabled: true,
			onClick: function () { return common.api.batchTargets(selectedIds(), false); }
		});
		row.appendChild(btnEnable);
		row.appendChild(btnDisable);
		row.appendChild(toolBtn({
			label: _('Refresh'),
			icon: icoRefresh,
			onClick: function () { return Promise.resolve(); }
		}));

		var spacer = common.el('div', 'nm-spacer');
		row.appendChild(spacer);

		var summary = common.el('div', 'nm-summary-pill');
		var sumIconBox = common.el('span', 'nm-inline-icon');
		sumIconBox.innerHTML = icons.multiTarget(targets, 30);
		summary.appendChild(sumIconBox);
		var sumProto = (cfg.default_proto === 'tcp')
			? ('TCP:' + (cfg.default_tcp_port || 80)) : 'ICMP';
		summary.appendChild(common.el('span', '',
			_('Default probe method') + ': ' + sumProto + ' · ' +
			_('Global interval') + ': ' + (cfg.interval || 10) + 's · ' +
			_('Timeout') + ': ' + (cfg.timeout || 3) + 's'));
		row.appendChild(summary);

		/* ------------------------------------------------------------ 表格 */

		var wrap = common.el('div', 'nm-table-wrap nm-targets-table-wrap');
		var table = common.el('table', 'nm-table');
		var thead = common.el('thead', '');
		var tbody = common.el('tbody', '');
		var htr = common.el('tr', '');

		var thChk = common.el('th', '');
		thChk.style.width = '36px';
		var chkAll = common.el('input', '');
		chkAll.type = 'checkbox';
		chkAll.setAttribute('aria-label', _('Select all targets'));
		thChk.appendChild(chkAll);
		htr.appendChild(thChk);

		[_('Name'), _('Address'), _('Probe method'), _('Region'), _('Custom label'), _('Family'),
		 _('Interval'), _('Timeout'), _('Interface'), _('Enabled'), _('Actions')]
			.forEach(function (h) {
			var th = common.el('th', '', h);
			/* scope 让读屏在逐单元格导航时能正确播报列名 */
			th.setAttribute('scope', 'col');
			htr.appendChild(th);
		});

		thead.appendChild(htr);
		table.appendChild(thead);
		table.appendChild(tbody);
		wrap.appendChild(table);
		page.appendChild(wrap);

		var cards = common.el('div', 'nm-cards-mobile nm-targets-cards');
		page.appendChild(cards);

		var tipRow = common.tcard();
		tipRow.appendChild(common.el('div', 'nm-card-description',
			_('Interval and timeout set to 0 inherit the global settings.') +
			' · ' + _('The table scrolls horizontally on small screens.')));
		page.appendChild(tipRow);

		/* ------------------------------------------------------------ 勾选状态 */

		function selectedIds() {
			var ids = [];
			for (var k in checked)
				if (checked[k]) ids.push(k);
			return ids;
		}

		/* 同步全选框三态：未选 / 部分选中 / 全选。
		 * 批量按钮的可用状态跟着走，避免「一个没选也去点批量」的无效请求。 */
		function syncSelectAll() {
			var all = targets.length;
			var n = selectedIds().length;
			chkAll.checked = (all > 0 && n === all);
			chkAll.indeterminate = (n > 0 && n < all);
			chkAll.disabled = (all === 0);
		}

		function syncBatchButtons() {
			common.ui.setDisabled(btnEnable, selectedIds().length === 0);
			common.ui.setDisabled(btnDisable, selectedIds().length === 0);
		}

		/* 表格流与卡片流共用 checked，按 data-id 定向回写，
		 * 避免整表重建导致列表闪烁与焦点丢失。 */
		function syncChecks() {
			var boxes = root.querySelectorAll('input[type="checkbox"][data-id]');
			for (var i = 0; i < boxes.length; i++)
				boxes[i].checked = !!checked[boxes[i].getAttribute('data-id')];
		}

		chkAll.addEventListener('change', function () {
			var want = chkAll.checked;
			for (var i = 0; i < targets.length; i++)
				checked[targets[i].id] = want;
			/* 同样走定向回写，不重建列表 */
			syncChecks();
			syncSelectAll();
			syncBatchButtons();
		});

		/* ------------------------------------------------------------ 标记 */

		function protoTag(t) {
			var isTcp = (t.proto === 'tcp');
			var text = isTcp
				? ('TCP:' + (((t.tcp_port || 0) > 0) ? t.tcp_port : (cfg.default_tcp_port || 80)))
				: 'ICMP';
			return common.ui.chip({
				text: text,
				kind: isTcp ? 'info' : 'ok',
				title: isTcp
					? (_('TCP connect') + (((t.tcp_port || 0) > 0) ? '' : ' · ' + _('global default port')))
					: _('ICMP (ping)')
			});
		}

		/* 区域标记：统一走 common.regionTag()（widgets.regionTag 的唯一实现）。
		 * 本页此前自带一份 common.ui.chip({ kind: info|warn|idle }) 的拼装，
		 * 而且不支持 t.label 兜底——自定义区域名的目标在这里显示原始 region 值。 */
		function regionTag(t) {
			return common.regionTag(t.region, t.label);
		}

		/* ------------------------------------------------------------ 控件工厂 */

		/* 勾选框：表格流与卡片流共用，避免两处逻辑漂移 */
		function selectCheckbox(t) {
			var cb = common.el('input', '');
			cb.type = 'checkbox';
			cb.checked = !!checked[t.id];
			cb.setAttribute('data-id', t.id);
			cb.setAttribute('aria-label', _('Select') + ' ' + (t.name || t.id));
			cb.addEventListener('change', function () {
				checked[t.id] = cb.checked;
				syncSelectAll();
				syncBatchButtons();
				syncChecks();
			});
			return cb;
		}

	/* 启用开关：同样两处共用。统一走 ui.switchControl（role=switch，
	 * 读屏播报「开关」语义）。
	 * 请求期间禁用自身，防止快速连点发出两个相反的 enabled 请求
	 * （响应顺序不保证，最终状态可能与用户最后一次点击相反）。 */
	function enabledSwitch(t) {
		var sw = common.ui.switchControl({
			checked: boolOf(t.enabled),
			ariaLabel: _('Enabled')
		});
		sw.addEventListener('change', function () {
			var want = sw.checked;
			common.ui.setDisabled(sw, true);
			common.api.updateTarget({ id: t.id, enabled: want }).then(reload).catch(function (err) {
				common.notify(String((err && err.message) || err), 'error');
				sw.checked = !want;
			}).then(function () {
				common.ui.setDisabled(sw, false);
			});
		});
		return sw;
	}

		/* 后端可能返回 1 / '1' / true / 'on' 等多种真值表示，
		 * 直接用 !!v 会把字符串 '0' 判成 true —— 已禁用的目标会显示为启用。 */
		function boolOf(v) {
			return v === true || v === 1 || v === '1' || v === 'on';
		}

		/* 行内操作按钮 */
		function mini(label, opts) {
			opts = opts || {};
			return common.ui.button({
				label: opts.text == null ? label : opts.text,
				theme: opts.danger ? 'danger' : 'default',
				variant: 'text',
				size: 'sm',
				title: opts.title || label,
				ariaLabel: opts.text == null ? label : (opts.title || label),
				onClick: function () {
					var p = opts.onClick();
					if (!p || typeof p.then !== 'function') return p;
					return p.then(function (r) { return reload().then(function () { return r; }); });
				}
			});
		}

		/* 目标的五个操作（编辑 / 上移 / 下移 / 复制 / 删除）。
		 * 表格行与窄屏卡片共用同一份实现。 */
		function appendActions(box, t) {
			box.appendChild(mini(_('Edit'), {
				onClick: function () { openEditor(t); return Promise.resolve(); }
			}));
			box.appendChild(mini(_('Move up'), {
				text: '↑',
				title: _('Move up') + ': ' + (t.name || t.id),
				onClick: function () { return common.api.moveTarget(t.id, -1); }
			}));
			box.appendChild(mini(_('Move down'), {
				text: '↓',
				title: _('Move down') + ': ' + (t.name || t.id),
				onClick: function () { return common.api.moveTarget(t.id, 1); }
			}));
			box.appendChild(mini(_('Copy'), {
				onClick: function () { return common.api.copyTarget(t.id); }
			}));
			box.appendChild(mini(_('Delete'), {
				danger: true,
				onClick: function () {
					/* 危险操作走确认弹窗：与全站视觉一致，且不阻塞主线程
					 * （低端路由器上原生 confirm 会整页卡住数百毫秒）。
					 * 删除动作由弹窗的 onOk 承接，确认后才真正调用后端。 */
					common.ui.confirm({
						host: root,
						header: _('Delete target'),
						message: _('Delete this target?') + ' (' + (t.name || t.id) + ')',
						ok: _('Delete'),
						danger: true,
						onOk: function () {
							common.api.deleteTarget(t.id).then(reload).catch(function (e) {
								common.notify(String((e && e.message) || e), 'error');
							});
						}
					});
					return Promise.resolve();
				}
			}));
			return box;
		}

		/* ------------------------------------------------------------ 渲染 */

		function renderCardList(list) {
			common.clear(cards);
			if (!list.length) {
				var empty = common.tcard();
				empty.appendChild(common.emptyState(_('No targets')));
				cards.appendChild(empty);
				return;
			}
			for (var i = 0; i < list.length; i++) {
				var t = list[i];
				var shell = common.tcard('nm-target-card-shell');

				var top = common.el('div', 'nm-target-card-top');
				top.appendChild(selectCheckbox(t));

				var meta = common.el('div', 'nm-target-card-meta');
				meta.appendChild(common.el('div', 'nm-target-name', t.name || t.id));
				meta.appendChild(common.el('div', 'nm-target-host', t.host || ''));
				top.appendChild(meta);
				top.appendChild(enabledSwitch(t));
				shell.appendChild(top);

				shell.appendChild(common.targetCard(t, { rings: false, spark: false }));

				var act = common.el('div', 'nm-target-card-actions');
				appendActions(act, t);
				shell.appendChild(act);

				cards.appendChild(shell);
			}
		}

		function renderList(list) {
			common.clear(tbody);
			targets = list;

			/* 剪枝已消失的目标 id：否则删除一个已勾选目标后，
			 * checked 里残留的幽灵 id 会让 selectedIds() 超出实际数量，
			 * 全选三态彻底失真，且批量操作整批失败。 */
			var alive = {};
			var i;
			for (i = 0; i < list.length; i++) alive[list[i].id] = true;
			for (var key in checked) {
				if (!alive[key])
					delete checked[key];
			}

			sumIconBox.innerHTML = icons.multiTarget(list, 30);
			renderCardList(list);

			if (!list.length) {
				var tr0 = common.el('tr', '');
				tr0.appendChild(common.emptyState(_('No targets'),
					{ tag: 'td', size: 'sm', colspan: 11 }));
				tbody.appendChild(tr0);
				syncSelectAll();
				syncBatchButtons();
				return;
			}

			for (i = 0; i < list.length; i++) {
				var t = list[i];
				var tr = common.el('tr', '');
				tr.setAttribute('data-id', t.id);

				var tdChk = common.el('td', '');
				tdChk.style.textAlign = 'center';
				tdChk.appendChild(selectCheckbox(t));
				tr.appendChild(tdChk);

				tr.appendChild(common.el('td', 'nm-target-name', t.name || t.id));
				tr.appendChild(common.el('td', 'nm-target-host', t.host || ''));

				var tdMethod = common.el('td', '');
				tdMethod.appendChild(protoTag(t));
				tr.appendChild(tdMethod);

				var tdR = common.el('td', '');
				tdR.appendChild(regionTag(t));
				tr.appendChild(tdR);

				tr.appendChild(common.el('td', '', t.label || '—'));

				var famText = { auto: _('Auto'), ipv4: _('IPv4'), ipv6: _('IPv6'), both: _('IPv4 + IPv6') };
				var tdFam = common.el('td', '');
				tdFam.style.whiteSpace = 'nowrap';
				tdFam.appendChild(common.inlineIcon(icons.dualStack(t.family, true, true, 20)));
				tdFam.appendChild(document.createTextNode(' ' + (famText[t.family] || t.family)));
				tr.appendChild(tdFam);

				tr.appendChild(common.el('td', 'nm-num', (t.interval || 0) === 0 ? _('Global') : (t.interval + 's')));
				tr.appendChild(common.el('td', 'nm-num', (t.timeout || 0) === 0 ? _('Global') : (t.timeout + 's')));
				tr.appendChild(common.el('td', '', t.interface || '—'));

				var tdEn = common.el('td', '');
				tdEn.style.whiteSpace = 'nowrap';
				tdEn.appendChild(common.inlineIcon(icons.online(18, boolOf(t.enabled))));
				tdEn.appendChild(enabledSwitch(t));
				tr.appendChild(tdEn);

				var tdAct = common.el('td', '');
				tdAct.style.whiteSpace = 'nowrap';
				appendActions(tdAct, t);
				tr.appendChild(tdAct);

				tbody.appendChild(tr);
			}

			syncSelectAll();
			syncBatchButtons();
		}

	/* ------------------------------------------------------------ 编辑弹窗 */

	/* 整数解析并夹到 [min, max]。
	 * <input type=number min=0> 的 min 只是表单校验提示，用户键入 -5
	 * 不会被拦下；必须显式钳位，否则负数会原样写进 UCI。 */
	function intOf(input, min, max) {
		var n = parseInt(input.value, 10);
		if (isNaN(n)) return min;
		if (n < min) return min;
		if (n > max) return max;
		return n;
	}

	function openEditor(t) {
		if (editorOpen) return;
		editorOpen = true;

		/* 提交守卫（第二道，与 dialog 的按钮 busy 双保险）。
		 *
		 * 【历史】submit() 曾恒返回 false（异步结果由它自己收尾），
		 * 而旧 dialog 的确认按钮只在 onClick 返回 Promise 时才加
		 * is-busy，于是整段提交期间按钮可连点——连发两次
		 * saveConfig / addSection：新增时一次建出两个一模一样的目标段，
		 * 编辑时后发请求覆盖先发请求。现在 dialog 的 onOk 直接返回
		 * Promise，按钮自动 busy + 禁用；这里的标志只防程序性重入。 */
		var submitting = false;

		var body = common.el('div', 'nm-dialog-body');
		var fields = {};
		var wraps = {};

		/* 字段包裹统一走 ui.field()：label[for] 关联 + 错误行 +
		 * aria-invalid 一次配齐。校验失败时错误写到对应字段下方，
		 * 不再是弹窗顶部一根孤零零的错误条。 */
		function field(label, key, control) {
			var f = common.ui.field(label, control);
			fields[key] = control;
			wraps[key] = f;
			body.appendChild(f);
		}

		/* 控件全部取自 ui.js 统一工厂（.nm-ctl 基线：40px 高、
		 * 聚焦环、禁用态、错误态、移动端 44px）。本页此前的
		 * selectInput / textInput / numberInput 三份本地实现已删除。 */
		var protoSel = common.ui.selectInput([
			{ label: _('ICMP (ping)'), value: 'icmp' },
			{ label: _('TCP connect'), value: 'tcp' }
		], t ? (t.proto || 'icmp') : (cfg.default_proto || 'icmp'));

		var portInp = common.ui.numberInput({
			value: (t && t.tcp_port) ? t.tcp_port : 0,
			min: 0,
			max: 65535
		});

		function syncProto() {
			var isTcp = (protoSel.value === 'tcp');
			portInp.disabled = !isTcp;
			portInp.setAttribute('placeholder', isTcp
				? String(cfg.default_tcp_port || 80)
				: _('Not used by ICMP'));
			portInp.style.opacity = isTcp ? '1' : '0.5';
		}
		protoSel.addEventListener('change', syncProto);

		field(_('Name'), 'name', common.ui.textInput({ value: t ? t.name : '', maxlength: 64 }));
		field(_('Address'), 'host', common.ui.textInput({ value: t ? t.host : '', maxlength: 253 }));
		field(_('Probe method'), 'proto', protoSel);
		field(_('TCP port (0 = global default)'), 'tcp_port', portInp);
		field(_('Region'), 'region', common.ui.selectInput([
			{ label: _('China'), value: 'cn' },
			{ label: _('Overseas'), value: 'overseas' },
			{ label: _('Other'), value: 'other' }
		], t ? t.region : 'cn'));
		field(_('Custom label'), 'label', common.ui.textInput({ value: t ? t.label : '', maxlength: 32 }));
		field(_('Address family'), 'family', common.ui.selectInput([
			{ label: _('Auto'), value: 'auto' },
			{ label: _('IPv4 only'), value: 'ipv4' },
			{ label: _('IPv6 only'), value: 'ipv6' },
			{ label: _('IPv4 + IPv6'), value: 'both' }
		], t ? t.family : 'auto'));
		field(_('Check interval (s, 0 = global)'), 'interval',
			common.ui.numberInput({ value: t ? t.interval : 0, min: 0, max: 3600 }));
		field(_('Timeout (s, 0 = global)'), 'timeout',
			common.ui.numberInput({ value: t ? t.timeout : 0, min: 0, max: 30 }));
		field(_('Interface (optional)'), 'interface',
			common.ui.textInput({ value: t ? t.interface : '', maxlength: 64 }));
		field(_('Source address (optional)'), 'source',
			common.ui.textInput({ value: t ? t.source : '', maxlength: 64 }));
		field(_('Remark'), 'remark', common.ui.textInput({ value: t ? t.remark : '', maxlength: 128 }));
		syncProto();

		var enRow = common.el('div', 'nm-row nm-row-inline');
		/* 启用开关统一走 ui.switchControl（role=switch） */
		var enSw = common.ui.switchControl({ checked: t ? boolOf(t.enabled) : true });
		enRow.appendChild(enSw);
		enRow.appendChild(common.el('span', '', _('Enabled')));
		body.appendChild(enRow);

		/* RPC 级错误（保存失败 / 应用失败）仍走顶部错误条：
		 * 字段级错误在各自字段下方，两者分工明确。 */
		var errBox = common.el('div', 'nm-modal-error');
		body.appendChild(errBox);

		function submit() {
			if (submitting) return false;
			var proto = fields.proto.value;
			var port = intOf(fields.tcp_port, 0, 65535);
			if (proto !== 'tcp') port = 0;

			var data = {
				name: String(fields.name.value || '').trim(),
				host: String(fields.host.value || '').trim(),
				proto: proto,
				tcp_port: port,
				region: fields.region.value,
				label: String(fields.label.value || '').trim(),
				family: fields.family.value,
				interval: intOf(fields.interval, 0, 3600),
				timeout: intOf(fields.timeout, 0, 30),
				interface: String(fields.interface.value || '').trim(),
				source: String(fields.source.value || '').trim(),
				remark: String(fields.remark.value || '').trim(),
				enabled: enSw.checked ? '1' : '0'
			};

			/* 先清掉上一轮的字段错误标记，再逐项校验：
			 * 错误写到对应字段下方（setError → aria-invalid），
			 * 视觉与读屏同时能定位到具体是哪一个字段。 */
			for (var fk in wraps) wraps[fk].setError('');

			if (!data.name) {
				wraps.name.setError(_('Name and address are required'));
				return false;
			}
			if (!data.host) {
				wraps.host.setError(_('Name and address are required'));
				return false;
			}
			/* cfg.default_tcp_port 是字符串，必须显式转数字再比较，
			 * 否则 '' / '0' 会被隐式转换骗过判断 */
			if (proto === 'tcp' && port === 0 && !(parseInt(cfg.default_tcp_port, 10) > 0)) {
				wraps.tcp_port.setError(_('TCP targets need a port or a global default port'));
				return false;
			}

			var p;
			if (t) {
				var ops = [];
				for (var k in data)
					ops.push({ sid: t.id, opt: k, val: data[k] });
				p = common.saveConfig(ops);
			} else {
				p = common.addSection('netmonitor', 'target', data);
			}

			/* 返回 Promise：dialog 给确认按钮加 busy + 禁用（连点不再
			 * 重复提交），resolve 后自动关闭；reject 时错误写回 errBox
			 * 并重新抛出，让 dialog 恢复按钮、弹窗保持打开。 */
			submitting = true;
			return p.then(function (changed) {
				if (changed === 0) {
					common.notify(_('No changes to save'));
					return;
				}
				return common.applyChanges();
			}).catch(function (e) {
				errBox.textContent = String((e && e.message) || e);
				throw e;
			}).then(function () {
				submitting = false;
			});
		}

		common.ui.dialog({
			/* 挂到 root 而非 document.body：LuCI 的 SPA 路由切换只替换
			 * view 容器，挂在 body 上的弹窗会带着遮罩永久残留。 */
			host: root,
			header: t ? _('Edit target') : _('Add target'),
			body: body,
			width: 'min(560px, calc(100vw - 24px))',
			ok: _('Save & Apply'),
			onOk: submit,
			onClose: function () { editorOpen = false; }
		});
	}

		/* ------------------------------------------------------------ 数据刷新 */

		function reload() {
			return common.api.getTargets().then(function (d) {
				renderList(d.targets || []);
			});
		}

		renderList(targets);
		return root;
	}
});