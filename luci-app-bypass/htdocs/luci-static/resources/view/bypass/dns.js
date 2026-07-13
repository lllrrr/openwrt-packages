'use strict';
'require view';
'require form';

return view.extend({
	render: function () {
		var m = new form.Map('bypass', _('DNS'), _('ChinaDNS-NG split DNS.'));

		var s = m.section(form.NamedSection, 'global_dns', 'global_dns', _('ChinaDNS-NG'));

		var o;

		o = s.option(form.Value, 'domestic_dns', _('Domestic DNS (china-dns)'));
		o.description = _('Resolves domestic domains. "auto" = detect ISP DNS from resolv.conf.');
		o.placeholder = 'auto';

		o = s.option(form.Value, 'remote_dns', _('Remote / Foreign DNS (trust-dns)'));
		o.description = _('Resolves foreign domains; their IPs are routed through the proxy.');
		o.placeholder = '1.1.1.1';

		o = s.option(form.ListValue, 'remote_dns_protocol', _('Remote DNS protocol'));
		o.value('udp', _('UDP'));
		o.value('tcp', _('TCP'));
		o.value('tls', _('TLS (DoT)'));
		o.value('https', _('HTTPS (DoH)'));

		o = s.option(form.ListValue, 'query_strategy', _('Query strategy'));
		o.value('UseIPv4', _('IPv4 only'));
		o.value('UseIPv6', _('IPv6 only'));
		o.value('UseIP', _('IPv4 + IPv6'));

		o = s.option(form.Value, 'chinadns_listen_port', _('ChinaDNS-NG listen port'));
		o.datatype = 'port';
		o.placeholder = '10553';

		/* BypassCore DNS subsystem (the split-DNS engine; ChinaDNS-NG stays as
		   the live resolver + ipset populator). These feed the 'dns' section of
		   the generated config.json, used by 'bypasscore -resolve'. */
		o = s.option(form.Value, 'bc_domestic_dns', _('BypassCore domestic DNS'));
		o.description = _('Upstream for domestic domains in the BypassCore DNS section (UDP/TCP/DoT/DoH). Leave empty to disable the split (only the remote upstream is emitted).');
		o.placeholder = 'https://223.5.5.5/dns-query';

		o = s.option(form.Value, 'bc_remote_dns', _('BypassCore remote DNS'));
		o.description = _('Upstream for everything else in the BypassCore DNS section.');
		o.placeholder = 'https://1.1.1.1/dns-query';

		o = s.option(form.Value, 'dns_split_domain', _('Domestic split domain'));
		o.description = _('v2ray rule prefix that selects which domains use the domestic upstream (default geosite:cn).');
		o.placeholder = 'geosite:cn';

		return m.render();
	}
});
