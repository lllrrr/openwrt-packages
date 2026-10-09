/*
 * luci-app-netmonitor 前端公共模块
 *
 * 提供：RPC 封装、格式化、等级判定、卡片与迷你曲线渲染、样式注入、i18n 加载。
 * 所有页面共用，避免重复代码。
 *
 * UI 组件（按钮 / 标签 / 提示条 / 弹窗）由 ui.js 提供。
 * 本项目不再依赖 TDesign Web Components —— 原因见 ui.js 文件头的说明：
 * 随包分发的 tdesign.min.js 有7.3 MB，而实际只用到四个组件；且随包的
 * tdesign.css 是残缺样式表（578 个 CSS 变量齐全，dialog 规则 0 条），
 * 导致 t-dialog 的定位容器拿不到display 规则、编辑弹窗点了毫无反应。
 */

'use strict';
'require rpc';
'require ui';
'require uci';
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

/* ---------------------------------------------------------------- RPC */

/* ------------------------------------------------ 后端错误文案本地化
 *
 * rpcd 的 ucode 插件运行在 rpcd 进程里，没有 LuCI 的 i18n 运行时，因此后端
 * 只能用 err('invalid host') 这样的英文串回报。这里在前端唯一的出口 call()
 * 上做一次「英文原文 → 可翻译文案」的映射，各页面拿到的 e.message 就已经是
 * 本地化后的文本，不必每个调用点各写一遍。
 *
 * 映射表覆盖 root/usr/share/rpcd/ucode/luci.netmonitor 里全部 err() 字面量；
 * 没命中的串原样透出，便于定位后端新增但尚未登记的报错。 */
var BACKEND_MSG = {
	'invalid arguments': 'Invalid arguments',
	'invalid id': 'Invalid ID',
	'invalid ids': 'Invalid target selection',
	'invalid name': 'Invalid name',
	'invalid host': 'Invalid host',
	'invalid region': 'Invalid region',
	'invalid label': 'Invalid label',
	'invalid proto': 'Invalid protocol',
	'invalid family': 'Invalid address family',
	'invalid interface': 'Invalid interface',
	'invalid source': 'Invalid source address',
	'invalid remark': 'Invalid remark',
	'invalid direction': 'Invalid direction',
	'target not found': 'Target not found',
	'target id already exists': 'Target already exists',
	'cannot create section': 'Cannot create configuration section',
	'already at boundary': 'Already at the boundary'
};

/* 带参数的报错：后端拼成 'invalid value for <键名>'。
 * 用显式 prefix 而不是正则，是为了让 po/gen_po.py 能静态解析出这条
 * 前缀，从而把拼接式报错一并纳入漂移审计（正则字面量解析不出前缀）。 */
var BACKEND_MSG_ARG = [
	{ prefix: 'invalid value for ', msg: 'Invalid value for %s' }
];

function localizeError(msg) {
	var s = (msg == null) ? '' : String(msg);
	if (BACKEND_MSG[s])
		return _(BACKEND_MSG[s]);
	for (var i = 0; i < BACKEND_MSG_ARG.length; i++) {
		var p = BACKEND_MSG_ARG[i].prefix;
		if (s.indexOf(p) === 0)
			return _(BACKEND_MSG_ARG[i].msg).replace('%s', s.slice(p.length));
	}
	return s;
}

function call(method, params) {
	var keys = [];
	var args = [];
	if (params != null) {
		for (var k in params) {
			keys.push(k);
			args.push(params[k]);
		}
	}
	var fn = rpc.declare({
		object: 'luci.netmonitor',
		method: method,
		params: keys
	});
	return fn.apply(null, args).then(function(res) {
		if (res && res.error)
			throw new Error(localizeError(res.error));
		return res;
	});
}

/* rpcd 的 ucode 插件只接受字符串参数：传数组、数字或布尔字面量都会被拒绝
 * （Invalid argument）。因此这里把所有标量序列化为字符串，
 * 数组（如 ids）转成逗号分隔列表，布尔值转成 '1' / '0'。 */
