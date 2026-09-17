/*
 * luci-app-netmonitor 动态 SVG 图标库（v3）
 *
 * 设计约束：
 *   1. 全部内联绘制，不引用任何外部图标 CDN、图标字体或位图。
 *   2. 每个图标都是「参数化」的：同一函数在不同真实数据下输出不同结构、
 *      不同颜色、不同动画速度，绝不作为纯装饰存在。
 *   3. 动画只作用于 transform / opacity / stroke-dashoffset 三类属性，
 *      不使用 filter 与 blur，低端路由设备也能长时间稳定运行。
 *   4. 颜色全部通过 .nm-fill-* / .nm-str-* 类引用主题变量，浅色与深色主题
 *      都能自动取得足够对比度，不写死单一配色。
 */

'use strict';

/* ---------------------------------------------------------------- 配色映射 */

var GRADE_COLOR = {
	excellent: 'green',
	good: 'green',
	fair: 'yellow',
	poor: 'orange',
	severe: 'red',
	down: 'red',
	disabled: 'idle',
	unknown: 'idle'
};

/* 仪表盘指针与圆环进度使用的等级归一化位置（0 = 最好，1 = 最差） */
var GRADE_RATIO = {
	excellent: 0.10,
	good: 0.28,
	fair: 0.50,
	poor: 0.72,
	severe: 0.90,
	down: 0.97,
	disabled: 0.50,
	unknown: 0.50
};

function gradeColor(g) {
	return GRADE_COLOR[g] || 'idle';
}

function gradeRatio(g) {
	var r = GRADE_RATIO[g];
	return (r == null) ? 0.5 : r;
}

/* 填充 / 描边类名（对应 style.css 中的 .nm-fill-* / .nm-str-*） */
function fc(name) { return 'nm-fill-' + name; }
function sc(name) { return 'nm-str-' + name; }

/* ---------------------------------------------------------------- 基础工具 */

function num(v, digits) {
	if (v == null || isNaN(v)) return '--';
	var p = Math.pow(10, digits == null ? 0 : digits);
	var r = Math.round(v * p) / p;
	return String(r);
}

