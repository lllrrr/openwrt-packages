/*
 * luci-app-netmonitor 轻量级 SVG 图表
 *
 * 目标：不引入任何图表库，用原生 SVG 实现折线图 / 面积图 / 丢包标记 / 时间轴 / Tooltip。
 * 设计：
 *   1. 按容器实际像素宽度渲染（不用 preserveAspectRatio 拉伸），保证文字不变形。
 *   2. 只在 transform / opacity 上做交互反馈，绘制过程无动画，避免持续重绘。
 *   3. 支持鼠标与触摸两种查看方式，移动端可用手指滑动查看数据。
 *   4. 悬停是「按时间切片」而非「按最近点」：一次悬停给出所有曲线在该时刻的
 *      取值，多目标对比才有意义。命中测试与绘制共用同一套几何参数（见 layout），
 *      否则鼠标换算出的时间与画出来的曲线会错位。
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
 * 计算一次绘制用到全部几何参数。
 * render 与命中测试都必须走这里：两者一旦各算各的，鼠标位置换算出的
 * 时间戳就会和曲线所在的像素位置对不上。
 *
 * series: [ { name, color, points: [ {t, l, mn, mx, s} ] } ]
 * opts:   { width, height, yMax, padL, padR, padT, padB }
 */
function layout(series, opts) {
	opts = opts || {};
	var W = opts.width || 720;
	var H = opts.height || 220;
	var padL = opts.padL != null ? opts.padL : 42;
	var padR = opts.padR != null ? opts.padR : 10;
	var padT = opts.padT != null ? opts.padT : 12;
	var padB = opts.padB != null ? opts.padB : 24;

	var iw = Math.max(10, W - padL - padR);
	var ih = Math.max(10, H - padT - padB);

	/* 时间范围取所有系列的并集：多目标对比时各曲线共享同一根时间轴 */
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

	return {
		W: W, H: H, padL: padL, padR: padR, padT: padT, padB: padB,
		iw: iw, ih: ih, t0: t0, t1: t1, span: (t1 - t0), yMax: yMax
	};
}

/*
 * 生成 SVG 字符串。
 * series: [ { name, color, points: [ {t, l, mn, mx, s} ] } ]
 * opts:   { width, height, yMax, area, padding, showAxis, showLegend, cursor }
 *
 * opts.cursor 为真时额外输出一组悬停游标元素（竖直基准线 + 每条曲线一个
 * 取值圆点），默认不可见，由 mount 在鼠标移动时更新坐标。
 */
