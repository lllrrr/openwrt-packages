'use strict';
'require view';
'require form';
'require poll';
'require rpc';

const callServiceList = rpc.declare({
	object: 'service',
	method: 'list',
	params: ['name'],
	expect: { '': {} }
});

function getServiceStatus() {
	return L.resolveDefault(callServiceList('panda'), {}).then(function(res) {
		var isRunning = false;
		try {
			var inst = res['panda']['instances'];
			for (var k in inst) {
				if (inst[k] && inst[k].running) { isRunning = true; break; }
			}
		} catch (e) { }
		return isRunning;
	});
}

function renderStatus(isRunning) {
	var color = isRunning ? 'green' : 'red';
	var text = isRunning ? 'Panda 运行中' : 'Panda 未运行';
	return String.format('<em><span style="color:%s"><strong>%s</strong></span></em>', color, text);
}

return view.extend({

	render: function() {
		var m, s, o;

		m = new form.Map('panda',
			'Panda — 设置',
			'动态 DNS 更新器配置。守护进程读取这些设置，按配置的时间间隔自动更新 DNS 记录。');

		/* ── 服务状态 ── */
		s = m.section(form.TypedSection);
		s.anonymous = true;
		s.render = function() {
			poll.add(function() {
				return L.resolveDefault(getServiceStatus()).then(function(res) {
					var view = document.getElementById('service_status');
					if (view) view.innerHTML = renderStatus(res);
				});
			});
			return E('div', { class: 'cbi-section', id: 'status_bar' }, [
				E('p', { id: 'service_status' }, '正在收集数据…')
			]);
		};

		/* ── 全局设置 ── */
		s = m.section(form.NamedSection, 'global', 'panda', '全局设置');
		s.anonymous = true;
		s.addremove = false;

		o = s.option(form.Flag, 'ddns_enabled', '启用');
		o.default  = '0';
		o.rmempty  = false;

		o = s.option(form.Value, 'ddns_interval', '更新间隔',
			'DNS 更新检查间隔（秒），最小值：60。');
		o.datatype = 'and(uinteger,min(60))';
		o.default  = '300';
		o.rmempty  = false;

		/* ── IP 检测地址 ── */
		s = m.section(form.NamedSection, 'ip_detect', 'panda', 'IP 检测');
		s.anonymous = true;
		s.addremove = false;

		o = s.option(form.DynamicList, 'ipv4_urls', 'IPv4 检测地址',
			'获取公网 IPv4 地址的 URL 列表，从前到后依次尝试。默认已填好可用的地址。');
		o.default  = 'https://api.ipify.org';
		o.rmempty = true;

		o = s.option(form.DynamicList, 'ipv6_urls', 'IPv6 检测地址',
			'获取公网 IPv6 地址的 URL 列表，从前到后依次尝试。');
		o.default  = 'https://api6.ipify.org';
		o.rmempty = true;

		/* ── DNS 条目 ── */
		s = m.section(form.TypedSection, 'ddns_entry', 'DNS 条目',
			'每条记录将域名映射到对应的服务商。守护进程在每个间隔内更新所有已启用的条目。');
		s.anonymous = false;
		s.addremove = true;
		s.nodescriptions = true;

		o = s.option(form.Flag, 'enabled', '启用');
		o.default = '0';

		o = s.option(form.Value, 'name', '名称',
			'为此条目设置一个便于识别的名称（如 home、office）。');
		o.rmempty = false;

		o = s.option(form.ListValue, 'provider', '服务商');
		o.value('cloudflare', 'Cloudflare');
		o.value('dnspod',     'DNSPod');
		o.value('aliyun',     '阿里云');
		o.value('huawei',     '华为云');
		o.value('noip',       'No-IP');
		o.value('duckdns',    'DuckDNS');
		o.value('baidu',      '百度云');
		o.rmempty = false;

		o = s.option(form.Value, 'domain', '域名',
			'要更新的完整域名（如 home.example.com）。');
		o.rmempty  = false;
		o.datatype = 'hostname';

		o = s.option(form.ListValue, 'record_type', '记录类型',
			'A = IPv4，AAAA = IPv6，双栈 = 同时更新 IPv4 + IPv6。');
		o.value('A',    'A（IPv4）');
		o.value('AAAA', 'AAAA（IPv6）');
		o.value('BOTH',  'A + AAAA（双栈）');
		o.default  = 'A';
		o.rmempty  = false;

		o = s.option(form.Value, 'token', 'API 令牌',
			'Cloudflare：创建 API Token（DNS:Edit 权限）；DNSPod：API 令牌（DNSPod Token）；阿里云：AccessKey ID。');
		o.password = true;
		o.rmempty  = false;

		/* ── Cloudflare 专用 ── */
		o = s.option(form.Value, 'cf_zone_id', 'Cloudflare Zone ID（可选）',
			'Cloudflare 区域 ID（32 位十六进制）。不填则自动从域名推断。\n在 Cloudflare 仪表板右侧栏「API」区域可找到。');
		o.optional = true;

		o = s.option(form.Flag, 'cf_proxied', '启用 Cloudflare CDN 代理');
		o.default = '0';
		o.optional = true;

		/* ── 其他 ── */
		o = s.option(form.Value, 'ttl', 'TTL',
			'DNS 记录 TTL（秒），设为 1 表示自动（服务商默认）。');
		o.datatype = 'and(uinteger,min(1))';
		o.default  = '120';
		o.optional = true;

		o = s.option(form.Value, 'custom_url', '自定义更新 URL（可选）',
			'仅「自定义」服务商需要。支持 {ip} 和 {domain} 占位符。');
		o.optional = true;

		return m.render();
	}

});
