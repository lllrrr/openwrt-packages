'use strict';
'require view';
'require rpc';
'require ui';
'require oxidns.i18n as i18n';
'require poll';

var callStatus = rpc.declare({
	object: 'luci.oxidns',
	method: 'status',
	expect: {}
});

var serviceCalls = {
	start: rpc.declare({ object: 'luci.oxidns', method: 'service_start', expect: {} }),
	stop: rpc.declare({ object: 'luci.oxidns', method: 'service_stop', expect: {} }),
	restart: rpc.declare({ object: 'luci.oxidns', method: 'service_restart', expect: {} })
};

var callDnsIntegrationStatus = rpc.declare({
	object: 'luci.oxidns',
	method: 'dns_integration_status',
	expect: {}
});

var dnsIntegrationCalls = {
	enable: rpc.declare({ object: 'luci.oxidns', method: 'dns_integration_enable', expect: {} }),
	disable: rpc.declare({ object: 'luci.oxidns', method: 'dns_integration_disable', expect: {} })
};

var statusState = {};
var serviceActionsKey = null;
var dnsIntegrationState = {};
var dnsIntegrationBusy = false;
var dnsIntegrationKey = null;

function valueOrDash(value) {
	if (value === null || value === undefined || value === '')
		return '-';
	return value;
}

function boolText(value) {
	return value ? _('Yes') : _('No');
}

function serviceRunning(status) {
	return !!(status && status.service_status && status.service_status.running);
}

function coreInstalled(status) {
	return !!(status && status.ok !== false && status.core && status.core.installed);
}

function statusBadge(text, good) {
	return E('span', {
		'class': good ? 'label label-success' : 'label label-warning'
	}, text);
}

function backendStatusBadge(status) {
	return status && status.ok ? statusBadge(_('Available'), true) : statusBadge(_('Unavailable'), false);
}

function serviceStatusBadge(status) {
	return serviceRunning(status) ? statusBadge(_('Running'), true) : statusBadge(_('Stopped'), false);
}

function localServiceHost(host) {
	return host === 'localhost' ||
		host === '127.0.0.1' ||
		host === '0.0.0.0' ||
		host === '::' ||
		host === '::1' ||
		host === '[::]' ||
		host === '[::1]';
}

function browserWebuiUrl(status) {
	var raw = status && status.webui && status.webui.url;
	if (!raw)
		return '';

	try {
		var url = new URL(raw, window.location.href);
		if (!(status && status.webui && status.webui.local_only) && localServiceHost(url.hostname) && window.location.hostname)
			url.hostname = window.location.hostname;
		url.pathname = url.pathname || '/';
		url.search = '';
		url.hash = '';
		return url.toString();
	} catch (e) {
		return raw;
	}
}

function webuiReady(status) {
	return !!(status && status.webui && status.webui.installed && serviceRunning(status) && browserWebuiUrl(status));
}

function webuiHint(status) {
	if (!status || !status.webui || !status.webui.installed) {
		if (!coreInstalled(status))
			return _('Install the OxiDNS core before using WebUI.');
		if (status.core && status.core.bundle === 'minimal')
			return _('The installed minimal core bundle does not include WebUI files. Install WebUI on the Installation and Deployment page to replace it with a bundle that includes WebUI.');
		return _('WebUI files are not installed. Install them from the Installation and Deployment page using Install WebUI.');
	}
	if (!serviceRunning(status))
		return _('Start the OxiDNS service before opening WebUI.');
	if (status.webui.local_only)
		return _('WebUI listens on loopback only. Configure the HTTP listen address to a LAN-reachable address, or use an SSH tunnel.');
	return '';
}

