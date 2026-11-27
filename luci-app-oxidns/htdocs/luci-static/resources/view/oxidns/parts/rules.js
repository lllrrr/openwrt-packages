'use strict';
'require baseclass';
'require rpc';
'require view.oxidns.tabs as tabs';
'require request';
'require ui';

var callRulesStatus = rpc.declare({
	object: 'luci.oxidns',
	method: 'rules_status',
	expect: {}
});

var callProgress = rpc.declare({
	object: 'luci.oxidns',
	method: 'core_progress',
	expect: {}
});

/* Long calls get their own HTTP timeout without touching L.env.rpctimeout */
var RULES_RPC = {
	check: { object: 'luci.oxidns', method: 'rules_check' },
	update: { object: 'luci.oxidns', method: 'rules_update' },
	restore: { object: 'luci.oxidns', method: 'rules_restore' }
};

var BACKEND_ERRORS = {
	rules_download_failed: _('Failed to download the rules archive.'),
	rules_save_failed: _('Failed to install the downloaded rules.'),
	rules_restore_failed: _('Failed to restore the bundled rules.'),
	rpc_unavailable: _('The LuCI backend is unavailable.'),
	operation_cancelled: _('The operation was cancelled in the browser. The device may still be working; check the status before retrying.')
};

var statusState = {};
var viewRoot = null;
var viewObserver = null;
var cleanupTasks = [];
var cleanupGeneration = 0;
var retryTimer = null;
var retryCount = 0;
var progressState = { generation: 0, timer: null, failures: 0, lastText: null, lastSig: '' };
var progressSession = null;
var progressPaused = false;
var fileSig = '';

function isAttached(node) {
	return !!(node && document.body && typeof document.body.contains === 'function' && document.body.contains(node));
}

/* 清理任务按实例代次标记：旧实例的 observer 回调即使晚到，也只会执行
 * 自己那一代的任务，不会连同新实例刚注册的任务一起清掉。 */
function beginRender() {
	if (viewRoot && !isAttached(viewRoot))
		runCleanup(cleanupGeneration);
	cleanupGeneration++;
}

function addCleanup(fn) {
	if (typeof fn !== 'function')
		return;

	for (var i = 0; i < cleanupTasks.length; i++) {
		if (cleanupTasks[i].fn === fn && cleanupTasks[i].generation === cleanupGeneration)
			return;
	}
	cleanupTasks.push({ 'fn': fn, 'generation': cleanupGeneration });
}

function runCleanup(generation) {
	var matched = [];
	var kept = [];

	for (var i = 0; i < cleanupTasks.length; i++) {
		if (generation == null || cleanupTasks[i].generation === generation)
			matched.push(cleanupTasks[i]);
		else
			kept.push(cleanupTasks[i]);
	}
	cleanupTasks = kept;

	for (var i = 0; i < matched.length; i++) {
		try { matched[i].fn(); } catch (e) {}
	}
}

