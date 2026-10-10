/*
 * luci-app-netmonitor 数据访问层
 *
 * 职责边界（本模块**只管进出设备的数据**，不碰任何 DOM / 样式）：
 *   RPC 调用与报错本地化   call() / api.*
 *   后端字符串数值归一化   numify*()
 *   UCI 配置的读改写与提交 saveConfig() / addSection() / applyChanges() / revertConfig()
 *
 * 刻意不 require netmonitor.ui / netmonitor.icons —— 数据层一旦依赖展示层，
 * 就会出现「为了拿到 latenc 数值而把图标库拖进来」的反向耦合。
 * 展示相关的卡片 / 曲线 / 通知一律在 widgets.js，两边互不引用。
 */

'use strict';
'require rpc';
'require ui';
'require uci';
'require netmonitor.format as fmt';

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
			o[k] = fmt.toNum(o[k]);
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
					t.spark[k] = fmt.toNum(t.spark[k]);
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

/* ---------------------------------------------------------------- RPC */

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
			throw new Error(fmt.localizeError(res.error));
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
	 * 差异（详见下方「UCI 事务」注释）。前端一律改用 saveConfig() /
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

/* LuCI 的模块加载器要求每个模块导出一个 Class（Class.isSubclass 校验）。 */
return Class.extend({
	__name__: 'NetMonitor.api',

	call: call,
	api: api,
	strParams: strParams,

	saveConfig: saveConfig,
	addSection: addSection,
	applyChanges: applyChanges,
	revertConfig: revertConfig,

	/* 归一化函数一并导出：调用方拿到原始数据后若需自行处理，
	 * 不必再从 RPC 层里翻抄这份字段清单。 */
	numify: {
		node: numifyNode,
		history: numifyHistory,
		status: numifyStatus,
		stats: numifyStats
	}
});
