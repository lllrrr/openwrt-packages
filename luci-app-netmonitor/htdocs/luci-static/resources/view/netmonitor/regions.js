/*
 * 国内 / 国外页面：分区指标对比 + 区域平均延迟曲线
 * TDesign Web Components 重构版本
 * 工具栏 / 区域对比卡 / 折线对比卡 / 分区明细表由 <t-*> 组件承载，
 * 动态环形指标与折线对比沿用自研 SVG 与原有逻辑。
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
		return Promise.all([
			common.loadI18n(),
			common.api.getConfig()
		]);
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

		/* 原生下拉工厂：统一取 ui.js 的 selectInput（.nm-ctl 基线）。
		 * 替代 t-select（TDesign 下拉在受控模式下无法打开，
		 * 见 settings.js 同类改造说明）。本页此前的 makeSelect 自建实现已删除，
		 * 这里只保留一个转调别名，避免改动全部调用点。 */
		function makeSelect(options, value) {
			return common.ui.selectInput(options, value);
		}

		/* 工具栏（TDesign 视觉卡） */
		var bar = common.tcard();
		var row = common.el('div', 'nm-toolbar-row');

		var fRange = common.el('div', 'nm-field-glass');
		var selRange = makeSelect(RANGES.map(function(r) {
			return { label: _(r[1]), value: r[0] };
		}), range);
		selRange.addEventListener('change', function() { range = selRange.value; reload(true); });
		/* 标签与下拉显式关联：点击标签即聚焦控件 */
		fRange.appendChild(common.ui.bindLabel(_('Time range'), selRange));
		fRange.appendChild(selRange);
		row.appendChild(fRange);

		var spacer = common.el('div', 'nm-spacer');
		spacer.style.flex = '1';
		row.appendChild(spacer);
		bar.appendChild(row);
		page.appendChild(bar);

		/* 顶部两个区域指标卡片网格 */
		var grid = common.el('div', 'nm-regions-grid');
		page.appendChild(grid);

		/* 区域平均延迟对比折线图（TDesign 视觉卡） */
		var compare = common.tcard('nm-compare-card');
		var cmpTitle = common.el('div', 'nm-panel-title-row');
		cmpTitle.appendChild(common.inlineIcon(icons.trend(32)));
		cmpTitle.appendChild(common.el('div', 'nm-panel-title', _('Region latency comparison')));
		compare.appendChild(cmpTitle);

		var compareBox = common.el('div', 'nm-chart-box nm-chart-box-glass');
		compare.appendChild(compareBox);

		var compareLegend = common.el('div', 'nm-chart-legend');
		compare.appendChild(compareLegend);
		page.appendChild(compare);

		/* 分区明细表格容器 */
		var lists = common.el('div', 'nm-tables-grid');
		page.appendChild(lists);

		function regionCard(title, x, icon, regKey) {
			var c = common.tcard('nm-region-card');

			/* 头部：标题与目标数胶囊 */
			var head = common.el('div', 'nm-region-header');
			head.appendChild(common.el('div', 'nm-region-title', title));
			head.appendChild(common.ui.chip({
				text: (x.total || 0) + ' ' + _('Target count'),
				kind: (regKey === 'cn') ? 'info' : 'warn'
			}));
			c.appendChild(head);

			/* 主视觉展台：SVG 与主读数 */
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

			/* 6 项微型指标网格 */
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

			/* 环形指标胶囊行 */
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
			/* 阈值配色按 UCI 的 loss_warn / loss_critical 判定，
			 * 不再各写一份硬编码的 5 / 99 / 95 —— 详见 format.js。 */
			rings.appendChild(ring(icons.lossRing(x.loss, 44, cfg), _('Loss'), common.fmt.percent(x.loss, 1),
				'nm-c-' + common.lossGrade(x.loss, cfg)));
			rings.appendChild(ring(icons.successRing(x.online_rate, 44, cfg), _('Availability'),
				common.fmt.percent(x.online_rate, 0),
				'nm-c-' + common.rateGrade(x.online_rate, cfg)));
			c.appendChild(rings);

			return c;
		}

		function regionTargets(region) {
			var box = common.tcard('nm-subtable-card');
			var regTitle = (region === 'cn' ? _('China network') : (region === 'overseas' ? _('Overseas network') : _('Other')));
			box.appendChild(common.el('div', 'nm-region-title', regTitle));

			var wrap = common.el('div', 'nm-table-wrap');
			var tb = common.el('table', 'nm-table');
			var thead = common.el('thead', '');
			var tbody = common.el('tbody', '');
			var tr = common.el('tr', '');
			[_('Name'), _('Current'), _('Average'), _('P95'), _('Loss'), _('Availability')].forEach(function(h) {
				var th = common.el('th', '', h);
				/* scope 让读屏逐格导航时播报列名 */
				th.setAttribute('scope', 'col');
				tr.appendChild(th);
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
				tr0.appendChild(common.emptyState(_('No targets'),
					{ tag: 'td', size: 'sm', colspan: 6 }));
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
				compareBox.appendChild(common.emptyState(_('No data in this range'), { size: 'lg' }));
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
				compareBox.appendChild(common.emptyState(String(e.message || e), { kind: 'error', size: 'lg' }));
			});
		}

		/* 轮询自注销。
		 *
		 * 与 overview.js / realtime.js 同理：LuCI 的 SPA 路由切换只替换
		 * view 容器、不清空 poll 队列，页面离开后这一路轮询会继续打 rpcd，
		 * 访问 N 次就是 N 路并发。
		 *
		 * 【本次修复】本页此前注册的是一个**匿名**函数
		 * （poll.add(function(){ return reload(false); }, refresh)），
		 * 不只是「忘了注销」——匿名函数每次 render 都是新的函数对象，
		 * 外部连 poll.remove() 的入参都拿不到，属于结构性地无法注销。
		 * 改为具名函数后按 isConnected 自判注销。
		 *
		 * 首次调用豁免：render() 末尾同步调 reload(true) 拉首屏，
		 * 那时 root 尚未入文档。 */
		var firstRun = true;

		function pollTick() {
			if (firstRun)
				firstRun = false;
			else if (!root.isConnected) {
				poll.remove(pollTick);
				return Promise.resolve();
			}
			return reload(false);
		}

		poll.add(pollTick, refresh);
		reload(true);

		return root;
	}
});