function strParams(o) {
	var r = {};
	if (o == null) return r;
	for (var k in o) {
		var v = o[k];
		if (v == null) continue;
		if (v === true) v = '1';
		else if (v === false) v = '0';
		if (Object.prototype.toString.call(v) === '[object Array]')
			v = v.join(',');
		r[k] = (typeof v === 'object') ? v : String(v);
	}
	return r;
}

/* ---------------------------------------------------- 数值归一化
 *
 * 后端把延迟 / 丢包率等浮点字段以**字符串**返回（见 rpcd/ucode/luci.netmonitor
 * 的 fx()：ucode 的 blobmsg 序列化器对 double 一律输出 17 位有效数字，
 * 连字面量 26.51 都会变成 26.510000000000002，该限制在算式层面无解，
 * 只能在服务端 sprintf 成字符串）。
 *
 * 但字符串在 JS 里参与 `+` 会走**拼接**而非相加：
 *     sum += "18.96"        -> "0" + "18.96" = "018.96"
 *     sum += "25.3"         -> "018.9625.3"
 *     "018.9625.3" / 3      -> NaN
 * 实测后果（1.5.0 引入的回归）：
 *   · regions 页的分区平均曲线全部算成 NaN，path 变成
 *     `M42.0 NaN L61.4 NaN ...`，曲线完全不可见、Y 轴退化为 0~10；
 *   · charts 页「当前」摘要卡显示「—」（NaN）。
 * 注意 `/`、`*`、`-` 的隐式转换是正确的，所以只有**累加**会踩这个坑 ——
 * 这也解释了为何问题只在少数位置暴露、且不易一眼看出。
 *
 * 因此在 RPC 出口统一转成数值：所有消费方都拿到 number，
 * 不必每个调用点自己记得 parseFloat。
 */
/* 需要转数值的字段名。
 *
 * 注意 'l'（曲线点位的延迟）与 'latency'（目标当前延迟）是两个不同的键，
 * 分属 get_history 的 points 与 get_status 的 targets，必须都列上 ——
 * 首次修复时漏掉 'l'，曲线因此仍然算出 NaN。 */
var FLOAT_KEYS = ['l', 'avg', 'min', 'max', 'p50', 'p95', 'p99', 'loss', 'loss_avg',
	'success_rate', 'latency', 'current', 'online_rate', 'mn', 'mx', 'value'];

function numifyNode(o) {
	if (!o || typeof o !== 'object')
		return o;
	for (var i = 0; i < FLOAT_KEYS.length; i++) {
		var k = FLOAT_KEYS[i];
		if (o[k] != null)
			o[k] = toNum(o[k]);
	}
	return o;
}

/* get_history：series[].points[].{l,mn,mx} 与 series[].summary.* */
function numifyHistory(d) {
	if (!d || !d.series)
		return d;
	for (var i = 0; i < d.series.length; i++) {
		var se = d.series[i];
		if (se.summary)
			numifyNode(se.summary);
		if (se.points) {
			for (var j = 0; j < se.points.length; j++)
				numifyNode(se.points[j]);
		}
	}
	return d;
}

/* get_status：overall / regions / targets[]
 * （targets 与 regions 在下面按字段单独处理） */
function numifyStatus(d) {
	if (!d)
		return d;
	numifyNode(d.overall);
	if (d.regions) {
		for (var rk in d.regions)
			numifyNode(d.regions[rk]);
	}
	if (d.targets) {
		for (var i = 0; i < d.targets.length; i++) {
			var t = d.targets[i];
			numifyNode(t);
			if (t.spark) {
				for (var k = 0; k < t.spark.length; k++)
					t.spark[k] = toNum(t.spark[k]);
			}
		}
	}
	return d;
}

/* get_statistics：targets[] 与 regions[] */
function numifyStats(d) {
	if (!d)
		return d;
	var i;
	if (d.targets)
		for (i = 0; i < d.targets.length; i++)
			numifyNode(d.targets[i]);
	if (d.regions)
		for (i = 0; i < d.regions.length; i++)
			numifyNode(d.regions[i]);
	return d;
}

