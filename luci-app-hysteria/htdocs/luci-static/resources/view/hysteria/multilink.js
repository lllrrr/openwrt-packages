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

/* A byte count, or a dash where the link published none.
 *
 * A dash rather than a zero, and the difference is the whole point: zero is the
 * claim that this server carried nothing, which is a fault. No figure at all is
 * what a link that never came up reports, and the state column beside it already
 * says why. */
function bytes(n) {
	return typeof n == 'number' ? hy.fmtBytes(n) : '-';
}

/* What these two columns are counting, as hover text on every cell.
 *
 * They are not the bundle's RX and TX divided up, and an operator who adds them
 * expecting the interface total will come up short by a few percent and go
 * looking for the missing traffic. The interface figure is the kernel counting IP
 * packets after multilink reassembly; these are PPP frames counted by the process
 * carrying each link, which includes the per-fragment multilink header and every
 * LCP echo, and excludes everything the QUIC leg adds underneath. */
var COUNTER_HELP = _('PPP frames this link carried, counted by the process carrying it. Includes multilink and LCP overhead, so the links do not sum exactly to the interface total above.');

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
		/* The address in an array rather than as a bare string: LuCI's dom.append
		 * createTextNode's the items of an array and assigns a lone string to
		 * innerHTML, so markup in a value would be parsed as markup. Nothing here
		 * is remote -- a server address comes from this router's own UCI -- but
		 * the array costs two characters and removes the question. */
		E('td', { 'class': 'td', 'style': 'white-space:nowrap' },
			E('code', {}, [l.server || '-'])),
		E('td', {
			'class': 'td',
			'style': 'opacity:0.7',
			'title': ROLE_HELP[l.role] || ''
		}, l.role || '-'),
		/* Both nowrap, now that two more columns compete for the width: "In bundle"
		 * broken across two lines reads as two states, and "2h 14m" broken after
		 * the hours reads as a column of gibberish. The table scrolls sideways
		 * instead -- its wrapper has always been overflow-x:auto. */
		E('td', { 'class': 'td', 'style': 'white-space:nowrap' }, [
			E('span', { 'class': 'hy-led hy-' + hy.severity(l.state, bundled) }),
			' ', hy.stateText(l.state, bundled)
		]),
		E('td', { 'class': 'td hy-num' }, duration(l['for'])),
		E('td', { 'class': 'td hy-num', 'title': COUNTER_HELP }, bytes(l.rx_bytes)),
		E('td', { 'class': 'td hy-num', 'title': COUNTER_HELP }, bytes(l.tx_bytes)),
		E('td', { 'class': 'td' }, note)
	]);
}

/* The interface's own counters, in the form Network -> Interfaces states them.
 *
 * The same source as that page: one netdev per bundle, read straight out of its
 * kernel statistics. Shown here so that an operator reading per-server figures
 * has the total they belong to on the same screen, rather than having to hold a
 * number in their head across two pages. */
function interfaceTotals(st) {
	if (typeof st.rx_bytes != 'number' && typeof st.tx_bytes != 'number')
		return E('div');

	/* LuCI's own %.2mB rather than hy.fmtBytes, which is the one place on this
	 * page that delegates. These two figures are the ones a reader will hold up
	 * against Network -> Interfaces, so they are produced by the expression that
	 * page uses, character for character. The per-link columns below cannot do
	 * the same -- hysteria-ppp-status prints them too and has no LuCI -- so they
	 * go through the shared implementation instead, which reproduces this one. */
	function line(label, b, pkts) {
		return E('div', {}, [
			E('strong', {}, label), ': ',
			typeof b == 'number' ? '%.2mB'.format(b) : '-',
			typeof pkts == 'number' ? ' (%d %s)'.format(pkts, _('Pkts.')) : ''
		]);
	}

	return E('div', { 'class': 'cbi-value-description hy-num', 'style': 'opacity:0.9' }, [
		line(_('RX'), st.rx_bytes, st.rx_packets),
		line(_('TX'), st.tx_bytes, st.tx_packets)
	]);
}

