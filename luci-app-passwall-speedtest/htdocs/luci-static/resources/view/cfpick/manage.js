'use strict';
'require view';
'require poll';
'require rpc';
'require ui';

const callStatus = rpc.declare({
	object: 'cfpick',
	method: 'api_status',
	expect: {}
});

const callResults = rpc.declare({
	object: 'cfpick',
	method: 'api_results',
	params: [ 'limit' ],
	expect: {}
});

const callHistory = rpc.declare({
	object: 'cfpick',
	method: 'api_history',
	expect: {}
});

const callTasks = rpc.declare({
	object: 'cfpick',
	method: 'api_tasks',
	expect: {}
});

const callLog = rpc.declare({
	object: 'cfpick',
	method: 'api_log',
	params: [ 'pos' ],
	expect: {}
});

const callStart = rpc.declare({
	object: 'cfpick',
	method: 'api_run_start',
	expect: {}
});

const callRetest = rpc.declare({
	object: 'cfpick',
	method: 'api_run_retest',
	expect: {}
});

const callStop = rpc.declare({
	object: 'cfpick',
	method: 'api_run_stop',
	expect: {}
});

function pick(result, errors) {
	if (result && result.ok === true)
		return result.data || {};

	const message = (result && result.error) || _('Request failed');

	if (errors.indexOf(message) < 0)
		errors.push(message);

	return {};
}

function fmtNumber(value, digits) {
	const number = Number(value);

	if (!Number.isFinite(number))
		return '—';

	return number.toFixed(digits == null ? 2 : digits);
}

function fmtDuration(seconds) {
	const total = Math.max(0, Math.floor(Number(seconds) || 0));
	const hours = Math.floor(total / 3600);
	const minutes = Math.floor((total % 3600) / 60);
	const rest = total % 60;

	if (hours > 0)
		return '%dh %02dm %02ds'.format(hours, minutes, rest);
	if (minutes > 0)
		return '%dm %02ds'.format(minutes, rest);
	return '%ds'.format(rest);
}

function phaseLabel(phase) {
	switch (phase) {
	case 'starting':
		return _('Starting');
	case 'testing':
		return _('Testing');
	case 'stopping':
		return _('Stopping');
	case 'committing':
		return _('Writing results');
	case 'idle':
	default:
		return _('Idle');
	}
}

function button(label, className, handler) {
	const node = E('button', {
		type: 'button',
		'class': 'btn cbi-button ' + (className || '')
	}, label);

	node.addEventListener('click', handler);

	return node;
}

