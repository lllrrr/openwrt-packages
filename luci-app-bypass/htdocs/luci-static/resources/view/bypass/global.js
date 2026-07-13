'use strict';
'require view';
'require form';
'require uci';
'require fs';

return view.extend({
	load: function() {
		return Promise.all([
			uci.load('bypass'),
			fs.exec('/usr/share/bypass/api.sh', ['interfaces']).then(function (res) {
				try { return JSON.parse(res.stdout || '{}').interfaces || []; }
				catch (e) { return []; }
			}).catch(function () { return []; })
		]);
	},

	render: function (data) {
		var ifaces = data[1] || [];

		var m = new form.Map('bypass', _('Bypass'),
			_('naiveproxy + ChinaDNS-ng + BypassCore split proxy.'));

		var s = m.section(form.NamedSection, 'global', 'global', _('Basic Settings'));
		s.addremove = false;

		var o;

		o = s.option(form.Flag, 'enabled', _('Enable'));
		o.rmempty = false;

		o = s.option(form.ListValue, 'node', _('Node'));
		o.description = _('The NaiveProxy node used as the global transparent proxy.');
		uci.sections('bypass', 'nodes').forEach(function (sec) {
			o.value(sec['.name'], sec.remarks ? sec.remarks + ' (' + sec['.name'] + ')' : sec['.name']);
		});

		o = s.option(form.Value, 'node_socks_port', _('SOCKS Port'));
		o.datatype = 'port';
		o.placeholder = '1070';

		o = s.option(form.Flag, 'localhost_proxy', _('Proxy localhost'));
		o = s.option(form.Flag, 'client_proxy', _('Proxy router clients'));

		o = s.option(form.ListValue, 'loglevel', _('Log Level'));
		o.value('debug', _('Debug'));
		o.value('info', _('Info'));
		o.value('warning', _('Warning'));
		o.value('error', _('Error'));

		o = s.option(form.Flag, 'dns_redirect', _('Redirect dnsmasq to ChinaDNS-NG'));
		o.rmempty = false;

		o = s.option(form.Flag, 'bypass_as_core', _('BypassCore as transparent core'));
		o.description = _('0 (default): naiveproxy carries traffic, BypassCore is diagnostic-only. 1: BypassCore runs -run as the transparent proxy core (inbound + sniff + route + SOCKS5-to-naiveproxy); naiveproxy becomes its SOCKS upstream. Requires BypassCore with the SOCKS5 dialer + UDP TPROXY listener (commit e60bd1f+).');
		o.rmempty = false;

		/* Binaries / paths */
		o = s.option(form.Value, 'bypasscore_file', _('BypassCore binary'));
		o.description = _('Install the Linux ELF from https://github.com/kinmeic/BypassCore/releases (the routing/split engine). Route-test / resolve / observatory auto-disable if missing or not a Linux ELF.');
		o.placeholder = '/usr/bin/bypasscore';

		o = s.option(form.Value, 'naive_file', _('naive binary'));
		o.placeholder = '/usr/bin/naive';

		o = s.option(form.Value, 'chinadns_file', _('chinadns-ng binary'));
		o.placeholder = '/usr/bin/chinadns-ng';

		/* Egress (default interface for the naive -> server connection) */
		o = s.option(form.ListValue, 'default_egress_interface', _('Default Egress Interface'));
		o.description = _('Steer the naive -> server tunnel connection out of this interface (dest-IP fwmark policy routing). Leave empty to use the system default route. Per-node egress_interface overrides this.');
		o.value('', _('(system default route)'));
		ifaces.forEach(function (i) { o.value(i, i); });

		o = s.option(form.Value, 'naive_egress_fwmark', _('Egress fwmark'));
		o.description = _('Firewall mark used to steer naive traffic. Advanced.');
		o.placeholder = '0x2';

		o = s.option(form.Value, 'naive_egress_table', _('Egress route table'));
		o.description = _('Routing table id used for the egress policy rule. Advanced.');
		o.datatype = 'uinteger';
		o.placeholder = '200';

		return m.render();
	}
});
