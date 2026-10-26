'use strict';
'require view';
'require form';

return view.extend({
	render: function() {
		let m, s, o;

		m = new form.Map('shellinabox');

		s = m.section(form.NamedSection, 'main', 'shellinabox', _('ShellInABox Instance'));
		s.addremove = false;

		o = s.option(form.Flag, 'enable', _('Enable'));
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.Value, 'port_min', _('Minimum port'),
			_('CGI port range (default: 4200-4210). Each terminal session listens on a separate port; the browser must be able to reach this range.'));
		o.datatype = 'range(1024,65535)';
		o.placeholder = '4200';
		o.rmempty = false;

		o = s.option(form.Value, 'port_max', _('Maximum port'));
		o.datatype = 'range(1024,65535)';
		o.placeholder = '4210';
		o.rmempty = false;
		o.validate = function(section_id, value) {
			let min = this.map.lookupOption('port_min', section_id)[0].formvalue(section_id);
			return +value >= +min ? true : _('Maximum port must not be smaller than minimum port.');
		};

		o = s.option(form.Value, 'uid', _('User ID'), _('User id to run the command with (default: 0)'));
		o.datatype = 'uinteger';
		o.placeholder = '0';

		o = s.option(form.Value, 'gid', _('Group ID'), _('Group id to run the command with (default: 0)'));
		o.datatype = 'uinteger';
		o.placeholder = '0';

		o = s.option(form.Value, 'cwd', _('Working directory'));
		o.placeholder = '/root';
		o.validate = function(section_id, value) {
			return /^\/[^:\r\n]*$/.test(value) ? true : _('Use an absolute directory path without colons or line breaks.');
		};
		o.rmempty = false;

		o = s.option(form.Value, 'css', _('CSS style'),
			_('Select a bundled style or enter an absolute path to a CSS file on the router. Changes apply to new terminal sessions.'));
		o.value('/etc/shellinabox/white-on-black.css', _('White on black'));
		o.value('/etc/shellinabox/black-on-white.css', _('Black on white'));
		o.value('default', _('ShellInABox default'));
		o.default = '/etc/shellinabox/white-on-black.css';
		o.rmempty = false;
		o.validate = function(section_id, value) {
			return value === 'default' || /^\/[^\r\n]+\.css$/.test(value)
				? true : _('Use an absolute CSS file path ending in .css, or select ShellInABox default.');
		};

		s.option(form.Flag, 'no_beep', _('Suppress all audio output'));

		o = s.option(form.Flag, 'ssl', _('SSL'));
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.Value, 'ssl_cert', _('SSL cert'),
			_('PEM file containing a certificate and an unencrypted traditional RSA private key. The default self-signed certificate is generated on the first HTTPS terminal launch. Open the terminal port separately to trust a self-signed certificate if needed.'));
		o.depends('ssl', '1');
		o.placeholder = '/etc/shellinabox/certificate.pem';

		o = s.option(form.Value, 'command', _('Command'));
		o.placeholder = '/bin/login';
		o.rmempty = false;

		return m.render();
	}
});
