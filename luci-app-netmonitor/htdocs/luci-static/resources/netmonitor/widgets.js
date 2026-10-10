/*
 * luci-app-netmonitor 业务组件层
 *
 * 职责边界（本模块**只管把数据画成 DOM**，不发起任何网络请求）：
 *   卡片 / 图标容器 / 横幅 / 迷你曲线   targetCard / kpiCard / iconCard / banner / sparkline
 *   DOM 小工具与全局通知               clear / notify / svgBox / cardIcon / inlineIcon
 *
 * 依赖方向严格单向：widgets → {ui, icons, format}。
 * 反向依赖（数据层引用组件层）是被禁止的，api.js 因此可以独立测试。
 *
 * 与 ui.js 的分工：
 *   ui.js      通用控件原语，不含本项目业务语义（button / chip / alert / dialog / confirm）
 *   widgets.js 本项目的业务卡片，认识 target / grade / region / spark 这些领域概念
 * 两者不互相 require，页面需要时各自取用。
 */

'use strict';
'require ui';
'require netmonitor.ui as nmui';
'require netmonitor.icons as icons';
'require netmonitor.format as fmt';

/* ---------------------------------------------------------------- DOM 辅助 */

/* 统一走 ui.js 的实现：那里对第三个参数走 textContent 而非 innerHTML，
 * 页面里大量展示用户自填的 name / host / label / remark，
 * 用 innerHTML 拼接等于给了存储型 XSS —— LuCI 会话等价于 root 权限。 */
function el(tag, cls, text) {
	return nmui.el(tag, cls, text);
}

/* 需要插入 HTML 时显式调用，让「哪里有 innerHTML」一目了然。 */
function elHtml(tag, cls, html) {
	return nmui.elHtml(tag, cls, html);
}

/* SVG 片段容器：内容来自本项目自带的 icons.js / chart.js，
 * 均为内置常量字符串，不含用户输入，故可安全走 innerHTML。 */
function svgBox(svg, cls) {
	return nmui.elHtml('div', cls, svg);
}

/* 把一个动态 SVG 挂到卡片的右上角。
 * 使用绝对定位，不参与文档流，因此不会因为图标尺寸影响卡片内的排版。 */
function cardIcon(card, svg) {
	var box = el('div', 'nm-card-icon');
	box.innerHTML = svg;
	card.appendChild(box);
	return card;
}

/* 行内小图标（表格单元格、状态行使用） */
function inlineIcon(svg) {
	return svgBox(svg, 'nm-inline-icon');
}

function clear(node) {
	while (node && node.firstChild)
		node.removeChild(node.firstChild);
}

/* 全局通知条。用 LuCI 原生 ui.addNotification，与系统其他页面观感一致；
 * 在脱离 LuCI 环境的场景下（单测 / 预览页）降级为 console，不抛异常。 */
function notify(msg, type) {
	try {
		ui.addNotification(null, E('p', {}, msg), type || 'info');
	} catch (e) {
		if (window.console && console.log) console.log('[netmonitor] ' + msg);
	}
}

