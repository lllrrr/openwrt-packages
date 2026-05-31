// SPDX-License-Identifier: GPL-2.0-only
//
// Copyright (C) 2024 OpenWrt.org
//
// Standalone sing-box server LuCI view.
// Equivalent to the server portion of homeproxy – no client / routing code.

'use strict';
'require view';
'require form';
'require uci';
'require rpc';
'require ui';
'require poll';

// ─── RPC stubs ──────────────────────────────────────────────────────────────
const callGetStatus = rpc.declare({
	object : 'luci.singbox-server',
	method : 'get_status',
	expect : {}
});

const callSingboxGenerator = rpc.declare({
	object : 'luci.singbox-server',
	method : 'singbox_generator',
	params : [ 'type', 'sni' ],
	expect : {}
});

const callUploadCert = rpc.declare({
	object  : 'luci.singbox-server',
	method  : 'upload_cert',
	params  : [ 'filename', 'content' ],
	expect  : {}
});

const callDeleteCert = rpc.declare({
	object  : 'luci.singbox-server',
	method  : 'delete_cert',
	params  : [ 'path' ],
	expect  : {}
});

const callServiceControl = rpc.declare({
	object  : 'luci.singbox-server',
	method  : 'service_control',
	params  : [ 'action' ],
	expect  : {}
});

// ─── Helpers ─────────────────────────────────────────────────────────────────
function genUUID() {
	return callSingboxGenerator('uuid', null).then(res => {
		if (res.error) throw new Error(res.error);
		return typeof res.result === 'object' ? res.result : res.result;
	});
}

function genKeypair(type, sni) {
	return callSingboxGenerator(type, sni || null).then(res => {
		if (res.error) throw new Error(res.error);
		return res.result;
	});
}

// Validate certificate / key paths
function validCertPath(path) {
	return /^(\/etc\/singbox-server\/certs\/|\/etc\/acme\/|\/etc\/ssl\/certs\/)/.test(path);
}

// ─── Server type definitions ──────────────────────────────────────────────────
const SERVER_TYPES = [
	[ 'mixed',       _('Mixed (HTTP + SOCKS5)')  ],
	[ 'http',        _('HTTP')                    ],
	[ 'socks',       _('SOCKS5')                  ],
	[ 'shadowsocks', _('Shadowsocks')             ],
	[ 'trojan',      _('Trojan')                  ],
	[ 'vless',       _('VLESS')                   ],
	[ 'vmess',       _('VMess')                   ],
	[ 'hysteria',    _('Hysteria v1')             ],
	[ 'hysteria2',   _('Hysteria2')               ],
	[ 'tuic',        _('TUIC v5')                 ],
	[ 'naive',       _('NaïveProxy')              ],
	[ 'anytls',      _('AnyTLS')                  ]
];

const SS_METHODS = [
	[ 'aes-128-gcm',                    '2022-blake3-aes-128-gcm'       ],
	[ 'aes-256-gcm',                    '2022-blake3-aes-256-gcm'       ],
	[ 'chacha20-ietf-poly1305',         '2022-blake3-chacha20-poly1305' ],
	[ 'xchacha20-ietf-poly1305',        'none'                          ],
	[ '2022-blake3-aes-128-gcm'   ],
	[ '2022-blake3-aes-256-gcm'   ],
	[ '2022-blake3-chacha20-poly1305' ]
].map(m => Array.isArray(m) ? m : [ m, m ]);

const TRANSPORT_TYPES = [
	[ 'none',        _('None (plain TCP/UDP)') ],
	[ 'ws',          _('WebSocket')            ],
	[ 'grpc',        _('gRPC')                 ],
	[ 'http',        _('HTTP/2')               ],
	[ 'httpupgrade', _('HTTP Upgrade')         ]
];

const TUIC_CC = [
	[ 'cubic',    _('Cubic')    ],
	[ 'new_reno', _('NewReno')  ],
	[ 'bbr',      _('BBR')      ]
];

const VLESS_FLOWS = [
	[ '',                    _('None')                      ],
	[ 'xtls-rprx-vision',   _('XTLS Vision')               ],
	[ 'xtls-rprx-vision-udp443', _('XTLS Vision (UDP443)') ]
];

