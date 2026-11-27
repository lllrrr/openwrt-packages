'use strict';
'require baseclass';
'require rpc';
'require ui';
'require view.oxidns.cmeditor as cmeditor';

var callConfigRead = rpc.declare({
	object: 'luci.oxidns',
	method: 'config_read',
	expect: {}
});

var callStatus = rpc.declare({
	object: 'luci.oxidns',
	method: 'status',
	expect: {}
});

var callConfigValidate = rpc.declare({
	object: 'luci.oxidns',
	method: 'config_validate',
	params: [ 'content' ],
	expect: {}
});

var callConfigSave = rpc.declare({
	object: 'luci.oxidns',
	method: 'config_save',
	params: [ 'content', 'base_mtime', 'restart' ],
	expect: {}
});

var BACKEND_ERRORS = {
	config_not_found: _('The configuration file was not found or is a symlink.'),
	config_too_large: _('The configuration file is too large to read.'),
	config_conflict: _('The configuration file changed on the device since it was loaded.'),
	config_invalid: _('The configuration is not valid.'),
	config_write_failed: _('The configuration could not be written.'),
	rpc_unavailable: _('The LuCI backend is unavailable.')
};

var configState = {};
var viewRoot = null;
var viewObserver = null;
var cleanupTasks = [];
var cleanupGeneration = 0;

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

function backendMessage(err, fallback) {
	var code = err && err.code;
	if (code && BACKEND_ERRORS[code])
		return BACKEND_ERRORS[code];
	return fallback || _('Operation failed');
}

function loadErrorMessage(err) {
	return backendMessage(err, _('Unable to load configuration.'));
}

function valueOrDash(value) {
	if (value === null || value === undefined || value === '')
		return '-';
	return value;
}

function coreInstalled(status) {
	return !!(status && status.core && status.core.installed);
}

function textareaValue() {
	var textarea = document.getElementById('oxidns-config-content');
	return textarea ? cmeditor.getValue(textarea) : '';
}

/* 简单 FNV-1a：后端只给 mtime，这里用内容指纹识别「本地是否改动」以及重载后内容是否变化 */
function contentHash(text) {
	var hash = 2166136261;
	var value = String(text === null || text === undefined ? '' : text);

	for (var i = 0; i < value.length; i++) {
		hash ^= value.charCodeAt(i);
		hash = (hash * 16777619) >>> 0;
	}

	return hash.toString(16);
}

