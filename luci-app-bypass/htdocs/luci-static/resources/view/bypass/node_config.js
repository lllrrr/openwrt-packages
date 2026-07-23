'use strict';
'require view';
'require form';
'require uci';
'require fs';
'require ui';

function api(/* action, ...args */) {
	return fs.exec('/usr/share/bypass/api.sh', Array.prototype.slice.call(arguments)).then(function (res) {
		try { return JSON.parse(res.stdout || '{}'); }
		catch (e) { return { code: -1, error: 'bad JSON: ' + res.stdout }; }
	}).catch(function (e) { return { code: -1, error: String(e) }; });
}

function currentSection() {
	return new URLSearchParams(window.location.search).get('section');
}

function validateWGKey(_sid, value) {
	if (/^[A-Za-z0-9+/]{43}=$/.test(value || '') || /^[A-Fa-f0-9]{64}$/.test(value || ''))
		return true;
	return _('Enter a 32-byte WireGuard key in base64 or hexadecimal form.');
}

function validateOptionalWGKey(sid, value) {
	return value ? validateWGKey(sid, value) : true;
}

function setFormValue(option, sectionId, value) {
	var widget = option.getUIElement(sectionId);
	if (widget) {
		widget.setValue(value);
		widget.triggerValidation();
	}
}

