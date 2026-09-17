/*
 * 设置页面：全局参数、后台服务控制、历史数据维护
 *
 * 关键教训（本页曾经「设置项一个都不显示」的真正原因）
 * ---------------------------------------------------------------
 * 旧实现用 `new form.JSONMap({}, ...)` 承载 UCI 表单，5 个分区都是
 * `m.section(form.NamedSection, 'global', 'netmonitor', 标题)`。
 * 对固件里的 /luci-static/resources/form.js 逐行核对后可以确定：
 *
 *   1. CBIJSONMap.__init__ 里 `this.data = new CBIJSONConfig(data)`，
 *      而 CBIJSONConfig.get() 的实现是
 *          get(config, section, option) {
 *              if (section == null) return null;
 *              if (option == null)  return this.data[section];
 *              ...
 *          }
 *      传给 JSONMap 的数据是空对象 {}，于是 get('json', 'global') 返回 undefined。
 *
 *   2. CBINamedSection.render() 正是拿这个值当 ucidata：
 *          render() {
 *              return Promise.all([this.map.data.get(config_name, this.section),
 *                                  this.renderUCISection(this.section)])
 *                     .then(this.renderContents.bind(this));
 *          }
 *      而 renderContents(data) 中只有 `if (ucidata) { ...渲染选项... }` 分支。
 *      ucidata 为假 → 选项整块被跳过，页面上只剩下一个由 section_id 派生的
 *      `<div id="cbi-json-global" class="cbi-section"><h3>标题</h3></div>`，
 *      连 h3 下面的选项容器都不存在。实测 5 个分区全部如此：cbiValue 计数为 0。
 *
 *   3. 顺带确认的两点：
 *      * `m.submit = false` / `m.reset = false` 在本固件版本的 form.js 里
 *        根本没有被引用，是无效写法；
 *      * 该 form.js 也不提供任何 Save / Apply 按钮（全文无 cbi-page-actions /
 *        handleSaveApply），所以旧页面即便渲染出选项也无处保存。
 *
 * 因此本页改为与 overview / targets 等页面一致的纯 DOM 实现。
 *
 * 读取与写入刻意走不同但各自更合适的接口：
 *   * 读取用 get_config RPC：它按后端 DEFAULTS 补齐缺省值并做 clamp，
 *     是默认值语义的唯一权威，界面因此永远显示「设备实际生效的值」；
 *   * 写入用 OpenWrt 原生 uci 事务（uci.set → uci.save() → 推入 rpcd 会话的
 *     「待应用更改」），应用则复用 LuCI「保存并应用」按钮背后的
 *     ui.changes.apply（见 common.applyChanges）：提交配置 →
 *     /sbin/reload_config → procd 的 reload trigger 重载
 *     /etc/init.d/netmonitor，应用后设备失联会自动回滚。
 *   * 保存成功后界面不再自己回读写回值：官方 apply 完成时 LuCI 会重载页面，
 *     重载后看到的一律是「已经落盘生效的值」，不是用户刚敲进去的值。
 */

'use strict';
'require view';
'require poll';
'require netmonitor.common as common';
'require netmonitor.icons as icons';

/* 全局设置字段定义。
 *
 * 这里刻意「全部字段始终可见」：本页此前的故障就是选项被静默丢弃，
 * 所以不再使用 depends() 那种「条件为假就整块不渲染」的机制。
 * 字段的适用范围写进说明文字，靠文字说清楚，不靠隐藏。
 *
 * kind：flag 开关 / int 整数 / enum 下拉 / text 文本
 * 每一项都必须与后端 GLOBAL_OPTS 的键名一一对应。 */
