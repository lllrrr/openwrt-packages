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

		/* 等级判定：统一走 common.gradeForLatency()，与后端
		 * luci.netmonitor 的 gradeOf() 同口径，阈值取自 UCI（getConfig）。
		 * 本页此前自带一份 `ms <= 阈值` 的实现，与后端差一个等号。 */
		function gradeOf(ms) {
			return common.gradeForLatency(ms, cfg);
		}

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

		/* 时间范围 */
		var fRange = common.el('div', 'nm-field-glass');
		var selRange = makeSelect(RANGES.map(function(r) {
			return { label: _(r[1]), value: r[0] };
		}), '6h');
		/* 标签与下拉显式关联：点击标签即聚焦控件 */
		fRange.appendChild(common.ui.bindLabel(_('Time range'), selRange));
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
		fRegion.appendChild(common.ui.bindLabel(_('Region'), selRegion));
		fRegion.appendChild(selRegion);
		row.appendChild(fRegion);

		/* 目标 */
		var fTarget = common.el('div', 'nm-field-glass');
		var targetOptions = [{ label: _('All targets'), value: 'all' }];
		targets.forEach(function(t) {
			targetOptions.push({ label: t.name || t.id, value: t.id });
		});
		var selTarget = makeSelect(targetOptions, 'all');
		fTarget.appendChild(common.ui.bindLabel(_('Target'), selTarget));
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

		/* 请求序号。
		 *
		 * 【本次修复】三个筛选下拉都直接绑定 query()，连续切换（或连点查询）
		 * 会并发发出多个请求，而响应到达顺序不保证与发出顺序一致：先发的慢
		 * 请求可能最后才返回，把界面覆盖回旧筛选条件的结果——表现为
		 * 「选了 24h，曲线却停在 15m 的数据上」，且不会再自动纠正。
		 *
		 * 加序号后，只有最新一次请求的响应会落到界面上；按钮也只在最新请求
		 * 结束后才解禁，否则先返回的旧请求会提前点亮按钮，让用户在请求仍在
		 * 途时再次点击。 */
		var querySeq = 0;

		function query() {
			var seq = ++querySeq;
			var range = selRange.value;
			var region = selRegion.value;
			var target = selTarget.value;

			btnQuery.setAttribute('disabled', '');
			return Promise.all([
				common.api.getStatistics({ range: range, region: region, target: target }),
				common.api.getHistory({ range: range, region: region, target: target, max_points: 600 })
			]).then(function(r) {
				if (seq !== querySeq) return;
				renderStats(r[0]);
				renderChart(r[1]);
			}).catch(function(e) {
				if (seq !== querySeq) return;
				common.notify(String(e.message || e), 'error');
			}).then(function() {
				if (seq !== querySeq) return;
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

		/* 区域胶囊标签：统一走 common.regionTag()（widgets.regionTag 的唯一实现），
		 * 本页此前自带一份 common.ui.chip({ kind: info|warn|idle }) 的拼装，
		 * 与目标卡片的 .nm-tag-* 是两套配色、两种形态。 */
		function regionTag(region, label) {
			return common.regionTag(region, label);
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
						/* 阈值配色按 UCI 的 loss_warn / loss_critical 判定，
						 * 不再硬编码 99 / 95 —— 详见 format.js 的 rateGradeName()。 */
						grade: (r.samples > 0)
							? common.rateGradeName(r.success_rate, cfg)
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
				icons.lossRing(loss, 46, cfg),
				/* 阈值配色按 UCI 的 loss_warn / loss_critical 判定，
				 * 不再硬编码 5 —— 详见 format.js 的 lossGrade()。 */
				'nm-c-' + common.lossGrade(loss, cfg)
			));

			strip.appendChild(makeStripCard(
				_('Success rate'),
				common.fmt.percent(rate, 1),
				_('Samples') + ': ' + den,
				icons.successRing(rate, 46, cfg),
				'nm-c-' + common.rateGrade(rate, cfg)
			));
		}

		function renderStats(st) {
			common.clear(statBody);
			var rows = st.targets || [];
			renderStrip(rows);
			if (!rows.length) {
				var tr0 = common.el('tr', '');
				tr0.appendChild(common.emptyState(_('No data in this range'),
					{ tag: 'td', size: 'sm', colspan: 10 }));
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
					color: chart.palette[i % chart.palette.length],
					points: hi.series[i].points
				});
			}
			if (!series.length) {
				chartBox.appendChild(common.emptyState(_('No data in this range'), { size: 'lg' }));
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
