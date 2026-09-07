'use strict';
'require view';
'require form';
'require fs';
'require ui';
'require poll';
'require network';

/* SPDX-License-Identifier: MIT */

var STATE_LABEL = {
	idle:      _('Idle'),
	running:   _('Redialing'),
	matched:   _('Address accepted'),
	exhausted: _('Gave up (max attempts reached)')
};

function readStatus() {
	return fs.exec('/usr/sbin/wanip-selector', [ 'status' ]).then(function (res) {
		try { return JSON.parse(res.stdout || '{}'); }
		catch (e) { return {}; }
	}).catch(function () { return {}; });
}

function badge(text, colour) {
	return E('span', {
		'style': 'display:inline-block;padding:2px 8px;border-radius:3px;' +
		         'background:' + colour + ';color:#fff;font-weight:bold'
	}, text);
}

function row(label, value) {
	return E('tr', { 'class': 'tr' }, [
		E('td', { 'class': 'td left', 'width': '33%' }, label),
		E('td', { 'class': 'td left' }, value)
	]);
}

function renderStatus(st) {
	var rows = [];
	var addr = st.ip || '-';
	var matched = (st.matched == 1);
	var state = st.status || 'idle';

	rows.push(row(_('Current address'), [
		E('strong', {}, addr), ' ',
		(addr === '-') ? badge(_('no address'), '#888')
		               : (matched ? badge(_('match'), '#4caf50')
		                          : badge(_('no match'), '#ff9800'))
	]));

	rows.push(row(_('State'),
		(st.running == 1) ? badge(STATE_LABEL.running, '#2196f3')
		                  : (STATE_LABEL[state] || state)));

	rows.push(row(_('Attempts'),
		String(st.attempts || 0) +
		((st.max_attempts > 0) ? ' / ' + st.max_attempts
		                       : ' / ' + _('unlimited'))));

	rows.push(row(_('Monitor'),
		(st.monitor == 1)
			? [ badge(_('running'), '#4caf50'), ' ',
			    _('checking every %s s').format(st.check_interval) ]
			: badge(_('stopped'), '#888')));

	if (st.message)
		rows.push(row(_('Message'), st.message));

	return E('table', { 'class': 'table' }, rows);
}