return view.extend({
	load: function() {
		return Promise.all([
			L.resolveDefault(callStatus(), null),
			L.resolveDefault(callResults(500), null),
			L.resolveDefault(callHistory(), null),
			L.resolveDefault(callTasks(), null)
		]);
	},

	render: function(data) {
		const errors = [];
		const status = pick(data[0], errors);
		const results = pick(data[1], errors);
		const history = pick(data[2], errors);
		const tasks = pick(data[3], errors);

		this.logPos = 0;
		this.lastRunning = !!status.running;
		this.pollCount = 0;

		const statusBox = E('div');
		const resultBody = E('tbody');
		const historyBody = E('tbody');
		const taskBody = E('tbody');
		const logView = E('textarea', {
			'class': 'cbi-input-textarea',
			style: 'width:100%;font-family:monospace;font-size:12px',
			rows: 24,
			readonly: 'readonly'
		});
		const logFollow = E('input', { type: 'checkbox', checked: 'checked' });

		const startButton = button(_('Start'), 'cbi-button-apply',
			L.bind(this.runAction, this, callStart, _('Test started')));
		const stopButton = button(_('Stop'), 'cbi-button-reset',
			L.bind(this.runAction, this, callStop, _('Stop requested')));
		const retestButton = button(_('Retest'), 'cbi-button-action',
			L.bind(this.runAction, this, callRetest, _('Retest started')));

		this.buttons = {
			start: startButton,
			stop: stopButton,
			retest: retestButton
		};
		this.statusBox = statusBox;

		const root = E([], [
			E('h2', {}, _('Management')),
			E('p', { 'class': 'cbi-section-descr' },
				_('Dashboard for the PassWall Cloudflare IP speed test: run state, best results, history, scheduled tasks and the live log.')),

			errors.length ? E('div', { 'class': 'alert-message warning' },
				errors.map((message) => E('p', {}, message))) : E([]),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Run status')),
				statusBox,
				E('div', { 'class': 'cbi-page-actions' }, [
					startButton, ' ', retestButton, ' ', stopButton
				])
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Best IPs')),
				E('table', { 'class': 'table' }, [
					E('thead', {}, [
						E('tr', {}, [
							E('th', {}, _('Node')),
							E('th', {}, _('IP')),
							E('th', {}, _('Latency')),
							E('th', {}, _('Loss')),
							E('th', {}, _('Download')),
							E('th', {}, _('Region'))
						])
					]),
					resultBody
				])
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('History')),
				E('table', { 'class': 'table' }, [
					E('thead', {}, [
						E('tr', {}, [
							E('th', {}, _('Time')),
							E('th', {}, _('Best IP')),
							E('th', {}, _('Latency')),
							E('th', {}, _('Download')),
							E('th', {}, _('Region'))
						])
					]),
					historyBody
				])
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Scheduled tasks')),
				E('table', { 'class': 'table' }, [
					E('thead', {}, [
						E('tr', {}, [
							E('th', {}, _('Source')),
							E('th', {}, _('Schedule')),
							E('th', {}, _('Command')),
							E('th', {}, _('Managed'))
						])
					]),
					taskBody
				])
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Live log')),
				E('label', {}, [ logFollow, ' ', _('Auto refresh') ]),
				E('br'),
				logView
			])
		]);

		this.renderStatus(statusBox, status);
		this.renderResults(resultBody, results);
		this.renderHistory(historyBody, history);
		this.renderTasks(taskBody, tasks);
		this.fetchLog(logView, false);

		poll.add(L.bind(function() {
			return this.poll(statusBox, resultBody, historyBody, logView, logFollow);
		}, this), 3);

		return root;
	},

	renderStatus: function(node, status) {
		const best = status.best;
		const running = !!status.running;

		node.replaceChildren(
			E('table', { 'class': 'table' }, [
				E('tr', {}, [
					E('th', {}, _('State')),
					E('td', {}, running
						? _('Running') + ' · ' + phaseLabel(status.phase) + ' · ' + fmtDuration(status.elapsed)
						: _('Idle'))
				]),
				E('tr', {}, [
					E('th', {}, _('Process')),
					E('td', {}, running
						? 'PID ' + (status.pid || '?') + ' · ' + (status.mode || 'start')
						: '—')
				]),
				E('tr', {}, [
					E('th', {}, _('Scheduled task')),
					E('td', {}, status.cron ? _('Enabled') : _('Disabled'))
				]),
				E('tr', {}, [
					E('th', {}, _('Best IP')),
					E('td', {}, best
						? '%s · %s ms · %s MB/s · %s'.format(
							best.ip || '—',
							fmtNumber(best.latency),
							best.speed > 0 ? fmtNumber(best.speed) : '—',
							best.node || '—')
						: '—')
				]),
				E('tr', {}, [
					E('th', {}, _('Last result')),
					E('td', {}, status.last_time || '—')
				]),
				E('tr', {}, [
					E('th', {}, _('Configured workers')),
					E('td', {}, '%d · %d result rows'.format(
						status.node_count || 0, status.result_rows || 0))
				])
			])
		);

		if (this.buttons) {
			this.buttons.start.disabled = running;
			this.buttons.retest.disabled = running;
			this.buttons.stop.disabled = !running;
		}
	},

	renderResults: function(node, results) {
		const rows = results.rows || [];
		const total = results.total || rows.length;
		const seen = {};

		node.replaceChildren();

		if (!rows.length) {
			node.appendChild(E('tr', {}, [
				E('td', { colspan: 6 }, _('No results yet'))
			]));
			return;
		}

		rows.forEach((row) => {
			const best = !seen[row.node];
			seen[row.node] = true;

			node.appendChild(E('tr', { style: best ? 'font-weight:600' : '' }, [
				E('td', {}, row.node || ''),
				E('td', {}, row.ip || ''),
				E('td', {}, fmtNumber(row.latency) + ' ms'),
				E('td', {}, fmtNumber((row.loss || 0) * 100) + '%'),
				E('td', {}, row.speed > 0 ? fmtNumber(row.speed) + ' MB/s' : '—'),
				E('td', {}, row.region || '')
			]));
		});

		if (total > rows.length) {
			node.appendChild(E('tr', {}, [
				E('td', { colspan: 6, style: 'text-align:center;color:#888' },
					_('Showing the first %d of %d rows').format(rows.length, total))
			]));
		}
	},

	renderHistory: function(node, history) {
		const runs = (history.history || []).slice(0, 12);

		node.replaceChildren();

		if (!runs.length) {
			node.appendChild(E('tr', {}, [
				E('td', { colspan: 5 }, _('No history yet'))
			]));
			return;
		}

		runs.forEach((run) => {
			node.appendChild(E('tr', {}, [
				E('td', {}, run.time || ''),
				E('td', {}, run.ip || ''),
				E('td', {}, fmtNumber(run.latency) + ' ms'),
				E('td', {}, run.speed > 0 ? fmtNumber(run.speed) + ' MB/s' : '—'),
				E('td', {}, run.region || '')
			]));
		});
	},

	renderTasks: function(node, tasks) {
		const entries = tasks.entries || [];

		node.replaceChildren();

		if (!entries.length) {
			node.appendChild(E('tr', {}, [
				E('td', { colspan: 4 }, _('No scheduled tasks'))
			]));
			return;
		}

		entries.forEach((entry) => {
			node.appendChild(E('tr', { style: entry.managed ? 'font-weight:600' : '' }, [
				E('td', {}, entry.source || ''),
				E('td', {}, entry.schedule || ''),
				E('td', { style: 'font-family:monospace;font-size:12px' }, entry.command || ''),
				E('td', {}, entry.managed ? _('This plugin') : '')
			]));
		});
	},

	fetchLog: function(textarea, append) {
		return callLog(this.logPos).then(L.bind(function(result) {
			if (!result || result.ok !== true)
				return;

			const data = result.data || {};
			const content = data.content || '';

			if (content != '') {
				textarea.value = ((append ? textarea.value : '') + content).slice(-524288);
				textarea.scrollTop = textarea.scrollHeight;
			}

			if (data.pos != null)
				this.logPos = parseInt(data.pos, 10) || this.logPos;
		}, this)).catch(function() {});
	},

	poll: function(statusBox, resultBody, historyBody, logView, logFollow) {
		return callStatus().then(L.bind(function(result) {
			if (!result || result.ok !== true)
				return;

			const status = result.data || {};
			const wasRunning = this.lastRunning;

			this.lastRunning = !!status.running;
			this.renderStatus(statusBox, status);

			if (wasRunning && !status.running) {
				callResults(500).then(L.bind(function(next) {
					if (next && next.ok === true)
						this.renderResults(resultBody, next.data || {});
				}, this));

				callHistory().then(L.bind(function(next) {
					if (next && next.ok === true)
						this.renderHistory(historyBody, next.data || {});
				}, this));
			}

			if (logFollow.checked) {
				this.pollCount = (this.pollCount || 0) + 1;

				// Status every 3s, log every other tick (~6s).
				if (this.pollCount % 2 === 0)
					this.fetchLog(logView, true);
			}
		}, this)).catch(function() {});
	},

	runAction: function(call, message) {
		return call().then(L.bind(function(result) {
			if (!result || result.ok !== true) {
				ui.addNotification(null, E('p', {},
					(result && result.error) || _('Request failed')));
				return;
			}

			ui.addNotification(null, E('p', {}, message));

			return callStatus().then(L.bind(function(next) {
				if (next && next.ok === true)
					this.renderStatus(this.statusBox, next.data || {});
			}, this));
		}, this)).catch(function(error) {
			ui.addNotification(null, E('p', {}, error.message || _('Request failed')));
		});
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
