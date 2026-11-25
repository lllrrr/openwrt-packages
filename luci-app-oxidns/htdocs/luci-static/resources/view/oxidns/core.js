'use strict';
'require view';
'require rpc';
'require request';
'require ui';

var callStatus = rpc.declare({
	object: 'luci.oxidns',
	method: 'status',
	expect: {}
});

var callCoreProgress = rpc.declare({
	object: 'luci.oxidns',
	method: 'core_progress',
	expect: {}
});

/*
 * Long running operations used to temporarily assign L.env.rpctimeout, which
 * races with every other RPC call on the page and leaks the changed value on
 * synchronous throws. The declarations below are invoked through a direct
 * JSON-RPC POST carrying its own timeout, so the global environment is never
 * touched. Method names and parameter names are unchanged.
 */
var CORE_RPC = {
	install: { object: 'luci.oxidns', method: 'core_install' },
	reinstall: { object: 'luci.oxidns', method: 'core_reinstall' },
	update_check: { object: 'luci.oxidns', method: 'core_update_check' },
	update: { object: 'luci.oxidns', method: 'core_update' },
	upload_install: { object: 'luci.oxidns', method: 'core_upload_install', params: [ 'path' ] },
	remove: { object: 'luci.oxidns', method: 'core_remove', params: [ 'remove_config', 'remove_workdir' ] }
};

var BACKEND_ERRORS = {
	core_download_failed: _('Failed to download the OxiDNS core archive.'),
	core_install_failed: _('Failed to install the OxiDNS core.'),
	core_update_failed: _('Failed to update the OxiDNS core.'),
	core_remove_failed: _('Failed to remove the OxiDNS core.'),
	core_upload_failed: _('Failed to install the uploaded core file.'),
	rpc_unavailable: _('The LuCI backend is unavailable.'),
	operation_cancelled: _('The operation was cancelled in the browser. The device may still be working; check the status before retrying.')
};

var statusState = {};
var viewRoot = null;
var viewObserver = null;
var cleanupTasks = [];
var retryTimer = null;
var retryCount = 0;
var progressState = { generation: 0, timer: null, failures: 0 };
var activeOperation = null;

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

