'use strict';
'require view';
'require form';
'require uci';

// Shunt-rule editor — reached from Rule Manage's table (extedit). Mirrors
// passwall2's client/shunt_rules.lua: a NamedSection editor for one rule with
// domain_list / ip_list / outbound / network. If opened without a valid ?rule=
// section, redirect to the list.

return view.extend({
	load: function () {
		return uci.load('bypass');
	},

	render: function () {
		var sid = (window.location.search || '').match(/(?:^|&|;)rule=([^&;]*)/);
		sid = sid ? decodeURIComponent(sid[1]) : null;

		if (!sid || !uci.get('bypass', sid)) {
			// No valid section — bounce back to the list.
			window.location.assign(L.url('admin/services/bypass/rule_manage'));
			return E('div', { class: 'cbi-map' }, [
				E('p', {}, _('Redirecting to Rule Manage…'))
			]);
		}

		var m = new form.Map('bypass', _('Edit Shunt Rule: %s').format(sid));

		var s = m.section(form.NamedSection, sid, 'shunt_rules', '');
		s.addremove = false;

		var o;

		o = s.option(form.Value, 'remarks', _('Remarks'));
		o.rmempty = false;

		o = s.option(form.ListValue, 'outbound', _('Outbound'));
		o.value('_direct', _('Direct'));
		o.value('_proxy', _('Proxy (naive)'));
		o.value('_block', _('Block'));

		o = s.option(form.ListValue, 'network', _('Network'));
		o.value('tcp', 'TCP');
		o.value('udp', 'UDP');
		o.value('tcp,udp', 'TCP + UDP');
		o.default = 'tcp,udp';

		o = s.option(form.TextValue, 'domain_list', _('Domain list'));
		o.rows = 8;
		o.wrap = 'off';
		o.placeholder = 'geosite:cn\ngeosite:category-ads-all\ndomain:example.com';
		o.description = _('One rule per line. v2ray prefixes: geosite:, domain:, full:, regexp:, ext:, or a bare domain.');

		o = s.option(form.TextValue, 'ip_list', _('IP / CIDR list'));
		o.rows = 8;
		o.wrap = 'off';
		o.placeholder = 'geoip:cn\ngeoip:private\n10.0.0.0/8';
		o.description = _('One rule per line. geoip:, ext:, or a bare CIDR / IP.');

		return m.render();
	}
});
