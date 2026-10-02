/*
 * 总览页面：总体健康状态、关键指标、目标卡片
 * 白色毛玻璃质感 + 高级动态 SVG 动效重构版本
 * 采用局部刷新（LuCI poll），不整页重载，不触发额外 Ping。
 */

'use strict';
'require view';
'require poll';
'require netmonitor.common as common';
'require netmonitor.icons as icons';

return view.extend({
	load: function() {
		common.css();
		return Promise.all([
			common.loadI18n(),
			common.api.getConfig(),
			common.api.getStatus(true)
		]);
	},

	render: function(res) {
		common.css();

		var cfg = (res && res[1]) || {};
		var first = (res && res[2]) || null;
		var refresh = Math.max(1, parseInt(cfg.ui_refresh, 10) || 2);

		// 注入系统级白色毛玻璃、排版体系与动态 SVG 微动效
		(function injectStyles() {
			if (document.getElementById('nm-overview-glass-theme')) return;
			var style = document.createElement('style');
			style.id = 'nm-overview-glass-theme';
			style.textContent = `
				:root {
					--nm-bg-canvas: radial-gradient(120% 120% at 50% 0%, #f1f5f9 0%, #f8fafc 50%, #edf2f7 100%);
					--nm-glass-bg: linear-gradient(135deg, rgba(255, 255, 255, 0.85) 0%, rgba(255, 255, 255, 0.65) 100%);
					--nm-glass-card-bg: linear-gradient(145deg, rgba(255, 255, 255, 0.8) 0%, rgba(255, 255, 255, 0.62) 100%);
					--nm-glass-border: rgba(255, 255, 255, 0.95);
					--nm-glass-inner-border: rgba(255, 255, 255, 0.4);
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
					max-width: 1320px;
					margin: 0 auto;
					display: flex;
					flex-direction: column;
					gap: 22px;
				}

				/* 毛玻璃卡片基类 */
				.nm-glass-card {
					background: var(--nm-glass-card-bg);
					backdrop-filter: var(--nm-blur);
					-webkit-backdrop-filter: var(--nm-blur);
					border: 1px solid var(--nm-glass-border);
					border-radius: 22px;
					box-shadow: var(--nm-glass-shadow);
					transition: transform 0.28s cubic-bezier(0.34, 1.56, 0.64, 1), box-shadow 0.28s ease, border-color 0.28s ease;
					position: relative;
					overflow: hidden;
				}

				.nm-glass-card::before {
					content: '';
					position: absolute;
					top: 0; left: 0; right: 0; height: 1px;
					background: linear-gradient(90deg, transparent 0%, rgba(255, 255, 255, 0.9) 30%, rgba(255, 255, 255, 0.9) 70%, transparent 100%);
					pointer-events: none;
				}

				.nm-glass-card:hover {
					transform: translateY(-3px);
					box-shadow: var(--nm-glass-shadow-hover);
					border-color: #ffffff;
				}

				/* Hero 健康状态展台 */
				.nm-hero-showcase {
					padding: 30px 36px;
					display: flex;
					align-items: center;
					gap: 36px;
					background: linear-gradient(135deg, rgba(255, 255, 255, 0.92) 0%, rgba(255, 255, 255, 0.72) 100%);
				}

				@media (max-width: 768px) {
					.nm-hero-showcase {
						flex-direction: column;
						align-items: flex-start;
						padding: 24px 20px;
						gap: 20px;
					}
				}

				.nm-hero-orb-wrap {
					flex-shrink: 0;
					width: 104px;
					height: 104px;
					position: relative;
					display: flex;
					align-items: center;
					justify-content: center;
				}

				.nm-hero-main {
					flex: 1;
					display: flex;
					flex-direction: column;
					gap: 14px;
				}

				.nm-hero-title {
					margin: 0;
					font-size: 1.65rem;
					font-weight: 800;
					letter-spacing: -0.03em;
					color: var(--nm-txt-title);
					line-height: 1.25;
				}

				.nm-hero-desc {
					font-size: 0.96rem;
					line-height: 1.55;
					color: var(--nm-txt-sub);
					max-width: 780px;
				}

				.nm-hero-stats-row {
					display: flex;
					flex-wrap: wrap;
					gap: 14px;
					margin-top: 6px;
				}

				.nm-stat-badge {
					background: rgba(255, 255, 255, 0.68);
					backdrop-filter: blur(10px);
					-webkit-backdrop-filter: blur(10px);
					border: 1px solid rgba(255, 255, 255, 0.95);
					border-radius: 14px;
					padding: 10px 18px;
					display: flex;
					flex-direction: column;
					min-width: 105px;
					box-shadow: 0 4px 12px -2px rgba(15, 23, 42, 0.03);
					transition: all 0.2s ease;
				}

				.nm-stat-badge:hover {
					background: #ffffff;
					transform: translateY(-1px);
				}

				.nm-stat-badge b {
					font-size: 1.28rem;
					font-weight: 800;
					color: var(--nm-txt-title);
					letter-spacing: -0.02em;
					font-variant-numeric: tabular-nums;
				}

				.nm-stat-badge span {
					font-size: 0.74rem;
					color: var(--nm-txt-light);
					text-transform: uppercase;
					letter-spacing: 0.06em;
					font-weight: 650;
					margin-top: 3px;
				}

				/* 网格系统优化 */
				.nm-grid {
					display: grid;
					grid-template-columns: repeat(auto-fit, minmax(270px, 1fr));
					gap: 18px;
				}

				.nm-grid-wide {
					display: grid;
					grid-template-columns: repeat(auto-fit, minmax(330px, 1fr));
					gap: 20px;
				}

				/* KPI 与小卡片内部排版 */
				.nm-card-inner {
					padding: 22px 24px;
					display: flex;
					flex-direction: column;
					height: 100%;
					position: relative;
				}

				.nm-card-header {
					display: flex;
					justify-content: space-between;
					align-items: center;
					margin-bottom: 12px;
				}

				.nm-card-label {
					font-size: 0.88rem;
					font-weight: 700;
					color: var(--nm-txt-sub);
					letter-spacing: 0.01em;
				}

				.nm-card-icon-box {
					width: 44px;
					height: 44px;
					display: flex;
					align-items: center;
					justify-content: center;
					border-radius: 12px;
					background: rgba(255, 255, 255, 0.5);
					box-shadow: inset 0 1px 3px rgba(255, 255, 255, 0.8);
				}

				.nm-card-number {
					font-size: 1.75rem;
					font-weight: 850;
					color: var(--nm-txt-title);
					letter-spacing: -0.035em;
					line-height: 1.15;
					font-variant-numeric: tabular-nums;
				}

				.nm-card-description {
					margin-top: 10px;
					font-size: 0.82rem;
					color: var(--nm-txt-sub);
					line-height: 1.5;
				}

				/* 底部控制台 */
				.nm-footer-panel {
					padding: 18px 28px;
					display: flex;
					align-items: center;
					flex-wrap: wrap;
					gap: 20px;
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

				.nm-btn-glass:active:not(:disabled) {
					transform: translateY(0);
				}

				.nm-btn-glass:disabled {
					opacity: 0.55;
					cursor: not-allowed;
				}

				.nm-btn-primary-glass {
					background: linear-gradient(135deg, #3b82f6 0%, #1d4ed8 100%);
					color: #ffffff !important;
					border-color: rgba(255, 255, 255, 0.25);
					box-shadow: 0 4px 14px rgba(37, 99, 235, 0.25);
				}

				.nm-btn-primary-glass:hover:not(:disabled) {
					background: linear-gradient(135deg, #60a5fa 0%, #2563eb 100%);
					box-shadow: 0 6px 20px rgba(37, 99, 235, 0.35);
				}

				/* 动态 SVG 微动效关键帧 */
				@keyframes nm-pulse-glow {
					0% { transform: scale(0.88); opacity: 0.75; }
					50% { transform: scale(1.18); opacity: 0.15; }
					100% { transform: scale(0.88); opacity: 0.75; }
				}

				@keyframes nm-ring-spin {
					from { transform: rotate(0deg); }
					to { transform: rotate(360deg); }
				}

				@keyframes nm-bar-osc {
					0%, 100% { transform: scaleY(0.45); }
					50% { transform: scaleY(1.15); }
				}

				@keyframes nm-dial-glow {
					0%, 100% { filter: drop-shadow(0 0 2px rgba(59, 130, 246, 0.4)); }
					50% { filter: drop-shadow(0 0 8px rgba(59, 130, 246, 0.8)); }
				}

				.nm-svg-radar-1 { transform-origin: center; animation: nm-pulse-glow 2.8s cubic-bezier(0.4, 0, 0.6, 1) infinite; }
				.nm-svg-radar-2 { transform-origin: center; animation: nm-pulse-glow 2.8s cubic-bezier(0.4, 0, 0.6, 1) 0.9s infinite; }
				.nm-svg-rotate-dash { transform-origin: center; animation: nm-ring-spin 24s linear infinite; }
				.nm-svg-dial-glow { animation: nm-dial-glow 3s ease-in-out infinite; }

				.nm-bar-dyn-1 { transform-origin: 50% 100%; animation: nm-bar-osc 1.5s ease-in-out infinite; }
				.nm-bar-dyn-2 { transform-origin: 50% 100%; animation: nm-bar-osc 1.5s ease-in-out 0.25s infinite; }
				.nm-bar-dyn-3 { transform-origin: 50% 100%; animation: nm-bar-osc 1.5s ease-in-out 0.5s infinite; }
				.nm-bar-dyn-4 { transform-origin: 50% 100%; animation: nm-bar-osc 1.5s ease-in-out 0.75s infinite; }
				.nm-bar-dyn-5 { transform-origin: 50% 100%; animation: nm-bar-osc 1.5s ease-in-out 1s infinite; }
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

					.nm-svg-rotate-dash-rev { transform-origin: center; animation: nm-ring-spin 14s linear infinite reverse; }

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

		var hero = common.el('div', 'nm-glass-card nm-hero-showcase');
		var bannerBox = common.el('div', '');
		var kpi = common.el('div', 'nm-grid');
		var live = common.el('div', 'nm-grid');
		var cards = common.el('div', 'nm-grid-wide');
		var foot = common.el('div', 'nm-glass-card nm-footer-panel');

		page.appendChild(hero);
		page.appendChild(bannerBox);
		page.appendChild(kpi);
		page.appendChild(live);
		page.appendChild(cards);
		page.appendChild(foot);

		/* 阈值等级判定工具函数 */
		function gradeOf(ms, th) {
			if (ms == null || isNaN(ms)) return 'unknown';
			th = th || {};
			var ex = parseFloat(th.latency_excellent) || 50;
			var gd = parseFloat(th.latency_good) || 100;
			var fr = parseFloat(th.latency_fair) || 200;
			var pr = parseFloat(th.latency_poor) || 500;
			if (ms <= ex) return 'excellent';
			if (ms <= gd) return 'good';
			if (ms <= fr) return 'fair';
			if (ms <= pr) return 'poor';
			return 'severe';
		}

		/* 动态 SVG 徽章生成器：多层雷达扩散 + 旋转光环 + 状态核心 */
		function buildHeroSvg(state) {
			var color = (state === 'good') ? '#10b981' :
				(state === 'warning' ? '#f59e0b' :
				(state === 'critical' ? '#ef4444' : '#94a3b8'));

			var iconPath = (state === 'good')
				? '<path d="M48 61.4l-8-8 2.8-2.8L48 55.8l13.2-13.2L64 45.4z" fill="white"/>'
				: ((state === 'warning')
					? '<path d="M52 41h-4v14h4V41zm0 18h-4v4h4v-4z" fill="white"/>'
					: '<path d="M58 48l-4-4-6 6-6-6-4 4 6 6-6 6 4 4 6-6 6 6 4-4-6-6 6-6z" fill="white"/>');

			var svgStr = `
			<svg width="104" height="104" viewBox="0 0 104 104" fill="none" xmlns="http://www.w3.org/2000/svg">
				<defs>
					<radialGradient id="nm-orb-glow" cx="50%" cy="50%" r="50%">
						<stop offset="0%" stop-color="${color}" stop-opacity="0.3" />
						<stop offset="100%" stop-color="${color}" stop-opacity="0" />
					</radialGradient>
					<linearGradient id="nm-orb-ring" x1="0%" y1="0%" x2="100%" y2="100%">
						<stop offset="0%" stop-color="${color}" stop-opacity="0.95" />
						<stop offset="55%" stop-color="${color}" stop-opacity="0.35" />
						<stop offset="100%" stop-color="${color}" stop-opacity="0.05" />
					</linearGradient>
					<linearGradient id="nm-orb-core" x1="0%" y1="0%" x2="100%" y2="100%">
						<stop offset="0%" stop-color="#34d399" />
						<stop offset="100%" stop-color="#059669" />
					</linearGradient>
				</defs>
				<circle cx="52" cy="52" r="48" fill="url(#nm-orb-glow)" />
				<circle class="nm-svg-radar-1" cx="52" cy="52" r="46" stroke="${color}" stroke-opacity="0.3" stroke-width="1.6" />
				<circle class="nm-svg-radar-2" cx="52" cy="52" r="39" stroke="${color}" stroke-opacity="0.55" stroke-width="1.8" />
				<circle class="nm-svg-rotate-dash" cx="52" cy="52" r="30" stroke="url(#nm-orb-ring)" stroke-width="2.4" stroke-dasharray="10 9" stroke-linecap="round" />
				<circle class="nm-svg-rotate-dash-rev" cx="52" cy="52" r="23" stroke="${color}" stroke-opacity="0.4" stroke-width="1.4" stroke-dasharray="3 11" stroke-linecap="round" />
				<circle cx="52" cy="52" r="19" fill="url(#nm-orb-core)" style="filter: drop-shadow(0 3px 8px ${color}55);" />
				${iconPath}
			</svg>`;

			var div = document.createElement('div');
			div.className = 'nm-hero-orb-wrap';
			div.innerHTML = svgStr;
			return div;
		}

		/* 动态 SVG 实时采样声波柱 */
		function buildLiveBarsSvg(bars) {
			var b1 = Math.min(22, Math.max(5, (bars[0] || 15) / 5));
			var b2 = Math.min(22, Math.max(5, (bars[1] || 35) / 5));
			var b3 = Math.min(22, Math.max(5, (bars[2] || 25) / 5));
			var b4 = Math.min(22, Math.max(5, (bars[3] || 45) / 5));
			var b5 = Math.min(22, Math.max(5, (bars[4] || 18) / 5));

			return `
			<svg width="44" height="28" viewBox="0 0 44 28" fill="none" xmlns="http://www.w3.org/2000/svg">
				<defs>
					<linearGradient id="nm-bar-grad" x1="0%" y1="100%" x2="0%" y2="0%">
						<stop offset="0%" stop-color="#2563eb" stop-opacity="0.5" />
						<stop offset="100%" stop-color="#60a5fa" />
					</linearGradient>
				</defs>
				<rect class="nm-bar-dyn-1" x="2" y="${28 - b1}" width="4.5" height="${b1}" rx="2.2" fill="url(#nm-bar-grad)" />
				<rect class="nm-bar-dyn-2" x="11" y="${28 - b2}" width="4.5" height="${b2}" rx="2.2" fill="url(#nm-bar-grad)" />
				<rect class="nm-bar-dyn-3" x="20" y="${28 - b3}" width="4.5" height="${b3}" rx="2.2" fill="url(#nm-bar-grad)" />
				<rect class="nm-bar-dyn-4" x="29" y="${28 - b4}" width="4.5" height="${b4}" rx="2.2" fill="url(#nm-bar-grad)" />
				<rect class="nm-bar-dyn-5" x="38" y="${28 - b5}" width="4.5" height="${b5}" rx="2.2" fill="url(#nm-bar-grad)" />
			</svg>`;
		}

		function renderHero(d) {
			common.clear(hero);

			var state = 'unknown';
			if (d.health === 'good') state = 'good';
			else if (d.health === 'warning') state = 'warning';
			else if (d.health === 'critical') state = 'critical';

			hero.appendChild(buildHeroSvg(state));

			var main = common.el('div', 'nm-hero-main');
			var title = _('No monitoring data');
			var desc = _('Add and enable monitoring targets to start collecting data.');

			if (state === 'good') {
				title = _('Network is healthy');
				desc = _('所有监控目标均正常响应，延迟低、吞吐稳定。');
			} else if (state === 'warning') {
				title = _('Network problems detected');
				desc = _('Some targets are unreachable or unstable. Check detailed target cards below.');
			} else if (state === 'critical') {
				title = _('Serious network failure');
				desc = _('One or more targets failed consecutively beyond the threshold limit.');
			}

			main.appendChild(common.el('h3', 'nm-hero-title', title));
			main.appendChild(common.el('div', 'nm-hero-desc', desc));

			var o = d.overall || {};
			var stats = common.el('div', 'nm-hero-stats-row');
			function stat(v, label) {
				var s = common.el('div', 'nm-stat-badge');
				s.appendChild(common.el('b', '', v));
				s.appendChild(common.el('span', '', label));
				return s;
			}
			stats.appendChild(stat(common.fmt.latency(o.current) + ' ms', _('Current latency')));
			stats.appendChild(stat(common.fmt.percent(o.loss), _('Packet loss')));
			stats.appendChild(stat(String(o.online || 0), _('Online')));
			stats.appendChild(stat(String(o.offline || 0), _('Abnormal')));
			stats.appendChild(stat(String(o.total || 0), _('Target count')));
			main.appendChild(stats);

			hero.appendChild(main);
		}

		function renderBanners(d) {
			common.clear(bannerBox);
			if (!d.running) {
				bannerBox.appendChild(common.banner(
					_('Background service is not running. Monitoring is stopped.'), 'warn'));
			} else if (d.stale) {
				bannerBox.appendChild(common.banner(
					_('Background service did not update data recently. Check the service status.'), 'warn'));
			}
			if (d.overall && d.overall.total === 0) {
				bannerBox.appendChild(common.banner(
					_('No enabled targets. Go to Targets to add one.'), 'info'));
			}
		}

		/* 白色毛玻璃卡片封装工厂 */
		function makeGlassCard(title, val, subText, svgIcon) {
			var card = common.el('div', 'nm-glass-card');
			var inner = common.el('div', 'nm-card-inner');

			var head = common.el('div', 'nm-card-header');
			head.appendChild(common.el('span', 'nm-card-label', title));

			if (svgIcon) {
				var iconWrap = common.el('div', 'nm-card-icon-box');
				if (typeof svgIcon === 'string') iconWrap.innerHTML = svgIcon;
				else iconWrap.appendChild(svgIcon);
				head.appendChild(iconWrap);
			}

			inner.appendChild(head);
			inner.appendChild(common.el('div', 'nm-card-number', val));
			if (subText) inner.appendChild(common.el('div', 'nm-card-description', subText));

			card.appendChild(inner);
			return card;
		}

		function renderKpi(d) {
			common.clear(kpi);
			var o = d.overall || {};
			var r = d.regions || {};
			var cn = r.cn || {};
			var ov = r.overseas || {};
			var list = d.targets || [];
			var th = d.thresholds || {};

			function regionCard(title, x, svg) {
				var subHtml = _('Weighted loss') + ' · ' + _('Samples') + ': ' + (x.loss_samples || 0) + '<br>' +
					_('Online') + ' ' + (x.online || 0) + ' / ' + (x.total || 0) + ' · ' +
					_('Avg') + ' ' + common.fmt.latency(x.avg) + ' ms · ' +
					_('P95') + ' ' + common.fmt.latency(x.p95) + ' ms';
				if (x.loss_lost > 0)
					subHtml += '<br>' + _('Lost packets') + ': ' + x.loss_lost;

				var c = makeGlassCard(title, common.fmt.percent(x.loss, 1), '', svg);
				var subDesc = common.el('div', 'nm-card-description');
				subDesc.innerHTML = subHtml;
				c.querySelector('.nm-card-inner').appendChild(subDesc);
				return c;
			}

			var curGrade = gradeOf(o.current, th);

			kpi.appendChild(makeGlassCard(_('Average latency'), common.fmt.latency(o.avg) + ' ms',
				_('Across enabled targets'), icons.trend(44)));
			kpi.appendChild(makeGlassCard(_('Current latency'), common.fmt.latency(o.current) + ' ms',
				_('Latest probe round'), icons.latencyDial(o.current, curGrade, 44)));

			var lossSub = _('Weighted by samples') + ': ' + (o.loss_samples || 0) + ' · ' +
				_('Unweighted') + ' ' + common.fmt.percent(o.loss_avg, 1);
			if (o.loss_lost > 0)
				lossSub += ' · ' + _('Lost packets') + ': ' + o.loss_lost;

			kpi.appendChild(makeGlassCard(_('Packet loss'), common.fmt.percent(o.loss, 1), lossSub, icons.packetLoss(o.loss, 44)));
			kpi.appendChild(regionCard(_('China network'), cn, icons.regionCN(44, cn, cn.avg)));
			kpi.appendChild(regionCard(_('Overseas network'), ov, icons.regionGlobal(44, ov, ov.avg)));
			kpi.appendChild(makeGlassCard(_('Online targets'), String(o.online || 0),
				_('Abnormal') + ': ' + (o.offline || 0), icons.multiTarget(list, 44)));
		}

		function renderLive(d) {
			common.clear(live);
			var o = d.overall || {};
			var list = d.targets || [];
			var cfgv = cfg || {};

			var acc = 0, samples = 0;
			for (var i = 0; i < list.length; i++) {
				if (!list[i].enabled) continue;
				var s = list[i].samples || 0;
				acc += (list[i].success_rate || 0) * s;
				samples += s;
			}
			var rate = (samples > 0) ? (acc / samples) : null;

			live.appendChild(makeGlassCard(_('Success rate'), common.fmt.percent(rate, 1),
				_('Samples') + ': ' + samples, icons.successRing(rate, 44)));

			live.appendChild(makeGlassCard(_('Abnormal'), String(o.offline || 0) + ' / ' + String(o.total || 0),
				_('Online') + ': ' + (o.online || 0), icons.bell(o.offline, 44)));

			live.appendChild(makeGlassCard(_('Last check'), common.fmt.ago(d.tick),
				common.fmt.clock(d.tick), icons.clock(d.tick, 44)));

			live.appendChild(makeGlassCard(_('Probe settings'),
				(cfgv.interval || 10) + 's / ' + (cfgv.timeout || 3) + 's',
				_('Interval') + ' / ' + _('Timeout'), icons.gear(44)));

			live.appendChild(makeGlassCard(_('Data source'),
				(cfgv.persistence === '1') ? _('Persistent history') : _('In-memory ring buffer'),
				_('Retention') + ': ' + (cfgv.history || '24h'), icons.database(44)));

			var fam = cfgv.address_family || 'auto';
			var v6 = false;
			for (var j = 0; j < list.length; j++) {
				var h = String(list[j].host || '');
				if (list[j].family === 'ipv6' || h.indexOf(':') >= 0) v6 = true;
			}
			var v4 = (fam !== 'ipv6');
			if (fam === 'ipv6') v6 = true;
			live.appendChild(makeGlassCard(_('Dual stack'),
				(v4 && v6) ? 'IPv4 + IPv6' : (v6 ? 'IPv6' : 'IPv4'),
				_('Address family') + ': ' + fam, icons.dualStack(fam, v4, v6, 44)));
		}

		function renderCards(d) {
			common.clear(cards);
			var list = d.targets || [];
			if (!list.length) {
				var e = common.el('div', 'nm-empty nm-glass-card', _('No targets configured'));
				e.style.padding = '36px';
				e.style.textAlign = 'center';
				cards.appendChild(e);
				return;
			}
			for (var i = 0; i < list.length; i++) {
				var tc = common.targetCard(list[i]);
				tc.classList.add('nm-glass-card');
				cards.appendChild(tc);
			}
		}

		function renderFoot(d) {
			common.clear(foot);
			var row = common.el('div', 'nm-row');
			row.style.display = 'flex';
			row.style.alignItems = 'center';
			row.style.gap = '14px';
			row.style.flex = '1';

			row.appendChild(common.inlineIcon(icons.service(d.running, 30)));
			row.appendChild(common.el('div', '',
				(d.running ? _('Service running') : _('Service stopped')) +
				' · ' + _('Last update') + ': ' + common.fmt.ago(d.tick)));

			// 动态 SVG 均衡柱图
			var bars = [];
			var tl = d.targets || [];
			for (var i = 0; i < tl.length && i < 5; i++)
				bars.push(tl[i].latency);

			var lb = common.el('div', 'nm-row');
			lb.style.display = 'flex';
			lb.style.alignItems = 'center';
			lb.style.gap = '10px';
			lb.style.marginLeft = '20px';

			var liveBarsHolder = common.el('div', '');
			liveBarsHolder.innerHTML = buildLiveBarsSvg(bars);
			lb.appendChild(liveBarsHolder);
			lb.appendChild(common.el('span', 'nm-card-description', _('Live sampling')));
			row.appendChild(lb);

			foot.appendChild(row);

			var actRow = common.el('div', 'nm-row');
			actRow.style.display = 'flex';
			actRow.style.gap = '10px';

			function btn(label, fn, isPrimary) {
				var b = common.el('button', 'nm-btn-glass ' + (isPrimary ? 'nm-btn-primary-glass' : ''), label);
				b.addEventListener('click', function() {
					b.disabled = true;
					fn().then(function() {
						common.notify(_('Operation completed'));
						update();
					}).catch(function(e) {
						common.notify(String(e.message || e), 'error');
					}).then(function() { b.disabled = false; });
				});
				return b;
			}

			actRow.appendChild(btn(_('Start'), common.api.startService, true));
			actRow.appendChild(btn(_('Stop'), common.api.stopService, false));
			actRow.appendChild(btn(_('Restart'), common.api.restartService, false));
			foot.appendChild(actRow);
		}

		function apply(d) {
			renderHero(d);
			renderBanners(d);
			renderKpi(d);
			renderLive(d);
			renderCards(d);
			renderFoot(d);
		}

		function update() {
			return common.api.getStatus(true).then(apply).catch(function(e) {
				common.clear(cards);
				var err = common.el('div', 'nm-empty nm-glass-card', String(e.message || e));
				err.style.padding = '24px';
				cards.appendChild(err);
			});
		}

		if (first) apply(first);
		poll.add(update, refresh);

		return root;
	}
});
