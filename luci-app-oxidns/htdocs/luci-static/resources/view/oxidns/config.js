'use strict';
'require view';
'require rpc';
'require ui';

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

var configState = {};

/*
 * 结果面板状态：
 *   content    - 上一次校验 / 保存所对应的编辑器内容快照
 *   resultKind - 当前结果面板的类型（success / warning / error / notice）
 *   buttons    - 三个操作按钮，操作期间统一禁用
 */
var editorState = {
	content: null,
	resultKind: null,
	buttons: []
};

function loadErrorMessage(err) {
	if (err && (err.message || err.error))
		return err.message || err.error;
	return _('Unable to load configuration.');
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
	return textarea ? textarea.value : '';
}

/* 去掉命令输出里的 ANSI 转义，避免终端色彩在页面上变成乱码 */
function plainText(value) {
	return String(value === null || value === undefined ? '' : value)
		.replace(/\u001b\[[0-9;]*[A-Za-z]/g, '')
		.replace(/[ \t]+$/gm, '')
		.replace(/\s+$/, '');
}

function ensureVisible(node) {
	if (!node || !node.getBoundingClientRect)
		return;

	var rect = node.getBoundingClientRect();
	var viewport = window.innerHeight || document.documentElement.clientHeight || 0;

	if (viewport && (rect.bottom > viewport || rect.top < 0))
		node.scrollIntoView({ 'behavior': 'smooth', 'block': 'nearest' });
}

/*
 * 在按钮下方渲染一块醒目的结果面板。
 * 标题行始终显示校验 / 保存的结论，详细输出（可能是多行）放进 <pre> 原样保留换行。
 */
function renderResult(kind, title, detail) {
	var container = document.getElementById('oxidns-config-status');
	if (!container)
		return;

	while (container.firstChild)
		container.removeChild(container.firstChild);

	var output = plainText(detail);

	/* 后端的默认文案与标题重复时不再重复一遍 */
	if (output && output.toLowerCase() === String(title).toLowerCase())
		output = '';

	var panel = E('div', {
		'class': 'alert-message ' + kind,
		'style': 'margin: .75em 0 0; overflow-wrap: break-word;'
	}, [
		E('h4', {}, title),
		output ? E('pre', {
			'style': 'margin: .35em 0 0; padding: .5em; max-height: 18em; overflow: auto; white-space: pre-wrap; word-break: break-word; font-size: 12px; line-height: 1.45; background: rgba(0, 0, 0, .06); border: 1px solid rgba(0, 0, 0, .12); border-radius: 3px;'
		}, output) : ''
	]);

	container.appendChild(panel);
	editorState.resultKind = kind;

	window.setTimeout(function() {
		ensureVisible(panel);
	}, 0);
}

/* 页面顶部横幅，滚动到别处时也能看见结论 */
function notifyResult(kind, message) {
	if (!message)
		return;

	ui.addTimeLimitedNotification(null, E('p', {}, message), 6000, kind === 'error' ? 'danger' : kind);
}

function setBusy(activeButton, busy) {
	editorState.buttons.forEach(function(button) {
		button.disabled = busy;
		if (busy && button === activeButton)
			button.classList.add('spinning');
		else
			button.classList.remove('spinning');
	});
}

function runConfigCall(button, busyText, call, args) {
	setBusy(button, true);
	renderResult('notice', busyText);

	/* 直接接住 RPC 抛出的错误，L.resolveDefault() 会把失败吞成 null，错误文案就丢了 */
	return Promise.resolve().then(function() {
		return call.apply(null, args || []);
	}).catch(function(err) {
		return {
			ok: false,
			code: 'rpc_error',
			message: (err && err.message) || String(err)
		};
	}).then(function(result) {
		setBusy(button, false);
		return result;
	});
}

function validateYaml(button) {
	var content = textareaValue();

	return runConfigCall(button, _('Validating configuration...'), callConfigValidate, [
		content
	]).then(function(result) {
		if (!result || result.ok === false) {
			renderResult('error', _('Validation failed'), result && (result.message || result.error));
			notifyResult('error', _('Validation failed'));
			return;
		}

		editorState.content = content;
		renderResult('success', _('Configuration is valid'), result.message);
		notifyResult('success', _('Configuration is valid'));
	});
}

function saveYaml(button, restart) {
	var content = textareaValue();

	return runConfigCall(button, restart ? _('Saving and restarting service...') : _('Saving configuration...'), callConfigSave, [
		content,
		configState.mtime,
		restart
	]).then(function(result) {
		var code = result && result.code;
		var message = result && (result.message || result.error);

		if (result && result.ok === false) {
			/* 文件其实已经写进去了，只是服务没起来：不能只报一个红色错误 */
			if (code === 'service_unavailable' || code === 'service_restart_failed') {
				editorState.content = content;
				renderResult('warning', _('Saved, but the service did not restart'), message);
				notifyResult('warning', _('Saved, but the service did not restart'));
				return;
			}

			renderResult('error', _('Save failed'), message);
			notifyResult('error', _('Save failed'));
			return;
		}

		if (result)
			configState.mtime = result.mtime;

		editorState.content = content;

		if (restart) {
			renderResult('success', _('Configuration saved and service restarted'), message);
			notifyResult('success', _('Configuration saved and service restarted'));
			return;
		}

		renderResult('warning', _('Saved, but not applied to the running service'),
			_('The running service still uses the previous configuration. Use Save & Restart to apply the changes.'));
		notifyResult('warning', _('Saved, but not applied to the running service'));
	});
}

/* 校验通过之后又改了内容：旧结论不再代表当前内容，降级为提示 */
function handleEditorInput() {
	if (editorState.content === null || editorState.resultKind !== 'success')
		return;
	if (textareaValue() === editorState.content)
		return;

	renderResult('notice', _('The content changed since it was last checked'));
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
	textarea.addEventListener('input', handleEditorInput);
	return textarea;
}

return view.extend({
	load: function() {
		var configPromise = L.resolveDefault(callConfigRead(), null).then(function(config) {
			return config || {
				ok: false,
				message: _('Unable to load configuration.')
			};
		}).catch(function(err) {
			return {
				ok: false,
				message: loadErrorMessage(err)
			};
		});

		return Promise.all([
			configPromise,
			L.resolveDefault(callStatus(), {})
		]).then(function(results) {
			return {
				config: results[0],
				status: results[1] || {}
			};
		});
	},

	render: function(data) {
		configState = data && data.config ? data.config : {};
		var statusState = data && data.status ? data.status : {};
		var readFailed = configState.ok === false;
		var configContent = configState.content || '';
		var configMessage = readFailed
			? (configState.message || _('Unable to load configuration.'))
			: '';

		editorState.content = null;
		editorState.resultKind = null;

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
						'href': L.url('admin/services/oxidns/core')
					}, _('Install Core'))
				])
			]);
		}

		var buttons = [
			E('button', {
				'class': 'btn cbi-button cbi-button-action',
				'click': function(ev) {
					ev.preventDefault();
					return validateYaml(ev.currentTarget);
				}
			}, _('Validate')),
			E('button', {
				'class': 'btn cbi-button cbi-button-positive',
				'click': function(ev) {
					ev.preventDefault();
					return saveYaml(ev.currentTarget, false);
				}
			}, _('Save')),
			E('button', {
				'class': 'btn cbi-button cbi-button-action',
				'click': function(ev) {
					ev.preventDefault();
					return saveYaml(ev.currentTarget, true);
				}
			}, _('Save & Restart'))
		];

		editorState.buttons = buttons;

		return E('div', { 'class': 'cbi-map' }, [
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
				E('div', {
					'class': 'cbi-button-row',
					'style': 'display: flex; flex-wrap: wrap; gap: .5em; margin-top: 1em;'
				}, buttons),
				E('div', { 'id': 'oxidns-config-status' })
			])
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
