/*
 * 历史数据页面：按时间范围 / 目标 / 区域查看聚合统计与曲线
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

		var bar = common.el('div', 'nm-card');
		var row = common.el('div', 'nm-row');

		var fRange = common.el('div', 'nm-field');
		var selRange = common.el('select', 'nm-select');
		RANGES.forEach(function(r) {
			var op = common.el('option', '', _(r[1]));
			op.value = r[0];
			selRange.appendChild(op);
		});
		selRange.value = '6h';
		fRange.appendChild(common.el('label', '', _('Time range')));
		fRange.appendChild(selRange);
		row.appendChild(fRange);

		var fRegion = common.el('div', 'nm-field');
		var selRegion = common.el('select', 'nm-select');
		[['all', _('All regions')], ['cn', _('China')], ['overseas', _('Overseas')], ['other', _('Other')]].forEach(function(o) {
			var op = common.el('option', '', o[1]);
			op.value = o[0];
			selRegion.appendChild(op);
		});
		fRegion.appendChild(common.el('label', '', _('Region')));
		fRegion.appendChild(selRegion);
		row.appendChild(fRegion);

		var fTarget = common.el('div', 'nm-field');
		var selTarget = common.el('select', 'nm-select');
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

		row.appendChild(common.el('div', 'nm-spacer'));

		var btnQuery = common.el('button', 'nm-btn nm-btn-primary', _('Query'));
		row.appendChild(btnQuery);
		bar.appendChild(row);

		var note = common.el('div', 'nm-card-sub');
		note.style.marginTop = '8px';
		if (cfg.persistence !== '1')
			note.textContent = _('History persistence is disabled. Ranges longer than the in-memory buffer may have no data.');
		bar.appendChild(note);
		page.appendChild(bar);

		/* 查询结果概览：图标随查询范围实时重算 */
		var strip = common.el('div', 'nm-grid');
		page.appendChild(strip);

		var statCard = common.el('div', 'nm-card');
		var statTitle = common.el('div', 'nm-row');
		statTitle.appendChild(common.inlineIcon(icons.database(34)));
		statTitle.appendChild(common.el('div', 'nm-card-title', _('Statistics')));
		statCard.appendChild(statTitle);
		var statWrap = common.el('div', 'nm-table-wrap');
		var statTable = common.el('table', 'nm-table');
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

		var chartCard = common.el('div', 'nm-card');
		var chartTitle = common.el('div', 'nm-row');
		chartTitle.appendChild(common.inlineIcon(icons.trend(34)));
		chartTitle.appendChild(common.el('div', 'nm-card-title', _('Latency trend')));
		chartCard.appendChild(chartTitle);
		var chartBox = common.el('div', 'nm-chart-box');
		chartCard.appendChild(chartBox);
		var legend = common.el('div', 'nm-chart-legend');
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

		/* 概览条：丢包率与成功率的权重都按样本数加权，
		 * 样本为 0 时不显示百分比，避免用 0% 或 100% 冒充真实数据。 */
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

			strip.appendChild(common.iconCard(_('Target count'), String(rows.length),
				_('Samples') + ': ' + den, icons.multiTarget(rows.map(function(r) {
					/* 统计行没有实时延迟，用区间平均值代替；
					 * 等级由区间成功率推导，与后端 grade 语义一致。 */
					return {
						name: r.name || r.id,
						latency: r.avg,
						grade: (r.samples > 0)
							? (r.success_rate >= 99 ? 'good' : (r.success_rate >= 95 ? 'fair' : 'down'))
							: 'unknown'
					};
				}), 60)));

			strip.appendChild(common.iconCard(_('Average latency'), common.fmt.latency(avg) + ' ms',
				_('Average'), icons.latencyDial(avg, gradeOf(avg), 60), common.gradeClass(gradeOf(avg))));

			strip.appendChild(common.iconCard(_('Packet loss'), common.fmt.percent(loss),
				_('Weighted by samples'), icons.lossRing(loss, 60),
				(loss > 5) ? 'nm-c-bad' : (loss > 0 ? 'nm-c-warn' : 'nm-c-ok')));

			strip.appendChild(common.iconCard(_('Success rate'), common.fmt.percent(rate, 1),
				_('Samples') + ': ' + den, icons.successRing(rate, 60),
				rate == null ? '' : (rate >= 99 ? 'nm-c-ok' : (rate >= 95 ? 'nm-c-warn' : 'nm-c-bad'))));
		}

		function renderStats(st) {
			common.clear(statBody);
			var rows = st.targets || [];
			renderStrip(rows);
			if (!rows.length) {
				var tr0 = common.el('tr', '');
				var td0 = common.el('td', 'nm-empty', _('No data in this range'));
				td0.colSpan = 10;
				tr0.appendChild(td0);
				statBody.appendChild(tr0);
				return;
			}
			for (var i = 0; i < rows.length; i++) {
				var t = rows[i];
				var tr = common.el('tr', '');
				tr.appendChild(common.el('td', '', t.name || t.id));
				var tdR = common.el('td', '');
				tdR.appendChild(common.el('span', common.regionTagClass(t.region), common.regionText(t.region)));
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
				chartBox.appendChild(common.el('div', 'nm-empty', _('No data in this range')));
				return;
			}
			chart.mount(chartBox, series, { height: 250, area: (series.length === 1) });
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
