'use strict';
'require view';
'require poll';
'require dom';
'require hysteria as hy';

/* The detail behind the one line the interface list shows.
 *
 * Read-only, deliberately. A per-link reconnect is trivial for a member and
 * rebuilds the entire interface for the holder, and which link is which changes
 * from minute to minute -- the pool hands servers out at dial time and the
 * process holding the device is whichever one claimed a slot first. A button
 * whose blast radius depends on unstated runtime state is not a button. */

function duration(s) {
	if (typeof s != 'number' || s < 0)
		return '-';
	if (s >= 86400)
		return '%dd %dh'.format(s / 86400, (s % 86400) / 3600);
	if (s >= 3600)
		return '%dh %dm'.format(s / 3600, (s % 3600) / 60);
	if (s >= 60)
		return '%dm %ds'.format(s / 60, s % 60);
	return '%ds'.format(s);
}

/* The banner, which is the point of the page.
 *
 * Every way this goes wrong goes wrong quietly: a bundle that never formed
 * carries traffic and reports itself up, just at a fraction of the throughput
 * that was configured. So the first line of every card is the verdict, and the
 * table underneath is the follow-up. */
function banner(st) {
	var cls = 'info', head, body;

	if (!st.up) {
		cls = 'danger';
		head = _('Interface is down');
		body = _('No PPP session is established. The interface status page has the reason netifd reported.');
	}
	else if (st.bundle_state == 'refused') {
		cls = 'warning';
		head = _('Single link — the server did not accept Multilink PPP');
		body = _('The link is up and working at one server\'s throughput. The other %d servers stay idle until a concentrator accepts MRRU.').format(Math.max(0, st.links_configured - 1));
	}
	else if (st.bundle_state == 'off') {
		cls = st.servers_ignored > 0 ? 'warning' : 'info';
		head = st.servers_ignored > 0
			? _('Multilink is disabled — %d configured servers are unused').format(st.servers_ignored)
			: _('Single server');
		body = st.servers_ignored > 0
			? _('Set Multilink PPP to Automatic on this interface to bundle them.')
			: _('This interface carries one Hysteria 2 server. Add another to bundle them with Multilink PPP.');
	}
	else if (st.links_up >= st.links_configured) {
		cls = 'info';
		head = _('Bundle formed — %d of %d servers carrying').format(st.links_up, st.links_configured);
		body = _('Every configured server is in the bundle.');
	}
	else {
		cls = 'warning';
		head = _('Bundle formed — %d of %d servers carrying').format(st.links_up, st.links_configured);
		body = _('The connection is up at reduced capacity. The links below say which server is missing and why.');
	}

	return E('div', { 'class': 'alert-message ' + cls }, [
		E('strong', {}, head), E('br'), body
	]);
}

/* The device-owning pppd having no link of its own reads as a fault and is not
 * one. It is what the pool does on purpose: when the holder's transport dies it
 * parks holding the bundle while a supervisor redials that same server as an
 * ordinary member, so capacity comes back without the interface being rebuilt. */
function footnotes(st) {
	var notes = [], links = st.links || [], i, holder = false;

	for (i = 0; i < links.length; i++)
		if (links[i].role == 'holder')
			holder = true;

	if (st.bundle_state == 'formed' && !holder && st.links_up > 0)
		notes.push(_('The process holding the interface carries no link of its own right now. This is normal after a reconnect.'));

	if (st.supervisors_spare > 0)
		notes.push(_('%d link supervisor is standing by without a server. One always is: it takes over whichever server drops first.').format(st.supervisors_spare));

	if (st.bundle_state == 'formed')
		notes.push(_('Numbers are positions in the server pool, not priorities. Losing any link costs the same as losing any other.'));

	return notes.length
		? E('div', { 'class': 'cbi-value-description' },
			notes.map(function(n) { return E('div', {}, n); }))
		: E('div');
}

function linkRow(st, l) {
	var err = l.last_error || {},
	    note = '-';

	if (err.code)
		note = '%s · %s'.format(hy.reasonText(err.code),
			typeof err.ago == 'number' ? _('%s ago').format(duration(err.ago)) : _('just now'));
	else if (l.state == 'refused')
		note = hy.REASONS.MLPPP_JOIN_REFUSED;

	return E('tr', { 'class': 'tr' }, [
		E('td', { 'class': 'td', 'style': 'width:2em;opacity:0.6' }, String(l.slot)),
		E('td', { 'class': 'td' }, E('code', {}, l.server || '-')),
		E('td', { 'class': 'td', 'style': 'opacity:0.7' }, l.role || '-'),
		E('td', { 'class': 'td' }, [
			E('span', { 'class': 'hy-led hy-' + hy.severity(l.state) }),
			' ', hy.stateText(l.state)
		]),
		E('td', { 'class': 'td', 'style': 'font-variant-numeric:tabular-nums' },
			duration(l['for'])),
		E('td', { 'class': 'td' }, note)
	]);
}

function card(st) {
	var links = st.links || [];

	return E('div', { 'class': 'cbi-section' }, [
		E('h3', {}, [
			st['interface'],
			st.device ? E('small', { 'style': 'opacity:0.6' }, ' — ' + st.device) : ''
		]),
		banner(st),
		E('div', { 'class': 'cbi-value-description', 'style': 'opacity:0.7' }, [
			st.mtu ? _('MTU %d').format(st.mtu) : '',
			st.bundle ? ' · ' + _('bundle %s').format(st.bundle) : '',
			st.endpoint ? ' · ' + _('endpoint %s').format(st.endpoint) : ''
		]),
		E('div', { 'style': 'overflow-x:auto' }, E('table', { 'class': 'table' }, [
			E('tr', { 'class': 'tr table-titles' }, [
				E('th', { 'class': 'th' }, '#'),
				E('th', { 'class': 'th' }, _('Server')),
				E('th', { 'class': 'th' }, _('Role')),
				E('th', { 'class': 'th' }, _('State')),
				E('th', { 'class': 'th' }, _('For')),
				E('th', { 'class': 'th' }, _('Last event'))
			])
		].concat(links.map(function(l) { return linkRow(st, l); })))),
		footnotes(st)
	]);
}

function body(map) {
	var names = Object.keys(map || {}).sort();

	if (!names.length)
		return E('div', { 'class': 'cbi-section' }, [
			E('p', {}, _('No Hysteria 2 interface is running. Bring one up from Network → Interfaces.'))
		]);

	return E('div', {}, names.map(function(n) { return card(map[n]); }));
}

return view.extend({
	load: function() {
		return hy.fetch();
	},

	render: function(map) {
		var container = E('div', {}, body(map));

		/* Its own poll rather than the module's shared one: this page renders the
		 * data instead of reading it out of the cache when asked, so it needs the
		 * refresh and the redraw in the same tick. */
		poll.add(function() {
			return hy.fetch().then(function(next) {
				dom.content(container, body(next));
			});
		}, 5);

		return E('div', {}, [
			E('style', {}, [
				'.hy-led{display:inline-block;width:9px;height:9px;border-radius:2px;vertical-align:baseline}' +
				'.hy-ok{background:#2e7d45}' +
				'.hy-busy{background:#96650c}' +
				'.hy-bad{background:#a6322d}' +
				'.hy-idle{background:transparent;border:1px solid currentColor;opacity:0.5}'
			]),
			E('h2', {}, _('Hysteria 2 Multilink PPP')),
			E('div', { 'class': 'cbi-map-descr' },
				_('Which servers each Hysteria 2 interface is connected to. Updates every 5 seconds.')),
			container
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