return view.extend({
	load: function () {
		return Promise.all([
			uci.load('bypass'),
			api('interfaces')
		]).then(function (res) {
			return { interfaces: (res[1] && res[1].interfaces) || [] };
		});
	},

	render: function (data) {
		var sid = currentSection();
		var ifaces = data.interfaces || [];

		if (!sid || uci.get('bypass', sid, '.type') !== 'nodes') {
			var hint = new form.Map('bypass', _('Node Config'));
			var hs = hint.section(form.NamedSection, '__dummy__', 'nodes', _('No node selected'));
			hs.option(form.DummyValue, '_hint', _('Pick a node from the Node List to edit, or add a new one there.')).optional = true;
			return hint.render();
		}

		var m = new form.Map('bypass');
		var s = m.section(form.NamedSection, sid, 'nodes');
		var o;

		var typeOption = s.option(form.ListValue, 'node_type', _('Type'));
		typeOption.value('naiveproxy', 'NaiveProxy');
		typeOption.value('wireguard', 'WireGuard');
		typeOption.default = 'naiveproxy';
		typeOption.rmempty = false;

		o = s.option(form.Value, 'remarks', _('Remarks'));
		o.rmempty = false;

		o = s.option(form.ListValue, 'protocol', _('Protocol'));
		o.value('https', 'HTTPS');
		o.value('quic', 'QUIC');
		o.default = 'https';
		o.rmempty = false;
		o.depends('node_type', 'naiveproxy');

		o = s.option(form.Value, 'address', _('Address (server)'));
		o.description = _('Domain or IP of the NaiveProxy server.');
		o.datatype = 'host';
		o.rmempty = false;
		o.depends('node_type', 'naiveproxy');

		o = s.option(form.Value, 'port', _('Port'));
		o.datatype = 'port';
		o.placeholder = '443';
		o.rmempty = false;
		o.depends('node_type', 'naiveproxy');

		o = s.option(form.Value, 'username', _('Username'));
		o.depends('node_type', 'naiveproxy');

		o = s.option(form.Value, 'password', _('Password'));
		o.password = true;
		o.depends('node_type', 'naiveproxy');

		o = s.option(form.ListValue, '_naive_egress_interface', _('Egress Interface'),
			_('Send this NaiveProxy node\'s server connection through the selected OpenWrt network. The first option inherits Default Naive Interface.'));
		o.ucioption = 'egress_interface';
		o.value('', _('(use default naive interface)'));
		ifaces.forEach(function (iface) { o.value(iface, iface); });
		o.depends('node_type', 'naiveproxy');

		o = s.option(form.Value, 'peer_public_key', _('Endpoint Public Key'));
		o.rmempty = false;
		o.validate = validateWGKey;
		o.depends('node_type', 'wireguard');

		o = s.option(form.Value, 'peer_address', _('Endpoint Address'));
		o.datatype = 'host';
		o.rmempty = false;
		o.depends('node_type', 'wireguard');

		o = s.option(form.Value, 'peer_port', _('Endpoint Port'));
		o.datatype = 'range(1,65535)';
		o.placeholder = '51820';
		o.rmempty = false;
		o.depends('node_type', 'wireguard');

		var secretOption = s.option(form.Value, 'secret_key', _('Local Private Key'));
		secretOption.password = true;
		secretOption.rmempty = false;
		secretOption.validate = validateWGKey;
		secretOption.depends('node_type', 'wireguard');

		var keyButton = s.option(form.Button, '_generate_keypair', _('Generate Key Pair'));
		keyButton.inputstyle = 'add';
		keyButton.inputtitle = _('Generate');
		keyButton.description = _('Generate a new local private key and derive its public key.');
		keyButton.depends('node_type', 'wireguard');

		var publicOption = s.option(form.Value, 'public_key', _('Local Public Key'));
		publicOption.rmempty = false;
		publicOption.validate = validateWGKey;
		publicOption.description = _('Automatically filled when a local key pair is generated.');
		publicOption.depends('node_type', 'wireguard');
		publicOption.renderWidget = function (sectionId, _optionIndex, cfgvalue) {
			return new ui.Textfield((cfgvalue != null) ? cfgvalue : '', {
				id: this.cbid(sectionId),
				optional: false,
				validate: this.getValidator(sectionId),
				readonly: true,
				disabled: this.map.readonly
			}).render();
		};

		var pskOption = s.option(form.Value, 'pre_shared_key', _('Pre-Shared Key'));
		pskOption.password = true;
		pskOption.validate = validateOptionalWGKey;
		pskOption.depends('node_type', 'wireguard');

		var pskButton = s.option(form.Button, '_generate_psk', _('Generate Pre-Shared Key'));
		pskButton.inputstyle = 'add';
		pskButton.inputtitle = _('Generate');
		pskButton.depends('node_type', 'wireguard');
		pskButton.onclick = function (ev) {
			var button = ev.currentTarget;
			button.disabled = true;
			return api('wireguard_psk').then(function (result) {
				button.disabled = false;
				if (result.code !== 0 || !result.preSharedKey) {
					ui.addNotification(null, E('p', {}, result.error || _('WireGuard preshared key generation failed.')));
					return;
				}
				setFormValue(pskOption, sid, result.preSharedKey);
			});
		};

		keyButton.onclick = function (ev) {
			var button = ev.currentTarget;
			button.disabled = true;
			return api('wireguard_keypair').then(function (result) {
				button.disabled = false;
				if (result.code !== 0 || !result.secretKey || !result.publicKey) {
					ui.addNotification(null, E('p', {}, result.error || _('WireGuard key generation failed.')));
					return;
				}
				setFormValue(secretOption, sid, result.secretKey);
				setFormValue(publicOption, sid, result.publicKey);
			});
		};

		o = s.option(form.DynamicList, 'wireguard_address', _('Local Address'));
		o.datatype = 'cidr';
		o.placeholder = '10.0.0.2/32';
		o.description = _('Local tunnel addresses. If omitted, BypassCore uses compatibility addresses; normally enter the addresses assigned by the provider.');
		o.depends('node_type', 'wireguard');

		o = s.option(form.Value, 'mtu', _('MTU'));
		o.datatype = 'range(576,65535)';
		o.default = '1420';
		o.placeholder = '1420';
		o.depends('node_type', 'wireguard');

		o = s.option(form.Value, 'keep_alive', _('Persistent Keepalive'));
		o.datatype = 'range(0,65535)';
		o.placeholder = '25';
		o.description = _('Seconds; leave empty or use 0 to disable.');
		o.depends('node_type', 'wireguard');

		o = s.option(form.ListValue, '_wireguard_egress_interface', _('Egress Interface'),
			_('Send this WireGuard endpoint connection through the selected OpenWrt network.'));
		o.ucioption = 'egress_interface';
		o.value('', _('(system default route)'));
		ifaces.forEach(function (iface) { o.value(iface, iface); });
		o.depends('node_type', 'wireguard');

		return m.render();
	},

	addFooter: function () {
		var footer = this.super('addFooter', []);
		var actions = footer.querySelector('.cbi-page-actions');
		if (actions) {
			actions.insertBefore(E('button', {
				type: 'button',
				class: 'cbi-button cbi-button-neutral',
				click: function () { window.location.assign(L.url('admin/services/bypass/node_list')); }
			}, _('Back')), actions.firstChild);
			actions.insertBefore(document.createTextNode(' '), actions.childNodes[1] || null);
		}
		return footer;
	}
});
