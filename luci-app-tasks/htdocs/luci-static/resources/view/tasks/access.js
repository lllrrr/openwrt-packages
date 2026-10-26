'use strict';
'require view';
'require form';
'require fs';
'require uci';
'require ui';
'require network';

var INITD = '/etc/init.d/tasks';
var STATE = '/etc/tasks/access.state';

var WEEKDAYS = [
	_('Sunday'), _('Monday'), _('Tuesday'), _('Wednesday'),
	_('Thursday'), _('Friday'), _('Saturday')
];

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

/* Number choices 0..23 / 0..59, rendered as zero padded labels. */
function numberChoices(o, from, to, width)
{
	for (var i = from; i <= to; i++) {
		var s = String(i);

		while (s.length < width)
			s = '0' + s;

		o.value(String(i), s);
	}
}

function validIPv4(value)
{
	var parts = value.split('.');

	if (parts.length !== 4)
		return false;

	for (var i = 0; i < parts.length; i++) {
		if (!/^[0-9]{1,3}$/.test(parts[i]))
			return false;

		if (parseInt(parts[i], 10) > 255)
			return false;
	}

	return true;
}

function validTarget(value)
{
	var cidr = value.match(/^(.+)\/([0-9]{1,2})$/);

	if (/^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$/.test(value))
		return true;

	if (cidr)
		return validIPv4(cidr[1]) && parseInt(cidr[2], 10) <= 32;

	return validIPv4(value);
}

/* The known hosts become combobox suggestions; the user may still type any
 * MAC address, IPv4 address or IPv4 prefix. */
function addHostChoices(o, hosts)
{
	var seen = {};
	var choices = [];

	Object.keys(hosts || {}).forEach(function(mac) {
		var host = hosts[mac] || {};
		var name = host.name || '';
		var ips = L.toArray(host.ipaddrs || host.ipv4);

		if (!ips.length)
			ips = [ null ];

		ips.forEach(function(ip) {
			if (ip) {
				choices.push({
					value: ip,
					label: 'IP %s – %s (%s)'.format(ip, name || mac, mac)
				});
			}

			choices.push({
				value: mac,
				label: (ip
					? 'MAC %s – %s (%s)'.format(mac, name || ip, ip)
					: 'MAC %s – %s'.format(mac, name || _('unknown host')))
			});
		});
	});

	choices.sort(function(a, b) {
		return a.label.localeCompare(b.label);
	});

	choices.forEach(function(choice) {
		if (seen[choice.value])
			return;

		seen[choice.value] = true;
		o.value(choice.value, choice.label);
	});
}

function parseState(text)
{
	var info = {
		state: '',
		backend: '',
		checked: '',
		blocked: '0',
		devices: []
	};

	(text || '').split('\n').forEach(function(line) {
		var pos = line.indexOf('=');

		if (pos < 0)
			return;

		var key = line.substring(0, pos);
		var val = line.substring(pos + 1);

		if (key === 'device') {
			var fields = val.split('\t');

			info.devices.push({
				target: fields[0] || '',
				comment: fields[1] || fields[0] || ''
			});
		}
		else {
			info[key] = val;
		}
	});

	return info;
}