function showRefreshError(message) {
	var node = document.getElementById('oxidns-core-error');
	if (!node)
		return;
	node.textContent = message || '';
	node.style.display = message ? 'block' : 'none';
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

function callLongRpc(desc, args, seconds) {
	var params = {};

	if (Array.isArray(desc.params))
		for (var i = 0; i < desc.params.length; i++)
			params[desc.params[i]] = args && args[i];

	return new Promise(function(resolve, reject) {
		var msg = {
			jsonrpc: '2.0',
			id: 'oxidns-' + Date.now() + '-' + Math.floor(Math.random() * 1000000),
			method: 'call',
			params: [ rpc.getSessionID(), desc.object, desc.method, params ]
		};
		var req = {
			object: desc.object,
			method: desc.method,
			expect: {},
			resolve: resolve,
			reject: reject
		};

		request.post(rpc.getBaseURL(), msg, {
			timeout: seconds * 1000,
			credentials: true
		}).then(function(res) {
			rpc.parseCallReply(req, res);
		}, function(err) {
			reject(err);
		});
	});
}

function valueOrDash(value) {
	if (value === null || value === undefined || value === '')
		return '-';
	return value;
}

function boolText(value) {
	return value ? _('Yes') : _('No');
}

function coreInstalled(status) {
	return !!(status && status.core && status.core.installed);
}

function serviceRunning(status) {
	return !!(status && status.service_status && status.service_status.running);
}

function persistText(status) {
	var persist = status && status.persist;
	if (!persist || !persist.enabled)
		return _('Disabled');
	return persist.binary_saved ? _('Enabled') : _('Enabled (core not saved yet)');
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

/* 只在内容变化时写 DOM，轮询刷新不会重建整张表 */
function setText(id, value) {
	var node = document.getElementById(id);
	if (!node)
		return;

	var text = valueOrDash(value);
	if (node.textContent !== text)
		node.textContent = text;
}

function scheduleStatusRetry() {
	cancelRetry();
	if (retryCount >= 4) {
		showRefreshError(_('Could not refresh core status. Use Refresh to try again.'));
		return;
	}

	retryCount++;
	showRefreshError(_('Could not refresh core status. Retrying...'));
	retryTimer = window.setTimeout(function() {
		retryTimer = null;
		if (isAttached(viewRoot))
			refreshStatus();
	}, Math.min(30000, 1000 * Math.pow(2, retryCount)));
}

function refreshStatus() {
	if (!isAttached(viewRoot))
		return Promise.resolve();

	return Promise.resolve(callStatus()).then(function(status) {
		if (!status || status.ok === false)
			throw status || { code: 'rpc_unavailable' };

		/* 失败时保留最后一次成功状态 */
		statusState = status;
		cancelRetry();
		showRefreshError('');

		var core = statusState.core || {};
		setText('oxidns-core-installed', boolText(core.installed));
		setText('oxidns-core-version', core.version);
		setText('oxidns-core-bundle', core.bundle);
		setText('oxidns-core-target', core.target);
		setText('oxidns-core-binary', core.binary_path);
		setText('oxidns-core-persist', persistText(statusState));
		setText('oxidns-core-service', serviceRunning(statusState) ? _('Running') : _('Stopped'));

		if (isAttached(viewRoot))
			refreshActionButtons();
	}).catch(function(err) {
		scheduleStatusRetry();
		console.warn('oxidns core status refresh:', err);
	});
}

function coreErrorStageLabel(stage) {
	var labels = {
		prepare_download: _('Prepare download'),
		download_metadata: _('Download release metadata'),
		select_release_asset: _('Select release archive'),
		verify_release_digest: _('Verify release digest'),
		download_archive: _('Download core archive'),
		verify_checksum: _('Verify checksum'),
		validate_archive: _('Validate core archive'),
		unpack_archive: _('Unpack core archive'),
		install_files: _('Install core files'),
		restart_service: _('Restart service'),
		validate_uploaded_core: _('Validate uploaded core')
	};

	return labels[stage] || stage || '-';
}

function errorDetailLine(label, value, extraClass) {
	if (value === null || value === undefined || value === '')
		return null;

	return E('div', { 'class': extraClass || '' }, [
		E('strong', {}, [ label + ': ' ]),
		value
	]);
}

function renderCoreError(result) {
	/* 后端 English message 不直接显示：只显示本地化摘要 + 已本地化的阶段 */
	var message = backendMessage(result, _('Core operation failed'));
	var detail = result && (result.detail || result.details);
	var children = [
		E('p', {}, E('strong', {}, _('Core operation failed'))),
		E('p', {}, message)
	];

	if (result && result.stage) {
		var line = errorDetailLine(_('Stage'), coreErrorStageLabel(result.stage));
		if (line)
			children.push(line);
	}
	if (detail) {
		var detailLine = errorDetailLine(_('Details'), detail, 'small');
		if (detailLine)
			children.push(detailLine);
	}
	if (result && result.code) {
		var codeLine = errorDetailLine(_('Error code'), result.code, 'small');
		if (codeLine)
			children.push(codeLine);
	}

	return E('div', {}, children);
}

function replaceContent(node, content) {
	if (!node)
		return;

	while (node.firstChild)
		node.removeChild(node.firstChild);

	if (content === null || content === undefined)
		return;

	if (Array.isArray(content)) {
		for (var i = 0; i < content.length; i++)
			node.appendChild(content[i]);
	} else if (content.nodeType) {
		node.appendChild(content);
	} else {
		node.textContent = String(content);
	}
}

function scrollProgressLog(logNode) {
	if (logNode && isAttached(logNode))
		logNode.scrollTop = logNode.scrollHeight;
}

function showCoreProgressModal(label, onCancel) {
	var statusNode = E('p', {
		'id': 'oxidns-core-progress-status',
		'aria-live': 'polite'
	}, label);
	var logNode = E('pre', {
		'id': 'oxidns-core-progress-log',
		'aria-label': _('Command output'),
		'role': 'log',
		'style': [
			'box-sizing: border-box',
			'width: 100%',
			'min-height: 18em',
			'max-height: 44vh',
			'overflow: auto',
			'padding: 1em',
			'border: 1px solid #ccc',
			'background: #111',
			'color: #eee',
			'white-space: pre-wrap',
			'font-family: monospace',
			'font-size: 12px',
			'line-height: 1.45'
		].join(';')
	}, _('Waiting for command output...'));
	var resultNode = E('div', { 'id': 'oxidns-core-progress-result', 'aria-live': 'polite' });
	var cancelButton = E('button', {
		'type': 'button',
		'class': 'btn cbi-button cbi-button-negative',
		'click': function(ev) {
			ev.preventDefault();
			if (onCancel)
				onCancel();
		}
	}, _('Cancel'));
	var closeButton = E('button', {
		'type': 'button',
		'class': 'btn cbi-button cbi-button-neutral',
		'disabled': 'disabled',
		'click': function(ev) {
			ev.preventDefault();
			ui.hideModal();
		}
	}, _('Close'));

	ui.showModal(_('OxiDNS'), [
		statusNode,
		E('div', { 'class': 'cbi-value-title', 'style': 'margin-bottom: .35em;' }, _('Command output')),
		logNode,
		resultNode,
		E('div', { 'class': 'right', 'style': 'margin-top: 1em;' }, [
			cancelButton, ' ', closeButton
		])
	]);
	focusModal();

	return {
		status: statusNode,
		log: logNode,
		result: resultNode,
		cancelButton: cancelButton,
		closeButton: closeButton
	};
}

function setCoreProgressFinished(nodes, statusText, resultContent) {
	if (nodes && nodes.status)
		nodes.status.textContent = statusText;
	if (nodes && nodes.result)
		replaceContent(nodes.result, resultContent);
	if (nodes && nodes.cancelButton) {
		nodes.cancelButton.disabled = true;
		nodes.cancelButton.setAttribute('disabled', 'disabled');
	}
	if (nodes && nodes.closeButton) {
		nodes.closeButton.disabled = false;
		nodes.closeButton.removeAttribute('disabled');
	}
}

/*
 * core_progress 是全局共享的日志缓冲，后端没有 operation id 可供过滤。这里用
 * 客户端 token 丢弃属于上一次操作的回包，并只写仍挂载在文档里的节点；真正按
 * 操作隔离进度需要后端增加 id 参数（见最终报告的残余风险）。
 */
function refreshCoreProgressLog(logNode, token) {
	if (token !== progressState.generation || !isAttached(logNode))
		return Promise.resolve();

	return Promise.resolve(callCoreProgress()).then(function(result) {
		if (token !== progressState.generation || !isAttached(logNode))
			return;

		progressState.failures = 0;

		if (!result || result.ok === false)
			return;

		var text = result.text || _('Waiting for command output...');
		if (logNode.textContent !== text)
			logNode.textContent = text;
		scrollProgressLog(logNode);
	}).catch(function(err) {
		if (token !== progressState.generation)
			return;

		progressState.failures++;
		console.warn('oxidns core progress:', err);
	});
}

function stopCoreProgressPolling() {
	progressState.generation++;

	if (progressState.timer !== null) {
		window.clearTimeout(progressState.timer);
		progressState.timer = null;
	}
	progressState.failures = 0;
}

function scheduleProgressTick(logNode, token) {
	if (token !== progressState.generation)
		return;

	var delay = progressState.failures
		? Math.min(10000, 1000 * Math.pow(2, progressState.failures))
		: 1000;

	progressState.timer = window.setTimeout(function() {
		progressState.timer = null;
		if (token !== progressState.generation)
			return;

		refreshCoreProgressLog(logNode, token).then(function() {
			scheduleProgressTick(logNode, token);
		});
	}, delay);
}

function startCoreProgressPolling(logNode) {
	var token = ++progressState.generation;
	scheduleProgressTick(logNode, token);

	return {
		token: token,
		stop: function() { stopCoreProgressPolling(); },
		refresh: function() { return refreshCoreProgressLog(logNode, token); }
	};
}

function runCoreAction(label, desc, args, timeout) {
	var cancelReject = null;
	var cancelled = false;
	var nodes = showCoreProgressModal(label, function() {
		if (cancelled)
			return;

		cancelled = true;
		stopCoreProgressPolling();
		if (cancelReject)
			cancelReject({ code: 'operation_cancelled' });
		setCoreProgressFinished(nodes, _('Operation cancelled locally.'),
			E('p', {}, backendMessage({ code: 'operation_cancelled' })));
	});
	var progress = startCoreProgressPolling(nodes.log);
	activeOperation = progress.token;

	var cancelPromise = new Promise(function(resolve, reject) {
		cancelReject = reject;
	});

	var callPromise = callLongRpc(desc, args, timeout);

	return Promise.race([ callPromise, cancelPromise ]).then(function(result) {
		stopCoreProgressPolling();
		return progress.refresh().then(function() {
			if (!result || result.ok === false) {
				setCoreProgressFinished(nodes, _('Core operation failed'), renderCoreError(result || {}));
				return false;
			}

			return refreshStatus().then(function() {
				setCoreProgressFinished(nodes, _('Core operation completed.'),
					E('p', {}, _('Core operation completed.')));
				ui.addNotification(null, E('p', {}, _('Core operation completed.')), 'info');
				return true;
			});
		});
	}).catch(function(err) {
		stopCoreProgressPolling();
		return progress.refresh().then(function() {
			var message = backendMessage(err, _('Core operation failed'));
			var errorResult = err || {};

			if (err instanceof Error || (err && err.message && !err.code))
				errorResult = { code: err.code, detail: err.message };

			ui.addNotification(null, E('p', {}, message), 'danger');
			setCoreProgressFinished(nodes, _('Core operation failed'), renderCoreError(errorResult));
			return false;
		});
	}).then(function(ok) {
		if (activeOperation === progress.token)
			activeOperation = null;
		return ok;
	});
}

function handleCheckUpdate() {
	return Promise.resolve(callLongRpc(CORE_RPC.update_check, [], 120)).then(function(result) {
		if (!result || result.ok === false) {
			ui.addNotification(null, renderCoreError(result || {}), 'danger');
			return;
		}

		var rows = [
			renderRow(_('Current version'), result.current_version),
			renderRow(_('Latest version'), result.latest_version),
			renderRow(_('Repository'), result.repository),
			renderRow(_('Bundle'), result.bundle),
			renderRow(_('Target'), result.target),
			renderRow(_('Archive'), result.asset)
		];
		var buttons = [
			E('button', {
				'type': 'button',
				'class': 'btn cbi-button cbi-button-neutral',
				'click': function(ev) {
					ev.preventDefault();
					ui.hideModal();
				}
			}, _('Close'))
		];

		if (result.update_available) {
			buttons.push(' ');
			buttons.push(E('button', {
				'type': 'button',
				'class': 'btn cbi-button cbi-button-positive',
				'click': function(ev) {
					ev.preventDefault();
					ui.hideModal();
					return runCoreAction(_('Updating OxiDNS core...'), CORE_RPC.update, [], 300);
				}
			}, _('Update to %s').format(result.latest_version)));
		}

		ui.showModal(_('OxiDNS Core Update'), [
			E('p', {}, result.update_available
				? _('A new OxiDNS core release is available.')
				: _('The OxiDNS core is already up to date.')),
			E('div', { 'class': 'table cbi-section-table' }, rows),
			E('div', { 'class': 'right', 'style': 'margin-top: 1em;' }, buttons)
		]);
		focusModal();
	}).catch(function(err) {
		ui.addNotification(null, renderCoreError(err || {}), 'danger');
	});
}

function handleInstall() {
	return runCoreAction(_('Installing OxiDNS core...'), CORE_RPC.install, [], 300);
}

function handleReinstall() {
	return runCoreAction(_('Repair reinstalling OxiDNS core...'), CORE_RPC.reinstall, [], 300);
}

function handleUploadInstall() {
	var uploadPath = '/tmp/oxidns-core-upload-%d-%d'.format(Date.now(), Math.floor(Math.random() * 1000000));

	return ui.uploadFile(uploadPath).then(function() {
		return runCoreAction(_('Installing uploaded OxiDNS core...'), CORE_RPC.upload_install, [ uploadPath ], 300);
	}).catch(function(err) {
		if (err && err.message && err.message.indexOf(_('Upload has been cancelled')) >= 0)
			return;
		ui.addNotification(null, E('p', {}, backendMessage(err, _('Failed to install the uploaded core file.'))), 'danger');
	});
}

function checked(id) {
	var node = document.getElementById(id);
	return !!(node && node.checked);
}

function handleRemove() {
	return new Promise(function(resolve) {
		var configPath = statusState.config_path || '-';
		var workingDir = statusState.working_dir || '-';

		ui.showModal(_('Remove OxiDNS Core'), [
			E('p', {}, _('Remove the OxiDNS core binary and Web UI files.')),
			E('p', { 'class': 'cbi-section-descr' },
				_('Configuration and working directory data are preserved unless selected below.')),
			E('div', { 'class': 'cbi-section' }, [
				E('label', { 'class': 'cbi-value' }, [
					E('input', {
						'id': 'oxidns-remove-config',
						'type': 'checkbox',
						'style': 'margin-right: .5em;'
					}),
					_('Delete configuration file'),
					E('div', { 'class': 'cbi-value-description' }, configPath)
				]),
				E('label', { 'class': 'cbi-value' }, [
					E('input', {
						'id': 'oxidns-remove-workdir',
						'type': 'checkbox',
						'style': 'margin-right: .5em;'
					}),
					_('Delete working directory'),
					E('div', { 'class': 'cbi-value-description' }, workingDir)
				])
			]),
			E('div', { 'class': 'right' }, [
				E('button', {
					'type': 'button',
					'class': 'btn cbi-button cbi-button-neutral',
					'click': function(ev) {
						ev.preventDefault();
						ui.hideModal();
						resolve();
					}
				}, _('Cancel')),
				' ',
				E('button', {
					'type': 'button',
					'class': 'btn cbi-button cbi-button-negative',
					'click': function(ev) {
						ev.preventDefault();
						var removeConfig = checked('oxidns-remove-config');
						var removeWorkdir = checked('oxidns-remove-workdir');
						ui.hideModal();
						resolve(runCoreAction(_('Removing OxiDNS core...'), CORE_RPC.remove,
							[ removeConfig, removeWorkdir ], 300));
					}
				}, _('Confirm'))
			])
		]);
		focusModal();
	});
}

function actionButton(label, handler, style) {
	return E('button', {
		'type': 'button',
		'class': 'btn cbi-button cbi-button-%s'.format(style || 'neutral'),
		'click': function(ev) {
			ev.preventDefault();
			return handler();
		}
	}, label);
}

var actionStateKey = null;

function actionButtons(status) {
	if (coreInstalled(status)) {
		return [
			actionButton(_('Check Update'), handleCheckUpdate, 'action'),
			actionButton(_('Repair Reinstall'), handleReinstall, 'action'),
			actionButton(_('Upload Core'), handleUploadInstall, 'action'),
			actionButton(_('Remove Core'), handleRemove, 'negative')
		];
	}

	return [
		actionButton(_('Install Core'), handleInstall, 'positive'),
		actionButton(_('Upload Core'), handleUploadInstall, 'action')
	];
}

function refreshActionButtons() {
	var node = document.getElementById('oxidns-core-actions');
	if (!node)
		return;

	var key = coreInstalled(statusState) ? 'installed' : 'missing';
	if (key === actionStateKey)
		return;

	actionStateKey = key;
	replaceContent(node, actionButtons(statusState));
}

return view.extend({
	load: function() {
		return Promise.resolve(callStatus()).catch(function(err) {
			console.warn('oxidns core status load:', err);
			return { ok: false, code: 'rpc_unavailable' };
		});
	},

	render: function(status) {
		statusState = status || {};
		actionStateKey = coreInstalled(statusState) ? 'installed' : 'missing';

		addCleanup(stopCoreProgressPolling);
		addCleanup(cancelRetry);

		var core = statusState.core || {};
		var rows = [
			renderRow(_('Installed'), boolText(core.installed), 'oxidns-core-installed'),
			renderRow(_('Version'), core.version, 'oxidns-core-version'),
			renderRow(_('Bundle'), core.bundle, 'oxidns-core-bundle'),
			renderRow(_('Target'), core.target, 'oxidns-core-target'),
			renderRow(_('Binary path'), core.binary_path, 'oxidns-core-binary'),
			renderRow(_('Persistent storage'), persistText(statusState), 'oxidns-core-persist'),
			renderRow(_('Service status'), serviceRunning(statusState) ? _('Running') : _('Stopped'), 'oxidns-core-service')
		];

		var map = E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('OxiDNS Core')),
			E('div', { 'class': 'cbi-map-descr' },
				_('Install, repair or update the OxiDNS core binary. With persistent storage enabled the core is kept across firmware upgrades.')),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Core Status')),
				E('div', { 'class': 'table cbi-section-table' }, rows)
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Actions')),
				E('div', { 'class': 'cbi-section-descr' },
					_('LuCI can download the official OxiDNS release archive, install an uploaded .tar.gz archive or single oxidns binary, check for new releases and update the core in place.')),
				E('div', {
					'id': 'oxidns-core-actions',
					'class': 'cbi-button-row',
					'style': 'display: flex; flex-wrap: wrap; gap: .5em;'
				}, actionButtons(statusState)),
				E('button', {
					'type': 'button',
					'class': 'btn cbi-button cbi-button-neutral',
					'style': 'margin-top: .5em;',
					'click': function(ev) {
						ev.preventDefault();
						return refreshStatus();
					}
				}, _('Refresh'))
			]),
			E('div', {
				'id': 'oxidns-core-error',
				'class': 'alert-message error',
				'aria-live': 'polite',
				'style': 'margin-top: 1em; display: none;'
			})
		]);

		watchView(map);

		if (statusState.ok === false)
			showRefreshError(backendMessage(statusState, _('Could not refresh core status.')));

		return map;
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