function webuiButton(status) {
	var url = browserWebuiUrl(status);
	var ready = webuiReady(status);
	var hint = webuiHint(status);

	if (!ready) {
		return E('button', {
			'id': 'oxidns-webui-link',
			'class': 'btn cbi-button cbi-button-neutral',
			'type': 'button',
			'disabled': 'disabled',
			'title': hint
		}, _('Open WebUI'));
	}

	return E('a', {
		'id': 'oxidns-webui-link',
		'class': 'btn cbi-button cbi-button-action',
		'href': url,
		'target': '_blank',
		'rel': 'noopener'
	}, _('Open WebUI'));
}

function webuiEntry(status) {
	var hint = webuiHint(status);

	return E('div', {
		'style': 'display: flex; flex-wrap: wrap; gap: .75em; align-items: center;'
	}, [
		webuiButton(status),
		hint ? E('span', { 'class': 'cbi-value-description' }, hint) : ''
	]);
}

function renderRow(label, value, id) {
	var attrs = { 'class': 'td left' };
	if (id)
		attrs.id = id;

	return E('div', { 'class': 'tr' }, [
		E('div', { 'class': 'td left', 'style': 'width: 240px' }, label),
		E('div', attrs, valueOrDash(value))
	]);
}

function coreSummary(status) {
	var core = status.core || {};
	var parts = [];

	parts.push(core.installed ? _('Installed') : _('Not installed'));
	if (core.version)
		parts.push(core.version);
	if (core.bundle)
		parts.push(core.bundle);
	if (core.target)
		parts.push(core.target);

	return parts.join(' · ');
}

function buildSummary(status) {
	var build = status.build || {};
	if (!build.version)
		return '-';
	return '%s · %s'.format(build.version, build.bundle || 'unknown');
}

function setNodeContent(node, value) {
	while (node.firstChild)
		node.removeChild(node.firstChild);

	if (value && value.nodeType)
		node.appendChild(value);
	else
		node.textContent = valueOrDash(value);
}

function blockedServiceActionMessage(action, status) {
	if (!coreInstalled(status))
		return _('Install the OxiDNS core before using service controls.');
	if (action === 'start' && serviceRunning(status))
		return _('OxiDNS is already running.');
	if (action === 'stop' && !serviceRunning(status))
		return _('OxiDNS is already stopped.');
	return null;
}

function confirmStopWithDnsIntegration() {
	return new Promise(function(resolve) {
		ui.showModal(_('Stop OxiDNS'), [
			E('p', {}, _('System DNS integration is enabled. Stopping OxiDNS will make LAN DNS resolution fail until OxiDNS is started again or system DNS integration is disabled.')),
			E('div', { 'class': 'right' }, [
				E('button', {
					'class': 'btn cbi-button cbi-button-neutral',
					'type': 'button',
					'click': function(ev) {
						ev.preventDefault();
						ui.hideModal();
						resolve(false);
					}
				}, _('Cancel')),
				' ',
				E('button', {
					'class': 'btn cbi-button cbi-button-negative',
					'type': 'button',
					'click': function(ev) {
						ev.preventDefault();
						ui.hideModal();
						resolve(true);
					}
				}, _('Stop OxiDNS'))
			])
		]);
	});
}

function performServiceAction(call, action) {
	ui.showModal(_('OxiDNS'), [
		E('p', {}, _('Applying service action...'))
	]);

	return L.resolveDefault(call(), null).then(function(result) {
		ui.hideModal();
		if (!result || result.ok === false) {
			ui.addNotification(null, E('p', {}, i18n.message(result) || _('Service action failed')), 'danger');
			return;
		}
		return refreshStatus();
	}).catch(function(err) {
		ui.hideModal();
		ui.addNotification(null, E('p', {}, (err && err.message) || String(err)), 'danger');
	});
}

function handleServiceAction(action) {
	var call = serviceCalls[action];
	if (!call)
		return Promise.resolve();

	var blocked = blockedServiceActionMessage(action, statusState);
	if (blocked) {
		ui.addNotification(null, E('p', {}, blocked), 'info');
		return refreshStatus();
	}

	if (action === 'stop' && dnsIntegrationState.managed) {
		return confirmStopWithDnsIntegration().then(function(confirmed) {
			if (confirmed)
				return performServiceAction(call, action);
		});
	}

	return performServiceAction(call, action);
}