/* --- the stacked per-link graph -------------------------------------------
 *
 * Why this is drawn here rather than fetched from LuCI's Realtime Graphs.
 *
 * That page's data comes from luci-bwc, whose interface sampler is an
 * opendir("/sys/class/net") loop with no plugin interface and no configuration:
 * it can sample a network device and nothing else. A member of a Multilink
 * bundle is not a network device -- it is a channel inside one, absent from
 * /sys/class/net entirely -- so no amount of configuration makes that feed
 * per-link. The bundle appears there and is already graphed correctly; the
 * breakdown below it is the part that has to come from somewhere else.
 *
 * What it comes from is the same ubus document the table above reads. Each
 * link's client publishes the rate series it measured, so the window is drawn
 * from the router's samples rather than from differences between page polls --
 * which is also why it is populated the moment the page opens rather than a
 * minute later, and why a reload does not clear it. */

var SVGNS = 'http://www.w3.org/2000/svg';

function SE(tag, attrs, children) {
	var el = document.createElementNS(SVGNS, tag), k;

	for (k in (attrs || {}))
		if (attrs[k] != null)
			el.setAttribute(k, attrs[k]);

	(Array.isArray(children) ? children : children != null ? [children] : [])
		.forEach(function(c) {
			el.appendChild(typeof c == 'object' ? c : document.createTextNode(String(c)));
		});

	return el;
}

/* One colour per slot, by position rather than by state.
 *
 * A slot keeps its colour for as long as the interface is up -- the server in
 * slot 2 is the same server from one poll to the next -- so a band that changes
 * height means throughput changed, and never that the legend was reshuffled
 * underneath it. Chosen to stay distinguishable on both LuCI themes; the first
 * three deliberately match the status LEDs above. */
var LINK_COLOURS = [
	'#2e7d45', '#1f6fb2', '#96650c', '#7b4ea8',
	'#a6322d', '#0f7c86', '#8a7300', '#4a4a8a'
];

function colourOf(i) {
	return LINK_COLOURS[i % LINK_COLOURS.length];
}

/* The links that published a usable series, and the window they share.
 *
 * Links are aligned by position from the *end* rather than by any timestamp,
 * because none of them publishes one. Every client writes on the same schedule
 * and the collector reads them all in a single pass, so the newest sample of one
 * link is within a write interval of the newest sample of the next -- a skew of
 * a few seconds on a window of sixty, which is invisible at this scale and is
 * the only alignment available without a shared clock.
 *
 * A link whose step differs is dropped rather than resampled. It cannot happen
 * between links of one bundle, which run the same binary; if it ever does, one
 * band drawn at the wrong time base would be worse than one band missing. */
function series(st) {
	var links = st.links || [], i, r, step = 0, len = 0, out = [];

	for (i = 0; i < links.length; i++) {
		r = hy.rates(links[i]);
		if (!r.length)
			continue;
		if (!step)
			step = links[i].hist_step_ms;
		else if (links[i].hist_step_ms != step)
			continue;

		out.push({ link: links[i], rates: r, colour: colourOf(i) });
		if (r.length > len)
			len = r.length;
	}

	return { step: step, len: len, links: out };
}

/* One link's rate at a position in the shared window, or zero before its series
 * begins. A link that connected thirty seconds ago carried nothing on this
 * bundle before that, so zero is the honest value rather than a gap. */
function valueAt(e, p, len, dir) {
	var off = len - e.rates.length;
	return p < off ? 0 : e.rates[p - off][dir];
}

/* A round number at or above the peak, so the axis label is readable and the
 * scale does not jitter with every poll the way a bare maximum would. */
function ceiling(v) {
	var mag, n;

	if (!(v > 0))
		return 1;

	mag = Math.pow(10, Math.floor(Math.log(v) / Math.LN10));
	n = v / mag;
	n = n <= 1 ? 1 : n <= 2 ? 2 : n <= 5 ? 5 : 10;
	return n * mag;
}

