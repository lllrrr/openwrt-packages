'use strict';
'require view';
'require form';
'require rpc';
'require ui';
'require uci';

const callReset = rpc.declare({
	object: 'cfpick',
	method: 'api_web_reset',
	expect: {}
});

function consoleUrl() {
	const port = uci.get('cfpick', 'global', 'web_port') || '17544';
	const host = window.location.hostname.indexOf(':') >= 0
		? '[' + window.location.hostname + ']' : window.location.hostname;

	return 'http://' + host + ':' + port + '/';
}

return view.extend({
	load: function() {
		return uci.load('cfpick');
	},

	render: function() {
		let m, s, o;

		m = new form.Map('cfpick', _('Settings'),
			_('This page only configures the standalone web console entry. All speed-test settings and operations are in the console.'));

		s = m.section(form.NamedSection, 'global', 'global');
		s.addremove = false;

		o = s.option(form.Flag, 'web_enabled', _('Enable standalone console'),
			_('Starts the separate console on its own port with its own admin login.'));
		o.default = o.disabled;
		o.rmempty = false;

		o = s.option(form.Value, 'web_port', _('Console port'),
			_('Default 17544 avoids the LuCI web port and Lucky\'s usual 17543.'));
		o.datatype = 'port';
		o.default = '17544';
		o.rmempty = false;

		o = s.option(form.Value, 'web_bind', _('Listen address'),
			_('0.0.0.0 listens on all interfaces (LAN access; WAN is still blocked by the firewall).'));
		o.default = '0.0.0.0';
		o.rmempty = false;

		o = s.option(form.Value, 'web_user', _('Console username'),
			_('The password is created on the console\'s first-run page and changed from the console settings.'));
		o.default = 'admin';
		o.rmempty = false;

		o = s.option(form.Value, 'web_timeout', _('Session timeout (seconds)'),
			_('How long a console login stays valid. Default 3600 seconds.'));
		o.datatype = 'uinteger';
		o.default = '3600';

		o = s.option(form.Button, '_open', _('Open web console'),
			_('Opens the standalone console in a new tab.'));
		o.onclick = function() {
			const input = document.querySelector('[name="cbid.cfpick.global.web_port"]');
			const port = (input && input.value) || '17544';
			const host = window.location.hostname.indexOf(':') >= 0
				? '[' + window.location.hostname + ']' : window.location.hostname;

			window.open('http://' + host + ':' + port + '/', '_blank');
		};

		o = s.option(form.Button, '_reset', _('Reset console password'),
			_('Forgets the console admin password and invalidates existing console sessions. The next console visit asks you to create a new password.'));
		o.onclick = function() {
			if (!confirm(_('Reset the console password? The next console visit will ask for a new one.')))
				return;

			return callReset().then(function(result) {
				if (!result || result.ok !== true)
					throw new Error((result && result.error) || _('Request failed'));

				ui.addNotification(null, E('p', {},
					_('Console password reset. Open the console to create a new one.')));
			}).catch(function(e) {
				ui.addNotification(null, E('p', {}, e.message || _('Request failed')));
			});
		};

		return m.render();
	}
});