function esc(s) {
	return String(s == null ? '' : s)
		.replace(/&/g, '&amp;')
		.replace(/</g, '&lt;')
		.replace(/>/g, '&gt;')
		.replace(/"/g, '&quot;')
		.replace(/'/g, '&#39;');
}

function clip(s, max) {
	s = String(s == null ? '' : s);
	return (s.length > max) ? (s.slice(0, max - 1) + '\u2026') : s;
}

function clamp01(v) {
	if (v == null || isNaN(v)) return 0;
	return (v < 0) ? 0 : (v > 1 ? 1 : v);
}

/* 文字可读性阈值。
 *
 * 图标统一按 0 0 120 120 绘制，字号会随渲染尺寸等比缩小：
 * font-size 23 在 44px 的图标里只剩 8.4px，font-size 11 更是只剩 4px，
 * 渲染出来是一团噪点而不是信息。因此约定：
 *   - 主数值（延迟数字、百分比）在 >= 60px 时绘制（约 11.5px 实际高度）
 *   - 辅助文字（ms、IPv4/IPv6、目标名、告警计数）在 >= 84px 时绘制
 * 小于阈值时只保留图形本身，数值改由旁边的真实文字承担，
 * 避免出现读不出来的装饰性文字。 */
var TEXT_MAIN_MIN = 60;
var TEXT_SUB_MIN = 84;

function bigEnough(size, min) {
	return (size == null) || (size >= min);
}

/* 统一的外层封装：所有图标共用 0 0 120 120 视口，保证在不同尺寸下比例一致 */
function wrap(size, inner, label) {
	var s = (size == null) ? 40 : size;
	return '<svg class="nm-svg" width="' + s + '" height="' + s + '" viewBox="0 0 120 120" ' +
		'role="img" aria-label="' + esc(label || _('Icon')) + '">' + inner + '</svg>';
}

/* 环形进度：track 为底环，progress 为真实数据对应的弧长 */
function ringProgress(ratio, colorName, size, label, text) {
	var R = 38;
	var C = 2 * Math.PI * R;
	var len = C * clamp01(ratio);
	var body = '<circle cx="60" cy="60" r="' + R + '" fill="none" class="' + sc('line') + '" stroke-width="9"/>' +
		'<circle cx="60" cy="60" r="' + R + '" fill="none" class="' + sc(colorName) +
			'" stroke-width="9" stroke-linecap="butt" transform="rotate(-90 60 60)" ' +
			'style="stroke-dasharray:' + len.toFixed(1) + ' ' + C.toFixed(1) + '"/>';
	body += '<circle cx="60" cy="60" r="46" fill="none" class="' + sc('cyan') +
		' nm-an-dash" stroke-width="1.5" opacity="0.5"/>';
	if (text != null && bigEnough(size, TEXT_MAIN_MIN))
		body += '<text x="60" y="68" text-anchor="middle" class="' + fc('fg') +
			'" font-size="23" font-weight="800">' + esc(text) + '</text>';
	return wrap(size, body, label);
}

/* ---------------------------------------------------------------- 01/02 总体健康 */

function health(state, size) {
	var col = (state === 'good') ? 'green' :
	          (state === 'warning') ? 'yellow' :
	          (state === 'critical') ? 'red' : 'idle';
	var sf = fc(col), ss = sc(col);

	if (state === 'good') {
		return wrap(size,
			'<circle cx="60" cy="60" r="45" fill="none" class="' + ss + ' nm-an-dash" stroke-width="2"/>' +
			'<circle cx="60" cy="60" r="35" fill="none" class="' + ss + '" stroke-width="5"/>' +
			'<circle cx="60" cy="60" r="43" fill="none" class="' + ss + ' nm-an-ring" stroke-width="2"/>' +
			'<path d="M43 60l11 11 24-27" fill="none" class="' + ss +
				'" stroke-width="7" stroke-linecap="round" stroke-linejoin="round"/>',
			'health-ok');
	}

	if (state === 'warning' || state === 'critical') {
		return wrap(size,
			'<circle cx="60" cy="60" r="45" fill="none" class="' + ss + ' nm-an-dash-rev" stroke-width="2"/>' +
			'<circle cx="60" cy="60" r="35" fill="none" class="' + ss + '" stroke-width="5"/>' +
			'<circle cx="60" cy="60" r="43" fill="none" class="' + ss + ' nm-an-ring" stroke-width="2"/>' +
			'<path d="M60 40v27M60 76v2" fill="none" class="' + ss +
				'" stroke-width="7" stroke-linecap="round"/>',
			'health-' + (state === 'critical' ? 'critical' : 'warning'));
	}

	return wrap(size,
		'<circle cx="60" cy="60" r="45" fill="none" class="' + ss + ' nm-an-dash" stroke-width="2"/>' +
		'<circle cx="60" cy="60" r="35" fill="none" class="' + ss + '" stroke-width="4" opacity="0.45"/>' +
		'<circle cx="60" cy="60" r="10" class="' + sf + ' nm-an-pulse"/>',
		'health-unknown');
}

/* ---------------------------------------------------------------- 03 Ping 探测 */

function ping(size, opts) {
	opts = opts || {};
	var col = (opts.grade === 'down' || opts.grade === 'severe') ? 'red' :
	          (opts.kind === 'dns') ? 'orange' : 'cyan';
	var ss = sc(col), sf = fc(col);
	return wrap(size,
		'<rect x="11" y="43" width="29" height="21" rx="4" fill="none" class="' + sc('blue') + '" stroke-width="3"/>' +
		'<path d="M17 70h17M25 64v6" fill="none" class="' + sc('blue') +
			'" stroke-width="3" stroke-linecap="round"/>' +
		'<rect x="80" y="39" width="29" height="30" rx="5" fill="none" class="' + ss + '" stroke-width="3"/>' +
		'<path d="M86 48h17M86 55h12" fill="none" class="' + ss +
			'" stroke-width="2" stroke-linecap="round"/>' +
		'<path d="M41 53C51 34 69 34 79 53" fill="none" class="' + ss + ' nm-an-dash" stroke-width="2"/>' +
		'<circle cx="60" cy="39" r="5" class="' + sf + ' nm-an-pulse"/>',
		'ping');
}

/* ---------------------------------------------------------------- 04 实时延迟 */

function latencyDial(ms, grade, size) {
	var col = gradeColor(grade);
	var txt = (ms == null || isNaN(ms)) ? '--' : num(ms, ms >= 100 ? 0 : 1);
	return wrap(size,
		'<circle cx="60" cy="60" r="45" fill="none" class="' + sc(col) + ' nm-an-dash" stroke-width="2"/>' +
		'<circle cx="60" cy="60" r="34" fill="none" class="' + sc(col) + '" stroke-width="5"/>' +
		'<circle cx="60" cy="60" r="26" fill="none" class="' + sc(col) + ' nm-an-ring" stroke-width="2"/>' +
		'<text x="60" y="63" text-anchor="middle" class="' + fc('fg') +
			'" font-size="23" font-weight="800">' + esc(txt) + '</text>' +
		(bigEnough(size, TEXT_SUB_MIN)
			? '<text x="60" y="78" text-anchor="middle" class="' + fc('muted') +
				'" font-size="10">ms</text>'
			: ''),
		'latency');
}

/* 兼容旧调用名 */
function latency(value, grade, size) {
	return latencyDial(value, grade, size);
}

/* ---------------------------------------------------------------- 05 在线状态 */

function online(size, ok) {
	var on = (ok !== false);
	var col = on ? 'green' : 'idle';
	var C = 2 * Math.PI * 40;
	var arc = C * 0.28;
	return wrap(size,
		'<circle cx="60" cy="60" r="46" fill="none" class="' + sc('cyan') +
			' nm-an-dash" stroke-width="1.5" opacity="0.5"/>' +
		'<circle cx="60" cy="60" r="40" fill="none" class="' + sc(col) + '" stroke-width="5" ' +
			'stroke-linecap="round" transform="rotate(-90 60 60)" ' +
			'style="stroke-dasharray:' + arc.toFixed(1) + ' ' + C.toFixed(1) + '"/>' +
		'<path d="M35 57c14-14 36-14 50 0M44 67c9-9 23-9 32 0M56 77h8" fill="none" ' +
			'class="' + sc(on ? 'cyan' : 'idle') + '" stroke-width="5" stroke-linecap="round"/>' +
		'<circle cx="60" cy="77" r="3.5" class="' + fc(on ? 'cyan' : 'idle') +
			(on ? ' nm-an-pulse' : '') + '"/>',
		on ? 'online' : 'offline');
}

/* ---------------------------------------------------------------- 06 丢包检测 */

function packetLoss(pct, size) {
	var lost = (pct != null && !isNaN(pct) && pct > 0);
	var col = lost ? 'red' : 'green';
	return wrap(size,
		'<path d="M12 60h96" fill="none" class="' + sc('line') + '" stroke-width="3" stroke-linecap="round"/>' +
		'<circle cx="24" cy="60" r="5" class="' + fc('cyan') + '"/>' +
		'<circle cx="43" cy="60" r="5" class="' + fc('blue') + ' nm-an-pulse"/>' +
		'<circle cx="61" cy="60" r="5" class="' + fc('cyan') + (lost ? ' nm-an-pulse' : '') + '"/>' +
		'<g class="' + fc(col) + ' nm-an-pulse">' +
			'<circle cx="80" cy="60" r="14" fill="none" class="' + sc(col) + '" stroke-width="3"/>' +
			(lost
				? '<path d="M74 54l12 12M86 54L74 66" fill="none" class="' + sc(col) +
					'" stroke-width="3" stroke-linecap="round"/>'
				: '<path d="M73 60l5 5 10-11" fill="none" class="' + sc(col) +
					'" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"/>') +
		'</g>' +
		'<path d="M98 60h10" fill="none" class="' + sc('muted') + ' nm-an-dash" stroke-width="3"/>',
		lost ? 'loss' : 'no-loss');
}

/* ---------------------------------------------------------------- 07 高延迟波形 */

function highLatency(ms, grade, size) {
	var col = gradeColor(grade);
	if (grade === 'unknown' || grade === 'disabled') col = 'idle';
	var peak = fc(col === 'green' ? 'yellow' : col);
	return wrap(size,
		'<path d="M12 83h96" fill="none" class="' + sc('line') + '" stroke-width="2"/>' +
		'<path d="M12 68L25 48 37 75 49 41 61 70 74 35 87 73 101 29 109 55" fill="none" class="' +
			sc(col) + ' nm-an-dash" stroke-width="4" stroke-linecap="round" stroke-linejoin="round"/>' +
		'<circle cx="101" cy="29" r="5" class="' + peak + ' nm-an-pulse"/>',
		'high-latency');
}

/* ---------------------------------------------------------------- 08 DNS 解析失败 */

function dnsFail(size) {
	return wrap(size,
		'<ellipse cx="60" cy="60" rx="40" ry="29" fill="none" class="' + sc('blue') + '" stroke-width="2"/>' +
		'<ellipse cx="60" cy="60" rx="18" ry="40" fill="none" class="' + sc('blue') + '" stroke-width="2"/>' +
		'<path d="M20 60h80M27 44h66M27 76h66" fill="none" class="' + sc('blue') + '" stroke-width="2"/>' +
		'<circle cx="89" cy="87" r="15" class="' + fc('line') + ' nm-an-pulse"/>' +
		'<circle cx="89" cy="87" r="15" fill="none" class="' + sc('red') + '" stroke-width="3"/>' +
		'<path d="M83 81l12 12M95 81L83 93" fill="none" class="' + sc('red') +
			'" stroke-width="3" stroke-linecap="round"/>',
		'dns-error');
}

/* ---------------------------------------------------------------- 09 国内网络 */

function regionCN(size, x, ms) {
	x = x || {};
	var ok = !(x.abnormal > 0);
	var col = ok ? 'green' : 'red';
	var sf = fc(col), ss = sc(col);
	return wrap(size,
		'<path d="M28 36l30-10 29 16 5 28-25 25-35-9-11-25z" fill="none" class="' + sc('cyan') +
			'" stroke-width="2"/>' +
		'<path d="M39 45l27 5-15 23 25-4-9 17" fill="none" class="' + sc('cyan') + '" stroke-width="2"/>' +
		'<circle cx="39" cy="45" r="5" class="' + sf + ' nm-an-pulse"/>' +
		'<circle cx="66" cy="50" r="4" class="' + sf + '"/>' +
		'<circle cx="51" cy="73" r="4" class="' + sf + (ok ? ' nm-an-pulse' : '') + '"/>' +
		'<circle cx="76" cy="69" r="4" class="' + sf + '"/>' +
		((ms != null && bigEnough(size, TEXT_SUB_MIN))
			? '<text x="60" y="112" text-anchor="middle" class="' + fc('muted') +
				'" font-size="13">' + esc(num(ms, 0)) + ' ms</text>'
			: '') +
		(ok ? '' : '<circle cx="88" cy="26" r="14" fill="none" class="' + ss +
			' nm-an-ring" stroke-width="3"/>'),
		'region-cn');
}

/* ---------------------------------------------------------------- 10 国外网络 */

function regionGlobal(size, x, ms) {
	x = x || {};
	var ok = !(x.abnormal > 0);
	var col = ok ? 'green' : 'yellow';
	return wrap(size,
		'<ellipse cx="60" cy="61" rx="44" ry="30" fill="none" class="' + sc('blue') + '" stroke-width="2"/>' +
		'<path d="M16 61h88M60 31c-18 17-18 43 0 60M60 31c18 17 18 43 0 60' +
			'M28 45c18 8 46 8 64 0M28 77c18-8 46-8 64 0" fill="none" class="' + sc('blue') +
			'" stroke-width="1.8"/>' +
		'<path d="M33 49C50 29 72 31 91 50" fill="none" class="' + sc('cyan') +
			' nm-an-dash" stroke-width="3"/>' +
		'<circle cx="33" cy="49" r="5" class="' + fc('cyan') + ' nm-an-pulse"/>' +
		'<circle cx="91" cy="50" r="5" class="' + fc(col) + ' nm-an-pulse"/>' +
		((ms != null && bigEnough(size, TEXT_SUB_MIN))
			? '<text x="60" y="112" text-anchor="middle" class="' + fc('muted') +
				'" font-size="13">' + esc(num(ms, 0)) + ' ms</text>'
			: ''),
		'region-overseas');
}

/* ---------------------------------------------------------------- 11 延迟等级仪表 */

function gradeGauge(ms, grade, size) {
	var col = gradeColor(grade);
	var ratio = gradeRatio(grade);
	var LEN = Math.PI * 42;                 /* 半圆弧长 ≈ 131.9 */
	var arc = LEN * ratio;
	var ang = (ratio * 180 - 90).toFixed(1); /* -90° 指左，+90° 指右 */
	return wrap(size,
		'<path d="M20 79a42 42 0 0 1 80 0" fill="none" class="' + sc('line') +
			'" stroke-width="10" stroke-linecap="butt"/>' +
		'<path d="M20 79a42 42 0 0 1 80 0" fill="none" class="' + sc(col) +
			'" stroke-width="10" stroke-linecap="butt" ' +
			'style="stroke-dasharray:' + arc.toFixed(1) + ' ' + LEN.toFixed(1) + '"/>' +
		'<g transform="rotate(' + ang + ' 60 79)">' +
			'<path d="M60 79L60 42" fill="none" class="' + sc('fg') +
				'" stroke-width="4" stroke-linecap="round"/>' +
		'</g>' +
		'<circle cx="60" cy="79" r="6" class="' + fc('fg') + ' nm-an-pulse"/>' +
		(bigEnough(size, TEXT_SUB_MIN)
			? '<text x="60" y="112" text-anchor="middle" class="' + fc('muted') +
				'" font-size="14">' + esc(num(ms, 0)) + ' ms</text>'
			: ''),
		'grade-gauge');
}

/* ---------------------------------------------------------------- 12 统计趋势 */

function trend(size) {
	return wrap(size,
		'<path d="M15 94V23M15 94h95" fill="none" class="' + sc('line') + '" stroke-width="2"/>' +
		'<path d="M21 78l14-17 14 9 14-24 14 26 13-17 17 10" fill="none" class="' + sc('cyan') +
			' nm-an-dash" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"/>' +
		'<path d="M21 84l14-5 14-11 14 8 14-5 13-10" fill="none" class="' + sc('green') +
			'" stroke-width="2" stroke-linecap="round"/>' +
		'<circle cx="87" cy="55" r="4" class="' + fc('cyan') + ' nm-an-pulse"/>',
		'trend');
}

/* ---------------------------------------------------------------- 13 网络接口 */

function iface(up, size) {
	var on = (up !== false);
	var col = on ? 'green' : 'red';
	return wrap(size,
		'<rect x="33" y="27" width="54" height="36" rx="7" fill="none" class="' + sc('blue') +
			'" stroke-width="3"/>' +
		'<circle cx="48" cy="45" r="4" class="' + fc(col) + (on ? ' nm-an-pulse' : ' nm-an-blink') + '"/>' +
		'<circle cx="60" cy="45" r="4" class="' + fc('cyan') + '"/>' +
		'<circle cx="72" cy="45" r="4" class="' + fc(col) + (on ? ' nm-an-pulse' : ' nm-an-blink') + '"/>' +
		'<path d="M45 63v12M60 63v20M75 63v12M33 85h54" fill="none" class="' + sc('cyan') +
			'" stroke-width="3" stroke-linecap="round"/>' +
		'<path d="M27 85c-12 0-12 18 0 18h16M93 85c12 0 12 18 0 18H77" fill="none" class="' +
			sc('blue') + ' nm-an-dash" stroke-width="2"/>',
		on ? 'iface-up' : 'iface-down');
}

/* ---------------------------------------------------------------- 14 服务状态 */

function service(state, size) {
	var on = !!state;
	var col = on ? 'green' : 'red';
	var d = fc(col) + (on ? ' nm-an-pulse' : ' nm-an-blink');
	return wrap(size,
		'<circle cx="60" cy="60" r="55" fill="none" class="' + sc(on ? 'green' : 'red') +
			' nm-an-dash' + (on ? '' : '-rev') + '" stroke-width="2" opacity="0.55"/>' +
		'<rect x="28" y="24" width="64" height="21" rx="5" fill="none" class="' + sc('blue') +
			'" stroke-width="3"/>' +
		'<rect x="28" y="50" width="64" height="21" rx="5" fill="none" class="' + sc('blue') +
			'" stroke-width="3"/>' +
		'<rect x="28" y="76" width="64" height="21" rx="5" fill="none" class="' + sc('blue') +
			'" stroke-width="3"/>' +
		'<circle cx="78" cy="34.5" r="4" class="' + d + '"/>' +
		'<circle cx="78" cy="60.5" r="4" class="' + d + '" style="animation-delay:.3s"/>' +
		'<circle cx="78" cy="86.5" r="4" class="' + d + '" style="animation-delay:.6s"/>' +
		'<path d="M38 35h20M38 61h20M38 87h20" fill="none" class="' + sc('muted') +
			'" stroke-width="2" stroke-linecap="round"/>',
		on ? 'service-running' : 'service-stopped');
}

/* ---------------------------------------------------------------- 15 多目标监控 */

/* list 元素可带 latency（实时）或 avg（聚合），二者都没有时只显示名称，
 * 绝不用 "--" 冒充一个数值；颜色优先取 grade，其次 status / enabled。 */
function multiTarget(list, size) {
	var ys = [36, 60, 84];
	var shown = (list || []).slice(0, 3);
	var body = '<path d="M17 36h86M17 60h86M17 84h86" fill="none" class="' + sc('line') +
		'" stroke-width="3" stroke-linecap="round"/>';

	if (!shown.length) {
		for (var i = 0; i < 3; i++)
			body += '<circle cx="25" cy="' + ys[i] + '" r="6" class="' + fc('idle') +
				' nm-an-blink" style="animation-delay:' + (i * 0.25).toFixed(2) + 's"/>';
		return wrap(size, body, 'targets-empty');
	}

	for (var j = 0; j < shown.length; j++) {
		var t = shown[j] || {};
		var col = t.color;
		if (!col) {
			if (t.grade != null && t.grade !== 'unknown')
				col = gradeColor(t.grade);
			else if (t.status === 'online')
				col = 'green';
			else if (t.status === 'failed')
				col = 'red';
			else if (t.enabled === false)
				col = 'idle';
			else
				/* 中立色：表示「已配置/已启用」，不代表链路健康 */
				col = 'accent';
		}
		var nm = clip(t.name || t.id || t.host || '?', 12);
		var lat = (t.latency != null) ? t.latency : t.avg;
		var tail = (lat == null || isNaN(lat)) ? '' : (' \u00b7 ' + num(lat, 0) + 'ms');
		body += '<circle cx="25" cy="' + ys[j] + '" r="6" class="' + fc(col) +
			' nm-an-pulse" style="animation-delay:' + (j * 0.22).toFixed(2) + 's"/>';
		if (bigEnough(size, TEXT_SUB_MIN))
			body += '<text x="40" y="' + (ys[j] + 4) + '" class="' + fc('fg') + '" font-size="11">' +
				esc(nm + tail) + '</text>';
	}
	return wrap(size, body, 'targets');
}

/* ---------------------------------------------------------------- 16 成功率圆环 */

function successRing(pct, size) {
	var v = (pct == null || isNaN(pct)) ? 0 : pct;
	return ringProgress(v / 100, v >= 99 ? 'green' : (v >= 95 ? 'yellow' : 'red'),
		size, 'success-rate', num(v, 0) + '%');
}

/* ---------------------------------------------------------------- 17 丢包率圆环 */

function lossRing(pct, size) {
	var v = (pct == null || isNaN(pct)) ? 0 : pct;
	return ringProgress(v / 100, v <= 0 ? 'green' : (v <= 5 ? 'yellow' : 'red'),
		size, 'packet-loss', num(v, 1) + '%');
}

/* ---------------------------------------------------------------- 18 检测时间 */

function clock(ts, size) {
	var d = (ts ? new Date(ts * 1000) : null);
	var hh = d ? (d.getHours() % 12) : 12;
	var mm = d ? d.getMinutes() : 0;
	var ss = d ? d.getSeconds() : 0;
	var hAng = (hh * 30 + mm * 0.5).toFixed(1);
	var mAng = (mm * 6 + ss * 0.1).toFixed(1);
	var live = !!ts;
	return wrap(size,
		'<circle cx="60" cy="60" r="39" fill="none" class="' +
			sc(live ? 'cyan' : 'idle') + '" stroke-width="4"/>' +
		'<circle cx="60" cy="60" r="46" fill="none" class="' +
			sc(live ? 'cyan' : 'idle') + ' nm-an-dash-rev" stroke-width="2"/>' +
		'<g transform="rotate(' + hAng + ' 60 60)">' +
			'<path d="M60 60V40" fill="none" class="' + sc('fg') +
				'" stroke-width="5" stroke-linecap="round"/>' +
		'</g>' +
		'<g transform="rotate(' + mAng + ' 60 60)">' +
			'<path d="M60 60V32" fill="none" class="' + sc('cyan') +
				'" stroke-width="3.4" stroke-linecap="round"/>' +
		'</g>' +
		'<circle cx="60" cy="60" r="5" class="' + fc(live ? 'cyan' : 'idle') +
			(live ? ' nm-an-pulse' : '') + '"/>',
		'last-check');
}

/* ---------------------------------------------------------------- 19 设置齿轮 */

function gear(size, spinning) {
	var spin = (spinning === false) ? '' : ' nm-an-spin';
	return wrap(size,
		'<g class="' + spin + '">' +
			'<path d="M60 19l8 9 12-2 3 11 11 5-4 11 8 8-8 8 4 11-11 5-3 11-12-2-8 9-8-9-12 2-3-11' +
				'-11-5 4-11-8-8 8-8-4-11 11-5 3-11 12 2z" fill="none" class="' + sc('blue') +
				'" stroke-width="4" stroke-linejoin="round"/>' +
		'</g>' +
		'<circle cx="60" cy="60" r="13" fill="none" class="' + sc('cyan') + '" stroke-width="4"/>',
		'settings');
}

/* ---------------------------------------------------------------- 20 历史数据 */

function database(size) {
	return wrap(size,
		'<ellipse cx="60" cy="34" rx="25" ry="9" fill="none" class="' + sc('cyan') + '" stroke-width="3"/>' +
		'<path d="M35 34v42c0 5 11 9 25 9s25-4 25-9V34M35 55c0 5 11 9 25 9s25-4 25-9" fill="none" class="' +
			sc('blue') + '" stroke-width="3"/>' +
		'<path d="M84 74c12 3 17 12 13 23" fill="none" class="' + sc('green') +
			' nm-an-dash" stroke-width="3"/>',
		'history');
}

/* ---------------------------------------------------------------- 21 异常提醒 */

function bell(count, size) {
	var alarm = (count == null || count > 0);
	return wrap(size,
		'<path d="M38 76h44l-5-10V50c0-11-7-20-17-20s-17 9-17 20v16z" fill="none" class="' +
			sc('blue') + '" stroke-width="4" stroke-linejoin="round"/>' +
		'<path d="M52 86c3 7 13 7 16 0" fill="none" class="' + sc('cyan') +
			'" stroke-width="4" stroke-linecap="round"/>' +
		'<circle cx="85" cy="34" r="11" class="' + fc(alarm ? 'red' : 'green') +
			(alarm ? ' nm-an-ring' : '') + '"/>' +
		(alarm
			? '<path d="M85 28.5v6.5M85 39v1.5" fill="none" stroke="#fff" stroke-width="2.4" stroke-linecap="round"/>'
			: '<path d="M80 34l3.5 4 7-7.5" fill="none" stroke="#fff" stroke-width="2.4" ' +
				'stroke-linecap="round" stroke-linejoin="round"/>') +
		(bigEnough(size, TEXT_SUB_MIN)
			? '<text x="85" y="63" text-anchor="middle" class="' + fc('muted') + '" font-size="12">' +
				esc(alarm ? String(count == null ? '!' : count) : '0') + '</text>'
			: ''),
		alarm ? 'alert' : 'no-alert');
}

/* ---------------------------------------------------------------- 22 IPv4 / IPv6 */

function dualStack(family, v4, v6, size) {
	var f = family || 'auto';
	var a4 = (f === 'ipv4' || f === 'both' || f === 'auto') && (v4 !== false);
	var a6 = (f === 'ipv6' || f === 'both' || f === 'auto') && (v6 !== false);
	var labels = bigEnough(size, TEXT_SUB_MIN);
	return wrap(size,
		'<circle cx="42" cy="60" r="28" fill="none" class="' + sc(a4 ? 'blue' : 'idle') +
			'" stroke-width="3" opacity="' + (a4 ? 1 : 0.45) + '"/>' +
		'<circle cx="78" cy="60" r="28" fill="none" class="' + sc(a6 ? 'cyan' : 'idle') +
			'" stroke-width="3" opacity="' + (a6 ? 1 : 0.45) + '"/>' +
		(labels
			? '<text x="42" y="64" text-anchor="middle" class="' + fc(a4 ? 'fg' : 'muted') +
				'" font-size="12" font-weight="700">IPv4</text>' +
				'<text x="78" y="64" text-anchor="middle" class="' + fc(a6 ? 'fg' : 'muted') +
				'" font-size="12" font-weight="700">IPv6</text>'
			: '') +
		'<path d="M57 60h6" fill="none" class="' + sc(a4 && a6 ? 'green' : 'idle') +
			(a4 && a6 ? ' nm-an-dash' : '') + '" stroke-width="3"/>',
		'dual-stack');
}

/* ---------------------------------------------------------------- 23 实时统计柱状 */

function liveBars(values, size) {
	var vals = (values || []).slice(0, 4);
	while (vals.length < 4) vals.push(null);

	var max = 0;
	for (var i = 0; i < vals.length; i++)
		if (vals[i] != null && vals[i] > max) max = vals[i];
	if (max <= 0) max = 1;

	var cols = ['blue', 'cyan', 'green', 'yellow'];
	var delays = ['0s', '.18s', '.36s', '.54s'];
	var bars = '';
	for (var j = 0; j < 4; j++) {
		var v = (vals[j] == null) ? 0.12 : Math.max(0.12, Math.min(1, vals[j] / max));
		var h = 18 + v * 48;
		bars += '<rect x="' + (25 + j * 19) + '" y="' + (94 - h).toFixed(1) + '" width="12" height="' +
			h.toFixed(1) + '" rx="3" class="' + fc(cols[j]) + ' nm-an-bar" style="animation-delay:' +
			delays[j] + '"/>';
	}
	return wrap(size,
		'<path d="M18 94h86" fill="none" class="' + sc('line') + '" stroke-width="2"/>' + bars,
		'live-stats');
}

/* ---------------------------------------------------------------- 24 响应式布局 */

function responsive(size) {
	return wrap(size,
		'<rect x="17" y="28" width="61" height="42" rx="5" fill="none" class="' + sc('blue') +
			'" stroke-width="3"/>' +
		'<path d="M31 80h33M47 70v10" fill="none" class="' + sc('blue') +
			'" stroke-width="3" stroke-linecap="round"/>' +
		'<rect x="83" y="49" width="20" height="39" rx="4" fill="none" class="' + sc('cyan') +
			'" stroke-width="3"/>' +
		'<circle cx="93" cy="80" r="2.5" class="' + fc('green') + ' nm-an-pulse"/>' +
		'<path d="M80 55c-7-6-7-15 0-21M106 55c7-6 7-15 0-21" fill="none" class="' + sc('cyan') +
			' nm-an-dash" stroke-width="2"/>',
		'responsive');
}

/* ---------------------------------------------------------------- 状态圆点（列表用） */

function dot(grade, size) {
	var s = size || 10;
	return '<svg class="nm-svg" width="' + s + '" height="' + s + '" viewBox="0 0 10 10" ' +
		'role="img" aria-label="' + esc(_('Status')) + '">' +
		'<circle cx="5" cy="5" r="4" class="' + fc(gradeColor(grade)) + '"/></svg>';
}

return Class.extend({
	__name__: 'NetMonitor.icons',

	/* 状态圆点与辅助 */
	dot: dot,
	gradeColor: gradeColor,

	/* 01 / 02 总体健康 */
	health: health,

	/* 03 – 08 探测与链路质量 */
	ping: ping,
	latencyDial: latencyDial,
	latency: latency,
	online: online,
	packetLoss: packetLoss,
	highLatency: highLatency,
	dnsFail: dnsFail,

	/* 09 – 12 区域与统计 */
	regionCN: regionCN,
	regionGlobal: regionGlobal,
	gradeGauge: gradeGauge,
	trend: trend,

	/* 13 – 18 运行状态与指标 */
	iface: iface,
	service: service,
	multiTarget: multiTarget,
	successRing: successRing,
	lossRing: lossRing,
	clock: clock,

	/* 19 – 24 功能入口与能力 */
	gear: gear,
	database: database,
	bell: bell,
	dualStack: dualStack,
	liveBars: liveBars,
	responsive: responsive
});
