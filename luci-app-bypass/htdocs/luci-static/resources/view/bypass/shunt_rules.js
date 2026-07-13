'use strict';
'require view';
'require form';
'require uci';

return view.extend({
	load: function () {
		return uci.load('bypass');
	},

	render: function () {
		var m = new form.Map('bypass', _('Shunt Rules'),
			_('Routing rules consumed by BypassCore (the split/routing engine) and shared with the nftables/ipset plane. domain_list and ip_list use v2ray rule prefixes: geosite:, geoip:, domain:, full:, regexp:, ext:, or bare CIDR/domain.'));

		var s = m.section(form.TypedSection, 'shunt_rules', _('Rules'));
		s.addremove = true;
		s.anonymous = false;        // use the section name (e.g. "China") as the heading
		s.template = 'cbi/tblsection'; // tabular header + inline editor per rule

		var o;

		o = s.option(form.Value, 'remarks', _('Remarks'));

		o = s.option(form.ListValue, 'outbound', _('Outbound'));
		o.value('_direct', _('Direct'));
		o.value('_proxy', _('Proxy (naive)'));
		o.value('_block', _('Block'));

		o = s.option(form.Value, 'network', _('Network'));
		o.value('tcp', 'TCP');
		o.value('udp', 'UDP');
		o.value('tcp,udp', 'TCP + UDP');
		o.default = 'tcp,udp';

		o = s.option(form.TextValue, 'domain_list', _('Domain list'));
		o.rows = 4;
		o.placeholder = 'geosite:cn\ngeosite:category-ads-all\ndomain:example.com';
		o.description = _('One rule per line.');

		o = s.option(form.TextValue, 'ip_list', _('IP / CIDR list'));
		o.rows = 4;
		o.placeholder = 'geoip:cn\ngeoip:private\n10.0.0.0/8';

		return m.render();
	}
});
