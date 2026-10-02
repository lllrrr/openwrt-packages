/*
 * 延迟曲线页面：多目标对比折线图（自研 SVG 图表，支持鼠标悬停与触摸查看）
 * 白色毛玻璃质感 + 高级动态 SVG 动效重构版本
 * 针对折线交互、多目标彩色胶囊选择器与统计卡片进行美化升级。
 */

'use strict';
'require view';
'require poll';
'require netmonitor.common as common';
'require netmonitor.chart as chart';
'require netmonitor.icons as icons';

var RANGES = [
	['1m', '1 min'],
	['5m', '5 min'],
	['15m', '15 min'],
	['30m', '30 min'],
	['1h', '1 hour'],
	['6h', '6 hours'],
	['24h', '24 hours']
];

return view.extend({
	load: function() {
		common.css();
		return Promise.all([common.loadI18n(), common.api.getConfig()]);
	},

	render: function(res) {
		common.css();

		var cfg = (res && res[1]) || {};
		var refresh = Math.max(3, parseInt(cfg.ui_refresh, 10) || 2);
		var range = '15m';
		var selected = {};
		var selectAll = true;
		var data = null;
		var chartBox, legend, summary, hint;

		// 注入系统级白色毛玻璃、排版体系与动态 SVG 微动效
		(function injectChartStyles() {
			if (document.getElementById('nm-chart-glass-theme')) return;
			var style = document.createElement('style');
			style.id = 'nm-chart-glass-theme';
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

				/* 毛玻璃卡片通用基础 */
				.nm-glass-card {
					background: var(--nm-glass-card-bg);
					backdrop-filter: var(--nm-blur);
					-webkit-backdrop-filter: var(--nm-blur);
					border: 1px solid var(--nm-glass-border);
					border-radius: 22px;
					box-shadow: var(--nm-glass-shadow);
					transition: transform 0.25s ease, box-shadow 0.25s ease;
					position: relative;
				}

				.nm-glass-card:hover {
					box-shadow: var(--nm-glass-shadow-hover);
				}

				/* 工具栏与筛选区域 */
				.nm-chart-toolbar {
					padding: 18px 26px;
					display: flex;
					flex-direction: column;
					gap: 16px;
				}

				.nm-toolbar-row {
					display: flex;
					align-items: center;
					flex-wrap: wrap;
					gap: 18px;
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

				.nm-select-glass {
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

				.nm-select-glass:focus {
					background: #ffffff;
					border-color: var(--nm-c-primary);
					box-shadow: 0 0 0 3px rgba(59, 130, 246, 0.16);
				}

				/* 彩色目标过滤 Chips 胶囊 */
				.nm-chips-container {
					display: flex;
					flex-wrap: wrap;
					gap: 9px;
					padding-top: 4px;
				}

				.nm-chip-btn {
					background: rgba(255, 255, 255, 0.7);
					backdrop-filter: blur(8px);
					-webkit-backdrop-filter: blur(8px);
					border: 1px solid rgba(226, 232, 240, 0.9);
					border-radius: 20px;
					padding: 6px 14px;
					font-size: 0.82rem;
					font-weight: 650;
					color: var(--nm-txt-sub);
					cursor: pointer;
					display: inline-flex;
					align-items: center;
					gap: 7px;
					transition: all 0.2s cubic-bezier(0.4, 0, 0.2, 1);
					user-select: none;
					box-shadow: 0 1px 3px rgba(0, 0, 0, 0.02);
				}

				.nm-chip-btn:hover {
					background: #ffffff;
					transform: translateY(-1.5px);
					box-shadow: 0 4px 10px rgba(0, 0, 0, 0.06);
					color: var(--nm-txt-title);
				}

				.nm-chip-btn.active {
					background: rgba(255, 255, 255, 0.98);
					box-shadow: 0 3px 12px rgba(15, 23, 42, 0.06);
					color: var(--nm-txt-title);
				}

				.nm-chip-dot {
					width: 8px;
					height: 8px;
					border-radius: 50%;
					display: inline-block;
					transition: all 0.2s ease;
				}

				.nm-chip-btn.active .nm-chip-dot {
					box-shadow: 0 0 8px currentColor;
				}

				/* 统计指标卡片网格 */
				.nm-chart-summary-grid {
					display: grid;
					grid-template-columns: repeat(auto-fit, minmax(190px, 1fr));
					gap: 16px;
					margin-bottom: 22px;
				}

				.nm-sum-card {
					background: rgba(255, 255, 255, 0.68);
					backdrop-filter: blur(12px);
					-webkit-backdrop-filter: blur(12px);
					border: 1px solid rgba(255, 255, 255, 0.95);
					border-radius: 16px;
					padding: 16px 18px;
					box-shadow: 0 2px 8px rgba(15, 23, 42, 0.02);
					position: relative;
					overflow: hidden;
					transition: transform 0.2s ease;
				}

				.nm-sum-card:hover {
					transform: translateY(-1.5px);
					background: rgba(255, 255, 255, 0.85);
				}

				.nm-sum-card-title {
					font-size: 0.78rem;
					font-weight: 700;
					color: var(--nm-txt-sub);
					text-transform: uppercase;
					letter-spacing: 0.05em;
				}

				.nm-sum-card-val {
					font-size: 1.45rem;
					font-weight: 850;
					margin-top: 6px;
					letter-spacing: -0.025em;
					color: var(--nm-txt-title);
					font-variant-numeric: tabular-nums;
				}

				/* 图表主体卡片 */
				.nm-chart-main-card {
					padding: 26px;
				}

				.nm-chart-box-glass {
					background: rgba(255, 255, 255, 0.52);
					border-radius: 18px;
					padding: 16px 12px;
					border: 1px solid rgba(255, 255, 255, 0.8);
					box-shadow: inset 0 1px 4px rgba(0, 0, 0, 0.02);
				}

				/* 图例样式 */
				.nm-chart-legend-glass {
					display: flex;
					flex-wrap: wrap;
					gap: 12px;
					margin-top: 18px;
					padding-top: 14px;
					border-top: 1px solid rgba(241, 245, 249, 0.85);
				}

				.nm-chart-legend-glass span {
					display: inline-flex;
					align-items: center;
					gap: 7px;
					font-size: 0.82rem;
					font-weight: 650;
					color: var(--nm-txt-title);
					background: rgba(255, 255, 255, 0.75);
					padding: 4px 12px;
					border-radius: 10px;
					border: 1px solid rgba(226, 232, 240, 0.85);
					box-shadow: 0 1px 3px rgba(0, 0, 0, 0.02);
				}

				.nm-chart-legend-glass span i {
					width: 9px;
					height: 9px;
					border-radius: 50%;
					display: inline-block;
				}

				/* 底部数据源状态小条 */
				.nm-chart-hint-pill {
					margin-top: 12px;
					display: inline-flex;
					align-items: center;
					gap: 6px;
					font-size: 0.8rem;
					color: var(--nm-txt-sub);
				}

				/* 动态 SVG 采样波浪动画 */
				@keyframes nm-chart-wave-bar {
					0%, 100% { transform: scaleY(0.45); }
					50% { transform: scaleY(1.15); }
				}

				.nm-wave-b1 { transform-origin: 50% 100%; animation: nm-chart-wave-bar 1.5s ease-in-out infinite; }
				.nm-wave-b2 { transform-origin: 50% 100%; animation: nm-chart-wave-bar 1.5s ease-in-out 0.25s infinite; }
				.nm-wave-b3 { transform-origin: 50% 100%; animation: nm-chart-wave-bar 1.5s ease-in-out 0.5s infinite; }
				.nm-wave-b4 { transform-origin: 50% 100%; animation: nm-chart-wave-bar 1.5s ease-in-out 0.75s infinite; }
				.nm-wave-b5 { transform-origin: 50% 100%; animation: nm-chart-wave-bar 1.5s ease-in-out 1s infinite; }
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
		var bar = common.el('div', 'nm-glass-card nm-chart-toolbar');
		var row = common.el('div', 'nm-toolbar-row');

		var fRange = common.el('div', 'nm-field-glass');
		var selRange = common.el('select', 'nm-select-glass');
		RANGES.forEach(function(r) {
			var op = common.el('option', '', _(r[1]));
			op.value = r[0];
			selRange.appendChild(op);
		});
		selRange.value = range;
		selRange.addEventListener('change', function() {
			range = selRange.value;
			reload();
		});
		fRange.appendChild(common.el('label', '', _('Time range')));
		fRange.appendChild(selRange);
		row.appendChild(fRange);

		var fPreset = common.el('div', 'nm-field-glass');
		var selPreset = common.el('select', 'nm-select-glass');
		[
			['all', _('All targets')],
			['cn', _('China')],
			['overseas', _('Overseas')],
			['other', _('Other')]
		].forEach(function(o) {
			var op = common.el('option', '', o[1]);
			op.value = o[0];
			selPreset.appendChild(op);
		});
		selPreset.addEventListener('change', function() {
			var v = selPreset.value;
			selectAll = (v === 'all');
			selected = {};
			if (!data) return;
			for (var i = 0; i < data.series.length; i++) {
				if (v === 'all' || data.series[i].region === v)
					selected[data.series[i].id] = true;
			}
			drawChart();
		});
		fPreset.appendChild(common.el('label', '', _('Quick filter')));
		fPreset.appendChild(selPreset);
		row.appendChild(fPreset);

		var spacer = common.el('div', 'nm-spacer');
		spacer.style.flex = '1';
		row.appendChild(spacer);
		bar.appendChild(row);

		// 彩色多选胶囊选择器
		var chips = common.el('div', 'nm-chips-container');
		bar.appendChild(chips);
		page.appendChild(bar);

		/* 图表主卡片 */
		var card = common.el('div', 'nm-glass-card nm-chart-main-card');
		summary = common.el('div', 'nm-chart-summary-grid');
		card.appendChild(summary);

		chartBox = common.el('div', 'nm-chart-box nm-chart-box-glass');
		card.appendChild(chartBox);

		legend = common.el('div', 'nm-chart-legend nm-chart-legend-glass');
		card.appendChild(legend);

		hint = common.el('div', 'nm-chart-hint-pill');
		card.appendChild(hint);

		page.appendChild(card);

		/* 阈值判定函数 */
		function gradeOf(ms) {
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

		/* 动态 SVG 实时采样声波柱生成器 */
		function buildLiveWaveSvg(bars) {
			var b1 = Math.min(22, Math.max(5, (bars[0] || 15) / 5));
			var b2 = Math.min(22, Math.max(5, (bars[1] || 35) / 5));
			var b3 = Math.min(22, Math.max(5, (bars[2] || 25) / 5));
			var b4 = Math.min(22, Math.max(5, (bars[3] || 45) / 5));
			var b5 = Math.min(22, Math.max(5, (bars[4] || 18) / 5));

			return `
			<svg width="44" height="28" viewBox="0 0 44 28" fill="none" xmlns="http://www.w3.org/2000/svg">
				<defs>
					<linearGradient id="nm-wave-grad" x1="0%" y1="100%" x2="0%" y2="0%">
						<stop offset="0%" stop-color="#2563eb" stop-opacity="0.5" />
						<stop offset="100%" stop-color="#60a5fa" />
					</linearGradient>
				</defs>
				<rect class="nm-wave-b1" x="2" y="${28 - b1}" width="4.5" height="${b1}" rx="2.2" fill="url(#nm-wave-grad)" />
				<rect class="nm-wave-b2" x="11" y="${28 - b2}" width="4.5" height="${b2}" rx="2.2" fill="url(#nm-wave-grad)" />
				<rect class="nm-wave-b3" x="20" y="${28 - b3}" width="4.5" height="${b3}" rx="2.2" fill="url(#nm-wave-grad)" />
				<rect class="nm-wave-b4" x="29" y="${28 - b4}" width="4.5" height="${b4}" rx="2.2" fill="url(#nm-wave-grad)" />
				<rect class="nm-wave-b5" x="38" y="${28 - b5}" width="4.5" height="${b5}" rx="2.2" fill="url(#nm-wave-grad)" />
			</svg>`;
		}

		function renderChips() {
			common.clear(chips);
			if (!data || !data.series.length) return;
			for (var i = 0; i < data.series.length; i++) {
				(function(s, idx) {
					var on = !!selected[s.id];
					var seriesColor = common.palette[idx % common.palette.length];
					var b = common.el('button', 'nm-chip-btn' + (on ? ' active' : ''));

					var dot = common.el('span', 'nm-chip-dot');
					dot.style.backgroundColor = seriesColor;
					dot.style.color = seriesColor;
					b.appendChild(dot);
					b.appendChild(document.createTextNode(s.name || s.id));

					if (on) {
						b.style.borderColor = seriesColor;
					}

					b.addEventListener('click', function() {
						if (selected[s.id]) delete selected[s.id];
						else selected[s.id] = true;
						renderChips();
						drawChart();
					});
					chips.appendChild(b);
				})(data.series[i], i);
			}
		}

		function releaseHold() {
			chartBox.style.minHeight = '';
			legend.style.minHeight = '';
			summary.style.minHeight = '';
		}
		
		function drawChart() {
			// 轮询重建前锁定容器高度：mount 内部会强制布局（clientWidth），
			// 若此时图表/摘要已清空，页面高度瞬时塌缩会把移动端滚动位置钳回顶部。
			var boxH = chartBox.offsetHeight || 0;
			var legH = legend.offsetHeight || 0;
			var sumH = summary.offsetHeight || 0;
			if (boxH > 0) chartBox.style.minHeight = boxH + 'px';
			if (legH > 0) legend.style.minHeight = legH + 'px';
			if (sumH > 0) summary.style.minHeight = sumH + 'px';
			
		common.clear(chartBox);
			common.clear(legend);
			common.clear(summary);
			if (!data) {
			releaseHold();
			return;
			}

			var series = [];
			var cur = [], mx = [], mn = [];
			for (var i = 0; i < data.series.length; i++) {
				var s = data.series[i];
				if (!selected[s.id]) continue;
				series.push({
					name: s.name,
					color: common.palette[data.series.indexOf(s) % common.palette.length],
					points: s.points
				});
				var last = null;
				for (var j = s.points.length - 1; j >= 0; j--) {
					if (s.points[j].l != null) { last = s.points[j].l; break; }
				}
				if (last != null) cur.push(last);
				if (s.summary) {
					if (s.summary.max != null) mx.push(s.summary.max);
					if (s.summary.min != null) mn.push(s.summary.min);
				}
			}

			if (!series.length) {
				var emptyEl = common.el('div', 'nm-empty', _('No target selected'));
				emptyEl.style.padding = '44px';
				emptyEl.style.textAlign = 'center';
				emptyEl.style.color = 'var(--nm-txt-sub)';
				chartBox.appendChild(emptyEl);
				releaseHold();
				return;
			}

			chart.mount(chartBox, series, { height: 280, area: (series.length === 1) });

			for (var k = 0; k < series.length; k++) {
				var item = common.el('span', '');
				var i2 = common.el('i', '');
				i2.style.background = series[k].color;
				item.appendChild(i2);
				item.appendChild(document.createTextNode(series[k].name));
				legend.appendChild(item);
			}

			function sumBox(label, value, cls, svg) {
				var b = common.el('div', 'nm-sum-card');
				var top = common.el('div', '');
				top.style.display = 'flex';
				top.style.justifyContent = 'space-between';
				top.style.alignItems = 'center';

				top.appendChild(common.el('div', 'nm-sum-card-title', label));
				if (svg) {
					var iconWrap = common.el('div', '');
					if (typeof svg === 'string') iconWrap.innerHTML = svg;
					else iconWrap.appendChild(svg);
					top.appendChild(iconWrap);
				}
				b.appendChild(top);
				b.appendChild(common.el('div', 'nm-sum-card-val ' + (cls || ''), value));
				return b;
			}

			var avgCur = cur.length ? (cur.reduce(function(a, b) { return a + b; }, 0) / cur.length) : null;
			var maxV = mx.length ? Math.max.apply(null, mx) : null;
			var minV = mn.length ? Math.min.apply(null, mn) : null;
			var rangeLabel = _(RANGES.filter(function(r) { return r[0] === range; })[0][1]);

			summary.appendChild(sumBox(_('Current'), common.fmt.latency(avgCur) + ' ms',
				common.gradeClass(gradeOf(avgCur)), icons.latencyDial(avgCur, gradeOf(avgCur), 40)));
			summary.appendChild(sumBox(_('Max'), common.fmt.latency(maxV) + ' ms',
				common.gradeClass(gradeOf(maxV)), icons.highLatency(maxV, gradeOf(maxV), 40)));
			summary.appendChild(sumBox(_('Min'), common.fmt.latency(minV) + ' ms',
				common.gradeClass(gradeOf(minV)), icons.gradeGauge(minV, gradeOf(minV), 40)));
			summary.appendChild(sumBox(_('Range'), rangeLabel, '', icons.database(40)));

			// 动态 SVG 音波实时采样指示
			var plot = [];
			for (var q = 0; q < cur.length && q < 5; q++) plot.push(cur[q]);
			summary.appendChild(sumBox(_('Live sampling'),
				String(series.length) + ' / ' + String(data.series.length),
				'', buildLiveWaveSvg(plot)));

			hint.innerHTML = `
				<svg width="14" height="14" viewBox="0 0 16 16" fill="currentColor" style="opacity:0.75"><circle cx="8" cy="8" r="7" stroke="currentColor" fill="none"/><path d="M8 4v5M8 11v1" stroke="currentColor" stroke-width="1.5"/></svg>
				<span>${(data.source === 'persistent') ? _('Data source: persistent history on flash') : _('Data source: in-memory ring buffer')}</span>
			`;
			releaseHold();
		}

		function reload() {
			var sy = window.scrollY || document.documentElement.scrollTop || 0;
			return common.api.getHistory({ range: range, max_points: 600 }).then(function(d) {
				data = d;
				if (selectAll) {
					selected = {};
					for (var i = 0; i < data.series.length; i++)
						selected[data.series[i].id] = true;
				}
				renderChips();
				drawChart();
				// 兜底：若移动端浏览器把滚动位置弹回顶部，则恢复原位
				if (sy > 0) {
				var now = window.scrollY || document.documentElement.scrollTop || 0;
				if (now === 0) window.scrollTo(0, sy);
				}
			}).catch(function(e) {
				var bh = chartBox.offsetHeight || 0;
				if (bh > 0) chartBox.style.minHeight = bh + 'px';
				common.clear(chartBox);
				var errEl = common.el('div', 'nm-empty', String(e.message || e));
				errEl.style.padding = '30px';
				chartBox.appendChild(errEl);
				chartBox.style.minHeight = '';
			});
		}

		poll.add(reload, refresh);
		reload();

		return root;
	}
});
