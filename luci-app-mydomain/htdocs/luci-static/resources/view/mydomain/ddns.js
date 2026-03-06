'use strict';
'require view';
'require ui';
'require form';
'require tools.widgets as widgets';

return view.extend({
	render: function() {
		var m, s, o;

		m = new form.Map('mydomain', _('Dynamic DNS Configuration'), 
			_('Configure Dynamic DNS for your domains'));

		s = m.section(form.TypedSection, 'ddns', _('DDNS Entries'));
		s.addremove = true;
		s.anonymous = false;

		o = s.option(form.Flag, 'enabled', _('Enable'));
		o.default = '0';

		o = s.option(form.Value, 'domain', _('Domain'));
		o.datatype = 'hostname';
		o.rmempty = false;

		o = s.option(form.ListValue, 'provider', _('DNS Provider'));
		o.value('dnspod', 'DNSPod');
		o.value('aliyun', 'Aliyun');
		o.value('cloudflare', 'Cloudflare');
		o.value('custom', 'Custom API');
		o.rmempty = false;

		o = s.option(form.Value, 'api_key', _('API Key'));
		o.password = true;
		o.depends('provider', 'dnspod');
		o.depends('provider', 'aliyun');
		o.depends('provider', 'cloudflare');
		o.depends('provider', 'custom');

		o = s.option(form.Value, 'secret', _('Secret'));
		o.password = true;
		o.depends('provider', 'dnspod');
		o.depends('provider', 'aliyun');
		o.depends('provider', 'cloudflare');
		o.depends('provider', 'custom');

		o = s.option(form.Flag, 'ipv4', _('Enable IPv4'));
		o.default = '1';

		o = s.option(form.Flag, 'ipv6', _('Enable IPv6'));
		o.default = '0';

		o = s.option(form.Value, 'interval', _('Update Interval (minutes)'));
		o.datatype = 'uinteger';
		o.default = '30';

		o = s.option(form.ListValue, 'record_type', _('Record Type'));
		o.value('A', 'A (IPv4)');
		o.value('AAAA', 'AAAA (IPv6)');
		o.value('CNAME', 'CNAME');
		o.default = 'A';

		o = s.option(form.Value, 'subdomain', _('Subdomain'));
		o.placeholder = '@';

		o = s.option(form.Value, 'api_url', _('API URL'));
		o.depends('provider', 'custom');

		return m.render();
	}
});
