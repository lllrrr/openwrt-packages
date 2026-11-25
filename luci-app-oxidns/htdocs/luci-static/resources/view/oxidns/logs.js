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

var BACKEND_ERRORS = {
	log_read_failed: _('The system log could not be read.'),
	rpc_unavailable: _('The LuCI backend is unavailable.')
};

var state = {
	lines: [],
	pending: [],
	rawLines: [],
	renderedLines: [],
	renderedSig: '',
	paused: false,
	followTail: true,
	limit: 100,
	clearBaseline: null,
	clearCursor: 0,
	inFlight: false,
	filters: {
		keyword: '',
		plugin: '',
		qtype: '',
		rcode: ''
	}
};

var FILTER_FIELDS = [ 'plugin', 'qtype', 'rcode' ];

var FIELD_RES = {
	plugin: /(?:^|\s)plugin=(\S+)/,
	qtype: /(?:^|\s)qtype=(\S+)/,
	rcode: /(?:^|\s)rcode=(\S+)/
};

var viewRoot = null;
var pollFn = null;
var viewObserver = null;
var cleanupTasks = [];
var retryTimer = null;
var retryCount = 0;

function isAttached(node) {
	return !!(node && document.body && typeof document.body.contains === 'function' && document.body.contains(node));
}

function addCleanup(fn) {
	if (typeof fn === 'function' && cleanupTasks.indexOf(fn) < 0)
		cleanupTasks.push(fn);
}

function runCleanup() {
	var tasks = cleanupTasks.slice();
	cleanupTasks = [];

	for (var i = 0; i < tasks.length; i++) {
		try { tasks[i](); } catch (e) {}
	}
}

function watchView(root) {
	viewRoot = root || null;

	if (viewObserver) {
		try { viewObserver.disconnect(); } catch (e) {}
		viewObserver = null;
	}

	var vp = document.getElementById('view');
	if (!vp || typeof MutationObserver !== 'function')
		return;

	viewObserver = new MutationObserver(function() {
		if (viewRoot && !isAttached(viewRoot)) {
			try { viewObserver.disconnect(); } catch (e) {}
			viewObserver = null;
			runCleanup();
		}
	});
	viewObserver.observe(vp, { childList: true, subtree: false });
}

function unregisterPoll() {
	if (pollFn && typeof poll.remove === 'function')
		poll.remove(pollFn);
	pollFn = null;
}

function cancelRetry() {
	if (retryTimer !== null) {
		window.clearTimeout(retryTimer);
		retryTimer = null;
	}
	retryCount = 0;
}

function backendMessage(err, fallback) {
	var code = err && err.code;
	if (code && BACKEND_ERRORS[code])
		return BACKEND_ERRORS[code];
	return fallback || _('Operation failed');
}

function showError(message) {
	var node = byId('oxidns-log-error');
	if (!node)
		return;
	node.textContent = message || '';
	node.style.display = message ? 'block' : 'none';
}

function scheduleRetry() {
	cancelRetry();
	if (retryCount >= 4) {
		showError(_('Could not refresh logs. Use Refresh to try again.'));
		return;
	}

	retryCount++;
	showError(_('Could not refresh logs. Retrying...'));
	retryTimer = window.setTimeout(function() {
		retryTimer = null;
		if (isAttached(viewRoot))
			refreshLogs();
	}, Math.min(30000, 1000 * Math.pow(2, retryCount)));
}

function byId(id) {
	return document.getElementById(id);
}

function normalizeLines(result) {
	var lines = result && result.lines;
	return Array.isArray(lines) ? lines : [];
}

function extractField(line, field) {
	var match = FIELD_RES[field].exec(line);
	return match ? match[1] : null;
}

function distinctValues(lines, field) {
	var seen = {};
	var values = [];

	for (var i = 0; i < lines.length; i++) {
		var value = extractField(lines[i], field);
		if (value && !seen[value]) {
			seen[value] = true;
			values.push(value);
		}
	}

	return values.sort();
}

function applyFilters(lines) {
	var f = state.filters;
	var keyword = f.keyword.toLowerCase();

	if (!keyword && !f.plugin && !f.qtype && !f.rcode)
		return lines;

	var filtered = [];

	for (var i = 0; i < lines.length; i++) {
		var line = lines[i];
		var keep = true;

		if (keyword && line.toLowerCase().indexOf(keyword) < 0)
			keep = false;

		for (var j = 0; keep && j < FILTER_FIELDS.length; j++) {
			var field = FILTER_FIELDS[j];
			var want = f[field];

			if (want && extractField(line, field) !== want)
				keep = false;
		}

		if (keep)
			filtered.push(line);
	}

	return filtered;
}

/*
 * 以前每次都用 baseline 的每个后缀去比对日志前缀，是 O(n^2)。
 * 现在只保留一个游标：logread 的旧行始终在窗口前部，新行追加在后面，
 * 所以从左到右推进游标即可，单轮 O(n)。
 */
