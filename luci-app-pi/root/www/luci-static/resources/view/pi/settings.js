'use strict';
'require view';
'require form';
'require poll';
'require rpc';
'require fs';

var callServiceList = rpc.declare({
	object: 'service',
	method: 'list',
	params: ['name'],
	expect: { '': {} }
});

var callInitAction = rpc.declare({
	object: 'luci',
	method: 'setInitAction',
	params: ['name', 'action'],
	expect: { result: false }
});

function getServiceStatus() {
	return L.resolveDefault(callServiceList('pi'), {}).then(function (res) {
		var isRunning = false;
		try {
			var inst = res['pi']['instances'];
			for (var k in inst) {
				if (inst[k] && inst[k].running) {
					isRunning = true;
					break;
				}
			}
		} catch (e) {}
		return isRunning;
	});
}

function renderStatus(isRunning) {
	var color = isRunning ? 'green' : 'red';
	var text = isRunning ? 'Pi 运行中' : 'Pi 未运行';
	return String.format('<em><span style="color:%s"><strong>%s</strong></span></em>', color, text);
}

return view.extend({

	render: function () {
		var m, s, o;

		m = new form.Map('pi', 'Pi — 设置',
			'基于 Mihomo 的 OpenWrt 透明代理。');

		/* ── 运行状态 ── */
		s = m.section(form.TypedSection);
		s.anonymous = true;
		s.render = function () {
			poll.add(function () {
				return L.resolveDefault(getServiceStatus()).then(function (res) {
					var view = document.getElementById('service_status');
					if (view)
						view.innerHTML = renderStatus(res);
				});
			});
			return E('div', { 'class': 'cbi-section', 'id': 'status_bar' }, [
				E('p', { 'id': 'service_status' }, '正在收集数据…')
			]);
		};

		/* ── 基本设置 ── */
		s = m.section(form.NamedSection, 'global', 'global', '基本设置');
		s.anonymous = true;
		s.addremove = false;

		o = s.option(form.Flag, 'enabled', '启用');
		o.default = '0';
		o.rmempty = false;

		o = s.option(form.Value, 'config_file', '配置文件路径');
		o.default   = '/etc/pi/config.yaml';
		o.rmempty   = false;
		o.placeholder = '/etc/pi/config.yaml';

		o = s.option(form.ListValue, 'log_level', '日志级别');
		o.default = 'info';
		o.value('silent',  '静默');
		o.value('error',   '错误');
		o.value('warning', '警告');
		o.value('info',    '信息');
		o.value('debug',   '调试');

		/* ── 操作 ── */
		s = m.section(form.NamedSection, 'global', 'global', '操作');
		s.anonymous = true;
		s.addremove = false;

		o = s.option(form.DummyValue, '_actions', '服务控制');
		o.rawhtml = true;
		o.cfgvalue = function () { return ''; };
		o.render = function () {
			var btnReload = E('button', {
				'class': 'cbi-button cbi-button-action',
				'style': 'margin-right:8px',
				'click': function () {
					btnReload.disabled = true;
					btnReload.textContent = '重载中…';
					callInitAction('pi', 'reload').then(function () {
						btnReload.disabled = false;
						btnReload.textContent = '重载配置';
					}).catch(function () {
						btnReload.disabled = false;
						btnReload.textContent = '重载配置';
					});
				}
			}, '重载配置');

			var btnRestart = E('button', {
				'class': 'cbi-button cbi-button-negative',
				'style': 'margin-right:8px',
				'click': function () {
					btnRestart.disabled = true;
					btnRestart.textContent = '重启中…';
					callInitAction('pi', 'restart').then(function () {
						setTimeout(function () { location.reload(); }, 3000);
					});
				}
			}, '重启服务');

			var btnPanel = E('button', {
				'class': 'cbi-button cbi-button-positive',
				'style': 'margin-right:8px',
				'click': function () {
					var host = window.location.hostname;
					window.open('http://' + host + ':9090/ui', '_blank');
				}
			}, '打开面板');

			return E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, '操作'),
				E('div', { 'class': 'cbi-value-field', 'style': 'display:flex;align-items:center;flex-wrap:wrap' },
					[ btnReload, btnRestart, btnPanel ])
			]);
		};

		/* ── 透明代理 ── */
		s = m.section(form.NamedSection, 'global', 'global', '透明代理');
		s.anonymous = true;
		s.addremove = false;

		o = s.option(form.Flag, 'proxy_router', '代理路由器自身');
		o.default = '1';
		o.rmempty = false;
		o.textvalue = '将路由器自身流量通过 TUN 设备转发给 Mihomo';

		o = s.option(form.Flag, 'bypass_china_ip', '绕过国内 IP',
			'开启后自动将中国 IP 段加入绕过列表，国内网站不经过 Mihomo。');
		o.default = '0';
		o.rmempty = false;

		return m.render();
	}

});
