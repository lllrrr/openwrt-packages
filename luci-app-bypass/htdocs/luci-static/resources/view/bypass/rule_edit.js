'use strict';
'require view';
'require form';
'require uci';
'require fs';

// Shunt-rule editor — reached from Rule Manage's table (extedit). Mirrors
// passwall2's client/shunt_rules.lua: a NamedSection editor for one rule with
// domain_list / ip_list / outbound / network. If opened without a valid ?rule=
// section, redirect to the list.

return view.extend({
	load: function () {
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
		var sid = new URLSearchParams(window.location.search).get('rule');

		if (!sid || uci.get('bypass', sid, '.type') !== 'shunt_rules') {
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

		o = s.option(form.ListValue, 'egress_interface', _('Egress Interface'));
		o.value('', _('(use default direct interface)'));
		ifaces.forEach(function (iface) { o.value(iface, iface); });
		o.depends('outbound', '_direct');
		o.description = _('Bind traffic matching this Direct rule to the selected OpenWrt network. This overrides the default direct interface.');

		o = s.option(form.DummyValue, '_proxy_egress', _('Proxy Egress Interface'));
		o.depends('outbound', '_proxy');
		o.cfgvalue = function () {
			return _('Proxy rules share the selected NaiveProxy node tunnel. Configure its physical WAN in Node Config; per-rule proxy WAN selection is not possible with one shared multiplexed Naive tunnel.');
		};

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