return view.extend({
	load: function() {
		return Promise.all([
			uci.load('tasks'),
			L.resolveDefault(network.getHostHints(), null)
		]);
	},

	render: function(data) {
		addStylesheet();

		var hosts = (data[1] && data[1].hosts) ? data[1].hosts : {};

		var m = new form.Map('tasks', '');

		/* form.Map always renders its description above every card. The hint
		 * belongs between the master switch and the device cards, so it is
		 * created here and placed into the rendered form instead. Saving
		 * redraws the map contents, which is why placeHint() also runs after
		 * every save. */
		var hint = E('div', { 'class': 'cbi-map-descr tasks-access-hint' },
			_('Block internet access for selected devices outside their allowed time window. A blocked device can still reach the router itself. The rule is checked every minute; no cron syntax or shell command is needed.'));

		function placeHint() {
			var node = m.root ? m.root.querySelector('#cbi-tasks-access') : null;
			var card = node ? node.closest('.cbi-section') : null;

			if (card && card.parentNode === m.root)
				m.root.insertBefore(hint, card.nextSibling);
		}

		this.map = m;
		this.placeHint = placeHint;

		/* --- Global switch --------------------------------------------- */
		var s = m.section(form.NamedSection, 'access', 'access',
			_('Access control'),
			_('When enabled, the devices below lose internet access outside their allowed window. Start and end are inclusive; if both are equal the whole day is allowed.'));

		var o = s.option(form.Flag, 'enabled', _('Enable access control'));
		o.rmempty = false;
		o.default = '0';

		/* --- Device rules ---------------------------------------------- */
		s = m.section(form.TypedSection, 'access_device', _('Devices'));
		s.anonymous = true;
		s.addremove = true;
		s.sectiontitle = function(section_id) {
			return uci.get('tasks', section_id, 'comment') ||
				uci.get('tasks', section_id, 'target') ||
				_('New device');
		};

		o = s.option(form.Flag, 'enabled', _('Enable'));
		o.rmempty = false;
		o.default = '1';

		o = s.option(form.Value, 'comment', _('Description'));
		o.optional = true;
		o.placeholder = _('For example: kids tablet');

		o = s.option(form.Value, 'target', _('MAC or IP address'),
			_('A MAC address is recommended: it also covers IPv6 and keeps working when DHCP assigns a new IP. An IPv4 address or subnet only blocks IPv4 traffic.'));
		o.rmempty = false;
		o.placeholder = 'AA:BB:CC:DD:EE:FF / 192.168.1.100';
		addHostChoices(o, hosts);
		o.validate = function(section_id, value) {
			value = (value || '').trim();

			if (value === '')
				return _('Enter a MAC address, an IPv4 address or an IPv4 subnet.');

			if (!validTarget(value))
				return _('Enter a MAC address, an IPv4 address or an IPv4 subnet (for example 192.168.1.0/24).');

			return true;
		};

		o = s.option(form.ListValue, 'mode', _('Mode'));
		o.value('period', _('Allowed during the time window'));
		o.value('block', _('Blocked all the time'));
		o.default = 'period';
		o.rmempty = false;

		o = s.option(form.ListValue, 'week', _('Days'));
		o.value('*', _('Every day'));
		o.value('1,2,3,4,5', _('Monday to Friday'));
		o.value('0,6', _('Saturday and Sunday'));
		for (var d = 0; d <= 6; d++)
			o.value(String(d), WEEKDAYS[d]);
		o.default = '*';
		o.rmempty = false;
		o.depends('mode', 'period');

		o = s.option(form.ListValue, 'start_hour', _('Start hour'));
		numberChoices(o, 0, 23, 2);
		o.default = '0';
		o.rmempty = false;
		o.depends('mode', 'period');

		o = s.option(form.ListValue, 'start_minute', _('Start minute'));
		numberChoices(o, 0, 59, 2);
		o.default = '0';
		o.rmempty = false;
		o.depends('mode', 'period');

		o = s.option(form.ListValue, 'end_hour', _('End hour'));
		numberChoices(o, 0, 23, 2);
		o.default = '23';
		o.rmempty = false;
		o.depends('mode', 'period');

		o = s.option(form.ListValue, 'end_minute', _('End minute'));
		numberChoices(o, 0, 59, 2);
		o.default = '59';
		o.rmempty = false;
		o.depends('mode', 'period');

		/* --- Enforcement status ---------------------------------------- */
		var statusBody = E('div', { 'class': 'tasks-access-status-body' });

		function paintStatus(info) {
			while (statusBody.firstChild)
				statusBody.removeChild(statusBody.firstChild);

			var label;

			switch (info.state) {
			case 'active':
				label = _('Access control is active.');
				break;
			case 'disabled':
				label = _('Access control is disabled.');
				break;
			case 'error':
				label = _('Access control could not be applied.');
				break;
			case 'inactive':
				label = _('The tasks service is not running.');
				break;
			default:
				label = _('Not applied yet. Save and apply the page to write the rules.');
				break;
			}

			statusBody.appendChild(E('p', { 'class': 'tasks-status' }, [
				E('span', {}, [ E('strong', {}, label) ]),
				E('span', {}, _('Firewall backend: %s').format(info.backend || _('none'))),
				E('span', {}, _('Blocked devices: %s').format(info.blocked || '0')),
				E('span', {}, _('Last check: %s').format(info.checked || _('never')))
			]));

			if (info.devices.length) {
				statusBody.appendChild(E('ul', { 'class': 'tasks-access-devices' },
					info.devices.map(function(device) {
						return E('li', {},
							device.comment === device.target
								? device.target
								: '%s (%s)'.format(device.comment, device.target));
					})));
			}
			else if (info.state === 'active') {
				statusBody.appendChild(E('p', { 'class': 'tasks-status' },
					_('No device is blocked right now.')));
			}
		}

		function refreshStatus() {
			return L.resolveDefault(fs.read(STATE), '').then(function(text) {
				paintStatus(parseState(text));
			});
		}

		var status = E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('Status')),
			statusBody
		]);

		var masterWarn = '';

		if (uci.get('tasks', 'global', 'enabled') !== '1') {
			masterWarn = E('div', { 'class': 'alert-message warning tasks-warning' },
				_('The master switch is off, so access control will not run.'));
		}

		refreshStatus();
		L.Poll.add(refreshStatus, 10);

		return m.render().then(function(formNode) {
			placeHint();

			return E('div', {}, [ status, masterWarn, formNode ]);
		});
	},

	/* Saving redraws the form contents, so the hint inserted between the
	 * cards has to be put back afterwards. Reset redraws them too. */
	handleSave: function(ev) {
		var self = this;

		return this.map.save().then(function() {
			self.placeHint();
		});
	},

	handleReset: function(ev) {
		var self = this;

		return this.map.reset().then(function() {
			self.placeHint();
		});
	},

	handleSaveApply: function(ev, mode) {
		var self = this;

		function applyNow() {
			document.removeEventListener('uci-applied', applyNow);

			function failed() {
				ui.addNotification(null, E('p', {},
					_('Configuration was saved, but the access rules could not be rebuilt. Reboot the device to retry.')), 'danger');
			}

			return fs.exec(INITD, [ 'reload' ]).then(function(res) {
				if (!res || res.code !== 0)
					return failed();

				/* The init script reports success even when the rules
				 * themselves could not be installed, so look at the state
				 * the handler just published. */
				return L.resolveDefault(fs.read(STATE), '').then(function(text) {
					if (parseState(text).state === 'error')
						failed();
					else
						ui.addNotification(null, E('p', {},
							_('Access control applied. The firewall rules are up to date.')), 'success');
				});
			}).catch(failed);
		}

		document.addEventListener('uci-applied', applyNow);

		return this.map.save().then(function() {
			self.placeHint();
			ui.changes.apply(mode == '0');
		}, function(err) {
			/* Validation failed, no commit will happen: drop the listener so
			 * it cannot fire for an unrelated apply later on. */
			document.removeEventListener('uci-applied', applyNow);
			throw err;
		});
	}
});
