'use strict';
'require baseclass';
'require rpc';
'require poll';

/* Shared by the protocol class and the status page.
 *
 * It exists for the reason data ever gets factored out: the two would otherwise
 * each carry their own copy of the reason strings and their own idea of what
 * counts as a degraded bundle, and the interface list and the status page would
 * eventually disagree about the same router with no way to tell which was right.
 * The collector on the other side of ubus is one library with two formatters for
 * exactly the same reason. */

var callStatus = rpc.declare({
	object: 'hysteria',
	method: 'status',
	expect: { interfaces: [] }
});

/* Why a link is not carrying, in sentences.
 *
 * The same strings the protocol class hands to network.registerErrorCode, from
 * one object rather than two lists: these arrive by two routes -- netifd's error
 * channel for the ones the handler reports, and the status object for the ones a
 * member link fails with -- and a subscriber reading the interface page should
 * not be able to tell which route a sentence took. */
var REASONS = {
	CONFIG_FILE_MISSING: _('Configuration file not found'),
	CONFIG_WRITE_FAILED: _('Unable to write generated configuration'),
	MISSING_SERVER: _('No server address specified'),
	AUTH_FAILED: _('Server rejected the authentication password'),
	NO_ROUTE: _('The server has no LNS group configured for this account'),

	LINK_DOWN: _('The connection to the Hysteria 2 server was lost'),
	LNS_UNREACHABLE: _('The server could not establish an L2TP tunnel to the LNS'),
	LNS_DISCONNECTED: _('The LNS disconnected the session'),
	NO_LNS: _('No LNS in the configured group is available'),
	PATH_NARROWED: _('The path stopped carrying full-size packets; the link will be rebuilt at a smaller MTU'),
	UNKNOWN: _('The session ended without a stated reason'),

	INVALID_OPTIONS: _('pppd rejected an option: check the endpoint discriminator and bundle name'),

	MLPPP_UNSUPPORTED: _('pppd was built without Multilink PPP; install the ppp-multilink package in place of ppp'),
	MLPPP_CONFIG_FILE_CONFLICT: _('A custom configuration file names one server, so it cannot be combined with additional servers'),
	MLPPP_DATASTREAMS_CONFLICT: _('Data streams cannot be combined with additional servers: reliable streams stall multilink reassembly instead of protecting it'),
	/* Written by the supervisor rather than by netifd: pppd announces the refusal
	 * on its own stdout one line after a successful authentication, so it reaches
	 * nothing that netifd can see. */
	MLPPP_JOIN_REFUSED: _('pppd authenticated and was then refused by the bundle; install the ppp-multilink package in place of ppp'),

	OBFS_TYPE_INVALID: _('Unknown obfuscation type: use salamander or gecko'),
	OBFS_PASSWORD_MISSING: _('Obfuscation is enabled but no obfuscation password is set'),
	OBFS_WITH_CAMOUFLAGE: _('Obfuscation cannot be combined with camouflage, which needs the QUIC header that obfuscation hides'),
	CAMOUFLAGE_SERVER_IP_MULTILINK: _('A camouflage server IP names one concentrator and cannot be set alongside additional servers; leave it empty so each link takes the address it dials')
};

/* One word per link state, matching the vocabulary the collector emits. Anything
 * outside it is reported as unknown rather than guessed into one of these. */
var STATES = {
	carrying: _('In bundle'),
	connected: _('Connected'),
	dialling: _('Connecting'),
	refused: _('Refused by bundle'),
	retrying: _('Retrying'),
	blocked: _('Stopped'),
	idle: _('Idle')
};

/* "connected" alone, where there is a bundle for the link to be in.
 *
 * The collector emits one state for two situations that a reader has no way to
 * tell apart from the word: a single-server interface, where a working transport
 * is the entire story, and a member of a formed bundle whose join was never
 * confirmed, where it is half of it. Kept out of STATES above rather than folded
 * into it, because the single-server case must keep reading as the plain success
 * it is. */
var CONNECTED_IN_BUNDLE = _('Connected, join unconfirmed');

/* Which of the three colours a state gets. Kept apart from the label because the
 * status page and the compact line want the same judgement in different forms. */
var SEVERITY = {
	carrying: 'ok',
	connected: 'ok',
	dialling: 'busy',
	refused: 'bad',
	retrying: 'bad',
	blocked: 'bad',
	idle: 'idle'
};

var cache = {},
    started = false,
    disabled = false,
    failures = 0;

function index(list) {
	var rv = {};
	for (var i = 0; i < (list || []).length; i++)
		if (L.isObject(list[i]) && list[i]['interface'])
			rv[list[i]['interface']] = list[i];
	return rv;
}

function refresh() {
	return callStatus().then(function(list) {
		failures = 0;
		cache = index(list);
		return cache;
	}, function() {
		/* An older hysteria2-ppp has no such ubus object, and this module is
		 * loaded on every page that touches the network configuration. Left to
		 * retry it would call into a void every five seconds for the lifetime of
		 * the session. Three failures is enough to tell "not installed" from a
		 * request that lost a race with a restarting rpcd. */
		cache = {};
		if (++failures >= 3 && started) {
			poll.remove(refresh);
			started = false;
			disabled = true;
		}
		return cache;
	});
}

