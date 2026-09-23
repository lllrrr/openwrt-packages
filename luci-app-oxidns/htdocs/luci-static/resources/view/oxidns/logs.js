'use strict';
'require view';
'require rpc';
'require poll';

var callLogsRecent = rpc.declare({
	object: 'luci.oxidns',
	method: 'logs_recent',
	params: [ 'limit' ],
	expect: {}
});

var callLogsClear = rpc.declare({
	object: 'luci.oxidns',
	method: 'logs_clear',
	expect: {}
});

var state = {
	lines: [],
	pending: [],
	rawLines: [],
	paused: false,
	followTail: true,
	limit: 100,
	clearBaseline: null
};

function byId(id) {
	return document.getElementById(id);
}

/* ISO 8601 UTC 时间戳（…Z / +00:00）转 +08:00 显示，其余行原样保留 */
function localizeTimestamps(line) {
	return String(line).replace(
		/(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(\.\d+)?(?:Z|\+00:00)/g,
		function(match, y, mo, d, h, mi, s, frac) {
			var t = Date.UTC(+y, +mo - 1, +d, +h, +mi, +s) + 8 * 3600 * 1000;
			var dt = new Date(t);
			function pad(n) { return (n < 10 ? '0' : '') + n; }
			return dt.getUTCFullYear() + '-' + pad(dt.getUTCMonth() + 1) + '-' + pad(dt.getUTCDate()) +
				'T' + pad(dt.getUTCHours()) + ':' + pad(dt.getUTCMinutes()) + ':' + pad(dt.getUTCSeconds()) +
				(frac || '') + '+08:00';
		});
}

function normalizeLines(result) {
	var lines = result && result.lines;
	if (!Array.isArray(lines))
		return [];
	return lines.map(localizeTimestamps);
}

function trimClearedLines(lines) {
	var baseline = state.clearBaseline;
	var remove = 0;

	if (!baseline || !baseline.length)
		return lines;

	for (var i = Math.min(baseline.length, lines.length); i > 0; i--) {
		var match = true;

		for (var j = 0; j < i; j++) {
			if (baseline[baseline.length - i + j] !== lines[j]) {
				match = false;
				break;
			}
		}

		if (match) {
			remove = i;
			break;
		}
	}

	if (remove > 0)
		return lines.slice(remove);

	return lines;
}

function afterPaint(fn) {
	if (window.requestAnimationFrame)
		window.requestAnimationFrame(fn);
	else
		window.setTimeout(fn, 0);
}

function isNearBottom(node) {
	return node.scrollHeight - node.scrollTop - node.clientHeight < 24;
}

function scrollLogToBottom() {
	var log = byId('oxidns-log-lines');
	if (log)
		log.scrollTop = log.scrollHeight;
}

function renderLines() {
	var log = byId('oxidns-log-lines');
	if (!log)
		return;

	var shouldFollow = state.followTail || isNearBottom(log);
	log.textContent = state.lines.join('\n');

	if (shouldFollow) {
		state.followTail = true;
		afterPaint(scrollLogToBottom);
	}
}

function updatePauseButton() {
	var button = byId('oxidns-log-pause-toggle');
	if (!button)
		return;

	button.textContent = state.paused ? _('Resume') : _('Pause');
	button.className = 'btn cbi-button cbi-button-%s'.format(state.paused ? 'positive' : 'neutral');
}

function refreshLogs() {
	return L.resolveDefault(callLogsRecent(state.limit), null).then(function(result) {
		if (!result || result.ok === false)
			return;

		state.rawLines = normalizeLines(result);

		var lines = trimClearedLines(state.rawLines);

		if (state.paused)
			state.pending = lines;
		else
			state.lines = lines;

		renderLines();
	});
}

function setPaused(paused) {
	state.paused = paused;
	if (!paused && state.pending.length) {
		state.lines = state.pending;
		state.pending = [];
	}
	updatePauseButton();
	renderLines();
}

function togglePaused() {
	return setPaused(!state.paused);
}

function clearLogs() {
	return L.resolveDefault(callLogsClear(), null).then(function(result) {
		if (result && result.ok === false)
			return;

		var currentLines = state.paused && state.pending.length
			? state.pending.slice()
			: state.lines.slice();
		var baseline = state.rawLines.length
			? state.rawLines.slice()
			: currentLines;

		if (baseline.length)
			state.clearBaseline = baseline;

		state.lines = [];
		state.pending = [];
		state.followTail = true;
		renderLines();
	});
}

function controlButton(label, handler, style) {
	return E('button', {
		'class': 'btn cbi-button cbi-button-%s'.format(style || 'neutral'),
		'click': function(ev) {
			ev.preventDefault();
			return handler();
		}
	}, label);
}

return view.extend({
	load: function() {
		return Promise.resolve({
			ok: true,
			source: 'file',
			lines: []
		});
	},

	render: function(initial) {
		state.lines = normalizeLines(initial);
		state.pending = [];
		state.rawLines = state.lines.slice();
		state.paused = false;
		state.followTail = true;
		state.clearBaseline = null;
		window.setTimeout(refreshLogs, 0);
		poll.add(refreshLogs, 1);

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('OxiDNS Logs')),
			E('div', { 'class': 'cbi-map-descr' },
				_('View the OxiDNS log file configured in config.yaml (log.file). Timestamps are shown in UTC+8. Clearing truncates the log file on the device.')),
			E('div', { 'class': 'cbi-section' }, [
				E('div', {
					'class': 'cbi-button-row',
					'style': 'display: flex; flex-wrap: wrap; gap: .5em; margin-bottom: 1.5em;'
				}, [
					E('button', {
						'id': 'oxidns-log-pause-toggle',
						'class': 'btn cbi-button cbi-button-neutral',
						'click': function(ev) {
							ev.preventDefault();
							return togglePaused();
						}
					}, _('Pause')),
					controlButton(_('Refresh'), refreshLogs, 'action'),
					controlButton(_('Clear'), clearLogs, 'negative')
				]),
				E('pre', {
					'id': 'oxidns-log-lines',
					'scroll': function(ev) {
						state.followTail = isNearBottom(ev.target);
					},
					'style': 'min-height: 560px; max-height: 72vh; overflow: auto; margin-top: .25em; padding: 1em; background: #111; color: #ddd; white-space: pre-wrap; overflow-wrap: anywhere;'
				}, state.lines.join('\n'))
			])
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