const ACME_PROVIDERS = [
	[ 'letsencrypt',   _("Let's Encrypt") ],
	[ 'zerossl',       _('ZeroSSL')        ],
	[ 'google',        _('Google')         ],
	[ 'buypass',       _('Buypass')        ]
];

const DNS_PROVIDERS = [
	[ 'cloudflare', _('Cloudflare') ],
	[ 'alidns',     _('Alibaba Cloud DNS') ]
];

const LOG_LEVELS = [
	[ 'trace',   _('Trace')   ],
	[ 'debug',   _('Debug')   ],
	[ 'info',    _('Info')    ],
	[ 'warn',    _('Warn')    ],
	[ 'error',   _('Error')   ],
	[ 'fatal',   _('Fatal')   ],
	[ 'disable', _('Disable') ]
];

// ─── Status banner widget ─────────────────────────────────────────────────────
function renderStatusBanner(statusEl) {
	return callGetStatus().then(res => {
		const running = res.running;
		const version = res.version || _('Unknown');
		const stateStr = running
			? `<span style="color:green;font-weight:bold">● ${_('RUNNING')}</span>`
			: `<span style="color:red;font-weight:bold">○ ${_('NOT RUNNING')}</span>`;

		statusEl.innerHTML = `
			<table class="table">
				<tr>
					<td style="width:30%">${_('Service')}</td>
					<td>${_('Sing-Box Server')}</td>
				</tr>
				<tr>
					<td>${_('sing-box version')}</td>
					<td>${version}</td>
				</tr>
				<tr>
					<td>${_('Status')}</td>
					<td>${stateStr}</td>
				</tr>
			</table>
			<div style="margin-top:8px">
				<button class="btn cbi-button cbi-button-action" id="sbs-btn-start">${_('Start')}</button>
				<button class="btn cbi-button cbi-button-negative" id="sbs-btn-stop">${_('Stop')}</button>
				<button class="btn cbi-button" id="sbs-btn-restart">${_('Restart')}</button>
			</div>`;

		const doControl = (action) => {
			return callServiceControl(action).then(() => renderStatusBanner(statusEl));
		};

		statusEl.querySelector('#sbs-btn-start').onclick   = () => doControl('start');
		statusEl.querySelector('#sbs-btn-stop').onclick    = () => doControl('stop');
		statusEl.querySelector('#sbs-btn-restart').onclick = () => doControl('restart');
	});
}