function watchView(root) {
	viewRoot = root || null;
	var observedRoot = viewRoot;
	var observedGeneration = cleanupGeneration;

	if (viewObserver) {
		try { viewObserver.disconnect(); } catch (e) {}
		viewObserver = null;
	}

	var vp = document.getElementById('view');
	if (!vp || typeof MutationObserver !== 'function')
		return;

	viewObserver = new MutationObserver(function() {
		if (!isAttached(observedRoot)) {
			try { viewObserver.disconnect(); } catch (e) {}
			viewObserver = null;
			runCleanup(observedGeneration);
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
	var node = document.getElementById('oxidns-rules-error');
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

function callLongRpc(desc, seconds) {
	var params = {};

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

function formatBytes(bytes) {
	var size = parseInt(bytes, 10) || 0;
	if (size <= 0)
		return '-';
	if (size < 1024)
		return '%d B'.format(size);
	if (size < 1048576)
		return '%.1f KiB'.format(size / 1024);
	return '%.1f MiB'.format(size / 1048576);
}

function renderRow(label, value, id) {
	var valueAttrs = { 'class': 'td left' };
	if (id)
		valueAttrs.id = id;

	return E('div', { 'class': 'tr' }, [
		E('div', { 'class': 'td left', 'style': 'width: 33%' }, label),
		E('div', valueAttrs, valueOrDash(value))
	]);
}

function renderRulesError(result) {
	var message = backendMessage(result, _('Rule operation failed'));
	var detail = result && (result.detail || result.details);
	var children = [
		E('p', {}, E('strong', {}, _('Rule operation failed'))),
		E('p', {}, message)
	];

	if (detail)
		children.push(E('p', { 'class': 'small' }, detail));
	if (result && result.code)
		children.push(E('p', { 'class': 'small' }, _('Error code') + ': ' + result.code));

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

function showProgressModal(label, onCancel) {
	var statusNode = E('p', { 'aria-live': 'polite' }, label);
	var logNode = E('pre', {
		'aria-label': _('Command output'),
		'role': 'log',
		'style': [
			'box-sizing: border-box',
			'width: 100%',
			'min-height: 16em',
			'max-height: 40vh',
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
	var resultNode = E('div', { 'aria-live': 'polite' });
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

	return { status: statusNode, log: logNode, result: resultNode, cancelButton: cancelButton, closeButton: closeButton };
}

function finishProgress(nodes, statusText, resultContent) {
	if (nodes.status)
		nodes.status.textContent = statusText;
	replaceContent(nodes.result, resultContent);
	if (nodes.cancelButton) {
		nodes.cancelButton.disabled = true;
		nodes.cancelButton.setAttribute('disabled', 'disabled');
	}
	if (nodes.closeButton) {
		nodes.closeButton.disabled = false;
		nodes.closeButton.removeAttribute('disabled');
	}
}

/*
 * core_progress 是共享缓冲，后端没有 operation id；客户端 token 用来丢弃旧操作
 * 的回包，并只更新仍挂载的节点。按操作隔离需要后端扩展（见残余风险）。
 */
function refreshProgressLog(logNode, token) {
	if (token !== progressState.generation || !isAttached(logNode))
		return Promise.resolve();

	return Promise.resolve(callProgress()).then(function(result) {
		if (token !== progressState.generation || !isAttached(logNode))
			return;

		progressState.failures = 0;

		if (!result || result.ok === false)
			return;

		var text = result.text || _('Waiting for command output...');
		if (text === progressState.lastText)
			return;

		progressState.lastText = text;
		logNode.textContent = text;
		logNode.scrollTop = logNode.scrollHeight;
	}).catch(function(err) {
		if (token !== progressState.generation)
			return;

		progressState.failures++;
		console.warn('oxidns rules progress:', err);
	});
}

function stopProgressPolling() {
	progressState.generation++;

	if (progressState.timer !== null) {
		window.clearTimeout(progressState.timer);
		progressState.timer = null;
	}
	progressState.failures = 0;
	progressSession = null;
	progressPaused = false;
}

function pauseProgressPolling() {
	progressPaused = true;
	if (progressState.timer !== null) {
		window.clearTimeout(progressState.timer);
		progressState.timer = null;
	}
}

function resumeProgressPolling() {
	if (!progressSession || progressSession.token !== progressState.generation)
		return;

	progressPaused = false;
	scheduleProgressTick(progressSession.logNode, progressSession.token);
}

function scheduleProgressTick(logNode, token) {
	if (progressPaused || token !== progressState.generation)
		return;

	var delay = progressState.failures
		? Math.min(10000, 1000 * Math.pow(2, progressState.failures))
		: 1000;

	if (progressState.timer !== null)
		window.clearTimeout(progressState.timer);
	progressState.timer = window.setTimeout(function() {
		progressState.timer = null;
		if (token !== progressState.generation)
			return;

		refreshProgressLog(logNode, token).then(function() {
			scheduleProgressTick(logNode, token);
		});
	}, delay);
}

function startProgressPolling(logNode) {
	progressState.lastText = null;
	var token = ++progressState.generation;
	progressPaused = false;
	progressSession = { 'logNode': logNode, 'token': token };
	scheduleProgressTick(logNode, token);

	return {
		token: token,
		stop: function() { stopProgressPolling(); },
		refresh: function() { return refreshProgressLog(logNode, token); }
	};
}

function runRulesAction(label, desc, seconds) {
	var cancelReject = null;
	var cancelled = false;
	var nodes = showProgressModal(label, function() {
		if (cancelled)
			return;

		cancelled = true;
		stopProgressPolling();
		if (cancelReject)
			cancelReject({ code: 'operation_cancelled' });
		finishProgress(nodes, _('Operation cancelled locally.'),
			E('p', {}, backendMessage({ code: 'operation_cancelled' })));
	});
	var progress = startProgressPolling(nodes.log);

	var cancelPromise = new Promise(function(resolve, reject) {
		cancelReject = reject;
	});
	var callPromise = callLongRpc(desc, seconds);

	return Promise.race([ callPromise, cancelPromise ]).then(function(result) {
		stopProgressPolling();
		return progress.refresh().then(function() {
			if (!result || result.ok === false) {
				finishProgress(nodes, _('Rule operation failed'), renderRulesError(result || {}));
				return false;
			}

			finishProgress(nodes, _('Rule operation completed.'), E('p', {}, _('Rule operation completed.')));
			ui.addNotification(null, E('p', {}, _('Rule operation completed.')), 'info');
			return loadStatus().then(function() { return true; });
		});
	}).catch(function(err) {
		stopProgressPolling();
		return progress.refresh().then(function() {
			var errorResult = err && err.code ? err : { detail: (err && err.message) || String(err) };
			finishProgress(nodes, _('Rule operation failed'), renderRulesError(errorResult));
			return false;
		});
	});
}

function scheduleStatusRetry() {
	cancelRetry();
	if (retryCount >= 4) {
		showRefreshError(_('Could not refresh rule status. Use Refresh to try again.'));
		return;
	}

	retryCount++;
	showRefreshError(_('Could not refresh rule status. Retrying...'));
	retryTimer = window.setTimeout(function() {
		retryTimer = null;
		if (tabs.isActive(viewRoot))
			loadStatus();
	}, Math.min(30000, 1000 * Math.pow(2, retryCount)));
}

function loadStatus() {
	if (!tabs.isActive(viewRoot))
		return Promise.resolve();

	return Promise.resolve(callRulesStatus()).then(function(status) {
		if (!status || status.ok === false)
			throw status || { code: 'rpc_unavailable' };

		/* 失败时保留最后一次成功状态 */
		statusState = status;
		cancelRetry();
		showRefreshError('');
		renderStatus();
	}).catch(function(err) {
		scheduleStatusRetry();
		console.warn('oxidns rules status refresh:', err);
	});
}

function setCellText(id, value) {
	var node = document.getElementById(id);
	if (!node)
		return;

	var text = valueOrDash(value);
	if (node.textContent !== text)
		node.textContent = text;
}

/* 值没变时不触碰 DOM，避免轮询把整张状态表重建 */
function renderStatus() {
	setCellText('oxidns-rules-installed', statusState.installed_version);
	setCellText('oxidns-rules-baseline', statusState.baseline_version);
	setCellText('oxidns-rules-repository', statusState.repository);
	setCellText('oxidns-rules-dir', statusState.rules_dir);

	var files = (statusState && statusState.files) || [];
	var sig = JSON.stringify(files);
	if (sig === fileSig)
		return;

	fileSig = sig;
	var body = document.getElementById('oxidns-rules-files');
	if (body)
		replaceContent(body, renderFileRows());
}

function stateText(file) {
	if (!file || !file.present)
		return _('Missing');
	if (file.matches_baseline)
		return _('Bundled');
	return _('Local copy');
}

function renderFileRows() {
	var files = (statusState && statusState.files) || [];
	var rows = [
		E('div', { 'class': 'tr table-titles' }, [
			E('div', { 'class': 'th' }, _('File')),
			E('div', { 'class': 'th' }, _('Lines')),
			E('div', { 'class': 'th' }, _('Size')),
			E('div', { 'class': 'th' }, _('State'))
		])
	];

	for (var i = 0; i < files.length; i++) {
		var file = files[i];
		rows.push(E('div', { 'class': 'tr' }, [
			E('div', { 'class': 'td left' }, file.name),
			E('div', { 'class': 'td' }, valueOrDash(file.lines)),
			E('div', { 'class': 'td' }, formatBytes(file.bytes)),
			E('div', { 'class': 'td' }, stateText(file))
		]));
	}

	if (!files.length)
		rows.push(E('div', { 'class': 'tr' }, [
			E('div', { 'class': 'td', 'colspan': 4 }, '-')
		]));

	return rows;
}

function handleCheck() {
	return Promise.resolve(callLongRpc(RULES_RPC.check, 300)).then(function(result) {
		if (!result || result.ok === false) {
			ui.addNotification(null, renderRulesError(result || {}), 'danger');
			return;
		}

		var rows = [
			renderRow(_('Installed version'), result.current_version),
			renderRow(_('Latest version'), result.latest_version),
			renderRow(_('Baseline version'), result.baseline_version),
			renderRow(_('Release asset'), result.asset)
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
					return runRulesAction(_('Updating rule subscriptions...'), RULES_RPC.update, 600);
				}
			}, _('Update now')));
		}

		ui.showModal(_('Rule Subscriptions'), [
			E('div', { 'class': 'table cbi-section-table' }, rows),
			E('p', {}, result.update_available ? _('Rule update available.') : _('No rule update available.')),
			E('div', { 'class': 'right', 'style': 'margin-top: 1em;' }, buttons)
		]);
		focusModal();
	}).catch(function(err) {
		ui.addNotification(null, renderRulesError(err || {}), 'danger');
	});
}

function handleRestore() {
	return new Promise(function(resolve) {
		ui.showModal(_('Restore baseline'), [
			E('p', {}, _('This overwrites every rule file in the working copy with the bundled baseline.')),
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
						ui.hideModal();
						resolve(runRulesAction(_('Restoring rules from the bundled baseline...'), RULES_RPC.restore, 300));
					}
				}, _('Confirm'))
			])
		]);
		focusModal();
	});
}

