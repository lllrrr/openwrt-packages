/*
 * 实时监控页面：以表格形式列出所有目标的实时状态
 * 白色毛玻璃质感 + 高级动态 SVG 动效重构版本
 * 手机端表格可横向平滑滚动，并支持自适应卡片流展示。
 */

'use strict';
'require view';
'require poll';
'require netmonitor.common as common';
'require netmonitor.icons as icons';

return view.extend({
	load: function() {
		common.css();
		return Promise.all([common.loadI18n(), common.api.getConfig()]);
	},

	render: function(res) {
		common.css();

		var cfg = (res && res[1]) || {};
		var refresh = Math.max(1, parseInt(cfg.ui_refresh, 10) || 2);

		var filterRegion = 'all';
		var filterStatus = 'all';
		var keyword = '';
		var paused = false;
		var latest = null;

		// 注入系统级白色毛玻璃、排版体系与动态 SVG 微动效
		(function injectRealtimeStyles() {
			if (document.getElementById('nm-realtime-glass-theme')) return;
			var style = document.createElement('style');
			style.id = 'nm-realtime-glass-theme';
			style.textContent = `
				:root {
					--nm-bg-canvas: radial-gradient(120% 120% at 50% 0%, #f1f5f9 0%, #f8fafc 50%, #edf2f7 100%);
					--nm-glass-bg: linear-gradient(135deg, rgba(255, 255, 255, 0.85) 0%, rgba(255, 255, 255, 0.65) 100%);
					--nm-glass-card-bg: linear-gradient(145deg, rgba(255, 255, 255, 0.8) 0%, rgba(255, 255, 255, 0.62) 100%);
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
					gap: 20px;
				}

				/* 毛玻璃卡片基类 */
				.nm-glass-card {
					background: var(--nm-glass-card-bg);
					backdrop-filter: var(--nm-blur);
					-webkit-backdrop-filter: var(--nm-blur);
					border: 1px solid var(--nm-glass-border);
					border-radius: 20px;
					box-shadow: var(--nm-glass-shadow);
					transition: transform 0.25s ease, box-shadow 0.25s ease;
					position: relative;
					overflow: hidden;
				}

				.nm-glass-card:hover {
					box-shadow: var(--nm-glass-shadow-hover);
				}

				/* 顶部工具栏 */
				.nm-toolbar-glass {
					padding: 16px 24px;
					display: flex;
					align-items: center;
					flex-wrap: wrap;
					gap: 16px;
				}

				.nm-field-glass {
					display: flex;
					align-items: center;
					gap: 10px;
				}

				.nm-field-glass label {
					font-size: 0.86rem;
					font-weight: 700;
					color: var(--nm-txt-sub);
					white-space: nowrap;
				}

				.nm-select-glass, .nm-input-glass {
					background: rgba(255, 255, 255, 0.72);
					backdrop-filter: blur(10px);
					-webkit-backdrop-filter: blur(10px);
					border: 1px solid rgba(203, 213, 225, 0.75);
					border-radius: 12px;
					padding: 7px 14px;
					font-size: 0.86rem;
					color: var(--nm-txt-title);
					outline: none;
					transition: all 0.2s cubic-bezier(0.4, 0, 0.2, 1);
					box-shadow: 0 1px 3px rgba(0, 0, 0, 0.02);
				}

				.nm-select-glass:focus, .nm-input-glass:focus {
					background: #ffffff;
					border-color: var(--nm-c-primary);
					box-shadow: 0 0 0 3px rgba(59, 130, 246, 0.16);
				}

				.nm-input-glass {
					min-width: 220px;
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

				.nm-btn-glass:hover {
					background: #ffffff;
					transform: translateY(-1.5px);
					box-shadow: 0 6px 16px rgba(15, 23, 42, 0.08);
					color: var(--nm-txt-title);
				}

				.nm-btn-active-glass {
					background: linear-gradient(135deg, #f59e0b 0%, #d97706 100%) !important;
					color: #ffffff !important;
					border-color: rgba(255, 255, 255, 0.3) !important;
					box-shadow: 0 4px 14px rgba(217, 119, 6, 0.25) !important;
				}

				/* 顶部实时指标条 */
				.nm-strip-grid {
					display: grid;
					grid-template-columns: repeat(auto-fit, minmax(260px, 1fr));
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
					font-size: 1.65rem;
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

				/* 表格毛玻璃外框与内部排版 */
				.nm-table-glass-wrap {
					background: var(--nm-glass-card-bg);
					backdrop-filter: var(--nm-blur);
					-webkit-backdrop-filter: var(--nm-blur);
					border: 1px solid var(--nm-glass-border);
					border-radius: 20px;
					box-shadow: var(--nm-glass-shadow);
					overflow-x: auto;
					-webkit-overflow-scrolling: touch;
				}

				.nm-table-glass-wrap::-webkit-scrollbar {
					height: 6px;
				}
				.nm-table-glass-wrap::-webkit-scrollbar-track {
					background: rgba(241, 245, 249, 0.5);
				}
				.nm-table-glass-wrap::-webkit-scrollbar-thumb {
					background: rgba(203, 213, 225, 0.8);
					border-radius: 4px;
				}

				.nm-table-glass {
					width: 100%;
					border-collapse: separate;
					border-spacing: 0;
					text-align: left;
					font-size: 0.88rem;
				}

				.nm-table-glass thead th {
					background: rgba(248, 250, 252, 0.9);
					backdrop-filter: blur(12px);
					-webkit-backdrop-filter: blur(12px);
					padding: 15px 18px;
					font-weight: 700;
					font-size: 0.8rem;
					color: var(--nm-txt-sub);
					text-transform: uppercase;
					letter-spacing: 0.05em;
					border-bottom: 1px solid rgba(226, 232, 240, 0.85);
					position: sticky;
					top: 0;
					z-index: 2;
					white-space: nowrap;
				}

				.nm-table-glass tbody tr {
					transition: background 0.18s ease;
				}

				.nm-table-glass tbody tr:hover {
					background: rgba(241, 245, 249, 0.7);
				}

				.nm-table-glass tbody td {
					padding: 14px 18px;
					border-bottom: 1px solid rgba(241, 245, 249, 0.85);
					color: var(--nm-txt-body);
					vertical-align: middle;
					white-space: nowrap;
				}

				.nm-table-glass tbody tr:last-child td {
					border-bottom: none;
				}

				.nm-target-name {
					font-weight: 700;
					color: var(--nm-txt-title);
				}

				.nm-target-host {
					font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
					font-size: 0.82rem;
					color: var(--nm-txt-sub);
				}

				.nm-num {
					font-variant-numeric: tabular-nums;
					font-weight: 650;
					color: var(--nm-txt-title);
				}

				/* 区域胶囊标签 */
				.nm-tag-pill {
					display: inline-flex;
					align-items: center;
					padding: 3px 9px;
					border-radius: 8px;
					font-size: 0.76rem;
					font-weight: 650;
					background: rgba(241, 245, 249, 0.9);
					border: 1px solid rgba(226, 232, 240, 0.9);
					color: #475569;
				}

				.nm-tag-pill.cn {
					background: rgba(239, 246, 255, 0.9);
					border-color: rgba(191, 219, 254, 0.9);
					color: #1d4ed8;
				}

				.nm-tag-pill.overseas {
					background: rgba(245, 243, 255, 0.9);
					border-color: rgba(221, 214, 254, 0.9);
					color: #6d28d9;
				}

				/* 动态呼吸 LED 状态指示器 */
				.nm-led-box {
					width: 20px;
					height: 20px;
					display: inline-flex;
					align-items: center;
					justify-content: center;
					position: relative;
				}

				@keyframes nm-led-ping {
					0% { transform: scale(0.85); opacity: 0.8; }
					50% { transform: scale(1.45); opacity: 0.2; }
					100% { transform: scale(0.85); opacity: 0.8; }
				}

				.nm-led-ping-ring {
					position: absolute;
					width: 16px;
					height: 16px;
					border-radius: 50%;
					animation: nm-led-ping 2.6s cubic-bezier(0.4, 0, 0.6, 1) infinite;
				}

				.nm-led-center {
					width: 9px;
					height: 9px;
					border-radius: 50%;
					position: relative;
					z-index: 1;
				}

				.nm-led-good .nm-led-ping-ring { background: rgba(16, 185, 129, 0.45); }
				.nm-led-good .nm-led-center { background: #10b981; box-shadow: 0 0 8px rgba(16, 185, 129, 0.8); }

				.nm-led-warn .nm-led-ping-ring { background: rgba(245, 158, 11, 0.45); }
				.nm-led-warn .nm-led-center { background: #f59e0b; box-shadow: 0 0 8px rgba(245, 158, 11, 0.8); }

				.nm-led-bad .nm-led-ping-ring { background: rgba(239, 68, 68, 0.45); }
				.nm-led-bad .nm-led-center { background: #ef4444; box-shadow: 0 0 8px rgba(239, 68, 68, 0.8); }

				.nm-led-off .nm-led-ping-ring { display: none; }
				.nm-led-off .nm-led-center { background: #cbd5e1; }

				/* 移动端与自适应视图 */
				@media (max-width: 860px) {
					.nm-table-glass-wrap {
						display: none;
					}
					.nm-cards-mobile {
						display: grid !important;
					}
				}

				@media (min-width: 861px) {
					.nm-cards-mobile {
						display: none !important;
					}
				}

				.nm-cards-mobile {
					display: none;
					grid-template-columns: repeat(auto-fit, minmax(310px, 1fr));
					gap: 16px;
				}

				.nm-foot-sub {
					padding: 14px 22px;
					font-size: 0.82rem;
					color: var(--nm-txt-sub);
				}
			`;
			document.head.appendChild(style);

			/* 统一增强：卡片高光 / 弹性上浮 / 表格斑马纹 / 键盘可达 / 减弱动效偏好 */
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

					.nm-table-glass tbody tr:nth-child(even) { background: rgba(248, 250, 252, 0.5); }

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

		/* 工具栏 (毛玻璃卡片) */
		var bar = common.el('div', 'nm-glass-card nm-toolbar-glass');
		var barRow = common.el('div', 'nm-row');
		barRow.style.display = 'flex';
		barRow.style.alignItems = 'center';
		barRow.style.flexWrap = 'wrap';
		barRow.style.gap = '16px';
		barRow.style.width = '100%';

		var fRegion = common.el('div', 'nm-field-glass');
		var selRegion = common.el('select', 'nm-select-glass');
		[
			['all', _('全部区域')],
			['cn', _('国内')],
			['overseas', _('国外')],
			['other', _('其他')]
		].forEach(function(o) {
			var op = common.el('option', '', o[1]);
			op.value = o[0];
			selRegion.appendChild(op);
		});
		selRegion.addEventListener('change', function() { filterRegion = selRegion.value; renderTable(); });
		fRegion.appendChild(common.el('label', '', _('区域')));
		fRegion.appendChild(selRegion);
		barRow.appendChild(fRegion);

		var fStatus = common.el('div', 'nm-field-glass');
		var selStatus = common.el('select', 'nm-select-glass');
		[
			['all', _('全部状态')],
			['online', _('在线')],
			['failed', _('失败')],
			['disabled', _('停用')]
		].forEach(function(o) {
			var op = common.el('option', '', o[1]);
			op.value = o[0];
			selStatus.appendChild(op);
		});
		selStatus.addEventListener('change', function() { filterStatus = selStatus.value; renderTable(); });
		fStatus.appendChild(common.el('label', '', _('状态')));
		fStatus.appendChild(selStatus);
		barRow.appendChild(fStatus);

		var fKw = common.el('div', 'nm-field-glass');
		var inKw = common.el('input', 'nm-input-glass');
		inKw.type = 'search';
		inKw.placeholder = _('搜索名称或地址');
		inKw.addEventListener('input', function() { keyword = inKw.value.toLowerCase(); renderTable(); });
		fKw.appendChild(common.el('label', '', _('搜索')));
		fKw.appendChild(inKw);
		barRow.appendChild(fKw);

		var spacer = common.el('div', 'nm-spacer');
		spacer.style.flex = '1';
		barRow.appendChild(spacer);

		var btnPause = common.el('button', 'nm-btn-glass');
		function updatePauseBtn() {
			common.clear(btnPause);
			if (paused) {
				btnPause.className = 'nm-btn-glass nm-btn-active-glass';
				btnPause.innerHTML = `
					<svg width="14" height="14" viewBox="0 0 16 16" fill="currentColor"><path d="M4 3l9 5-9 5V3z"/></svg>
					<span>${_('Resume')}</span>
				`;
			} else {
				btnPause.className = 'nm-btn-glass';
				btnPause.innerHTML = `
					<svg width="14" height="14" viewBox="0 0 16 16" fill="currentColor"><path d="M4 3h3v10H4V3zm5 0h3v10H9V3z"/></svg>
					<span>${_('暂停')}</span>
				`;
			}
		}
		updatePauseBtn();
		btnPause.addEventListener('click', function() {
			paused = !paused;
			updatePauseBtn();
		});
		barRow.appendChild(btnPause);

		bar.appendChild(barRow);
		page.appendChild(bar);

		/* 顶部实时指标条 */
		var strip = common.el('div', 'nm-strip-grid');
		page.appendChild(strip);

		/* 表格毛玻璃容器 */
		var wrap = common.el('div', 'nm-table-glass-wrap');
		var table = common.el('table', 'nm-table-glass');
		var thead = common.el('thead', '');
		var tbody = common.el('tbody', '');
		table.appendChild(thead);
		table.appendChild(tbody);
		wrap.appendChild(table);
		page.appendChild(wrap);

		var heads = [
			'', _('名称'), _('地址'), _('区域'), _('状态'),
			_('当前'), _('平均'), _('P95'), _('丢包'),
			_('在线率'), _('连续失败'), _('最后检测')
		];
		var tr = common.el('tr', '');
		heads.forEach(function(h) {
			var th = common.el('th', '', h);
			tr.appendChild(th);
		});
		thead.appendChild(tr);

		/* 窄屏自适应卡片容器 */
		var cards = common.el('div', 'nm-cards-mobile');
		page.appendChild(cards);

		/* 底部状态提示条 */
		var foot = common.el('div', 'nm-glass-card nm-foot-sub');
		page.appendChild(foot);

		function match(t) {
			if (filterRegion !== 'all' && t.region !== filterRegion) return false;
			if (filterStatus !== 'all' && t.status !== filterStatus) return false;
			if (keyword) {
				var s = ((t.name || '') + ' ' + (t.host || '') + ' ' + (t.label || '')).toLowerCase();
				if (s.indexOf(keyword) < 0) return false;
			}
			return true;
		}

		/* 状态诊断图标（矢量） */
		function statusIcon(t) {
			if (!t.enabled) return icons.online(20, false);
			if (t.last_error === 'dns') return icons.dnsFail(20);
			if (t.last_error) return icons.packetLoss(100, 20);
			if (t.grade === 'poor' || t.grade === 'severe') return icons.highLatency(t.latency, t.grade, 20);
			return icons.online(20, true);
		}

		/* 动态呼吸 LED 节点 */
		function createLedIndicator(t) {
			var wrap = common.el('div', 'nm-led-box');
			var cls = 'nm-led-off';
			if (t.enabled) {
				if (t.status === 'online') {
					cls = (t.grade === 'poor' || t.grade === 'severe') ? 'nm-led-warn' : 'nm-led-good';
				} else {
					cls = 'nm-led-bad';
				}
			}
			wrap.classList.add(cls);
			wrap.appendChild(common.el('span', 'nm-led-ping-ring', ''));
			wrap.appendChild(common.el('span', 'nm-led-center', ''));
			return wrap;
		}

		function gradeFromCfg(ms) {
			if (ms == null || isNaN(ms)) return 'unknown';
			var ex = parseFloat(cfg.latency_excellent) || 50;
			var gd = parseFloat(cfg.latency_good) || 100;
			var fr = parseFloat(cfg.latency_fair) || 200;
			var pr = parseFloat(cfg.latency_poor) || 500;
			if (ms <= ex) return 'excellent';
			if (ms <= gd) return 'good';
			if (ms <= fr) return 'fair';
			if (ms <= pr) return 'poor';
			return 'severe';
		}

		/* 玻璃风指标小卡片生成器 */
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

		function renderStrip(d) {
			common.clear(strip);
			var o = d.overall || {};
			var ok = (o.offline || 0) === 0;

			strip.appendChild(makeGlassStripCard(
				_('在线目标'),
				String(o.online || 0) + ' / ' + String(o.total || 0),
				_('异常') + ': ' + (o.offline || 0),
				icons.online(46, ok),
				ok ? 'nm-c-ok' : 'nm-c-bad'
			));

			var curGrade = gradeFromCfg(o.current);
			strip.appendChild(makeGlassStripCard(
				_('当前延迟'),
				common.fmt.latency(o.current) + ' ms',
				_('最近一次检测'),
				icons.latencyDial(o.current, curGrade, 46),
				common.gradeClass(curGrade)
			));

			strip.appendChild(makeGlassStripCard(
				_('丢包率'),
				common.fmt.percent(o.loss),
				_('按样本加权'),
				icons.lossRing(o.loss, 46),
				(o.loss > 5) ? 'nm-c-bad' : (o.loss > 0 ? 'nm-c-warn' : 'nm-c-ok')
			));

			strip.appendChild(makeGlassStripCard(
				_('最后检测'),
				common.fmt.ago(d.tick),
				common.fmt.clock(d.tick),
				icons.clock(d.tick, 46)
			));
		}

		function renderTable() {
			if (!latest) return;
			common.clear(tbody);
			common.clear(cards);
			renderStrip(latest);

			var list = (latest.targets || []).filter(match);
			if (!list.length) {
				var tr0 = common.el('tr', '');
				var td0 = common.el('td', 'nm-empty', _('No matching targets'));
				td0.colSpan = heads.length;
				td0.style.padding = '38px';
				td0.style.textAlign = 'center';
				td0.style.color = 'var(--nm-txt-sub)';
				tr0.appendChild(td0);
				tbody.appendChild(tr0);

				var emptyCard = common.el('div', 'nm-glass-card', _('No matching targets'));
				emptyCard.style.padding = '36px';
				emptyCard.style.textAlign = 'center';
				cards.appendChild(emptyCard);
				return;
			}

			for (var i = 0; i < list.length; i++) {
				var t = list[i];
				var row = common.el('tr', '');

				// 1. 动态呼吸 LED 状态指示
				var tdDot = common.el('td', '');
				tdDot.style.textAlign = 'center';
				tdDot.appendChild(createLedIndicator(t));
				row.appendChild(tdDot);

				// 2. 名称
				var tdName = common.el('td', 'nm-target-name', t.name || t.id);
				row.appendChild(tdName);

				// 3. 地址
				var tdHost = common.el('td', 'nm-target-host', t.host || '');
				row.appendChild(tdHost);

				// 4. 区域胶囊
				var tdRegion = common.el('td', '');
				var regCls = (t.region === 'cn') ? 'cn' : ((t.region === 'overseas') ? 'overseas' : '');
				var regPill = common.el('span', 'nm-tag-pill ' + regCls, t.label ? t.label : common.regionText(t.region));
				tdRegion.appendChild(regPill);
				row.appendChild(tdRegion);

				// 5. 状态与诊断图标
				var stText = t.enabled ? (t.status === 'online' ? _('在线') : _('失败')) : _('停用');
				if (!t.enabled) stText = _('停用');
				else if (t.last_error) stText = common.errorText(t.last_error);

				var tdSt = common.el('td', '');
				tdSt.style.display = 'flex';
				tdSt.style.alignItems = 'center';
				tdSt.style.gap = '8px';
				tdSt.appendChild(common.inlineIcon(statusIcon(t)));
				tdSt.appendChild(common.el('span', common.gradeClass(t.grade), stText));
				row.appendChild(tdSt);

				// 6-11. 指标数值
				row.appendChild(common.el('td', 'nm-num', common.fmt.latency(t.latency)));
				row.appendChild(common.el('td', 'nm-num', common.fmt.latency(t.avg)));
				row.appendChild(common.el('td', 'nm-num', common.fmt.latency(t.p95)));
				row.appendChild(common.el('td', 'nm-num', common.fmt.percent(t.loss)));
				row.appendChild(common.el('td', 'nm-num', common.fmt.percent(t.success_rate, 0)));
				row.appendChild(common.el('td', 'nm-num', String(t.streak_fail || 0)));

				// 12. 最后检查时间
				row.appendChild(common.el('td', 'nm-txt-sub', common.fmt.ago(t.last_check)));

				tbody.appendChild(row);

				// 窄屏卡片构建
				var tc = common.targetCard(t);
				tc.classList.add('nm-glass-card');
				cards.appendChild(tc);
			}

			foot.textContent = _('更新') + ': ' + common.fmt.clock(latest.updated) +
				' · ' + _('间隔') + ': ' + (cfg.interval || 10) + 's' +
				' · ' + _('界面刷新') + ': ' + refresh + 's';
		}

		function update() {
			if (paused) return Promise.resolve();
			return common.api.getStatus(false).then(function(d) {
				latest = d;
				renderTable();
			}).catch(function(e) {
				common.clear(tbody);
				var tr0 = common.el('tr', '');
				var td0 = common.el('td', 'nm-empty', String(e.message || e));
				td0.colSpan = heads.length;
				td0.style.padding = '28px';
				tr0.appendChild(td0);
				tbody.appendChild(tr0);
			});
		}

		update();
		poll.add(update, refresh);

		return root;
	}
});