function actionButton(label, action, style, id) {
	return E('button', {
		'id': id,
		'class': 'btn cbi-button cbi-button-%s'.format(style || 'neutral'),
		'click': function(ev) {
			ev.preventDefault();
			return handleServiceAction(action);
		}
	}, label);
}

function disabledActionButton(label, hint, id) {
	return E('button', {
		'id': id,
		'class': 'btn cbi-button cbi-button-neutral',
		'type': 'button',
		'disabled': 'disabled',
		'aria-disabled': 'true',
		'title': hint
	}, label);
}

function serviceLockedHint() {
	return E('span', {
		'class': 'cbi-value-description',
		'style': 'align-self: center;'
	}, _('Install the OxiDNS core before using service controls.'));
}

function serviceActionButtons(status) {
	var actions = [];

	if (!coreInstalled(status)) {
		actions.push(disabledActionButton(_('Start'), _('Install the OxiDNS core before using service controls.'), 'oxidns-service-start'));
		actions.push(serviceLockedHint());
		return actions;
	}

	if (serviceRunning(status)) {
		actions.push(actionButton(_('Stop'), 'stop', 'negative', 'oxidns-service-stop'));
		actions.push(actionButton(_('Restart'), 'restart', 'action', 'oxidns-service-restart'));
	} else {
		actions.push(actionButton(_('Start'), 'start', 'positive', 'oxidns-service-start'));
	}

	return actions;
}

function serviceActionStateKey(status) {
	return '%s:%s'.format(
		coreInstalled(status) ? 'core' : 'missing-core',
		serviceRunning(status) ? 'running' : 'stopped');
}

function replaceContent(node, content) {
	while (node.firstChild)
		node.removeChild(node.firstChild);

	if (Array.isArray(content)) {
		content.forEach(function(child) {
			if (child)
				node.appendChild(child);
		});
	} else if (content && content.nodeType) {
		node.appendChild(content);
	} else {
		node.textContent = valueOrDash(content);
	}
}

function updateServiceActions(status) {
	var node = document.getElementById('oxidns-service-actions');
	if (!node)
		return;

	var nextKey = serviceActionStateKey(status);
	if (nextKey === serviceActionsKey)
		return;

	serviceActionsKey = nextKey;
	replaceContent(node, serviceActionButtons(status));
}

function dnsServerListText(values) {
	if (!Array.isArray(values) || !values.length)
		return _('None');
	return values.join(', ');
}

function dnsIntegrationBadge(state) {
	if (!state || state.ok === false || !state.supported)
		return statusBadge(_('Unavailable'), false);
	if (state.managed)
		return statusBadge(_('Enabled'), true);
	return E('span', { 'class': 'label' }, _('Not enabled'));
}

function dnsmasqStatusBadge(state) {
	if (!state || state.ok === false || !state.supported)
		return statusBadge(_('Unavailable'), false);
	return state.dnsmasq_running ? statusBadge(_('Running'), true) : statusBadge(_('Stopped'), false);
}

function dnsIntegrationTargetText(state) {
	if (!state || !state.target)
		return '-';
	if (state.listener_active)
		return state.target;
	return _('%s (not listening)').format(state.target);
}

function dnsIntegrationUpstreamText(state) {
	if (!state || !state.supported)
		return '-';
	if (state.managed)
		return dnsServerListText(state.previous_servers);
	return dnsServerListText(state.generic_servers);
}

function dnsIntegrationDomainText(state) {
	if (!state || !state.supported)
		return '-';
	return dnsServerListText(state.domain_servers);
}