function render(series, opts) {
	opts = opts || {};
	var g = layout(series, opts);

	var W = g.W, H = g.H, padL = g.padL, padT = g.padT, iw = g.iw, ih = g.ih;

	function X(t) { return padL + (t - g.t0) / g.span * iw; }
	function Y(v) { return padT + ih - (v / g.yMax) * ih; }

	var out = '';
	out += '<svg class="nm-chart" width="100%" height="' + H + '" viewBox="0 0 ' + W + ' ' + H + '" preserveAspectRatio="xMidYMid meet" role="img">';

	/* 网格与 Y 轴刻度 */
	var ticks = 4;
	for (var k = 0; k <= ticks; k++) {
		var yv = g.yMax * k / ticks;
		var y = Y(yv);
		out += '<line x1="' + padL + '" y1="' + y.toFixed(1) + '" x2="' + (padL + iw) + '" y2="' + y.toFixed(1) +
			'" stroke="currentColor" stroke-opacity="0.10" stroke-width="1"/>';
		out += '<text x="' + (padL - 6) + '" y="' + (y + 3.5).toFixed(1) + '" text-anchor="end" font-size="10" fill="currentColor" fill-opacity="0.55">' +
			(Math.round(yv * 10) / 10) + '</text>';
	}

	/* X 轴时间标签 */
	var xTicks = (W < 420) ? 3 : 5;
	for (var m = 0; m <= xTicks; m++) {
		var tt = g.t0 + g.span * m / xTicks;
		var x = X(tt);
		var anchor = (m === 0) ? 'start' : (m === xTicks ? 'end' : 'middle');
		out += '<text x="' + x.toFixed(1) + '" y="' + (H - 6) + '" text-anchor="' + anchor +
			'" font-size="10" fill="currentColor" fill-opacity="0.55">' + fmtTime(tt, g.span) + '</text>';
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

	/* 悬停游标：竖直基准线 + 每条曲线一个取值圆点。
	 * 顺序与 series 一一对应，mount 按索引更新。 */
	if (opts.cursor) {
		out += '<g class="nm-cursor" opacity="0">';
		out += '<line class="nm-cur-line" x1="0" y1="' + padT + '" x2="0" y2="' + (padT + ih) +
			'" stroke="currentColor" stroke-opacity="0.35" stroke-width="1" stroke-dasharray="3 3"/>';
		for (var c = 0; c < series.length; c++) {
			var cc = series[c].color || PALETTE[c % PALETTE.length];
			out += '<circle class="nm-cur-dot" cx="-10" cy="-10" r="3.6" fill="' + cc +
				'" fill-opacity="1" stroke="' + cc + '" stroke-opacity="0.35" stroke-width="3"/>';
		}
		out += '</g>';
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

	function width() { return Math.max(320, container.clientWidth || 720); }

	var entry = { container: container, holder: holder, tip: tip, series: series, opts: opts, geo: null };
	registry.push(entry);

	function svgEl() { return holder.firstChild; }

	/* 重绘并重建游标引用。render 会覆盖 innerHTML，游标元素必须重新查。 */
	function redraw() {
		entry.geo = layout(series, {
			width: width(), height: opts.height || 220,
			yMax: opts.yMax, padL: opts.padL, padR: opts.padR, padT: opts.padT, padB: opts.padB
		});
		holder.innerHTML = render(series, {
			width: width(), height: opts.height || 220, area: opts.area,
			yMax: opts.yMax, padL: opts.padL, padR: opts.padR, padT: opts.padT, padB: opts.padB,
			cursor: true
		});
		var svg = svgEl();
		entry.cursor = svg ? svg.querySelector('.nm-cursor') : null;
		entry.curLine = svg ? svg.querySelector('.nm-cur-line') : null;
		entry.curDots = svg ? svg.querySelectorAll('.nm-cur-dot') : null;
	}

	container.appendChild(holder);
	container.appendChild(tip);
	redraw();

	/* 屏幕坐标 -> viewBox 坐标。
	 * SVG 是 width="100%" + viewBox，容器宽度变化时缩放比不是 1，
	 * 必须用 CTM 换算；直接拿 offsetX 或按比例估算都会偏。 */
	function toViewBox(clientX, clientY) {
		var svg = svgEl();
		if (!svg) return null;
		var m = (svg.getScreenCTM && svg.getScreenCTM()) || null;
		if (m) {
			if (svg.createSVGPoint) {
				var p = svg.createSVGPoint();
				p.x = clientX; p.y = clientY;
				var q = p.matrixTransform(m.inverse());
				return { x: q.x, y: q.y };
			}
			try {
				var p2 = new DOMPoint(clientX, clientY).matrixTransform(m.inverse());
				return { x: p2.x, y: p2.y };
			} catch (e) { /* 落到下面的兜底 */ }
		}
		var r = svg.getBoundingClientRect();
		return {
			x: (clientX - r.left) * (entry.geo.W / (r.width || 1)),
			y: (clientY - r.top) * (entry.geo.H / (r.height || 1))
		};
	}

	/* viewBox x -> 容器内像素 x（tooltip 用容器坐标系定位） */
	function toClientX(vx) {
		var svg = svgEl();
		if (!svg) return vx;
		var m = (svg.getScreenCTM && svg.getScreenCTM()) || null;
		if (m) {
			if (svg.createSVGPoint) {
				var p = svg.createSVGPoint();
				p.x = vx; p.y = 0;
				return p.matrixTransform(m).x;
			}
			try {
				return new DOMPoint(vx, 0).matrixTransform(m).x;
			} catch (e) { /* 落到下面的兜底 */ }
		}
		var r = svg.getBoundingClientRect();
		return r.left + vx * ((r.width || 1) / entry.geo.W);
	}

	/* 在一条曲线里找时间上最接近 tv 的采样点。
	 * 采样按时间升序写入，二分足够；点数很少时线性更省事。 */
	function nearest(pts, tv) {
		if (!pts || !pts.length) return null;
		var lo = 0, hi = pts.length - 1;
		if (tv <= pts[lo].t) return pts[lo];
		if (tv >= pts[hi].t) return pts[hi];
		while (hi - lo > 1) {
			var mid = (lo + hi) >> 1;
			if (pts[mid].t <= tv) lo = mid; else hi = mid;
		}
		return (tv - pts[lo].t <= pts[hi].t - tv) ? pts[lo] : pts[hi];
	}

	function X(t) {
		var g = entry.geo;
		return g.padL + (t - g.t0) / g.span * g.iw;
	}
	function Y(v) {
		var g = entry.geo;
		return g.padT + g.ih - (v / g.yMax) * g.ih;
	}

	/*
	 * 悬停：先由鼠标横坐标换算出「时间」，再取每条曲线在该时刻的取值。
	 * 这样 tooltip 一次给出所有曲线的数值——多目标对比时这才是有效信息，
	 * 只报离鼠标最近的那一个点会让其余曲线无从对照。
	 */
	function show(clientX, clientY) {
		var vb = toViewBox(clientX, clientY);
		var g = entry.geo;
		if (!vb || !g) return;

		var ratio = (vb.x - g.padL) / g.iw;
		if (ratio < 0) ratio = 0;
		if (ratio > 1) ratio = 1;
		var tv = g.t0 + ratio * g.span;

		var rows = '';
		var shown = 0;
		for (var i = 0; i < series.length; i++) {
			var se = series[i];
			var pts = se.points || [];
			if (!pts.length) continue;
			var p = nearest(pts, tv);
			if (!p) continue;
			var color = se.color || PALETTE[i % PALETTE.length];
			var val = (p.l == null) ? '—' : (Math.round(p.l * 10) / 10) + ' ms';
			rows += '<div class="nm-tip-row">' +
				'<i style="background:' + color + '"></i>' +
				'<span class="nm-tip-name">' + esc(se.name || ('#' + (i + 1))) + '</span>' +
				'<b class="nm-tip-val">' + val + '</b>' +
				'</div>';
			shown++;

			/* 游标取值点：无数值的采样不画圆点（曲线在此处断开） */
			var dot = entry.curDots ? entry.curDots[i] : null;
			if (dot) {
				if (p.l == null) {
					dot.setAttribute('opacity', '0');
				} else {
					dot.setAttribute('cx', X(p.t).toFixed(1));
					dot.setAttribute('cy', Y(p.l).toFixed(1));
					dot.setAttribute('opacity', '1');
				}
			}
		}
		if (!shown) { hide(); return; }

		var cx = X(tv);
		if (entry.curLine) {
			entry.curLine.setAttribute('x1', cx.toFixed(1));
			entry.curLine.setAttribute('x2', cx.toFixed(1));
		}
		if (entry.cursor) entry.cursor.setAttribute('opacity', '1');

		tip.innerHTML = '<div class="nm-tip-hd">' + fmtTime(tv, g.span) + '</div>' + rows;

		/* 定位：默认跟随光标上方；贴近图表上边缘时翻到下方，
		 * 贴近左右边缘时夹住，避免 tooltip 被容器裁掉。 */
		var rect = container.getBoundingClientRect();
		var px = toClientX(cx) - rect.left;
		var half = tip.offsetWidth ? (tip.offsetWidth / 2 + 4) : 80;
		px = Math.max(half, Math.min((rect.width || 0) - half, px));
		tip.style.left = px + 'px';
		tip.classList.toggle('is-below', (clientY - rect.top) < 72);
		tip.classList.add('is-on');
	}

	function hide() {
		tip.classList.remove('is-on');
		if (entry.cursor) entry.cursor.setAttribute('opacity', '0');
	}

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
				if (e.redraw) e.redraw();
			}
		});
	}

	/* 容器被清空（切换筛选 / 刷新数据）后旧 entry 仍在 registry 里，
	 * 这里暴露 redraw 供 resize 回调复用，并让调用方可以主动重绘。 */
	entry.redraw = redraw;
	entry.hide = hide;

	return entry;
}

return Class.extend({
	__name__: 'NetMonitor.chart',

	palette: PALETTE,
	layout: layout,
	render: render,
	mount: mount,
	niceMax: niceMax,
	fmtTime: fmtTime
});
