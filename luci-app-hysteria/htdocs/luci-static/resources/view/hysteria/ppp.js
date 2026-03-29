'use strict';
'require view';
'require form';

return view.extend({
	render: function () {
		var m, s, o;

		m = new form.Map('hysteria', _('PPP Settings'),
			_('PPP over Hysteria2 tunnel configuration.'));

		s = m.section(form.NamedSection, 'ppp', 'ppp', _('PPP Client'));
		s.anonymous = true;

		o = s.option(form.Flag, 'enabled', _('Enable PPP'));
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.Value, 'mtu', _('MTU'),
			_('Maximum transmission unit. Leave empty for auto-detection (range: 576-1500). Auto-detection accounts for QUIC, UDP, and obfuscation overhead.'));
		o.placeholder = _('auto');
		o.datatype = 'range(576,1500)';
		o.optional = true;
		o.depends('enabled', '1');

		o = s.option(form.Value, 'pppd_path', _('pppd path'),
			_('Path to the pppd executable.'));
		o.default = '/usr/sbin/pppd';
		o.depends('enabled', '1');

		o = s.option(form.DynamicList, 'pppd_args', _('pppd arguments'),
			_('Custom arguments for pppd. Leave empty to use hysteria defaults (nodetach, local, +ipv6, multilink, lcp-echo-interval 0). Only set if you need to override.'));
		o.placeholder = 'defaultroute';
		o.depends('enabled', '1');

		o = s.option(form.Value, 'data_streams', _('Data streams'),
			_('Number of parallel QUIC streams. 0 uses datagram mode (recommended for most setups). Values greater than 0 enable multilink mode with that many streams.'));
		o.default = '0';
		o.datatype = 'uinteger';
		o.depends('enabled', '1');

		return m.render();
	}
});
