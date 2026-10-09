/*
 * 延迟曲线页面：多目标对比折线图（自研 SVG 图表，支持鼠标悬停与触摸查看）
 * TDesign Web Components 重构版本
 * 工具栏 / 目标胶囊选择器 / 统计摘要卡 / 图表容器由 <t-*> 组件承载，
 * 折线交互与动态 SVG 采样动效保留原有实现。
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
		return Promise.all([
			common.loadI18n(),
			common.api.getConfig()
		]);
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
		var bar = common.tcard('nm-chart-toolbar');
		var row = common.el('div', 'nm-toolbar-row');

		/* 时间范围 */
		var fRange = common.el('div', 'nm-field-glass');
		var selRange = makeSelect(RANGES.map(function(r) {
			return { label: _(r[1]), value: r[0] };
		}), range);
		selRange.addEventListener('change', function() {
			range = selRange.value;
			reload();
		});
		fRange.appendChild(common.el('label', '', _('Time range')));
		fRange.appendChild(selRange);
		row.appendChild(fRange);

		/* 快捷筛选 */
		var fPreset = common.el('div', 'nm-field-glass');
		var selPreset = makeSelect([
			{ label: _('All targets'), value: 'all' },
			{ label: _('China'), value: 'cn' },
			{ label: _('Overseas'), value: 'overseas' },
			{ label: _('Other'), value: 'other' }
		], 'all');
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

		/* 目标多选胶囊（原生 button，可点击切换） */
		var chips = common.el('div', 'nm-chips-container');
		bar.appendChild(chips);
		page.appendChild(bar);

		/* 图表主卡片（TDesign 视觉卡） */
		var card = common.tcard('nm-chart-main-card');

		summary = common.el('div', 'nm-chart-summary-grid');
		card.appendChild(summary);

		chartBox = common.el('div', 'nm-chart-box nm-chart-box-glass');
		card.appendChild(chartBox);

		legend = common.el('div', 'nm-chart-legend');
		card.appendChild(legend);

		hint = common.el('div', 'nm-chart-hint-pill');
		card.appendChild(hint);

		page.appendChild(card);

		/* 阈值判定函数（与后端一致，阈值取自 UCI） */
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

		/* 动态 SVG 实时采样声波柱生成器（动效类收口在 style.css） */
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
				<rect class="nm-bar-dyn-1" x="2" y="${28 - b1}" width="4.5" height="${b1}" rx="2.2" fill="url(#nm-wave-grad)" />
				<rect class="nm-bar-dyn-2" x="11" y="${28 - b2}" width="4.5" height="${b2}" rx="2.2" fill="url(#nm-wave-grad)" />
				<rect class="nm-bar-dyn-3" x="20" y="${28 - b3}" width="4.5" height="${b3}" rx="2.2" fill="url(#nm-wave-grad)" />
				<rect class="nm-bar-dyn-4" x="29" y="${28 - b4}" width="4.5" height="${b4}" rx="2.2" fill="url(#nm-wave-grad)" />
				<rect class="nm-bar-dyn-5" x="38" y="${28 - b5}" width="4.5" height="${b5}" rx="2.2" fill="url(#nm-wave-grad)" />
			</svg>`;
		}

		function renderChips() {
			common.clear(chips);
			if (!data || !data.series.length) return;
			for (var i = 0; i < data.series.length; i++) {
				(function(s, idx) {
					var on = !!selected[s.id];
					var seriesColor = common.palette[idx % common.palette.length];
					/* 可点切换的胶囊：用原生 <button> 而非 div/自定义元素。
					 * 原生按钮自带键盘可达与回车激活，无需再手工补 keydown；
					 * aria-pressed 让读屏播报「已按下 / 未按下」。 */
					var tag = common.el('button', 'nm-chip-tag');
					tag.type = 'button';
					tag.classList.add(on ? 'is-on' : 'is-off');
					tag.setAttribute('aria-pressed', on ? 'true' : 'false');
					tag.setAttribute('aria-label', (s.name || s.id));
					/* 把该目标在曲线上的颜色以自定义属性交给 CSS。
					 * 选中态的边框 / 文字 / 底色都由它派生，从而保证
					 * 「胶囊颜色 == 折线颜色 == 图例颜色」，三处不会漂移；
					 * 颜色也不需要在样式表里重复硬编码。 */
					tag.style.setProperty('--nm-chip-color', seriesColor);

					var dot = common.el('span', 'nm-chip-dot');
					dot.style.backgroundColor = seriesColor;
					tag.appendChild(dot);
					tag.appendChild(document.createTextNode(s.name || s.id));

					function toggle() {
						if (selected[s.id]) delete selected[s.id];
						else selected[s.id] = true;
						renderChips();
						drawChart();
					}
					tag.addEventListener('click', toggle);
					chips.appendChild(tag);
				})(data.series[i], i);
			}
		}

		function releaseHold() {
			chartBox.style.minHeight = '';
			legend.style.minHeight = '';
			summary.style.minHeight = '';
		}

		function drawChart() {
			/* 轮询重建前锁定容器高度：mount 内部会强制布局（clientWidth），
			 * 若此时图表/摘要已清空，页面高度瞬时塌缩会把移动端滚动位置钳回顶部。 */
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

			/* 动态 SVG 音波实时采样指示 */
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
				/* 兜底：若移动端浏览器把滚动位置弹回顶部，则恢复原位 */
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