function setStatus(message, danger) {
	var node = document.getElementById('oxidns-config-status');
	if (!node)
		return;
	node.textContent = message || '';
	node.className = danger ? 'alert-message error' : 'alert-message info';
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

function configTextarea(content) {
	var value = content || '';
	var textarea = E('textarea', {
		'id': 'oxidns-config-content',
		'class': 'cbi-input-textarea',
		'style': 'width: 100%; min-height: 420px; font-family: monospace;',
		'spellcheck': 'false'
	});

	textarea.defaultValue = value;
	textarea.value = value;

	addCleanup(function() {
		cmeditor.detach(textarea);
	});

	/* CodeMirror 挂载失败时保留普通 textarea；卸载视图时由上面的 cleanup 断开观察器 */
	cmeditor.load().then(function(ok) {
		if (ok && isAttached(textarea))
			cmeditor.defer(textarea, { mode: 'text/x-yaml' });
	}).catch(function(err) {
		console.warn('oxidns cmeditor load:', err);
	});

	return textarea;
}

function showBusy(label) {
	ui.showModal(_('OxiDNS'), [ E('p', {}, label) ]);
	focusModal();
}

function hideBusy() {
	ui.hideModal();
}

function applyLoadedConfig(result) {
	configState = result || {};
	var textarea = document.getElementById('oxidns-config-content');

	if (textarea) {
		var value = configState.content || '';
		cmeditor.setValue(textarea, value);
		textarea.defaultValue = value;
	}

	configState.contentHash = contentHash(configState.content);

	return value;
}

function hasLocalEdits() {
	return configState.contentHash != null &&
		contentHash(textareaValue()) !== configState.contentHash;
}

function reloadConfig() {
	return Promise.resolve(callConfigRead()).then(function(result) {
		if (!result || result.ok === false)
			throw result || { code: 'rpc_unavailable' };

		applyLoadedConfig(result);
		setStatus(_('Configuration reloaded from the device.'), false);
		return result;
	}).catch(function(err) {
		setStatus(backendMessage(err, _('Unable to load configuration.')), true);
		throw err;
	});
}

/* 冲突后只刷新 base_mtime，保留编辑器里的本地修改 */
function refreshConfigMetadata() {
	return Promise.resolve(callConfigRead()).then(function(result) {
		if (!result || result.ok === false)
			throw result || { code: 'rpc_unavailable' };

		configState.mtime = result.mtime;
		configState.path = result.path;
		return result;
	}).catch(function(err) {
		setStatus(backendMessage(err, _('Unable to load configuration.')), true);
		throw err;
	});
}

function showConflict() {
	var buttons = [
		E('button', {
			'type': 'button',
			'class': 'btn cbi-button cbi-button-neutral',
			'click': function(ev) {
				ev.preventDefault();
				ui.hideModal();
				reloadConfig().catch(function() {});
			}
		}, _('Reload from device')),
		' ',
		E('button', {
			'type': 'button',
			'class': 'btn cbi-button cbi-button-positive',
			'click': function(ev) {
				ev.preventDefault();
				ui.hideModal();
				var restart = checked('oxidns-config-restart');
				refreshConfigMetadata().then(function() {
					return saveYaml(restart, true);
				}).catch(function() {});
			}
		}, _('Reload and retry')),
		' ',
		E('button', {
			'type': 'button',
			'class': 'btn cbi-button cbi-button-neutral',
			'click': function(ev) {
				ev.preventDefault();
				ui.hideModal();
			}
		}, _('Close'))
	];

	var content = [
		E('p', {}, _('The configuration file changed on the device since it was loaded. Reloading discards local edits; reloading and retrying refreshes the base version and then saves the current editor content, overwriting the device changes.'))
	];

	if (hasLocalEdits())
		content.push(E('p', { 'class': 'alert-message warning' },
			_('You have local edits in the editor. Reloading from the device will discard them.')));

	content.push(E('div', { 'class': 'right', 'style': 'margin-top: 1em;' }, buttons));

	ui.showModal(_('Configuration changed'), content);
	focusModal();
}

function checked(id) {
	var node = document.getElementById(id);
	return !!(node && node.checked);
}

function runConfigCall(label, call, args, onSuccess) {
	showBusy(label);

	return Promise.resolve(call.apply(null, args || [])).then(function(result) {
		hideBusy();
		if (!result || result.ok === false) {
			setStatus(backendMessage(result, _('Operation failed')), true);

			if (result && result.code === 'config_conflict')
				showConflict();

			return false;
		}
		if (onSuccess)
			onSuccess(result);
		setStatus(result.message || _('Operation completed.'), false);
		return true;
	}).catch(function(err) {
		hideBusy();
		setStatus(backendMessage(err, _('Operation failed')), true);
		return false;
	});
}

function validateYaml() {
	return runConfigCall(_('Validating configuration...'), callConfigValidate, [
		textareaValue()
	]);
}

function saveYaml(restart, retried) {
	return runConfigCall(restart ? _('Saving and restarting service...') : _('Saving configuration...'), callConfigSave, [
		textareaValue(),
		configState.mtime,
		restart
	], function(result) {
		configState.mtime = result.mtime;
		configState.content = textareaValue();
		configState.contentHash = contentHash(configState.content);
		if (!retried)
			setStatus(result.message || _('Operation completed.'), false);
	});
}

return baseclass.extend({
	load: function() {
		var configPromise = Promise.resolve(callConfigRead()).then(function(config) {
			if (!config || config.ok === false)
				throw config || { code: 'rpc_unavailable' };

			config.contentHash = contentHash(config.content);
			return config;
		}).catch(function(err) {
			return {
				ok: false,
				code: err && err.code,
				message: loadErrorMessage(err)
			};
		});

		return Promise.all([
			configPromise,
			Promise.resolve(callStatus()).catch(function(err) {
				console.warn('oxidns status load:', err);
				return { ok: false, code: 'rpc_unavailable' };
			})
		]).then(function(results) {
			return {
				config: results[0],
				status: results[1] || {}
			};
		});
	},

	render: function(data) {
		beginRender();
		configState = data && data.config ? data.config : {};
		var statusState = data && data.status ? data.status : {};
		var readFailed = configState.ok === false;
		var configContent = configState.content || '';
		var configMessage = readFailed
			? (configState.message || _('Unable to load configuration.'))
			: '';

		if (readFailed && !coreInstalled(statusState)) {
			return E('div', { 'class': 'cbi-map' }, [
				E('h2', {}, _('OxiDNS Configuration')),
				E('div', { 'class': 'cbi-map-descr' },
					_('Edit, validate, and save the full OxiDNS YAML configuration file.')),
				E('div', { 'class': 'cbi-section' }, [
					E('div', { 'class': 'alert-message warning', 'style': 'margin: 1em 0;' },
						_('Install the OxiDNS core before editing the configuration.')),
					E('a', {
						'class': 'btn cbi-button cbi-button-action',
						'href': L.url('admin/services/oxidns/data') + '#core'
					}, _('Install Core'))
				])
			]);
		}

		var map = E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('OxiDNS Configuration')),
			E('div', { 'class': 'cbi-map-descr' },
				_('Edit, validate, and save the full OxiDNS YAML configuration file.')),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('YAML')),
				E('div', { 'class': 'table cbi-section-table' }, [
					E('div', { 'class': 'tr' }, [
						E('div', { 'class': 'td left', 'style': 'width: 240px' }, _('Path')),
						E('div', { 'class': 'td left' }, valueOrDash(configState.path))
					])
				]),
				readFailed ? E('div', {
					'class': 'alert-message warning',
					'style': 'margin: 1em 0;'
				}, configMessage) : '',
				configTextarea(configContent),
				E('label', { 'style': 'display: block; margin: .5em 0;' }, [
					E('input', {
						'id': 'oxidns-config-restart',
						'type': 'checkbox',
						'style': 'margin-right: .5em;'
					}),
					_('Restart OxiDNS after saving')
				]),
				E('div', {
					'class': 'cbi-button-row',
					'style': 'display: flex; flex-wrap: wrap; gap: .5em; margin-top: 1em;'
				}, [
					E('button', {
						'type': 'button',
						'class': 'btn cbi-button cbi-button-action',
						'click': function(ev) {
							ev.preventDefault();
							return validateYaml();
						}
					}, _('Validate')),
					E('button', {
						'type': 'button',
						'class': 'btn cbi-button cbi-button-positive',
						'click': function(ev) {
							ev.preventDefault();
							return saveYaml(checked('oxidns-config-restart'));
						}
					}, _('Save')),
					E('button', {
						'type': 'button',
						'class': 'btn cbi-button cbi-button-neutral',
						'click': function(ev) {
							ev.preventDefault();
							return reloadConfig().catch(function() {});
						}
					}, _('Reload from device')),
					E('button', {
						'type': 'button',
						'class': 'btn cbi-button cbi-button-action',
						'click': function(ev) {
							ev.preventDefault();
							return saveYaml(true);
						}
					}, _('Save & Restart'))
				]),
				E('div', {
					'id': 'oxidns-config-status',
					'aria-live': 'polite',
					'style': 'margin-top: 1em;'
				})
			])
		]);

		watchView(map);

		return map;
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