function dnsIntegrationNote(state) {
	if (!state || state.ok === false)
		return _('Unable to query system DNS integration status.');
	if (!state.supported)
		return i18n.translate(state.message) || _('dnsmasq is not available');
	if (state.managed && !state.service_running)
		return _('OxiDNS is stopped. LAN DNS resolution is failing until OxiDNS is started or system DNS integration is disabled.');
	if (state.warning)
		return i18n.translate(state.warning);
	if (state.managed)
		return _('LAN DNS queries are forwarded to OxiDNS. Stopping OxiDNS will break DNS resolution for LAN clients.');
	if (state.message)
		return i18n.translate(state.message);
	return _('Optional feature: forward LAN DNS queries through OxiDNS. This is disabled by default and can be reverted here at any time.') + ' ' +
		_('When enabled, dnsmasq forwards generic DNS queries to OxiDNS. Domain-specific upstreams are kept.');
}

function dnsIntegrationRows(state) {
	return [
		renderRow(_('dnsmasq'), dnsmasqStatusBadge(state), 'oxidns-dnsmasq-status'),
		renderRow(_('DNS integration'), dnsIntegrationBadge(state), 'oxidns-dns-integration-badge'),
		renderRow(_('OxiDNS DNS listener'), dnsIntegrationTargetText(state), 'oxidns-dns-integration-target'),
		renderRow(_('dnsmasq upstream'), dnsIntegrationUpstreamText(state), 'oxidns-dns-integration-upstream'),
		renderRow(_('Domain-specific upstreams'), dnsIntegrationDomainText(state), 'oxidns-dns-integration-domain'),
		renderRow(_('dnsmasq noresolv'),
			state && state.noresolv_set ? state.noresolv : '-',
			'oxidns-dns-integration-noresolv')
	];
}

function dnsIntegrationButtons(state) {
	var hint = dnsIntegrationNote(state);
	var actions = [];

	if (!state || state.ok === false || !state.supported) {
		actions.push(disabledActionButton(_('Enable dnsmasq forwarding'), hint, 'oxidns-dns-integration-enable'));
	}
	else if (dnsIntegrationBusy) {
		actions.push(disabledActionButton(_('Applying...'), hint, 'oxidns-dns-integration-busy'));
	}
	else if (state.managed) {
		actions.push(E('button', {
			'id': 'oxidns-dns-integration-disable',
			'class': 'btn cbi-button cbi-button-negative',
			'type': 'button',
			'click': function(ev) {
				ev.preventDefault();
				return handleDnsIntegrationAction('disable');
			}
		}, _('Disable dnsmasq forwarding')));
	}
	else {
		var button = E('button', {
			'id': 'oxidns-dns-integration-enable',
			'class': 'btn cbi-button cbi-button-positive',
			'type': 'button',
			'click': function(ev) {
				ev.preventDefault();
				return handleDnsIntegrationAction('enable');
			}
		}, _('Enable dnsmasq forwarding'));

		if (!state.can_enable) {
			button.disabled = true;
			button.setAttribute('aria-disabled', 'true');
			button.title = hint;
		}
		actions.push(button);
	}

	return actions;
}

function dnsIntegrationBody(state) {
	return [
		E('div', { 'class': 'table cbi-section-table' }, dnsIntegrationRows(state)),
		E('div', {
			'id': 'oxidns-dns-integration-actions',
			'class': 'cbi-button-row',
			'style': 'display: flex; flex-wrap: wrap; justify-content: flex-start; gap: .5em; padding-inline: var(--section-inset, 0); padding-top: .5em; padding-bottom: var(--field-gap, 1em);'
		}, dnsIntegrationButtons(state))
	];
}

function dnsIntegrationStateKey(state) {
	try {
		return JSON.stringify(state || {}) + '|' + (dnsIntegrationBusy ? 'busy' : 'idle');
	}
	catch (e) {
		return String(Date.now());
	}
}

