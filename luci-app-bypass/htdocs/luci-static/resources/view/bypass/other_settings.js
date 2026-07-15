'use strict';
'require view';
'require form';
'require uci';
'require fs';

function api(/* action, ...args */) {
	return fs.exec('/usr/share/bypass/api.sh', Array.prototype.slice.call(arguments)).then(function (res) {
		var data = JSON.parse(res.stdout || '{}');
		if (data.code !== 0) throw new Error(data.error || _('Operation failed.'));
		return data;
	});
}

function encodeBase64(value) {
	return btoa(unescape(encodeURIComponent(value)));
}

function validateDirectIpList(_sid, value) {
	var lines = String(value || '').replace(/\r\n/g, '\n').split('\n');
	for (var i = 0; i < lines.length; i++) {
		var line = lines[i].trim();
		if (!line || line.charAt(0) === '#') continue;
		if (/^geoip:[A-Za-z0-9_-]+$/.test(line)) continue;
		var prefix = line.split('/');
		if (prefix.length > 2 || !prefix[0])
			return _('Invalid Direct IP entry: %s').format(line);
		if (prefix[0].indexOf(':') >= 0) {
			if (!/^[0-9A-Fa-f:.]+$/.test(prefix[0]) ||
				(prefix.length === 2 && (!/^\d+$/.test(prefix[1]) || +prefix[1] > 128)))
				return _('Invalid Direct IP entry: %s').format(line);
		} else {
			var octets = prefix[0].split('.');
			if (octets.length !== 4 || octets.some(function (n) {
				return !/^\d+$/.test(n) || +n > 255;
			}) || (prefix.length === 2 && (!/^\d+$/.test(prefix[1]) || +prefix[1] > 32)))
				return _('Invalid Direct IP entry: %s').format(line);
		}
	}
	return true;
}

function validatePortList(_sid, value) {
	if (value === 'disable') return true;
	if (!/^\d+(?::\d+)?(?:,\d+(?::\d+)?)*$/.test(value || ''))
		return _('Use comma-separated ports or ranges, for example 80,443,1000:2000.');
	var entries = value.split(',');
	for (var i = 0; i < entries.length; i++) {
		var range = entries[i].split(':');
		var first = +range[0], last = +(range[1] || range[0]);
		if (first < 1 || last > 65535 || first > last)
			return _('Ports must be between 1 and 65535 and ranges must be ascending.');
	}
	return true;
}

function validateTime(_sid, value) {
	var match = /^(\d{1,2}):(\d{2})$/.exec(value || '');
	return match && +match[1] <= 23 && +match[2] <= 59
		? true : _('Enter a valid time in HH:MM format.');
}

// Other Settings — mirrors passwall2's client/other.lua, minus the Xray /
// Sing-box core sections (bypass has neither). Two sections:
//   • Delay Settings (global_delay): start_delay, scheduled
//     stop/start/restart via week_mode + time_mode + interval_mode (cron).
//   • Forwarding Settings (global_forwarding): redir/no-redir ports, redirect
//     vs tproxy.

