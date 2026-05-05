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
		try {
			return res['kiwi']['instances']['kiwi']['running'];
		} catch (e) {
			return false;
		}
	});
}

return view.extend({
	render() {
		let m, s, o;

		m = new form.Map('kiwi', 'Kiwi', '高性能 DNS 转发器，基于 kixdns 构建。');

		// 状态栏
		s = m.section(form.TypedSection);
		s.anonymous = true;
		s.render = function() {
			function checkStatus() {
				return getServiceStatus().then(function(isRunning) {
					let view = document.getElementById('kiwi-status');
					if (view) {
						if (isRunning) {
							view.innerHTML = '<span style="color:green"><strong>Kiwi — RUNNING</strong></span>';
						} else {
							view.innerHTML = '<span style="color:red"><strong>Kiwi — NOT RUNNING</strong></span>';
						}
					}
				});
			}
			poll.add(checkStatus);
			checkStatus();
			return E('div', { class: 'cbi-section' }, [
				E('p', { id: 'kiwi-status' }, '收集状态中…')
			]);
		};

		// 全局配置段
		s = m.section(form.NamedSection, 'config', 'kiwi', '全局设置');
		s.anonymous = true;
		s.addremove = false;

		o = s.option(form.Flag, 'enabled', '启用',
			'开启后 kiwi 将随系统启动。');
		o.default = '0';
		o.rmempty = false;

		o = s.option(form.Value, 'config_file', '配置文件',
			'Pipeline JSON 配置文件的完整路径。');
		o.default = '/etc/kiwi/pipeline.json';
		o.rmempty = false;
		o.readonly = true;

		o = s.option(form.Value, 'log_level', '日志级别',
			'info / debug。');
		o.value('info', 'Info');
		o.value('debug', 'Debug');
		o.default = 'info';
		o.rmempty = false;

		o = s.option(form.Value, 'udp_workers', 'UDP Worker 数量',
			'0 = 自动（CPU 核心数）。');
		o.datatype = 'uinteger';
		o.placeholder = '0';

		o = s.option(form.Value, 'listener_label', '监听器标签',
			'用于 Pipeline 匹配的标签。');
		o.default = 'default';

		return m.render();
	}
});
