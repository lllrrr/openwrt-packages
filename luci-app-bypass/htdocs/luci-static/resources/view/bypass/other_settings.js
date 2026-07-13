'use strict';
'require view';
'require form';
'require uci';

// Other Settings — mirrors passwall2's client/other.lua, minus the Xray /
// Sing-box core sections (bypass has neither). Two sections:
//   • Delay Settings (global_delay): start_daemon, start_delay, scheduled
//     stop/start/restart via week_mode + time_mode + interval_mode (cron).
//   • Forwarding Settings (global_forwarding): redir/no-redir ports, redirect
//     vs tproxy, ipv6_tproxy, accept_icmp/v6.

return view.extend({
	load: function () {
		return uci.load('bypass');
	},

	render: function () {
		var m = new form.Map('bypass', _('Other Settings'));
		var o;

		/* ===== Delay Settings ===== */
		var sDelay = m.section(form.TypedSection, 'global_delay', _('Delay Settings'));
		sDelay.anonymous = true;

		o = sDelay.option(form.Flag, 'start_daemon', _('Open and close Daemon'),
			_('Keep the service alive; restart it if it dies.'));
		o.rmempty = false;
		o.default = '1';

		o = sDelay.option(form.Value, 'start_delay', _('Delay Start'), _('Units: seconds.'));

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
		o.value('disable', _('No patterns are used'));
		o.value('1:65535', _('All'));

		o = sFwd.option(form.Value, 'udp_no_redir_ports', _('UDP No Redir Ports'),
			E('span', { style: 'color:red' }, _('Fill in the ports you don\'t want to be forwarded by the agent, with the highest priority.')));
		o.value('disable', _('No patterns are used'));
		o.value('1:65535', _('All'));

		o = sFwd.option(form.Value, 'tcp_redir_ports', _('TCP Redir Ports'));
		o.value('1:65535', _('All'));
		o.value('22,25,53,80,143,443,465,587,853,873,993,995,5222,8080,8443,9418', _('Common Use'));
		o.value('80,443', _('Only Web'));

		o = sFwd.option(form.Value, 'udp_redir_ports', _('UDP Redir Ports'));
		o.value('1:65535', _('All'));

		o = sFwd.option(form.ListValue, 'tcp_proxy_way', _('TCP Proxy way'));
		o.value('redirect', _('REDIRECT'));
		o.value('tproxy', _('TPROXY'));

		o = sFwd.option(form.Flag, 'ipv6_tproxy', _('IPv6 TProxy'),
			E('span', { style: 'color:red' }, _('Experimental feature. Make sure that your node supports IPv6.')));
		o.rmempty = false;

		o = sFwd.option(form.Flag, 'accept_icmp', _('Hijacking ICMP (PING)'));
		o = sFwd.option(form.Flag, 'accept_icmpv6', _('Hijacking ICMPv6 (IPv6 PING)'));
		o.depends('ipv6_tproxy', '1');

		return m.render();
	}
});