return view.extend({
	load: function () {
		return Promise.all([
			uci.load('bypass'),
			api('get_direct_ip')
		]);
	},

	render: function (data) {
		var m = new form.Map('bypass');
		var o;

		/* ===== Delay Settings ===== */
		var sDelay = m.section(form.TypedSection, 'global_delay', _('Delay Settings'));
		sDelay.anonymous = true;

		o = sDelay.option(form.Flag, 'start_daemon', _('Open and close Daemon'));
		o.default = '1';
		o.rmempty = false;

		o = sDelay.option(form.Value, 'start_delay', _('Delay Start'), _('Units: seconds.'));
		o.datatype = 'uinteger';
		o.default = '60';
		o.placeholder = '60';

		// Scheduled stop / start / restart: week_mode + time_mode + interval_mode.
		var verbs = ['stop', 'start', 'restart'];
		verbs.forEach(function (verb) {
			o = sDelay.option(form.ListValue, verb + '_week_mode',
				_(verb.charAt(0).toUpperCase() + verb.slice(1)) + ' ' + _('automatically mode'));
			o.value('', _('Disable'));
			if (verb === 'restart') o.value('8', _('Loop Mode'));
			o.value('7', _('Every day'));
			o.value('1', _('Every Monday'));
			o.value('2', _('Every Tuesday'));
			o.value('3', _('Every Wednesday'));
			o.value('4', _('Every Thursday'));
			o.value('5', _('Every Friday'));
			o.value('6', _('Every Saturday'));
			o.value('0', _('Every Sunday'));

			o = sDelay.option(form.Value, verb + '_time_mode',
				_(verb.charAt(0).toUpperCase() + verb.slice(1)) + ' ' + _('Time'));
			o.value('0:00');
			for (var t = 0; t <= 23; t++) {
				if (t === 12) o.value('12:30');
				else if (t === 23) o.value('23:59');
				else o.value(t + ':00');
			}
			o.default = '0:00';
			o.validate = validateTime;
			o.depends(verb + '_week_mode', '0');
			o.depends(verb + '_week_mode', '1');
			o.depends(verb + '_week_mode', '2');
			o.depends(verb + '_week_mode', '3');
			o.depends(verb + '_week_mode', '4');
			o.depends(verb + '_week_mode', '5');
			o.depends(verb + '_week_mode', '6');
			o.depends(verb + '_week_mode', '7');

			o = sDelay.option(form.ListValue, verb + '_interval_mode',
				_(verb.charAt(0).toUpperCase() + verb.slice(1)) + ' ' + _('Interval(Hour)'));
			for (var h = 1; h <= 24; h++) o.value(String(h), h + ' ' + _('hour'));
			o.default = '2';
			o.depends(verb + '_week_mode', '8');
		});

		/* ===== Forwarding Settings ===== */
		var sFwd = m.section(form.TypedSection, 'global_forwarding', _('Forwarding Settings'));
		sFwd.anonymous = true;

		o = sFwd.option(form.Value, 'tcp_no_redir_ports', _('TCP No Redir Ports'));
		o.validate = validatePortList;
		o.value('disable', _('No patterns are used'));
		o.value('1:65535', _('All'));

		o = sFwd.option(form.Value, 'udp_no_redir_ports', _('UDP No Redir Ports'),
			_('NaiveProxy cannot proxy UDP. These destination ports bypass strict UDP blocking and go Direct, which may expose the real egress IP. With no patterns configured, external forwarded UDP is blocked by default; redirected DNS and local network traffic remain available.'));
		o.validate = validatePortList;
		o.default = 'disable';
		o.value('disable', _('No patterns are used'));
		o.value('1:65535', _('All'));

		o = sFwd.option(form.Value, 'tcp_redir_ports', _('TCP Redir Ports'));
		o.validate = validatePortList;
		o.default = '1:65535';
		o.value('1:65535', _('All'));
		o.value('22,25,53,80,143,443,465,587,853,873,993,995,5222,8080,8443,9418', _('Common Use'));
		o.value('80,443', _('Only Web'));

		o = sFwd.option(form.DummyValue, '_port_tips', ' ');
		o.rawhtml = true;
		o.cfgvalue = function () {
			return E('span', { style: 'color:red' }, [
				_('The port settings support single ports and ranges.'), E('br'),
				_('Separate multiple ports with commas (,).'), E('br'),
				_('Example: 21,80,443,1000:2000.')
			]);
		};

		o = sFwd.option(form.ListValue, 'tcp_proxy_way', _('TCP Proxy way'));
		o.default = 'redirect';
		o.value('redirect', _('REDIRECT'));
		o.value('tproxy', _('TPROXY'));

		o = sFwd.option(form.Flag, 'ipv6_tproxy', _('IPv6 TProxy'),
			_('Experimental feature. Make sure that your node supports IPv6.'));
		o.default = '0';
		o.rmempty = false;

		o = sFwd.option(form.Flag, 'accept_icmp', _('Hijacking ICMP (PING)'));
		o.default = '0';
		o.rmempty = false;

		o = sFwd.option(form.TextValue, '_direct_ip', _('Direct IP List'),
			_('These IP addresses and CIDR ranges connect directly without entering BypassCore. One entry per line; geoip:CODE and comments beginning with # are also supported.'));
		o.rows = 15;
		o.wrap = 'off';
		o.rawhtml = false;
		o.validate = validateDirectIpList;
		o.cfgvalue = function () { return data[1].direct_ip || ''; };
		o.write = function (_sid, value) {
			return api('set_direct_ip', encodeBase64(String(value || '').replace(/\r\n/g, '\n')));
		};
		o.remove = function () { return api('set_direct_ip', encodeBase64('')); };

		return m.render();
	}
});