var api = {
	getStatus: function(withSpark) {
		return call('get_status', withSpark ? { spark: '1' } : {}).then(numifyStatus);
	},
	getTargets: function() { return call('get_targets', {}); },
	getHistory: function(o) {
		return call('get_history', strParams(o)).then(numifyHistory);
	},
	getStatistics: function(o) {
		return call('get_statistics', strParams(o)).then(numifyStats);
	},
	getConfig: function() { return call('get_config', {}); },
	/* 配置写入刻意不走后端 set_config / add_target：那些方法虽然也写
	 * 同一份 uci 配置，但自成一个没有提交/回滚/触发器语义的平行通道。
	 * 与两条通道并存，就会出现「界面已保存、系统未重载」这类难以定位的
	 * 差异（详见上方「UCI 事务」注释）。前端一律改用 saveConfig() /
	 * addSection() + applyChanges()，走 LuCI 原生「保存并应用」链路。
	 * 后端两个方法本身保持注册，仍可供 ubus CLI / 第三方脚本使用。 */
	updateTarget: function(o) { return call('update_target', strParams(o)); },
	deleteTarget: function(id) { return call('delete_target', { id: String(id) }); },
	moveTarget: function(id, dir) { return call('move_target', { id: String(id), direction: String(dir) }); },
	copyTarget: function(id) { return call('copy_target', { id: String(id) }); },
	batchTargets: function(ids, enabled) {
		var idstr = (Object.prototype.toString.call(ids) === '[object Array]') ? ids.join(',') : String(ids);
		return call('batch_targets', { ids: idstr, enabled: enabled ? '1' : '0' });
	},
	clearHistory: function(id) { return call('clear_history', id ? { id: String(id) } : {}); },
	serviceStatus: function() { return call('service_status', {}); },
	startService: function() { return call('start_service', {}); },
	stopService: function() { return call('stop_service', {}); },
	restartService: function() { return call('restart_service', {}); }
};

/* ------------------------------------------------------------ UCI 事务
 *
 * 所有配置写入都走 OpenWrt 原生链路（LuCI 的 uci 模块，底层就是 rpcd 的 uci
 * 对象），与 LuCI 自带页面完全一致：
 *
 *     uci.get / uci.set / uci.unset   比较现值、写入候选改动
 *     uci.save()            把候选改动推入 rpcd 会话的「待应用更改」
 *                           （此时只进会话，不落盘、不重载——实测
 *                            /etc/config/netmonitor 不会立刻变化）；
 *                           与设备现值一致的项会被跳过（见 saveConfig 注释）
 *
 * 提交（落盘 + 重载）一律由 applyChanges() 走 OpenWRT 官方机制完成，
 * 即 LuCI 自带「保存并应用」按钮背后的 ui.changes.apply()。
 *
 * 刻意不再经过插件私有的 set_config / add_target 等 RPC：那些方法虽然也是
 * 用 libuci 写同一份配置，但自成一个没有提交/回滚/触发器语义的平行通道，
 * 一旦两条通道并存，就会出现「界面已保存、系统未重载」这类难以定位的差异。
 */

/* 写入一批选项并推入「待应用更改」。
 * ops: [{ conf?, sid, opt, val }]，val 为 null 表示删除该选项。
 *
 * 返回值是「真正写下去的项数」：
 *   0 表示填的值与设备现状完全一致，此时不入会话、也不产生待应用改动，
 *   调用方据此直接跳过 applyChanges()。这一点很关键——没有待提交改动时
 *   rpcd 的 uci.apply 会直接报错（实测 ubus code 5: No data received），
 *   调用方若照常弹「保存失败」，用户看到的就是一条原始 RPC 报错；
 *   同时也能避免无意义的写 Flash。
 * 与 LuCI 自带页面一致：只写入与设备现值不同的项。
 *
 * 比较时把「选项不存在」与「空字符串」视为同一个状态：表单里清空的字段
 * 传上来就是 ''，而设备上该选项本来就不存在（uci.get 返回 null）。
 * 若按字面比较，这种情况会被算成一次改动，入会话后仍会走到 apply，
 * 于是又撞上同一条 NO_DATA 报错——实测就是这么暴露出来的。
 * 空值统一按「删除该选项」处理，配置文件里不会残留 option x ''。 */
