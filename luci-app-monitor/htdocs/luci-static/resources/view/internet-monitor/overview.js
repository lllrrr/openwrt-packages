'use strict';
'require view';
'require rpc';
'require poll';
'require ui';
'require dom';

var callGetStatus = rpc.declare({
	object: 'luci.internet-monitor',
	method: 'getStatus',
	expect: { '': {} },
	reject: true
});

var callGetHistory = rpc.declare({
	object: 'luci.internet-monitor',
	method: 'getHistory',
	params: [ 'hours' ],
	expect: { '': { points: [], incidents: [] } },
	reject: true
});

var callRunProbe = rpc.declare({
	object: 'luci.internet-monitor',
	method: 'runProbe',
	expect: { '': { ok: false, message: '' } },
	reject: true
});

var callClearHistory = rpc.declare({
	object: 'luci.internet-monitor',
	method: 'clearHistory',
	expect: { '': { ok: false, message: '' } },
	reject: true
});

function ensureStylesheet() {
	var id = 'internet-monitor-stylesheet';
	var head = document.head || document.querySelector('head');

	if (head && !document.getElementById(id))
		head.appendChild(E('link', {
			'id': id,
			'rel': 'stylesheet',
			'type': 'text/css',
			'href': L.resource('internet-monitor/internet-monitor.css')
		}));
}

function settled(promise) {
	return promise.then(function(value) {
		return { value: value };
	}, function(error) {
		return { error: error };
	});
}

function getErrorMessage(error) {
	if (error == null)
		return _('Unknown RPC error');

	if (error.message)
		return error.message;

	return String(error);
}

function toTimestamp(value) {
	var number;
	var parsed;

	if (value == null || value === '')
		return null;

	if (typeof(value) === 'number')
		number = value;
	else if (/^\d+(?:\.\d+)?$/.test(String(value)))
		number = Number(value);

	if (isFinite(number))
		return number < 100000000000 ? number * 1000 : number;

	parsed = Date.parse(value);
	return isNaN(parsed) ? null : parsed;
}

function formatDateTime(value) {
	var timestamp = toTimestamp(value);

	if (timestamp == null)
		return _('Unknown');

	return new Date(timestamp).toLocaleString();
}

function formatShortTime(value) {
	var timestamp = toTimestamp(value);

	if (timestamp == null)
		return _('Unknown');

	return new Date(timestamp).toLocaleTimeString([], {
		hour: '2-digit',
		minute: '2-digit'
	});
}

function formatDuration(value) {
	var seconds = Math.max(0, Math.round(Number(value)));
	var days;
	var hours;
	var minutes;

	if (!isFinite(seconds))
		return '—';

	if (seconds === 0)
		return _('0 min');

	if (seconds < 60)
		return _('< 1 min');

	days = Math.floor(seconds / 86400);
	hours = Math.floor((seconds % 86400) / 3600);
	minutes = Math.floor((seconds % 3600) / 60);

	if (days > 0)
		return hours > 0 ? _('%d d %d h').format(days, hours) : _('%d d').format(days);

	if (hours > 0)
		return minutes > 0 ? _('%d h %d min').format(hours, minutes) : _('%d h').format(hours);

	return _('%d min').format(minutes);
}

function formatLatency(value) {
	var latency = Number(value);

	if (!isFinite(latency) || latency < 0)
		return '—';

	return _('%d ms').format(Math.round(latency));
}

function formatAvailability(value) {
	var availability;
	var decimals;

	if (value == null || value === '')
		return '—';

	availability = Number(String(value).replace('%', ''));
	if (!isFinite(availability))
		return '—';

	availability = Math.max(0, Math.min(100, availability));
	decimals = availability === 100 || availability === 0 ? 0 :
		(availability >= 99 ? 3 : (availability >= 90 ? 2 : 1));

	return availability.toFixed(decimals) + '%';
}

function flagIsFalse(value) {
	return value === false || value === 0 || value === '0' || value === 'false';
}