/* 迷你延迟曲线（SVG，无文本，可安全横向拉伸） */
function sparkline(values, color, height) {
	var h = height || 46;
	var w = 100;
	var pts = [];
	var max = 0;
	for (var i = 0; i < values.length; i++) {
		if (values[i] != null) {
			pts.push(values[i]);
			if (values[i] > max) max = values[i];
		} else {
			pts.push(null);
		}
	}
	if (max <= 0) max = 10;
	var yMax = max * 1.2;

	var d = '', area = '', started = false, lastX = 0;
	for (var j = 0; j < pts.length; j++) {
		var x = (pts.length > 1) ? (j / (pts.length - 1)) * w : 0;
		if (pts[j] == null) { started = false; continue; }
		var y = h - (pts[j] / yMax) * (h - 4) - 2;
		if (!started) {
			d += (d ? ' M' : 'M') + x.toFixed(2) + ' ' + y.toFixed(2);
			area += (area ? ' L' : 'M') + x.toFixed(2) + ' ' + h + ' L' + x.toFixed(2) + ' ' + y.toFixed(2);
			started = true;
		} else {
			d += ' L' + x.toFixed(2) + ' ' + y.toFixed(2);
			area += ' L' + x.toFixed(2) + ' ' + y.toFixed(2);
		}
		lastX = x;
	}

	var col = color || '#2f6fed';
	var svg = '<svg class="nm-spark" viewBox="0 0 ' + w + ' ' + h + '" preserveAspectRatio="none" role="img">';
	if (area)
		svg += '<path d="' + area + ' L' + lastX.toFixed(2) + ' ' + h + ' Z" fill="' + col + '" fill-opacity="0.12"/>';
	if (d)
		svg += '<path d="' + d + '" fill="none" stroke="' + col + '" stroke-width="1.4" vector-effect="non-scaling-stroke" stroke-linejoin="round"/>';
	svg += '</svg>';
	return svg;
}

/* 延迟卡片：名称 / 区域 / 当前延迟 / 等级 / 指标 / 迷你曲线 */
function targetCard(t, opts) {
	opts = opts || {};
	var card = el('div', 'nm-target' + (t.enabled ? '' : ' is-disabled'));
	var head = el('div', 'nm-target-head');
	head.appendChild(el('span', fmt.dotClass(t.grade), ''));
	var nm = el('div', '', '');
	nm.style.minWidth = '0';
	nm.style.flex = '1 1 auto';
	nm.appendChild(el('div', 'nm-target-name', t.name ? t.name : t.id));
	nm.appendChild(el('div', 'nm-target-host', (t.host || '') + (t.last_error ? ' · ' + fmt.errorText(t.last_error) : '')));
	head.appendChild(nm);
	head.appendChild(el('span', fmt.regionTagClass(t.region), t.label ? t.label : fmt.regionText(t.region)));
	/* 动态状态图标：在线时旋转虚线环 + 脉冲点；离线时静止的灰色环。
	 * 与 dotClass() 的纯色圆点不同，它同时表达「是否在流动」的状态。 */
	head.appendChild(inlineIcon(icons.online(26, t.enabled && t.status === 'online')));
	card.appendChild(head);

	var lat = el('div', 'nm-target-latency');
	lat.appendChild(el('span', 'nm-latency-num ' + fmt.gradeClass(t.grade), fmt.latency(t.latency)));
	lat.appendChild(el('span', 'nm-latency-unit', 'ms'));
	lat.appendChild(el('span', 'nm-latency-note', fmt.gradeText(t.grade)));
	card.appendChild(lat);

	/* 环形指标：丢包率与成功率的弧长直接由真实百分比换算，
	 * 不是固定长度的装饰圆环。 */
	if (opts.rings !== false) {
		var rings = el('div', 'nm-target-rings');
		function ring(svg, label, value, cls) {
			var box = el('div', 'nm-ring-item');
			box.appendChild(svgBox(svg, 'nm-ring-svg'));
			var txt = el('div', 'nm-ring-text');
			txt.appendChild(el('b', cls || '', value));
			txt.appendChild(el('span', '', label));
			box.appendChild(txt);
			return box;
		}
		rings.appendChild(ring(icons.lossRing(t.loss, 44), _('Loss'), fmt.percent(t.loss, 1),
			t.loss > 5 ? 'nm-c-bad' : (t.loss > 0 ? 'nm-c-warn' : 'nm-c-ok')));
		rings.appendChild(ring(icons.successRing(t.success_rate, 44), _('Availability'), fmt.percent(t.success_rate, 0),
			t.success_rate >= 99 ? 'nm-c-ok' : (t.success_rate >= 95 ? 'nm-c-warn' : 'nm-c-bad')));
		card.appendChild(rings);
	}

	var metrics = el('div', 'nm-target-metrics');
	function metric(label, value) {
		var m = el('div', 'nm-metric');
		m.appendChild(el('span', '', label));
		m.appendChild(el('b', '', value));
		return m;
	}
	metrics.appendChild(metric(_('Avg'), fmt.latency(t.avg) + ' ms'));
	metrics.appendChild(metric(_('P95'), fmt.latency(t.p95) + ' ms'));
	metrics.appendChild(metric(_('Loss'), fmt.percent(t.loss)));
	metrics.appendChild(metric(_('Availability'), fmt.percent(t.success_rate, 0)));
	card.appendChild(metrics);

	if (opts.spark !== false && t.spark && t.spark.length)
		card.appendChild(svgBox(sparkline(t.spark, 'var(--nm-accent, #2f6fed)'), ''));

	return card;
}

