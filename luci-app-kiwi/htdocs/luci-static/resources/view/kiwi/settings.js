// SPDX-License-Identifier: Apache-2.0
// Kiwi — 设置页

'use strict';
'require form';
'require poll';
'require rpc';
'require uci';
'require view';

const callServiceList = rpc.declare({
	object: 'service',
	method: 'list',
	params: ['name'],
	expect: { '': {} }
});

function getServiceStatus() {
	return L.resolveDefault(callServiceList('kiwi'), {}).then(function(res) {
		let isRunning = false;
		try {
			isRunning = res['kiwi']['instances']['kiwi']['running'];
		} catch (e) {}
		return isRunning;
	});
}

function renderStatus(isRunning) {
	let spanTemp = '<em><span style="color:%s"><strong>%s</strong></span></em>';
	let renderHTML;
	if (isRunning)
		renderHTML = String.format(spanTemp, 'var(--bs-success, green)', _('Kiwi 运行中'));
	else
		renderHTML = String.format(spanTemp, 'var(--bs-danger, red)', _('Kiwi 未运行'));
	return renderHTML;
}

return view.extend({
	render() {
		let m, s, o;

		m = new form.Map('kiwi', _('Kiwi'), _('高性能 DNS 转发器，基于 kixdns 构建。'));

		// 状态栏
		s = m.section(form.TypedSection);
		s.anonymous = true;
		s.render = function() {
			poll.add(function() {
				return L.resolveDefault(getServiceStatus()).then(function(res) {
					let view = document.getElementById('kiwi-status');
					if (view) {
						view.innerHTML = renderStatus(res);
					}
				});
			});
			return E('div', { class: 'cbi-section' }, [
				E('p', { id: 'kiwi-status' }, _('收集状态中…'))
			]);
		};

		// 全局配置段
		s = m.section(form.NamedSection, 'config', 'kiwi', _('全局设置'));
		s.anonymous = true;
		s.addremove = false;

		o = s.option(form.Flag, 'enabled', _('启用'));
		o.default = '0';
		o.rmempty = false;

		// 启用后执行两项操作：
		//   1. 配置 dnsmasq 将上游查询转发至 kiwi（noresolv + server=127.0.0.1#<port>）
		//   2. 添加防火墙 DNAT 规则，劫持 LAN 内硬编码 DNS 的客户端（:53 → kiwi）
		o = s.option(form.Flag, 'dns_redirect', _('DNS 劫持重定向'),
			_('将 dnsmasq 上游及 LAN 客户端的 DNS 请求统一转发到 Kiwi。'));
		o.default = '0';
		o.rmempty = false;

		o = s.option(form.Value, 'config_file', _('配置文件'),
			_('Pipeline JSON 配置文件的完整路径。'));
		o.default = '/etc/kiwi/pipeline.json';
		o.rmempty = false;
		o.readonly = true;

		o = s.option(form.Value, 'log_level', _('日志级别'),
			_('info / debug。'));
		o.value('info', 'Info');
		o.value('debug', 'Debug');
		o.default = 'info';
		o.rmempty = false;

		o = s.option(form.Value, 'udp_workers', _('UDP Worker 数量'),
			_('0 = 自动（CPU 核心数）。'));
		o.datatype = 'uinteger';
		o.placeholder = '0';

		o = s.option(form.Value, 'listener_label', _('监听器标签'),
			_('用于 Pipeline 匹配的标签。'));
		o.default = 'default';

		return m.render();
	}
});