function trimClearedLines(lines) {
	var baseline = state.clearBaseline;
	if (!baseline || !baseline.length)
		return lines;

	var cursor = state.clearCursor || 0;
	var i = 0;

	while (cursor < baseline.length && i < lines.length && baseline[cursor] === lines[i]) {
		cursor++;
		i++;
	}

	state.clearCursor = cursor;

	if (cursor >= baseline.length) {
		state.clearBaseline = null;
		state.clearCursor = 0;
	}
	else if (i === 0) {
		/* 日志轮转 / 清空后 baseline 不再出现在窗口里，直接丢弃 */
		state.clearBaseline = null;
		state.clearCursor = 0;
	}

	return i ? lines.slice(i) : lines;
}

/* 后端每次返回最新 N 行：找出与旧窗口重叠的部分，只追加真正新增的行 */
function mergeRecentLines(prev, next) {
	if (!prev.length || !next.length)
		return (next.length ? next : prev).slice(-state.limit);

	var first = next[0];
	var start = -1;

	for (var i = prev.length - 1; i >= 0 && i >= prev.length - state.limit; i--) {
		if (prev[i] === first) {
			start = i;
			break;
		}
	}

	if (start < 0)
		return next.slice(-state.limit);

	var k = 1;
	while (start + k < prev.length && k < next.length && prev[start + k] === next[k])
		k++;

	return prev.slice(0, start + k).concat(next.slice(k)).slice(-state.limit);
}

