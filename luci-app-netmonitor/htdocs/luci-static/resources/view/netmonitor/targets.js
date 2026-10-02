/*
 * 目标管理页面：新增 / 编辑 / 删除 / 启用 / 禁用 / 上下移动 / 复制 / 批量操作
 * TDesign Web Components 重构版本
 * 工具栏 / 按钮 / 标签 / 开关 / 弹窗 / 表单由 <t-*> 组件承载，
 * 明细表格保留 .nm-table 平面结构（t-table 的列配置在 WC 版渲染成本高，
 * 且本表含动态 SVG / 开关 / 按钮混合单元格，手写结构更可控）。
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
			common.tdesign(),
			common.api.getTargets(),
			common.api.getConfig()
		]);
	},

	render: function(res) {
		common.css();

		var targets = ((res && res[2]) || {}).targets || [];
		var cfg = (res && res[3]) || {};
		var checked = {};

		var root = common.el('div', 'nm-root');
		var page = common.el('div', 'nm-page');
		root.appendChild(page);

		/* 工具栏 */
		var bar = common.tcard();
		var row = common.el('div', 'nm-row');
		row.style.display = 'flex';
		row.style.alignItems = 'center';
		row.style.flexWrap = 'wrap';
		row.style.gap = '12px';
		row.style.width = '100%';

		function toolBtn(label, fn, isPrimary, svgIcon) {
			var b = document.createElement('t-button');
			b.setAttribute('theme', isPrimary ? 'primary' : 'default');
			if (!isPrimary) b.setAttribute('variant', 'outline');
			if (svgIcon) {
				var icBox = common.el('span', '');
				icBox.innerHTML = svgIcon;
				b.appendChild(icBox);
			}
			b.appendChild(document.createTextNode(label));
			b.addEventListener('click', function() {
				b.setAttribute('disabled', '');
				Promise.resolve(fn()).then(function() {
					reload();
				}).catch(function(e) {
					common.notify(String(e.message || e), 'error');
				}).then(function() {
					/* 收尾不能无脑清 disabled：批量按钮的可用态由
					 * syncBatchButtons() 依据勾选数决定，这里交还控制权，
					 * 否则「没勾选却可点批量」的问题会被这里重新打开。 */
					if (b !== btnEnable && b !== btnDisable)
						b.removeAttribute('disabled');
					else
						syncBatchButtons();
				});
			});
			return b;
		}

		var addSvg = `<svg width="15" height="15" viewBox="0 0 16 16" fill="currentColor"><path d="M8 2a1 1 0 0 1 1 1v4h4a1 1 0 1 1 0 2H9v4a1 1 0 1 1-2 0V9H3a1 1 0 0 1 0-2h4V3a1 1 0 0 1 1-1z"/></svg>`;
		var okSvg = `<svg width="15" height="15" viewBox="0 0 16 16" fill="currentColor"><path d="M13.485 1.929a1 1 0 0 1 1.414 1.414L6.343 11.899 1.1 6.657a1 1 0 0 1 1.414-1.414l3.829 3.829 7.142-7.143z"/></svg>`;
		var disSvg = `<svg width="15" height="15" viewBox="0 0 16 16" fill="currentColor"><circle cx="8" cy="8" r="6" stroke="currentColor" stroke-width="2" fill="none"/><line x1="3.5" y1="3.5" x2="12.5" y2="12.5" stroke="currentColor" stroke-width="2"/></svg>`;
		var refSvg = `<svg width="15" height="15" viewBox="0 0 16 16" fill="currentColor"><path d="M11.534 7h3.932a.25.25 0 0 1 .192.41l-1.966 2.36a.25.25 0 0 1-.384 0l-1.966-2.36a.25.25 0 0 1 .192-.41zm-11 2h3.932a.25.25 0 0 0 .192-.41L2.692 6.23a.25.25 0 0 0-.384 0L.342 8.59A.25.25 0 0 0 .534 9z"/><path fill-rule="evenodd" d="M8 3c-1.552 0-2.94.707-3.857 1.818a.5.5 0 1 1-.771-.636A6.002 6.002 0 0 1 13.917 7H12.9A5.002 5.002 0 0 0 8 3zM3.1 9a5.002 5.002 0 0 0 8.9 4.182.5.5 0 1 1 .771.636A6.002 6.002 0 0 1 2.083 9H3.1z"/></svg>`;

		row.appendChild(toolBtn(_('Add target'), function() { return openEditor(null); }, true, addSvg));
		var btnEnable = toolBtn(_('Enable selected'), function() {
			return common.api.batchTargets(selectedIds(), true);
		}, false, okSvg);
		var btnDisable = toolBtn(_('Disable selected'), function() {
			return common.api.batchTargets(selectedIds(), false);
		}, false, disSvg);
		row.appendChild(btnEnable);
		row.appendChild(btnDisable);
		row.appendChild(toolBtn(_('Refresh'), function() { return Promise.resolve(); }, false, refSvg));

		var spacer = common.el('div', 'nm-spacer');
		spacer.style.flex = '1';
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
		bar.appendChild(row);
		page.appendChild(bar);

		var wrap = common.el('div', 'nm-table-wrap nm-targets-table-wrap');
		var table = common.el('table', 'nm-table');
		var thead = common.el('thead', '');
		var tbody = common.el('tbody', '');
		var htr = common.el('tr', '');
		/* 勾选列表头：全选控件。原先是一个空 th，读屏会念成「空白表头」，
		 * 键盘也无法触达。这里放一个真正的 checkbox + aria-label。 */
		var thChk = common.el('th', '');
		thChk.style.width = '36px';
		var chkAll = common.el('input', '');
		chkAll.type = 'checkbox';
		chkAll.setAttribute('aria-label', _('Select all targets'));
		thChk.appendChild(chkAll);
		htr.appendChild(thChk);
		[_('Name'), _('Address'), _('Probe method'), _('Region'), _('Custom label'), _('Family'),
		 _('Interval'), _('Timeout'), _('Interface'), _('Enabled'), _('Actions')]
			.forEach(function(h) {
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

		/* 窄屏卡片流：12 列表格在手机上必须横拖两层才能看到「操作」列，
		 * 勾选与编辑都不可达。这里在 ≤860px 时用卡片流替换表格（与
		 * realtime 页同一套 .nm-cards-mobile 断点策略），每张卡片自带
		 * 勾选、状态与全部操作按钮，拇指可达。 */
		var cards = common.el('div', 'nm-cards-mobile nm-targets-cards');
		page.appendChild(cards);

		var tipRow = common.tcard();
		var tipText = common.el('div', '');
		tipText.innerHTML = _('Interval and timeout set to 0 inherit the global settings.') +
			' · ' + _('The table scrolls horizontally on small screens.');
		tipRow.appendChild(tipText);
		tipRow.style.fontSize = '12px';
		tipRow.style.color = 'var(--nm-muted)';
		page.appendChild(tipRow);

		function selectedIds() {
			var ids = [];
			for (var k in checked)
				if (checked[k]) ids.push(k);
			return ids;
		}

		/* 同步全选框的三态：未选 / 部分选中(indeterminate) / 全选。
		 * 批量按钮的可用状态跟着一起走，避免「一个没选也去点批量」的无效请求。 */
		function syncSelectAll() {
			var all = targets.length;
			var n = selectedIds().length;
			chkAll.checked = (all > 0 && n === all);
			chkAll.indeterminate = (n > 0 && n < all);
			chkAll.disabled = (all === 0);
		}

		chkAll.addEventListener('change', function() {
			var want = chkAll.checked;
			for (var i = 0; i < targets.length; i++)
				checked[targets[i].id] = want;
			renderList(targets);
		});

		function syncBatchButtons() {
			var has = (selectedIds().length > 0);
			/* 必须用 removeAttribute 解禁：disabled 是布尔属性，
			 * setAttribute('disabled', '') 依然是「禁用」状态，
			 * 那样勾选后批量按钮永远解不开。 */
			if (has) {
				btnEnable.removeAttribute('disabled');
				btnDisable.removeAttribute('disabled');
			} else {
				btnEnable.setAttribute('disabled', '');
				btnDisable.setAttribute('disabled', '');
			}
		}

		/* 表格流与卡片流同时存在于 DOM 中（靠 CSS 断点切换显示），
		 * 两侧的勾选框必须表现一致。这里按 data-id 定向回写状态，
		 * 而不是整表重建——重建会让列表在每次点击后闪一下。 */
		function syncChecks() {
			var boxes = root.querySelectorAll('input[type="checkbox"][data-id]');
			for (var i = 0; i < boxes.length; i++)
				boxes[i].checked = !!checked[boxes[i].getAttribute('data-id')];
		}

		/* TDesign 标签：协议 / 区域胶囊 */
		function protoTag(t) {
			var isTcp = (t.proto === 'tcp');
			var tag = document.createElement('t-tag');
			tag.setAttribute('theme', isTcp ? 'primary' : 'success');
			tag.setAttribute('variant', 'light');
			var text;
			if (isTcp) {
				var tport = (t.tcp_port || 0) > 0 ? t.tcp_port : (cfg.default_tcp_port || 80);
				text = 'TCP:' + tport;
			} else {
				text = 'ICMP';
			}
			tag.textContent = text;
			return tag;
		}

		function regionTag(t) {
			var tag = document.createElement('t-tag');
			var theme = 'default', variant = 'outline';
			if (t.region === 'cn') { theme = 'primary'; variant = 'light-outline'; }
			else if (t.region === 'overseas') { theme = 'warning'; variant = 'light-outline'; }
			tag.setAttribute('theme', theme);
			tag.setAttribute('variant', variant);
			tag.textContent = common.regionText(t.region);
			return tag;
		}

		/* 行内操作按钮工厂（TDesign 文本按钮）。
		 * text: 可选的纯文本/符号内容（替代按钮文字，保证视觉紧凑）；
		 * aria: 无可见文字时（如箭头符号）必须提供，否则读屏只会念「按钮」。 */
		function mini(label, fn, isDanger, text, aria) {
			var b = document.createElement('t-button');
			b.setAttribute('theme', isDanger ? 'danger' : 'default');
			b.setAttribute('variant', 'text');
			b.setAttribute('size', 'small');
			if (text != null) b.textContent = text;
			else b.textContent = label;
			if (aria) b.setAttribute('aria-label', aria);
			b.addEventListener('click', function() {
				b.setAttribute('disabled', '');
				Promise.resolve(fn()).then(reload).catch(function(e) {
					common.notify(String(e.message || e), 'error');
				}).then(function() { b.removeAttribute('disabled'); });
			});
			return b;
		}

		/* 目标的五个操作（编辑 / 上移 / 下移 / 复制 / 删除）。
		 * 表格行与窄屏卡片共用同一份实现，避免两处行为漂移。 */
		function appendActions(box, t) {
			box.appendChild(mini(_('Edit'), function() { return openEditor(t); }));
			box.appendChild(mini(_('Move up'), function() { return common.api.moveTarget(t.id, -1); },
				false, '↑', _('Move up') + ': ' + (t.name || t.id)));
			box.appendChild(mini(_('Move down'), function() { return common.api.moveTarget(t.id, 1); },
				false, '↓', _('Move down') + ': ' + (t.name || t.id)));
			box.appendChild(mini(_('Copy'), function() { return common.api.copyTarget(t.id); }));
			box.appendChild(mini(_('Delete'), function() {
				/* 危险操作走 TDesign 确认弹窗：与全站视觉一致，且不阻塞
				 * 主线程（低端路由器上原生 confirm 会整页卡住）。 */
				return common.confirmDialog({
					header: _('Delete target'),
					message: _('Delete this target?') + ' (' + (t.name || t.id) + ')',
					ok: _('Delete'),
					danger: true
				}).then(function(ok) {
					if (!ok) return null;
					return common.api.deleteTarget(t.id);
				});
			}, true));
			return box;
		}

		/* 窄屏卡片流：把一行 12 列的目标压成一张可独立操作的卡片。
		 * 复用 common.targetCard 呈现指标，这里额外补上勾选与操作区，
		 * 保证手机上「批量启用 / 编辑 / 删除」都不再需要横拖表格。 */
		function renderCardList(list) {
			common.clear(cards);
			if (!list.length) {
				var empty = common.tcard();
				empty.appendChild(common.el('div', 'nm-empty', _('No targets')));
				cards.appendChild(empty);
				return;
			}
			for (var i = 0; i < list.length; i++) {
				(function(t) {
					var shell = common.tcard('nm-target-card-shell');

					var top = common.el('div', 'nm-target-card-top');
					var cb = common.el('input', 'nm-target-card-check');
					cb.type = 'checkbox';
				cb.checked = !!checked[t.id];
				cb.setAttribute('data-id', t.id);
				cb.setAttribute('aria-label', _('Select') + ' ' + (t.name || t.id));
				cb.addEventListener('change', function() {
					checked[t.id] = cb.checked;
					/* 卡片与表格共用 checked 状态，互相触发刷新保持一致 */
					syncSelectAll();
					syncBatchButtons();
					syncChecks();
				});
					top.appendChild(cb);

					var meta = common.el('div', 'nm-target-card-meta');
					meta.appendChild(common.el('div', 'nm-target-name', t.name || t.id));
					var sub = common.el('div', 'nm-target-host', (t.host || ''));
					meta.appendChild(sub);
					top.appendChild(meta);

					var sw = document.createElement('t-switch');
					sw.value = !!t.enabled;
					sw.setAttribute('aria-label', _('Enabled'));
					sw.addEventListener('change', function(e) {
						var v = !!(e.detail && e.detail.value);
						common.api.updateTarget({ id: t.id, enabled: v }).then(reload).catch(function(err) {
							common.notify(String(err.message || err), 'error');
							sw.value = !v;
						});
					});
					top.appendChild(sw);
					shell.appendChild(top);

					shell.appendChild(common.targetCard(t, { rings: false, spark: false }));

					var act = common.el('div', 'nm-target-card-actions');
					appendActions(act, t);
					shell.appendChild(act);

					cards.appendChild(shell);
				})(list[i]);
			}
		}

		function renderList(list) {
			common.clear(tbody);
			targets = list;
			sumIconBox.innerHTML = icons.multiTarget(list, 30);
			/* 表格与卡片流共用同一份数据，任一处的勾选/操作都经由 reload()
			 * 回到这里重渲染，两种视图天然保持一致。 */
			renderCardList(list);
			if (!list.length) {
				var tr0 = common.el('tr', '');
				var td0 = common.el('td', 'nm-empty', _('No targets'));
				td0.colSpan = 12;
				td0.style.padding = '36px';
				td0.style.textAlign = 'center';
				tr0.appendChild(td0);
				tbody.appendChild(tr0);
				syncSelectAll();
				syncBatchButtons();
				return;
			}

			for (var i = 0; i < list.length; i++) {
				(function(t, idx) {
					var tr = common.el('tr', '');
					tr.setAttribute('data-id', t.id);

					var tdChk = common.el('td', '');
					tdChk.style.textAlign = 'center';
					var cb = common.el('input', '');
					cb.type = 'checkbox';
				cb.checked = !!checked[t.id];
				cb.setAttribute('data-id', t.id);
				/* 勾选框本身没有可见标签，必须给 aria-label，
				 * 否则读屏只会念「复选框 未选中」，不知道对应哪一行。 */
				cb.setAttribute('aria-label', _('Select') + ' ' + (t.name || t.id));
				cb.addEventListener('change', function() {
					checked[t.id] = cb.checked;
					syncSelectAll();
					syncBatchButtons();
					syncChecks();
				});
					tdChk.appendChild(cb);
					tr.appendChild(tdChk);

					tr.appendChild(common.el('td', 'nm-target-name', t.name || t.id));
					tr.appendChild(common.el('td', 'nm-target-host', t.host || ''));

					var tdMethod = common.el('td', '');
					var badge = protoTag(t);
					badge.title = (t.proto === 'tcp')
						? (_('TCP connect') + (((t.tcp_port || 0) > 0) ? '' : ' · ' + _('global default port')))
						: _('ICMP (ping)');
					tdMethod.appendChild(badge);
					tr.appendChild(tdMethod);

					var tdR = common.el('td', '');
					tdR.appendChild(regionTag(t));
					tr.appendChild(tdR);

					tr.appendChild(common.el('td', '', t.label || '—'));

					var fam = { auto: _('Auto'), ipv4: _('IPv4'), ipv6: _('IPv6'), both: _('IPv4 + IPv6') };
					var tdFam = common.el('td', '');
					tdFam.style.whiteSpace = 'nowrap';
					tdFam.appendChild(common.inlineIcon(icons.dualStack(t.family, true, true, 20)));
					tdFam.appendChild(document.createTextNode(' ' + (fam[t.family] || t.family)));
					tr.appendChild(tdFam);

					tr.appendChild(common.el('td', 'nm-num', (t.interval || 0) === 0 ? _('Global') : (t.interval + 's')));
					tr.appendChild(common.el('td', 'nm-num', (t.timeout || 0) === 0 ? _('Global') : (t.timeout + 's')));
					tr.appendChild(common.el('td', '', t.interface || '—'));

					/* 启用状态切换开关（TDesign） */
					var tdEn = common.el('td', '');
					tdEn.style.whiteSpace = 'nowrap';
					tdEn.appendChild(common.inlineIcon(icons.online(18, !!t.enabled)));
					var sw = document.createElement('t-switch');
					sw.value = !!t.enabled;
					sw.addEventListener('change', function(e) {
						var v = !!(e.detail && e.detail.value);
						common.api.updateTarget({ id: t.id, enabled: v }).then(reload).catch(function(err) {
							common.notify(String(err.message || err), 'error');
							sw.value = !v;
						});
					});
					tdEn.appendChild(sw);
					tr.appendChild(tdEn);

				/* 操作按钮组（TDesign 文本按钮） */
				var tdAct = common.el('td', '');
				tdAct.style.whiteSpace = 'nowrap';
				appendActions(tdAct, t);

				tr.appendChild(tdAct);
				tbody.appendChild(tr);
			})(list[i], i);
			}

			/* 列表变化后统一同步全选三态与批量按钮可用性 */
			syncSelectAll();
			syncBatchButtons();
		}

		/* 编辑弹窗（TDesign t-dialog + t-input / t-select / t-input-number / t-switch） */
		function openEditor(t) {
			var modal = document.createElement('t-dialog');
			modal.setAttribute('header', t ? _('Edit target') : _('Add target'));
			/* 宽度用 min() 而非固定 560px：固定宽度在 375px 手机上会让弹窗
			 * 左右溢出视口，标题与「保存」按钮被推到屏幕外。min() 让宽屏
			 * 保持 560px 的舒适排版，窄屏自动收缩到视口内并留 16px 边距。 */
			modal.setAttribute('width', 'min(560px, calc(100vw - 24px))');
			/* 属性名是 closeOnEscKeydown（不是 closeOnEsc）—— 核对
			 * tdesign.min.js 的 propTypes 后确认，后者并不存在，
			 * 写错会导致 ESC 关闭静默失效。 */
			modal.setAttribute('closeOnEscKeydown', 'true');
			modal.setAttribute('closeOnOverlayClick', 'true');
			modal.visible = true;

			/* 焦点陷阱 + 打开后把焦点送进第一个输入框：键盘用户不再需要
			 * 先 Tab 穿过背后的整页才能开始填写。
			 * onEscape 是 ESC 关闭的兜底 —— 组件自身的 closeOnEscKeydown
			 * 在本项目的调用方式下实测不生效，详见 common.trapFocus 注释。 */
			var releaseFocus = common.trapFocus(modal, function() { close(); });

			var body = common.el('div', 'nm-dialog-body');
			var fields = {};

			function field(label, key, control) {
				var f = common.el('div', 'nm-field');
				control.setAttribute('data-nm-key', key);
				f.appendChild(common.el('label', '', label));
				f.appendChild(control);
				fields[key] = control;
				body.appendChild(f);
			}

			function tinput(value, extra) {
				var i = document.createElement('t-input');
				if (value != null && value !== '') i.value = String(value);
				if (extra) {
					if (extra.placeholder) i.setAttribute('placeholder', extra.placeholder);
					if (extra.maxlength) i.setAttribute('maxlength', String(extra.maxlength));
				}
				return i;
			}

			function tnum(value, extra) {
				var n = document.createElement('t-input-number');
				if (value != null) n.value = value;
				if (extra) {
					if (extra.min != null) n.min = extra.min;
					if (extra.max != null) n.max = extra.max;
				}
				return n;
			}

			function tselect(options, value) {
				var s = document.createElement('t-select');
				s.options = options;
				s.value = value;
				return s;
			}

			var protoSel = tselect([
				{ label: _('ICMP (ping)'), value: 'icmp' },
				{ label: _('TCP connect'), value: 'tcp' }
			], t ? (t.proto || 'icmp') : (cfg.default_proto || 'icmp'));

			var portInp = tnum((t && t.tcp_port) ? t.tcp_port : 0, { min: 0, max: 65535 });

			function syncProto() {
				var isTcp = (protoSel.value === 'tcp');
				portInp.disabled = !isTcp;
				portInp.setAttribute('placeholder', isTcp
					? String(cfg.default_tcp_port || 80)
					: _('Not used by ICMP'));
				portInp.style.opacity = isTcp ? '1' : '0.5';
			}
			protoSel.addEventListener('change', syncProto);

			field(_('Name'), 'name', tinput(t ? t.name : ''));
			field(_('Address'), 'host', tinput(t ? t.host : ''));
			field(_('Probe method'), 'proto', protoSel);
			field(_('TCP port (0 = global default)'), 'tcp_port', portInp);
			field(_('Region'), 'region', tselect([
				{ label: _('China'), value: 'cn' },
				{ label: _('Overseas'), value: 'overseas' },
				{ label: _('Other'), value: 'other' }
			], t ? t.region : 'cn'));
			field(_('Custom label'), 'label', tinput(t ? t.label : ''));
			field(_('Address family'), 'family', tselect([
				{ label: _('Auto'), value: 'auto' },
				{ label: _('IPv4 only'), value: 'ipv4' },
				{ label: _('IPv6 only'), value: 'ipv6' },
				{ label: _('IPv4 + IPv6'), value: 'both' }
			], t ? t.family : 'auto'));
			field(_('Check interval (s, 0 = global)'), 'interval', tnum(t ? t.interval : 0, { min: 0, max: 86400 }));
			field(_('Timeout (s, 0 = global)'), 'timeout', tnum(t ? t.timeout : 0, { min: 0, max: 600 }));
			field(_('Interface (optional)'), 'interface', tinput(t ? t.interface : ''));
			field(_('Source address (optional)'), 'source', tinput(t ? t.source : ''));
			field(_('Remark'), 'remark', tinput(t ? t.remark : ''));
			syncProto();

			var enRow = common.el('div', 'nm-row');
			enRow.style.display = 'flex';
			enRow.style.alignItems = 'center';
			enRow.style.gap = '10px';
			enRow.style.margin = '10px 0';
			var enSw = document.createElement('t-switch');
			enSw.value = t ? !!t.enabled : true;
			enRow.appendChild(enSw);
			enRow.appendChild(common.el('span', '', _('Enabled')));
			body.appendChild(enRow);

			var errBox = common.el('div', 'nm-modal-error');
			body.appendChild(errBox);

			modal.appendChild(body);

			var footer = common.el('div', 'nm-modal-actions');
			var btnCancel = document.createElement('t-button');
			btnCancel.setAttribute('theme', 'default');
			btnCancel.setAttribute('variant', 'outline');
			btnCancel.textContent = _('Cancel');
			var btnSave = document.createElement('t-button');
			btnSave.setAttribute('theme', 'primary');
			btnSave.textContent = _('Save & Apply');
			footer.appendChild(btnCancel);
			footer.appendChild(btnSave);

			var slot = common.el('div');
			slot.setAttribute('slot', 'footer');
			slot.appendChild(footer);
			modal.appendChild(slot);

			/* closed 守卫：取消按钮、遮罩点击、ESC 三条路径都会走到这里，
			 * 若都各自跑一遍 releaseFocus / removeChild，第二次就会对已
			 * 移除的节点操作而抛错。 */
			var closed = false;
			function close() {
				if (closed) return;
				closed = true;
				/* 先解锁 Tab 循环再移除节点：反序会让 keydown 监听在节点
				 * 离场瞬间仍试图 querySelector，短暂抛错。 */
				releaseFocus();
				modal.visible = false;
				if (modal.parentNode) modal.parentNode.removeChild(modal);
			}
			btnCancel.addEventListener('click', close);
			/* t-dialog 的关闭出口只有一个 close 事件（内部 onClose({e,trigger})
			 * 派发），没有 visible-change —— 这里监听遮罩点击 / ESC 触发的
			 * 关闭并同步移除节点，避免 DOM 残留。 */
			modal.addEventListener('close', function() { close(); });

			btnSave.addEventListener('click', function() {
				var proto = fields.proto.value;
				var port = parseInt(fields.tcp_port.value, 10);
				if (isNaN(port) || port < 0) port = 0;
				if (port > 65535) port = 65535;
				if (proto !== 'tcp') port = 0;

				var data = {
					name: String(fields.name.value || '').trim(),
					host: String(fields.host.value || '').trim(),
					proto: proto,
					tcp_port: port,
					region: fields.region.value,
					label: String(fields.label.value || '').trim(),
					family: fields.family.value,
					interval: parseInt(fields.interval.value, 10) || 0,
					timeout: parseInt(fields.timeout.value, 10) || 0,
					interface: String(fields.interface.value || '').trim(),
					source: String(fields.source.value || '').trim(),
					remark: String(fields.remark.value || '').trim(),
					enabled: enSw.value ? '1' : '0'
				};
				if (!data.name || !data.host) {
					errBox.textContent = _('Name and address are required');
					return;
				}
				if (proto === 'tcp' && port === 0 && !(cfg.default_tcp_port > 0)) {
					errBox.textContent = _('TCP targets need a port or a global default port');
					return;
				}
				btnSave.setAttribute('disabled', '');
				btnCancel.setAttribute('disabled', '');

				var p;
				if (t) {
					var ops = [];
					for (var k in data)
						ops.push({ sid: t.id, opt: k, val: data[k] });
					p = common.saveConfig(ops);
				} else {
					p = common.addSection('netmonitor', 'target', data);
				}
				p.then(function(changed) {
					if (changed === 0) {
						close();
						common.notify(_('No changes to save'));
						return;
					}
					close();
					return common.applyChanges();
				}).catch(function(e) {
					if (!modal.parentNode) return;
					errBox.textContent = String(e.message || e);
					btnSave.removeAttribute('disabled');
					btnCancel.removeAttribute('disabled');
				});
			});

			document.body.appendChild(modal);
			/* 打开后把焦点送进弹窗，键盘用户不再需要先 Tab 穿过背后的整页。
			 * 落点选弹窗容器本身而非内部 t-input：t-input 是自定义元素，
			 * 未显式 tabindex 时 focus() 会被浏览器忽略（实测焦点仍留在 body），
			 * 给容器加 tabindex="-1" 则任何情况下都能稳定接住焦点，
			 * 用户按一次 Tab 即进入第一个输入框。 */
			modal.setAttribute('tabindex', '-1');
			window.setTimeout(function() {
				try { modal.focus(); } catch (e) { /* 组件未就绪则跳过 */ }
			}, 60);
			return Promise.resolve();
		}

		function reload() {
			return common.api.getTargets().then(function(d) {
				renderList(d.targets || []);
			});
		}

		renderList(targets);
		return root;
	}
});
