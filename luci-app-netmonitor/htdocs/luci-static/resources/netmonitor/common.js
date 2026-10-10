/*
 * luci-app-netmonitor 前端公共模块（聚合层）
 *
 * 【本文件现在只做两件事】
 *   1. 资源加载：样式表注入 ensureCss() 与插件 i18n domain 加载 loadI18n()；
 *   2. 向后兼容：把历史上堆在这里的导出逐项转发到拆分后的专职模块。
 *
 * 【为什么拆】
 * 本文件曾是一个 809 行的「上帝模块」，同时装着六类职责：
 *   资源加载 · RPC 调用 · UCI 事务 · 数值格式化 · DOM 转发 · 业务卡片组件。
 * 结果是改任何一类都要动同一个文件，且无法单独测试。现按职责边界拆为：
 *
 *   format.js   纯函数层   数值→文本、状态→类名/文案、后端报错→可翻译文案
 *                          （不 require 任何东西，不碰 DOM）
 *   api.js      数据访问层 RPC 调用、字符串数值归一化、UCI 读改写与提交
 *                          （依赖 rpc / uci / format，不碰展示层）
 *   widgets.js  业务组件层 目标卡片 / KPI 卡 / 图标卡 / 横幅 / 迷你曲线
 *                          （依赖 ui / icons / format，不发任何请求）
 *   ui.js       控件原语层 按钮 / 标签 / 提示条 / 弹窗 / 确认框（无业务语义）
 *   icons.js    图标层     动态 SVG，状态驱动
 *   chart.js    图表层     折线 / 柱状 / 环形，含配色 palette
 *
 * 依赖方向严格单向，无环：
 *   view/*.js → common ┐
 *                      ├→ widgets → {ui, icons, format}
 *                      ├→ api     → {rpc, uci, format}
 *                      ├→ chart
 *                      └→ icons / ui
 *
 * 【迁移约定】
 * 新代码请直接 require 专职模块，不要再经由 common 转发；
 * 本文件保留的转发项仅为让既有页面零改动，随页面迁移逐项退场。
 *
 * UI 组件（按钮 / 标签 / 提示条 / 弹窗）由 ui.js 提供。
 * 本项目不再依赖 TDesign Web Components —— 原因见 ui.js 文件头的说明：
 * 随包分发的 tdesign.min.js 有7.3 MB，而实际只用到四个组件；且随包的
 * tdesign.css 是残缺样式表（578 个 CSS 变量齐全，dialog 规则 0 条），
 * 导致 t-dialog 的定位容器拿不到display 规则、编辑弹窗点了毫无反应。
 */

'use strict';
'require netmonitor.api as nmapi';
'require netmonitor.format as nfmt';
'require netmonitor.widgets as nmw';
'require netmonitor.icons as icons';
'require netmonitor.ui as nmui';

var CSS_ID = 'nm-netmonitor-css';
var I18N_DOMAIN = 'luci-app-netmonitor';

/* ---------------------------------------------------------------- 资源 */

function resourceUrl(path) {
	if (typeof L !== 'undefined' && L && L.resource)
		return L.resource(path);
	return '/luci-static/resources/' + path;
}

/* 样式表注入。
 *
 * 这是图标能显示的关键前提：icons.js 的颜色由本样式表的 .nm-str-* /
 * .nm-fill-* 提供。若注入失败（CSP、路径错、加载竞态），图标会退回
 * icons.js 里写在 <svg> 根元素上的 stroke/fill="currentColor" 兜底色，
 * 仍然可见、仍然能表达状态，只是失去分级配色。 */
function ensureCss() {
	if (document.getElementById(CSS_ID))
		return;
	var link = document.createElement('link');
	link.id = CSS_ID;
	link.rel = 'stylesheet';
	link.type = 'text/css';
	link.href = resourceUrl('netmonitor/style.css');
	document.head.appendChild(link);
}

