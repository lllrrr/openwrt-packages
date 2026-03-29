'use strict';
'require view';
'require form';
'require uci';

return view.extend({
	render: function () {
		var m, s, o;

		m = new form.Map('hysteria', _('Hysteria2'),
			_('Hysteria2 PPP VPN client configuration.'));

		// Service section
		s = m.section(form.NamedSection, 'main', 'hysteria', _('Service'));
		s.anonymous = true;

		o = s.option(form.Flag, 'enabled', _('Enable'));
		o.rmempty = false;

		o = s.option(form.Value, 'config_file', _('Custom config file'),
			_('Path to a raw YAML config file. Leave empty to use the settings below.'));
		o.placeholder = '/etc/hysteria/config.yaml';
		o.optional = true;

		// Connection section
		s = m.section(form.NamedSection, 'client', 'client', _('Server Connection'));
		s.anonymous = true;

		o = s.option(form.Value, 'server', _('Server address'));
		o.placeholder = 'example.com:443';
		o.rmempty = false;
		o.datatype = 'string';

		o = s.option(form.Value, 'auth', _('Authentication'),
			_('Password for server authentication.'));
		o.password = true;
		o.optional = true;

		// TLS
		o = s.option(form.Value, 'tls_sni', _('TLS SNI'),
			_('Server Name Indication. Auto-detected from server address if empty.'));
		o.optional = true;

		o = s.option(form.Flag, 'tls_insecure', _('Skip TLS verification'),
			_('Disable certificate verification. Not recommended for production use.'));
		o.default = '0';

		o = s.option(form.Value, 'tls_pin_sha256', _('TLS certificate pin'),
			_('SHA-256 hash of the server certificate for pinning.'));
		o.optional = true;

		o = s.option(form.Value, 'tls_ca', _('Custom CA certificate'),
			_('Path to a custom CA certificate file.'));
		o.optional = true;

		// Bandwidth
		o = s.option(form.Value, 'bandwidth_up', _('Upload bandwidth'));
		o.placeholder = '100 mbps';
		o.optional = true;

		o = s.option(form.Value, 'bandwidth_down', _('Download bandwidth'));
		o.placeholder = '200 mbps';
		o.optional = true;

		// Obfuscation
		o = s.option(form.ListValue, 'obfs_type', _('Obfuscation type'));
		o.value('', _('None'));
		o.value('salamander', _('Salamander'));
		o.default = '';

		o = s.option(form.Value, 'obfs_password', _('Obfuscation password'));
		o.password = true;
		o.depends('obfs_type', 'salamander');

		// Transport
		o = s.option(form.Value, 'transport_hop_interval', _('Port hopping interval'),
			_('Interval for UDP port hopping. Leave empty to disable.'));
		o.placeholder = '30s';
		o.optional = true;

		// Advanced flags
		o = s.option(form.Flag, 'fast_open', _('Fast Open'),
			_('Accept connections immediately without waiting for server acknowledgement.'));
		o.default = '0';

		o = s.option(form.Flag, 'lazy', _('Lazy mode'),
			_('Only connect to the server when data arrives.'));
		o.default = '0';

		// Camouflage section
		s = m.section(form.NamedSection, 'camouflage', 'camouflage', _('Camouflage'));
		s.anonymous = true;

		o = s.option(form.Flag, 'enabled', _('Enable camouflage'),
			_('Obfuscate QUIC connection IDs using a pre-shared key.'));
		o.default = '0';

		o = s.option(form.Value, 'secret', _('Pre-shared key'),
			_('Base64-encoded pre-shared key for QUIC DCID generation.'));
		o.depends('enabled', '1');
		o.password = true;

		o = s.option(form.Value, 'server_ip', _('Server IP'),
			_('Real server IP address for camouflage DCID generation.'));
		o.depends('enabled', '1');
		o.datatype = 'ipaddr';

		return m.render();
	}
});