function canonicalState(value) {
	var state = String(value == null ? '' : value).toLowerCase();

	if (value === true || /^(up|ok|online|healthy|operational|success|available)$/.test(state))
		return 'operational';

	if (/^(degraded|warning|warn|partial|unstable)$/.test(state))
		return 'degraded';

	if (value === false || /^(down|offline|outage|critical|failed|failure|unavailable)$/.test(state))
		return 'outage';

	if (/^(disabled|inactive)$/.test(state))
		return 'disabled';

	return 'unknown';
}

function stateLabel(state) {
	switch (state) {
	case 'operational':
		return _('Operational');
	case 'degraded':
		return _('Degraded');
	case 'outage':
		return _('Outage');
	case 'disabled':
		return _('Disabled');
	default:
		return _('No data');
	}
}

function stateIcon(state) {
	switch (state) {
	case 'operational':
		return '✓';
	case 'degraded':
		return '!';
	case 'outage':
		return '×';
	case 'disabled':
		return '–';
	default:
		return '?';
	}
}

function statusPresentation(status) {
	var service = status && status.service || {};
	var state;

	if (!status)
		return {
			state: 'unknown',
			title: _('Internet status is unavailable'),
			description: _('The monitoring backend did not return a status response.')
		};

	if (status.snapshot_consistent === false)
		return {
			state: 'unknown',
			title: _('Connectivity status is updating'),
			description: _('A new probe result was being written. This page will retry automatically.')
		};

	if (flagIsFalse(service.enabled))
		return {
			state: 'disabled',
			title: _('Internet monitoring is disabled'),
			description: _('Enable the service in settings to resume connectivity checks.')
		};

	if (flagIsFalse(service.running))
		return {
			state: 'unknown',
			title: _('Monitoring service is stopped'),
			description: _('The service is enabled but is not currently running.')
		};

	state = canonicalState(status.state);

	if (state === 'operational')
		return {
			state: state,
			title: _('All systems operational'),
			description: _('The configured external connectivity checks are passing.')
		};

	if (state === 'degraded')
		return {
			state: state,
			title: _('External connectivity is degraded'),
			description: _('Only part of the configured connectivity checks are passing.')
		};

	if (state === 'outage')
		return {
			state: state,
			title: _('Internet connection interrupted'),
			description: _('The required number of external connectivity checks failed.')
		};

	return {
		state: 'unknown',
		title: _('Waiting for connectivity data'),
		description: _('No conclusive probe result is available yet.')
	};
}

function targetState(ok) {
	if (ok === true || ok === 1 || ok === '1')
		return 'operational';

	if (ok === false || ok === 0 || ok === '0')
		return 'outage';

	return 'unknown';
}

function targetStateLabel(state) {
	if (state === 'operational')
		return _('Reachable');

	if (state === 'outage')
		return _('Unreachable');

	return _('Unknown');
}

function targetTypeLabel(type) {
	switch (String(type || '').toLowerCase()) {
	case 'icmp':
		return _('ICMP');
	case 'http':
	case 'https':
		return _('HTTP');
	default:
		return type || _('Probe');
	}
}

function familyLabel(family) {
	switch (String(family || '').toLowerCase()) {
	case 'ipv4':
	case '4':
		return _('IPv4');
	case 'ipv6':
	case '6':
		return _('IPv6');
	case 'auto':
	case 'any':
	case '':
		return _('Auto');
	default:
		return family;
	}
}

function timelineBins(points, hours, count, generatedAt) {
	var end = toTimestamp(generatedAt);

	if (end == null)
		end = Date.now();

	var start = end - hours * 3600000;
	var width = (end - start) / count;
	var severity = { operational: 1, degraded: 2, unknown: 3, outage: 4 };
	var bins = [];

	for (var i = 0; i < count; i++)
		bins.push({
			state: 'unknown',
			observed: false,
			latency: null,
			start: start + i * width,
			end: start + (i + 1) * width
		});

	(points || []).forEach(function(point) {
		var timestamp = toTimestamp(point && point.timestamp);
		var state;
		var index;

		if (timestamp == null || timestamp < start || timestamp >= end)
			return;

		index = Math.min(count - 1, Math.floor((timestamp - start) / (end - start) * count));
		state = canonicalState(point.state);

		if (!bins[index].observed || severity[state] >= severity[bins[index].state]) {
			bins[index].state = state;
			bins[index].observed = true;
			bins[index].latency = point.latency_ms;
		}
	});

	return bins;
}

