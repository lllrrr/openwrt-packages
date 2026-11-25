'use strict';
'require view';
'require rpc';
'require ui';
'require poll';

var callStatus = rpc.declare({
	object: 'luci.oxidns',
	method: 'status',
	expect: {}
});

var serviceCalls = {
	start: rpc.declare({ object: 'luci.oxidns', method: 'service_start', expect: {} }),
	stop: rpc.declare({ object: 'luci.oxidns', method: 'service_stop', expect: {} }),
	restart: rpc.declare({ object: 'luci.oxidns', method: 'service_restart', expect: {} }),
	enable: rpc.declare({ object: 'luci.oxidns', method: 'service_enable', expect: {} }),
	disable: rpc.declare({ object: 'luci.oxidns', method: 'service_disable', expect: {} })
};

var SERVICE_LABELS = {
	start: _('Start'),
	stop: _('Stop'),
	restart: _('Restart'),
	enable: _('Enable'),
	disable: _('Disable')
};

var BACKEND_ERRORS = {
	service_failed: _('The service action failed.'),
	service_unavailable: _('The init script is not available.'),
	rpc_unavailable: _('The LuCI backend is unavailable.')
};

var statusState = {};
var serviceActionsKey = null;
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

function showRefreshError(message) {
	var node = document.getElementById('oxidns-overview-error');
	if (!node)
		return;
	node.textContent = message || '';
	node.style.display = message ? 'block' : 'none';
}

function backendMessage(err, fallback) {
	var code = err && err.code;

	if (code && BACKEND_ERRORS[code])
		return BACKEND_ERRORS[code];

	return fallback || _('Operation failed');
}

function scheduleRetry() {
	cancelRetry();
	if (retryCount >= 4) {
		showRefreshError(_('Could not refresh OxiDNS status. Use Refresh to try again.'));
		return;
	}

	retryCount++;
	showRefreshError(_('Could not refresh OxiDNS status. Retrying...'));
	retryTimer = window.setTimeout(function() {
		retryTimer = null;
		if (isAttached(viewRoot))
			refreshStatus();
	}, Math.min(30000, 1000 * Math.pow(2, retryCount)));
}

function focusModal() {
	window.setTimeout(function() {
		var modal = document.getElementById('modal') || document.querySelector('.modal');
		if (!modal)
			return;

		var target = modal.querySelector('[autofocus], button:not([disabled]), input:not([disabled]), select, textarea');
		if (target && typeof target.focus === 'function')
			target.focus();
	}, 0);
}

function confirmAction(title, message, onConfirm) {
	ui.showModal(title, [
		E('p', {}, message),
		E('div', { 'class': 'right', 'style': 'margin-top: 1em;' }, [
			E('button', {
				'type': 'button',
				'class': 'btn cbi-button cbi-button-neutral',
				'click': function(ev) {
					ev.preventDefault();
					ui.hideModal();
				}
			}, _('Cancel')),
			' ',
			E('button', {
				'type': 'button',
				'class': 'btn cbi-button cbi-button-positive',
				'click': function(ev) {
					ev.preventDefault();
					ui.hideModal();
					return onConfirm();
				}
			}, _('Confirm'))
		])
	]);
	focusModal();
}

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

function serviceEnabled(status) {
	return !!(status && status.service_status && status.service_status.enabled);
}

function coreInstalled(status) {
	return !!(status && status.core && status.core.installed);
}

function statusBadge(text, good) {
	return E('span', {
		'class': good ? 'label label-success' : 'label label-warning',
		'aria-live': 'polite'
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
		/* 只接受 http/https，拒绝 javascript: 等伪协议 */
		if (url.protocol !== 'http:' && url.protocol !== 'https:')
			return '';

		if (!(status && status.webui && status.webui.local_only) && localServiceHost(url.hostname) && window.location.hostname)
			url.hostname = window.location.hostname;
		url.pathname = url.pathname || '/';
		url.search = '';
		url.hash = '';
		return url.toString();
	} catch (e) {
		return '';
	}
}

function webuiReady(status) {
	return !!(status && status.webui && status.webui.installed && serviceRunning(status) && browserWebuiUrl(status));
}

function webuiHint(status) {
	if (!status || !status.webui || !status.webui.installed)
		return _('WebUI files are not installed.');
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
		'rel': 'noopener noreferrer'
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

function blockedActionMessage(action, status) {
	if (!coreInstalled(status))
		return _('Install the OxiDNS core before using service controls.');
	if (action === 'start' && serviceRunning(status))
		return _('OxiDNS is already running.');
	if (action === 'stop' && !serviceRunning(status))
		return _('OxiDNS is already stopped.');
	if (action === 'enable' && serviceEnabled(status))
		return _('OxiDNS is already enabled on boot.');
	if (action === 'disable' && !serviceEnabled(status))
		return _('OxiDNS is already disabled on boot.');
	return null;
}

function refreshStatus() {
	if (!isAttached(viewRoot)) {
		unregisterPoll();
		return Promise.resolve();
	}

	/* 不用 L.resolveDefault：它吞掉错误，导致界面停留在旧状态且没有提示 */
	return Promise.resolve(callStatus()).then(function(status) {
		if (!status || status.ok === false)
			throw status || { code: 'rpc_unavailable' };

		statusState = status;
		cancelRetry();
		showRefreshError('');

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
			if (node && isAttached(viewRoot))
				setNodeContent(node, fields[id]);
		});

		if (isAttached(viewRoot))
			updateServiceActions(statusState);
	}).catch(function(err) {
		/* 保留最后一次成功的状态，只提示错误并按指数退避重试 */
		scheduleRetry();
		console.warn('oxidns status refresh:', err);
	});
}

