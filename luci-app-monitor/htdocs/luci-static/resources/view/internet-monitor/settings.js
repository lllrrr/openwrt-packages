'use strict';
'require view';
'require form';
'require uci';

function ensureStylesheet() {
	var id = 'internet-monitor-stylesheet';
	var head = document.head || document.querySelector('head');

	if (head && !document.getElementById(id))
		head.appendChild(E('link', {
			'id': id,
			'rel': 'stylesheet',
			'type': 'text/css',
			'href': L.resource('internet-monitor/internet-monitor.css')
		}));
}

function validateProbeAddress(sectionId, value) {
	var type = this.section.formvalue(sectionId, 'type') || 'icmp';
	var address = String(value || '');

	if (!address)
		return _('A probe address is required.');

	if (/\s/.test(address))
		return _('The probe address must not contain spaces.');

	if (type === 'http' && !/^https?:\/\/[^\s]+$/i.test(address))
		return _('HTTP probes require a URL beginning with http:// or https://.');

	if (type === 'icmp' && /^[a-z][a-z0-9+.-]*:\/\//i.test(address))
		return _('ICMP probes require a hostname or IP address, not a URL.');

	return true;
}

function validateExpectedCodes(sectionId, value) {
	var type = this.section.formvalue(sectionId, 'type') || 'icmp';
	var ranges;

	if (type !== 'http')
		return true;

	if (!value)
		return _('At least one expected HTTP status code or range is required.');

	ranges = String(value).split(',');

	for (var i = 0; i < ranges.length; i++) {
		var match = /^\s*(\d{3})(?:-(\d{3}))?\s*$/.exec(ranges[i]);
		var first;
		var last;

		if (!match)
			return _('Use comma-separated HTTP codes or ranges, for example 200-399,404.');

		first = Number(match[1]);
		last = match[2] ? Number(match[2]) : first;

		if (first < 100 || first > 599 || last < 100 || last > 599 || first > last)
			return _('HTTP status codes must be between 100 and 599 and ranges must be ascending.');
	}

	return true;
}

return view.extend({
	load: function() {
		return uci.load('internet-monitor');
	},

	render: function() {
		var m;
		var s;
		var o;

		ensureStylesheet();

		m = new form.Map('internet-monitor', _('Internet Connectivity Monitor'),
			_('Configure independent external probes and the policy used to decide whether Internet access is available. Save & Apply commits the configuration and restarts the monitor service.'));

		s = m.section(form.TypedSection, 'global', _('Global settings'));
		s.anonymous = true;
		s.addremove = false;
		s.description = _('These values apply to every enabled target unless a target overrides its timeout.');

		o = s.option(form.Flag, 'enabled', _('Enable monitoring'));
		o.default = '1';
		o.rmempty = false;
		o.description = _('Start the monitor at boot and continuously test external connectivity.');

		o = s.option(form.Value, 'interval', _('Probe interval'));
		o.datatype = 'range(10,3600)';
		o.default = '60';
		o.rmempty = false;
		o.description = _('Seconds between scheduled probe rounds (10–3600).');

		o = s.option(form.Value, 'timeout', _('Default timeout'));
		o.datatype = 'range(1,30)';
		o.default = '5';
		o.rmempty = false;
		o.description = _('Maximum seconds to wait for each probe unless overridden below.');

		o = s.option(form.Value, 'failure_threshold', _('Failure threshold'));
		o.datatype = 'range(1,20)';
		o.default = '3';
		o.rmempty = false;
		o.description = _('Consecutive failed rounds required before opening an incident.');

		o = s.option(form.Value, 'recovery_threshold', _('Recovery threshold'));
		o.datatype = 'range(1,20)';
		o.default = '2';
		o.rmempty = false;
		o.description = _('Consecutive successful rounds required before resolving an incident.');

		o = s.option(form.Value, 'quorum', _('Required quorum'));
		o.datatype = 'range(1,64)';
		o.default = '2';
		o.rmempty = false;
		o.description = _('Minimum number of targets that must succeed for a probe round to be available.');

		o = s.option(form.Value, 'history_days', _('History retention'));
		o.datatype = 'range(1,365)';
		o.default = '30';
		o.rmempty = false;
		o.description = _('Number of days of confirmed incident records used for long-range availability (1–365). Fine-grained target quality and latency samples are RAM-backed; after a reboot, the timeline falls back to persisted availability boundaries.');

		s = m.section(form.GridSection, 'target', _('Probe targets'));
		s.anonymous = true;
		s.addremove = true;
		s.sortable = true;
		s.nodescriptions = true;
		s.addbtntitle = _('Add probe target');
		s.description = _('Use multiple providers and protocols so a single remote outage or blocked protocol does not create a false Internet outage.');

		o = s.option(form.Flag, 'enabled', _('Enabled'));
		o.default = '1';
		o.rmempty = false;
		o.width = '8%';

		o = s.option(form.Value, 'name', _('Name'));
		o.rmempty = false;
		o.placeholder = _('Example: Cloudflare DNS');
		o.width = '20%';

		o = s.option(form.ListValue, 'type', _('Type'));
		o.value('icmp', _('ICMP ping'));
		o.value('http', _('HTTP request'));
		o.default = 'icmp';
		o.rmempty = false;
		o.width = '12%';

		o = s.option(form.Value, 'address', _('Address'));
		o.rmempty = false;
		o.placeholder = _('1.1.1.1 or https://example.com/');
		o.validate = validateProbeAddress;
		o.width = '38%';

		o = s.option(form.ListValue, 'family', _('Address family'));
		o.value('auto', _('Automatic'));
		o.value('ipv4', _('IPv4 only'));
		o.value('ipv6', _('IPv6 only'));
		o.default = 'auto';
		o.rmempty = false;
		o.modalonly = true;
		o.description = _('Force a specific IP family or let the monitor choose automatically.');

		o = s.option(form.Value, 'timeout', _('Timeout override'));
		o.datatype = 'range(1,30)';
		o.rmempty = true;
		o.modalonly = true;
		o.placeholder = _('Use global timeout');
		o.description = _('Optional per-target timeout in seconds. Leave empty to inherit the global value.');

		o = s.option(form.Value, 'expected_codes', _('Expected HTTP codes'));
		o.default = '200-399';
		o.rmempty = false;
		o.modalonly = true;
		o.depends('type', 'http');
		o.validate = validateExpectedCodes;
		o.description = _('Comma-separated status codes or inclusive ranges accepted as success, for example 200-399,404.');

		return m.render().then(function(node) {
			return E('div', { 'class': 'internet-monitor internet-monitor-settings' }, [
				E('div', { 'class': 'im-settings-note' }, [
					E('strong', {}, [ _('Quorum guidance') ]),
					E('p', {}, [
						_('Set quorum no higher than the number of enabled targets. Two successes across three or more diverse targets is a practical default.')
					])
				]),
				node
			]);
		});
	}
});