function renderStatusRows() {
	return [
		renderRow(_('Installed version'), statusState.installed_version, 'oxidns-rules-installed'),
		renderRow(_('Baseline version'), statusState.baseline_version, 'oxidns-rules-baseline'),
		renderRow(_('Repository'), statusState.repository, 'oxidns-rules-repository'),
		renderRow(_('Working copy'), statusState.rules_dir, 'oxidns-rules-dir')
	];
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

function updateNow() {
	return new Promise(function(resolve) {
		ui.showModal(_('Update rules now'), [
			E('p', {}, _('Download and install the latest rule subscription now?')),
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
					'class': 'btn cbi-button cbi-button-positive',
					'click': function(ev) {
						ev.preventDefault();
						ui.hideModal();
						resolve(runRulesAction(_('Updating rule subscriptions...'), RULES_RPC.update, 600));
					}
				}, _('Confirm'))
			])
		]);
		focusModal();
	});
}

return baseclass.extend({
	load: function() {
		return Promise.resolve(callRulesStatus()).catch(function(err) {
			console.warn('oxidns rules status load:', err);
			return { ok: false, code: 'rpc_unavailable' };
		});
	},

	render: function(status) {
		beginRender();
		statusState = status || {};
		fileSig = JSON.stringify((statusState && statusState.files) || []);

		addCleanup(stopProgressPolling);
		addCleanup(cancelRetry);

		var map = E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('Rule Subscriptions')),
			E('div', { 'class': 'cbi-map-descr' },
				_('Domain lists used for China/ad split and ad blocking. The working copy is seeded from the bundled baseline at boot and can be updated from a published release.')),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Versions')),
				E('div', { 'class': 'table cbi-section-table', 'id': 'oxidns-rules-summary' },
					renderStatusRows())
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Actions')),
				E('div', { 'class': 'cbi-section-descr' },
					_('Updates are downloaded from the repository release, verified with SHA256 and validated with oxidns check before they replace the working copy. Restoring the baseline works offline.')),
				E('div', { 'class': 'cbi-button-row', 'style': 'display: flex; flex-wrap: wrap; gap: .5em;' }, [
					actionButton(_('Check for updates'), handleCheck, 'action'),
					actionButton(_('Update now'), updateNow, 'positive'),
					actionButton(_('Restore baseline'), handleRestore, 'neutral'),
					actionButton(_('Refresh'), loadStatus, 'neutral')
				])
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Rule files')),
				E('div', { 'class': 'table cbi-section-table', 'id': 'oxidns-rules-files' },
					renderFileRows())
			]),
			E('div', {
				'id': 'oxidns-rules-error',
				'class': 'alert-message error',
				'aria-live': 'polite',
				'style': 'margin-top: 1em; display: none;'
			})
		]);

		watchView(map);

		window.setTimeout(function() {
			if (!tabs.isActive(viewRoot))
				return;

			var unwatch = tabs.watchActivation(viewRoot, resumeProgressPolling,
				pauseProgressPolling);
			addCleanup(unwatch);
		}, 0);

		if (statusState.ok === false)
			showRefreshError(backendMessage(statusState, _('Could not refresh rule status.')));

		return map;
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
