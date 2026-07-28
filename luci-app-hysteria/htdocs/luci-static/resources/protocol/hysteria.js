'use strict';
'require uci';
'require form';
'require network';

/* ppp.sh names the device "${proto}-${interface}", which would be hysteria-wan.
 * The proto handler overrides that to hy-<interface>, so this pattern and
 * getIfname below have to agree with it: get it wrong and LuCI treats the device
 * as a missing physical one and will not show the interface as up. */
network.registerPatternVirtual(/^hy-.+$/);

network.registerErrorCode('CONFIG_FILE_MISSING', _('Configuration file not found'));
network.registerErrorCode('CONFIG_WRITE_FAILED', _('Unable to write generated configuration'));
network.registerErrorCode('MISSING_SERVER', _('No server address specified'));
network.registerErrorCode('AUTH_FAILED', _('Server rejected the authentication password'));
network.registerErrorCode('NO_ROUTE', _('The server has no LNS group configured for this account'));

/* keepalive is one UCI option holding "<failures> <interval>", which ppp.sh turns
 * into pppd's lcp-echo-failure and lcp-echo-interval. It is presented as two
 * fields, the way every other PPP protocol in LuCI does it. */
function write_keepalive(section_id, value) {
	var f_opt = this.map.lookupOption('_keepalive_failure', section_id),
	    i_opt = this.map.lookupOption('_keepalive_interval', section_id),
	    f = parseInt(f_opt?.[0]?.formvalue(section_id), 10),
	    i = parseInt(i_opt?.[0]?.formvalue(section_id), 10);

	if (isNaN(i))
		i = 1;

	if (isNaN(f))
		f = (i == 1) ? null : 5;

	if (f !== null)
		uci.set('network', section_id, 'keepalive', '%d %d'.format(f, i));
	else
		uci.unset('network', section_id, 'keepalive');
}

return network.registerProtocol('hysteria', {
	getI18n: function() {
		return _('Hysteria2 PPP');
	},

	getIfname: function() {
		return this._ubus('l3_device') || 'hy-%s'.format(this.sid);
	},

	/* getPackageName is the current name; getOpkgPackage is kept for older LuCI,
	 * where it is what drives the "install package" prompt. */
	getPackageName: function() {
		return 'hysteria2-ppp';
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

	/* This form is deliberately the short list: what a subscriber needs to get a
	 * link up, and nothing else.
	 *
	 * The protocol handler understands considerably more than appears here --
	 * obfuscation, bandwidth hints, port hopping, camouflage, fast open and the
	 * rest are all declared in hysteria.sh and can be set with "uci set" on the
	 * interface section, or supplied wholesale through the custom configuration
	 * file below. Leaving them off the page keeps the common case legible; it
	 * does not remove them from the product. */
	renderFormOptions: function(s) {
		var dev = this.getL3Device() || this.getDevice(), o;

		/* --- the Hysteria 2 connection --- */

		o = s.taboption('general', form.Value, 'server', _('Server address'),
			_('Hysteria 2 server, as <code>host:port</code>. This is the access concentrator the PPP session is carried to.'));
		o.rmempty = false;
		o.placeholder = 'example.com:443';

		o = s.taboption('general', form.Value, 'auth', _('Hysteria authentication'),
			_('Password or token expected by the Hysteria 2 server. This is not your broadband account.'));
		o.password = true;

		/* --- the PPP account, which a different machine checks --- */

		/* These are verified by the LNS at the far end of the tunnel, not by the
		 * Hysteria server, and they are a different secret from the one above.
		 * Without them the link comes up and is then dropped by the LNS. */
		s.taboption('general', form.Value, 'username', _('PAP/CHAP username'),
			_('Broadband account name, as issued by the network operator.'));

		o = s.taboption('general', form.Value, 'password', _('PAP/CHAP password'));
		o.password = true;

		/* --- TLS, only the two settings a bring-up usually needs --- */

		o = s.taboption('general', form.Value, 'sni', _('TLS SNI'),
			_('Server name to present during the TLS handshake. Defaults to the server host.'));

		o = s.taboption('general', form.Flag, 'insecure', _('Skip certificate verification'),
			_('Disables TLS verification entirely. Useful while bringing a link up; prefer a proper certificate afterwards.'));
		o.default = o.disabled;

		/* --- advanced: the PPP link itself --- */

		if (L.hasSystemFeature('ipv6')) {
			o = s.taboption('advanced', form.ListValue, 'ppp_ipv6', _('Obtain IPv6 address'),
				_('Enable IPv6 negotiation on the PPP link. Required if the operator provisions IPv6.'));
			o.ucioption = 'ipv6';
			o.value('auto', _('Automatic'));
			o.value('0', _('Disabled'));
			o.value('1', _('Manual'));
			o.default = 'auto';
		}

		o = s.taboption('advanced', form.Value, '_keepalive_failure', _('LCP echo failure threshold'),
			_('Presume the link dead after this many unanswered LCP echoes, use 0 to ignore failures. This is the only thing that notices a link which is up but no longer passing traffic.'));
		o.placeholder = '3';
		o.datatype    = 'uinteger';
		o.write       = write_keepalive;
		o.remove      = write_keepalive;
		o.cfgvalue = function(section_id) {
			var v = uci.get('network', section_id, 'keepalive');
			if (typeof(v) == 'string' && v != '') {
				var m = v.match(/^(\d+)[ ,]\d+$/);
				return m ? m[1] : v;
			}
		};

		o = s.taboption('advanced', form.Value, '_keepalive_interval', _('LCP echo interval'),
			_('Send LCP echo requests at this interval in seconds, only effective together with the failure threshold.'));
		o.placeholder = '5';
		o.datatype    = 'and(uinteger,min(1))';
		o.write       = write_keepalive;
		o.remove      = write_keepalive;
		o.cfgvalue = function(section_id) {
			var v = uci.get('network', section_id, 'keepalive');
			if (typeof(v) == 'string' && v != '') {
				var m = v.match(/^\d+[ ,](\d+)$/);
				return m ? m[1] : v;
			}
		};

		o = s.taboption('advanced', form.Value, 'mtu', _('Override MTU'),
			_('Leave empty to let the client size the link from the path it measures.'));
		o.placeholder = dev ? (dev.getMTU() || '1400') : '1400';
		o.datatype = 'range(576,1500)';

		o = s.taboption('advanced', form.Value, 'config_file', _('Custom configuration file'),
			_('Use this YAML file verbatim instead of generating one, for anything this page does not cover. It must set <code>ppp.mode: nospawn</code>, otherwise the client spawns its own pppd and the interface will not come up. When set, every setting above except the PPP account is ignored.'));
		o.datatype = 'file';
	}
});
