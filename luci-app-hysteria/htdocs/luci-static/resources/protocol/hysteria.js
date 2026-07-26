'use strict';
'require form';
'require network';

network.registerPatternVirtual(/^hy-.+$/);

network.registerErrorCode('CONFIG_FILE_MISSING', _('Configuration file not found'));
network.registerErrorCode('CONFIG_WRITE_FAILED', _('Unable to write generated configuration'));
network.registerErrorCode('MISSING_SERVER', _('No server address specified'));

return network.registerProtocol('hysteria', {
	getI18n: function() {
		return _('Hysteria2 PPP');
	},

	getIfname: function() {
		return this._ubus('l3_device') || 'hy-%s'.format(this.sid);
	},

	getOpkgPackage: function() {
		return 'hysteria2-ppp';
	},

	isFloating: function() {
		return true;
	},

	isVirtual: function() {
		return true;
	},

	getDevices: function() {
		return null;
	},

	containsDevice: function(ifname) {
		return (network.getIfnameOf(ifname) == this.getIfname());
	},

	renderFormOptions: function(s) {
		var o;

		o = s.taboption('general', form.Value, 'server', _('Server address'),
			_('Hysteria 2 server, as <code>host:port</code>.'));
		o.rmempty = false;
		o.placeholder = 'example.com:443';

		o = s.taboption('general', form.Value, 'auth', _('Authentication'),
			_('Password or token expected by the server.'));
		o.password = true;

		o = s.taboption('general', form.Value, 'sni', _('TLS SNI'),
			_('Server name to present during the TLS handshake. Defaults to the server host.'));

		o = s.taboption('general', form.Flag, 'insecure', _('Skip certificate verification'),
			_('Disables TLS verification entirely. Prefer pinning a certificate or CA instead.'));
		o.default = o.disabled;

		o = s.taboption('general', form.Value, 'data_streams', _('Data streams'),
			_('Number of parallel QUIC streams carrying PPP data. Leave at 0 to use datagrams.'));
		o.placeholder = '0';
		o.datatype = 'range(0,64)';

		o = s.taboption('advanced', form.Value, 'ca', _('CA certificate'),
			_('Path to a PEM CA bundle used to verify the server.'));
		o.datatype = 'file';

		o = s.taboption('advanced', form.Value, 'pin_sha256', _('Certificate fingerprint'),
			_('Pin the server certificate by its SHA-256 fingerprint.'));

		o = s.taboption('advanced', form.ListValue, 'obfs_type', _('Obfuscation'),
			_('Salamander obfuscation must match the server. It cannot be combined with camouflage.'));
		o.value('', _('None'));
		o.value('salamander', _('Salamander'));
		o.default = '';

		o = s.taboption('advanced', form.Value, 'obfs_password', _('Obfuscation password'));
		o.password = true;
		o.depends('obfs_type', 'salamander');

		o = s.taboption('advanced', form.Value, 'bandwidth_up', _('Upload bandwidth'),
			_('Advertised upload rate, for example <code>20 mbps</code>.'));

		o = s.taboption('advanced', form.Value, 'bandwidth_down', _('Download bandwidth'),
			_('Advertised download rate, for example <code>100 mbps</code>.'));

		o = s.taboption('advanced', form.Value, 'hop_interval', _('Port hopping interval'),
			_('Enables UDP port hopping, for example <code>30s</code>.'));

		o = s.taboption('advanced', form.Flag, 'fast_open', _('Fast open'),
			_('Sends payload without waiting for the handshake to finish.'));
		o.default = o.disabled;

		o = s.taboption('advanced', form.Value, 'mtu', _('Override MTU'));
		o.placeholder = '1400';
		o.datatype = 'range(576,1500)';

		o = s.taboption('advanced', form.Value, 'config_file', _('Custom configuration file'),
			_('Use this YAML file verbatim instead of generating one. It must set <code>ppp.mode: nospawn</code>, otherwise the client spawns its own pppd and the interface will not come up.'));
		o.datatype = 'file';

		o = s.taboption('advanced', form.Value, 'camouflage_secret', _('Camouflage secret'),
			_('Base64 pre-shared key matching one of the server camouflage secrets. Cannot be combined with obfuscation.'));
		o.password = true;

		o = s.taboption('advanced', form.Value, 'camouflage_server_ip', _('Camouflage server IP'),
			_('Server address the camouflage token is bound to.'));
		o.datatype = 'ipaddr';
	}
});