return view.extend({
	load: function () {
		return Promise.all([
			readStatus(),
			network.getNetworks()
		]);
	},

	render: function (data) {
		var st = data[0] || {};
		var networks = data[1] || [];
		var m, s, o;

		/* ------------------------- live status ------------------------- */

		var statusBox = E('div', { 'id': 'wanip-status' }, renderStatus(st));

		poll.add(function () {
			return readStatus().then(function (cur) {
				var box = document.getElementById('wanip-status');
				if (box) {
					box.innerHTML = '';
					box.appendChild(renderStatus(cur));
				}
			});
		}, 5);

		var buttons = E('div', { 'class': 'cbi-value' }, [
			E('button', {
				'class': 'cbi-button cbi-button-apply',
				/* 'trigger' returns at once, the loop keeps running detached,
				   otherwise the browser would hang for the whole round */
				'click': ui.createHandlerFn(this, function () {
					return fs.exec('/usr/sbin/wanip-selector',
					               [ 'trigger', 'force' ]).then(function () {
						ui.addNotification(null, E('p',
							_('Redial round started. Watch the status above; the connection drops while it runs.')),
							'info');
					});
				})
			}, _('Redial now')),
			' ',
			E('button', {
				'class': 'cbi-button cbi-button-neutral',
				'click': ui.createHandlerFn(this, function () {
					return fs.exec('/usr/sbin/wanip-selector', [ 'check' ]).then(function (res) {
						ui.addNotification(null, E('p', (res.stdout || '').trim()),
							(res.code === 0) ? 'info' : 'warning');
					});
				})
			}, _('Check now')),
			' ',
			E('button', {
				'class': 'cbi-button cbi-button-reset',
				'click': ui.createHandlerFn(this, function () {
					return fs.exec('/usr/sbin/wanip-selector', [ 'stop' ]).then(function () {
						ui.addNotification(null,
							E('p', _('Redial loop stopped and the lock was cleared.')), 'info');
					});
				})
			}, _('Stop'))
		]);

		/* ------------------------- settings ------------------------- */

		m = new form.Map('wanip_selector', _('WAN IP Selector'),
			_('Redial the WAN interface until its public IPv4 address falls inside (or outside) the address pools listed below. Useful when an ISP hands out addresses from several pools of very different quality.'));

		s = m.section(form.NamedSection, 'config', 'wanip_selector');
		s.anonymous = true;

		s.tab('general', _('General'));
		s.tab('monitor', _('Monitoring'));
		s.tab('advanced', _('Advanced'));

		o = s.taboption('general', form.Flag, 'enabled', _('Enable'),
			_('While disabled nothing is redialed automatically. The buttons above still work.'));
		o.rmempty = false;

		o = s.taboption('general', form.ListValue, 'interface', _('Interface'),
			_('Logical interface to watch and redial.'));
		networks.forEach(function (net) {
			var name = net.getName();
			if (name !== 'loopback')
				o.value(name, name + ' (' + (net.getProtocol() || '?') + ')');
		});
		o.default = 'wan';

		o = s.taboption('general', form.ListValue, 'match_mode', _('Match mode'));
		o.value('include', _('Accept only addresses inside the list'));
		o.value('exclude', _('Accept anything except the list'));
		o.default = 'include';

		o = s.taboption('general', form.DynamicList, 'target', _('Address pools'),
			_('CIDR such as 203.0.113.0/24, or a bare prefix such as 203.0.113. or 203.0 which expand to /24 and /16. An empty list accepts any address.'));
		o.datatype = 'string';
		o.placeholder = '203.0.113.0/24';

		o = s.taboption('general', form.Value, 'max_attempts', _('Max attempts'),
			_('Redial at most this many times. 0 means never give up, which keeps the line down until a matching address appears. Use with care.'));
		o.datatype = 'uinteger';
		o.default = '10';

		/* -- monitoring -- */

		o = s.taboption('monitor', form.Flag, 'monitor_enabled', _('Enable monitoring'),
			_('Keep checking the address in the background, not only when the link comes up. ISPs usually rotate the address every few days on their own, which does not always produce an interface event.'));
		o.rmempty = false;

		o = s.taboption('monitor', form.Value, 'check_interval', _('Check interval'),
			_('Seconds between checks. A few minutes is plenty; the address changes at most once every few days.'));
		o.datatype = 'range(30,86400)';
		o.default = '300';
		o.depends('monitor_enabled', '1');

		/* -- advanced -- */

		o = s.taboption('advanced', form.Value, 'retry_delay', _('Delay between attempts'),
			_('Seconds. Keep this above a few seconds so the ISP is not hammered.'));
		o.datatype = 'range(1,3600)';
		o.default = '15';

		o = s.taboption('advanced', form.Value, 'settle_time', _('Settle time'),
			_('Seconds to wait for the interface to obtain an address after a redial. A grace period is added automatically for slow PPPoE links.'));
		o.datatype = 'range(1,300)';
		o.default = '8';

		o = s.taboption('advanced', form.Value, 'cooldown', _('Cooldown'),
			_('Seconds to pause after the attempt limit is reached, before a new round may start. 0 disables the pause.'));
		o.datatype = 'uinteger';
		o.default = '600';

		o = s.taboption('advanced', form.Flag, 'verbose', _('Verbose logging'),
			_('Log every attempt to the system log under the tag wanip-selector.'));
		o.default = '1';

		return m.render().then(function (formEl) {
			return E('div', {}, [
				E('h3', {}, _('Status')),
				statusBox,
				buttons,
				E('hr'),
				formEl
			]);
		});
	}
});
