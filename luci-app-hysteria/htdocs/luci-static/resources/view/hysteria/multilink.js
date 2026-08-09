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
 * table underneath is the follow-up.
 *
 * An unsettled join is one of those quiet ways, which is why it gets a warning
 * rather than the reassurance it used to get folded into. It is not a failure --
 * the link may well be carrying its full share -- but nobody can tell, and a
 * headline that cannot tell must not say "every configured server is in the
 * bundle". */
function banner(st) {
	/* hy.tally rather than st.links_up: that field is the sum of "confirmed in
	 * the bundle" and "up, membership never settled", and printing the sum under
	 * the word "carrying" is what made this banner contradict its own table. */
	var cls = 'info', head, body, t = hy.tally(st), missing;

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
	else {
		missing = Math.max(0, st.links_configured - t.up);

		if (missing > 0 && t.unconfirmed > 0) {
			cls = 'warning';
			head = _('Bundle formed — %d of %d servers confirmed in it').format(t.carrying, st.links_configured);
			body = missing == 1 && t.unconfirmed == 1
				? _('One server is not connected at all, and one more is connected without having reported a join. The table says which is which.')
				: _('%d servers are not connected at all, and %d more are connected without having reported a join. The table says which is which.').format(missing, t.unconfirmed);
		}
		else if (missing > 0) {
			cls = 'warning';
			head = _('Bundle formed — %d of %d servers carrying').format(t.carrying, st.links_configured);
			body = _('The connection is up at reduced capacity. The links below say which server is missing and why.');
		}
		else if (t.unconfirmed > 0) {
			cls = 'warning';
			head = _('Bundle formed — %d of %d servers confirmed in it').format(t.carrying, st.links_configured);
			body = t.unconfirmed == 1
				? _('The remaining server is connected, but never reported joining the bundle, so whether it carries any share of the traffic is unknown. See the note below the table.')
				: _('The remaining %d servers are connected, but never reported joining the bundle, so whether they carry any share of the traffic is unknown. See the note below the table.').format(t.unconfirmed);
		}
		else {
			cls = 'info';
			head = _('Bundle formed — %d of %d servers carrying').format(t.carrying, st.links_configured);
			body = _('Every configured server is confirmed in the bundle.');
		}
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
	var notes = [], links = st.links || [], i, holder = false, t = hy.tally(st);

	for (i = 0; i < links.length; i++)
		if (links[i].role == 'holder')
			holder = true;

	if (st.bundle_state == 'formed' && !holder && t.up > 0)
		notes.push(_('The process holding the interface carries no link of its own right now. This is normal after a reconnect.'));

	/* What an unsettled join is, because the state name alone reads as either a
	 * failure or a success depending on which the reader expected, and it is
	 * neither. A member announces its join on its own pppd log and nothing else
	 * on the router reports the fact -- there is no ioctl that asks whether a
	 * channel is in a bundle -- so a pppd whose wording does not match, or a log
	 * that could not be opened, leaves the question open for as long as the link
	 * runs. The remedy is in the system log either way, so say where to look. */
	if (st.bundle_state == 'formed' && t.unconfirmed > 0)
		notes.push(_('"Join unconfirmed" is the absence of a verdict, not a refusal: the transport is up, but nothing has confirmed the link joined the bundle. A link that was actually turned away reads "Refused by bundle" instead, and one that failed to stay up would not hold this state for long — so a link that has been here for hours is most likely carrying its share, with only the confirmation missing. That confirmation is a line on the link\'s own pppd log, which stays unread if the log is empty or if this pppd words the line differently.'));

	/* supervisors_spare is not reported here at all, and that is the decision
	 * rather than an omission.
	 *
	 * There is one supervisor per configured server and the interface's own pppd
	 * occupies a slot without being one of them, so exactly one supervisor is
	 * idle whenever the bundle is whole. Stated on a page whose every other line
	 * is about servers, "standing by without a server" reads as a fourth server
	 * that has gone missing -- and the note was written for a reader counting
	 * dialling links against configured ones and coming up short, which a table
	 * listing every configured server with its own state does not leave anybody
	 * doing.
	 *
	 * Nor is a surplus worth reporting, which was the tempting half. A member in
	 * backoff has released its slot, so the count rises for as long as the sleep
	 * lasts -- meaning the line would appear exactly when the table already says
	 * "Retrying", and disappear on the next attempt. A footnote that flaps with
	 * the retry loop is worse than no footnote.
	 *
	 * The field stays in the ubus object and in hysteria-ppp-status, where the
	 * reader is debugging the pool rather than reading a server list. */

	if (st.bundle_state == 'formed')
		notes.push(_('Numbers are positions in the server pool, not priorities. Losing any link costs the same as losing any other.'));

	return notes.length
		? E('div', { 'class': 'cbi-value-description' },
			notes.map(function(n) { return E('div', {}, n); }))
		: E('div');
}

/* Two words the page prints raw and nothing else on the router explains. Which
 * of them a server gets is decided at dial time and changes at every reconnect,
 * so an operator who reads "holder" as a rank has been told the opposite of the
 * truth. Hover text rather than another footnote: the page already carries
 * three, and this is a question about one cell. */
var ROLE_HELP = {
	holder: _('The link netifd itself runs. Its pppd owns the interface device and created the bundle. Which server holds it is decided at dial time, not configured.'),
	member: _('An extra link dialled into the same bundle. It contributes bandwidth and nothing else — no address, no routes of its own.')
};

function linkRow(st, l) {
	var err = l.last_error || {},
	    bundled = (st.bundle_state == 'formed'),
	    note = '-';

	if (err.code)
		note = '%s · %s'.format(hy.reasonText(err.code),
			typeof err.ago == 'number' ? _('%s ago').format(duration(err.ago)) : _('just now'));
	else if (l.state == 'refused')
		note = hy.REASONS.MLPPP_JOIN_REFUSED;
	/* The same column the refusal above uses, for the same reason: it is where
	 * this table says why a link is not known to be carrying. */
	else if (bundled && l.state == 'connected')
		note = _('no join reported on this link\'s pppd log');

	return E('tr', { 'class': 'tr' }, [
		E('td', { 'class': 'td', 'style': 'width:2em;opacity:0.6' }, String(l.slot)),
		E('td', { 'class': 'td' }, E('code', {}, l.server || '-')),
		E('td', {
			'class': 'td',
			'style': 'opacity:0.7',
			'title': ROLE_HELP[l.role] || ''
		}, l.role || '-'),
		E('td', { 'class': 'td' }, [
			E('span', { 'class': 'hy-led hy-' + hy.severity(l.state, bundled) }),
			' ', hy.stateText(l.state, bundled)
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
			E('h2', {}, _('Hysteria 2 Links')),
			E('div', { 'class': 'cbi-map-descr' },
				_('Which servers each Hysteria 2 interface is connected to, and which of them are carrying traffic. Updates every 5 seconds.')),
			container
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
