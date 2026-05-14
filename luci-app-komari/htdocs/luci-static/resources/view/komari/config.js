'use strict';
'require view';
'require form';
'require poll';
'require rpc';
'require uci';

var callServiceList = rpc.declare({
	object: 'service',
	method: 'list',
	params: ['name'],
	expect: { '': {} }
});

function getServiceStatus() {
	return L.resolveDefault(callServiceList('komari'), {}).then(function(res) {
		var isRunning = false;
		try {
			isRunning = res['komari']['instances']['instance1']['running'];
		} catch (e) { }
		return isRunning;
	});
}

function renderStatus(isRunning) {
	var color = isRunning ? 'green' : 'red';
	var text = isRunning ? 'Komari 运行中' : 'Komari 未运行';
	return String.format('<em><span style="color:%s"><strong>%s</strong></span></em>', color, text);
}

return view.extend({
	load: function() {
		return uci.load('komari');
	},

	render: function() {
		var m, s, o;

		m = new form.Map('komari', 'Komari 探针', '轻量化自托管服务器监控探针');

		// ── 服务状态 ──
		s = m.section(form.TypedSection);
		s.anonymous = true;
		s.render = function() {
			poll.add(function() {
				return L.resolveDefault(getServiceStatus()).then(function(res) {
					var view = document.getElementById('komari_service_status');
					if (view)
						view.innerHTML = renderStatus(res);
				});
			});

			return E('div', { class: 'cbi-section', id: 'status_bar' }, [
				E('p', { id: 'komari_service_status' }, '正在检测服务状态…')
			]);
		};

		// ── 全局设置 ──
		s = m.section(form.NamedSection, 'global', 'komari', '全局设置');
		s.anonymous = true;
		s.addremove = false;

		o = s.option(form.Flag, 'enabled', '启用',
			'开启后 Komari 探针将连接服务器并上报系统运行状态。');
		o.default = '0';
		o.rmempty = false;

		o = s.option(form.Value, 'interval', '上报间隔（秒）',
			'采集 CPU、内存、网络等性能指标并向服务器上报的时间间隔，建议设为 1~5 秒。');
		o.datatype = 'and(uinteger,min(1))';
		o.placeholder = '1';
		o.default = '1';
		o.depends('enabled', '1');

		o = s.option(form.Value, 'info_report_interval', '基础信息上报（分钟）',
			'主机名、操作系统版本、内核版本等静态基础信息的上报间隔。');
		o.datatype = 'and(uinteger,min(1))';
		o.placeholder = '5';
		o.default = '5';
		o.depends('enabled', '1');

		// ── 连接设置 ──
		s = m.section(form.NamedSection, 'connection', 'komari', '连接设置');
		s.anonymous = true;
		s.addremove = false;

		o = s.option(form.Value, 'endpoint', '服务器地址',
			'Komari 面板服务器的完整 URL，例如 https://status.example.com。');
		o.placeholder = 'https://your-server.com';
		o.rmempty = false;

		o = s.option(form.Value, 'token', 'API Token',
			'在 Komari 面板「设置 → API 令牌」页面中生成的访问令牌。');
		o.password = true;
		o.rmempty = false;

		o = s.option(form.Flag, 'ignore_unsafe_cert', '忽略证书错误',
			'跳过 SSL/TLS 证书验证。仅在使用自签名证书时启用，生产环境不建议开启。');
		o.default = '0';
		o.rmempty = false;

		// ── 监控设置 ──
		s = m.section(form.NamedSection, 'monitor', 'komari', '监控设置');
		s.anonymous = true;
		s.addremove = false;

		o = s.option(form.Flag, 'enable_gpu', 'GPU 监控',
			'启用 NVIDIA GPU 温度、利用率、显存等指标采集（需要安装 nvidia-smi）。');
		o.default = '0';
		o.rmempty = false;

		o = s.option(form.Flag, 'memory_include_cache', '内存统计含缓存',
			'将 Linux 缓冲区/缓存（buffers/cache）一并计入已用内存。关闭后仅统计应用程序实际占用。');
		o.default = '0';
		o.rmempty = false;

		o = s.option(form.Value, 'include_nics', '统计网卡',
			'仅统计指定网卡的流量，多个网卡用逗号分隔（如 eth0,eth1）。留空则统计所有网卡。');

		o = s.option(form.Value, 'exclude_nics', '排除网卡',
			'不统计指定网卡的流量，多个网卡用逗号分隔。例如排除虚拟网卡 docker0,veth*,br-*。');

		o = s.option(form.Value, 'custom_dns', '自定义 DNS',
			'用于检测 DNS 解析延迟的 DNS 服务器地址，例如 8.8.8.8 或 223.5.5.5。');

		o = s.option(form.Value, 'month_rotate', '流量月重置日',
			'每月几号重置流量统计计数器。设为 0 表示不按月重置，持续累计。');
		o.datatype = 'and(uinteger,min(0))';
		o.placeholder = '0';
		o.default = '0';

		o = s.option(form.Value, 'custom_ipv4', '自定义 IPv4',
			'手动指定上报的 IPv4 公网地址。留空则由探针自动检测出口 IP。');
		o.datatype = 'ip4addr';

		o = s.option(form.Value, 'custom_ipv6', '自定义 IPv6',
			'手动指定上报的 IPv6 公网地址。留空则由探针自动检测出口 IP。');
		o.datatype = 'ip6addr';

		// ── 高级设置 ──
		s = m.section(form.NamedSection, 'advanced', 'komari', '高级设置');
		s.anonymous = true;
		s.addremove = false;

		o = s.option(form.Flag, 'disable_web_ssh', '禁用远程终端',
			'关闭 Komari 面板中的 Web SSH 远程终端功能，禁止通过面板登录本机 Shell。');
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.Flag, 'disable_auto_update', '禁用自动更新',
			'禁止探针 Agent 自动下载并安装新版本。建议在稳定运行后开启此选项。');
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.Value, 'max_retries', '最大重试次数',
			'与服务器断开连接后的最大重试次数，超出后探针将停止运行。');
		o.datatype = 'and(uinteger,min(1))';
		o.placeholder = '3';
		o.default = '3';

		o = s.option(form.Value, 'reconnect_interval', '重连间隔（秒）',
			'断开连接后等待多少秒再尝试重新连接，建议设为 3~10 秒。');
		o.datatype = 'and(uinteger,min(1))';
		o.placeholder = '5';
		o.default = '5';

		// ── Cloudflare Access ──
		s = m.section(form.NamedSection, 'cloudflare', 'komari', 'Cloudflare Access');
		s.anonymous = true;
		s.addremove = false;

		o = s.option(form.Value, 'cf_access_client_id', 'Client ID',
			'Cloudflare Zero Trust Access 应用的 Client ID（用于通过 Cloudflare Access 访问面板）。');

		o = s.option(form.Value, 'cf_access_client_secret', 'Client Secret',
			'Cloudflare Zero Trust Access 应用的 Client Secret。');
		o.password = true;

		return m.render();
	}
});
