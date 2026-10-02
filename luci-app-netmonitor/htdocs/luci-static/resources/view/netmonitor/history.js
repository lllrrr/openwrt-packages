/*
 * 历史数据页面：按时间范围 / 目标 / 区域查看聚合统计与曲线
 * 白色毛玻璃质感 + 高级动态 SVG 动效重构版本
 * 针对历史聚合统计表、多维筛选工具栏与折线走势图进行排版与动效升级。
 */

'use strict';
'require view';
'require netmonitor.common as common';
'require netmonitor.chart as chart';
'require netmonitor.icons as icons';

var RANGES = [
	['15m', '15 min'], ['30m', '30 min'], ['1h', '1 hour'], ['6h', '6 hours'],
	['12h', '12 hours'], ['24h', '24 hours'], ['3d', '3 days'], ['7d', '7 days'], ['30d', '30 days']
];

return view.extend({
	load: function() {
		common.css();
		return Promise.all([
			common.loadI18n(),
			common.api.getConfig(),
			common.api.getTargets()
		]);
	},

	render: function(res) {
		common.css();

		var cfg = (res && res[1]) || {};
		var targets = ((res && res[2]) || {}).targets || [];

		// 注入系统级白色毛玻璃、排版体系与动态 SVG 微动效
		(function injectHistoryStyles() {
			if (document.getElementById('nm-history-glass-theme')) return;
			var style = document.createElement('style');
			style.id = 'nm-history-glass-theme';
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

				.nm-glass-card:hover {
					box-shadow: var(--nm-glass-shadow-hover);
				}

				/* 顶部多维查询栏 */
				.nm-toolbar-glass {
					padding: 18px 26px;
					display: flex;
					flex-direction: column;
					gap: 12px;
				}

				.nm-toolbar-row {
					display: flex;
					align-items: center;
					flex-wrap: wrap;
					gap: 16px;
					width: 100%;
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
					background: rgba(255, 255, 255, 0.75);
					backdrop-filter: blur(10px);
					-webkit-backdrop-filter: blur(10px);
					border: 1px solid rgba(203, 213, 225, 0.8);
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

				.nm-btn-primary-glass {
					background: linear-gradient(135deg, #3b82f6 0%, #1d4ed8 100%);
					color: #ffffff !important;
					border: 1px solid rgba(255, 255, 255, 0.25);
					border-radius: 12px;
					padding: 8px 22px;
					font-size: 0.88rem;
					font-weight: 700;
					box-shadow: 0 4px 14px rgba(37, 99, 235, 0.28);
					cursor: pointer;
					display: inline-flex;
					align-items: center;
					gap: 8px;
					transition: all 0.2s cubic-bezier(0.4, 0, 0.2, 1);
				}

				.nm-btn-primary-glass:hover:not(:disabled) {
					background: linear-gradient(135deg, #60a5fa 0%, #2563eb 100%);
					transform: translateY(-1.5px);
					box-shadow: 0 6px 20px rgba(37, 99, 235, 0.38);
				}

				.nm-btn-primary-glass:disabled {
					opacity: 0.55;
					cursor: not-allowed;
				}

				.nm-warn-pill {
					display: inline-flex;
					align-items: center;
					gap: 6px;
					font-size: 0.8rem;
					color: #b45309;
					background: rgba(254, 243, 199, 0.85);
					border: 1px solid rgba(253, 230, 138, 0.9);
					padding: 4px 12px;
					border-radius: 8px;
					width: fit-content;
				}

				/* 统计指标卡片网格 */
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

				/* 统计大表格卡片 */
				.nm-table-panel {
					padding: 24px 26px;
					display: flex;
					flex-direction: column;
					gap: 16px;
				}

				.nm-panel-title-row {
					display: flex;
					align-items: center;
					gap: 10px;
				}

				.nm-panel-title {
					font-size: 1.15rem;
					font-weight: 750;
					color: var(--nm-txt-title);
					letter-spacing: -0.02em;
				}

				.nm-table-glass-wrap {
					background: rgba(255, 255, 255, 0.55);
					border-radius: 18px;
					border: 1px solid rgba(255, 255, 255, 0.85);
					box-shadow: inset 0 1px 4px rgba(0, 0, 0, 0.02);
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
					background: rgba(248, 250, 252, 0.9);
					padding: 14px 16px;
					font-weight: 700;
					font-size: 0.8rem;
					color: var(--nm-txt-sub);
					text-transform: uppercase;
					letter-spacing: 0.04em;
					border-bottom: 1px solid rgba(226, 232, 240, 0.85);
					white-space: nowrap;
					position: sticky;
					top: 0;
					z-index: 2;
				}

				.nm-table-glass tbody td {
					padding: 12px 16px;
					border-bottom: 1px solid rgba(241, 245, 249, 0.85);
					color: var(--nm-txt-body);
					vertical-align: middle;
					white-space: nowrap;
				}

				.nm-table-glass tbody tr:last-child td {
					border-bottom: none;
				}

				.nm-table-glass tbody tr:hover {
					background: rgba(241, 245, 249, 0.65);
				}

				.nm-target-name {
					font-weight: 700;
					color: var(--nm-txt-title);
				}

				.nm-num {
					font-variant-numeric: tabular-nums;
					font-weight: 650;
				}

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

				/* 折线走势卡片 */
				.nm-chart-panel {
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
					font-size: 0.82rem;
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

		/* 与后端一致的等级判定，阈值取自 UCI（getConfig） */
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

		var root = common.el('div', 'nm-root');
		var page = common.el('div', 'nm-page');
		root.appendChild(page);

		/* 工具栏 */
		var bar = common.el('div', 'nm-glass-card nm-toolbar-glass');
		var row = common.el('div', 'nm-toolbar-row');

		var fRange = common.el('div', 'nm-field-glass');
		var selRange = common.el('select', 'nm-select-glass');
		RANGES.forEach(function(r) {
			var op = common.el('option', '', _(r[1]));
			op.value = r[0];
			selRange.appendChild(op);
		});
		selRange.value = '6h';
		fRange.appendChild(common.el('label', '', _('Time range')));
		fRange.appendChild(selRange);
		row.appendChild(fRange);

		var fRegion = common.el('div', 'nm-field-glass');
		var selRegion = common.el('select', 'nm-select-glass');
		[['all', _('All regions')], ['cn', _('China')], ['overseas', _('Overseas')], ['other', _('Other')]].forEach(function(o) {
			var op = common.el('option', '', o[1]);
			op.value = o[0];
			selRegion.appendChild(op);
		});
		fRegion.appendChild(common.el('label', '', _('Region')));
		fRegion.appendChild(selRegion);
		row.appendChild(fRegion);

		var fTarget = common.el('div', 'nm-field-glass');
		var selTarget = common.el('select', 'nm-select-glass');
		var opAll = common.el('option', '', _('All targets'));
		opAll.value = 'all';
		selTarget.appendChild(opAll);
		targets.forEach(function(t) {
			var op = common.el('option', '', t.name || t.id);
			op.value = t.id;
			selTarget.appendChild(op);
		});
		fTarget.appendChild(common.el('label', '', _('Target')));
		fTarget.appendChild(selTarget);
		row.appendChild(fTarget);

		var spacer = common.el('div', 'nm-spacer');
		spacer.style.flex = '1';
		row.appendChild(spacer);

		var btnQuery = common.el('button', 'nm-btn-primary-glass');
		btnQuery.innerHTML = `
			<svg width="15" height="15" viewBox="0 0 16 16" fill="currentColor"><path d="M11.742 10.344a6.5 6.5 0 1 0-1.397 1.398h-.001c.03.04.062.078.098.115l3.85 3.85a1 1 0 0 0 1.415-1.414l-3.85-3.85a1.007 1.007 0 0 0-.115-.1zM12 6.5a5.5 5.5 0 1 1-11 0 5.5 5.5 0 0 1 11 0z"/></svg>
			<span>${_('Query')}</span>
		`;
		row.appendChild(btnQuery);
		bar.appendChild(row);

		if (cfg.persistence !== '1') {
			var note = common.el('div', 'nm-warn-pill');
			note.innerHTML = `
				<svg width="14" height="14" viewBox="0 0 16 16" fill="currentColor"><path d="M8 1a7 7 0 1 0 0 14A7 7 0 0 0 8 1zm0 3a.9.9 0 0 1 .9.9v4.2a.9.9 0 0 1-1.8 0V4.9A.9.9 0 0 1 8 4zm0 8.2a1 1 0 1 1 0-2 1 1 0 0 1 0 2z"/></svg>
				<span>${_('History persistence is disabled. Ranges longer than the in-memory buffer may have no data.')}</span>
			`;
			bar.appendChild(note);
		}
		page.appendChild(bar);

		/* 查询结果概览条 */
		var strip = common.el('div', 'nm-strip-grid');
		page.appendChild(strip);

		/* 统计详情卡片 */
		var statCard = common.el('div', 'nm-glass-card nm-table-panel');
		var statTitle = common.el('div', 'nm-panel-title-row');
		statTitle.appendChild(common.inlineIcon(icons.database(30)));
		statTitle.appendChild(common.el('div', 'nm-panel-title', _('Statistics')));
		statCard.appendChild(statTitle);

		var statWrap = common.el('div', 'nm-table-glass-wrap');
		var statTable = common.el('table', 'nm-table-glass');
		var statHead = common.el('thead', '');
		var statBody = common.el('tbody', '');
		var htr = common.el('tr', '');
		[_('Target'), _('Region'), _('Samples'), _('Average'), _('Min'), _('Max'), _('P50'), _('P95'), _('Loss'), _('Availability')]
			.forEach(function(h) { htr.appendChild(common.el('th', '', h)); });
		statHead.appendChild(htr);
		statTable.appendChild(statHead);
		statTable.appendChild(statBody);
		statWrap.appendChild(statTable);
		statCard.appendChild(statWrap);
		page.appendChild(statCard);

		/* 延迟曲线图卡片 */
		var chartCard = common.el('div', 'nm-glass-card nm-chart-panel');
		var chartTitle = common.el('div', 'nm-panel-title-row');
		chartTitle.appendChild(common.inlineIcon(icons.trend(30)));
		chartTitle.appendChild(common.el('div', 'nm-panel-title', _('Latency trend')));
		chartCard.appendChild(chartTitle);

		var chartBox = common.el('div', 'nm-chart-box nm-chart-box-glass');
		chartCard.appendChild(chartBox);
		var legend = common.el('div', 'nm-chart-legend nm-chart-legend-glass');
		chartCard.appendChild(legend);
		page.appendChild(chartCard);

		function query() {
			var range = selRange.value;
			var region = selRegion.value;
			var target = selTarget.value;

			btnQuery.disabled = true;
			return Promise.all([
				common.api.getStatistics({ range: range, region: region, target: target }),
				common.api.getHistory({ range: range, region: region, target: target, max_points: 600 })
			]).then(function(r) {
				var st = r[0];
				var hi = r[1];
				renderStats(st);
				renderChart(hi);
			}).catch(function(e) {
				common.notify(String(e.message || e), 'error');
			}).then(function() {
				btnQuery.disabled = false;
			});
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

		function renderStrip(rows) {
			common.clear(strip);
			var den = 0, accSucc = 0, accLoss = 0, accAvg = 0, avgN = 0;
			for (var i = 0; i < rows.length; i++) {
				var s = rows[i].samples || 0;
				den += s;
				accSucc += (rows[i].success_rate || 0) * s;
				accLoss += (rows[i].loss || 0) * s;
				if (rows[i].avg != null) { accAvg += rows[i].avg; avgN++; }
			}
			var rate = (den > 0) ? (accSucc / den) : null;
			var loss = (den > 0) ? (accLoss / den) : null;
			var avg = (avgN > 0) ? (accAvg / avgN) : null;

			strip.appendChild(makeGlassStripCard(
				_('Target count'),
				String(rows.length),
				_('Samples') + ': ' + den,
				icons.multiTarget(rows.map(function(r) {
					return {
						name: r.name || r.id,
						latency: r.avg,
						grade: (r.samples > 0)
							? (r.success_rate >= 99 ? 'good' : (r.success_rate >= 95 ? 'fair' : 'down'))
							: 'unknown'
					};
				}), 46)
			));

			var curGrade = gradeOf(avg);
			strip.appendChild(makeGlassStripCard(
				_('Average latency'),
				common.fmt.latency(avg) + ' ms',
				_('Average'),
				icons.latencyDial(avg, curGrade, 46),
				common.gradeClass(curGrade)
			));

			strip.appendChild(makeGlassStripCard(
				_('Packet loss'),
				common.fmt.percent(loss),
				_('Weighted by samples'),
				icons.lossRing(loss, 46),
				(loss > 5) ? 'nm-c-bad' : (loss > 0 ? 'nm-c-warn' : 'nm-c-ok')
			));

			strip.appendChild(makeGlassStripCard(
				_('Success rate'),
				common.fmt.percent(rate, 1),
				_('Samples') + ': ' + den,
				icons.successRing(rate, 46),
				rate == null ? '' : (rate >= 99 ? 'nm-c-ok' : (rate >= 95 ? 'nm-c-warn' : 'nm-c-bad'))
			));
		}

		function renderStats(st) {
			common.clear(statBody);
			var rows = st.targets || [];
			renderStrip(rows);
			if (!rows.length) {
				var tr0 = common.el('tr', '');
				var td0 = common.el('td', 'nm-empty', _('No data in this range'));
				td0.colSpan = 10;
				td0.style.padding = '36px';
				td0.style.textAlign = 'center';
				td0.style.color = 'var(--nm-txt-sub)';
				tr0.appendChild(td0);
				statBody.appendChild(tr0);
				return;
			}
			for (var i = 0; i < rows.length; i++) {
				var t = rows[i];
				var tr = common.el('tr', '');
				tr.appendChild(common.el('td', 'nm-target-name', t.name || t.id));

				var tdR = common.el('td', '');
				var regCls = (t.region === 'cn') ? 'cn' : ((t.region === 'overseas') ? 'overseas' : '');
				tdR.appendChild(common.el('span', 'nm-tag-pill ' + regCls, common.regionText(t.region)));
				tr.appendChild(tdR);

				tr.appendChild(common.el('td', 'nm-num', String(t.samples || 0)));
				tr.appendChild(common.el('td', 'nm-num', common.fmt.latency(t.avg)));
				tr.appendChild(common.el('td', 'nm-num', common.fmt.latency(t.min)));
				tr.appendChild(common.el('td', 'nm-num', common.fmt.latency(t.max)));
				tr.appendChild(common.el('td', 'nm-num', common.fmt.latency(t.p50)));
				tr.appendChild(common.el('td', 'nm-num', common.fmt.latency(t.p95)));
				tr.appendChild(common.el('td', 'nm-num', common.fmt.percent(t.loss)));
				tr.appendChild(common.el('td', 'nm-num', common.fmt.percent(t.success_rate, 0)));
				statBody.appendChild(tr);
			}
		}

		function renderChart(hi) {
			common.clear(chartBox);
			common.clear(legend);
			var series = [];
			for (var i = 0; i < hi.series.length; i++) {
				if (!hi.series[i].points.length) continue;
				series.push({
					name: hi.series[i].name,
					color: common.palette[i % common.palette.length],
					points: hi.series[i].points
				});
			}
			if (!series.length) {
				var emptyEl = common.el('div', 'nm-empty', _('No data in this range'));
				emptyEl.style.padding = '36px';
				emptyEl.style.textAlign = 'center';
				emptyEl.style.color = 'var(--nm-txt-sub)';
				chartBox.appendChild(emptyEl);
				return;
			}
			chart.mount(chartBox, series, { height: 260, area: (series.length === 1) });
			for (var k = 0; k < series.length; k++) {
				var item = common.el('span', '');
				var ic = common.el('i', '');
				ic.style.background = series[k].color;
				item.appendChild(ic);
				item.appendChild(document.createTextNode(series[k].name));
				legend.appendChild(item);
			}
		}

		btnQuery.addEventListener('click', query);
		selRange.addEventListener('change', query);
		selRegion.addEventListener('change', query);
		selTarget.addEventListener('change', query);

		query();

		return root;
	}
});