/* 顶部 KPI 小卡；可选在右上角挂一个与数值同源的动态图标 */
function kpiCard(title, value, sub, cls, iconSvg) {
	var c = el('div', 'nm-card');
	c.appendChild(el('div', 'nm-card-title', title));
	c.appendChild(el('div', 'nm-card-value ' + (cls || ''), value));
	if (sub) c.appendChild(el('div', 'nm-card-sub', sub));
	if (iconSvg) cardIcon(c, iconSvg);
	return c;
}

/* 图标 + 实时数值 的一体卡片：图标挂在左侧，右侧为标题 / 数值 / 说明。
 * 用于把「图标对应的功能」和「该功能的真实读数」放在一起。 */
function iconCard(title, value, sub, svg, valueCls) {
	var c = el('div', 'nm-card nm-icon-card');
	var ico = svgBox(svg, 'nm-icon-card-svg');
	c.appendChild(ico);
	var body = el('div', 'nm-icon-card-body');
	body.appendChild(el('div', 'nm-card-title', title));
	body.appendChild(el('div', 'nm-card-value ' + (valueCls || ''), value));
	if (sub) body.appendChild(el('div', 'nm-card-sub', sub));
	c.appendChild(body);
	return c;
}

/* TDesign 视觉卡片容器（普通 div，替代 <t-card>）。
 *
 * 为什么不直接用 <t-card>：t-card 在 shadow DOM 里克隆 light DOM 内容，
 * 外部样式表（.nm-* 布局类）无法穿透 shadow 边界，卡片内部 flex/grid/
 * 宽度全部失效（实测 .nm-card-inner 退化为 block、图例粘连、输入框零宽）。
 * 这里用 div + TDesign CSS 变量复刻 t-card 的视觉（背景 / 边框 / 圆角 /
 * 内边距），布局样式照常生效；页面交互组件（按钮 / 开关 / 选择 / 输入 /
 * 弹窗）仍为 <t-*>。 */
function tcard(extraCls) {
	var c = el('div', 'nm-tcard');
	if (extraCls) c.classList.add(extraCls);
	return c;
}

/* 统一的状态横幅（服务未运行 / 数据不足 等） */
function banner(msg, kind) {
	var b = el('div', 'nm-card');
	b.style.borderColor = (kind === 'warn') ? 'rgba(214,154,26,.45)' : 'var(--nm-border)';
	b.style.display = 'flex';
	b.style.alignItems = 'center';
	b.style.gap = '10px';
	b.appendChild(el('span', 'nm-dot ' + (kind === 'warn' ? 'nm-dot-warn' : 'nm-dot-idle'), ''));
	b.appendChild(el('div', '', msg));
	return b;
}

/* LuCI 的模块加载器要求每个模块导出一个 Class（Class.isSubclass 校验）。 */
return Class.extend({
	__name__: 'NetMonitor.widgets',

	el: el,
	elHtml: elHtml,
	svgBox: svgBox,
	cardIcon: cardIcon,
	inlineIcon: inlineIcon,
	tcard: tcard,

	clear: clear,
	notify: notify,
	sparkline: sparkline,

	targetCard: targetCard,
	kpiCard: kpiCard,
	iconCard: iconCard,
	banner: banner
});
