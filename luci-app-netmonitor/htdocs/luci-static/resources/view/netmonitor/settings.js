/*
 * 设置页面：全局参数、后台服务控制、历史数据维护
 * 白色毛玻璃质感 + 高级动态 SVG 动效重构版本
 * 采用纯 DOM 渲染，杜绝 CBI/JSONMap 静默吞选项问题；全面升级排版与微交互。
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

		// 注入系统级白色毛玻璃、排版体系与动态 SVG 微动效
		(function injectSettingsStyles() {
			if (document.getElementById('nm-settings-glass-theme')) return;
			var style = document.createElement('style');
			style.id = 'nm-settings-glass-theme';
			style.textContent = `
				:root {
					--nm-bg-canvas: radial-gradient(120% 120% at 50% 0%, #f1f5f9 0%, #f8fafc 50%, #edf2f7 100%);
					--nm-glass-bg: linear-gradient(135deg, rgba(255, 255, 255, 0.85) 0%, rgba(255, 255, 255, 0.65) 100%);
					--nm-glass-card-bg: linear-gradient(145deg, rgba(255, 255, 255, 0.82) 0%, rgba(255, 255, 255, 0.65) 100%);
					--nm-glass-border: rgba(255, 255, 255, 0.95);
					--nm-glass-shadow: 0 10px 30px -5px rgba(15, 23, 42, 0.05), 0 2px 8px -2px rgba(15, 23, 42, 0.03);
					--nm-glass-shadow-hover: 0 20px 38px -8px rgba(15, 23, 42, 0.09), 0 6px 14px -3px rgba(15, 23, 42, 0.05);
					--nm-blur: blur(20px) saturate(190%);
					
					--nm-c-ok: #10b981;
					--nm-c-warn: #f59e0b;
					--nm-c-bad: #ef4444;
					--nm-c-primary: #3b82f6;
					
					--nm-txt-title: #0f172a;
					--nm-txt-body: #334155;
					--nm-txt-sub: #64748b;
					--nm-txt-light: #94a3b8;
				}

				.nm-root {
					background: var(--nm-bg-canvas);
					min-height: 100%;
					padding: 24px 20px 48px;
					font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "PingFang SC", "Hiragino Sans GB", "Microsoft YaHei", sans-serif;
					color: var(--nm-txt-body);
					-webkit-font-smoothing: antialiased;
				}

				.nm-page {
					max-width: 1360px;
					margin: 0 auto;
					display: flex;
					flex-direction: column;
					gap: 22px;
				}

				/* 毛玻璃卡片通用基类 */
				.nm-glass-card {
					background: var(--nm-glass-card-bg);
					backdrop-filter: var(--nm-blur);
					-webkit-backdrop-filter: var(--nm-blur);
					border: 1px solid var(--nm-glass-border);
					border-radius: 22px;
					box-shadow: var(--nm-glass-shadow);
					transition: transform 0.25s ease, box-shadow 0.25s ease;
					position: relative;
					overflow: hidden;
				}

				/* 服务控制与状态大卡片 */
				.nm-svc-panel {
					padding: 24px 30px;
					display: flex;
					flex-direction: column;
					gap: 16px;
				}

				.nm-svc-row-top {
					display: flex;
					align-items: center;
					flex-wrap: wrap;
					gap: 16px;
				}

				.nm-svc-info {
					display: flex;
					align-items: center;
					gap: 12px;
				}

				.nm-svc-text {
					font-size: 0.92rem;
					font-weight: 650;
					color: var(--nm-txt-title);
				}

				.nm-btn-glass {
					background: rgba(255, 255, 255, 0.88);
					border: 1px solid rgba(255, 255, 255, 0.95);
					border-radius: 12px;
					padding: 8px 18px;
					font-size: 0.86rem;
					font-weight: 650;
					color: var(--nm-txt-body);
					box-shadow: 0 2px 6px rgba(15, 23, 42, 0.04);
					cursor: pointer;
					display: inline-flex;
					align-items: center;
					gap: 7px;
					transition: all 0.2s cubic-bezier(0.4, 0, 0.2, 1);
				}

				.nm-btn-glass:hover:not(:disabled) {
					background: #ffffff;
					transform: translateY(-1.5px);
					box-shadow: 0 6px 16px rgba(15, 23, 42, 0.08);
					color: var(--nm-txt-title);
				}

				.nm-btn-primary-glass {
					background: linear-gradient(135deg, #3b82f6 0%, #1d4ed8 100%) !important;
					color: #ffffff !important;
					border: 1px solid rgba(255, 255, 255, 0.25) !important;
					box-shadow: 0 4px 14px rgba(37, 99, 235, 0.28) !important;
				}

				.nm-btn-primary-glass:hover:not(:disabled) {
					background: linear-gradient(135deg, #60a5fa 0%, #2563eb 100%) !important;
					box-shadow: 0 6px 20px rgba(37, 99, 235, 0.38) !important;
				}

				.nm-btn-danger-glass {
					background: rgba(254, 242, 242, 0.9);
					border: 1px solid rgba(254, 202, 202, 0.9);
					color: #dc2626;
				}

				.nm-btn-danger-glass:hover:not(:disabled) {
					background: #fee2e2;
					border-color: #ef4444;
					color: #b91c1c;
				}

				/* 生效值速览指标网格 */
				.nm-strip-grid {
					display: grid;
					grid-template-columns: repeat(auto-fit, minmax(250px, 1fr));
					gap: 16px;
				}

				.nm-card-inner {
					padding: 20px 22px;
					display: flex;
					flex-direction: column;
					position: relative;
				}

				.nm-card-header {
					display: flex;
					justify-content: space-between;
					align-items: center;
					margin-bottom: 8px;
				}

				.nm-card-label {
					font-size: 0.84rem;
					font-weight: 700;
					color: var(--nm-txt-sub);
					letter-spacing: 0.01em;
				}

				.nm-card-number {
					font-size: 1.6rem;
					font-weight: 850;
					color: var(--nm-txt-title);
					letter-spacing: -0.03em;
					line-height: 1.15;
					font-variant-numeric: tabular-nums;
				}

				.nm-card-description {
					margin-top: 8px;
					font-size: 0.8rem;
					color: var(--nm-txt-sub);
				}

				/* 分组设置表单卡片 */
				.nm-group-card {
					padding: 26px 30px;
					display: flex;
					flex-direction: column;
					gap: 20px;
				}

				.nm-group-header {
					display: flex;
					align-items: center;
					gap: 14px;
				}

				.nm-group-icon-wrap {
					width: 44px;
					height: 44px;
					display: flex;
					align-items: center;
					justify-content: center;
					background: rgba(255, 255, 255, 0.65);
					border-radius: 12px;
					border: 1px solid rgba(255, 255, 255, 0.9);
					box-shadow: 0 2px 6px rgba(15, 23, 42, 0.03);
				}

				.nm-group-title {
					font-size: 1.25rem;
					font-weight: 800;
					color: var(--nm-txt-title);
					letter-spacing: -0.025em;
				}

				.nm-group-desc {
					font-size: 0.86rem;
					color: var(--nm-txt-sub);
					margin-top: 2px;
				}

				.nm-group-divider {
					height: 1px;
					background: linear-gradient(90deg, rgba(226, 232, 240, 0.9) 0%, rgba(226, 232, 240, 0.2) 100%);
				}

				/* 单项设置行排版 */
				.nm-setting-row {
					display: flex;
					align-items: center;
					justify-content: space-between;
					gap: 24px;
					padding: 10px 0;
					border-bottom: 1px solid rgba(241, 245, 249, 0.7);
				}

				.nm-setting-row:last-child {
					border-bottom: none;
				}

				@media (max-width: 640px) {
					.nm-setting-row {
						flex-direction: column;
						align-items: flex-start;
						gap: 12px;
					}
				}

				.nm-setting-main {
					flex: 1;
					display: flex;
					flex-direction: column;
					gap: 4px;
				}

				.nm-setting-title {
					font-size: 0.92rem;
					font-weight: 700;
					color: var(--nm-txt-title);
				}

				.nm-setting-desc {
					font-size: 0.82rem;
					color: var(--nm-txt-sub);
					line-height: 1.45;
				}

				.nm-setting-ctl {
					flex-shrink: 0;
				}

				.nm-input, .nm-select {
					background: rgba(255, 255, 255, 0.85);
					border: 1px solid rgba(203, 213, 225, 0.85);
					border-radius: 12px;
					padding: 7px 14px;
					font-size: 0.86rem;
					color: var(--nm-txt-title);
					outline: none;
					transition: all 0.2s cubic-bezier(0.4, 0, 0.2, 1);
					box-shadow: 0 1px 3px rgba(0, 0, 0, 0.02);
				}

				.nm-input:focus, .nm-select:focus {
					background: #ffffff;
					border-color: var(--nm-c-primary);
					box-shadow: 0 0 0 3px rgba(59, 130, 246, 0.16);
				}

				.nm-num-input {
					width: 140px;
					font-variant-numeric: tabular-nums;
					font-weight: 650;
				}

				/* iOS 风格平滑切换开关 */
				.nm-switch {
					position: relative;
					display: inline-flex;
					align-items: center;
					gap: 10px;
					cursor: pointer;
				}

				.nm-switch input {
					opacity: 0;
					width: 0;
					height: 0;
					position: absolute;
				}

				.nm-switch i {
					position: relative;
					display: inline-block;
					width: 42px;
					height: 24px;
					background-color: #cbd5e1;
					transition: .24s ease;
					border-radius: 24px;
				}

				.nm-switch i:before {
					position: absolute;
					content: "";
					height: 20px;
					width: 20px;
					left: 2px;
					bottom: 2px;
					background-color: white;
					transition: .24s ease;
					border-radius: 50%;
					box-shadow: 0 2px 4px rgba(0, 0, 0, 0.2);
				}

				.nm-switch input:checked + i {
					background: linear-gradient(135deg, #10b981 0%, #059669 100%);
				}

				.nm-switch input:checked + i:before {
					transform: translateX(18px);
				}

				.nm-switch-text {
					font-size: 0.84rem;
					font-weight: 700;
					color: var(--nm-txt-body);
					user-select: none;
				}

				/* 底部保存与变更动作栏（页内卡片，不悬浮）。
				 * 不做 position: sticky：改动经标准 UCI API 暂存后，OpenWrt 原生
				 * 「保存并应用」栏会自动出现在视口底部，悬浮会与它叠成两栏互相冲突。 */
				.nm-action-bar-glass {
					padding: 16px 28px;
					display: flex;
					align-items: center;
					gap: 16px;
					background: rgba(255, 255, 255, 0.92) !important;
					backdrop-filter: blur(24px) saturate(200%) !important;
					-webkit-backdrop-filter: blur(24px) saturate(200%) !important;
					box-shadow: 0 20px 40px -10px rgba(15, 23, 42, 0.15), 0 4px 12px rgba(0, 0, 0, 0.05);
					border: 1px solid rgba(255, 255, 255, 1);
				}

				.nm-dirty-pill {
					display: inline-flex;
					align-items: center;
					gap: 8px;
					font-size: 0.84rem;
					font-weight: 700;
					padding: 6px 14px;
					border-radius: 20px;
					transition: all 0.25s ease;
				}

				.nm-dirty-pill.dirty {
					background: rgba(254, 243, 199, 0.9);
					border: 1px solid rgba(253, 230, 138, 0.95);
					color: #b45309;
				}

				.nm-dirty-pill.clean {
					background: rgba(236, 253, 245, 0.9);
					border: 1px solid rgba(167, 243, 208, 0.95);
					color: #047857;
				}

				/* 已暂存待应用：改动已入 UCI 会话，等原生栏提交 */
				.nm-dirty-pill.staged {
					background: rgba(239, 246, 255, 0.9);
					border: 1px solid rgba(191, 219, 254, 0.95);
					color: #1d4ed8;
				}

				/* 动态 SVG 微动效 */
				@keyframes nm-pulse-led {
					0%, 100% { transform: scale(0.9); opacity: 0.8; }
					50% { transform: scale(1.3); opacity: 0.3; }
				}
				.nm-led-ping { animation: nm-pulse-led 2.4s cubic-bezier(0.4, 0, 0.6, 1) infinite; }
			`;
			document.head.appendChild(style);

			/* 统一增强：卡片高光 / 弹性上浮 / 键盘可达 / 减弱动效偏好 */
			if (!document.getElementById('nm-glass-enhance')) {
				var enh = document.createElement('style');
				enh.id = 'nm-glass-enhance';
				enh.textContent = `
					.nm-page { max-width: 1360px; gap: 22px; }

					.nm-glass-card::before {
						content: '';
						position: absolute;
						top: 0; left: 0; right: 0; height: 1px;
						background: linear-gradient(90deg, transparent 0%, rgba(255, 255, 255, 0.95) 25%, rgba(255, 255, 255, 0.95) 75%, transparent 100%);
						pointer-events: none;
						z-index: 1;
					}

					.nm-glass-card:hover {
						transform: translateY(-3px);
						border-color: #ffffff;
					}

					.nm-action-bar-glass:hover { transform: none; }

					.nm-btn-glass:focus-visible,
					.nm-btn-mini:focus-visible,
					.nm-select-glass:focus-visible,
					.nm-input-glass:focus-visible,
					.nm-input:focus-visible,
					.nm-select:focus-visible {
						outline: 2px solid rgba(59, 130, 246, 0.5);
						outline-offset: 2px;
					}

					input[type="checkbox"] { accent-color: var(--nm-c-primary); }

					.nm-switch:focus-within i { box-shadow: 0 0 0 3px rgba(59, 130, 246, 0.3); }

					@media (max-width: 640px) {
						.nm-root { padding: 16px 12px 40px; }
						.nm-page { gap: 16px; }
					}

					@media (prefers-reduced-motion: reduce) {
						.nm-glass-card,
						.nm-btn-glass,
						.nm-stat-badge,
						.nm-sum-card,
						.nm-chip-btn,
						.nm-led-ping-ring,
						.nm-svg-radar-1,
						.nm-svg-radar-2,
						.nm-svg-rotate-dash,
						.nm-svg-rotate-dash-rev,
						.nm-svg-dial-glow,
						.nm-bar-dyn-1, .nm-bar-dyn-2, .nm-bar-dyn-3, .nm-bar-dyn-4, .nm-bar-dyn-5,
						.nm-wave-b1, .nm-wave-b2, .nm-wave-b3, .nm-wave-b4, .nm-wave-b5,
						.nm-svg-soft-pulse,
						.nm-led-ping {
							animation: none !important;
							transition: none !important;
						}
					}
				`;
				document.head.appendChild(enh);
			}
		})();

		var root = common.el('div', 'nm-root');
		var page = common.el('div', 'nm-page');
		root.appendChild(page);

		var controls = {};
		var baseline = {};
		var btnSave = null, btnDiscard = null, dirtyTag = null;

		if (!Object.prototype.hasOwnProperty.call(cfg, 'default_proto'))
			cfg.default_proto = 'icmp';
		if (!Object.prototype.hasOwnProperty.call(cfg, 'default_tcp_port'))
			cfg.default_tcp_port = '80';

		/* ---------------------------------------------------- 服务控制面板 */
		var svcCard = common.el('div', 'nm-glass-card nm-svc-panel');
		var svcRow = common.el('div', 'nm-svc-row-top');

		var svcIcon = common.el('div', 'nm-svc-info');
		svcRow.appendChild(svcIcon);
		var svcText = common.el('div', 'nm-svc-text', '');
		svcRow.appendChild(svcText);

		var spacerSvc = common.el('div', 'nm-spacer');
		spacerSvc.style.flex = '1';
		svcRow.appendChild(spacerSvc);

		function svcBtn(label, fn, isPrimary) {
			var b = common.el('button', 'nm-btn-glass' + (isPrimary ? ' nm-btn-primary-glass' : ''), label);
			b.addEventListener('click', function() {
				b.disabled = true;
				Promise.resolve().then(fn).then(function() {
					common.notify(_('操作已完成'));
					refreshSvc();
				}).catch(function(e) {
					common.notify(String(e.message || e), 'error');
				}).then(function() { b.disabled = false; });
			});
			return b;
		}

		svcRow.appendChild(svcBtn(_('启动'), common.api.startService, true));
		svcRow.appendChild(svcBtn(_('停止'), common.api.stopService, false));
		svcRow.appendChild(svcBtn(_('重启'), common.api.restartService, false));
		svcCard.appendChild(svcRow);

		var clearRow = common.el('div', 'nm-row');
		clearRow.style.display = 'flex';
		clearRow.style.alignItems = 'center';
		clearRow.style.marginTop = '6px';
		clearRow.style.paddingTop = '12px';
		clearRow.style.borderTop = '1px solid rgba(241, 245, 249, 0.8)';

		var clearDesc = common.el('div', 'nm-card-description');
		clearDesc.textContent = _('清空所有已采集样本与持久化历史');
		clearRow.appendChild(clearDesc);

		var spacerClear = common.el('div', 'nm-spacer');
		spacerClear.style.flex = '1';
		clearRow.appendChild(spacerClear);

		var btnClear = common.el('button', 'nm-btn-glass nm-btn-danger-glass', _('清空历史'));
		btnClear.addEventListener('click', function() {
			if (!window.confirm(_('确定清空所有历史数据？'))) return;
			btnClear.disabled = true;
			common.api.clearHistory(null).then(function() {
				common.notify(_('历史已清空'));
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
				svcText.textContent = (d.running ? _('服务运行中') : _('服务已停止')) +
					' · ' + _('最后更新') + ': ' + (d.tick ? common.fmt.ago(d.tick) : _('从未检测'));
			}).catch(function() {
				common.clear(svcIcon);
				svcIcon.appendChild(common.svgBox(icons.service(false, 30), ''));
				svcText.textContent = _('服务已停止');
			});
		}

		/* ---------------------------------------------------- 生效值速览条 */
		var strip = common.el('div', 'nm-strip-grid');
		page.appendChild(strip);

		function makeGlassStripCard(title, val, subText, svgIcon, valCls) {
			var card = common.el('div', 'nm-glass-card');
			var inner = common.el('div', 'nm-card-inner');

			var head = common.el('div', 'nm-card-header');
			head.appendChild(common.el('span', 'nm-card-label', title));

			if (svgIcon) {
				var icoBox = common.el('div', '');
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

			strip.appendChild(makeGlassStripCard(
				_('默认探测方式'),
				(proto === 'tcp') ? _('TCP 连接') : _('ICMP（ping）'),
				(proto === 'tcp') ? _('到端口的手握耗时') + ': ' + port : _('回显请求 / 应答'),
				icons.ping(44, { grade: 'good' }),
				'nm-c-ok'
			));

			strip.appendChild(makeGlassStripCard(
				_('检测间隔'),
				interval + ' s',
				_('每次探测包数') + ': ' + count,
				icons.ping(44, { grade: 'good' }),
				'nm-c-ok'
			));

			strip.appendChild(makeGlassStripCard(
				_('探测超时'),
				timeout + ' s',
				_('并发探测数') + ': ' + conc,
				icons.gear(44)
			));

			strip.appendChild(makeGlassStripCard(
				_('持久化历史'),
				(persist === '1') ? _('已启用') : _('已停用'),
				_('保留期') + ': ' + hist,
				icons.database(44),
				(persist === '1') ? 'nm-c-warn' : 'nm-c-ok'
			));

			strip.appendChild(makeGlassStripCard(
				_('地址族'),
				fam,
				_('总开关') + ': ' + ((enabled === '1') ? _('已启用') : _('已停用')),
				icons.dualStack(fam, fam !== 'ipv6', v6, 44)
			));

			strip.appendChild(makeGlassStripCard(
				_('启用通知'),
				(notify === '1') ? _('已启用') : _('已停用'),
				_('预留') + ' · ' + _('阈值'),
				icons.bell(0, 44)
			));

			strip.appendChild(makeGlassStripCard(
				_('UI refresh interval'),
				String(v.ui_refresh == null ? '2' : v.ui_refresh) + ' s',
				_('Independent from the probe interval'),
				icons.clock(null, 44)
			));
		}

		/* ---------------------------------------------------- 表单控件工厂 */
		function switchControl(key, value) {
			var lab = common.el('label', 'nm-switch');
			var inp = common.el('input', '');
			inp.type = 'checkbox';
			inp.checked = (value === '1' || value === 1 || value === true);
			lab.appendChild(inp);
			lab.appendChild(common.el('i', ''));
			var txt = common.el('span', 'nm-switch-text', inp.checked ? _('已启用') : _('已停用'));
			lab.appendChild(txt);
			inp.addEventListener('change', function() {
				txt.textContent = inp.checked ? _('已启用') : _('已停用');
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
			if (sel.selectedIndex < 0) {
				var op2 = common.el('option', '', String(value) + ' ' + _('（当前）'));
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
			var card = common.el('div', 'nm-glass-card nm-group-card');

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
				var row = common.el('div', 'nm-setting-row');
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
			if (btnSave) btnSave.disabled = !isDirty;
			if (btnDiscard) btnDiscard.disabled = !isDirty;
		}

		/* 状态胶囊：clean（无改动）/ dirty（有未保存的修改）/ staged（已暂存待应用） */
		function setPill(mode) {
			if (!dirtyTag) return;
			dirtyTag.className = 'nm-dirty-pill ' + mode;
			if (mode === 'dirty')
				dirtyTag.innerHTML = `<svg width="14" height="14" viewBox="0 0 16 16" fill="currentColor"><circle cx="8" cy="8" r="6" fill="#f59e0b"/></svg><span>${_('有未保存的修改')}</span>`;
			else if (mode === 'staged')
				dirtyTag.innerHTML = `<svg width="14" height="14" viewBox="0 0 16 16" fill="currentColor"><circle cx="8" cy="8" r="6" fill="#3b82f6"/></svg><span>${_('已暂存，待应用')}</span>`;
			else
				dirtyTag.innerHTML = `<svg width="14" height="14" viewBox="0 0 16 16" fill="currentColor"><path d="M13.485 1.929a1 1 0 0 1 1.414 1.414L6.343 11.899 1.1 6.657a1 1 0 0 1 1.414-1.414l3.829 3.829 7.142-7.143z" fill="#10b981"/></svg><span>${_('所有修改已生效')}</span>`;
		}

		var actCard = common.el('div', 'nm-glass-card nm-action-bar-glass');
		btnSave = common.el('button', 'nm-btn-glass nm-btn-primary-glass', _('保存更改'));
		btnDiscard = common.el('button', 'nm-btn-glass', _('放弃修改'));
		dirtyTag = common.el('div', 'nm-dirty-pill clean');

		/* 保存只做「暂存」：把改动经标准 UCI API（uci.set/unset + uci.save）写入
		 * 会话的待应用更改，提交（落盘 + reload）交给 OpenWrt 原生「保存并应用」栏。
		 * 刻意不再在这里调 ui.changes.apply() —— 那会让本页自带的按钮和原生栏
		 * 出现两套应用入口，互相冲突。 */
		btnSave.addEventListener('click', function() {
			var v = collect();
			var bad = validate(v);
			if (bad) { common.notify(bad, 'error'); return; }
			btnSave.disabled = true;

			var ops = [];
			for (var k in v)
				ops.push({ sid: 'global', opt: k, val: v[k] });

			common.saveConfig(ops).then(function(changed) {
				if (changed === 0) {
					markDirty();
					common.notify(_('没有需要保存的修改'));
					return;
				}
				baseline = takeBaseline(v);
				btnSave.disabled = true;
				btnDiscard.disabled = false;
				renderStrip(v);
				setPill('staged');
				common.notify(_('更改已暂存，请点击页面底部的「保存并应用」使其生效'));
			}).catch(function(e) {
				btnSave.disabled = false;
				common.notify(String(e.message || e), 'error');
			});
		});

		btnDiscard.addEventListener('click', function() {
			applyConfig(cfg);
			/* 同步撤回本页暂存的会话改动，避免「表单已还原、底部原生栏仍显示待应用」 */
			return common.revertConfig('netmonitor').catch(function() {
				/* 撤回失败不阻断表单复位 */
			}).then(function() {
				common.notify(_('修改已放弃'));
			});
		});

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
					var txt = c.el.parentNode.querySelector('.nm-switch-text');
					if (txt) txt.textContent = c.el.checked ? _('已启用') : _('已停用');
				}
				else if (c.el.value !== s) {
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
		poll.add(refreshSvc, 10);

		return root;
	}
});