function fieldGroups() {
	return [
		{
			title: _('Detection'),
			desc: _('How the background daemon probes every target.'),
			icon: function() { return icons.ping(46, { grade: 'good' }); },
			fields: [
				{
					key: 'enabled', kind: 'flag',
					title: _('Enable monitoring'),
					desc: _('Master switch. When disabled the background daemon stops probing.')
				},
				{
					key: 'default_proto', kind: 'enum',
					title: _('Default probe method'),
					desc: _('ICMP echo (ping) by default. TCP connect measures the TCP handshake time to a port and still works on networks that drop ICMP. A target can override this.'),
					values: [['icmp', _('ICMP (ping)')], ['tcp', _('TCP connect')]]
				},
				{
					key: 'default_tcp_port', kind: 'int', min: 1, max: 65535,
					title: _('Default TCP port'),
					desc: _('Used by TCP targets that do not specify a port of their own. Allowed range 1-65535.')
				},
				{
					key: 'interval', kind: 'int', min: 1, max: 3600,
					title: _('Check interval (seconds)'),
					desc: _('Recommended values: 1, 5, 10, 15, 30, 60, 120, 300. Allowed range 1-3600.')
				},
				{
					key: 'timeout', kind: 'int', min: 1, max: 30,
					title: _('Probe timeout (seconds)'),
					desc: _('Per-packet wait time before a probe is considered lost.')
				},
				{
					key: 'count', kind: 'int', min: 1, max: 20,
					title: _('Packets per probe'),
					desc: _('ICMP only. Higher values give better loss statistics but cost more time. TCP always performs a single connect.')
				},
				{
					key: 'concurrency', kind: 'int', min: 1, max: 50,
					title: _('Concurrent probes'),
					desc: _('Maximum number of targets probed in parallel.')
				},
				{
					key: 'address_family', kind: 'enum',
					title: _('Address family'),
					desc: _('Which protocol family the probes use. A target can override this.'),
					values: [['auto', _('Auto')], ['ipv4', _('IPv4 only')], ['ipv6', _('IPv6 only')]]
				},
				{
					key: 'interface', kind: 'text',
					title: _('Outbound interface (optional)'),
					desc: _('Example: wan, wwan. Leave empty to use the system default route.')
				},
				{
					key: 'source', kind: 'text',
					title: _('Source address (optional)'),
					desc: _('Bind probes to a specific source IP address.')
				}
			]
		},
		{
			title: _('Data retention'),
			desc: _('Where samples are kept and how long they survive.'),
			icon: function() { return icons.database(46); },
			fields: [
				{
					key: 'persistence', kind: 'flag',
					title: _('Persistent history'),
					desc: _('Write aggregated samples to flash periodically. Disabled by default to protect flash lifetime.')
				},
				{
					key: 'history', kind: 'enum',
					title: _('History retention'),
					desc: _('How long aggregated samples are kept on flash when persistence is enabled.'),
					values: [['1h', _('1 hour')], ['6h', _('6 hours')], ['12h', _('12 hours')],
					         ['24h', _('24 hours')], ['3d', _('3 days')], ['7d', _('7 days')],
					         ['30d', _('30 days')]]
				},
				{
					key: 'persist_interval', kind: 'int', min: 60, max: 3600,
					title: _('Flush interval (seconds)'),
					desc: _('How often aggregated data is written to flash. Larger values mean fewer writes.')
				},
				{
					key: 'max_points', kind: 'int', min: 60, max: 200000,
					title: _('In-memory samples per target'),
					desc: _('Ring buffer size in tmpfs. 4320 samples at a 10s interval covers about 12 hours.')
				}
			]
		},
		{
			title: _('Thresholds'),
			desc: _('Values used to turn raw measurements into a quality grade.'),
			icon: function() { return icons.gear(46); },
			fields: [
				{
					key: 'latency_excellent', kind: 'int', min: 1, max: 10000,
					title: _('Excellent below (ms)'),
					desc: _('Latency below this value is graded Excellent.')
				},
				{
					key: 'latency_good', kind: 'int', min: 1, max: 10000,
					title: _('Good below (ms)'),
					desc: _('Latency below this value is graded Good.')
				},
				{
					key: 'latency_fair', kind: 'int', min: 1, max: 10000,
					title: _('Fair below (ms)'),
					desc: _('Latency below this value is graded Fair.')
				},
				{
					key: 'latency_poor', kind: 'int', min: 1, max: 10000,
					title: _('Poor below (ms)'),
					desc: _('Latency at or above this value is graded Severe.')
				},
				{
					key: 'loss_warn', kind: 'int', min: 0, max: 100,
					title: _('Loss warning (%)'),
					desc: _('Packet loss at or above this percentage is considered a warning.')
				},
				{
					key: 'loss_critical', kind: 'int', min: 0, max: 100,
					title: _('Loss critical (%)'),
					desc: _('Packet loss at or above this percentage is considered critical.')
				},
				{
					key: 'fail_warn', kind: 'int', min: 1, max: 100,
					title: _('Consecutive failures to warn'),
					desc: _('After this many consecutive failures the target is graded Severe.')
				},
				{
					key: 'fail_critical', kind: 'int', min: 1, max: 1000,
					title: _('Consecutive failures to critical'),
					desc: _('After this many consecutive failures the target is graded Offline.')
				}
			]
		},
		{
			title: _('Interface & logging'),
			desc: _('Front-end refresh rate and log verbosity.'),
			icon: function() { return icons.clock(null, 46); },
			fields: [
				{
					key: 'ui_refresh', kind: 'int', min: 1, max: 60,
					title: _('UI refresh interval (seconds)'),
					desc: _('How often the page fetches new state. Independent from the probe interval.')
				},
				{
					key: 'log_level', kind: 'enum',
					title: _('Log level'),
					desc: _('Normal probes are never logged. Only state changes and failures produce log entries.'),
					values: [['debug', _('Debug')], ['info', _('Info')],
					         ['warning', _('Warning')], ['error', _('Error')]]
				}
			]
		},
		{
			title: _('Notification (reserved)'),
			desc: _('The notification backend is not implemented yet.'),
			icon: function() { return icons.bell(0, 46); },
			fields: [
				{
					key: 'notify_enabled', kind: 'flag',
					title: _('Enable notification'),
					desc: _('Reserved for future webhook / Telegram / WeCom / DingTalk / mail support. Has no effect yet.')
				},
				{
					key: 'notify_url', kind: 'text',
					title: _('Notification endpoint'),
					desc: _('Reserved. Leave empty until a notification backend is available.')
				}
			]
		}
	];
}

