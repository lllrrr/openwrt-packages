/*
 * 国内 / 国外页面：分区指标对比 + 区域平均延迟曲线
 * 白色毛玻璃质感 + 高级动态 SVG 动效重构版本
 * 全面优化分区卡片层级、动态环形指标与折线图对比呈现。
 */

'use strict';
'require view';
'require poll';
'require netmonitor.common as common';
'require netmonitor.chart as chart';
'require netmonitor.icons as icons';

var RANGES = [
	['5m', '5 min'], ['15m', '15 min'], ['30m', '30 min'],
	['1h', '1 hour'], ['6h', '6 hours'], ['24h', '24 hours']
];

return view.extend({
	load: function() {
		common.css();
		return Promise.all([common.loadI18n(), common.api.getConfig()]);
	},

	render: function(res) {
		common.css();

		var cfg = (res && res[1]) || {};
		var refresh = Math.max(5, parseInt(cfg.ui_refresh, 10) || 2);
		var range = '1h';
		var data = null;
		var status = null;

		// 注入系统级白色毛玻璃、排版体系与动态 SVG 微动效
		(function injectRegionsStyles() {
			if (document.getElementById('nm-regions-glass-theme')) return;
			var style = document.createElement('style');
			style.id = 'nm-regions-glass-theme';
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
					--nm-c-cn: #2563eb;
					--nm-c-ov: #8b5cf6;
					
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

				/* 分区对比大卡片网格：每卡限宽居中，避免在宽屏上拉得过大 */
				.nm-regions-grid {
					display: grid;
					grid-template-columns: repeat(auto-fit, minmax(340px, 520px));
					justify-content: center;
					gap: 18px;
				}

				.nm-region-card {
					padding: 20px;
					display: flex;
					flex-direction: column;
					gap: 14px;
				}

				.nm-region-header {
					display: flex;
					align-items: center;
					justify-content: space-between;
				}

				.nm-region-title {
					font-size: 1.02rem;
					font-weight: 750;
					color: var(--nm-txt-title);
					letter-spacing: -0.02em;
				}

				.nm-tag-pill {
					display: inline-flex;
					align-items: center;
					padding: 4px 11px;
					border-radius: 10px;
					font-size: 0.76rem;
					font-weight: 700;
					background: rgba(241, 245, 249, 0.9);
					border: 1px solid rgba(226, 232, 240, 0.95);
					color: #475569;
				}

				.nm-tag-pill.cn {
					background: rgba(239, 246, 255, 0.9);
					border-color: rgba(191, 219, 254, 0.9);
					color: var(--nm-c-cn);
				}

				.nm-tag-pill.ov {
					background: rgba(245, 243, 255, 0.9);
					border-color: rgba(221, 214, 254, 0.9);
					color: var(--nm-c-ov);
				}

				/* 区域主视觉展位：SVG 图标 + 主读数（收敛尺寸，避免在宽屏上过大） */
				.nm-region-hero {
					display: flex;
					align-items: center;
					gap: 14px;
					background: rgba(255, 255, 255, 0.55);
					border-radius: 14px;
					padding: 12px 16px;
					border: 1px solid rgba(255, 255, 255, 0.85);
				}

				.nm-region-svg-box {
					flex-shrink: 0;
					width: 64px;
					height: 64px;
					display: flex;
					align-items: center;
					justify-content: center;
					position: relative;
				}

				/* 图标以 84px 生成（viewBox 120×120），随盒体等比缩放，避免溢出 */
				.nm-region-svg-box svg {
					width: 100%;
					height: 100%;
				}

				.nm-region-hero-right {
					display: flex;
					flex-direction: column;
					gap: 3px;
				}

				.nm-region-avg-val {
					font-size: 1.55rem;
					font-weight: 850;
					letter-spacing: -0.04em;
					line-height: 1.1;
					font-variant-numeric: tabular-nums;
				}

				.nm-region-avg-label {
					font-size: 0.72rem;
					font-weight: 650;
					color: var(--nm-txt-sub);
					text-transform: uppercase;
					letter-spacing: 0.04em;
				}

				/* 6项细化指标卡片矩阵 */
				.nm-region-metrics-grid {
					display: grid;
					grid-template-columns: repeat(3, 1fr);
					gap: 8px;
				}

				.nm-mini-metric {
					background: rgba(255, 255, 255, 0.65);
					backdrop-filter: blur(8px);
					-webkit-backdrop-filter: blur(8px);
					border: 1px solid rgba(255, 255, 255, 0.9);
					border-radius: 12px;
					padding: 8px 10px;
					display: flex;
					flex-direction: column;
					gap: 2px;
				}

				.nm-mini-metric span {
					font-size: 0.72rem;
					font-weight: 650;
					color: var(--nm-txt-light);
					text-transform: uppercase;
					letter-spacing: 0.04em;
				}

				.nm-mini-metric b {
					font-size: 0.98rem;
					font-weight: 750;
					color: var(--nm-txt-title);
					font-variant-numeric: tabular-nums;
				}

				/* 环形指标胶囊行 */
				.nm-target-rings-row {
					display: flex;
					gap: 12px;
					margin-top: 2px;
				}

				.nm-ring-card {
					flex: 1;
					background: rgba(255, 255, 255, 0.6);
					border: 1px solid rgba(255, 255, 255, 0.9);
					border-radius: 14px;
					padding: 10px 14px;
					display: flex;
					align-items: center;
					gap: 12px;
				}

				.nm-ring-text {
					display: flex;
					flex-direction: column;
				}

				.nm-ring-text b {
					font-size: 1.05rem;
					font-weight: 800;
					font-variant-numeric: tabular-nums;
				}

				.nm-ring-text span {
					font-size: 0.74rem;
					color: var(--nm-txt-sub);
					font-weight: 600;
				}

				/* 折线对比卡片 */
				.nm-compare-card {
					padding: 24px 26px;
				}

				.nm-chart-box-glass {
					background: rgba(255, 255, 255, 0.52);
					border-radius: 18px;
					padding: 16px 12px;
					border: 1px solid rgba(255, 255, 255, 0.8);
					box-shadow: inset 0 1px 4px rgba(0, 0, 0, 0.02);
					margin-top: 14px;
				}

				.nm-chart-legend-glass {
					display: flex;
					flex-wrap: wrap;
					gap: 12px;
					margin-top: 16px;
					padding-top: 14px;
					border-top: 1px solid rgba(241, 245, 249, 0.85);
				}

				.nm-chart-legend-glass span {
					display: inline-flex;
					align-items: center;
					gap: 7px;
					font-size: 0.84rem;
					font-weight: 650;
					color: var(--nm-txt-title);
					background: rgba(255, 255, 255, 0.75);
					padding: 4px 12px;
					border-radius: 10px;
					border: 1px solid rgba(226, 232, 240, 0.85);
				}

				.nm-chart-legend-glass span i {
					width: 9px;
					height: 9px;
					border-radius: 50%;
					display: inline-block;
				}

				/* 分区明细表格容器 */
				.nm-tables-grid {
					display: grid;
					grid-template-columns: repeat(auto-fit, minmax(420px, 1fr));
					gap: 20px;
				}

				.nm-subtable-card {
					padding: 22px;
					display: flex;
					flex-direction: column;
					gap: 14px;
				}

				.nm-table-glass-wrap {
					background: rgba(255, 255, 255, 0.55);
					border-radius: 16px;
					border: 1px solid rgba(255, 255, 255, 0.85);
					overflow-x: auto;
				}

				.nm-table-glass {
					width: 100%;
					border-collapse: separate;
					border-spacing: 0;
					text-align: left;
					font-size: 0.86rem;
				}

				.nm-table-glass thead th {
					background: rgba(248, 250, 252, 0.88);
					padding: 12px 14px;
					font-weight: 700;
					font-size: 0.78rem;
					color: var(--nm-txt-sub);
					text-transform: uppercase;
					letter-spacing: 0.04em;
					border-bottom: 1px solid rgba(226, 232, 240, 0.85);
					white-space: nowrap;
				}

				.nm-table-glass tbody td {
					padding: 11px 14px;
					border-bottom: 1px solid rgba(241, 245, 249, 0.85);
					color: var(--nm-txt-body);
					white-space: nowrap;
				}

				.nm-table-glass tbody tr:last-child td {
					border-bottom: none;
				}

				.nm-table-glass tbody tr:hover {
					background: rgba(241, 245, 249, 0.6);
				}

				.nm-num {
					font-variant-numeric: tabular-nums;
					font-weight: 650;
				}

				/* 动态 SVG 微动效 */
				@keyframes nm-pulse-soft {
					0%, 100% { transform: scale(1); opacity: 0.95; }
					50% { transform: scale(1.05); opacity: 0.8; }
				}
				.nm-svg-soft-pulse { animation: nm-pulse-soft 3s ease-in-out infinite; }
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
		var bar = common.el('div', 'nm-glass-card nm-toolbar-glass');
		var row = common.el('div', 'nm-row');
		row.style.display = 'flex';
		row.style.alignItems = 'center';
		row.style.gap = '14px';

		var fRange = common.el('div', 'nm-field-glass');
		var selRange = common.el('select', 'nm-select-glass');
		RANGES.forEach(function(r) {
			var op = common.el('option', '', _(r[1]));
			op.value = r[0];
			selRange.appendChild(op);
		});
		selRange.value = range;
		selRange.addEventListener('change', function() { range = selRange.value; reload(true); });
		fRange.appendChild(common.el('label', '', _('Time range')));
		fRange.appendChild(selRange);
		row.appendChild(fRange);
		bar.appendChild(row);
		page.appendChild(bar);

		/* 顶部两个区域指标卡片大网格 */
		var grid = common.el('div', 'nm-regions-grid');
		page.appendChild(grid);

		/* 区域平均延迟对比折线图 */
		var compare = common.el('div', 'nm-glass-card nm-compare-card');
		var cmpTitle = common.el('div', 'nm-row');
		cmpTitle.style.display = 'flex';
		cmpTitle.style.alignItems = 'center';
		cmpTitle.style.gap = '10px';
		cmpTitle.appendChild(common.inlineIcon(icons.trend(32)));
		cmpTitle.appendChild(common.el('div', 'nm-region-title', _('Region latency comparison')));
		compare.appendChild(cmpTitle);

		var compareBox = common.el('div', 'nm-chart-box nm-chart-box-glass');
		compare.appendChild(compareBox);

		var compareLegend = common.el('div', 'nm-chart-legend nm-chart-legend-glass');
		compare.appendChild(compareLegend);
		page.appendChild(compare);

		/* 分区明细表格容器 */
		var lists = common.el('div', 'nm-tables-grid');
		page.appendChild(lists);

		function regionCard(title, x, icon, regKey) {
			var c = common.el('div', 'nm-glass-card nm-region-card');

			// 头部：标题与目标数胶囊
			var head = common.el('div', 'nm-region-header');
			head.appendChild(common.el('div', 'nm-region-title', title));
			var tagCls = (regKey === 'cn') ? 'cn' : 'ov';
			head.appendChild(common.el('span', 'nm-tag-pill ' + tagCls, (x.total || 0) + ' ' + _('Target count')));
			c.appendChild(head);

			// 主视觉展台：SVG 与主读数
			var heroBox = common.el('div', 'nm-region-hero');
			var svgWrap = common.el('div', 'nm-region-svg-box nm-svg-soft-pulse');
			svgWrap.appendChild(common.svgBox(icon, 'nm-icon-card-svg'));
			heroBox.appendChild(svgWrap);

			var right = common.el('div', 'nm-region-hero-right');
			var valCls = (x.abnormal > 0) ? 'nm-c-warn' : 'nm-c-ok';
			right.appendChild(common.el('div', 'nm-region-avg-val ' + valCls, common.fmt.latency(x.avg) + ' ms'));
			right.appendChild(common.el('div', 'nm-region-avg-label', _('Average latency')));
			heroBox.appendChild(right);
			c.appendChild(heroBox);

			// 6项微型指标网格
			var m = common.el('div', 'nm-region-metrics-grid');
			function mm(label, value) {
				var d = common.el('div', 'nm-mini-metric');
				d.appendChild(common.el('span', '', label));
				d.appendChild(common.el('b', '', value));
				return d;
			}
			m.appendChild(mm(_('P95'), common.fmt.latency(x.p95) + ' ms'));
			m.appendChild(mm(_('Loss'), common.fmt.percent(x.loss)));
			m.appendChild(mm(_('Availability'), common.fmt.percent(x.online_rate, 0)));
			m.appendChild(mm(_('Abnormal'), String(x.abnormal || 0)));
			m.appendChild(mm(_('Online'), String(x.online || 0)));
			m.appendChild(mm(_('Total'), String(x.total || 0)));
			c.appendChild(m);

			// 环形指标胶囊行
			var rings = common.el('div', 'nm-target-rings-row');
			function ring(svg, label, value, cls) {
				var box = common.el('div', 'nm-ring-card');
				box.appendChild(common.svgBox(svg, 'nm-ring-svg'));
				var txt = common.el('div', 'nm-ring-text');
				txt.appendChild(common.el('b', cls || '', value));
				txt.appendChild(common.el('span', '', label));
				box.appendChild(txt);
				return box;
			}
			rings.appendChild(ring(icons.lossRing(x.loss, 44), _('Loss'), common.fmt.percent(x.loss, 1),
				(x.loss > 5) ? 'nm-c-bad' : (x.loss > 0 ? 'nm-c-warn' : 'nm-c-ok')));
			rings.appendChild(ring(icons.successRing(x.online_rate, 44), _('Availability'),
				common.fmt.percent(x.online_rate, 0),
				(x.online_rate >= 99) ? 'nm-c-ok' : (x.online_rate >= 95 ? 'nm-c-warn' : 'nm-c-bad')));
			c.appendChild(rings);

			return c;
		}

		function regionTargets(region) {
			var box = common.el('div', 'nm-glass-card nm-subtable-card');
			var regTitle = (region === 'cn' ? _('China network') : (region === 'overseas' ? _('Overseas network') : _('Other')));
			box.appendChild(common.el('div', 'nm-region-title', regTitle));

			var wrap = common.el('div', 'nm-table-glass-wrap');
			var tb = common.el('table', 'nm-table-glass');
			var thead = common.el('thead', '');
			var tbody = common.el('tbody', '');
			var tr = common.el('tr', '');
			[_('Name'), _('Current'), _('Average'), _('P95'), _('Loss'), _('Availability')].forEach(function(h) {
				tr.appendChild(common.el('th', '', h));
			});
			thead.appendChild(tr);
			tb.appendChild(thead);
			tb.appendChild(tbody);
			wrap.appendChild(tb);
			box.appendChild(wrap);

			var list = (status && status.targets ? status.targets : []).filter(function(t) {
				return t.region === region;
			});
			if (!list.length) {
				var tr0 = common.el('tr', '');
				var td0 = common.el('td', 'nm-empty', _('No targets'));
				td0.colSpan = 6;
				td0.style.padding = '24px';
				td0.style.textAlign = 'center';
				td0.style.color = 'var(--nm-txt-sub)';
				tr0.appendChild(td0);
				tbody.appendChild(tr0);
			}
			for (var i = 0; i < list.length; i++) {
				var t = list[i];
				var r = common.el('tr', '');
				r.appendChild(common.el('td', 'nm-target-name', t.name || t.id));
				r.appendChild(common.el('td', 'nm-num ' + common.gradeClass(t.grade), common.fmt.latency(t.latency)));
				r.appendChild(common.el('td', 'nm-num', common.fmt.latency(t.avg)));
				r.appendChild(common.el('td', 'nm-num', common.fmt.latency(t.p95)));
				r.appendChild(common.el('td', 'nm-num', common.fmt.percent(t.loss)));
				r.appendChild(common.el('td', 'nm-num', common.fmt.percent(t.success_rate, 0)));
				tbody.appendChild(r);
			}
			return box;
		}

		/* 按区域合并平均曲线 */
		function regionSeries(region) {
			if (!data) return [];
			var buckets = 60;
			var t0 = data.from, t1 = data.to;
			var step = Math.max(1, (t1 - t0) / buckets);
			var sum = [], cnt = [], lost = [];
			for (var i = 0; i < buckets; i++) { sum.push(0); cnt.push(0); lost.push(0); }

			for (var s = 0; s < data.series.length; s++) {
				var se = data.series[s];
				if (se.region !== region) continue;
				for (var p = 0; p < se.points.length; p++) {
					var pt = se.points[p];
					var bi = Math.floor((pt.t - t0) / step);
					if (bi < 0) bi = 0;
					if (bi >= buckets) bi = buckets - 1;
					if (pt.l != null) { sum[bi] += pt.l; cnt[bi]++; }
					else lost[bi]++;
				}
			}

			var out = [];
			for (var b = 0; b < buckets; b++) {
				var t = t0 + b * step;
				if (cnt[b] > 0)
					out.push({ t: t, l: sum[b] / cnt[b], s: 1 });
				else if (lost[b] > 0)
					out.push({ t: t, l: null, s: 0 });
			}
			return out;
		}

		function drawCompare() {
			common.clear(compareBox);
			common.clear(compareLegend);
			var series = [];
			var cn = regionSeries('cn');
			var ov = regionSeries('overseas');
			if (cn.length) series.push({ name: _('China'), color: '#3b82f6', points: cn });
			if (ov.length) series.push({ name: _('Overseas'), color: '#8b5cf6', points: ov });
			if (!series.length) {
				var emptyEl = common.el('div', 'nm-empty', _('No data in this range'));
				emptyEl.style.padding = '36px';
				emptyEl.style.textAlign = 'center';
				emptyEl.style.color = 'var(--nm-txt-sub)';
				compareBox.appendChild(emptyEl);
				return;
			}
			chart.mount(compareBox, series, { height: 260 });
			for (var i = 0; i < series.length; i++) {
				var item = common.el('span', '');
				var ic = common.el('i', '');
				ic.style.background = series[i].color;
				item.appendChild(ic);
				item.appendChild(document.createTextNode(series[i].name));
				compareLegend.appendChild(item);
			}
		}

		function renderRegions() {
			common.clear(grid);
			var r = (status && status.regions) || {};
			grid.appendChild(regionCard(_('China network'), r.cn || {}, icons.regionCN(84, r.cn || {}), 'cn'));
			grid.appendChild(regionCard(_('Overseas network'), r.overseas || {}, icons.regionGlobal(84, r.overseas || {}), 'ov'));

			common.clear(lists);
			lists.appendChild(regionTargets('cn'));
			lists.appendChild(regionTargets('overseas'));
		}

		function reload(hard) {
			return Promise.all([
				common.api.getHistory({ range: range, max_points: 600 }),
				common.api.getStatus(false)
			]).then(function(r) {
				data = r[0];
				status = r[1];
				renderRegions();
				drawCompare();
			}).catch(function(e) {
				common.clear(compareBox);
				var errEl = common.el('div', 'nm-empty', String(e.message || e));
				errEl.style.padding = '24px';
				compareBox.appendChild(errEl);
			});
		}

		poll.add(function() { return reload(false); }, refresh);
		reload(true);

		return root;
	}
});