function saveConfig(ops) {
	var conf = 'netmonitor';
	return uci.load(conf).then(function() {
		var changed = 0;

		for (var i = 0; i < ops.length; i++) {
			var o = ops[i];
			var c = o.conf || conf;
			var cur = uci.get(c, o.sid, o.opt);
			var want = (o.val == null) ? '' : String(o.val);
			var have = (cur == null) ? '' : String(cur);

			if (have === want)
				continue;

			if (want === '')
				uci.unset(c, o.sid, o.opt);
			else
				uci.set(c, o.sid, o.opt, want);
			changed++;
		}

		if (changed === 0)
			return 0;

		/* 只推入会话，不提交：提交交给 applyChanges()（官方机制）。
		 * uci.save() 之后 LuCI 自己的「未保存的更改: N」顶部指示器
		 * 会自动亮起（它监听 uci-loaded 事件并调 uci.changes()）。 */
		return uci.save().then(function() {
			return changed;
		});
	});
}

/* 新增一个 UCI 段、写入键值并推入「待应用更改」；resolve 新的段名。
 * 新段一定是有改动的，不需要像 saveConfig 那样先比对现值。 */
function addSection(conf, type, values) {
	var sid = null;
	return uci.load(conf).then(function() {
		sid = uci.add(conf, type);
		for (var k in values) {
			if (values[k] == null)
				continue;
			uci.set(conf, sid, k, String(values[k]));
		}
		return uci.save();
	}).then(function() {
		return sid;
	});
}

/* ------------------------------------------------------- 应用（官方机制）
 *
 * 提交「待应用更改」刻意复用 OpenWRT 自带的实现，而不是插件自己调
 * uci.apply()：ui.changes.apply(true) 就是 LuCI「保存并应用」按钮背后那一个
 * 函数，它 POST 到 /cgi-bin/luci/admin/uci/apply_rollback，服务端执行
 *     ubus call uci apply { rollback: true, timeout: max(cfg.apply.rollback, 90) }
 * 也就是说：提交配置 → /sbin/reload_config → procd 的 reload trigger
 * 触发 /etc/init.d/netmonitor reload（SIGHUP 原地重载守护进程）。
 *
 * 好处是连「应用」过程的交互也一并复用官方实现，插件不必自己造一套：
 *   * 应用期间显示官方的「正在应用配置更改… Ns」状态；
 *   * 改动涉及当前连接接口时，弹官方的连接性变更确认；
 *   * 应用后设备失联则在 90s 内自动回滚到上一份配置；
 *   * 成功后按 apply_display 秒重载页面，回到干净状态。
 *
 * 设备实测（targets 页，暂存 label 后点页面底部官方按钮）：
 *   /etc/config/netmonitor 出现该选项，日志出现
 *   "configuration reload requested" + "configuration reloaded"。
 *
 * 若官方机制不可用（例如无 sessionid 的精简环境），退回
 * uci.save() + uci.apply()，仍是同一条 ubus 链路、同样带回滚保护。 */
function applyChanges() {
	var hasOfficial = false;
	try {
		hasOfficial = (typeof ui !== 'undefined' && ui && ui.changes &&
			typeof ui.changes.apply === 'function' &&
			typeof L !== 'undefined' && L.env && L.env.sessionid);
	} catch (e) {
		hasOfficial = false;
	}

	if (hasOfficial)
		return Promise.resolve(ui.changes.apply(true));

	return uci.save().then(function() {
		return uci.apply();
	});
}

/* 撤回指定配置的全部待应用改动（标准 API：uci.revert）。
 * 与 LuCI 原生「放弃更改」语义一致；没有待应用改动时是空操作。
 * 用于设置页「放弃修改」：先把本页暂存的改动从会话中撤回，
 * 再复位表单，避免「表单已还原、底部原生栏仍显示待应用」的割裂状态。 */
function revertConfig(conf) {
	return uci.load(conf).then(function() {
		uci.revert(conf);
	});
}

/* ---------------------------------------------------------------- 格式化 */

/* 后端把延迟 / 丢包率等浮点字段以**已格式化的字符串**返回
 * （见 rpcd/ucode/luci.netmonitor 的 fx()：ucode 的 blobmsg 序列化器对
 * double 一律输出 17 位有效数字，字面量 26.51 也会变成 26.510000000000002，
 * 该限制在算式层面无法消除，只能在传输前就固化成字符串）。
 *
 * 这里统一先转成 number 再做展示运算，保证：
 *   - 空值（后端给 null）与非法值统一显示为占位符；
 *   - 后续的算术与比较（>、+）走数值语义而非字符串拼接。
 */