function updateDnsIntegration() {
	var node = document.getElementById('oxidns-dns-integration-body');
	if (!node)
		return;

	var nextKey = dnsIntegrationStateKey(dnsIntegrationState);
	if (nextKey === dnsIntegrationKey)
		return;

	dnsIntegrationKey = nextKey;
	var note = document.getElementById('oxidns-dns-integration-note');
	if (note)
		note.textContent = dnsIntegrationNote(dnsIntegrationState);
	replaceContent(node, dnsIntegrationBody(dnsIntegrationState));
}

function confirmDnsIntegration(action) {
	var state = dnsIntegrationState || {};
	var title = action === 'enable'
		? _('Enable system DNS integration')
		: _('Disable system DNS integration');
	var items;

	if (action === 'enable') {
		items = [
			E('li', {}, _('Remove generic upstream servers: %s.').format(dnsServerListText(state.generic_servers))),
			E('li', {}, _('Add forwarding server %s.').format(state.target)),
			E('li', {}, _('Set dnsmasq noresolv to 1.')),
			E('li', {}, _('Keep domain-specific upstream servers unchanged: %s.').format(dnsServerListText(state.domain_servers)))
		];
	}
	else {
		items = [
			E('li', {}, _('Remove forwarding server %s.').format(state.forward || '-')),
			E('li', {}, _('Restore previous upstream servers: %s.').format(dnsServerListText(state.previous_servers))),
			E('li', {}, _('Restore the previous dnsmasq noresolv setting.'))
		];
	}

	return new Promise(function(resolve) {
		ui.showModal(title, [
			action === 'enable'
				? E('p', {}, _('dnsmasq will forward generic DNS queries to %s.').format(state.target))
				: E('p', {}, _('dnsmasq will stop forwarding DNS queries to OxiDNS.')),
			E('ul', { 'style': 'margin: .5em 0 .5em 1.25em;' }, items),
			E('p', { 'class': 'alert-message warning' },
				action === 'enable'
					? _('While OxiDNS is stopped, LAN DNS resolution will fail. Disable system DNS integration to restore the previous dnsmasq settings.')
					: _('LAN DNS queries will use the restored upstream servers again.')),
			E('div', { 'class': 'right' }, [
				E('button', {
					'class': 'btn cbi-button cbi-button-neutral',
					'type': 'button',
					'click': function(ev) {
						ev.preventDefault();
						ui.hideModal();
						resolve(false);
					}
				}, _('Cancel')),
				' ',
				E('button', {
					'class': 'btn cbi-button cbi-button-%s'.format(action === 'enable' ? 'positive' : 'negative'),
					'type': 'button',
					'click': function(ev) {
						ev.preventDefault();
						ui.hideModal();
						resolve(true);
					}
				}, action === 'enable' ? _('Enable') : _('Disable'))
			])
		]);
	});
}

function handleDnsIntegrationAction(action) {
	var call = dnsIntegrationCalls[action];

	if (!call || dnsIntegrationBusy)
		return Promise.resolve();

	return confirmDnsIntegration(action).then(function(confirmed) {
		if (!confirmed)
			return;

		dnsIntegrationBusy = true;
		updateDnsIntegration();
		ui.showModal(_('System DNS integration'), [
			E('p', {}, _('Applying DNS integration...'))
		]);

		return L.resolveDefault(call(), null).then(function(result) {
			ui.hideModal();
			dnsIntegrationBusy = false;

			if (!result || result.ok === false) {
				ui.addNotification(null, E('p', {},
					i18n.message(result) || _('DNS integration action failed.')), 'danger');
			}
			else if (result.warning) {
				ui.addNotification(null, E('p', {}, i18n.translate(result.warning)), 'warning');
			}
			else {
				ui.addNotification(null, E('p', {}, action === 'enable'
					? _('System DNS integration enabled.')
					: _('System DNS integration disabled.')), 'info');
			}

			return refreshStatus();
		}).catch(function(err) {
			ui.hideModal();
			dnsIntegrationBusy = false;
			ui.addNotification(null, E('p', {},
				(err && err.message) || String(err)), 'danger');
			return refreshStatus();
		});
	});
}

