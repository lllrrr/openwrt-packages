/*
 * 延迟曲线页面：多目标对比折线图（自研 SVG 图表，支持鼠标悬停与触摸查看）
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

		var root = common.el('div', 'nm-root');
		var page = common.el('div', 'nm-page');
		root.appendChild(page);

		/* 工具栏 */
		var bar = common.el('div', 'nm-card');
		var row = common.el('div', 'nm-row');

		var fRange = common.el('div', 'nm-field');
		var selRange = common.el('select', 'nm-select');
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

		var fPreset = common.el('div', 'nm-field');
		var selPreset = common.el('select', 'nm-select');
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

		row.appendChild(common.el('div', 'nm-spacer'));
		bar.appendChild(row);

		var chips = common.el('div', 'nm-row');
		chips.style.marginTop = '10px';
		bar.appendChild(chips);
		page.appendChild(bar);

		/* 图表 */
		var card = common.el('div', 'nm-card');
		summary = common.el('div', 'nm-row');
		card.appendChild(summary);

		chartBox = common.el('div', 'nm-chart-box');
		chartBox.style.marginTop = '10px';
		card.appendChild(chartBox);

		legend = common.el('div', 'nm-chart-legend');
		card.appendChild(legend);

		hint = common.el('div', 'nm-card-sub');
		hint.style.marginTop = '6px';
		card.appendChild(hint);

		page.appendChild(card);

		/* 与后端一致的等级判定（阈值取自 getConfig），保证图标颜色与后端 grade 对齐 */
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

		function renderChips() {
			common.clear(chips);
			if (!data || !data.series.length) return;
			for (var i = 0; i < data.series.length; i++) {
				(function(s, idx) {
					var on = !!selected[s.id];
					var b = common.el('button', 'nm-btn nm-btn-sm' + (on ? ' nm-btn-primary' : ''),
						(on ? '● ' : '○ ') + (s.name || s.id));
					b.style.borderColor = on ? '' : common.palette[idx % common.palette.length];
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

		function drawChart() {
			common.clear(chartBox);
			common.clear(legend);
			common.clear(summary);
			if (!data) return;

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
				chartBox.appendChild(common.el('div', 'nm-empty', _('No target selected')));
				return;
			}

			chart.mount(chartBox, series, { height: 260, area: (series.length === 1) });

			for (var k = 0; k < series.length; k++) {
				var item = common.el('span', '');
				var i2 = common.el('i', '');
				i2.style.background = series[k].color;
				item.appendChild(i2);
				item.appendChild(document.createTextNode(series[k].name));
				legend.appendChild(item);
			}

			function sumBox(label, value, cls, svg) {
				var b = common.el('div', 'nm-card');
				b.style.flex = '1 1 150px';
				b.appendChild(common.el('div', 'nm-card-title', label));
				b.appendChild(common.el('div', 'nm-card-value ' + (cls || ''), value));
				if (svg) common.cardIcon(b, svg);
				return b;
			}
			var avgCur = cur.length ? (cur.reduce(function(a, b) { return a + b; }, 0) / cur.length) : null;
			var maxV = mx.length ? Math.max.apply(null, mx) : null;
			var minV = mn.length ? Math.min.apply(null, mn) : null;
			var rangeLabel = _(RANGES.filter(function(r) { return r[0] === range; })[0][1]);

			summary.appendChild(sumBox(_('Current'), common.fmt.latency(avgCur) + ' ms',
				common.gradeClass(gradeOf(avgCur)), icons.latencyDial(avgCur, gradeOf(avgCur), 50)));
			summary.appendChild(sumBox(_('Max'), common.fmt.latency(maxV) + ' ms',
				common.gradeClass(gradeOf(maxV)), icons.highLatency(maxV, gradeOf(maxV), 50)));
			summary.appendChild(sumBox(_('Min'), common.fmt.latency(minV) + ' ms',
				common.gradeClass(gradeOf(minV)), icons.gradeGauge(minV, gradeOf(minV), 50)));
			summary.appendChild(sumBox(_('Range'), rangeLabel, '', icons.database(50)));

			/* 柱状高度取各已选目标的当前延迟，柱数与已选目标数一致 */
			var plot = [];
			for (var q = 0; q < cur.length && q < 4; q++) plot.push(cur[q]);
			summary.appendChild(common.iconCard(_('Live sampling'),
				String(series.length) + ' / ' + String(data.series.length),
				_('Selected targets'), icons.liveBars(plot, 56)));

			hint.textContent = (data.source === 'persistent')
				? _('Data source: persistent history on flash')
				: _('Data source: in-memory ring buffer');
		}

		function reload() {
			return common.api.getHistory({ range: range, max_points: 600 }).then(function(d) {
				data = d;
				if (selectAll) {
					selected = {};
					for (var i = 0; i < data.series.length; i++)
						selected[data.series[i].id] = true;
				}
				renderChips();
				drawChart();
			}).catch(function(e) {
				common.clear(chartBox);
				chartBox.appendChild(common.el('div', 'nm-empty', String(e.message || e)));
			});
		}

		poll.add(reload, refresh);
		reload();

		return root;
	}
});
