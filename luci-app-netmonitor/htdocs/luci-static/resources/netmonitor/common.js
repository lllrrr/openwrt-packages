/*
 * luci-app-netmonitor 前端公共模块
 *
 * 提供：RPC 封装、格式化、等级判定、卡片与迷你曲线渲染、样式注入、i18n 加载。
 * 所有页面共用，避免重复代码。
 */

'use strict';
'require rpc';
'require ui';
'require uci';
'require netmonitor.icons as icons';

var CSS_ID = 'nm-netmonitor-css';
var TD_CSS_ID = 'nm-tdesign-css';
var TD_JS_ID = 'nm-tdesign-js';
var I18N_DOMAIN = 'luci-app-netmonitor';
var _tdReady = null;

function resourceUrl(path) {
	if (typeof L !== 'undefined' && L && L.resource)
		return L.resource(path);
	return '/luci-static/resources/' + path;
}

/* ---------------------------------------------------------------- 资源 */

function ensureCss() {
	if (document.getElementById(CSS_ID))
		return;
	var link = document.createElement('link');
	link.id = CSS_ID;
	link.rel = 'stylesheet';
	link.type = 'text/css';
	link.href = resourceUrl('netmonitor/style.css');
	document.head.appendChild(link);
	/* TDesign 组件样式：只注入一次，与业务样式分开便于后续升级替换 */
	if (!document.getElementById(TD_CSS_ID)) {
		var td = document.createElement('link');
		td.id = TD_CSS_ID;
		td.rel = 'stylesheet';
		td.type = 'text/css';
		td.href = resourceUrl('netmonitor/tdesign/tdesign.css');
		document.head.appendChild(td);
	}
}

/* 动态加载 TDesign Web Components 库（UMD，全局注册 <t-*> 自定义元素）。
 *
 * 返回 Promise，resolve 后组件树已可用。加载过程只发生一次（_tdReady 缓存）；
 * 失败时清空缓存并 reject，便于页面在 render 阶段降级或提示。
 *
 * 注意：LuCI 的 require 体系不支持动态 import / ESM，因此这里用经典的
 * <script> 注入方式挂载 UMD 构建，组件库自己负责注册 custom elements。 */
function tdesign() {
	if (_tdReady)
		return _tdReady;
	_tdReady = new Promise(function(resolve, reject) {
		if (window.customElements &&
			typeof window.customElements.get('t-button') !== 'undefined') {
			resolve();
			return;
		}
		injectTDesign(resolve, reject, 0);
	});
	return _tdReady;
}

/* 注入 tdesign.min.js。外部 <script src> 的 load 事件在「下载 + 执行完成」后
 * 触发——即使脚本执行过程中抛错也会触发（实测），因此仅靠 onload 判断成功
 * 会把「执行失败、组件未注册」误判为加载成功，导致页面带着一堆裸 <t-*> 标签
 * 渲染（开关 / 下拉 / 按钮全部无样式无交互）。这里必须在 onload 后校验组件
 * 是否真的注册（customElements.get('t-button')），未注册按失败处理：重试一次
 * （移除旧节点后重新注入，排除偶发失败），仍失败才 reject，不再假装成功。 */