/* 加载插件自己的 i18n domain。
 *
 * 不能无条件 L.require('i18n')：LuCI 的 i18n 模块在部分精简固件里并未安装
 * （/www/luci-static/resources/i18n.js 不存在），require 会产生一个 404 请求，
 * 而这个网络层错误无法用 catch 消除，会一直出现在浏览器控制台。
 *
 * 因此这里只在 LuCI 已注册 i18n 能力时才调用，否则交给 LuCI 自身的服务端
 * 翻译机制（_() 由页面注入的翻译表提供），不额外发起请求。 */
function loadI18n() {
	try {
		if (typeof L === 'undefined')
			return Promise.resolve(null);
		var m = L.i18n;
		if (m && typeof m.load === 'function')
			return Promise.resolve(m.load(I18N_DOMAIN));
	} catch (e) {
		/* 忽略：翻译不可用不影响功能 */
	}
	return Promise.resolve(null);
}

/* LuCI 的模块加载器要求每个模块导出一个 Class（Class.isSubclass 校验），
 * 这里用 Class.extend（与项目其余模块一致；README 开发约定禁止 Class.singleton，
 * 其返回的静态实例会触发 factory yields invalid constructor），
 * 页面可以直接以 common.xxx() 形式调用。 */
return Class.extend({
	__name__: 'NetMonitor.common',

	/* ---- 资源加载：本文件自有的唯一实质职责 ---- */
	css: ensureCss,
	loadI18n: loadI18n,

	/* ---- 数据访问：转发 api.js ---- */
	api: nmapi.api,
	call: nmapi.call,
	saveConfig: nmapi.saveConfig,
	addSection: nmapi.addSection,
	applyChanges: nmapi.applyChanges,
	revertConfig: nmapi.revertConfig,

	/* ---- 格式化与语义映射：转发 format.js ---- */
	fmt: nfmt.fmt,
	/* 后端浮点字段以字符串返回，算术/比较前必须先过这道转换 */
	toNum: nfmt.toNum,
	gradeClass: nfmt.gradeClass,
	gradeText: nfmt.gradeText,
	dotClass: nfmt.dotClass,
	regionText: nfmt.regionText,
	regionTagClass: nfmt.regionTagClass,
	errorText: nfmt.errorText,
	localizeError: nfmt.localizeError,

	/* ---- 业务组件：转发 widgets.js ---- */
	el: nmw.el,
	elHtml: nmw.elHtml,
	svgBox: nmw.svgBox,
	tcard: nmw.tcard,
	cardIcon: nmw.cardIcon,
	inlineIcon: nmw.inlineIcon,
	clear: nmw.clear,
	notify: nmw.notify,
	sparkline: nmw.sparkline,
	targetCard: nmw.targetCard,
	kpiCard: nmw.kpiCard,
	iconCard: nmw.iconCard,
	banner: nmw.banner,

	/* ---- 展示层聚合引用 ---- */
	icons: icons,
	/* 原生 UI 组件：按钮 / 标签 / 提示条 / 弹窗。页面直接 common.ui.button(...)
	 * 即可，无需各自 require ui.js。 */
	ui: nmui,
	/* 确认弹窗。此前本文件另有一份完整实现，与 ui.js 的 confirm() 重复；
	 * 且经全仓检索确认**零调用点**（页面一律用 common.ui.confirm），
	 * 故此处不再保留实现，直接指向 ui.confirm —— 消除双实现与死代码。 */
	confirmDialog: nmui.confirm

	/* 注意：配色 palette 已不再由本文件导出。
	 * 它此前是 chart.js 中 PALETTE 的一份硬编码副本（逐字节相同），
	 * 属于典型的双真源——改一处漏另一处就会让图例与曲线配色错位。
	 * 现统一取 chart.palette；charts.js / history.js 本就 require chart，
	 * 无需经由 common 再绕一层（否则会让所有页面都多加载一个图表模块）。 */
});
