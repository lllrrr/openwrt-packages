'use strict';
'require view';
'require rpc';
'require uci';
'require form';

var callRestart = rpc.declare({
	object: 'atomdns',
	method: 'restart',
	params: []
});

return view.extend({
	load: function () {
		return uci.load('atomdns');
	},

	render: function () {
		var m, s, o;

		m = new form.Map('atomdns', _('AtomDNS'),
			_('Rust 版 DNS 分流器，支持国内外分流、FakeIP、路由学习与内置 WebUI。'));

		// ---------- 服务设置 ----------
		s = m.section(form.NamedSection, 'main', 'atomdns', _('服务设置'));

		o = s.option(form.Flag, 'enabled', _('启用'),
			_('开启后由 procd 托管，开机自启；关闭则不占用任何端口。'));
		o.default = '0';
		o.rmempty = false;

		o = s.option(form.Value, 'dns_port', _('DNS 监听端口'),
			_('默认 2053，避开 dnsmasq 的 53；若需接管局域网 DNS，请先停用 dnsmasq 的 DNS 监听再改为 53。'));
		o.datatype = 'port';
		o.default = '2053';
		o.rmempty = false;

		o = s.option(form.Value, 'webui_port', _('WebUI 端口'),
			_('内置管理界面端口，默认 9099；改动后需重启服务，再用下方按钮打开。'));
		o.datatype = 'port';
		o.default = '9099';
		o.rmempty = false;

		o = s.option(form.Value, 'config_dir', _('配置目录'),
			_('首次启动会从内置配置包初始化该目录，规则/缓存/学习数据都保存在这里。'));
		o.default = '/etc/atomdns';
		o.rmempty = false;

		o = s.option(form.Value, 'log_file', _('日志文件'));
		o.default = '/tmp/atomdns.log';
		o.rmempty = false;

		// ---------- 操作按钮 ----------
		var btnOpen = E('button', {
			'class': 'btn cbi-button-action',
			'click': function (ev) {
				ev.preventDefault();
				var port = uci.get('atomdns', 'main', 'webui_port') || '9099';
				var host = window.location.hostname || window.location.host;
				// AtomDNS 内置 WebUI 只提供明文 HTTP（api.http），不随 LuCI 的 HTTPS 切换；
				// 若沿用 window.location.protocol，在 HTTPS 访问 LuCI 时会拼出 https://host:9099 导致 SSL 失败。
				window.open('http://' + host + ':' + port + '/', '_blank');
			}
		}, _('打开 WebUI'));

		var btnRestart = E('button', {
			'class': 'btn',
			'click': function (ev) {
				ev.preventDefault();
				return callRestart().then(function () {
					window.location.reload();
				});
			}
		}, _('重启服务'));

		var actions = E('div', { 'class': 'cbi-section' }, [
			E('p', { 'class': 'cbi-section-descr' },
				_('打开内置 WebUI 需要服务正在运行，且浏览器能访问本页所在主机的对应端口。')),
			E('div', { 'style': 'display:flex;gap:8px;flex-wrap:wrap' }, [btnOpen, btnRestart])
		]);

		return m.render().then(function (mapEl) {
			return [mapEl, actions];
		});
	}
});
