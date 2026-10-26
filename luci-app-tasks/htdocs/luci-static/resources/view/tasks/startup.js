'use strict';
'require view';
'require form';
'require fs';
'require uci';
'require ui';

var INITD = '/etc/init.d/tasks';

/* Load the shared stylesheet once. It only uses theme CSS variables, so it
 * follows the light / dark variant of Bootstrap and Argon by itself. */
function addStylesheet()
{
	if (document.querySelector('link[data-tasks-style]'))
		return;

	document.head.appendChild(E('link', {
		'rel': 'stylesheet',
		'type': 'text/css',
		'href': L.resource('view/tasks.css'),
		'data-tasks-style': '1'
	}));
}

/* Used only if the service directory cannot be listed. */
var FALLBACK_SERVICES = [
	'network', 'firewall', 'dnsmasq', 'odhcpd', 'dropbear', 'uhttpd'
];

/* Turn fs.list() results into a sorted, human usable list of service names. */
function serviceNames(entries)
{
	var names = [];

	for (var i = 0; i < entries.length; i++) {
		var name = (typeof(entries[i]) === 'string') ? entries[i] : entries[i].name;

		if (!name || name.charAt(0) === '.' || name === 'rc.common' ||
				/[~]$/.test(name) || /\.(bak|dpkg-[a-z]+|orig|rej|rpmnew|rpmorig|rpmsave|swp)$/.test(name))
			continue;

		names.push(name);
	}

	return names.sort();
}

return view.extend({
	load: function() {
		return uci.load('tasks');
	},

	render: function() {
		addStylesheet();

		var m = new form.Map('tasks', '',
			_('Choose what should start automatically after every boot. Select an existing service or type a command; no script or cron syntax is needed.'));

		this.map = m;

		var s = m.section(form.TypedSection, 'startup', _('Startup entries'));
		s.anonymous = true;
		s.addremove = true;
		s.sectiontitle = function(section_id) {
			return uci.get('tasks', section_id, 'title') || _('Custom startup entry');
		};

		var o;

		o = s.option(form.Flag, 'enabled', _('Enable'));
		o.rmempty = false;
		o.default = '1';

		o = s.option(form.Value, 'title', _('Description'));
		o.optional = true;

		o = s.option(form.ListValue, 'kind', _('What to start'));
		o.value('service', _('A system service'));
		o.value('command', _('A custom command'));
		o.default = 'command';
		o.rmempty = false;

		var serviceOpt = s.option(form.ListValue, 'service', _('Service'));
		serviceOpt.value('', _('-- Please choose a service --'));
		serviceOpt.depends('kind', 'service');

		o = s.option(form.TextValue, 'command', _('Command'));
		o.rows = 3;
		o.placeholder = 'sleep 30; /etc/init.d/myservice start';
		o.rmempty = false;
		o.depends('kind', 'command');

		o = s.option(form.Value, 'delay', _('Wait before starting (seconds)'));
		o.datatype = 'range(0,600)';
		o.default = '10';
		o.rmempty = false;

		return L.resolveDefault(fs.list('/etc/init.d'), []).then(function(entries) {
			var names = serviceNames(entries);
			var known = {};

			if (!names.length)
				names = FALLBACK_SERVICES.slice();

			for (var i = 0; i < names.length; i++) {
				known[names[i]] = true;
				serviceOpt.value(names[i], names[i]);
			}

			/* Keep an already configured service selectable even if its
			 * init script has been removed in the meantime. */
			var sections = uci.sections('tasks', 'startup');

			for (i = 0; i < sections.length; i++) {
				var v = sections[i].service;

				if (v && !known[v]) {
					known[v] = true;
					serviceOpt.value(v, v);
				}
			}

			return m.render();
		}).then(function(formNode) {
			return E('div', {}, [
				E('div', { 'class': 'cbi-section' }, [
					E('p', {}, _('Entries run as root a few seconds after boot. A service entry calls “/etc/init.d/<service> start”; it does not change whether that service starts on boot on its own.'))
				]),
				formNode
			]);
		});
	},

	handleSaveApply: function(ev, mode) {
		function applyNow() {
			document.removeEventListener('uci-applied', applyNow);

			function failed() {
				ui.addNotification(null, E('p', {},
					_('Configuration was saved, but the startup script could not be rebuilt. Reboot the device to retry.')), 'danger');
			}

			return fs.exec(INITD, [ 'reload' ]).then(function(res) {
				if (res && res.code === 0)
					ui.addNotification(null, E('p', {},
						_('Startup entries applied. They will run on the next boot.')), 'success');
				else
					failed();
			}).catch(failed);
		}

		document.addEventListener('uci-applied', applyNow);

		return this.map.save().then(function() {
			ui.changes.apply(mode == '0');
		}, function(err) {
			/* Validation failed, no commit will happen: drop the listener so
			 * it cannot fire for an unrelated apply later on. */
			document.removeEventListener('uci-applied', applyNow);
			throw err;
		});
	}
});
