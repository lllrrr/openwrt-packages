// SPDX-License-Identifier: Apache-2.0
// Sheep — 配置页

'use strict';
'require form';
'require poll';
'require rpc';
'require ui';
'require uci';
'require view';

const callGetStatus = rpc.declare({
	object: 'luci.sheep',
	method: 'getStatus',
	expect: {}
});

const callRestart = rpc.declare({
	object: 'luci.sheep',
	method: 'restart',
	expect: {}
});

return view.extend({
	render: function() {
		var m, s, o;

		m = new form.Map('sheep', 'Sheep',
			'Shadowsocks-Rust 服务端管理。');

		// ── 状态栏（kiwi 风格）────────────────────────────────
		s = m.section(form.TypedSection);
		s.anonymous = true;
		s.render = function() {
			function renderStatusHTML(st) {
				var spanTemp = '<em><span style="color:%s"><strong>%s</strong></span></em>';
				return st.running
					? String.format(spanTemp, 'var(--bs-success, green)', 'Sheep 运行中')
					: String.format(spanTemp, 'var(--bs-danger, red)', 'Sheep 未运行');
			}
			function checkStatus() {
				return L.resolveDefault(callGetStatus(), {}).then(function(st) {
					var el = document.getElementById('sheep-cfg-status');
					if (el) el.innerHTML = renderStatusHTML(st);
				});
			}
			poll.add(checkStatus, 5);
			checkStatus();
			return E('div', { 'class': 'cbi-section' }, [
				E('p', { id: 'sheep-cfg-status' }, '收集状态中…')
			]);
		};

		// ── 基础设置────────────────────────────────────────────
		s = m.section(form.NamedSection, 'server', 'sheep', '基础设置');
		s.anonymous = false;
		s.addremove = false;

		o = s.option(form.Flag, 'enabled', '启用服务',
			'开启后 Sheep 将随系统自动启动。');
		o.default = '0';
		o.rmempty = false;

		o = s.option(form.Value, 'server', '监听地址');
		o.datatype = 'ipaddr';
		o.default = '0.0.0.0';
		o.rmempty = false;

		o = s.option(form.Value, 'server_port', '监听端口');
		o.datatype = 'range(1024,65535)';
		o.default = '8388';
		o.rmempty = false;

		o = s.option(form.Value, 'password', '密码');
		o.password = true;
		o.rmempty = false;
		o.renderWidget = function(section_id, option_index, cfgvalue) {
			var origNode = form.Value.prototype.renderWidget.call(this, section_id, option_index, cfgvalue);
			var sid = section_id;

			// 读取当前加密方式：直接用 LuCI 确定性 ID 读 DOM，绝不依赖 UCI 缓存
			function getMethod() {
				var el = document.getElementById('cbid.sheep.' + sid + '.method');
				if (el) {
					// 原生 <select>
					if (el.tagName === 'SELECT') return el.value || '';
					// LuCI 自定义 dropdown：内部有隐藏 <select> 或 <input>
					var inner = el.querySelector('select') || el.querySelector('input[type="hidden"]');
					if (inner) return inner.value || '';
				}
				return '';
			}

			var genBtn = E('button', {
				'class': 'btn cbi-button',
				'style': 'margin-left:.375rem;white-space:nowrap',
				'title': '生成随机密钥（SS2022 自动匹配长度）',
				'click': function(ev) {
					ev.preventDefault();
					var method = getMethod();
					// aes-128 → 16 字节；其余（aes-256 / chacha20 / 普通）→ 32 字节
					var bytes = (method === '2022-blake3-aes-128-gcm') ? 16 : 32;
					var raw = new Uint8Array(bytes);
					crypto.getRandomValues(raw);
					var b64 = btoa(String.fromCharCode.apply(null, raw));
					var input = origNode.querySelector('input[type="password"], input[type="text"]');
					if (input) {
						input.value = b64;
						input.dispatchEvent(new Event('input', { bubbles: true }));
						input.dispatchEvent(new Event('change', { bubbles: true }));
					}
				}
			}, '随机生成');

			return E('div', { 'style': 'display:flex;align-items:center' }, [origNode, genBtn]);
		};

		o = s.option(form.ListValue, 'method', '加密方式');
		o.value('aes-128-gcm',                  'AES-128-GCM');
		o.value('aes-256-gcm',                  'AES-256-GCM');
		o.value('chacha20-ietf-poly1305',        'ChaCha20-IETF-Poly1305');
		o.value('2022-blake3-aes-128-gcm',       '2022-Blake3-AES-128-GCM');
		o.value('2022-blake3-aes-256-gcm',       '2022-Blake3-AES-256-GCM');
		o.value('2022-blake3-chacha20-poly1305', '2022-Blake3-ChaCha20-Poly1305');
		o.default = 'aes-256-gcm';
		o.rmempty = false;

		o = s.option(form.Value, 'timeout', '超时（秒）');
		o.datatype = 'uinteger';
		o.default = '300';

		o = s.option(form.Flag, 'fast_open', 'TCP Fast Open');
		o.default = '0';

		o = s.option(form.ListValue, 'mode', '转发模式');
		o.value('tcp_only',    '仅 TCP');
		o.value('udp_only',    '仅 UDP');
		o.value('tcp_and_udp', 'TCP + UDP');
		o.default = 'tcp_and_udp';

		o = s.option(form.Value, 'plugin', '插件');
		o.placeholder = '如 v2ray-plugin';
		o.optional = true;

		o = s.option(form.Value, 'plugin_opts', '插件参数');
		o.optional = true;

		o = s.option(form.Flag, 'manage_firewall', '自动管理防火墙',
			'自动在 WAN 区域开放服务端口。');
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.DummyValue, '_ssuri', 'SS URI',
			'点击可切换显示 / 隐藏。');
		o.cfgvalue = function(section_id) {
			var server = uci.get('sheep', section_id, 'server')      || '0.0.0.0';
			var port   = uci.get('sheep', section_id, 'server_port') || '';
			var method = uci.get('sheep', section_id, 'method')      || '';
			var pw     = uci.get('sheep', section_id, 'password')    || '';
			if (!pw || !port || !method)
				return E('em', {}, '（需先填写密码、端口和加密方式）');
			var uri = 'ss://' + btoa(method + ':' + pw + '@' + server + ':' + port) + '#Sheep-SS';
			var input = E('input', {
				'type': 'password',
				'readonly': '',
				'value': uri,
				'style': 'flex:1;min-width:0;font-family:var(--bs-font-monospace,monospace);font-size:.875em;cursor:pointer',
				'title': '点击切换显示 / 隐藏',
				'click': function(ev) {
					var el = ev.currentTarget;
					el.type = el.type === 'password' ? 'text' : 'password';
				}
			});
			var copyBtn = E('button', {
				'class': 'btn cbi-button',
				'style': 'margin-left:.375rem;white-space:nowrap',
				'title': '复制 SS URI',
				'click': function(ev) {
					ev.preventDefault();
					var btn = ev.currentTarget;
					var done = function() {
						var orig = btn.textContent;
						btn.textContent = '已复制 ✓';
						setTimeout(function() { btn.textContent = orig; }, 1500);
					};
					if (navigator.clipboard) {
						navigator.clipboard.writeText(uri).then(done);
					} else {
						var t = document.createElement('textarea');
						t.value = uri;
						document.body.appendChild(t);
						t.select();
						document.execCommand('copy');
						document.body.removeChild(t);
						done();
					}
				}
			}, '复制');
			return E('div', { 'style': 'display:flex;align-items:center;max-width:42em' }, [input, copyBtn]);
		};
		o.write = function() {};

		return m.render();
	},

	handleSaveApply: function(ev, mode) {
		return this.handleSave(ev).then(function() {
			return ui.changes.apply(mode == '0').then(function() {
				return L.resolveDefault(callRestart(), null);
			});
		});
	}
});
