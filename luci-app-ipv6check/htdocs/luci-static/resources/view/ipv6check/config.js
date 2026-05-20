'use strict';
'require view';
'require form';
'require uci';
'require rpc';

/* IPv6 连通性检测 - 参数配置页面 */

var callGetInterfaces = rpc.declare({
	object: 'ipv6check',
	method: 'get_interfaces',
	expect: {}
});

return view.extend({
	load: function() {
		return Promise.all([
			uci.load('ipv6check'),
			callGetInterfaces().catch(function() { return { interfaces: [] }; })
		]);
	},

	render: function(data) {
		var ifaceData = data[1] || {};
		var interfaces = ifaceData.interfaces || ['wan', 'wan6', 'lan'];
		if (!interfaces.length)
			interfaces = ['wan', 'wan6', 'lan'];

		var m, s, o;

		/* ===== 主表单 ===== */
		m = new form.Map('ipv6check', 'IPv6 连通性检测',
			'定时检测 IPv6 网络连通性，当所有目标均不可达时自动重启指定网络接口以恢复连接。');

		/* ===== 全局设置 ===== */
		s = m.section(form.NamedSection, 'global', 'ipv6check', '全局设置');
		s.anonymous = false;
		s.addremove = false;

		/* 启用开关 */
		o = s.option(form.Flag, 'enabled', '启用监测',
			'启用或禁用 IPv6 连通性定时检测服务');
		o.default = '1';
		o.rmempty = false;

		/* 检测间隔 */
		o = s.option(form.Value, 'interval', '检测间隔（秒）',
			'每次检测之间的等待时间，最小 30 秒');
		o.datatype = 'uinteger';
		o.default = '300';
		o.placeholder = '300';
		o.rmempty = false;
		o.validate = function(section_id, value) {
			var v = parseInt(value);
			if (isNaN(v) || v < 30 || v > 86400) return '检测间隔必须在 30 到 86400 秒之间';
			return true;
		};

		/* 重试次数 */
		o = s.option(form.Value, 'retry_count', '重试次数',
			'对每个目标地址的最大 ping 尝试次数');
		o.datatype = 'uinteger';
		o.default = '3';
		o.placeholder = '3';
		o.validate = function(section_id, value) {
			var v = parseInt(value);
			if (isNaN(v) || v < 1 || v > 10) return '重试次数必须在 1 到 10 之间';
			return true;
		};

		/* 重试间隔 */
		o = s.option(form.Value, 'retry_interval', '重试间隔（秒）',
			'每次重试之间的等待时间');
		o.datatype = 'uinteger';
		o.default = '10';
		o.placeholder = '10';
		o.validate = function(section_id, value) {
			var v = parseInt(value);
			if (isNaN(v) || v < 1 || v > 3600) return '重试间隔必须在 1 到 3600 秒之间';
			return true;
		};

		/* 失败阈值 */
		o = s.option(form.Value, 'failure_threshold', '失败阈值',
			'连续检测全部失败达到此次数后触发接口重启');
		o.datatype = 'uinteger';
		o.default = '3';
		o.placeholder = '3';
		o.validate = function(section_id, value) {
			var v = parseInt(value);
			if (isNaN(v) || v < 1 || v > 100) return '失败阈值必须在 1 到 100 之间';
			return true;
		};

		/* 自动重启开关 */
		o = s.option(form.Flag, 'auto_restart', '自动重启接口',
			'当 IPv6 连续失败达到阈值时自动重启指定的网络接口');
		o.default = '1';

		/* 重启接口选择 */
		o = s.option(form.ListValue, 'restart_interface', '重启接口',
			'失败时需要重启的网络接口');
		o.default = 'wan6';
		interfaces.forEach(function(iface) {
			o.value(iface, iface);
		});
		/* 确保 wan6 始终在列表中 */
		if (interfaces.indexOf('wan6') === -1) {
			o.value('wan6', 'wan6');
		}

		/* 日志级别 */
		o = s.option(form.ListValue, 'log_level', '日志级别',
			'控制日志的详细程度');
		o.value('0', '静默 - 仅记录错误');
		o.value('1', '普通 - 记录检测结果');
		o.value('2', '详细 - 记录所有操作');
		o.default = '1';

		/* 最大日志条目 */
		o = s.option(form.Value, 'max_log_entries', '最大日志条目',
			'本地日志文件保留的最大条目数');
		o.datatype = 'uinteger';
		o.default = '100';
		o.placeholder = '100';
		o.validate = function(section_id, value) {
			var v = parseInt(value);
			if (isNaN(v) || v < 10 || v > 10000) return '最大日志条目必须在 10 到 10000 之间';
			return true;
		};

		/* ===== 检测目标列表 ===== */
		s = m.section(form.TableSection, 'target', '检测目标',
			'添加需要检测的 IPv6 目标地址。建议添加多个不同运营商的 DNS 以提高检测准确性。');
		s.anonymous = true;
		s.addremove = true;
		s.addbtntitle = '添加检测目标';
		s.sortable = true;

		/* 目标名称 */
		o = s.option(form.Value, 'name', '名称');
		o.placeholder = '例如: Google DNS';
		o.rmempty = false;
		o.width = '25%';

		/* 目标地址 */
		o = s.option(form.Value, 'host', 'IPv6 地址');
		o.placeholder = '例如: 2001:4860:4860::8888';
		o.rmempty = false;
		o.width = '45%';
		o.validate = function(section_id, value) {
			if (!value || value === '') return '请输入 IPv6 地址';

			/* 严格 IPv6 地址格式校验（RFC 4291 全表示形式） */
			var ipv6Regex = /^(([0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:){1,7}:|([0-9a-fA-F]{1,4}:){1,6}:[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:){1,5}(:[0-9a-fA-F]{1,4}){1,2}|([0-9a-fA-F]{1,4}:){1,4}(:[0-9a-fA-F]{1,4}){1,3}|([0-9a-fA-F]{1,4}:){1,3}(:[0-9a-fA-F]{1,4}){1,4}|([0-9a-fA-F]{1,4}:){1,2}(:[0-9a-fA-F]{1,4}){1,5}|[0-9a-fA-F]{1,4}:((:[0-9a-fA-F]{1,4}){1,6})|:((:[0-9a-fA-F]{1,4}){1,7}|:))$/;
			/* 合规域名格式校验（RFC 1123：每段 1-63 字母数字或连字符，不以连字符开头/结尾） */
			var hostnameRegex = /^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*$/;

			if (!ipv6Regex.test(value) && !hostnameRegex.test(value)) {
				return '请输入有效的 IPv6 地址或域名';
			}
			return true;
		};

		/* 启用开关 */
		o = s.option(form.Flag, 'enabled', '启用');
		o.default = '1';
		o.width = '15%';

		return m.render();
	}
});