return view.extend({
	loadData: function() {
		return Promise.all([
			settled(callGetStatus()),
			settled(callGetHistory(24))
		]).then(function(results) {
			return {
				status: results[0].value || null,
				statusError: results[0].error || null,
				history: results[1].value || { points: [], incidents: [] },
				historyError: results[1].error || null
			};
		});
	},

	load: function() {
		return this.loadData();
	},

	notifyError: function(title, error) {
		ui.addNotification(title, E('p', {}, [ getErrorMessage(error) ]), 'danger');
	},

	handleRefresh: function(ev) {
		var button = ev.currentTarget;

		button.disabled = true;
		button.classList.add('spinning');

		return this.refresh().then(function() {
			button.disabled = false;
			button.classList.remove('spinning');
		}, function(error) {
			button.disabled = false;
			button.classList.remove('spinning');
			this.notifyError(_('Refresh failed'), error);
		}.bind(this));
	},

	handleProbe: function(ev) {
		var button = ev.currentTarget;
		var self = this;

		button.disabled = true;
		button.classList.add('spinning');

		return callRunProbe().then(function(result) {
			if (!result || result.ok === false)
				throw new Error(result && result.message || _('The probe could not be started.'));

			ui.addNotification(null, E('p', {}, [
				result.message || _('Connectivity probe completed.')
			]), 'info');

			return self.refresh();
		}).then(function() {
			button.disabled = false;
			button.classList.remove('spinning');
		}, function(error) {
			button.disabled = false;
			button.classList.remove('spinning');
			self.notifyError(_('Probe failed'), error);
		});
	},

	handleClearHistory: function() {
		var self = this;

		ui.showModal(_('Clear monitoring history'), [
			E('p', {}, [
				_('This permanently removes availability samples and recorded incidents. This action cannot be undone.')
			]),
			E('div', { 'class': 'right' }, [
				E('button', {
					'class': 'btn cbi-button',
					'type': 'button',
					'click': ui.hideModal
				}, [ _('Cancel') ]),
				' ',
				E('button', {
					'class': 'btn cbi-button cbi-button-negative important',
					'type': 'button',
					'click': function(ev) {
						var button = ev.currentTarget;

						button.disabled = true;
						button.classList.add('spinning');

						callClearHistory().then(function(result) {
							if (!result || result.ok === false)
								throw new Error(result && result.message || _('History could not be cleared.'));

							ui.hideModal();
							ui.addNotification(null, E('p', {}, [
								result.message || _('Monitoring history cleared.')
							]), 'info');
							return self.refresh();
						}).catch(function(error) {
							ui.hideModal();
							self.notifyError(_('Unable to clear history'), error);
						});
					}
				}, [ _('Clear history') ])
			])
		]);
	},

	refresh: function() {
		var self = this;
		var root = document.getElementById('internet-monitor-overview');

		if (!root || this._refreshing)
			return Promise.resolve();

		this._refreshing = true;

		return this.loadData().then(function(data) {
			var currentRoot = document.getElementById('internet-monitor-overview');

			if (currentRoot)
				dom.content(currentRoot, self.renderDashboard(data));
		}).then(function() {
			self._refreshing = false;
		}, function(error) {
			self._refreshing = false;
			return Promise.reject(error);
		});
	},

	renderHeader: function() {
		var actions = [
			E('button', {
				'class': 'cbi-button im-button',
				'type': 'button',
				'click': L.bind(this.handleRefresh, this)
			}, [ _('Refresh') ])
		];

		if (L.hasViewPermission())
			actions.push(E('button', {
				'class': 'cbi-button cbi-button-positive im-button',
				'type': 'button',
				'click': L.bind(this.handleProbe, this)
			}, [ _('Probe now') ]));

		actions.push(E('a', {
			'class': 'cbi-button cbi-button-action im-button',
			'href': L.url('admin', 'status', 'internet-monitor', 'settings')
		}, [ _('Settings') ]));

		if (L.hasViewPermission())
			actions.push(E('button', {
				'class': 'cbi-button cbi-button-negative im-button',
				'type': 'button',
				'click': L.bind(this.handleClearHistory, this)
			}, [ _('Clear history') ]));

		return E('div', { 'class': 'im-page-header' }, [
			E('div', { 'class': 'im-heading' }, [
				E('h2', {}, [ _('Internet Connectivity Monitor') ]),
				E('p', {}, [
					_('Independent ICMP and HTTP checks show whether this router can reach the public Internet.')
				])
			]),
			E('div', { 'class': 'im-actions' }, actions)
		]);
	},

	renderRpcError: function(error) {
		return E('div', {
			'class': 'im-error',
			'role': 'alert'
		}, [
			E('span', { 'class': 'im-error-icon', 'aria-hidden': 'true' }, [ '!' ]),
			E('div', {}, [
				E('strong', {}, [ _('Unable to read monitor status') ]),
				E('p', {}, [ getErrorMessage(error) ]),
				E('p', { 'class': 'im-error-hint' }, [
					_('Check that rpcd and the internet-monitor service are running, then refresh this page.')
				])
			])
		]);
	},

	renderStatusBanner: function(status) {
		var presentation = statusPresentation(status);
		var service = status && status.service || {};
		var summary = status && status.summary || {};
		var meta = [];
		var targetSummary;

		if (summary.total != null) {
			targetSummary = _('%d of %d targets reachable').format(
				Number(summary.success) || 0,
				Number(summary.total) || 0
			);
			meta.push(E('span', {}, [ targetSummary ]));
		}

		if (Number(summary.targets_truncated) > 0)
			meta.push(E('span', {}, [
				_('%d targets were not probed (limit %d)').format(
					Number(summary.targets_truncated),
					Number(summary.target_limit) || 64
				)
			]));

		if (summary.threshold != null)
			meta.push(E('span', {}, [ _('Required quorum: %d').format(Number(summary.threshold) || 0) ]));

		if (summary.latency_ms != null)
			meta.push(E('span', {}, [ _('Average latency: %s').format(formatLatency(summary.latency_ms)) ]));

		if (status && status.updated)
			meta.push(E('span', {}, [ _('Updated %s').format(formatDateTime(status.updated)) ]));

		if (service.version)
			meta.push(E('span', {}, [ _('Version %s').format(service.version) ]));

		return E('section', {
			'class': 'im-status-banner im-state-' + presentation.state,
			'aria-live': 'polite'
		}, [
			E('div', { 'class': 'im-status-icon', 'aria-hidden': 'true' }, [
				stateIcon(presentation.state)
			]),
			E('div', { 'class': 'im-status-copy' }, [
				E('div', { 'class': 'im-status-kicker' }, [ _('Current status') ]),
				E('h3', {}, [ presentation.title ]),
				E('p', {}, [ presentation.description ]),
				status && status.since ? E('p', { 'class': 'im-status-since' }, [
					_('Current state since %s').format(formatDateTime(status.since))
				]) : E([]),
				meta.length ? E('div', { 'class': 'im-status-meta' }, meta) : E([])
			])
		]);
	},

	renderAvailability: function(status) {
		var stats = status && status.stats || {};
		var periods = [
			{ key: '24h', label: _('Last 24 hours') },
			{ key: '7d', label: _('Last 7 days') },
			{ key: '30d', label: _('Last 30 days') }
		];

		return E('section', { 'class': 'im-section' }, [
			E('div', { 'class': 'im-section-heading' }, [
				E('div', {}, [
					E('h3', {}, [ _('Availability') ]),
					E('p', {}, [ _('Measured time without a confirmed Internet outage.') ])
				])
			]),
			E('div', { 'class': 'im-metric-grid' }, periods.map(function(period) {
				var periodStats = stats[period.key] || {};
				var hasMonitoredData = Number(periodStats.monitored) > 0;

				return E('article', { 'class': 'im-metric-card' }, [
					E('div', { 'class': 'im-metric-period' }, [ period.label ]),
					E('div', { 'class': 'im-metric-value' }, [
						hasMonitoredData ? formatAvailability(periodStats.availability) : '—'
					]),
					E('dl', { 'class': 'im-metric-details' }, [
						E('div', {}, [
							E('dt', {}, [ _('Monitored') ]),
							E('dd', {}, [ formatDuration(periodStats.monitored) ])
						]),
						E('div', {}, [
							E('dt', {}, [ _('Downtime') ]),
							E('dd', {}, [ formatDuration(periodStats.downtime) ])
						])
					])
				]);
			}))
		]);
	},

	renderTimeline: function(history, historyError) {
		var points = history && Array.isArray(history.points) ? history.points : [];
		var bins = timelineBins(points, 24, 96, history && history.generated_at);
		var hasData = points.length > 0;
		var body;

		if (historyError) {
			body = E('div', { 'class': 'im-empty im-empty-error', 'role': 'alert' }, [
				E('strong', {}, [ _('History is unavailable') ]),
				E('span', {}, [ getErrorMessage(historyError) ])
			]);
		}
		else if (!hasData) {
			body = E('div', { 'class': 'im-empty' }, [
				E('strong', {}, [ _('No history recorded yet') ]),
				E('span', {}, [ _('The timeline will appear after the first connectivity checks complete.') ])
			]);
		}
		else {
			body = E('div', {}, [
				E('div', {
					'class': 'im-timeline',
					'role': 'img',
					'aria-label': _('Connectivity state over the last 24 hours')
				}, bins.map(function(bin) {
					var title = _('%s–%s: %s').format(
						formatShortTime(bin.start),
						formatShortTime(bin.end),
						stateLabel(bin.state)
					);

					if (bin.latency != null)
						title += ' · ' + formatLatency(bin.latency);

					return E('span', {
						'class': 'im-timeline-segment im-state-' + bin.state,
						'title': title
					});
				})),
				E('div', { 'class': 'im-timeline-labels' }, [
					E('span', {}, [ _('24 hours ago') ]),
					E('span', {}, [ _('Now') ])
				]),
				E('div', { 'class': 'im-legend' }, [
					this.renderLegendItem('operational', _('Operational')),
					this.renderLegendItem('degraded', _('Degraded')),
					this.renderLegendItem('outage', _('Outage')),
					this.renderLegendItem('unknown', _('No data'))
				])
			]);
		}

		return E('section', { 'class': 'im-section im-timeline-section' }, [
			E('div', { 'class': 'im-section-heading' }, [
				E('div', {}, [
					E('h3', {}, [ _('24-hour connectivity') ]),
					E('p', {}, [ _('Each bar represents a 15-minute period; the most severe result is shown.') ])
				])
			]),
			body
		]);
	},

	renderLegendItem: function(state, label) {
		return E('span', {}, [
			E('i', { 'class': 'im-legend-swatch im-state-' + state, 'aria-hidden': 'true' }),
			label
		]);
	},

	renderTargets: function(status) {
		var targets = status && Array.isArray(status.targets) ? status.targets : [];
		var cards;

		if (!targets.length) {
			cards = E('div', { 'class': 'im-empty' }, [
				E('strong', {}, [ _('No probe targets configured') ]),
				E('span', {}, [ _('Add at least one ICMP or HTTP target in settings.') ])
			]);
		}
		else {
			cards = E('div', { 'class': 'im-target-grid' }, targets.map(function(target) {
				var state = targetState(target.ok);

				return E('article', { 'class': 'im-target-card im-target-' + state }, [
					E('div', { 'class': 'im-target-head' }, [
						E('div', {}, [
							E('h4', {}, [ target.name || target.address || _('Unnamed target') ]),
							E('div', { 'class': 'im-target-address' }, [ target.address || '—' ])
						]),
						E('span', { 'class': 'im-badge im-badge-' + state }, [
							E('i', { 'aria-hidden': 'true' }),
							targetStateLabel(state)
						])
					]),
					E('div', { 'class': 'im-target-stats' }, [
						E('span', {}, [
							E('small', {}, [ _('Method') ]),
							E('strong', {}, [ targetTypeLabel(target.type) ])
						]),
						E('span', {}, [
							E('small', {}, [ _('Address family') ]),
							E('strong', {}, [ familyLabel(target.family) ])
						]),
						E('span', {}, [
							E('small', {}, [ _('Latency') ]),
							E('strong', {}, [ formatLatency(target.latency_ms) ])
						])
					]),
					target.message ? E('p', { 'class': 'im-target-message' }, [ target.message ]) : E([])
				]);
			}));
		}

		return E('section', { 'class': 'im-section' }, [
			E('div', { 'class': 'im-section-heading' }, [
				E('div', {}, [
					E('h3', {}, [ _('Probe targets') ]),
					E('p', {}, [ _('Latest result from each independent external check.') ])
				]),
				E('span', { 'class': 'im-count' }, [
					_('%d targets').format(targets.length)
				])
			]),
			cards
		]);
	},

	renderIncidents: function(history, historyError) {
		var incidents = history && Array.isArray(history.incidents) ? history.incidents.slice() : [];
		var content;

		incidents.sort(function(a, b) {
			return (toTimestamp(b.start) || 0) - (toTimestamp(a.start) || 0);
		});

		if (historyError) {
			content = E('div', { 'class': 'im-empty im-empty-error', 'role': 'alert' }, [
				E('strong', {}, [ _('Incident history is unavailable') ]),
				E('span', {}, [ getErrorMessage(historyError) ])
			]);
		}
		else if (!incidents.length) {
			content = E('div', { 'class': 'im-no-incidents' }, [
				E('span', { 'aria-hidden': 'true' }, [ '✓' ]),
				E('div', {}, [
					E('strong', {}, [ _('No incidents in the last 24 hours') ]),
					E('p', {}, [ _('No connectivity outage met the configured failure threshold.') ])
				])
			]);
		}
		else {
			content = E('div', { 'class': 'im-incident-list' }, incidents.map(function(incident) {
				var ongoing = incident.ongoing === true || incident.ongoing === 1 || !incident.end;
				var start = toTimestamp(incident.start);
				var end = toTimestamp(incident.end);
				var duration = incident.duration;

				if (duration == null && start != null)
					duration = Math.max(0, ((end || Date.now()) - start) / 1000);

				return E('article', { 'class': 'im-incident' + (ongoing ? ' im-incident-ongoing' : '') }, [
					E('div', { 'class': 'im-incident-marker', 'aria-hidden': 'true' }),
					E('div', { 'class': 'im-incident-body' }, [
						E('div', { 'class': 'im-incident-title' }, [
							E('h4', {}, [ ongoing ? _('Ongoing incident') : _('Connectivity incident') ]),
							ongoing ? E('span', { 'class': 'im-badge im-badge-outage' }, [ _('Ongoing') ]) : E([])
						]),
						E('p', {}, [
							incident.reason || _('Connectivity checks did not meet the configured quorum.')
						]),
						E('div', { 'class': 'im-incident-meta' }, [
							E('span', {}, [
								ongoing ?
									_('Started %s').format(formatDateTime(incident.start)) :
									_('%s – %s').format(formatDateTime(incident.start), formatDateTime(incident.end))
							]),
							E('span', {}, [ _('Duration: %s').format(formatDuration(duration)) ])
						])
					])
				]);
			}));
		}

		return E('section', { 'class': 'im-section' }, [
			E('div', { 'class': 'im-section-heading' }, [
				E('div', {}, [
					E('h3', {}, [ _('Incidents') ]),
					E('p', {}, [ _('Recorded periods where Internet availability fell below the configured quorum.') ])
				])
			]),
			content
		]);
	},

	renderDashboard: function(data) {
		var nodes = [ this.renderHeader() ];

		if (data.statusError)
			nodes.push(this.renderRpcError(data.statusError));

		nodes.push(this.renderStatusBanner(data.status));
		nodes.push(this.renderAvailability(data.status));
		nodes.push(this.renderTimeline(data.history, data.historyError));
		nodes.push(this.renderTargets(data.status));
		nodes.push(this.renderIncidents(data.history, data.historyError));
		nodes.push(E('p', { 'class': 'im-poll-note' }, [
			_('This page refreshes automatically every 5 seconds.')
		]));

		return nodes;
	},

	render: function(data) {
		ensureStylesheet();

		if (!this._pollStarted) {
			poll.add(L.bind(this.refresh, this), 5);
			this._pollStarted = true;
		}

		return E('div', {
			'id': 'internet-monitor-overview',
			'class': 'internet-monitor'
		}, this.renderDashboard(data));
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
