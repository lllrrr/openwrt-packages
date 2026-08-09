'use strict';
'require uci';
'require form';
'require network';
'require hysteria as hy';

/* ppp.sh names the device "${proto}-${interface}", which would be hysteria-wan.
 * The proto handler overrides that to hy-<interface>, so this pattern and
 * getIfname below have to agree with it: get it wrong and LuCI treats the device
 * as a missing physical one and will not show the interface as up. */
network.registerPatternVirtual(/^hy-.+$/);

/* Every reason this protocol can report, registered from the one place they are
 * written down.
 *
 * They reach a subscriber by two routes -- netifd's error channel for what the
 * handler refuses at setup, and the status object for what an individual link
 * fails with while running -- and the sentence must be the same either way. Two
 * copies would drift, and the drift would be invisible: each route looks correct
 * on its own.
 *
 * Settings this page does not render can still be set with "uci set", and the
 * proto handler refuses the combinations that cannot work rather than bringing a
 * link up that will never connect. Registering the codes is what turns those
 * refusals into a sentence on the interface status instead of a bare identifier.
 *
 * ReasonCode.String() in the Go client is the other half of the running-failure
 * half of this list. */
Object.keys(hy.REASONS).forEach(function(code) {
	network.registerErrorCode(code, hy.REASONS[code]);
});

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
	/* The Protocol row of the interface status box, and one of exactly two rows
	 * in that box a protocol gets to fill.
	 *
	 * render_status() in luci-mod-network builds the rest of it -- Carrier,
	 * Uptime, RX, TX, the addresses -- straight off the device, from a fixed
	 * list. There is no hook for adding a row of one's own, so the count of
	 * connected servers goes here and the servers that are missing go on the
	 * Error row below. Counting the norm and naming the exception: when every
	 * server is carrying nobody needs their names, and when one is not, its
	 * address is the only thing anybody wants.
	 *
	 * The suffix appears only where there is live data for a real interface.
	 * getI18n is also what fills the protocol dropdown, and those instances are
	 * created with a placeholder name and no runtime state -- so "Hysteria2 PPP
	 * — 2 of 3 servers" cannot end up as something an operator is offered to
	 * choose. */
	getI18n: function() {
		var base = _('Hysteria2 PPP'),
		    st = hy.statusOf(this),
		    t;

		if (!st)
			return base;

		/* Extra servers configured and switched off. Worth saying, because the
		 * interface otherwise looks exactly like one that was only ever given a
		 * single server, and "why is my second concentrator idle" has no answer
		 * anywhere else on the router. */
		if (st.servers_ignored > 0)
			return '%s — %s'.format(base,
				_('single link, %d server not in use').format(st.servers_ignored));

		/* One server is not a bundle, and "1 of 1 servers" is noise beside an
		 * Uptime row that already says the link is up. */
		if (st.links_configured > 1) {
			t = hy.tally(st);

			/* Where some link is up without its bundle membership having been
			 * settled, this row has to say so. The plain count is links_up, which
			 * includes those links -- so an interface the status page is warning
			 * about would otherwise read "3 of 3 servers" here, and of the two
			 * surfaces the reassuring one is the one an operator sees first.
			 *
			 * It stays a count rather than becoming a sentence: this is the
			 * Protocol row, sharing a narrow box with Uptime and RX, and the
			 * explanation belongs on the page the count is inviting them to. */
			if (st.bundle_state == 'formed' && t.unconfirmed > 0)
				return '%s — %s'.format(base,
					_('%d of %d servers confirmed').format(t.carrying, st.links_configured));

			return '%s — %s'.format(base,
				_('%d of %d servers').format(t.up, st.links_configured));
		}

		return base;
	},

	/* The Error row, which is where a server that is not connected gets named.
	 *
	 * netifd's own errors come first and are untouched: AUTH_FAILED and the rest
	 * still arrive and still read exactly as they did. What is added is the half
	 * netifd cannot see, because a member link has no error channel of its own --
	 * netifd has one per interface and the holder owns it.
	 *
	 * A degraded bundle is a genuine fault that is otherwise invisible: the
	 * interface is up, the traffic counters move, and the only symptom is a
	 * fraction of the throughput that was configured. It clears itself the moment
	 * the link comes back. */
	getErrors: function() {
		var rv = this.super('getErrors', []) || [],
		    st = hy.statusOf(this);

		if (st)
			rv = rv.concat(hy.problems(st));

		return rv.length ? rv : null;
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

		/* One interface, several access concentrators, bundled by Multilink PPP at
		 * the LNS. Each entry is one more PPP link carrying the same account.
		 *
		 * There is no ordering significance. The server above is simply the one
		 * configured first: the handler pools every address and each link claims
		 * whichever is free, so losing any one of them costs that link's share and
		 * nothing more. */
		o = s.taboption('general', form.DynamicList, 'extra_server', _('Additional servers (Multilink PPP)'),
			_('Further Hysteria 2 servers, one PPP link each, bundled with the server above into a single connection. All links carry the same account and must reach the same LNS, and the LNS has to support Multilink PPP over L2TP. Leave empty for an ordinary single-server link.'));
		o.placeholder = 'example2.com:443';

		/* Shared by every link, and that is not merely a simplification. The
		 * concentrator chooses an LNS by hashing this identity, which is what makes
		 * two independent concentrators pick the same one; two identities can hash
		 * apart, and links that land on different LNS cannot be bundled by either. */
		o = s.taboption('general', form.Value, 'auth', _('Hysteria authentication'),
			_('Password or token expected by the Hysteria 2 server. This is not your broadband account. With additional servers it must be the same on all of them: the server picks an LNS from this identity, and links that reach different LNS cannot be bundled.'));
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

		/* Pinning is what lets a self-signed certificate be trusted, and with
		 * camouflage below it is what removes the need for an ACME certificate on
		 * the concentrator at all. Prefer it over "Skip certificate verification":
		 * camouflage proves the CLIENT to the server, never the server to the
		 * client, so without a pin there is nothing authenticating the far end. */
		o = s.taboption('general', form.Value, 'pin_sha256', _('Certificate fingerprint'),
			_('SHA-256 fingerprint of the server certificate, as <code>xx:xx:...</code>. Lets a self-signed certificate be trusted without a public CA, which is what makes ACME unnecessary on the concentrator. Leave empty to use normal CA verification.'));

		/* --- advanced: camouflage --- */

		/* Camouflage is a filter in front of QUIC, not a TLS setting. The client
		 * carries an HMAC of a shared secret inside the QUIC connection ID, and a
		 * packet that does not carry a valid one is relayed to a real server
		 * instead -- so a prober never reaches the TLS handshake and never sees a
		 * certificate to attribute. That, not the certificate itself, is why a
		 * self-signed one becomes viable.
		 *
		 * Every link of a bundle uses the same secret, like every other Hysteria
		 * setting here: the links differ only in which concentrator they cross. */
		o = s.taboption('advanced', form.Flag, 'camouflage_enabled', _('Enable camouflage'),
			_('Identify this client to the concentrator before the QUIC handshake begins, so that traffic which cannot do so is relayed to a decoy server and the concentrator never answers a probe. Both settings below are optional overrides: on their own defaults this needs nothing but the credential and server address already configured, and it works unchanged across a multilink bundle.'));
		o.default = o.disabled;

		o = s.taboption('advanced', form.Value, 'camouflage_secret', _('Camouflage secret'),
			_('Shared secret that identifies real clients before the QUIC handshake begins. Traffic without it is relayed to a decoy server, so the concentrator does not answer probes at all. <strong>Normally leave this empty</strong>: the secret is then computed from the Hysteria2 credential above, exactly as the server computes it, and there is one credential to keep in step instead of two. Do not paste the credential here — this field is a separate base64 key, and filling it in overrides the computation. Only do that if the server carries the same key under its own <code>camouflage.secrets</code>.'));
		o.password = true;
		o.depends({ camouflage_enabled: '1' });

		/* The credential belongs in "Hysteria authentication", and pasting it here
		 * instead is the natural misreading of "derived from the credential". It
		 * fails late and invisibly -- the server relays the link away exactly like
		 * a probe -- so catch the shape of the value at the point of entry. */
		o.validate = function (section_id, value) {
			if (value == null || value === '')
				return true;
			if (!/^[A-Za-z0-9+/]+={0,2}$/.test(value))
				return _('Not base64. To use your Hysteria2 credential, leave this field empty — it is derived automatically. Do not paste the credential here.');
			return true;
		};

		/* A token is minted against one concentrator's address, and a bundle
		 * crosses several. The client resolves the address from the server its own
		 * link dials, which is the only setting that differs between links -- so
		 * this override is single-server only, and the proto handler refuses it
		 * alongside additional servers rather than let all but one link fail. */
		o = s.taboption('advanced', form.Value, 'camouflage_server_ip', _('Camouflage server IP'),
			_('The concentrator\'s own public address, as an IP rather than a name. <strong>Normally leave this empty</strong>: it is taken from the server address this link dials, which is what lets one configuration cover a bundle whose links each cross a different concentrator. Fill it in only for a single-server link whose address resolves to something the concentrator does not know itself as — split-horizon DNS, or a load balancer in front. It cannot be used together with additional servers.'));
		o.datatype = 'ipaddr';
		o.depends({ camouflage_enabled: '1' });

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
			_('Leave empty for 1399, which is the largest packet a QUIC datagram can carry once path discovery and the QUIC, AEAD and PPP headers are accounted for. Raise it only if you know the path allows it. This is the ceiling for one link: with additional servers the interface itself reports 6 bytes less, which is what the multilink header costs.'));
		o.placeholder = '1399';
		o.datatype = 'range(576,1500)';

		/* --- advanced: multilink, only meaningful once a second server exists --- */

		o = s.taboption('advanced', form.ListValue, 'multilink', _('Multilink PPP'),
			_('Whether the additional servers above are bundled into one connection. <em>Automatic</em> bundles whenever more than one server is configured. <em>Disabled</em> keeps them in the configuration without using them, which is how one concentrator is tested at a time.'));
		o.value('auto', _('Automatic'));
		o.value('1', _('Always'));
		o.value('0', _('Disabled'));
		o.default = 'auto';

		/* Both of these have defaults derived from the interface name and the PPP
		 * account, which is what an operator wants unless the LNS has an opinion.
		 * They are here because when the LNS does have one, there is no other way
		 * to satisfy it, and the failure it produces -- two single-link bundles
		 * instead of one bundle of two -- looks exactly like success. */
		o = s.taboption('advanced', form.Value, 'endpoint', _('Endpoint discriminator'),
			_('Identifies this router to the LNS, which uses it together with the PPP username to decide which links belong to one bundle. Every link sends the same value. Leave empty to derive one from the interface and account; set it as <code>local:</code> followed by hex digits if the operator requires a particular value.'));
		o.placeholder = 'local:0011223344556677';
		o.depends('multilink', 'auto');
		o.depends('multilink', '1');

		o = s.taboption('advanced', form.Value, 'bundle', _('Local bundle name'),
			_('Keeps this interface\'s links separate from any other multilink connection on the same router. It is never sent to the LNS. Leave empty to derive one from the interface name.'));
		o.placeholder = 'hysteria-wan';
		o.depends('multilink', 'auto');
		o.depends('multilink', '1');

		o = s.taboption('advanced', form.Value, 'config_file', _('Custom configuration file'),
			_('Use this YAML file verbatim instead of generating one, for anything this page does not cover. It must set <code>ppp.mode: nospawn</code>, otherwise the client spawns its own pppd and the interface will not come up. When set, every setting above except the PPP account is ignored, and it cannot be combined with additional servers: the file names one server, and the other links have nowhere to take their address from.'));
		o.datatype = 'file';
	}
});
