/*
 * 历史数据页面：按时间范围 / 目标 / 区域查看聚合统计与曲线
 * TDesign Web Components 重构版本
 * 筛选工具栏 / 统计卡 / 表格面板 / 曲线卡片由 <t-*> 组件承载，
 * 统计明细表保留 .nm-table 平面结构，折线走势图沿用自研 SVG 图表。
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

		/* 原生下拉工厂：替代 t-select（TDesign 下拉在受控模式下无法打开，
		 * 见 settings.js 同类改造说明）。样式沿用 .nm-select。 */
		function makeSelect(options, value) {
			var sel = document.createElement('select');
			sel.className = 'nm-select';
			options.forEach(function(o) {
				var opt = document.createElement('option');
				opt.value = o.value;
				opt.textContent = o.label;
				sel.appendChild(opt);
			});
			sel.value = value;
			return sel;
		}

		/* 工具栏（TDesign 视觉卡） */
		var bar = common.tcard();
		var row = common.el('div', 'nm-toolbar-row');

		/* 时间范围 */
		var fRange = common.el('div', 'nm-field-glass');
		var selRange = makeSelect(RANGES.map(function(r) {
			return { label: _(r[1]), value: r[0] };
		}), '6h');
		fRange.appendChild(common.el('label', '', _('Time range')));
		fRange.appendChild(selRange);
		row.appendChild(fRange);

		/* 区域 */
		var fRegion = common.el('div', 'nm-field-glass');
		var selRegion = makeSelect([
			{ label: _('All regions'), value: 'all' },
			{ label: _('China'), value: 'cn' },
			{ label: _('Overseas'), value: 'overseas' },
			{ label: _('Other'), value: 'other' }
		], 'all');
		fRegion.appendChild(common.el('label', '', _('Region')));
		fRegion.appendChild(selRegion);
		row.appendChild(fRegion);

		/* 目标 */
		var fTarget = common.el('div', 'nm-field-glass');
		var targetOptions = [{ label: _('All targets'), value: 'all' }];
		targets.forEach(function(t) {
			targetOptions.push({ label: t.name || t.id, value: t.id });
		});
		var selTarget = makeSelect(targetOptions, 'all');
		fTarget.appendChild(common.el('label', '', _('Target')));
		fTarget.appendChild(selTarget);
		row.appendChild(fTarget);

		var spacer = common.el('div', 'nm-spacer');
		spacer.style.flex = '1';
		row.appendChild(spacer);

		/* 查询按钮 */
		var qIcon = '<svg width="15" height="15" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true">' +
			'<path d="M11.742 10.344a6.5 6.5 0 1 0-1.397 1.398h-.001c.03.04.062.078.098.115l3.85 3.85a1 1 0 0 0 1.415-1.414l-3.85-3.85a1.007 1.007 0 0 0-.115-.1zM12 6.5a5.5 5.5 0 1 1-11 0 5.5 5.5 0 0 1 11 0z"/></svg>';
		var btnQuery = common.ui.button({
			label: _('Query'),
			theme: 'primary',
			icon: qIcon
		});
		row.appendChild(btnQuery);
		bar.appendChild(row);

		if (cfg.persistence !== '1') {
			/* 持久化关闭时，超出内存缓冲区的区间必然无数据，提前告知，
			 * 否则用户会以为图表坏了。 */
			bar.appendChild(common.ui.alert({
				kind: 'warning',
				icon: '<svg width="14" height="14" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true">' +
					'<path d="M8 1a7 7 0 1 0 0 14A7 7 0 0 0 8 1zm0 3a.9.9 0 0 1 .9.9v4.2a.9.9 0 0 1-1.8 0V4.9A.9.9 0 0 1 8 4zm0 8.2a1 1 0 1 1 0-2 1 1 0 0 1 0 2z"/></svg>',
				text: _('History persistence is disabled. Ranges longer than the in-memory buffer may have no data.')
			}));
		}
		page.appendChild(bar);

		/* 查询结果概览条 */
		var strip = common.el('div', 'nm-strip-grid');
		page.appendChild(strip);

		/* 统计详情卡片（TDesign 视觉卡 + 平面表格） */
		var statCard = common.tcard('nm-table-panel');
		var statTitle = common.el('div', 'nm-panel-title-row');
		statTitle.appendChild(common.inlineIcon(icons.database(30)));
		statTitle.appendChild(common.el('div', 'nm-panel-title', _('Statistics')));
		statCard.appendChild(statTitle);

		var statWrap = common.el('div', 'nm-table-wrap');
		var statTable = common.el('table', 'nm-table');
		var statHead = common.el('thead', '');
		var statBody = common.el('tbody', '');
		var htr = common.el('tr', '');
		[_('Target'), _('Region'), _('Samples'), _('Average'), _('Min'), _('Max'), _('P50'), _('P95'), _('Loss'), _('Availability')]
			.forEach(function(h) {
				var th = common.el('th', '', h);
				th.setAttribute('scope', 'col');
				htr.appendChild(th);
			});
		statHead.appendChild(htr);
		statTable.appendChild(statHead);
		statTable.appendChild(statBody);
		statWrap.appendChild(statTable);
		statCard.appendChild(statWrap);
		page.appendChild(statCard);

		/* 延迟曲线图卡片（TDesign 视觉卡） */
		var chartCard = common.tcard();
		var chartTitle = common.el('div', 'nm-panel-title-row');
		chartTitle.appendChild(common.inlineIcon(icons.trend(30)));
		chartTitle.appendChild(common.el('div', 'nm-panel-title', _('Latency trend')));
		chartCard.appendChild(chartTitle);

		var chartBox = common.el('div', 'nm-chart-box nm-chart-box-glass');
		chartCard.appendChild(chartBox);
		var legend = common.el('div', 'nm-chart-legend');
		chartCard.appendChild(legend);
		page.appendChild(chartCard);

		function query() {
			var range = selRange.value;
			var region = selRegion.value;
			var target = selTarget.value;

			btnQuery.setAttribute('disabled', '');
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
				btnQuery.removeAttribute('disabled');
			});
		}

		/* 指标速览小卡（外层 .nm-tcard） */
		function makeStripCard(title, val, subText, svgIcon, valCls) {
			var card = common.tcard();
			var inner = common.el('div', 'nm-card-inner');

			var head = common.el('div', 'nm-card-header');
			head.appendChild(common.el('span', 'nm-card-label', title));

			if (svgIcon) {
				var icoBox = common.el('div', 'nm-card-icon-box');
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

		/* 区域胶囊标签 */
		function regionTag(region) {
			return common.ui.chip({
				text: common.regionText(region),
				kind: (region === 'cn') ? 'info' : ((region === 'overseas') ? 'warn' : 'idle')
			});
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

			strip.appendChild(makeStripCard(
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
			strip.appendChild(makeStripCard(
				_('Average latency'),
				common.fmt.latency(avg) + ' ms',
				_('Average'),
				icons.latencyDial(avg, curGrade, 46),
				common.gradeClass(curGrade)
			));

			strip.appendChild(makeStripCard(
				_('Packet loss'),
				common.fmt.percent(loss),
				_('Weighted by samples'),
				icons.lossRing(loss, 46),
				(loss > 5) ? 'nm-c-bad' : (loss > 0 ? 'nm-c-warn' : 'nm-c-ok')
			));

			strip.appendChild(makeStripCard(
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
				tr0.appendChild(td0);
				statBody.appendChild(tr0);
				return;
			}
			for (var i = 0; i < rows.length; i++) {
				var t = rows[i];
				var tr = common.el('tr', '');
				tr.appendChild(common.el('td', 'nm-target-name', t.name || t.id));

				var tdR = common.el('td', '');
				tdR.appendChild(regionTag(t.region));
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