/* The chart itself: one filled band per link, stacked, so the outline is the
 * bundle's throughput and each band is one server's share of it.
 *
 * Stacked rather than overlaid, which is the one decision here that changes what
 * the picture means. Overlaid bands answer "how fast is this link", which the
 * table already answers; stacked, the top edge is the bundle and the question it
 * answers is the one this page exists for -- whether the throughput is coming
 * from every server or from one.
 *
 * preserveAspectRatio="none" so the SVG stretches to whatever width the theme
 * gives it. Nothing inside is stroked and no text lives in here, so there is
 * nothing for the non-uniform scale to distort; the labels are HTML alongside. */
function chart(s, dir) {
	var W = 600, H = 110, i, p, len = s.len,
	    totals = [], peak = 0, scale, below = [], bands = [], grid = [];

	for (p = 0; p < len; p++) {
		totals[p] = 0;
		below[p] = 0;
		for (i = 0; i < s.links.length; i++)
			totals[p] += valueAt(s.links[i], p, len, dir);
		if (totals[p] > peak)
			peak = totals[p];
	}

	/* Two different numbers, and reporting the wrong one is how a graph lies
	 * quietly. The axis is drawn against a round figure at or above the peak, so
	 * the picture does not rescale on every poll; the figure printed beside it is
	 * the peak itself, because that is what the reader is being told. */
	scale = ceiling(peak);

	/* With one sample there is no interval to plot across, and a polygon whose
	 * points all share an x is an empty chart beside a legend reporting a live
	 * rate. Drawn as a flat band spanning the width instead: one sample really
	 * does describe the whole of the window it is the only measurement of. */
	function x(p) {
		return len > 1 ? (p * W / (len - 1)).toFixed(1) : (p ? W : 0);
	}

	function y(v) {
		return (H - v * H / scale).toFixed(1);
	}

	for (i = 0; i < s.links.length; i++) {
		var top = [], bottom = [], v;

		for (p = 0; p < len; p++) {
			v = valueAt(s.links[i], p, len, dir);
			top.push(x(p) + ',' + y(below[p] + v));
			bottom.unshift(x(p) + ',' + y(below[p]));
			if (len == 1) {
				/* The same sample again at the far edge, so the band has width. */
				top.push(W + ',' + y(below[p] + v));
				bottom.unshift(W + ',' + y(below[p]));
			}
			below[p] += v;
		}

		bands.push(SE('polygon', {
			points: top.concat(bottom).join(' '),
			fill: s.links[i].colour,
			'fill-opacity': '0.55'
		}));
	}

	for (p = 1; p < 4; p++)
		grid.push(SE('line', {
			x1: 0, x2: W, y1: (p * H / 4).toFixed(1), y2: (p * H / 4).toFixed(1),
			stroke: 'currentColor', 'stroke-opacity': '0.15', 'stroke-width': '1',
			'vector-effect': 'non-scaling-stroke'
		}));

	return {
		peak: peak,
		svg: SE('svg', {
			viewBox: '0 0 ' + W + ' ' + H,
			preserveAspectRatio: 'none',
			width: '100%', height: H,
			style: 'display:block;border:1px solid rgba(128,128,128,0.3);border-radius:3px'
		}, grid.concat(bands))
	};
}

/* One direction's chart, with its scale and the window it covers. */
function chartBlock(s, dir, title) {
	var c = chart(s, dir), seconds = Math.round(s.len * s.step / 1000);

	return E('div', { 'style': 'flex:1 1 20em;min-width:16em' }, [
		E('div', { 'class': 'hy-num', 'style': 'display:flex;justify-content:space-between;opacity:0.7' }, [
			E('strong', {}, title),
			E('span', {}, _('peak %s').format(hy.fmtRate(c.peak, 1)))
		]),
		c.svg,
		E('div', { 'style': 'opacity:0.55;font-size:90%' },
			_('last %d seconds').format(seconds))
	]);
}

