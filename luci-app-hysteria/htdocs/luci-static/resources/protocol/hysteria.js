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

/* Settings this page does not render can still be set with "uci set", and the
 * proto handler refuses the combinations that cannot work rather than bringing a
 * link up that will never connect. Registering the codes is what turns them into
 * a sentence on the interface status instead of a bare identifier. */
/* These arrive by a different route: the client writes the reason it ended into
 * a status file, the proto handler reads it back on teardown and reports it. They
 * are the ordinary running failures, so they are the ones most worth spelling
 * out -- ReasonCode.String() in the Go client is the other half of this list. */
network.registerErrorCode('LINK_DOWN', _('The connection to the Hysteria 2 server was lost'));
network.registerErrorCode('LNS_UNREACHABLE', _('The server could not establish an L2TP tunnel to the LNS'));
network.registerErrorCode('LNS_DISCONNECTED', _('The LNS disconnected the session'));
network.registerErrorCode('NO_LNS', _('No LNS in the configured group is available'));
network.registerErrorCode('PATH_NARROWED', _('The path stopped carrying full-size packets; the link will be rebuilt at a smaller MTU'));
network.registerErrorCode('UNKNOWN', _('The session ended without a stated reason'));

network.registerErrorCode('OBFS_TYPE_INVALID', _('Unknown obfuscation type: use salamander or gecko'));
network.registerErrorCode('OBFS_PASSWORD_MISSING', _('Obfuscation is enabled but no obfuscation password is set'));
network.registerErrorCode('OBFS_WITH_CAMOUFLAGE', _('Obfuscation cannot be combined with camouflage, which needs the QUIC header that obfuscation hides'));
network.registerErrorCode('CAMOUFLAGE_INCOMPLETE', _('Camouflage needs both a secret and a server IP'));

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

	/* The live device once netifd reports one, and before that the same name the
	 * proto handler will ask for -- including its truncation to 15 characters,
	 * which is all a Linux network device name holds. Computing the untruncated
	 * name here would stop matching the device the kernel actually created, and
	 * containsDevice below would then report a working interface as down. */
	getIfname: function() {
		return this._ubus('l3_device') || 'hy-%s'.format(this.sid.substring(0, 12));
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
		var o;

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

		/* luci-mod-network renders this control itself, but only for protocols on
		 * a hardcoded list in has_peerdns() -- ours is not on it, and neither is
		 * l2tp, so this is an upstream wart rather than something we did wrong.
		 * The option works regardless: netifd fills the interface blob from
		 * interface_attr_list before the protocol's own parameters, so peerdns
		 * reaches ppp.sh whatever the protocol is. Without a control here there is
		 * no way to stop the operator's DNS servers being used, and the "Use
		 * custom DNS servers" field is silently overridden. */
		o = s.taboption('advanced', form.Flag, 'peerdns', _('Use DNS servers advertised by peer'),
			_('If unchecked, the DNS servers advertised by the operator are ignored.'));
		o.default = o.enabled;

		o = s.taboption('advanced', form.Value, '_keepalive_failure', _('LCP echo failure threshold'),
			_('Presume the link dead after this many unanswered LCP echoes, use 0 to ignore failures. This is the only thing that notices a link which is up but no longer passing traffic.'));
		o.placeholder = '5';
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
		o.placeholder = '1';
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
			_('Leave empty for 1399, which is the largest packet a QUIC datagram can carry once path discovery and the QUIC, AEAD and PPP headers are accounted for. Raise it only if you know the path allows it.'));
		o.placeholder = '1399';
		o.datatype = 'range(576,1500)';

		o = s.taboption('advanced', form.Value, 'config_file', _('Custom configuration file'),
			_('Use this YAML file verbatim instead of generating one, for anything this page does not cover. It must set <code>ppp.mode: nospawn</code>, otherwise the client spawns its own pppd and the interface will not come up. When set, every setting above except the PPP account is ignored.'));
		o.datatype = 'file';
	}
});