// ─── Main view ────────────────────────────────────────────────────────────────
return view.extend({

	handleSaveApply(ev) {
		return this.handleSave(ev).then(() => {
			ui.changes.apply(true);
			return callServiceControl('restart');
		});
	},

	load() {
		return Promise.all([
			uci.load('singbox-server')
		]);
	},

	render() {
		const m = new form.Map('singbox-server',
			_('Sing-Box Server'),
			_('Configure an independent sing-box inbound server. '
			+ 'Each server section defines one inbound listener with its own protocol, '
			+ 'authentication, TLS and transport settings.'));

		// ── Status banner ──────────────────────────────────────────────
		const statusSection = m.section(form.NamedSection, '_status', 'singbox-server');
		statusSection.anonymous = true;
		statusSection.addremove  = false;

		const statusWidget = statusSection.option(form.DummyValue, '_status_widget');
		statusWidget.cfgvalue = () => '';
		statusWidget.render = function(section_id) {
			const el = E('div', { class: 'cbi-value' });
			const statusEl = E('div');
			el.appendChild(statusEl);
			renderStatusBanner(statusEl);

			// Refresh status every 5 seconds
			poll.add(() => renderStatusBanner(statusEl), 5);

			return el;
		};

		// ── Global settings ────────────────────────────────────────────
		const gs = m.section(form.NamedSection, 'config', 'singbox-server',
			_('Global Settings'));
		gs.anonymous = false;
		gs.addremove  = false;

		let o;

		o = gs.option(form.Flag, 'enabled', _('Enable'));
		o.rmempty = false;

		o = gs.option(form.ListValue, 'log_level', _('Log Level'));
		LOG_LEVELS.forEach(([v, l]) => o.value(v, l));
		o.default = 'warn';

		// ── Server sections ────────────────────────────────────────────
		const ss = m.section(form.GridSection, 'server', _('Server Instances'));
		ss.anonymous = false;
		ss.addremove  = true;
		ss.sortable   = true;
		ss.nodescriptions = false;

		ss.modaltitle = function(section_id) {
			const label = uci.get('singbox-server', section_id, 'label');
			return label ? _('Edit Server') + ' – ' + label : _('Add Server');
		};

		// Validate unique label+port per section
		ss.filter = () => true;

		// ── Basic fields (visible in grid row) ────────────────────
		o = ss.option(form.Flag, 'enabled', _('En.'));
		o.rmempty = false;

		o = ss.option(form.Value, 'label', _('Label'));
		o.rmempty  = false;
		o.datatype = 'uciname';
		o.validate = function(section_id, value) {
			if (!value) return _('Label is required');
			// Uniqueness check
			const sections = uci.sections('singbox-server', 'server');
			for (const s of sections) {
				if (s['.name'] !== section_id && s.label === value)
					return _('Label must be unique');
			}
			return true;
		};

		o = ss.option(form.ListValue, 'type', _('Type'));
		SERVER_TYPES.forEach(([v, l]) => o.value(v, l));
		o.rmempty = false;

		o = ss.option(form.Value, 'port', _('Listen Port'));
		o.datatype = 'port';
		o.rmempty  = false;
		o.validate = function(section_id, value) {
			if (!value) return _('Port is required');
			const sections = uci.sections('singbox-server', 'server');
			for (const s of sections) {
				if (s['.name'] !== section_id && s.port === value)
					return _('Port must be unique');
			}
			return true;
		};

		o = ss.option(form.Value, 'address', _('Listen Address'));
		o.placeholder = '::';
		o.rmempty     = true;

		// ─────────────────────────────────────────────────────────────
		// Authentication / Protocol parameters (modal only)
		// ─────────────────────────────────────────────────────────────
		o = ss.option(form.Value, 'username', _('Username'));
		o.depends({ type: 'mixed' });
		o.depends({ type: 'http'  });
		o.depends({ type: 'socks' });
		o.depends({ type: 'naive' });
		o.modalonly = true;

		o = ss.option(form.Value, 'password', _('Password'));
		o.depends({ type: 'mixed'       });
		o.depends({ type: 'http'        });
		o.depends({ type: 'socks'       });
		o.depends({ type: 'shadowsocks' });
		o.depends({ type: 'trojan'      });
		o.depends({ type: 'hysteria'    });
		o.depends({ type: 'hysteria2'   });
		o.depends({ type: 'tuic'        });
		o.depends({ type: 'naive'       });
		o.depends({ type: 'anytls'      });
		o.password  = true;
		o.modalonly = true;

		// UUID (VLESS / VMess / TUIC)
		o = ss.option(form.Value, 'uuid', _('UUID'));
		o.depends({ type: 'vless' });
		o.depends({ type: 'vmess' });
		o.depends({ type: 'tuic'  });
		o.validate = function(section_id, value) {
			if (!value) return true;
			if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value))
				return _('Please enter a valid UUID v4');
			return true;
		};
		o.modalonly = true;

		// UUID generate button
		o = ss.option(form.Button, '_uuid_gen', _('Generate UUID'));
		o.depends({ type: 'vless' });
		o.depends({ type: 'vmess' });
		o.depends({ type: 'tuic'  });
		o.inputtitle = _('Generate');
		o.onclick = function(ev, section_id) {
			return genUUID().then(uuid => {
				const uuidField = this.map.lookupOption('uuid', section_id);
				if (uuidField && uuidField[0])
					uuidField[0].getUIElement(section_id).setValue(uuid);
			}).catch(err => ui.addNotification(null, E('p', err.message), 'danger'));
		};
		o.modalonly = true;

		// VLESS flow
		o = ss.option(form.ListValue, 'vless_flow', _('VLESS Flow'));
		o.depends({ type: 'vless' });
		VLESS_FLOWS.forEach(([v, l]) => o.value(v, l));
		o.modalonly = true;

		// Shadowsocks method
		o = ss.option(form.ListValue, 'shadowsocks_encrypt_method',
			_('Encryption Method'));
		o.depends({ type: 'shadowsocks' });
		[
			'aes-128-gcm', 'aes-256-gcm', 'chacha20-ietf-poly1305',
			'xchacha20-ietf-poly1305', 'none',
			'2022-blake3-aes-128-gcm', '2022-blake3-aes-256-gcm',
			'2022-blake3-chacha20-poly1305'
		].forEach(m => o.value(m, m));
		o.default    = 'aes-128-gcm';
		o.modalonly  = true;

		// Shadowsocks / NaïveProxy network
		o = ss.option(form.ListValue, 'network', _('Network'));
		o.depends({ type: 'shadowsocks' });
		o.depends({ type: 'naive'       });
		o.value('',    _('TCP and UDP'));
		o.value('tcp', _('TCP only'));
		o.value('udp', _('UDP only'));
		o.modalonly = true;

		// ─── Hysteria v1 specific ──────────────────────────────────────
		o = ss.option(form.Value, 'hysteria_up_mbps', _('Max Upload (Mbps)'));
		o.depends({ type: 'hysteria' });
		o.datatype  = 'uinteger';
		o.default   = '100';
		o.modalonly = true;

		o = ss.option(form.Value, 'hysteria_down_mbps', _('Max Download (Mbps)'));
		o.depends({ type: 'hysteria' });
		o.datatype  = 'uinteger';
		o.default   = '100';
		o.modalonly = true;

		// ─── Hysteria2 specific ────────────────────────────────────────
		o = ss.option(form.Value, 'hysteria2_up_mbps', _('Max Upload (Mbps)'));
		o.depends({ type: 'hysteria2' });
		o.datatype  = 'uinteger';
		o.modalonly = true;

		o = ss.option(form.Value, 'hysteria2_down_mbps', _('Max Download (Mbps)'));
		o.depends({ type: 'hysteria2' });
		o.datatype  = 'uinteger';
		o.modalonly = true;

		o = ss.option(form.Flag, 'hysteria2_ignore_client_bandwidth',
			_('Ignore Client Bandwidth'));
		o.depends({ type: 'hysteria2' });
		o.modalonly = true;

		// ─── TUIC specific ────────────────────────────────────────────
		o = ss.option(form.ListValue, 'tuic_congestion_control',
			_('Congestion Control'));
		o.depends({ type: 'tuic' });
		TUIC_CC.forEach(([v, l]) => o.value(v, l));
		o.default   = 'cubic';
		o.modalonly = true;

		o = ss.option(form.Flag, 'tuic_zero_rtt_handshake',
			_('Zero-RTT Handshake'));
		o.depends({ type: 'tuic' });
		o.modalonly = true;

		o = ss.option(form.Value, 'tuic_heartbeat', _('Heartbeat Interval'));
		o.depends({ type: 'tuic' });
		o.placeholder = '10s';
		o.modalonly   = true;

		// ─── AnyTLS specific ──────────────────────────────────────────
		o = ss.option(form.Value, 'anytls_idle_session_check_interval',
			_('Idle Session Check Interval'));
		o.depends({ type: 'anytls' });
		o.placeholder = '30s';
		o.modalonly   = true;

		o = ss.option(form.Value, 'anytls_idle_session_timeout',
			_('Idle Session Timeout'));
		o.depends({ type: 'anytls' });
		o.placeholder = '30s';
		o.modalonly   = true;

		// ─────────────────────────────────────────────────────────────
		// Transport
		// ─────────────────────────────────────────────────────────────
		o = ss.option(form.ListValue, 'transport', _('Transport'));
		TRANSPORT_TYPES.forEach(([v, l]) => o.value(v, l));
		o.default    = 'none';
		o.modalonly  = true;

		// WebSocket
		o = ss.option(form.Value, 'ws_path', _('WebSocket Path'));
		o.depends({ transport: 'ws' });
		o.placeholder = '/';
		o.modalonly   = true;

		o = ss.option(form.Value, 'ws_host', _('WebSocket Host (override)'));
		o.depends({ transport: 'ws' });
		o.modalonly = true;

		// gRPC
		o = ss.option(form.Value, 'grpc_service_name', _('gRPC Service Name'));
		o.depends({ transport: 'grpc' });
		o.placeholder = 'GunService';
		o.modalonly   = true;

		// HTTP/2
		o = ss.option(form.Value, 'http_path', _('HTTP/2 Path'));
		o.depends({ transport: 'http' });
		o.placeholder = '/';
		o.modalonly   = true;

		o = ss.option(form.Value, 'http_host', _('HTTP/2 Host'));
		o.depends({ transport: 'http' });
		o.modalonly = true;

		// HTTPUpgrade
		o = ss.option(form.Value, 'httpupgrade_path', _('HTTPUpgrade Path'));
		o.depends({ transport: 'httpupgrade' });
		o.placeholder = '/';
		o.modalonly   = true;

		o = ss.option(form.Value, 'httpupgrade_host', _('HTTPUpgrade Host'));
		o.depends({ transport: 'httpupgrade' });
		o.modalonly = true;

		// ─────────────────────────────────────────────────────────────
		// Multiplexing
		// ─────────────────────────────────────────────────────────────
		o = ss.option(form.Flag, 'multiplex', _('Multiplexing'));
		o.modalonly = true;

		o = ss.option(form.Flag, 'multiplex_padding',
			_('Multiplex Padding'));
		o.depends({ multiplex: '1' });
		o.modalonly = true;

		o = ss.option(form.Flag, 'multiplex_brutal',
			_('TCP Brutal Congestion Control'));
		o.depends({ multiplex: '1' });
		o.modalonly = true;

		o = ss.option(form.Value, 'multiplex_brutal_up',
			_('Brutal Upload (Mbps)'));
		o.depends({ multiplex: '1', multiplex_brutal: '1' });
		o.datatype  = 'uinteger';
		o.default   = '100';
		o.modalonly = true;

		o = ss.option(form.Value, 'multiplex_brutal_down',
			_('Brutal Download (Mbps)'));
		o.depends({ multiplex: '1', multiplex_brutal: '1' });
		o.datatype  = 'uinteger';
		o.default   = '100';
		o.modalonly = true;

		// ─────────────────────────────────────────────────────────────
		// TLS
		// ─────────────────────────────────────────────────────────────
		o = ss.option(form.Flag, 'tls', _('Enable TLS'));
		o.modalonly = true;

		o = ss.option(form.Value, 'tls_sni', _('SNI'));
		o.depends({ tls: '1' });
		o.modalonly = true;

		o = ss.option(form.Flag, 'tls_acme', _('ACME (Auto Certificate)'));
		o.depends({ tls: '1' });
		o.modalonly = true;

		o = ss.option(form.Flag, 'tls_reality', _('REALITY (VLESS only)'));
		o.depends({ tls: '1', type: 'vless' });
		o.modalonly = true;

		// ─── Manual certificate ──────────────────────────────────────
		o = ss.option(form.Value, 'tls_cert_path', _('Certificate Path'));
		o.depends('tls', '1');    // shown when TLS on + not ACME/Reality
		o.placeholder  = '/etc/singbox-server/certs/server.pem';
		o.validate = (id, v) => (!v || validCertPath(v)) || _('Path must be in /etc/singbox-server/certs/, /etc/acme/, or /etc/ssl/certs/');
		o.modalonly    = true;

		o = ss.option(form.Value, 'tls_key_path', _('Key Path'));
		o.depends('tls', '1');
		o.placeholder  = '/etc/singbox-server/certs/server.key';
		o.validate = (id, v) => (!v || validCertPath(v)) || _('Path must be in /etc/singbox-server/certs/, /etc/acme/, or /etc/ssl/certs/');
		o.modalonly    = true;

		// ── Cert upload helper ───────────────────────────────────────
		o = ss.option(form.Button, '_cert_upload', _('Upload Certificate / Key'));
		o.depends({ tls: '1' });
		o.inputtitle = _('Upload…');
		o.onclick = function(ev, section_id) {
			const input = document.createElement('input');
			input.type   = 'file';
			input.accept = '.pem,.crt,.cer,.key';
			input.onchange = (fileEv) => {
				const file = fileEv.target.files[0];
				if (!file) return;
				const reader = new FileReader();
				reader.onload = (readEv) => {
					callUploadCert(file.name, readEv.target.result).then(res => {
						if (res.error) {
							ui.addNotification(null, E('p', _('Upload failed: ') + res.error), 'danger');
						} else {
							ui.addNotification(null, E('p', _('Uploaded to: ') + res.path), 'success');
						}
					});
				};
				reader.readAsText(file);
			};
			input.click();
		};
		o.modalonly = true;

		// ─── ACME settings ───────────────────────────────────────────
		o = ss.option(form.Value, 'tls_acme_domain', _('ACME Domain(s)'));
		o.depends({ tls: '1', tls_acme: '1' });
		o.placeholder  = 'example.com';
		o.modalonly    = true;

		o = ss.option(form.Value, 'tls_acme_email', _('ACME E-mail'));
		o.depends({ tls: '1', tls_acme: '1' });
		o.datatype  = 'email';
		o.modalonly = true;

		o = ss.option(form.ListValue, 'tls_acme_provider', _('ACME CA Provider'));
		o.depends({ tls: '1', tls_acme: '1' });
		ACME_PROVIDERS.forEach(([v, l]) => o.value(v, l));
		o.default   = 'letsencrypt';
		o.modalonly = true;

		o = ss.option(form.Flag, 'tls_acme_disable_http_challenge',
			_('Disable HTTP-01 Challenge'));
		o.depends({ tls: '1', tls_acme: '1' });
		o.modalonly = true;

		o = ss.option(form.Value, 'tls_acme_http01_port',
			_('HTTP-01 Alternative Port'));
		o.depends({ tls: '1', tls_acme: '1' });
		o.datatype  = 'port';
		o.modalonly = true;

		o = ss.option(form.Value, 'tls_acme_tlsalpn01_port',
			_('TLS-ALPN-01 Alternative Port'));
		o.depends({ tls: '1', tls_acme: '1' });
		o.datatype  = 'port';
		o.modalonly = true;

		// DNS-01 challenge
		o = ss.option(form.ListValue, 'tls_acme_dns_provider',
			_('DNS-01 Provider'));
		o.depends({ tls: '1', tls_acme: '1' });
		o.value('', _('None (use HTTP/TLS-ALPN)'));
		DNS_PROVIDERS.forEach(([v, l]) => o.value(v, l));
		o.modalonly = true;

		o = ss.option(form.Value, 'tls_acme_dns_access_key_id',
			_('DNS Access Key ID'));
		o.depends({ tls: '1', tls_acme: '1', tls_acme_dns_provider: 'alidns' });
		o.modalonly = true;

		o = ss.option(form.Value, 'tls_acme_dns_access_key_secret',
			_('DNS Access Key Secret'));
		o.depends({ tls: '1', tls_acme: '1', tls_acme_dns_provider: 'alidns' });
		o.password  = true;
		o.modalonly = true;

		// EAB (External Account Binding)
		o = ss.option(form.Value, 'tls_acme_eab_kid', _('EAB Key ID'));
		o.depends({ tls: '1', tls_acme: '1' });
		o.modalonly = true;

		o = ss.option(form.Value, 'tls_acme_eab_hmac_key', _('EAB HMAC Key'));
		o.depends({ tls: '1', tls_acme: '1' });
		o.password  = true;
		o.modalonly = true;

		// ─── REALITY settings ───────────────────────────────────────
		o = ss.option(form.Value, 'tls_reality_handshake_server',
			_('REALITY Handshake Server'));
		o.depends({ tls: '1', tls_reality: '1' });
		o.placeholder  = 'google.com';
		o.modalonly    = true;

		o = ss.option(form.Value, 'tls_reality_handshake_port',
			_('REALITY Handshake Port'));
		o.depends({ tls: '1', tls_reality: '1' });
		o.datatype     = 'port';
		o.default      = '443';
		o.modalonly    = true;

		o = ss.option(form.Value, 'tls_reality_private_key',
			_('REALITY Private Key'));
		o.depends({ tls: '1', tls_reality: '1' });
		o.password  = true;
		o.modalonly = true;

		o = ss.option(form.Value, 'tls_reality_short_id',
			_('REALITY Short ID(s) (comma-separated)'));
		o.depends({ tls: '1', tls_reality: '1' });
		o.placeholder = 'e.g. abcdef01, 12345678';
		o.modalonly   = true;

		// Reality key pair generator
		o = ss.option(form.Button, '_reality_keygen', _('Generate REALITY Key Pair'));
		o.depends({ tls: '1', tls_reality: '1' });
		o.inputtitle = _('Generate');
		o.onclick = function(ev, section_id) {
			return genKeypair('reality-keypair', null).then(result => {
				const kp = typeof result === 'object' ? result : JSON.parse(result);
				const privField = this.map.lookupOption('tls_reality_private_key', section_id);
				if (privField && privField[0])
					privField[0].getUIElement(section_id).setValue(kp.private_key || kp.PrivateKey || '');
				ui.addNotification(null,
					E('div', [
						E('p', _('Public Key (share with clients):') + ' ' + (kp.public_key || kp.PublicKey || '')),
						E('p', _('Private Key was filled into the field above.'))
					]), 'success');
			}).catch(err => ui.addNotification(null, E('p', err.message), 'danger'));
		};
		o.modalonly = true;

		// ─── ECH ────────────────────────────────────────────────────
		o = ss.option(form.Flag, 'tls_ech', _('ECH (Encrypted Client Hello)'));
		o.depends({ tls: '1' });
		o.modalonly = true;

		o = ss.option(form.Value, 'tls_ech_key', _('ECH Private Key'));
		o.depends({ tls: '1', tls_ech: '1' });
		o.password  = true;
		o.modalonly = true;

		o = ss.option(form.Value, 'tls_ech_config', _('ECH Config (for clients)'));
		o.depends({ tls: '1', tls_ech: '1' });
		o.modalonly = true;

		// ECH key pair generator
		o = ss.option(form.Button, '_ech_keygen', _('Generate ECH Key Pair'));
		o.depends({ tls: '1', tls_ech: '1' });
		o.inputtitle = _('Generate');
		o.onclick = function(ev, section_id) {
			const sniField = this.map.lookupOption('tls_sni', section_id);
			const sni = sniField?.[0]?.formvalue(section_id) || 'example.com';
			return genKeypair('ech-keypair', sni).then(result => {
				const kp = typeof result === 'object' ? result
					: (() => { try { return JSON.parse(result); } catch { return null; } })();
				if (kp) {
					const keyField = this.map.lookupOption('tls_ech_key', section_id);
					const cfgField = this.map.lookupOption('tls_ech_config', section_id);
					if (keyField?.[0]) keyField[0].getUIElement(section_id).setValue(kp.key || '');
					if (cfgField?.[0]) cfgField[0].getUIElement(section_id).setValue(kp.config || '');
				} else {
					ui.addNotification(null, E('pre', result), 'success');
				}
			}).catch(err => ui.addNotification(null, E('p', err.message), 'danger'));
		};
		o.modalonly = true;

		// ─── Advanced options ────────────────────────────────────────
		o = ss.option(form.Flag, 'sniff', _('Protocol Sniffing'));
		o.modalonly = true;

		o = ss.option(form.Flag, 'sniff_override_destination',
			_('Override Destination on Sniff'));
		o.depends({ sniff: '1' });
		o.modalonly = true;

		o = ss.option(form.Flag, 'tcp_fast_open', _('TCP Fast Open'));
		o.modalonly = true;

		o = ss.option(form.Flag, 'tcp_multi_path', _('TCP Multi-Path'));
		o.modalonly = true;

		o = ss.option(form.Flag, 'udp_fragment', _('UDP Fragment'));
		o.modalonly = true;

		return m.render();
	}
});
