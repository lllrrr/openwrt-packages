/*
 * 目标管理页面：新增 / 编辑 / 删除 / 启用 / 禁用 / 上下移动 / 复制 / 批量操作
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

		var root = common.el('div', 'nm-root');
		var page = common.el('div', 'nm-page');
		root.appendChild(page);

		/* 工具栏 */
		var bar = common.el('div', 'nm-card');
		var row = common.el('div', 'nm-row');

		function toolBtn(label, fn, cls) {
			var b = common.el('button', 'nm-btn ' + (cls || ''), label);
			b.addEventListener('click', function() {
				b.disabled = true;
				Promise.resolve(fn()).then(function() {
					reload();
				}).catch(function(e) {
					common.notify(String(e.message || e), 'error');
				}).then(function() { b.disabled = false; });
			});
			return b;
		}

		row.appendChild(toolBtn(_('Add target'), function() { return openEditor(null); }, 'nm-btn-primary'));
		row.appendChild(toolBtn(_('Enable selected'), function() {
			return common.api.batchTargets(selectedIds(), true);
		}));
		row.appendChild(toolBtn(_('Disable selected'), function() {
			return common.api.batchTargets(selectedIds(), false);
		}));
		row.appendChild(toolBtn(_('Refresh'), function() { return Promise.resolve(); }));
		row.appendChild(common.el('div', 'nm-spacer'));

		/* 工具条右侧：多目标图标的圆点数量与目标配置一致，蓝色表示已启用、
		 * 灰色表示已禁用（本页不采集延迟，因此图标只表达配置状态，不冒充链路健康）；
		 * 齿轮图标与左侧的全局间隔 / 超时数值一一对应。 */
		var summary = common.el('div', 'nm-row');
		var sumIconBox = common.el('span', 'nm-inline-icon');
		sumIconBox.innerHTML = icons.multiTarget(targets, 34);
		summary.appendChild(sumIconBox);
		summary.appendChild(common.inlineIcon(icons.gear(30)));
		var sumProto = (cfg.default_proto === 'tcp')
			? ('TCP:' + (cfg.default_tcp_port || 80)) : 'ICMP';
		summary.appendChild(common.el('span', 'nm-card-sub',
			_('Default probe method') + ': ' + sumProto + ' · ' +
			_('Global interval') + ': ' + (cfg.interval || 10) + 's · ' +
			_('Timeout') + ': ' + (cfg.timeout || 3) + 's'));
		row.appendChild(summary);
		bar.appendChild(row);
		page.appendChild(bar);

		var wrap = common.el('div', 'nm-table-wrap');
		var table = common.el('table', 'nm-table');
		var thead = common.el('thead', '');
		var tbody = common.el('tbody', '');
		var htr = common.el('tr', '');
		htr.appendChild(common.el('th', '', ''));
		[_('Name'), _('Address'), _('Probe method'), _('Region'), _('Custom label'), _('Family'),
		 _('Interval'), _('Timeout'), _('Interface'), _('Enabled'), _('Actions')]
			.forEach(function(h) { htr.appendChild(common.el('th', '', h)); });
		thead.appendChild(htr);
		table.appendChild(thead);
		table.appendChild(tbody);
		wrap.appendChild(table);
		page.appendChild(wrap);

		var tipRow = common.el('div', 'nm-row');
		tipRow.appendChild(common.inlineIcon(icons.responsive(30)));
		var tipText = common.el('div', 'nm-card-sub');
		tipText.innerHTML = _('Interval and timeout set to 0 inherit the global settings.') +
			'<br>' + _('The table scrolls horizontally on small screens.');
		tipRow.appendChild(tipText);
		page.appendChild(tipRow);

		function selectedIds() {
			var ids = [];
			for (var k in checked)
				if (checked[k]) ids.push(k);
			return ids;
		}

		function renderList(list) {
			common.clear(tbody);
			targets = list;
			sumIconBox.innerHTML = icons.multiTarget(list, 34);
			if (!list.length) {
				var tr0 = common.el('tr', '');
				var td0 = common.el('td', 'nm-empty', _('No targets'));
				td0.colSpan = 12;
				tr0.appendChild(td0);
				tbody.appendChild(tr0);
				return;
			}

			for (var i = 0; i < list.length; i++) {
				(function(t, idx) {
					var tr = common.el('tr', '');
					/* UCI 段名挂到行上：实机验证脚本据此定位「哪一行是哪个目标」，
					 * 不必依赖行序（行序会被新增/删除打乱）。 */
					tr.setAttribute('data-id', t.id);

					var tdChk = common.el('td', '');
					var cb = common.el('input', '');
					cb.type = 'checkbox';
					cb.checked = !!checked[t.id];
					cb.addEventListener('change', function() { checked[t.id] = cb.checked; });
					tdChk.appendChild(cb);
					tr.appendChild(tdChk);

					tr.appendChild(common.el('td', '', t.name || t.id));
					tr.appendChild(common.el('td', 'nm-target-host', t.host || ''));

					/* 探测方式列：显示的端口取自该目标的 tcp_port，
					 * 未单独指定时回落到全局默认端口（与守护进程的取值规则一致）。 */
					var tdMethod = common.el('td', '');
					var badge, badgeTitle;
					if (t.proto === 'tcp') {
						var tport = (t.tcp_port || 0) > 0
							? t.tcp_port : (cfg.default_tcp_port || 80);
						badge = 'TCP:' + tport;
						badgeTitle = _('TCP connect') +
							(((t.tcp_port || 0) > 0) ? '' : ' · ' + _('global default port'));
					} else {
						badge = 'ICMP';
						badgeTitle = _('ICMP (ping)');
					}
					var bspan = common.el('span',
						'nm-proto-badge nm-proto-' + (t.proto === 'tcp' ? 'tcp' : 'icmp'), badge);
					bspan.title = badgeTitle;
					tdMethod.appendChild(bspan);
					tr.appendChild(tdMethod);

					var tdR = common.el('td', '');
					tdR.appendChild(common.el('span', common.regionTagClass(t.region), common.regionText(t.region)));
					tr.appendChild(tdR);

					tr.appendChild(common.el('td', '', t.label || '—'));

					var fam = { auto: _('Auto'), ipv4: _('IPv4'), ipv6: _('IPv6'), both: _('IPv4 + IPv6') };
					var tdFam = common.el('td', '');
					tdFam.style.whiteSpace = 'nowrap';
					/* 双栈图标直接反映该目标配置的地址族：ipv4/ipv6 时另一侧变灰 */
					tdFam.appendChild(common.inlineIcon(icons.dualStack(t.family, true, true, 22)));
					tdFam.appendChild(document.createTextNode(' ' + (fam[t.family] || t.family)));
					tr.appendChild(tdFam);
					tr.appendChild(common.el('td', 'nm-num', (t.interval || 0) === 0 ? _('Global') : (t.interval + 's')));
					tr.appendChild(common.el('td', 'nm-num', (t.timeout || 0) === 0 ? _('Global') : (t.timeout + 's')));
					tr.appendChild(common.el('td', '', t.interface || '—'));

					var tdEn = common.el('td', '');
					tdEn.style.whiteSpace = 'nowrap';
					tdEn.appendChild(common.inlineIcon(icons.online(20, !!t.enabled)));
					var lab = common.el('label', 'nm-switch');
					var inp = common.el('input', '');
					inp.type = 'checkbox';
					inp.checked = !!t.enabled;
					inp.addEventListener('change', function() {
						common.api.updateTarget({ id: t.id, enabled: inp.checked }).then(reload).catch(function(e) {
							common.notify(String(e.message || e), 'error');
							inp.checked = !inp.checked;
						});
					});
					lab.appendChild(inp);
					lab.appendChild(common.el('i', ''));
					tdEn.appendChild(lab);
					tr.appendChild(tdEn);

					var tdAct = common.el('td', '');
					tdAct.style.whiteSpace = 'nowrap';

					function mini(label, fn) {
						var b = common.el('button', 'nm-btn nm-btn-sm', label);
						b.style.marginRight = '4px';
						b.addEventListener('click', function() {
							b.disabled = true;
							Promise.resolve(fn()).then(reload).catch(function(e) {
								common.notify(String(e.message || e), 'error');
							}).then(function() { b.disabled = false; });
						});
						return b;
					}

					tdAct.appendChild(mini(_('Edit'), function() { return openEditor(t); }));
					tdAct.appendChild(mini('↑', function() { return common.api.moveTarget(t.id, -1); }));
					tdAct.appendChild(mini('↓', function() { return common.api.moveTarget(t.id, 1); }));
					tdAct.appendChild(mini(_('Copy'), function() { return common.api.copyTarget(t.id); }));
					tdAct.appendChild(mini(_('Delete'), function() {
						if (!window.confirm(_('Delete this target?') + ' (' + (t.name || t.id) + ')'))
							return Promise.resolve();
						return common.api.deleteTarget(t.id);
					}));

					tr.appendChild(tdAct);
					tbody.appendChild(tr);
				})(list[i], i);
			}
		}

		/* 编辑弹窗 */
		function openEditor(t) {
			var modal = common.el('div', 'nm-modal');
			var box = common.el('div', 'nm-modal-box');

			box.appendChild(common.el('h3', 'nm-modal-title', t ? _('Edit target') : _('Add target')));

			var fields = {};

			function field(label, key, control) {
				var f = common.el('div', 'nm-field');
				/* 把 UCI 键名挂到「控件」上（不要挂到 .nm-field 容器：
				 * 容器在 DOM 里排在前面，会让 [data-nm-key=x] 选中容器，
				 * 赋值变成给 div 挂临时属性，输入框纹丝不动，
				 * 实机验证会得到「看起来成功、实际没保存」的假象）。 */
				control.setAttribute('data-nm-key', key);
				f.appendChild(common.el('label', '', label));
				f.appendChild(control);
				fields[key] = control;
				box.appendChild(f);
			}

			function input(cls, value) {
				var i = common.el('input', cls || 'nm-input');
				i.value = (value == null ? '' : value);
				i.type = 'text';
				return i;
			}

			function select(options, value) {
				var s = common.el('select', 'nm-select');
				options.forEach(function(o) {
					var op = common.el('option', '', o[1]);
					op.value = o[0];
					s.appendChild(op);
				});
				s.value = value;
				return s;
			}

			/* 探测方式：icmp 默认；tcp 需要端口，端口留 0 表示跟随全局默认端口。
			 * 端口输入框在 icmp 下置灰（而不是隐藏），避免出现「选项不见了」的困惑。 */
			var protoSel = select([
				['icmp', _('ICMP (ping)')], ['tcp', _('TCP connect')]
			], t ? (t.proto || 'icmp') : (cfg.default_proto || 'icmp'));

			var portInp = input('', (t && t.tcp_port) ? t.tcp_port : '');
			portInp.type = 'number';
			portInp.min = '0';
			portInp.max = '65535';

			function syncProto() {
				var isTcp = (protoSel.value === 'tcp');
				portInp.disabled = !isTcp;
				portInp.placeholder = isTcp
					? String(cfg.default_tcp_port || 80)
					: _('Not used by ICMP');
				portInp.style.opacity = isTcp ? '' : '0.5';
			}
			protoSel.addEventListener('change', syncProto);

			field(_('Name'), 'name', input('', t ? t.name : ''));
			field(_('Address'), 'host', input('', t ? t.host : ''));
			field(_('Probe method'), 'proto', protoSel);
			field(_('TCP port (0 = global default)'), 'tcp_port', portInp);
			field(_('Region'), 'region', select([
				['cn', _('China')], ['overseas', _('Overseas')], ['other', _('Other')]
			], t ? t.region : 'cn'));
			field(_('Custom label'), 'label', input('', t ? t.label : ''));
			field(_('Address family'), 'family', select([
				['auto', _('Auto')], ['ipv4', _('IPv4 only')], ['ipv6', _('IPv6 only')], ['both', _('IPv4 + IPv6')]
			], t ? t.family : 'auto'));
			field(_('Check interval (s, 0 = global)'), 'interval', input('', t ? t.interval : 0));
			field(_('Timeout (s, 0 = global)'), 'timeout', input('', t ? t.timeout : 0));
			field(_('Interface (optional)'), 'interface', input('', t ? t.interface : ''));
			field(_('Source address (optional)'), 'source', input('', t ? t.source : ''));
			field(_('Remark'), 'remark', input('', t ? t.remark : ''));
			syncProto();

			var enRow = common.el('div', 'nm-row');
			var lab = common.el('label', 'nm-switch');
			var enInp = common.el('input', '');
			enInp.type = 'checkbox';
			enInp.checked = t ? !!t.enabled : true;
			lab.appendChild(enInp);
			lab.appendChild(common.el('i', ''));
			lab.appendChild(common.el('span', '', _('Enabled')));
			enRow.appendChild(lab);
			box.appendChild(enRow);

			var errBox = common.el('div', 'nm-modal-error');
			box.appendChild(errBox);

			var actions = common.el('div', 'nm-modal-actions');
			var btnCancel = common.el('button', 'nm-btn', _('Cancel'));
			/* 弹窗里唯一的保存入口。它是模态对话框自己的确认动作，
			 * 不是页面级的第二个「保存并应用」——页面底部那组由 LuCI 主题
			 * 渲染的按钮保持原样，插件不另外添加，避免两个入口并存。
			 * 弹窗打开时它被遮罩完全盖住，两者不会同时出现在视野里。 */
			var btnSave = common.el('button', 'nm-btn nm-btn-primary', _('Save & Apply'));

			function close() {
				if (modal.parentNode) modal.parentNode.removeChild(modal);
			}
			btnCancel.addEventListener('click', close);

			btnSave.addEventListener('click', function() {
				var proto = fields.proto.value;
				var port = parseInt(fields.tcp_port.value, 10);
				if (isNaN(port) || port < 0) port = 0;
				if (port > 65535) port = 65535;
				/* ICMP 目标不保留端口，统一存 0，避免切换协议后残留旧端口 */
				if (proto !== 'tcp') port = 0;

				var data = {
					name: fields.name.value.trim(),
					host: fields.host.value.trim(),
					proto: proto,
					tcp_port: port,
					region: fields.region.value,
					label: fields.label.value.trim(),
					family: fields.family.value,
					interval: parseInt(fields.interval.value, 10) || 0,
					timeout: parseInt(fields.timeout.value, 10) || 0,
					interface: fields.interface.value.trim(),
					source: fields.source.value.trim(),
					remark: fields.remark.value.trim(),
					enabled: enInp.checked ? '1' : '0'
				};
				if (!data.name || !data.host) {
					errBox.textContent = _('Name and address are required');
					return;
				}
				if (proto === 'tcp' && port === 0 && !(cfg.default_tcp_port > 0)) {
					errBox.textContent = _('TCP targets need a port or a global default port');
					return;
				}
				btnSave.disabled = true;
				btnCancel.disabled = true;

				/* 「保存」与「应用」都复用 OpenWRT 自带的机制：
				 *
				 *   写配置  common.saveConfig / common.addSection
				 *           → 原生 uci 事务（uci.set/unset/add），把改动推入
				 *             rpcd 会话的「待应用更改」；此时只进会话，不落盘
				 *
				 *   应用    common.applyChanges()
				 *           → LuCI「保存并应用」按钮背后的 ui.changes.apply(true)，
				 *             即 POST admin/uci/apply_rollback →
				 *             ubus call uci apply { rollback:true, timeout>=90 }
				 *             → 提交配置 + /sbin/reload_config → procd reload
				 *               trigger 触发 /etc/init.d/netmonitor reload
				 *
				 * 应用过程本身也由 LuCI 负责：官方的「正在应用配置更改… Ns」
				 * 提示、连接性变更确认、应用后失联的自动回滚、成功后重载页面，
				 * 插件都不再自建一套，因此不存在两条提交通道并存的差异。 */
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
					/* changed 为 0 表示填的值与设备现状完全一致。此时不能调用
					 * applyChanges()：没有待提交改动时 rpcd 的 uci.apply 会直接
					 * 报错（实测 ubus code 5）。 */
					if (changed === 0) {
						close();
						common.notify(_('No changes to save'));
						return;
					}
					close();
					/* 这里刻意不刷新表格：改动还在 rpcd 会话里、尚未落盘，
					 * 立即回读只会拿到旧值。官方 apply 完成后 LuCI 会重载页面，
					 * 届时读到的就是新配置。 */
					return common.applyChanges();
				}).catch(function(e) {
					/* 写入阶段失败时弹窗还在，错误照常显示在弹窗内；
					 * 应用阶段失败时弹窗已关闭，由 LuCI 自己的状态提示负责告知。 */
					if (!modal.parentNode)
						return;
					errBox.textContent = String(e.message || e);
					btnSave.disabled = false;
					btnCancel.disabled = false;
				});
			});

			actions.appendChild(btnCancel);
			actions.appendChild(btnSave);
			box.appendChild(actions);

			modal.appendChild(box);
			modal.addEventListener('click', function(ev) {
				if (ev.target === modal) close();
			});
			document.body.appendChild(modal);
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