function handleServiceAction(action) {
	var call = serviceCalls[action];
	if (!call)
		return;

	var blocked = blockedActionMessage(action, statusState);
	if (blocked) {
		ui.addNotification(null, E('p', {}, blocked), 'info');
		return refreshStatus();
	}

	ui.showModal(_('OxiDNS'), [
		E('p', {}, _('Applying service action...'))
	]);
	focusModal();

	return Promise.resolve(call()).then(function(result) {
		ui.hideModal();
		if (!result || result.ok === false) {
			ui.addNotification(null, E('p', {}, backendMessage(result, _('Service action failed'))), 'danger');
			return;
		}
		return refreshStatus().then(function() {
			ui.addNotification(null, E('p', {}, _('Service action completed.')), 'info');
		});
	}).catch(function(err) {
		ui.hideModal();
		ui.addNotification(null, E('p', {}, backendMessage(err, _('Service action failed'))), 'danger');
	});
}

function actionButton(label, action, style, id) {
	var attrs = {
		'id': id,
		'type': 'button',
		'class': 'btn cbi-button cbi-button-%s'.format(style || 'neutral'),
		'click': function(ev) {
			ev.preventDefault();
			var name = SERVICE_LABELS[action] || action;
			return confirmAction(_('OxiDNS'), _('Apply the %s service action?').format(name), function() {
				return handleServiceAction(action);
			});
		}
	};

	return E('button', attrs, label);
}

function disabledActionButton(label, hint, id) {
	return E('button', {
		'id': id,
		'type': 'button',
		'class': 'btn cbi-button cbi-button-neutral',
		'disabled': 'disabled',
		'title': hint
	}, label);
}

function coreInstallLink() {
	return E('a', {
		'class': 'btn cbi-button cbi-button-action',
		'href': L.url('admin/services/oxidns/core')
	}, _('Install Core'));
}

function serviceActionButtons(status) {
	var actions = [];
	var missingCoreHint = _('Install the OxiDNS core before using service controls.');

	if (!coreInstalled(status)) {
		actions.push(disabledActionButton(_('Start'), missingCoreHint, 'oxidns-service-start'));
		actions.push(disabledActionButton(_('Enable'), missingCoreHint, 'oxidns-service-enable'));
		actions.push(coreInstallLink());
		return actions;
	}

	if (serviceRunning(status)) {
		actions.push(actionButton(_('Stop'), 'stop', 'negative', 'oxidns-service-stop'));
		actions.push(actionButton(_('Restart'), 'restart', 'action', 'oxidns-service-restart'));
	} else {
		actions.push(actionButton(_('Start'), 'start', 'positive', 'oxidns-service-start'));
	}

	if (serviceEnabled(status))
		actions.push(actionButton(_('Disable'), 'disable', 'neutral', 'oxidns-service-disable'));
	else
		actions.push(actionButton(_('Enable'), 'enable', 'positive', 'oxidns-service-enable'));

	return actions;
}

function serviceActionStateKey(status) {
	return '%s:%s:%s'.format(
		coreInstalled(status) ? 'core' : 'missing-core',
		serviceRunning(status) ? 'running' : 'stopped',
		serviceEnabled(status) ? 'enabled' : 'disabled');
}

function updateServiceActions(status) {
	var node = document.getElementById('oxidns-service-actions');
	if (!node)
		return;

	var nextKey = serviceActionStateKey(status);
	if (nextKey === serviceActionsKey)
		return;

	serviceActionsKey = nextKey;
	while (node.firstChild)
		node.removeChild(node.firstChild);

	serviceActionButtons(status).forEach(function(button) {
		node.appendChild(button);
	});
}

return view.extend({
	load: function() {
		return Promise.resolve(callStatus()).catch(function(err) {
			console.warn('oxidns status load:', err);
			return {
				ok: false,
				error: _('Unable to query OxiDNS status')
			};
		});
	},

	render: function(status) {
		status = status || {};
		statusState = status;

		addCleanup(unregisterPoll);
		addCleanup(cancelRetry);

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
			rows.push(renderRow(_('Error'), status.error));

		serviceActionsKey = serviceActionStateKey(statusState);

		var map = E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('OxiDNS')),
			E('div', { 'class': 'cbi-map-descr' },
				_('Manage the OxiDNS runtime, service, configuration, and logs from LuCI.')),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Overview')),
				E('div', { 'class': 'table cbi-section-table' }, rows)
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Service')),
				E('div', { 'class': 'cbi-section-descr' },
					_('Control the OpenWrt init service for OxiDNS.')),
				E('div', {
					'id': 'oxidns-service-actions',
					'class': 'cbi-button-row',
					'style': 'display: flex; flex-wrap: wrap; gap: .5em;'
				}, serviceActionButtons(statusState))
			]),
			E('div', {
				'id': 'oxidns-overview-error',
				'class': 'alert-message error',
				'aria-live': 'polite',
				'style': 'margin-top: 1em; display: none;'
			})
		]);

		watchView(map);

		/* poll 是全局对象：必须保存函数引用并在视图卸载时 poll.remove */
		pollFn = refreshStatus;
		poll.add(pollFn, 5);

		return map;
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