function toNum(v) {
	if (v == null || v === '')
		return null;
	var n = parseFloat(v);
	return isNaN(n) ? null : n;
}

function num(v, digits) {
	var n = toNum(v);
	if (n == null) return '—';
	var p = Math.pow(10, digits == null ? 1 : digits);
	return String(Math.round(n * p) / p);
}

function latency(v) {
	var n = toNum(v);
	if (n == null) return '—';
	if (n >= 100) return String(Math.round(n));
	return String(Math.round(n * 10) / 10);
}

function percent(v, digits) {
	var n = toNum(v);
	if (n == null) return '—';
	var p = Math.pow(10, digits == null ? 1 : digits);
	return (Math.round(n * p) / p) + '%';
}

function pad2(x) { return (x < 10 ? '0' : '') + x; }

function clockOf(ts) {
	if (!ts) return '—';
	var d = new Date(ts * 1000);
	return pad2(d.getHours()) + ':' + pad2(d.getMinutes()) + ':' + pad2(d.getSeconds());
}

function dateTimeOf(ts) {
	if (!ts) return '—';
	var d = new Date(ts * 1000);
	return (d.getMonth() + 1) + '/' + d.getDate() + ' ' + pad2(d.getHours()) + ':' + pad2(d.getMinutes());
}

function ago(ts) {
	if (!ts) return _('Never checked');
	var d = Math.floor(Date.now() / 1000) - ts;
	if (d < 0) d = 0;
	if (d < 5) return _('Just now');
	if (d < 60) return _('%d seconds ago').replace('%d', d);
	if (d < 3600) return _('%d minutes ago').replace('%d', Math.floor(d / 60));
	if (d < 86400) return _('%d hours ago').replace('%d', Math.floor(d / 3600));
	return _('%d days ago').replace('%d', Math.floor(d / 86400));
}

/* ---------------------------------------------------------------- 等级 */

var GRADE_CLASS = {
	excellent: 'ok',
	good: 'ok',
	fair: 'warn',
	poor: 'poor',
	severe: 'bad',
	down: 'bad',
	disabled: 'idle',
	unknown: 'idle'
};

var GRADE_TEXT = {
	excellent: 'Excellent',
	good: 'Good',
	fair: 'Fair',
	poor: 'Poor',
	severe: 'Severe',
	down: 'Offline',
	disabled: 'Disabled',
	unknown: 'Unknown'
};

function gradeClass(g) {
	return 'nm-c-' + (GRADE_CLASS[g] || 'idle');
}

function gradeText(g) {
	return _(GRADE_TEXT[g] || 'Unknown');
}

function dotClass(g) {
	return 'nm-dot nm-dot-' + (GRADE_CLASS[g] || 'idle');
}

function regionText(r) {
	if (r === 'cn') return _('China');
	if (r === 'overseas') return _('Overseas');
	return _('Other');
}

function regionTagClass(r) {
	if (r === 'cn') return 'nm-tag nm-tag-cn';
	if (r === 'overseas') return 'nm-tag nm-tag-overseas';
	return 'nm-tag nm-tag-other';
}

function errorText(e) {
	switch (e) {
		case 'timeout': return _('Timeout');
		case 'dns': return _('DNS resolve failed');
		case 'unreachable': return _('Network unreachable');
		case 'invalid': return _('Invalid target');
		case 'error': return _('Check failed');
	}
	return '';
}

/* ---------------------------------------------------------------- 弹窗 */

/* 确认弹窗。转调 ui.js 的 confirm()，这里只补文案默认值。
 *
 * 此前本文件另有一份基于 <t-dialog> 的完整实现，与 targets.js 的编辑弹窗
 * 脚手架逐行重复（属性名、footer slot、ESC 兜底、focus 收尾各写一遍），
 * 现已统一到 ui.dialog 一处。
 *
 * message 以 textContent 填充：用户自填的目标名不会被当作 HTML 解析。
 * 取消 / ESC / 点遮罩 / 关闭按钮都只是关闭弹窗，不产生错误。 */
