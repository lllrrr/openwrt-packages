/*
 * 设置页面：全局参数、后台服务控制、历史数据维护
 *
 * UI 结构：服务控制 / 保存 / 放弃等按钮用 ui.button()（原生 <button>），
 * 确认弹窗用 ui.confirm()，状态胶囊为纯 DOM。
 * 不再依赖 TDesign Web Components —— 原 <t-dialog> 因随包样式表残缺
 * （无 dialog 定位规则）而停在 display:none 状态，导致弹窗点了毫无反应，
 * 详见 netmonitor/ui.js 文件头。
 *
 * 表单控件（开关 / 数字 / 下拉 / 文本）本来就是原生 HTML 元素：早期版本的
 * t-switch / t-input-number / t-select / t-input 基于 Omi 框架，受控模式下
 * 点击与下拉交互实测失效，故早已改为原生控件，本次不再改动。
 *
 * 采用纯 DOM 渲染，杜绝 CBI/JSONMap 静默吞选项问题。
 */

'use strict';
'require view';
'require poll';
'require netmonitor.common as common';
'require netmonitor.icons as icons';

/* 全局设置字段定义 */
function fieldGroups() {
	return [
		{
			title: _('探测'),
			desc: _('后台守护进程如何探测每个目标。'),
			icon: function() { return icons.ping(44, { grade: 'good' }); },
			fields: [
				{
					key: 'enabled', kind: 'flag',
					title: _('启用监控'),
					desc: _('总开关。关闭后后台守护进程停止探测。')
				},
				{
					key: 'default_proto', kind: 'enum',
					title: _('默认探测方式'),
					desc: _('默认使用 ICMP 回显（ping）。TCP 连接测量到指定端口的握手耗时，在丢弃 ICMP 的网络中仍可用；单个目标可单独覆盖此设置。'),
					values: [['icmp', _('ICMP（ping）')], ['tcp', _('TCP 连接')]]
				},
				{
					key: 'default_tcp_port', kind: 'int', min: 1, max: 65535,
					title: _('默认 TCP 端口'),
					desc: _('供未指定端口的 TCP 目标使用，允许范围 1-65535。')
				},
				{
					key: 'interval', kind: 'int', min: 1, max: 3600,
					title: _('检测间隔（秒）'),
					desc: _('推荐值：1、5、10、15、30、60、120、300，允许范围 1-3600。')
				},
				{
					key: 'timeout', kind: 'int', min: 1, max: 30,
					title: _('探测超时（秒）'),
					desc: _('单包等待时间，超过即视为探测丢失。')
				},
				{
					key: 'count', kind: 'int', min: 1, max: 20,
					title: _('每次探测包数'),
					desc: _('仅 ICMP。数值越大丢包统计越准确，但耗时更长；TCP 始终只做一次连接。')
				},
				{
					key: 'concurrency', kind: 'int', min: 1, max: 50,
					title: _('并发探测数'),
					desc: _('同时并行探测的最大目标数。')
				},
				{
					key: 'address_family', kind: 'enum',
					title: _('地址族'),
					desc: _('探测使用的协议族，单个目标可单独覆盖。'),
					values: [['auto', _('自动')], ['ipv4', _('仅 IPv4')], ['ipv6', _('仅 IPv6')]]
				},
				{
					key: 'interface', kind: 'text',
					title: _('出口接口（可选）'),
					desc: _('例如：wan、wwan，留空则使用系统默认路由。')
				},
				{
					key: 'source', kind: 'text',
					title: _('源地址（可选）'),
					desc: _('将探测绑定到指定的源 IP 地址。')
				}
			]
		},
		{
			title: _('数据保留'),
			desc: _('样本的存储位置与保留时长。'),
			icon: function() { return icons.database(44); },
			fields: [
				{
					key: 'persistence', kind: 'flag',
					title: _('持久化历史'),
					desc: _('定期将聚合样本写入闪存，默认关闭以保护闪存寿命。')
				},
				{
					key: 'history', kind: 'enum',
					title: _('历史保留时长'),
					desc: _('启用持久化后，聚合样本在闪存上的保留时长。'),
					values: [['1h', _('1 小时')], ['6h', _('6 小时')], ['12h', _('12 小时')],
					         ['24h', _('24 小时')], ['3d', _('3 天')], ['7d', _('7 天')],
					         ['30d', _('30 天')]]
				},
				{
					key: 'persist_interval', kind: 'int', min: 60, max: 3600,
					title: _('写入间隔（秒）'),
					desc: _('聚合数据写入闪存的频率，数值越大写入次数越少。')
				},
				{
					key: 'max_points', kind: 'int', min: 60, max: 200000,
					title: _('每个目标的内存样本数'),
					desc: _('tmpfs 中的环形缓冲区大小；10 秒间隔下 4320 个样本约覆盖 12 小时。')
				}
			]
		},
		{
			title: _('阈值'),
			desc: _('将原始测量值转换为质量等级的判定标准。'),
			icon: function() { return icons.gear(44); },
			fields: [
				{
					key: 'latency_excellent', kind: 'int', min: 1, max: 10000,
					title: _('优秀阈值（毫秒）'),
					desc: _('延迟低于该值判定为优秀。')
				},
				{
					key: 'latency_good', kind: 'int', min: 1, max: 10000,
					title: _('良好阈值（毫秒）'),
					desc: _('延迟低于该值判定为良好。')
				},
				{
					key: 'latency_fair', kind: 'int', min: 1, max: 10000,
					title: _('一般阈值（毫秒）'),
					desc: _('延迟低于该值判定为一般。')
				},
				{
					key: 'latency_poor', kind: 'int', min: 1, max: 10000,
					title: _('较差阈值（毫秒）'),
					desc: _('延迟达到或超过该值判定为严重。')
				},
				{
					key: 'loss_warn', kind: 'int', min: 0, max: 100,
					title: _('丢包告警（%）'),
					desc: _('丢包率达到或超过该百分比视为告警。')
				},
				{
					key: 'loss_critical', kind: 'int', min: 0, max: 100,
					title: _('丢包严重（%）'),
					desc: _('丢包率达到或超过该百分比视为严重。')
				},
				{
					key: 'fail_warn', kind: 'int', min: 1, max: 100,
					title: _('连续失败告警次数'),
					desc: _('连续失败达到该次数后判定为严重。')
				},
				{
					key: 'fail_critical', kind: 'int', min: 1, max: 1000,
					title: _('连续失败严重次数'),
					desc: _('连续失败达到该次数后判定为离线。')
				}
			]
		},
		{
			title: _('界面与日志'),
			desc: _('前端刷新频率与日志详细程度。'),
			icon: function() { return icons.clock(null, 44); },
			fields: [
				{
					key: 'ui_refresh', kind: 'int', min: 1, max: 60,
					title: _('界面刷新间隔（秒）'),
					desc: _('页面获取新状态的频率，与探测间隔相互独立。')
				},
				{
					key: 'log_level', kind: 'enum',
					title: _('日志级别'),
					desc: _('正常探测不产生日志，仅状态变化与失败会记录。'),
					values: [['debug', _('调试')], ['info', _('信息')],
					         ['warning', _('警告')], ['error', _('错误')]]
				}
			]
		},
		{
			title: _('通知（预留）'),
			desc: _('通知后端尚未实现。'),
			icon: function() { return icons.bell(0, 44); },
			fields: [
				{
					key: 'notify_enabled', kind: 'flag',
					title: _('启用通知'),
					desc: _('为将来的 webhook / Telegram / 企业微信 / 钉钉 / 邮件支持预留，暂不生效。')
				},
				{
					key: 'notify_url', kind: 'text',
					title: _('通知地址'),
					desc: _('预留，在通知后端可用前留空。')
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
			/* 取不到配置不能整体失败：getConfig 的 RPC 被 rpcd 拒绝（ubus 对象未注册 /
			 * 会话 ACL 未刷新）时 Promise.all 会 reject，LuCI 框架直接显示「加载失败」，
			 * 用户连表单和诊断横幅都看不到。这里降级成 null，交给 render 的
			 * cfgEmpty 判断去渲染「无法从后端读取配置」横幅。 */
			common.api.getConfig().catch(function() {
				return null;
			}),
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

		var controls = {};
		var baseline = {};
		var btnSave = null, btnDiscard = null, dirtyTag = null;

		/* 配置读取失败兜底：get_config 正常时必然带齐全部全局键，一个都不在
		 * 说明 RPC 返回为空（rpcd 缓存旧 ucode / 会话 ACL 未刷新 / 浏览器缓存
		 * 旧页面 都会造成这个现象）。此时不再静默渲染一张空白表单，而是先给出
		 * 可操作的诊断提示，避免「表单全空又看不出原因」的困惑。
		 * 必须放在 default_proto / default_tcp_port 兜底之前：那两个兜底会往
		 * 空对象里写键，导致下面的 some() 误判 cfg 非空。 */
		var cfgEmpty = !['enabled', 'interval', 'timeout', 'count', 'concurrency',
			'address_family', 'default_proto', 'default_tcp_port', 'interface', 'source',
			'persistence', 'history', 'persist_interval', 'max_points', 'ui_refresh',
			'log_level', 'fail_warn', 'fail_critical', 'loss_warn', 'loss_critical',
			'latency_excellent', 'latency_good', 'latency_fair', 'latency_poor',
			'notify_enabled', 'notify_url'].some(function(k) {
			return Object.prototype.hasOwnProperty.call(cfg, k);
		});
		if (cfgEmpty) {
			page.appendChild(common.banner(
				_('无法从后端读取配置（RPC 调用失败或返回为空）。') +
					_('请重启 rpcd 后重新登录 LuCI，并执行 ubus call luci.netmonitor get_config 检查后端。'),
				'warn'));
		}

		if (!Object.prototype.hasOwnProperty.call(cfg, 'default_proto'))
			cfg.default_proto = 'icmp';
		if (!Object.prototype.hasOwnProperty.call(cfg, 'default_tcp_port'))
			cfg.default_tcp_port = '80';

		/* ---------------------------------------------------- 服务控制面板 */
		var svcCard = common.tcard('nm-svc-panel');
		var svcRow = common.el('div', 'nm-svc-row-top');

		var svcIcon = common.el('div', 'nm-svc-info');
		svcRow.appendChild(svcIcon);
		var svcText = common.el('div', 'nm-svc-text', '');
		svcRow.appendChild(svcText);

		var spacerSvc = common.el('div', 'nm-spacer');
		spacerSvc.style.flex = '1';
		svcRow.appendChild(spacerSvc);

		/* 服务控制按钮。disabled 由 refreshSvc 按实时运行态刷新：
		 * 避免「服务已在运行还去点启动」这种无意义请求，也让当前状态
		 * 一眼可辨。Restart 两种状态下都有效，始终可点。 */
		var btnStart, btnStop;

		function svcBtn(label, fn, isPrimary) {
			return common.ui.button({
				label: label,
				theme: isPrimary ? 'primary' : 'default',
				variant: 'outline',
				onClick: function() {
					/* 请求期间的禁用与失败提示由 ui.button 统一处理 */
					return Promise.resolve().then(fn).then(function() {
						common.notify(_('操作已完成'));
						refreshSvc();
					});
				}
			});
		}

		btnStart = svcBtn(_('启动'), common.api.startService, true);
		btnStop = svcBtn(_('停止'), common.api.stopService, false);
		svcRow.appendChild(btnStart);
		svcRow.appendChild(btnStop);
		svcRow.appendChild(svcBtn(_('重启'), common.api.restartService, false));
		svcCard.appendChild(svcRow);

		var clearRow = common.el('div', 'nm-svc-clear-row');
		var clearDesc = common.el('div', 'nm-card-description');
		clearDesc.textContent = _('清空所有已采集样本与持久化历史');
		clearRow.appendChild(clearDesc);

		var spacerClear = common.el('div', 'nm-spacer');
		spacerClear.style.flex = '1';
		clearRow.appendChild(spacerClear);

		var btnClear = common.ui.button({
			label: _('清空历史'),
			theme: 'danger',
			variant: 'outline',
			onClick: function() {
				/* 不可撤销的破坏性操作：用项目自建确认弹窗（与全站视觉一致），
				 * 且不阻塞主线程 —— 原生 confirm 在低端路由器上会整页卡死。
				 * 删除动作放在 onOk 里：用户点「取消」时不应执行。 */
				common.ui.confirm({
					host: root,
					header: _('清空历史'),
					message: _('确定清空所有历史数据？'),
					ok: _('清空历史'),
					danger: true,
					onOk: function() {
						common.ui.setDisabled(btnClear, true);
						return common.api.clearHistory(null).then(function() {
							common.notify(_('历史已清空'));
						}).then(function() {
							common.ui.setDisabled(btnClear, false);
						});
					}
				});
			}
		});
		clearRow.appendChild(btnClear);
		svcCard.appendChild(clearRow);
		page.appendChild(svcCard);

		/* 首次加载标记：与 realtime.js 同理，refreshSvc 在 render() 末尾被
		 * 同步调用一次，此时 root 尚未挂到文档、isConnected 为 false。
		 * 若不加区分，首次调用就会自注销并短路，服务状态条永远停在初始
		 * 文案（「启动/停止」按钮的可用态也不跟随实时运行态）。 */
		var svcFirstRun = true;

		function refreshSvc() {
			/* LuCI 是 SPA：切页只替换 view 容器，不会清空 poll 队列。
			 * 本闭包除了注册点外无人持有引用，页面离开后既没人调用
			 * poll.remove 也拿不到引用，轮询会一直打 rpcd —— 访问 N 次
			 * 就有 N 个并发。承载的 DOM 已离开文档即说明页面已被卸载，
			 * 此时自注销。 */
			if (!svcFirstRun && !root.isConnected) {
				poll.remove(refreshSvc);
				return Promise.resolve();
			}
			svcFirstRun = false;
			return common.api.serviceStatus().then(function(d) {
				common.clear(svcIcon);
				svcIcon.appendChild(common.svgBox(icons.service(!!d.running, 30), ''));
				svcText.textContent = (d.running ? _('服务运行中') : _('服务已停止')) +
					' · ' + _('最后更新') + ': ' + (d.tick ? common.fmt.ago(d.tick) : _('从未检测'));
				/* 按钮可用态跟随实时运行态：已在跑就别让用户再点「启动」 */
				common.ui.setDisabled(btnStart, !!d.running);
				common.ui.setDisabled(btnStop, !d.running);
			}).catch(function() {
				common.clear(svcIcon);
				svcIcon.appendChild(common.svgBox(icons.service(false, 30), ''));
				svcText.textContent = _('服务已停止');
				common.ui.setDisabled(btnStart, false);
				common.ui.setDisabled(btnStop, true);
			});
		}

		/* ---------------------------------------------------- 生效值速览条 */
		var strip = common.el('div', 'nm-strip-grid');
		page.appendChild(strip);

		function makeStripCard(title, val, subText, svgIcon, valCls) {
			var card = common.tcard();
			var inner = common.el('div', 'nm-card-inner');

			var head = common.el('div', 'nm-card-header');
			head.appendChild(common.el('span', 'nm-card-label', title));

			if (svgIcon) {
				var icoBox = common.el('div', 'nm-card-icon-box');
				/* 图标来自 icons.js（内置常量字符串，不含用户输入），可安全走 innerHTML */
				if (typeof svgIcon === 'string') icoBox.innerHTML = svgIcon;
				else icoBox.appendChild(svgIcon);
				head.appendChild(icoBox);
			}

			inner.appendChild(head);
			inner.appendChild(common.el('div', 'nm-card-number ' + (valCls || ''), val));
			if (subText) inner.appendChild(common.el('div', 'nm-card-description', subText));

			card.appendChild(inner);
			return card;
		}

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

			strip.appendChild(makeStripCard(
				_('默认探测方式'),
				(proto === 'tcp') ? _('TCP 连接') : _('ICMP（ping）'),
				(proto === 'tcp') ? _('到端口的手握耗时') + ': ' + port : _('回显请求 / 应答'),
				icons.ping(44, { grade: 'good' }),
				'nm-c-ok'
			));

			strip.appendChild(makeStripCard(
				_('检测间隔'),
				interval + ' s',
				_('每次探测包数') + ': ' + count,
				icons.ping(44, { grade: 'good' }),
				'nm-c-ok'
			));

			strip.appendChild(makeStripCard(
				_('探测超时'),
				timeout + ' s',
				_('并发探测数') + ': ' + conc,
				icons.gear(44)
			));

			strip.appendChild(makeStripCard(
				_('持久化历史'),
				(persist === '1') ? _('已启用') : _('已停用'),
				_('保留期') + ': ' + hist,
				icons.database(44),
				(persist === '1') ? 'nm-c-warn' : 'nm-c-ok'
			));

			strip.appendChild(makeStripCard(
				_('地址族'),
				fam,
				_('总开关') + ': ' + ((enabled === '1') ? _('已启用') : _('已停用')),
				icons.dualStack(fam, fam !== 'ipv6', v6, 44)
			));

			strip.appendChild(makeStripCard(
				_('启用通知'),
				(notify === '1') ? _('已启用') : _('已停用'),
				_('预留') + ' · ' + _('阈值'),
				icons.bell(0, 44)
			));

			strip.appendChild(makeStripCard(
				_('界面刷新间隔'),
				String(v.ui_refresh == null ? '2' : v.ui_refresh) + ' s',
				_('与探测间隔相互独立'),
				icons.clock(null, 44)
			));
		}

		/* ---------------------------------------------------- 表单控件工厂（原生控件）
		 *
		 * 表单控件一开始就是原生 HTML 元素，早期尝试过用 TDesign 的
		 * t-switch / t-select / t-input-number / t-input，但它们基于 Omi 框架，
		 * 受控模式下点击与下拉交互实测失效（真实浏览器点击也打不开下拉、
		 * 开关不切换状态）。这里保持原生控件并沿用自有样式
		 * （见 style.css 的 .nm-switch / .nm-select / .nm-input），
		 * 交互由浏览器原生保证，兼容 LuCI 全部目标浏览器。 */
		function switchControl(key, value) {
			var sw = document.createElement('input');
			sw.type = 'checkbox';
			sw.className = 'nm-switch';
			sw.checked = (value === '1' || value === 1 || value === true);
			sw.addEventListener('change', markDirty);
			return { kind: 'flag', el: sw };
		}

		function intControl(key, value, min, max) {
			var n = document.createElement('input');
			n.type = 'number';
			n.className = 'nm-num-input';
			n.min = min;
			n.max = max;
			n.value = (value == null || value === '') ? '' : Number(value);
			n.addEventListener('input', markDirty);
			n.addEventListener('change', markDirty);
			return { kind: 'int', el: n, min: min, max: max };
		}

		function enumControl(key, value, values) {
			var sel = document.createElement('select');
			sel.className = 'nm-select';
			var options = values.map(function(o) {
				return { label: o[1], value: o[0] };
			});
			/* 当前值不在选项列表时（例如旧配置），补一个「当前值」兜底选项 */
			var cur = (value == null ? '' : String(value));
			var found = false;
			for (var i = 0; i < options.length; i++) {
				if (String(options[i].value) === cur) { found = true; break; }
			}
			if (!found && cur !== '')
				options.push({ label: cur + ' ' + _('（当前）'), value: cur });
			options.forEach(function(o) {
				var opt = document.createElement('option');
				opt.value = o.value;
				opt.textContent = o.label;
				sel.appendChild(opt);
			});
			sel.value = cur;
			sel.addEventListener('change', markDirty);
			return { kind: 'enum', el: sel };
		}

		function textControl(key, value) {
			var i = document.createElement('input');
			i.type = 'text';
			i.className = 'nm-input';
			i.value = (value == null ? '' : String(value));
			i.addEventListener('input', markDirty);
			i.addEventListener('change', markDirty);
			return { kind: 'text', el: i };
		}

		/* ---------------------------------------------------- 表单渲染 */
		var groups = fieldGroups();

		groups.forEach(function(g) {
			var card = common.tcard('nm-group-card');

			var head = common.el('div', 'nm-group-header');
			var ibox = common.el('span', 'nm-group-icon-wrap');
			ibox.innerHTML = g.icon();
			head.appendChild(ibox);

			var htxt = common.el('div', '');
			htxt.appendChild(common.el('div', 'nm-group-title', g.title));
			if (g.desc)
				htxt.appendChild(common.el('div', 'nm-group-desc', g.desc));
			head.appendChild(htxt);
			card.appendChild(head);
			card.appendChild(common.el('div', 'nm-group-divider'));

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

		function takeBaseline(v) {
			var o = {};
			for (var k in controls) {
				var raw = v[k];
				o[k] = (raw == null) ? '' : String(raw);
			}
			return o;
		}

		function validate(v) {
			for (var k in controls) {
				var c = controls[k];
				if (c.kind !== 'int') continue;
				var s = v[k];
				if (s === '' || !/^[0-9]+$/.test(s)) {
					var t = c.el.getAttribute('data-title') || k;
					return t + ': ' + _('请输入整数');
				}
				var n = parseInt(s, 10);
				if (n < c.min || n > c.max) {
					var t2 = c.el.getAttribute('data-title') || k;
					return t2 + ': ' + _('允许范围') + ' ' + c.min + '-' + c.max;
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
			setPill(isDirty ? 'dirty' : 'clean');
			common.ui.setDisabled(btnSave, !isDirty);
			common.ui.setDisabled(btnDiscard, !isDirty);
		}

		/* 状态胶囊：clean（无改动）/ dirty（有未保存的修改）/ staged（已暂存待应用） */
		function setPill(mode) {
			if (!dirtyTag) return;
			dirtyTag.className = 'nm-dirty-pill ' + mode;
			/* 这里必须用 innerHTML 拼 SVG + 文本：胶囊的圆点本身就是一段
			 * 内联图形，不是文字。用 textContent 会把标签整个显示成源码。
			 * 插入内容只有常量 SVG 与经 _() 的文案，不含用户输入。 */
			if (mode === 'dirty')
				dirtyTag.innerHTML = `<svg width="14" height="14" viewBox="0 0 16 16" fill="currentColor"><circle cx="8" cy="8" r="6" fill="#f59e0b"/></svg><span>${_('有未保存的修改')}</span>`;
			else if (mode === 'staged')
				dirtyTag.innerHTML = `<svg width="14" height="14" viewBox="0 0 16 16" fill="currentColor"><circle cx="8" cy="8" r="6" fill="#3b82f6"/></svg><span>${_('已暂存，待应用')}</span>`;
			else
				dirtyTag.innerHTML = `<svg width="14" height="14" viewBox="0 0 16 16" fill="currentColor"><path d="M13.485 1.929a1 1 0 0 1 1.414 1.414L6.343 11.899 1.1 6.657a1 1 0 0 1 1.414-1.414l3.829 3.829 7.142-7.143z" fill="#10b981"/></svg><span>${_('所有修改已生效')}</span>`;
		}

		/* 动作栏：保存 / 放弃 / 状态胶囊 */
		var actCard = common.tcard('nm-action-bar-glass');

		btnSave = common.ui.button({
			label: _('保存更改'),
			theme: 'primary',
			/* onClick 刻意不返回 Promise：ui.button 会在 Promise 结束后
			 * 无条件解禁按钮，而本页保存按钮的可用态由「表单 vs 基线」决定
			 * （保存成功后应保持禁用）。自动解禁会把它错误地亮起来，
			 * 所以这里自行管理禁用态与错误提示。 */
			onClick: function() {
				var v = collect();
				var bad = validate(v);
				if (bad) { common.notify(bad, 'error'); return; }

				var ops = [];
				for (var k in v)
					ops.push({ sid: 'global', opt: k, val: v[k] });

				/* 保存只做「暂存」：把改动经标准 UCI API（uci.set/unset + uci.save）写入
				 * 会话的待应用更改，提交（落盘 + reload）交给 OpenWrt 原生「保存并应用」栏。
				 * 刻意不再在这里调 ui.changes.apply() —— 那会让本页自带的按钮和原生栏
				 * 出现两套应用入口，互相冲突。 */
				common.ui.setDisabled(btnSave, true);
				common.saveConfig(ops).then(function(changed) {
					if (changed === 0) {
						markDirty();
						common.notify(_('没有需要保存的修改'));
						return;
					}
					baseline = takeBaseline(v);
					renderStrip(v);
					setPill('staged');
					common.notify(_('更改已暂存，请点击页面底部的「保存并应用」使其生效'));
					/* 已暂存 ≠ 无改动：仍允许「放弃修改」把暂存撤回 */
					common.ui.setDisabled(btnDiscard, false);
				}).catch(function(e) {
					common.notify(String(e.message || e), 'error');
					common.ui.setDisabled(btnSave, false);
				});
			}
		});

		btnDiscard = common.ui.button({
			label: _('放弃修改'),
			variant: 'outline',
			/* 同样不返回 Promise，理由同上：applyConfig() 会按 dirty 状态
			 * 把按钮禁用，交给 ui.button 自动解禁会覆盖这个结论。 */
			onClick: function() {
				applyConfig(cfg);
				/* 同步撤回本页暂存的会话改动，避免「表单已还原、底部原生栏仍显示待应用」 */
				common.revertConfig('netmonitor').catch(function() {
					/* 撤回失败不阻断表单复位 */
				}).then(function() {
					common.notify(_('修改已放弃'));
				});
			}
		});

		dirtyTag = common.el('div', 'nm-dirty-pill clean');

		actCard.appendChild(btnSave);
		actCard.appendChild(btnDiscard);
		var spacerAct = common.el('div', 'nm-spacer');
		spacerAct.style.flex = '1';
		actCard.appendChild(spacerAct);
		actCard.appendChild(dirtyTag);
		page.appendChild(actCard);

		function applyConfig(v) {
			cfg = v;
			for (var k in controls) {
				var c = controls[k];
				var raw = v[k];
				var s = (raw == null) ? '' : String(raw);
				if (c.kind === 'flag') {
					c.el.checked = (s === '1');
				} else if (c.kind === 'int') {
					c.el.value = (s === '') ? '' : Number(s);
				} else if (c.el.value !== s) {
					c.el.value = s;
				}
			}
			baseline = takeBaseline(v);
			renderStrip(v);
			markDirty();
		}

		groups.forEach(function(g) {
			g.fields.forEach(function(f) {
				if (f.kind === 'int')
					controls[f.key].el.setAttribute('data-title', f.title);
			});
		});

		applyConfig(cfg);

		refreshSvc();
		/* 轮询间隔读配置里的 ui_refresh：硬编码 10 秒会让用户在本页改的
		 * 「界面刷新间隔」对本页自己无效（其他页面都遵守该值）。 */
		poll.add(refreshSvc, Math.max(1, parseInt(cfg.ui_refresh, 10) || 2));

		return root;
	}
});
