'use strict';
'require view';
'require rpc';
'require uci';
'require form';
'require ui';

var callRestart = rpc.declare({
	object: 'atomdns',
	method: 'restart',
	params: []
});

function showError(e) {
	ui.showModal(_('Operation failed'), [
		E('p', {}, String(e && e.message ? e.message : e)),
		E('div', { 'class': 'right' }, [
			E('button', {
				'class': 'btn',
				'type': 'button',
				'click': function() { ui.hideModal(); }
			}, _('Close'))
		])
	]);
}

// UCI may be edited outside LuCI, so never interpolate an unvalidated value
// into a URL: "9099@evil.example" would otherwise turn the host into user info.
function validWebUIPort(value) {
	var port = String(value || '');
	if (!/^[0-9]{1,5}$/.test(port))
		return null;

	var n = Number(port);
	return (n >= 1 && n <= 65535) ? port : null;
}

function webUIURL() {
	var port = validWebUIPort(uci.get('atomdns', 'main', 'webui_port') || '9099');
	if (!port)
		throw new Error(_('Invalid WebUI port'));

	var host = window.location.hostname || window.location.host;
	if (!host || /[\s/?#@\\]/.test(host))
		throw new Error(_('Invalid WebUI host'));

	// AtomDNS only serves plain HTTP; do not inherit LuCI's HTTPS scheme.
	var url = 'http://' + host + ':' + port + '/';
	var parsed = new URL(url);
	var currentHost = String(window.location.hostname || '').replace(/^\[|\]$/g, '');
	var targetHost = parsed.hostname.replace(/^\[|\]$/g, '');

	if (parsed.protocol !== 'http:' || parsed.port !== port || targetHost !== currentHost)
		throw new Error(_('Invalid WebUI URL'));

	return url;
}

return view.extend({
	load: function () {
		return uci.load('atomdns');
	},

	render: function () {
		var m, s, o;

		m = new form.Map('atomdns', _('AtomDNS'),
			_('A Rust DNS splitter with domestic/overseas routing, FakeIP, route learning and a built-in WebUI.'));

		// ---------- 服务设置 ----------
		s = m.section(form.NamedSection, 'main', 'atomdns', _('Service settings'));

		o = s.option(form.Flag, 'enabled', _('Enabled'),
			_('Run under procd and start on boot when enabled; no ports are bound when disabled.'));
		o.default = '0';
		o.rmempty = false;

		o = s.option(form.Value, 'dns_port', _('DNS listen port'),
			_('Default 2053 to avoid dnsmasq on port 53. Disable the dnsmasq DNS listener first before taking over port 53.'));
		o.datatype = 'port';
		o.default = '2053';
		o.rmempty = false;

		o = s.option(form.Value, 'webui_port', _('WebUI port'),
			_('Built-in management port, 9099 by default. Restart the service and use the button below after changing it.'));
		o.datatype = 'port';
		o.default = '9099';
		o.rmempty = false;

		o = s.option(form.Value, 'config_dir', _('Configuration directory'),
			_('Initialised from the bundled config package on first start; rules, cache and learned data are stored here.'));
		o.default = '/etc/atomdns';
		o.rmempty = false;

		o = s.option(form.Value, 'log_file', _('Log file'));
		o.default = '/tmp/atomdns.log';
		o.rmempty = false;

		// ---------- 操作按钮 ----------
		var btnOpen = E('button', {
			'class': 'btn cbi-button-action',
			'type': 'button',
			'click': function (ev) {
				ev.preventDefault();
				try {
					window.open(webUIURL(), '_blank', 'noopener,noreferrer');
				}
				catch (e) {
					showError(e);
				}
			}
		}, _('Open WebUI'));

		var btnRestart = E('button', {
			'class': 'btn',
			'type': 'button',
			'click': function (ev) {
				ev.preventDefault();
				var btn = ev.currentTarget;
				btn.disabled = true;
				// Use a separate catch(): a throw inside the success handler
				// is not handled by then()'s onRejected argument.
				return callRestart().then(function (res) {
					btn.disabled = false;
					if (res && res.result && res.result !== 'ok')
						throw new Error(res.message || _('Operation failed'));

					window.location.reload();
				}).catch(function (e) {
					btn.disabled = false;
					showError(e);
				});
			}
		}, _('Restart service'));

		var actions = E('div', { 'class': 'cbi-section' }, [
			E('p', { 'class': 'cbi-section-descr' },
				_('The built-in WebUI requires a running service and browser access to this port on the router.')),
			E('div', { 'style': 'display:flex;gap:8px;flex-wrap:wrap' }, [btnOpen, btnRestart])
		]);

		return m.render().then(function (mapEl) {
			return [mapEl, actions];
		});
	}
});
