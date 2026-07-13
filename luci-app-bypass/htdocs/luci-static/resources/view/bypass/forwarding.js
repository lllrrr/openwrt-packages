'use strict';
'require view';
'require form';

return view.extend({
	render: function () {
		var m = new form.Map('bypass', _('Forwarding'), _('Transparent-proxy redirect settings.'));

		var s = m.section(form.NamedSection, 'global_forwarding', 'global_forwarding', _('Ports & Mode'));

		var o;

		o = s.option(form.Value, 'tcp_redir_ports', _('TCP redirect ports'));
		o.description = _('Port range or list. "1:65535" redirects all TCP. Use "disable" to disable.');
		o.placeholder = '1:65535';

		o = s.option(form.Value, 'udp_redir_ports', _('UDP redirect ports'));
		o.placeholder = '1:65535';

		o = s.option(form.Value, 'tcp_no_redir_ports', _('TCP no-redirect ports'));
		o.description = _('Ports to leave direct. "disable" = none.');
		o.placeholder = 'disable';

		o = s.option(form.Value, 'udp_no_redir_ports', _('UDP no-redirect ports'));
		o.placeholder = 'disable';

		o = s.option(form.ListValue, 'tcp_proxy_way', _('Transparent mode'));
		o.value('redirect', _('Redirect (recommended, TCP)'));
		o.value('tproxy', _('TPROXY (TCP + UDP, experimental)'));
		o.description = _('naive listen mode. "redirect" = TCP, supported by every naive build. "tproxy" = TCP+UDP and requires a naive build compiled with tproxy support plus kmod-nft-tproxy.');

		o = s.option(form.Flag, 'ipv6_tproxy', _('Enable IPv6 TProxy'));
		o.rmempty = false;

		return m.render();
	}
});
