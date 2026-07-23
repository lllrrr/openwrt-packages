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

function validateEndpoint(_sid, value) {
	var match = /^\[([0-9A-Fa-f:.]+)\]:(\d+)$/.exec(value || '') ||
		/^([^:\s]+):(\d+)$/.exec(value || '');
	if (!match || +match[2] < 1 || +match[2] > 65535)
		return _('Enter an endpoint as host:port (bracket IPv6 addresses).');
	return true;
}

function setFormValue(id, value) {
	var input = document.getElementById(id);
	if (!input) return;
	input.value = value;
	input.dispatchEvent(new Event('change', { bubbles: true }));
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

		o = s.option(form.ListValue, 'egress_interface', _('Egress Interface'),
			_('Send this NaiveProxy node\'s server connection through the selected OpenWrt network. The first option inherits Default Naive Interface.'));
		o.value('', _('(use default naive interface)'));
		ifaces.forEach(function (iface) { o.value(iface, iface); });
		o.depends('node_type', 'naiveproxy');

		var secretOption = s.option(form.Value, 'secret_key', _('Secret Key'));
		secretOption.password = true;
		secretOption.rmempty = false;
		secretOption.validate = validateWGKey;
		secretOption.depends('node_type', 'wireguard');

		var keyButton = s.option(form.Button, '_generate_keypair', _('Generate Key Pair'));
		keyButton.inputstyle = 'add';
		keyButton.inputtitle = _('Generate');
		keyButton.description = _('Generate a new local private key and derive its public key.');
		keyButton.depends('node_type', 'wireguard');

		var publicOption = s.option(form.Value, 'public_key', _('Public Key'));
		publicOption.rmempty = false;
		publicOption.validate = validateWGKey;
		publicOption.description = _('Automatically filled when a local key pair is generated.');
		publicOption.depends('node_type', 'wireguard');

		keyButton.onclick = function (ev) {
			ev.currentTarget.disabled = true;
			return api('wireguard_keypair').then(function (result) {
				ev.currentTarget.disabled = false;
				if (result.code !== 0 || !result.secretKey || !result.publicKey) {
					ui.addNotification(null, E('p', {}, result.error || _('WireGuard key generation failed.')));
					return;
				}
				setFormValue(secretOption.cbid(sid), result.secretKey);
				setFormValue(publicOption.cbid(sid), result.publicKey);
			});
		};

		o = s.option(form.DynamicList, 'wireguard_address', _('Address'));
		o.datatype = 'cidr';
		o.placeholder = '10.0.0.2/32';
		o.description = _('Local tunnel addresses. If omitted, BypassCore uses its compatibility addresses; normally enter the addresses assigned by the provider.');
		o.depends('node_type', 'wireguard');

		o = s.option(form.Value, 'mtu', _('MTU'));
		o.datatype = 'range(576,65535)';
		o.default = '1420';
		o.placeholder = '1420';
		o.depends('node_type', 'wireguard');

		var peers = m.section(form.TableSection, 'wireguard_peer', _('WireGuard Peers'),
			_('At least one peer is required. Allowed IPs default to 0.0.0.0/0 and ::/0 when left empty.'));
		peers.anonymous = true;
		peers.addremove = true;
		peers.max_cols = 2;
		peers.filter = function (peerSid) {
			return uci.get('bypass', peerSid, 'node') === sid;
		};
		peers.handleAdd = function () {
			var peerSid = uci.add('bypass', 'wireguard_peer');
			uci.set('bypass', peerSid, 'node', sid);
			uci.set('bypass', peerSid, 'allowed_ips', [ '0.0.0.0/0', '::/0' ]);
			return this.map.save(null, true);
		};

		o = peers.option(form.Value, 'public_key', _('Peer Public Key'));
		o.rmempty = false;
		o.validate = validateWGKey;

		o = peers.option(form.Value, 'endpoint', _('Endpoint'));
		o.rmempty = false;
		o.placeholder = 'vpn.example.com:51820';
		o.validate = validateEndpoint;

		o = peers.option(form.DynamicList, 'allowed_ips', _('Allowed IPs'));
		o.datatype = 'cidr';
		o.placeholder = '0.0.0.0/0';

		var pskOption = peers.option(form.Value, 'pre_shared_key', _('Pre-Shared Key'));
		pskOption.password = true;
		pskOption.validate = validateOptionalWGKey;

		var pskButton = peers.option(form.Button, '_generate_psk', _('Generate Pre-Shared Key'));
		pskButton.inputstyle = 'add';
		pskButton.inputtitle = _('Generate');
		pskButton.onclick = function (ev, peerSid) {
			ev.currentTarget.disabled = true;
			return api('wireguard_psk').then(function (result) {
				ev.currentTarget.disabled = false;
				if (result.code !== 0 || !result.preSharedKey) {
					ui.addNotification(null, E('p', {}, result.error || _('WireGuard preshared key generation failed.')));
					return;
				}
				setFormValue(pskOption.cbid(peerSid), result.preSharedKey);
			});
		};

		o = peers.option(form.Value, 'keep_alive', _('Persistent Keepalive'));
		o.datatype = 'range(0,65535)';
		o.placeholder = '25';
		o.description = _('Seconds; leave empty or use 0 to disable.');

		return m.render().then(function (node) {
			var selector = node.querySelector('#' + typeOption.cbid(sid).replace(/\./g, '\\.'));
			var peerSection = node.querySelector('#cbi-bypass-wireguard_peer');
			var togglePeers = function () {
				if (peerSection)
					peerSection.style.display = selector && selector.value === 'wireguard' ? '' : 'none';
			};
			if (selector) selector.addEventListener('change', togglePeers);
			togglePeers();
			return node;
		});
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
