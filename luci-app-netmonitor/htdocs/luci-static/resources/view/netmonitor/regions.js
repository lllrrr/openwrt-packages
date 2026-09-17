/*
 * 国内 / 国外页面：分区指标对比 + 区域平均延迟曲线
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
		selRange.value = range;
		selRange.addEventListener('change', function() { range = selRange.value; reload(true); });
		fRange.appendChild(common.el('label', '', _('Time range')));
		fRange.appendChild(selRange);
		row.appendChild(fRange);
		bar.appendChild(row);
		page.appendChild(bar);

		var grid = common.el('div', 'nm-grid');
		page.appendChild(grid);

		var compare = common.el('div', 'nm-card');
		var cmpTitle = common.el('div', 'nm-row');
		cmpTitle.appendChild(common.inlineIcon(icons.trend(36)));
		cmpTitle.appendChild(common.el('div', 'nm-card-title', _('Region latency comparison')));
		compare.appendChild(cmpTitle);
		var compareBox = common.el('div', 'nm-chart-box');
		compare.appendChild(compareBox);
		var compareLegend = common.el('div', 'nm-chart-legend');
		compare.appendChild(compareLegend);
		page.appendChild(compare);

		var lists = common.el('div', 'nm-grid-wide');
		page.appendChild(lists);

		function regionCard(title, x, icon) {
			var c = common.el('div', 'nm-card nm-card-hi');
			var head = common.el('div', 'nm-row');
			head.appendChild(common.el('div', 'nm-card-title', title));
			head.appendChild(common.el('div', 'nm-spacer'));
			head.appendChild(common.el('span', 'nm-tag', (x.total || 0) + ' ' + _('Target count')));
			c.appendChild(head);

			/* 区域图标与区域真实延迟并排：图标中的节点颜色由 abnormal 决定，
			 * 因此「图标本身就是该区域的健康度」 */
			var body = common.el('div', 'nm-icon-card');
			body.appendChild(common.svgBox(icon, 'nm-icon-card-svg'));
			var right = common.el('div', 'nm-icon-card-body');
			right.appendChild(common.el('div', 'nm-card-value ' + ((x.abnormal > 0) ? 'nm-c-warn' : 'nm-c-ok'),
				common.fmt.latency(x.avg) + ' ms'));
			right.appendChild(common.el('div', 'nm-card-sub', _('Average latency')));
			body.appendChild(right);
			c.appendChild(body);

			var m = common.el('div', 'nm-target-metrics');
			m.style.marginTop = '10px';
			function mm(label, value) {
				var d = common.el('div', 'nm-metric');
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

			var rings = common.el('div', 'nm-target-rings');
			function ring(svg, label, value, cls) {
				var box = common.el('div', 'nm-ring-item');
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
			var box = common.el('div', 'nm-card');
			box.appendChild(common.el('div', 'nm-card-title',
				(region === 'cn' ? _('China network') : (region === 'overseas' ? _('Overseas network') : _('Other')))));
			var wrap = common.el('div', 'nm-table-wrap');
			var tb = common.el('table', 'nm-table');
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
				tr0.appendChild(td0);
				tbody.appendChild(tr0);
			}
			for (var i = 0; i < list.length; i++) {
				var t = list[i];
				var r = common.el('tr', '');
				r.appendChild(common.el('td', '', t.name || t.id));
				r.appendChild(common.el('td', 'nm-num ' + common.gradeClass(t.grade), common.fmt.latency(t.latency)));
				r.appendChild(common.el('td', 'nm-num', common.fmt.latency(t.avg)));
				r.appendChild(common.el('td', 'nm-num', common.fmt.latency(t.p95)));
				r.appendChild(common.el('td', 'nm-num', common.fmt.percent(t.loss)));
				r.appendChild(common.el('td', 'nm-num', common.fmt.percent(t.success_rate, 0)));
				tbody.appendChild(r);
			}
			return box;
		}

		/* 按区域把多个目标的点合并为一条平均曲线 */
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
			if (cn.length) series.push({ name: _('China'), color: '#2f6fed', points: cn });
			if (ov.length) series.push({ name: _('Overseas'), color: '#8a63d2', points: ov });
			if (!series.length) {
				compareBox.appendChild(common.el('div', 'nm-empty', _('No data in this range')));
				return;
			}
			chart.mount(compareBox, series, { height: 240 });
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
			grid.appendChild(regionCard(_('China network'), r.cn || {}, icons.regionCN(84, r.cn || {})));
			grid.appendChild(regionCard(_('Overseas network'), r.overseas || {}, icons.regionGlobal(84, r.overseas || {})));

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
				compareBox.appendChild(common.el('div', 'nm-empty', String(e.message || e)));
			});
		}

		poll.add(function() { return reload(false); }, refresh);
		reload(true);

		return root;
	}
});