function isPrefix(prefix, values) {
	if (prefix.length > values.length)
		return false;

	for (var i = 0; i < prefix.length; i++)
		if (prefix[i] !== values[i])
			return false;

	return true;
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

function updateFilterSummary(visible) {
	var node = byId('oxidns-log-filter-summary');
	if (!node)
		return;

	var total = state.lines.length;
	var shown = visible.length;

	if (shown === total)
		node.textContent = _('%d lines').format(total);
	else
		node.textContent = _('%d of %d lines').format(shown, total);
}

function renderLines(force) {
	var log = byId('oxidns-log-lines');
	if (!log)
		return;

	var visible = applyFilters(state.lines);
	var sig = visible.join('\n') + '\u0000' + JSON.stringify(state.filters);

	if (!force && sig === state.renderedSig)
		return;

	var shouldFollow = state.followTail || isNearBottom(log);

	/* 大部分刷新只是末尾追加几行：只追加文本节点，不重建整块日志 */
	if (!force && state.renderedLines.length && visible.length > state.renderedLines.length &&
	    isPrefix(state.renderedLines, visible)) {
		for (var i = state.renderedLines.length; i < visible.length; i++)
			log.appendChild(document.createTextNode((i ? '\n' : '') + visible[i]));
	}
	else {
		while (log.firstChild)
			log.removeChild(log.firstChild);
		log.textContent = visible.join('\n');
	}

	state.renderedLines = visible.slice();
	state.renderedSig = sig;
	updateFilterSummary(visible);

	if (shouldFollow) {
		state.followTail = true;
		afterPaint(scrollLogToBottom);
	}
}

/* 只追加新出现的选项，不删已有项，避免过滤下拉框每秒抖动 */
function updateFilterOptions() {
	for (var i = 0; i < FILTER_FIELDS.length; i++) {
		var field = FILTER_FIELDS[i];
		var select = byId('oxidns-log-filter-' + field);
		if (!select)
			continue;

		var values = distinctValues(state.lines, field);
		var existing = {};

		for (var j = 0; j < select.options.length; j++)
			existing[select.options[j].value] = true;

		for (var k = 0; k < values.length; k++) {
			if (!existing[values[k]]) {
				select.appendChild(E('option', { 'value': values[k] }, values[k]));
				existing[values[k]] = true;
			}
		}

		if (state.filters[field] && !existing[state.filters[field]])
			state.filters[field] = '';

		select.value = state.filters[field];
	}
}

function refreshLogs() {
	if (!isAttached(viewRoot)) {
		unregisterPoll();
		return Promise.resolve();
	}

	if (state.inFlight)
		return Promise.resolve();

	state.inFlight = true;

	return Promise.resolve(callLogsRecent(state.limit)).then(function(result) {
		state.inFlight = false;

		if (!result || result.ok === false)
			throw result || { code: 'rpc_unavailable' };

		/* 保留最后一次成功读取的内容，错误时不把日志清空 */
		state.rawLines = mergeRecentLines(state.rawLines, normalizeLines(result));
		var lines = trimClearedLines(state.rawLines);

		if (state.paused)
			state.pending = lines;
		else
			state.lines = lines;

		cancelRetry();
		showError('');
		updateFilterOptions();
		renderLines();
	}).catch(function(err) {
		state.inFlight = false;
		showError(backendMessage(err, _('Could not refresh logs.')));
		scheduleRetry();
		console.warn('oxidns logs refresh:', err);
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
	var currentLines = state.paused && state.pending.length
		? state.pending.slice()
		: state.lines.slice();
	var baseline = state.rawLines.length
		? state.rawLines.slice()
		: currentLines;

	if (baseline.length) {
		state.clearBaseline = baseline;
		state.clearCursor = 0;
	}

	state.lines = [];
	state.pending = [];
	state.followTail = true;
	state.renderedLines = [];
	state.renderedSig = '';
	renderLines(true);
}

function resetFilters() {
	state.filters = { keyword: '', plugin: '', qtype: '', rcode: '' };

	var keyword = byId('oxidns-log-filter-keyword');
	if (keyword)
		keyword.value = '';

	for (var i = 0; i < FILTER_FIELDS.length; i++) {
		var select = byId('oxidns-log-filter-' + FILTER_FIELDS[i]);
		if (select)
			select.value = '';
	}

	renderLines(true);
}

function updatePauseButton() {
	var button = byId('oxidns-log-pause-toggle');
	if (!button)
		return;

	button.textContent = state.paused ? _('Resume') : _('Pause');
	button.className = 'btn cbi-button cbi-button-%s'.format(state.paused ? 'positive' : 'neutral');
}

function controlButton(label, handler, style) {
	return E('button', {
		'type': 'button',
		'class': 'btn cbi-button cbi-button-%s'.format(style || 'neutral'),
		'click': function(ev) {
			ev.preventDefault();
			return handler();
		}
	}, label);
}

function filterLabel(text) {
	return E('span', {
		'style': 'align-self: center; color: #888; font-size: 12px; white-space: nowrap;'
	}, text);
}

function filterBar() {
	var keywordInput = E('input', {
		'id': 'oxidns-log-filter-keyword',
		'class': 'cbi-input-text',
		'type': 'text',
		'placeholder': _('Keyword (qname, domain, text...)'),
		'style': 'flex: 1 1 220px; min-width: 180px;',
		'input': function(ev) {
			state.filters.keyword = ev.target.value;
			renderLines();
		}
	});

	var bar = E('div', {
		'style': 'display: flex; flex-wrap: wrap; gap: .5em; margin-bottom: .75em;'
	}, [ keywordInput ]);

	var fieldLabels = {
		plugin: _('Plugin'),
		qtype: _('QType'),
		rcode: _('RCode')
	};

	for (var i = 0; i < FILTER_FIELDS.length; i++) {
		(function(field) {
			bar.appendChild(filterLabel(fieldLabels[field]));
			bar.appendChild(E('select', {
				'id': 'oxidns-log-filter-' + field,
				'class': 'cbi-input-select',
				'style': 'max-width: 180px;',
				'change': function(ev) {
					state.filters[field] = ev.target.value;
					renderLines();
				}
			}, E('option', { 'value': '' }, _('All'))));
		})(FILTER_FIELDS[i]);
	}

	bar.appendChild(controlButton(_('Reset'), resetFilters, 'neutral'));

	return bar;
}

return view.extend({
	load: function() {
		return Promise.resolve({
			ok: true,
			source: _('logread'),
			lines: []
		});
	},

	render: function(initial) {
		state.lines = normalizeLines(initial);
		state.pending = [];
		state.rawLines = state.lines.slice();
		state.renderedLines = [];
		state.renderedSig = '';
		state.paused = false;
		state.followTail = true;
		state.clearBaseline = null;
		state.clearCursor = 0;
		state.inFlight = false;
		state.filters = { keyword: '', plugin: '', qtype: '', rcode: '' };

		addCleanup(unregisterPoll);
		addCleanup(cancelRetry);

		var map = E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('OxiDNS Logs')),
			E('div', { 'class': 'cbi-map-descr' },
				_('View recent OxiDNS entries from OpenWrt logread. Use the filters to narrow down entries by keyword, plugin, query type or response code.')),
			E('div', { 'class': 'cbi-section' }, [
				E('div', {
					'class': 'cbi-button-row',
					'style': 'display: flex; flex-wrap: wrap; gap: .5em; margin-bottom: 1em;'
				}, [
					E('button', {
						'id': 'oxidns-log-pause-toggle',
						'type': 'button',
						'class': 'btn cbi-button cbi-button-neutral',
						'click': function(ev) {
							ev.preventDefault();
							return togglePaused();
						}
					}, _('Pause')),
					controlButton(_('Refresh'), refreshLogs, 'action'),
					controlButton(_('Clear'), clearLogs, 'negative'),
					E('span', {
						'id': 'oxidns-log-filter-summary',
						'aria-live': 'polite',
						'style': 'align-self: center; margin-left: auto; color: #888; font-size: 12px;'
					}, '')
				]),
				E('div', {
					'id': 'oxidns-log-error',
					'class': 'alert-message error',
					'aria-live': 'polite',
					'style': 'margin-bottom: .75em; display: none;'
				}),
				filterBar(),
				E('pre', {
					'id': 'oxidns-log-lines',
					'aria-label': _('OxiDNS log output'),
					'role': 'log',
					'scroll': function(ev) {
						state.followTail = isNearBottom(ev.target);
					},
					'style': 'min-height: 560px; max-height: 72vh; overflow: auto; margin-top: .25em; padding: 1em; background: #111; color: #ddd; white-space: pre-wrap; overflow-wrap: anywhere;'
				}, state.lines.join('\n'))
			])
		]);

		watchView(map);

		pollFn = refreshLogs;
		poll.add(pollFn, 1);
		window.setTimeout(function() {
			if (isAttached(viewRoot))
				refreshLogs();
		}, 0);

		return map;
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
