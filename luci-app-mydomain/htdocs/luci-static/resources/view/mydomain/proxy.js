'use strict';
'require view';
'require ui';
'require form';
'require tools.widgets as widgets';
'require fs';

return view.extend({
	load: function() {
		return Promise.all([
			fs.glob('/etc/ssl/certs/*.crt').then(function(files) {
				return files || [];
			}).catch(function() {
				return [];
			})
		]);
	},

	render: function(certFiles) {
		var m, s, o;

		m = new form.Map('mydomain', _('Reverse Proxy Configuration'), 
			_('Configure Reverse Proxy with HAProxy'));

		s = m.section(form.TypedSection, 'proxy', _('Proxy Entries'));
		s.addremove = true;
		s.anonymous = false;

		o = s.option(form.Flag, 'enabled', _('Enable'));
		o.default = '0';

		o = s.option(form.Value, 'name', _('Name'));
		o.rmempty = false;

		o = s.option(form.Value, 'frontend_port', _('Frontend Port'));
		o.datatype = 'port';
		o.rmempty = false;

		o = s.option(form.Value, 'backend_url', _('Backend URL'));
		o.datatype = 'hostport';
		o.rmempty = false;

		o = s.option(form.ListValue, 'protocol', _('Protocol'));
		o.value('http', 'HTTP');
		o.value('https', 'HTTPS');
		o.value('tcp', 'TCP');
		o.value('websocket', 'WebSocket');
		o.default = 'http';

		o = s.option(form.ListValue, 'cert', _('SSL Certificate'));
		o.depends('protocol', 'https');
		o.value('', _('None'));
		if (certFiles && certFiles.length > 0) {
			certFiles.forEach(function(file) {
				var name = file.replace(/\/etc\/ssl\/certs\/(.*?)\.crt/, '$1');
				o.value(name, name);
			});
		}

		o = s.option(form.DynamicList, 'acl_rules', _('ACL Rules'));
		o.depends('protocol', 'http');
		o.depends('protocol', 'https');

		o = s.option(form.ListValue, 'lb_algorithm', _('Load Balancing Algorithm'));
		o.value('roundrobin', 'Round Robin');
		o.value('static-rr', 'Static Round Robin');
		o.value('leastconn', 'Least Connections');
		o.value('source', 'Source');
		o.default = 'roundrobin';

		o = s.option(form.Flag, 'health_check', _('Enable Health Check'));
		o.default = '1';

		o = s.option(form.Value, 'health_check_url', _('Health Check URL'));
		o.depends('health_check', '1');
		o.placeholder = '/health';

		return m.render();
	}
});