function start() {
	if (started || disabled)
		return;
	started = true;
	poll.add(refresh, 5);
}

return baseclass.extend({
	REASONS: REASONS,

	/* The sentence for a reason code, or the code itself when it is one this
	 * version does not know. Showing the bare code beats showing nothing: it is
	 * still greppable, and a package pair that has drifted is not a reason to
	 * withhold the only fact available. */
	reasonText: function(code) {
		if (!code)
			return null;
		return REASONS[code] || _('Unrecognised failure (%s)').format(code);
	},

	/* The label for a link state. "bundled" says whether this interface has a
	 * bundle for the link to be in, which is the one piece of context the state
	 * word does not carry: without a bundle "connected" is the whole truth, with
	 * one it leaves out the only thing the reader is asking. Optional, so a
	 * caller with no interface in hand still gets the plain vocabulary. */
	stateText: function(state, bundled) {
		if (bundled && state == 'connected')
			return CONNECTED_IN_BUNDLE;
		return STATES[state] || _('Unknown');
	},

	/* Amber for the same case, and for the same reason the label changes: green
	 * beside "In bundle" green says the two links are equally well understood,
	 * and one of them is not understood at all. Not red -- nothing is known to
	 * have failed, and an unsettled verdict is not a fault. */
	severity: function(state, bundled) {
		if (bundled && state == 'connected')
			return 'busy';
		return SEVERITY[state] || 'idle';
	},

	/* The live status of one interface, or null when there is none to be had.
	 *
	 * Synchronous on purpose. Its callers are getI18n and getErrors, which LuCI
	 * calls while building the interface status box and cannot await; the poll
	 * started here fills the cache, and LuCI re-runs that box every five seconds
	 * of its own accord, so the line appears one tick after the page and stays
	 * current without this module rendering anything itself.
	 *
	 * Starting the poll from the first live call is what keeps it off routers
	 * that have no Hysteria interface: protocol classes are loaded on every page
	 * that touches the network, and the protocol dropdown instantiates every one
	 * of them with a placeholder name. */
	statusOf: function(proto) {
		if (!proto || !proto.sid || proto.sid == '__dummy__')
			return null;
		start();
		if (typeof proto.isUp == 'function' && !proto.isUp())
			return null;
		return cache[proto.sid] || null;
	},

	/* A fresh answer for a page that wants to render immediately rather than on
	 * the next tick. */
	fetch: function() {
		start();
		return refresh();
	},

	/* How many links are confirmed in the bundle, how many are up without that
	 * having been settled, and the total of the two.
	 *
	 * Here rather than in the status page because links_up -- which is the only
	 * count the collector publishes -- is the sum, and both surfaces were reading
	 * it as though it were the first. That is the drift this module exists to
	 * stop: the interface list said "3 of 3 servers" while the status page said
	 * one of them was unconfirmed, about the same router, in the same second.
	 *
	 * Derived from the links array rather than from a new collector field, so it
	 * is right against every hysteria2-ppp that has ever shipped this object:
	 * links_up is carrying + connected by construction, so counting the states
	 * back out cannot disagree with it. */
	tally: function(st) {
		var links = (st && st.links) || [], i,
		    rv = { carrying: 0, unconfirmed: 0, up: 0 };

		for (i = 0; i < links.length; i++) {
			if (links[i].state == 'carrying')
				rv.carrying++;
			else if (links[i].state == 'connected')
				rv.unconfirmed++;
		}

		rv.up = rv.carrying + rv.unconfirmed;
		return rv;
	},

	/* What is wrong with this interface, as sentences, or an empty list when the
	 * answer is "nothing".
	 *
	 * Capped, and the cap is not cosmetic: this goes into the interface status
	 * box beside Uptime and RX, and a sixteen-server bundle whose LNS has gone
	 * away would otherwise push every other interface on the page off the screen.
	 * The status page is where the full list belongs. */
	problems: function(st, limit) {
		var rv = [], links = st.links || [], i, l;

		if (st.bundle_state == 'refused')
			rv.push(_('The server did not accept Multilink PPP, so this is a single link; the other %d servers stay idle.').format(Math.max(0, st.links_configured - 1)));

		for (i = 0; i < links.length; i++) {
			l = links[i];
			if (!L.isObject(l) || l.state == 'carrying' || l.state == 'connected')
				continue;

			var name = l.server || _('server %d').format(l.slot),
			    code = (l.last_error || {}).code;

			if (l.state == 'refused')
				rv.push('%s: %s'.format(name, REASONS.MLPPP_JOIN_REFUSED));
			else if (code)
				rv.push(_('%s is not connected — %s').format(name, this.reasonText(code)));
			else if (st.bundle_state != 'down')
				rv.push(_('%s is not connected').format(name));
		}

		limit = limit || 3;
		if (rv.length > limit)
			rv = rv.slice(0, limit).concat([
				_('%d more link problems; see Status → Hysteria 2 Links.').format(rv.length - limit)
			]);

		return rv;
	}
});