function refreshStatus() {
	return Promise.all([
		L.resolveDefault(callStatus(), {}),
		L.resolveDefault(callDnsIntegrationStatus(), {})
	]).then(function(results) {
		statusState = results[0] || {};
		dnsIntegrationState = results[1] || {};

		var fields = {
			'oxidns-backend-status': backendStatusBadge(statusState),
			'oxidns-core': coreSummary(statusState),
			'oxidns-build': buildSummary(statusState),
			'oxidns-service-running': serviceStatusBadge(statusState),
			'oxidns-service-enabled': boolText(statusState.service_status && statusState.service_status.enabled),
			'oxidns-webui': webuiEntry(statusState),
			'oxidns-config-path': statusState.config_path,
			'oxidns-working-dir': statusState.working_dir
		};

		Object.keys(fields).forEach(function(id) {
			var node = document.getElementById(id);
			if (node)
				setNodeContent(node, fields[id]);
		});

		updateServiceActions(statusState);
		updateDnsIntegration();
	});
}

return view.extend({
	load: function() {
		return Promise.all([
			L.resolveDefault(callStatus(), {
				ok: false,
				error: _('Unable to query OxiDNS status')
			}),
			L.resolveDefault(callDnsIntegrationStatus(), {
				ok: false,
				message: _('Unable to query system DNS integration status.')
			})
		]).then(function(results) {
			return {
				status: results[0],
				dns: results[1]
			};
		});
	},

	render: function(data) {
		var status = (data && data.status) || {};
		var dns = (data && data.dns) || {};
		statusState = status;
		dnsIntegrationState = dns;

		var rows = [
			renderRow(_('LuCI backend'), backendStatusBadge(status), 'oxidns-backend-status'),
			renderRow(_('Core'), coreSummary(status), 'oxidns-core'),
			renderRow(_('Build'), buildSummary(status), 'oxidns-build'),
			renderRow(_('Service status'), serviceStatusBadge(status), 'oxidns-service-running'),
			renderRow(_('Start on boot'), boolText(status.service_status && status.service_status.enabled), 'oxidns-service-enabled'),
			renderRow(_('WebUI'), webuiEntry(status), 'oxidns-webui'),
			renderRow(_('Config path'), status.config_path || '/etc/oxidns/config.yaml', 'oxidns-config-path'),
			renderRow(_('Working directory'), status.working_dir || '/var/lib/oxidns', 'oxidns-working-dir')
		];

		if (status.error)
			rows.push(renderRow(_('Error'), i18n.translate(status.error)));

		serviceActionsKey = serviceActionStateKey(statusState);
		dnsIntegrationKey = dnsIntegrationStateKey(dnsIntegrationState);
		poll.add(refreshStatus, 5);

		return E('div', { 'class': 'cbi-map' }, [
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Status Overview')),
				E('div', { 'class': 'table cbi-section-table' }, rows)
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Service control')),
				E('div', { 'class': 'cbi-section-descr' },
					_('Start, stop, and restart control the running process.')),
				E('div', {
					'id': 'oxidns-service-actions',
					'class': 'cbi-button-row',
					'style': 'display: flex; flex-wrap: wrap; justify-content: flex-start; gap: .5em; padding-inline: var(--section-inset, 0); padding-bottom: var(--field-gap, 1em);'
				}, serviceActionButtons(statusState))
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('System DNS integration')),
				E('div', {
					'class': 'cbi-section-descr',
					'id': 'oxidns-dns-integration-note'
				}, dnsIntegrationNote(dnsIntegrationState)),
				E('div', { 'id': 'oxidns-dns-integration-body' }, dnsIntegrationBody(dnsIntegrationState))
			])
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