function injectTDesign(resolve, reject, attempt) {
	var s = document.createElement('script');
	s.id = TD_JS_ID;
	s.src = resourceUrl('netmonitor/tdesign/tdesign.min.js');
	s.onload = function() {
		if (window.customElements &&
			typeof window.customElements.get('t-button') !== 'undefined') {
			resolve();
			return;
		}
		if (attempt === 0) {
			_tdReady = null; /* 清掉失败缓存，允许重试 */
			var old = document.getElementById(TD_JS_ID);
			if (old && old.parentNode)
				old.parentNode.removeChild(old);
			injectTDesign(resolve, reject, 1);
			return;
		}
		reject(new Error('TDesign loaded but components not registered'));
	};
	s.onerror = function() {
		_tdReady = null;
		reject(new Error('TDesign library failed to load'));
	};
	document.head.appendChild(s);
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

var api = {
	getStatus: function(withSpark) {
		return call('get_status', withSpark ? { spark: '1' } : {});
	},
	getTargets: function() { return call('get_targets', {}); },
	getHistory: function(o) { return call('get_history', strParams(o)); },
	getStatistics: function(o) { return call('get_statistics', strParams(o)); },
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

function num(v, digits) {
	if (v == null || isNaN(v)) return '—';
	var p = Math.pow(10, digits == null ? 1 : digits);
	return String(Math.round(v * p) / p);
}

function latency(v) {
	if (v == null || isNaN(v)) return '—';
	if (v >= 100) return String(Math.round(v));
	return String(Math.round(v * 10) / 10);
}

function percent(v, digits) {
	if (v == null || isNaN(v)) return '—';
	var p = Math.pow(10, digits == null ? 1 : digits);
	return (Math.round(v * p) / p) + '%';
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

/* TDesign 确认弹窗：替换 window.confirm。
 *
 * 为什么不用原生 confirm：它是阻塞式同步调用，会冻结整个主线程，在低端
 * 路由器的 LuCI 页面上表现为点一下「删除」后整页无响应数百毫秒；且样式
 * 完全由浏览器决定，与本插件的 TDesign 视觉体系割裂。
 *
 * 事件与属性契约（逐条核对随包 tdesign.min.js 的 propTypes 后确定，勿凭印象改）：
 *   · 关闭出口只有一个 close 事件，由内部 onClose({ e, trigger }) 派发，
     trigger 取值为 'confirm' | 'cancel' | 'overlay' | 'esc'。
     —— 组件没有 visible-change 事件，早期误用会导致弹窗关不掉。
 *   · ESC 开关的属性名是 closeOnEscKeydown，不是 closeOnEsc。
 *   · footer 传 true 时按钮由组件自行生成，此时 confirmBtn / cancelBtn
     这两个 prop 并未在 t-dialog 的 propTypes 中声明（那是 popconfirm 的），
     设了也不生效。因此这里与 targets.js 的编辑弹窗保持一致，改用
     footer slot 自带按钮 —— 走的是组件明确支持的渲染路径。
 *
 * 返回 Promise<boolean>：确认 resolve(true)，取消/ESC/点遮罩 resolve(false)。
 * 调用方无需 try/catch —— 用户主动取消不是错误。 */
function confirmDialog(opts) {
	opts = opts || {};
	return tdesign().then(function() {
		return new Promise(function(resolve) {
			var settled = false;
			function done(v) {
				if (settled) return;
				settled = true;
				/* 解除 keydown 监听后再移除节点，避免关闭瞬间的 ESC
				 * 把焦点抢回一个已经离场的元素。 */
				document.removeEventListener('keydown', onKey, true);
				try { modal.visible = false; } catch (e) { /* 组件已卸载 */ }
				if (modal.parentNode) modal.parentNode.removeChild(modal);
				resolve(v);
			}
			/* 兜底：焦点在 shadow 外时组件可能收不到 ESC，这里在 capture
			 * 阶段拦一道。注意只在弹窗仍在文档中时处理。 */
			function onKey(e) {
				if (e.key === 'Escape' && modal.isConnected) {
					e.stopPropagation();
					done(false);
				}
			}

			var modal = document.createElement('t-dialog');
			modal.setAttribute('header', opts.header || _('Confirm'));
			modal.setAttribute('width', 'min(420px, calc(100vw - 32px))');
			/* 自带关闭按钮 + ESC 关闭，属性名必须是 closeOnEscKeydown */
			modal.setAttribute('closeOnEscKeydown', 'true');
			modal.setAttribute('closeOnOverlayClick', 'true');
			/* 自行提供 footer，故关掉组件默认 footer */
			modal.setAttribute('footer', 'false');
			modal.visible = true;
			/* 弹窗同样需要焦点落点，否则打开后焦点仍在背后的页面上 */
			modal.setAttribute('tabindex', '-1');

			modal.appendChild(el('div', 'nm-confirm-body', opts.message || ''));

			var footer = el('div', 'nm-modal-actions');
			var btnCancel = document.createElement('t-button');
			btnCancel.setAttribute('theme', 'default');
			btnCancel.setAttribute('variant', 'outline');
			btnCancel.textContent = opts.cancel || _('Cancel');
			btnCancel.addEventListener('click', function() { done(false); });

			var btnOk = document.createElement('t-button');
			btnOk.setAttribute('theme', opts.danger ? 'danger' : 'primary');
			btnOk.textContent = opts.ok || _('OK');
			btnOk.addEventListener('click', function() { done(true); });

			footer.appendChild(btnCancel);
			footer.appendChild(btnOk);
			var slot = el('div');
			slot.setAttribute('slot', 'footer');
			slot.appendChild(footer);
			modal.appendChild(slot);

			/* 唯一关闭出口：读 trigger 区分确认与其它来源 */
			modal.addEventListener('close', function(e) {
				var d = e && e.detail;
				var trigger = d && d.trigger ? d.trigger : '';
				done(trigger === 'confirm');
			});

			document.addEventListener('keydown', onKey, true);
			document.body.appendChild(modal);
			window.setTimeout(function() {
				try { btnCancel.focus(); } catch (e) { /* 未就绪则跳过 */ }
			}, 60);
		});
	});
}

/* 焦点陷阱：把 Tab 键循环限制在 container 内。
 *
 * t-dialog 走 shadow DOM，宿主元素上拿不到内部可聚焦节点列表，因此这里
 * 只做「宿主级别的兜底」：Tab 到最后一个可聚焦元素时绕回第一个。真正的
 * 内部循环由组件自身负责，本函数只防止焦点跑到弹窗背后的页面上 ——
 * 对键盘用户而言，跑出去就意味着看不见焦点落在哪，比顺序错更糟。
 *
 * 返回 release()，在弹窗关闭时调用以解除监听。
 *
 * onEscape: 可选回调。传入后在 capture 阶段拦下 Escape 并调用它。
 * 这一层兜底是必需的，不是冗余：t-dialog 的 ESC 关闭依赖组件内部的
 * uid 栈（Gw.top === this.uid），而 uid 只在 receiveProps 检测到 visible
 * 真实变化时才入栈。经实测，本项目用 modal.visible = true 打开弹窗时
 * 该入栈动作不会发生，closeOnEscKeydown 属性设了也不生效——事件能到达
 * document，组件却不响应。因此 ESC 关闭必须由我们在 document 上兜住。 */
function trapFocus(container, onEscape) {
	function onKey(e) {
		/* ESC 兜底：必须在 capture 阶段抢在组件自己的监听之前，
		 * 否则组件一旦（在别的路径上）也响应 ESC，会双触发。 */
		if (e.key === 'Escape' && typeof onEscape === 'function') {
			if (!container.isConnected) return;
			e.stopPropagation();
			e.preventDefault();
			onEscape();
			return;
		}
		if (e.key !== 'Tab') return;
		var f = container.querySelectorAll(
			'a[href], button:not([disabled]), input:not([disabled]), ' +
			'select:not([disabled]), textarea:not([disabled]), ' +
			'[tabindex]:not([tabindex="-1"])'
		);
		if (!f.length) return;
		var first = f[0], last = f[f.length - 1];
		if (e.shiftKey && document.activeElement === first) {
			last.focus();
			e.preventDefault();
		} else if (!e.shiftKey && document.activeElement === last) {
			first.focus();
			e.preventDefault();
		}
	}
	document.addEventListener('keydown', onKey, true);
	return function release() {
		document.removeEventListener('keydown', onKey, true);
	};
}

/* ---------------------------------------------------------------- DOM 辅助 */

function el(tag, cls, html) {
	var e = document.createElement(tag);
	if (cls) e.className = cls;
	if (html != null) e.innerHTML = html;
	return e;
}

function svgBox(svg, cls) {
	var d = document.createElement('div');
	if (cls) d.className = cls;
	d.innerHTML = svg;
	return d;
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
	nm.appendChild(el('div', 'nm-target-name', t.name ? String(t.name).replace(/[<>&]/g, '') : t.id));
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
	tdesign: tdesign,
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
	gradeClass: gradeClass,
	gradeText: gradeText,
	dotClass: dotClass,
	regionText: regionText,
	regionTagClass: regionTagClass,
	errorText: errorText,
	localizeError: localizeError,
	el: el,
	svgBox: svgBox,
	tcard: tcard,
	cardIcon: cardIcon,
	inlineIcon: inlineIcon,
	confirmDialog: confirmDialog,
	trapFocus: trapFocus,
	icons: icons,
	clear: clear,
	notify: notify,
	sparkline: sparkline,
	targetCard: targetCard,
	kpiCard: kpiCard,
	iconCard: iconCard,
	banner: banner,
	palette: ['#2f6fed', '#2e9e5b', '#8a63d2', '#e0762c', '#00a3b4', '#d69a1a', '#cf4437', '#5c6b7a']
});
