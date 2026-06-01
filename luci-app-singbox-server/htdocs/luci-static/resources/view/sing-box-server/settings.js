'use strict';
'require view';
'require form';
'require fs';
'require uci';
'require ui';

return view.extend({
	load: function() {
		return Promise.all([
			uci.load('sing_box_server'),
			fs.exec_direct('/etc/init.d/sing-box-server', ['status']).catch(function(e) { return ''; }),
			fs.read('/var/log/sing-box-server.log').catch(function(e) { return ''; })
		]);
	},

	render: function(data) {
		var running = (data[1] || '').indexOf('running') > -1;
		var m, s, o;

		m = new form.Map('sing_box_server', _('服务器端'));

		s = m.section(form.NamedSection, 'global', 'global');
		s.anonymous = true;
		s.addremove = false;

		o = s.option(form.Flag, 'enabled', _('启用'));
		o.rmempty = false;

		o = s.option(form.ListValue, 'log_level', _('日志等级'));
		['trace', 'debug', 'info', 'warn', 'error', 'fatal', 'panic'].forEach(function(v) { o.value(v); });
		o.default = 'info';
		o.modalonly = true; 

		s = m.section(form.GridSection, 'server', _('用户管理'));
		s.anonymous = true;
		s.addremove = true;
		s.sortable = true;
		s.rowcolors = true; 
		s.nodescriptions = true;

		o = s.option(form.Flag, 'enabled', _('启用'));
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.DummyValue, '_status', _('状态'));
		o.modalonly = false;
		o.rawhtml = true; 
		o.cfgvalue = function(section_id) {
			var en = uci.get('sing_box_server', section_id, 'enabled');
			if (running && en === '1') {
				return '✓';
			}
			return 'X';
		};

		o = s.option(form.Value, 'remarks', _('备注'));
		o.rmempty = false;

		o = s.option(form.ListValue, 'protocol', _('类型'));
		o.value('vmess', 'Xray VMess');
		o.value('vless', 'Xray VLESS');
		o.value('trojan', 'Trojan');
		o.value('shadowsocks', 'Shadowsocks');
		o.value('hysteria2', 'Hysteria2');
		o.value('tuic', 'TUIC');
		o.default = 'vmess';

		o = s.option(form.Value, 'listen_port', _('端口'));
		o.datatype = 'port';
		o.rmempty = false;

		o = s.option(form.Value, 'listen', _('监听地址'));
		o.placeholder = '::';
		o.modalonly = true;

		o = s.option(form.Value, 'uuid', _('UUID'));
		o.depends('protocol', 'vmess');
		o.depends('protocol', 'vless');
		o.depends('protocol', 'tuic');
		o.placeholder = '00000000-0000-0000-0000-000000000000';
		o.modalonly = true;

		o = s.option(form.Value, 'password', _('密码'));
		o.password = true;
		o.depends('protocol', 'trojan');
		o.depends('protocol', 'shadowsocks');
		o.depends('protocol', 'hysteria2');
		o.depends('protocol', 'tuic');
		o.modalonly = true;

		o = s.option(form.ListValue, 'method', _('加密方法'));
		o.value('2022-blake3-aes-128-gcm');
		o.value('2022-blake3-aes-256-gcm');
		o.value('aes-128-gcm');
		o.value('aes-256-gcm');
		o.value('chacha20-ietf-poly1305');
		o.default = 'aes-128-gcm';
		o.depends('protocol', 'shadowsocks');
		o.modalonly = true;

		o = s.option(form.Value, 'flow', _('VLESS flow'));
		o.placeholder = 'xtls-rprx-vision';
		o.depends('protocol', 'vless');
		o.modalonly = true;

		o = s.option(form.ListValue, 'transport', _('传输层'));
		o.value('tcp', 'TCP');
		o.value('ws', 'WebSocket');
		o.value('http', 'HTTP');
		o.value('grpc', 'gRPC');
		o.value('httpupgrade', 'HTTPUpgrade');
		o.default = 'tcp';
		o.modalonly = true;

		o = s.option(form.Value, 'path', _('路径 / 服务名'));
		o.depends('transport', 'ws');
		o.depends('transport', 'http');
		o.depends('transport', 'grpc');
		o.depends('transport', 'httpupgrade');
		o.modalonly = true;

		o = s.option(form.Value, 'host', _('Host'));
		o.depends('transport', 'ws');
		o.depends('transport', 'httpupgrade');
		o.modalonly = true;

		o = s.option(form.Flag, 'tls', _('TLS'));
		o.rmempty = false;
		o.depends('protocol', 'vmess');
		o.depends('protocol', 'vless');
		o.depends('protocol', 'trojan');
		o.depends('protocol', 'shadowsocks');
		o.modalonly = true;

		o = s.option(form.ListValue, 'tls_mode', _('TLS 模式'));
		o.value('tls', 'TLS');
		o.value('reality', 'Reality');
		o.default = 'tls';
		o.depends('tls', '1');
		o.modalonly = true;

		o = s.option(form.Value, 'server_name', _('服务名 / SNI'));
		o.depends('tls', '1');
		o.modalonly = true;

		o = s.option(form.Value, 'cert', _('证书路径'));
		o.depends({ tls: '1', tls_mode: 'tls' });
		o.depends('protocol', 'hysteria2');
		o.depends('protocol', 'tuic');
		o.modalonly = true;

		o = s.option(form.Value, 'key', _('私钥路径'));
		o.depends({ tls: '1', tls_mode: 'tls' });
		o.depends('protocol', 'hysteria2');
		o.depends('protocol', 'tuic');
		o.modalonly = true;

		o = s.option(form.Value, 'reality_private_key', _('Reality 私钥'));
		o.password = true;
		o.depends({ tls: '1', tls_mode: 'reality' });
		o.modalonly = true;

		o = s.option(form.Value, 'reality_short_id', _('Reality short id'));
		o.depends({ tls: '1', tls_mode: 'reality' });
		o.modalonly = true;

		o = s.option(form.Value, 'reality_handshake_server', _('Reality 握手服务器'));
		o.depends({ tls: '1', tls_mode: 'reality' });
		o.modalonly = true;

		o = s.option(form.Value, 'reality_handshake_server_port', _('Reality 握手端口'));
		o.datatype = 'port';
		o.depends({ tls: '1', tls_mode: 'reality' });
		o.modalonly = true;

		// --- 日志面板 ---
		s = m.section(form.TypedSection, '_log', _('日志'));
		s.anonymous = true;
		s.render = function() {
			// 延迟 100 毫秒，等 DOM 渲染完成后自动滚动到底部
			setTimeout(function() {
				var box = document.getElementById('singbox_server_log_box');
				if (box) box.scrollTop = box.scrollHeight;
			}, 100);

			return E('div', { 'class': 'cbi-section' }, [
				E('div', { 'style': 'margin-bottom: 10px;' }, [
					E('button', {
						'class': 'btn cbi-button cbi-button-remove',
						'click': ui.createHandlerFn(this, function() {
							// 关键修复：使用输出重定向清空文件内容，而不是删除文件，防止文件描述符断裂
							return fs.exec('/bin/sh', ['-c', 'cat /dev/null > /var/log/sing-box-server.log']).then(function() {
								var logBox = document.getElementById('singbox_server_log_box');
								if (logBox) logBox.value = '';
							});
						})
					}, _('清空日志'))
				]),
				E('div', {}, [
					E('textarea', {
						'id': 'singbox_server_log_box',
						'style': 'width: 100%; height: 400px; resize: vertical; font-family: monospace; white-space: pre-wrap;',
						'readonly': 'readonly'
					}, data[2] || '')
				])
			]);
		};

		return m.render();
	}
});
