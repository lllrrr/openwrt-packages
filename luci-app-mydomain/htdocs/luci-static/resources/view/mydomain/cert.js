'use strict';
'require view';
'require ui';
'require form';
'require fs';

return view.extend({
	render: function() {
		var m, s, o;

		m = new form.Map('mydomain', _('Certificate Management'), 
			_('Manage SSL/TLS certificates with ACME'));

		s = m.section(form.TypedSection, 'certificate', _('Certificates'));
		s.addremove = true;
		s.anonymous = false;

		o = s.option(form.Flag, 'enabled', _('Enable'));
		o.default = '0';

		o = s.option(form.Value, 'domain', _('Domain'));
		o.datatype = 'hostname';
		o.rmempty = false;

		o = s.option(form.Value, 'email', _('Email'));
		o.datatype = 'email';
		o.rmempty = false;

		o = s.option(form.ListValue, 'validation', _('Validation Method'));
		o.value('http', 'HTTP-01');
		o.value('dns', 'DNS-01');
		o.value('manual', 'Manual');
		o.default = 'http';

		o = s.option(form.ListValue, 'dns_api', _('DNS API'));
		o.value('dnspod', 'DNSPod');
		o.value('aliyun', 'Aliyun');
		o.value('cloudflare', 'Cloudflare');
		o.depends('validation', 'dns');

		o = s.option(form.Value, 'api_key', _('API Key'));
		o.password = true;
		o.depends('validation', 'dns');

		o = s.option(form.Value, 'secret', _('Secret'));
		o.password = true;
		o.depends('validation', 'dns');

		o = s.option(form.Value, 'cert_path', _('Certificate Path'));
		o.default = '/etc/ssl/certs/';
		o.rmempty = false;

		o = s.option(form.Value, 'key_path', _('Private Key Path'));
		o.default = '/etc/ssl/private/';
		o.rmempty = false;

		o = s.option(form.Value, 'renew_interval', _('Renewal Interval (days)'));
		o.datatype = 'uinteger';
		o.default = '60';

		o = s.option(form.Flag, 'wildcard', _('Wildcard Certificate'));
		o.depends('validation', 'dns');

		return m.render();
	}
});