function confirmDialog(opts) {
	opts = opts || {};
	nmui.confirm({
		host: opts.host,
		header: opts.header,
		message: opts.message == null ? '' : String(opts.message),
		ok: opts.ok,
		cancel: opts.cancel,
		danger: !!opts.danger
	});
}


/* ---------------------------------------------------------------- DOM 辅助 */

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
	head.appendChild(el('span', dotClass(t.grade), ''));
	var nm = el('div', '', '');
	nm.style.minWidth = '0';
	nm.style.flex = '1 1 auto';
	nm.appendChild(el('div', 'nm-target-name', t.name ? t.name : t.id));
	nm.appendChild(el('div', 'nm-target-host', (t.host || '') + (t.last_error ? ' · ' + errorText(t.last_error) : '')));
	head.appendChild(nm);
	head.appendChild(el('span', regionTagClass(t.region), t.label ? t.label : regionText(t.region)));
	/* 动态状态图标：在线时旋转虚线环 + 脉冲点；离线时静止的灰色环。
	 * 与 dotClass() 的纯色圆点不同，它同时表达「是否在流动」的状态。 */
	head.appendChild(inlineIcon(icons.online(26, t.enabled && t.status === 'online')));
	card.appendChild(head);

	var lat = el('div', 'nm-target-latency');
	lat.appendChild(el('span', 'nm-latency-num ' + gradeClass(t.grade), latency(t.latency)));
	lat.appendChild(el('span', 'nm-latency-unit', 'ms'));
	lat.appendChild(el('span', 'nm-latency-note', gradeText(t.grade)));
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
		rings.appendChild(ring(icons.lossRing(t.loss, 44), _('Loss'), percent(t.loss, 1),
			t.loss > 5 ? 'nm-c-bad' : (t.loss > 0 ? 'nm-c-warn' : 'nm-c-ok')));
		rings.appendChild(ring(icons.successRing(t.success_rate, 44), _('Availability'), percent(t.success_rate, 0),
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
	metrics.appendChild(metric(_('Avg'), latency(t.avg) + ' ms'));
	metrics.appendChild(metric(_('P95'), latency(t.p95) + ' ms'));
	metrics.appendChild(metric(_('Loss'), percent(t.loss)));
	metrics.appendChild(metric(_('Availability'), percent(t.success_rate, 0)));
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

/* LuCI 的模块加载器要求每个模块导出一个 Class（Class.isSubclass 校验），
 * 这里使用 Class.singleton，页面可以直接以 common.xxx() 形式调用。 */
return Class.extend({
	__name__: 'NetMonitor.common',

	css: ensureCss,
	loadI18n: loadI18n,
	api: api,
	call: call,
	saveConfig: saveConfig,
	addSection: addSection,
	applyChanges: applyChanges,
	revertConfig: revertConfig,
	fmt: {
		num: num,
		latency: latency,
		percent: percent,
		clock: clockOf,
		dateTime: dateTimeOf,
		ago: ago
	},
	/* 后端浮点字段以字符串返回，算术/比较前必须先过这道转换 */
	toNum: toNum,
	gradeClass: gradeClass,
	gradeText: gradeText,
	dotClass: dotClass,
	regionText: regionText,
	regionTagClass: regionTagClass,
	errorText: errorText,
	localizeError: localizeError,
	el: el,
	elHtml: elHtml,
	svgBox: svgBox,
	tcard: tcard,
	cardIcon: cardIcon,
	inlineIcon: inlineIcon,
	confirmDialog: confirmDialog,
	icons: icons,
	clear: clear,
	notify: notify,
	sparkline: sparkline,
	targetCard: targetCard,
	kpiCard: kpiCard,
	iconCard: iconCard,
	banner: banner,
	/* 原生UI 组件：按钮 / 标签 / 提示条 / 弹窗。页面直接 common.ui.button(...)
	 * 即可，无需各自 require ui.js。 */
	ui: nmui,
	palette: ['#2f6fed', '#2e9e5b', '#8a63d2', '#e0762c', '#00a3b4', '#d69a1a', '#cf4437', '#5c6b7a']
});
