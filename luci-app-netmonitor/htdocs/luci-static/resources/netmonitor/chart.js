/*
 * luci-app-netmonitor 轻量级 SVG 图表
 *
 * 目标：不引入任何图表库，用原生 SVG 实现折线图 / 面积图 / 丢包标记 / 时间轴 / Tooltip。
 * 设计：
 *   1. 按容器实际像素宽度渲染（不用 preserveAspectRatio 拉伸），保证文字不变形。
 *   2. 只在 transform / opacity 上做交互反馈，绘制过程无动画，避免持续重绘。
 *   3. 支持鼠标与触摸两种查看方式，移动端可用手指滑动查看数据。
 */

'use strict';

var PALETTE = ['#2f6fed', '#2e9e5b', '#8a63d2', '#e0762c', '#00a3b4', '#d69a1a', '#cf4437', '#5c6b7a'];

var registry = [];
var resizeBound = false;

function esc(s) {
	return String(s == null ? '' : s)
		.replace(/&/g, '&amp;')
		.replace(/</g, '&lt;')
		.replace(/>/g, '&gt;')
		.replace(/"/g, '&quot;');
}

function niceMax(v) {
	if (!(v > 0)) return 10;
	var p = Math.pow(10, Math.floor(Math.log(v) / Math.LN10));
	var n = v / p;
	var m;
	if (n <= 1) m = 1;
	else if (n <= 2) m = 2;
	else if (n <= 2.5) m = 2.5;
	else if (n <= 5) m = 5;
	else m = 10;
	return m * p;
}

function fmtTime(t, spanSec) {
	var d = new Date(t * 1000);
	var p = function(x) { return (x < 10 ? '0' : '') + x; };
	if (spanSec <= 3600)
		return p(d.getHours()) + ':' + p(d.getMinutes()) + ':' + p(d.getSeconds());
	if (spanSec <= 86400 * 2)
		return p(d.getHours()) + ':' + p(d.getMinutes());
	return p(d.getMonth() + 1) + '/' + p(d.getDate()) + ' ' + p(d.getHours()) + ':' + p(d.getMinutes());
}

/*
 * 生成 SVG 字符串。
 * series: [ { name, color, points: [ {t, l, mn, mx, s} ] } ]
 * opts:   { width, height, yMax, area, padding, showAxis, showLegend }
 */
function render(series, opts) {
	opts = opts || {};
	var W = opts.width || 720;
	var H = opts.height || 220;
	var padL = opts.padL != null ? opts.padL : 42;
	var padR = opts.padR != null ? opts.padR : 10;
	var padT = opts.padT != null ? opts.padT : 12;
	var padB = opts.padB != null ? opts.padB : 24;

	var iw = Math.max(10, W - padL - padR);
	var ih = Math.max(10, H - padT - padB);

	/* 计算时间范围与 Y 轴范围 */
	var t0 = Infinity, t1 = -Infinity, vmax = 0;
	for (var i = 0; i < series.length; i++) {
		var pts = series[i].points || [];
		for (var j = 0; j < pts.length; j++) {
			if (pts[j].t < t0) t0 = pts[j].t;
			if (pts[j].t > t1) t1 = pts[j].t;
			var v = pts[j].l;
			if (pts[j].mx != null && pts[j].mx > vmax) vmax = pts[j].mx;
			if (v != null && v > vmax) vmax = v;
		}
	}
	if (!isFinite(t0)) { t0 = 0; t1 = 1; }
	if (t1 - t0 < 1) t1 = t0 + 1;

	var yMax = opts.yMax || niceMax(vmax * 1.15 || 10);
	var span = t1 - t0;

	function X(t) { return padL + (t - t0) / span * iw; }
	function Y(v) { return padT + ih - (v / yMax) * ih; }

	var out = '';
	out += '<svg class="nm-chart" width="100%" height="' + H + '" viewBox="0 0 ' + W + ' ' + H + '" preserveAspectRatio="xMidYMid meet" role="img">';

	/* 网格与 Y 轴刻度 */
	var ticks = 4;
	for (var k = 0; k <= ticks; k++) {
		var yv = yMax * k / ticks;
		var y = Y(yv);
		out += '<line x1="' + padL + '" y1="' + y.toFixed(1) + '" x2="' + (padL + iw) + '" y2="' + y.toFixed(1) +
			'" stroke="currentColor" stroke-opacity="0.10" stroke-width="1"/>';
		out += '<text x="' + (padL - 6) + '" y="' + (y + 3.5).toFixed(1) + '" text-anchor="end" font-size="10" fill="currentColor" fill-opacity="0.55">' +
			(Math.round(yv * 10) / 10) + '</text>';
	}

	/* X 轴时间标签 */
	var xTicks = (W < 420) ? 3 : 5;
	for (var m = 0; m <= xTicks; m++) {
		var tt = t0 + span * m / xTicks;
		var x = X(tt);
		var anchor = (m === 0) ? 'start' : (m === xTicks ? 'end' : 'middle');
		out += '<text x="' + x.toFixed(1) + '" y="' + (H - 6) + '" text-anchor="' + anchor +
			'" font-size="10" fill="currentColor" fill-opacity="0.55">' + fmtTime(tt, span) + '</text>';
	}

	/* 数据系列 */
	for (var s = 0; s < series.length; s++) {
		var se = series[s];
		var color = se.color || PALETTE[s % PALETTE.length];
		var pts2 = se.points || [];
		if (!pts2.length) continue;

		var d = '', dArea = '', started = false, lastX = null;
		for (var p = 0; p < pts2.length; p++) {
			var pt = pts2[p];
			var px = X(pt.t);
			if (pt.l == null) {
				started = false;
				lastX = px;
				continue;
			}
			var py = Y(pt.l);
			if (!started) {
				d += (d ? ' M' : 'M') + px.toFixed(1) + ' ' + py.toFixed(1);
				dArea += (dArea ? ' L' : 'M') + px.toFixed(1) + ' ' + (padT + ih) + ' L' + px.toFixed(1) + ' ' + py.toFixed(1);
				started = true;
			} else {
				d += ' L' + px.toFixed(1) + ' ' + py.toFixed(1);
				dArea += ' L' + px.toFixed(1) + ' ' + py.toFixed(1);
			}
			lastX = px;
		}

		if (opts.area && series.length === 1 && dArea) {
			dArea += ' L' + lastX + ' ' + (padT + ih) + ' Z';
			out += '<path d="' + dArea + '" fill="' + color + '" fill-opacity="0.12"/>';
		}

		if (d)
			out += '<path d="' + d + '" fill="none" stroke="' + color + '" stroke-width="1.8" stroke-linejoin="round" stroke-linecap="round"/>';

		/* 失败点标记 */
		for (var q = 0; q < pts2.length; q++) {
			if (pts2[q].s === 0 || pts2[q].l == null) {
				out += '<line x1="' + X(pts2[q].t).toFixed(1) + '" y1="' + (padT + 2) + '" x2="' + X(pts2[q].t).toFixed(1) +
					'" y2="' + (padT + ih) + '" stroke="#cf4437" stroke-opacity="0.28" stroke-width="1"/>';
			}
		}

		/* 当前值圆点 */
		var last = pts2[pts2.length - 1];
		if (last && last.l != null)
			out += '<circle cx="' + X(last.t).toFixed(1) + '" cy="' + Y(last.l).toFixed(1) + '" r="3" fill="' + color + '"/>';
	}

	out += '</svg>';
	return out;
}

/* 在容器中渲染图表，并绑定 tooltip / 触摸查看 / 自适应尺寸 */
function mount(container, series, opts) {
	opts = opts || {};
	if (!container) return null;

	var holder = document.createElement('div');
	var tip = document.createElement('div');
	tip.className = 'nm-tip';
	holder.innerHTML = render(series, { width: Math.max(320, container.clientWidth || 720), height: opts.height || 220, area: opts.area, yMax: opts.yMax });
	container.appendChild(holder);
	container.appendChild(tip);

	var entry = { container: container, holder: holder, tip: tip, series: series, opts: opts };
	registry.push(entry);

	var iw = Math.max(10, (container.clientWidth || 720) - 42 - 10);
	var padL = 42;

	function hit(clientX) {
		var rect = holder.getBoundingClientRect();
		var x = clientX - rect.left;
		var scale = holder.firstChild ? (rect.width / parseFloat(holder.firstChild.getAttribute('width') || rect.width)) : 1;
		var vx = x / (scale || 1);
		/* 找到时间上最近的点 */
		var best = null, bestD = Infinity;
		for (var i = 0; i < series.length; i++) {
			var pts = series[i].points || [];
			if (!pts.length) continue;
			var t0 = pts[0].t, t1 = pts[pts.length - 1].t;
			var span = (t1 - t0) || 1;
			var ratio = (vx - padL) / iw;
			var tv = t0 + ratio * span;
			for (var j = 0; j < pts.length; j++) {
				var d = Math.abs(pts[j].t - tv);
				if (d < bestD) { bestD = d; best = { s: series[i], p: pts[j] }; }
			}
		}
		if (!best) return null;
		var rect2 = holder.getBoundingClientRect();
		var span2 = ((best.s.points[best.s.points.length - 1].t - best.s.points[0].t) || 1);
		var xr = (best.p.t - best.s.points[0].t) / span2 * iw + padL;
		return { x: xr * (rect2.width / (parseFloat(holder.firstChild.getAttribute('width')) || rect2.width)), y: rect2.height / 2, item: best, rect: rect2 };
	}

	function show(clientX, clientY) {
		var h = hit(clientX);
		if (!h) return;
		var p = h.item.p;
		var label = h.item.s.name ? esc(h.item.s.name) + ' · ' : '';
		var val = (p.l == null) ? '—' : (Math.round(p.l * 10) / 10) + ' ms';
		tip.innerHTML = label + val + '<br><span style="opacity:.7">' + fmtTime(p.t, 3600) + '</span>';
		tip.style.left = h.x + 'px';
		tip.style.top = (clientY - holder.getBoundingClientRect().top + 8) + 'px';
		tip.classList.add('is-on');
	}

	function hide() { tip.classList.remove('is-on'); }

	container.addEventListener('mousemove', function(ev) { show(ev.clientX, ev.clientY); });
	container.addEventListener('mouseleave', hide);
	container.addEventListener('touchstart', function(ev) {
		if (ev.touches && ev.touches[0]) show(ev.touches[0].clientX, ev.touches[0].clientY);
	}, { passive: true });
	container.addEventListener('touchmove', function(ev) {
		if (ev.touches && ev.touches[0]) show(ev.touches[0].clientX, ev.touches[0].clientY);
	}, { passive: true });
	container.addEventListener('touchend', hide);

	if (!resizeBound) {
		resizeBound = true;
		window.addEventListener('resize', function() {
			for (var i = 0; i < registry.length; i++) {
				var e = registry[i];
				if (!e.container || !e.container.isConnected) continue;
				var w = Math.max(320, e.container.clientWidth || 720);
				e.holder.innerHTML = render(e.series, { width: w, height: e.opts.height || 220, area: e.opts.area, yMax: e.opts.yMax });
			}
		});
	}

	return entry;
}

return Class.extend({
	__name__: 'NetMonitor.chart',

	palette: PALETTE,
	render: render,
	mount: mount,
	niceMax: niceMax,
	fmtTime: fmtTime
});