return view.extend({
	load: function() {
		common.css();
		return Promise.all([
			common.loadI18n(),
			common.api.getConfig(),
			common.api.serviceStatus().catch(function() {
				return { running: false, tick: 0 };
			})
		]);
	},

	render: function(res) {
		common.css();

		var cfg = (res && res[1]) || {};
		var svc = (res && res[2]) || {};

		var root = common.el('div', 'nm-root');
		var page = common.el('div', 'nm-page');
		root.appendChild(page);

		/* 每个字段的控件与元信息：key -> { kind, el, min, max } */
		var controls = {};
		/* 载入基线：与 collect() 的输出可直接字符串比较，用于判断「有无改动」 */
		var baseline = {};
		var btnSave = null, btnDiscard = null, dirtyTag = null;

		if (!Object.prototype.hasOwnProperty.call(cfg, 'default_proto'))
			cfg.default_proto = 'icmp';
		if (!Object.prototype.hasOwnProperty.call(cfg, 'default_tcp_port'))
			cfg.default_tcp_port = '80';

		/* ---------------------------------------------------- 服务控制 */
		var svcCard = common.el('div', 'nm-card');
		var svcRow = common.el('div', 'nm-row');
		var svcIcon = common.el('div', '');
		svcRow.appendChild(svcIcon);
		var svcText = common.el('div', 'nm-card-sub', '');
		svcRow.appendChild(svcText);
		svcRow.appendChild(common.el('div', 'nm-spacer'));

		function svcBtn(label, fn, cls) {
			var b = common.el('button', 'nm-btn ' + (cls || ''), label);
			b.addEventListener('click', function() {
				b.disabled = true;
				Promise.resolve().then(fn).then(function() {
					common.notify(_('Operation completed'));
					refreshSvc();
				}).catch(function(e) {
					common.notify(String(e.message || e), 'error');
				}).then(function() { b.disabled = false; });
			});
			return b;
		}

		svcRow.appendChild(svcBtn(_('Start'), common.api.startService, 'nm-btn-primary'));
		svcRow.appendChild(svcBtn(_('Stop'), common.api.stopService));
		svcRow.appendChild(svcBtn(_('Restart'), common.api.restartService));
		svcCard.appendChild(svcRow);

		var clearRow = common.el('div', 'nm-row');
		clearRow.style.marginTop = '12px';
		clearRow.appendChild(common.el('div', 'nm-card-sub',
			_('Clear all collected samples and persistent history')));
		clearRow.appendChild(common.el('div', 'nm-spacer'));
		var btnClear = common.el('button', 'nm-btn nm-btn-danger', _('Clear history'));
		btnClear.addEventListener('click', function() {
			if (!window.confirm(_('Clear all collected history data?'))) return;
			btnClear.disabled = true;
			common.api.clearHistory(null).then(function() {
				common.notify(_('History cleared'));
			}).catch(function(e) {
				common.notify(String(e.message || e), 'error');
			}).then(function() { btnClear.disabled = false; });
		});
		clearRow.appendChild(btnClear);
		svcCard.appendChild(clearRow);
		page.appendChild(svcCard);

		function refreshSvc() {
			return common.api.serviceStatus().then(function(d) {
				common.clear(svcIcon);
				svcIcon.appendChild(common.svgBox(icons.service(!!d.running, 30), ''));
				svcText.textContent = (d.running ? _('Service running') : _('Service stopped')) +
					' · ' + _('Last update') + ': ' + (d.tick ? common.fmt.ago(d.tick) : _('Never checked'));
			}).catch(function() {
				common.clear(svcIcon);
				svcIcon.appendChild(common.svgBox(icons.service(false, 30), ''));
				svcText.textContent = _('Service stopped');
			});
		}

		/* ---------------------------------------------------- 生效值速览 */
		var strip = common.el('div', 'nm-grid');
		page.appendChild(strip);

		/* 速览卡片的数值一律来自设备回读的配置对象，图标与数值一一对应。 */
		function renderStrip(v) {
			common.clear(strip);

			var interval = String(v.interval == null ? '10' : v.interval);
			var timeout = String(v.timeout == null ? '3' : v.timeout);
			var count = String(v.count == null ? '1' : v.count);
			var conc = String(v.concurrency == null ? '5' : v.concurrency);
			var persist = String(v.persistence == null ? '0' : v.persistence);
			var hist = String(v.history == null ? '24h' : v.history);
			var fam = String(v.address_family == null ? 'auto' : v.address_family);
			var notify = String(v.notify_enabled == null ? '0' : v.notify_enabled);
			var enabled = String(v.enabled == null ? '1' : v.enabled);
			var proto = String(v.default_proto == null ? 'icmp' : v.default_proto);
			var port = String(v.default_tcp_port == null ? '80' : v.default_tcp_port);
			var v6 = (fam === 'ipv6');

			/* 探测方式卡片：图标语义随 ICMP / TCP 切换 */
			strip.appendChild(common.iconCard(_('Default probe method'),
				(proto === 'tcp') ? _('TCP connect') : _('ICMP (ping)'),
				(proto === 'tcp') ? _('Handshake timing to port') + ': ' + port
				                  : _('Echo request / reply'),
				icons.ping(58, { grade: 'good' }), 'nm-c-ok'));

			strip.appendChild(common.iconCard(_('Check interval'), interval + ' s',
				_('Packets per probe') + ': ' + count,
				icons.ping(58, { grade: 'good' }), 'nm-c-ok'));

			strip.appendChild(common.iconCard(_('Probe timeout'), timeout + ' s',
				_('Concurrent probes') + ': ' + conc, icons.gear(58)));

			strip.appendChild(common.iconCard(_('Persistent history'),
				(persist === '1') ? _('Enabled') : _('Disabled'),
				_('Retention') + ': ' + hist, icons.database(58),
				(persist === '1') ? 'nm-c-warn' : 'nm-c-ok'));

			strip.appendChild(common.iconCard(_('Address family'), fam,
				_('Master switch') + ': ' + ((enabled === '1') ? _('Enabled') : _('Disabled')),
				icons.dualStack(fam, fam !== 'ipv6', v6, 58)));

			strip.appendChild(common.iconCard(_('Enable notification'),
				(notify === '1') ? _('Enabled') : _('Disabled'),
				_('Reserved') + ' · ' + _('Thresholds'), icons.bell(0, 58)));

			strip.appendChild(common.iconCard(_('UI refresh interval'),
				String(v.ui_refresh == null ? '2' : v.ui_refresh) + ' s',
				_('Independent from the probe interval'), icons.clock(null, 58)));
		}

		/* ---------------------------------------------------- 表单控件 */
		function switchControl(key, value) {
			var lab = common.el('label', 'nm-switch');
			var inp = common.el('input', '');
			inp.type = 'checkbox';
			inp.checked = (value === '1' || value === 1 || value === true);
			lab.appendChild(inp);
			lab.appendChild(common.el('i', ''));
			var txt = common.el('span', '', inp.checked ? _('Enabled') : _('Disabled'));
			lab.appendChild(txt);
			inp.addEventListener('change', function() {
				txt.textContent = inp.checked ? _('Enabled') : _('Disabled');
				markDirty();
			});
			return { kind: 'flag', el: inp };
		}

		function intControl(key, value, min, max) {
			var inp = common.el('input', 'nm-input nm-num-input');
			inp.type = 'number';
			inp.step = '1';
			inp.min = String(min);
			inp.max = String(max);
			inp.value = (value == null ? '' : String(value));
			inp.addEventListener('input', markDirty);
			inp.addEventListener('change', markDirty);
			return { kind: 'int', el: inp, min: min, max: max };
		}

		function enumControl(key, value, values) {
			var sel = common.el('select', 'nm-select');
			values.forEach(function(o) {
				var op = common.el('option', '', o[1]);
				op.value = o[0];
				sel.appendChild(op);
			});
			sel.value = (value == null ? '' : String(value));
			/* 值不在候选项里时（例如手工改过配置文件），补一个当前值，
			 * 避免下拉框静默回落到第一项后又被保存回去。 */
			if (sel.selectedIndex < 0) {
				var op2 = common.el('option', '', String(value) + ' ' + _('(current)'));
				op2.value = String(value);
				sel.appendChild(op2);
				sel.value = String(value);
			}
			sel.addEventListener('change', markDirty);
			return { kind: 'enum', el: sel };
		}

		function textControl(key, value) {
			var inp = common.el('input', 'nm-input');
			inp.type = 'text';
			inp.value = (value == null ? '' : String(value));
			inp.addEventListener('input', markDirty);
			inp.addEventListener('change', markDirty);
			return { kind: 'text', el: inp };
		}

		/* ---------------------------------------------------- 表单渲染 */
		var groups = fieldGroups();

		groups.forEach(function(g) {
			var card = common.el('div', 'nm-card');
			var head = common.el('div', 'nm-group-head');
			var ibox = common.el('span', 'nm-group-icon');
			ibox.innerHTML = g.icon();
			head.appendChild(ibox);
			var htxt = common.el('div', '');
			htxt.appendChild(common.el('div', 'nm-card-title', g.title));
			if (g.desc)
				htxt.appendChild(common.el('div', 'nm-card-sub', g.desc));
			head.appendChild(htxt);
			card.appendChild(head);
			card.appendChild(common.el('div', 'nm-group-sep'));

			g.fields.forEach(function(f) {
				var row = common.el('div', 'nm-setting');
				var main = common.el('div', 'nm-setting-main');
				main.appendChild(common.el('div', 'nm-setting-title', f.title));
				if (f.desc)
					main.appendChild(common.el('div', 'nm-setting-desc', f.desc));
				row.appendChild(main);

				var ctlBox = common.el('div', 'nm-setting-ctl');
				var ctl;
				if (f.kind === 'flag')
					ctl = switchControl(f.key, cfg[f.key]);
				else if (f.kind === 'int')
					ctl = intControl(f.key, cfg[f.key], f.min, f.max);
				else if (f.kind === 'enum')
					ctl = enumControl(f.key, cfg[f.key], f.values);
				else
					ctl = textControl(f.key, cfg[f.key]);

				ctl.el.setAttribute('data-nm-key', f.key);
				ctlBox.appendChild(ctl.el);
				row.appendChild(ctlBox);
				card.appendChild(row);
				controls[f.key] = ctl;
			});

			page.appendChild(card);
		});

		/* ---------------------------------------------------- 采集与保存 */
		function valueOf(k) {
			var c = controls[k];
			if (c.kind === 'flag') return c.el.checked ? '1' : '0';
			return String(c.el.value == null ? '' : c.el.value).trim();
		}

		function collect() {
			var o = {};
			for (var k in controls) o[k] = valueOf(k);
			return o;
		}

		/* 载入基线：以设备返回的值为准（后端会补默认值，前端不做二次猜测） */
		function takeBaseline(v) {
			var o = {};
			for (var k in controls) {
				var raw = v[k];
				o[k] = (raw == null) ? '' : String(raw);
			}
			return o;
		}

		/* 保存前的本地校验：只为给出即时反馈，最终取值范围仍由设备侧决定。
		 * 返回错误文案，或 null 表示通过。 */
		function validate(v) {
			for (var k in controls) {
				var c = controls[k];
				if (c.kind !== 'int') continue;
				var s = v[k];
				if (s === '' || !/^[0-9]+$/.test(s)) {
					var t = c.el.getAttribute('data-title') || k;
					return t + ': ' + _('Please enter a whole number');
				}
				var n = parseInt(s, 10);
				if (n < c.min || n > c.max) {
					var t2 = c.el.getAttribute('data-title') || k;
					return t2 + ': ' + _('Allowed range') + ' ' + c.min + '-' + c.max;
				}
			}
			return null;
		}

		function sameAsBaseline(v) {
			for (var k in baseline)
				if ((v[k] || '') !== (baseline[k] || '')) return false;
			return true;
		}

		function markDirty() {
			var isDirty = !sameAsBaseline(collect());
			if (btnSave) btnSave.disabled = !isDirty;
			if (btnDiscard) btnDiscard.disabled = !isDirty;
			if (dirtyTag) {
				dirtyTag.textContent = isDirty ? _('Unsaved changes') : _('All changes applied');
				dirtyTag.className = 'nm-card-sub' + (isDirty ? ' nm-dirty' : '');
			}
		}

		var actCard = common.el('div', 'nm-card');
		var actRow = common.el('div', 'nm-row');
		btnSave = common.el('button', 'nm-btn nm-btn-primary', _('Save & Apply'));
		btnDiscard = common.el('button', 'nm-btn', _('Discard changes'));
		dirtyTag = common.el('div', 'nm-card-sub');

		btnSave.addEventListener('click', function() {
			var v = collect();
			var bad = validate(v);
			if (bad) { common.notify(bad, 'error'); return; }
			btnSave.disabled = true;

			/* 保存与应用都复用 OpenWRT 自带的机制，与 targets 编辑弹窗一致：
			 *   写入 common.saveConfig → 原生 uci 事务，推入 rpcd 会话的待应用更改
			 *   应用 common.applyChanges → LuCI「保存并应用」按钮背后的
			 *        ui.changes.apply(true)（POST admin/uci/apply_rollback）
			 * 插件不再自己调用 uci.apply()，全插件只剩这一条提交通道；
			 * 应用期间的状态提示、连接性变更确认、失联自动回滚、成功后重载页面
			 * 都由 LuCI 负责，不再自建。 */
			var ops = [];
			for (var k in v)
				ops.push({ sid: 'global', opt: k, val: v[k] });

			common.saveConfig(ops).then(function(changed) {
				/* 无改动时不能调用 applyChanges()：没有待提交改动时 rpcd
				 * 的 uci.apply 会直接报错（实测 ubus code 5）。 */
				if (changed === 0) {
					common.notify(_('No changes to save'));
					return;
				}
				return common.applyChanges();
			}).catch(function(e) {
				common.notify(String(e.message || e), 'error');
			}).then(function() {
				btnSave.disabled = false;
				markDirty();
			});
		});

		btnDiscard.addEventListener('click', function() {
			applyConfig(cfg);
			common.notify(_('Changes discarded'));
		});

		actRow.appendChild(btnSave);
		actRow.appendChild(btnDiscard);
		actRow.appendChild(common.el('div', 'nm-spacer'));
		actRow.appendChild(dirtyTag);
		actCard.appendChild(actRow);
		page.appendChild(actCard);

		/* 用一份配置对象刷新整个页面：输入框、速览卡片与基线同步更新。
		 * 保存后走一次，保证界面显示的就是设备里实际生效的值。 */
		function applyConfig(v) {
			cfg = v;
			for (var k in controls) {
				var c = controls[k];
				var raw = v[k];
				var s = (raw == null) ? '' : String(raw);
				if (c.kind === 'flag') {
					c.el.checked = (s === '1');
					var txt = c.el.parentNode.querySelector('span');
					if (txt) txt.textContent = c.el.checked ? _('Enabled') : _('Disabled');
				}
				else if (c.el.value !== s) {
					c.el.value = s;
				}
			}
			baseline = takeBaseline(v);
			renderStrip(v);
			markDirty();
		}

		/* 给整型输入挂上标题，便于本地校验提示带上字段名 */
		groups.forEach(function(g) {
			g.fields.forEach(function(f) {
				if (f.kind === 'int')
					controls[f.key].el.setAttribute('data-title', f.title);
			});
		});

		applyConfig(cfg);

		refreshSvc();
		poll.add(refreshSvc, 10);

		return root;
	}
});