/* Which band is which, and what each is carrying right now.
 *
 * The current figure is the newest sample rather than an average over the
 * window, so it answers the same question the colour band's right-hand edge
 * does. A link that has just stopped reads zero here while its band still shows
 * the minute it carried, which is the correct pair of statements. */
function legend(s) {
	return E('div', { 'style': 'display:flex;flex-wrap:wrap;gap:0.25em 1.5em;margin-top:0.5em' },
		s.links.map(function(e) {
			var last = e.rates[e.rates.length - 1];

			return E('span', { 'class': 'hy-num', 'style': 'display:inline-flex;align-items:center;gap:0.4em' }, [
				E('span', {
					'style': 'width:10px;height:10px;border-radius:2px;background:' +
						e.colour + ';opacity:0.75'
				}),
				E('code', {}, [e.link.server || _('server %d').format(e.link.slot)]),
				E('span', { 'style': 'opacity:0.7' }, '↓ ' + hy.fmtRate(last.rx, 1)),
				E('span', { 'style': 'opacity:0.7' }, '↑ ' + hy.fmtRate(last.tx, 1))
			]);
		}));
}

function graphs(st) {
	var s = series(st), split = s.links.length > 1;

	/* Nothing to draw is the ordinary state of a bundle that is down, and an
	 * empty pair of axes reads as "no traffic" rather than "no measurement".
	 * The banner above has already said which. */
	if (!s.len || !s.links.length)
		return E('div');

	return E('div', { 'style': 'margin:0.75em 0' }, [
		E('div', { 'style': 'display:flex;gap:1.5em;flex-wrap:wrap' }, [
			/* "by server" only where there is more than one, because with a single
			 * link the phrase promises a breakdown that the picture does not have
			 * and the reader would go looking for. */
			chartBlock(s, 'rx', split ? _('Download, by server') : _('Download')),
			chartBlock(s, 'tx', split ? _('Upload, by server') : _('Upload'))
		]),
		/* One band needs no key: the table below already names the server, and a
		 * legend of one is a colour swatch beside the only thing it could mean. */
		split ? legend(s) : E('div')
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
		interfaceTotals(st),
		graphs(st),
		E('div', { 'style': 'overflow-x:auto' }, E('table', { 'class': 'table' }, [
			E('tr', { 'class': 'tr table-titles' }, [
				E('th', { 'class': 'th' }, '#'),
				E('th', { 'class': 'th' }, _('Server')),
				E('th', { 'class': 'th' }, _('Role')),
				E('th', { 'class': 'th' }, _('State')),
				E('th', { 'class': 'th' }, _('For')),
				E('th', { 'class': 'th hy-num' }, _('RX')),
				E('th', { 'class': 'th hy-num' }, _('TX')),
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
		 * refresh and the redraw in the same tick.
		 *
		 * Three seconds rather than the module's five, matching both the rate at
		 * which the clients rewrite their counter files and the cadence of LuCI's
		 * own realtime graphs. Polling faster would redraw the same samples; the
		 * window itself is the router's and does not depend on this interval. */
		poll.add(function() {
			return hy.fetch().then(function(next) {
				dom.content(container, body(next));
			});
		}, 3);

		return E('div', {}, [
			E('style', {}, [
				'.hy-num{font-variant-numeric:tabular-nums;white-space:nowrap}' +
				'.hy-led{display:inline-block;width:9px;height:9px;border-radius:2px;vertical-align:baseline}' +
				'.hy-ok{background:#2e7d45}' +
				'.hy-busy{background:#96650c}' +
				'.hy-bad{background:#a6322d}' +
				'.hy-idle{background:transparent;border:1px solid currentColor;opacity:0.5}'
			]),
			E('h2', {}, _('Hysteria 2 Links')),
			E('div', { 'class': 'cbi-map-descr' },
				_('Which servers each Hysteria 2 interface is connected to, and how much of the interface\'s traffic each one is carrying. Updates every 3 seconds.')),
			container
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
