'use strict';
'require view';
'require form';
'require rpc';
'require poll';
'require ui';
'require dom';

const callSettings = rpc.declare({ object: 'luci.virtualhere', method: 'settings' });
const callStatus = rpc.declare({ object: 'luci.virtualhere', method: 'status' });
const callRead = rpc.declare({ object: 'luci.virtualhere', method: 'read_config' });
const callLogs = rpc.declare({ object: 'luci.virtualhere', method: 'logs' });
const callSaveSettings = rpc.declare({
	object: 'luci.virtualhere', method: 'save_settings',
	params: [ 'binary_path', 'config_path', 'enabled', 'apply' ]
});
const callWrite = rpc.declare({
	object: 'luci.virtualhere', method: 'write_config',
	params: [ 'path', 'content', 'original', 'exists', 'apply' ]
});
const callAction = rpc.declare({
	object: 'luci.virtualhere', method: 'action', params: [ 'action' ]
});

const errors = {
	invalid_path: _('Use an absolute file path without control characters or a trailing slash.'),
	binary_missing: _('The executable does not exist or is not a regular file.'),
	binary_empty: _('The executable is empty.'),
	binary_permission: _('The executable has no execution permission.'),
	service_unavailable: _('Unable to query the service manager.'),
	read_failed: _('Unable to read the configuration file or its directory.'),
	logs_failed: _('Unable to read the runtime log.'),
	not_regular: _('The configuration path is not a regular file.'),
	too_large: _('The configuration file must not exceed 16 KiB.'),
	not_text: _('The configuration file must be text without NUL characters.'),
	same_path: _('Use separate paths for the executable, server configuration and UCI settings.'),
	path_changed: _('The configuration path changed. Save basic settings and reload the file first.'),
	conflict: _('The file changed since it was read, possibly during service shutdown. Reload it before saving.'),
	stop_before_save: _('Stop the service before saving the file, or use Save & Apply.'),
	stop_failed: _('Unable to stop the service completely. Check the system log and retry.'),
	start_failed: _('Unable to start the service. Check the executable, configuration and system log.'),
	write_failed: _('Unable to write the configuration file.'),
	lock_failed: _('Unable to lock VirtualHere settings.'),
	settings_failed: _('Unable to save basic settings.'),
	autostart_failed: _('Settings were saved, but updating service autostart failed.'),
	invalid_action: _('Unsupported service action.'),
	config_invalid: _('The configuration file or directory is not readable and writable. Check the system log.')
};

function checked(reply) {
	if (reply.error) {
		let message = errors[reply.error] || reply.error;
		if (reply.saved)
			message += ' ' + _('Changes were saved, but applying the service settings failed.');
		if (reply.detail)
			message += ' ' + reply.detail;
		if (reply.restore_error)
			message += ' ' + _('Restoring the previous service also failed: %s').format(errors[reply.restore_error] || reply.restore_error);
		throw new Error(message);
	}
	return reply;
}

function loadStylesheet() {
	const id = 'virtualhere-view-stylesheet';
	if (document.getElementById(id))
		return;
	const link = E('link', { id, rel: 'stylesheet', href: L.resource('view/virtualhere/config.css') });
	document.head.appendChild(link);
}

return view.extend({
	load: function() {
		loadStylesheet();
		return Promise.all([
			callSettings(),
			L.resolveDefault(callStatus(), { error: 'service_unavailable' }),
			L.resolveDefault(callRead(), { error: 'read_failed' })
		]);
	},

	fileDirty: function() {
		return this.editor && this.file && !this.file.error && this.editor.value !== this.file.content;
	},

	settingsDirty: function() {
		return this.options && Object.keys(this.options).some(key =>
			this.options[key].formvalue('main') !== this.settings[key]);
	},

	showFile: function(file) {
		this.file = file;
		this.editor.value = file.content || '';
		this.editor.disabled = this.map.readonly || !!file.error;
		dom.content(this.filePath, file.path || this.settings.config_path);
		dom.content(this.fileHint, file.error ? (errors[file.error] || file.error) + (file.detail ? ' ' + file.detail : '') :
			file.exists ? _('The file is loaded. Use the buttons below to save its contents.') :
			_('The file does not exist. Enter contents and save to create it.'));
	},

	updateButtons: function() {
		const status = this.serviceStatus;
		const unavailable = !status || !!status.error;
		Object.keys(this.serviceButtons).forEach(action => {
			const item = this.serviceButtons[action];
			const disabled = this.busy || this.map.readonly || unavailable ||
				(action === 'start' && status.running) ||
				(action !== 'start' && !status.running);
			item.button.disabled = !!disabled;
			item.button.className = 'cbi-button ' + item.style;
		});
		Object.keys(this.fileButtons).forEach(action => {
			this.fileButtons[action].disabled = !!(this.busy ||
				(action !== 'reload' && (this.map.readonly || !this.file || this.file.error)));
		});
		this.editor.readOnly = !!(this.busy || this.map.readonly);
		if (this.logRefresh)
			this.logRefresh.disabled = !!(this.busy || this.logLoading);
		dom.content(this.controlHint, this.map.readonly ? _('Your account has read-only access. Service control is unavailable.') :
			this.busy && this.pendingAction === 'stop' ? _('Stopping VirtualHere; waiting for the process to exit…') :
			unavailable ? _('Unable to query the service manager.') :
			status.binary_error ? _('Install the server executable at the configured path and grant execution permission before starting.') :
			_('Service actions use saved settings without changing Enable. Save & Apply starts or stops the service according to Enable. The page footer saves basic settings only.'));
	},

	renderStatus: function(status) {
		if (status.error) {
			dom.content(this.statusNode, E('span', { 'class': 'label warning' }, errors[status.error] || status.error));
			return;
		}
		const enabled = status.enabled === '1';
		if (!enabled && !status.running) {
			dom.content(this.statusNode, [
				E('span', { 'class': 'label warning' }, _('Not enabled')),
				E('span', { 'class': 'virtualhere-status-meta' }, _('The service is not running'))
			]);
			return;
		}
		dom.content(this.statusNode, [
			E('span', { 'class': status.running ? 'label success' : 'label' },
				status.running ? (enabled ? _('Running') : _('Running (not enabled)')) : _('Stopped')),
			E('span', { 'class': 'virtualhere-status-meta' }, _('PID: %s').format(status.pids.length ? status.pids.join(', ') : '-'))
		]);
	},

	refreshStatus: function(force) {
		if (this.busy && !force)
			return Promise.resolve();
		const request = ++this.statusRequest;
		return callStatus().then(status => {
			if (request !== this.statusRequest)
				return;
			this.serviceStatus = status;
			this.renderStatus(status);
			if (status.error) {
				dom.content(this.checkNode, errors[status.error] || status.error);
				this.checkNode.style.color = '';
				return;
			}
			dom.content(this.checkNode, status.binary_error ? (errors[status.binary_error] || status.binary_error) + ' ' + this.settings.binary_path :
				_('File check passed: the executable exists, is non-empty and has execution permission. Architecture and startup are not verified.'));
			this.checkNode.style.color = status.binary_error ? 'red' : 'green';
		}).catch(error => {
			if (request !== this.statusRequest)
				return;
			this.serviceStatus = { error: 'service_unavailable' };
			this.renderStatus({ error: error.message });
			dom.content(this.checkNode, _('Unable to query the service manager.'));
			this.checkNode.style.color = '';
		}).finally(() => this.updateButtons());
	},

	logsVisible: function() {
		const tab = this.logNode && this.logNode.closest('[data-tab="logs"]');
		return !!tab && this.logNode.isConnected && tab.getAttribute('data-tab-active') === 'true' && !document.hidden;
	},

	refreshLogs: function() {
		if (this.busy || this.logLoading || !this.logsVisible())
			return Promise.resolve();
		this.logLoading = true;
		this.logRefresh.disabled = true;
		return callLogs().then(checked).then(reply => {
			if (typeof reply.content !== 'string')
				throw new Error(errors.logs_failed);
			// A hidden panel has no scroll geometry; refresh it on the next opening.
			if (!this.logsVisible())
				return;
			const follow = this.logContent === null ||
				this.logNode.scrollTop + this.logNode.clientHeight >= this.logNode.scrollHeight - 4;
			if (reply.content !== this.logContent) {
				const scrollTop = this.logNode.scrollTop;
				this.logContent = reply.content;
				this.logNode.value = reply.content || _('No VirtualHere log entries.');
				this.logNode.scrollTop = follow ? this.logNode.scrollHeight : scrollTop;
			}
			this.logHint.textContent = reply.truncated ? _('Only the most recent log entries are shown.') : '';
			this.logHint.classList.remove('warning');
		}).catch(() => {
			// Keep the last successful snapshot and leave settings/file edits alone.
			this.logHint.textContent = errors.logs_failed;
			this.logHint.classList.add('warning');
		}).finally(() => {
			this.logLoading = false;
			this.logRefresh.disabled = !!this.busy;
		});
	},

	finishOperation: function() {
		return this.refreshStatus(true).finally(() => {
			this.busy = false;
			this.pendingAction = null;
			this.updateButtons();
			return this.refreshLogs();
		});
	},

	reloadFile: function() {
		if (this.busy)
			return Promise.resolve();
		if (this.options.config_path.formvalue('main') !== this.settings.config_path)
			return Promise.reject(new Error(errors.path_changed));
		if (this.fileDirty() && !window.confirm(_('Discard unsaved file changes and reload?')))
			return Promise.resolve();
		this.busy = true;
		++this.statusRequest;
		this.updateButtons();
		return callRead().then(checked).then(file => this.showFile(file))
			.finally(() => this.finishOperation());
	},

	saveFile: function(apply) {
		if (this.busy || this.map.readonly)
			return Promise.resolve();
		if (!this.file || this.file.error)
			return Promise.reject(new Error(_('Load a readable configuration file before saving.')));
		if (this.options.config_path.formvalue('main') !== this.file.path)
			return Promise.reject(new Error(errors.path_changed));
		const content = this.editor.value;
		if (new TextEncoder().encode(content).length > 16384)
			return Promise.reject(new Error(errors.too_large));
		this.busy = true;
		++this.statusRequest;
		this.updateButtons();
		return callWrite(this.file.path, content, this.file.content, this.file.exists, apply)
			.then(reply => {
				if (reply.saved) {
					this.file.content = content;
					this.file.exists = true;
					dom.content(this.fileHint, _('The file is loaded. Use the buttons below to save its contents.'));
				}
				checked(reply);
				ui.addNotification(null, E('p', {}, _('Configuration file saved.')), 'info');
			}).finally(() => this.finishOperation());
	},

	saveSettings: function(apply) {
		if (this.busy || this.map.readonly)
			return Promise.resolve();
		const pathChanged = this.options.config_path.formvalue('main') !== this.settings.config_path;
		if (pathChanged && this.fileDirty())
			return Promise.reject(new Error(_('Save or discard file edits before changing the configuration path.')));
		this.busy = true;
		++this.statusRequest;
		this.updateButtons();
		// Parse only; keeping the existing DOM preserves unsaved file contents.
		return this.map.parse().then(() => {
			const data = this.map.data.get('json', 'main');
			return callSaveSettings(data.binary_path, data.config_path, data.enabled, apply);
		}).then(reply => callSettings().then(settings => {
			this.settings = checked(settings);
			const reload = pathChanged && (reply.saved || !reply.error) ?
				callRead().then(file => this.showFile(file)) : Promise.resolve();
			return reload.then(() => {
				checked(reply);
				ui.addNotification(null, E('p', {}, _('Basic settings saved.')), 'info');
			});
		})).finally(() => this.finishOperation());
	},

	serviceAction: function(action) {
		if (this.busy || this.map.readonly || this.serviceButtons[action].button.disabled)
			return Promise.resolve();
		this.busy = true;
		this.pendingAction = action;
		++this.statusRequest;
		this.updateButtons();
		return callAction(action).then(checked).finally(() => this.finishOperation());
	},

	render: function(data) {
		this.settings = checked(data[0]);
		this.map = new form.JSONMap({ main: Object.assign({}, this.settings) }, _('VirtualHere'),
			_('Manage a separately installed VirtualHere USB Server. Download the executable for your router from the official website.') + ' ' +
			'<a href="https://www.virtualhere.com/usb_server_software" target="_blank" rel="noopener noreferrer">' +
			_('VirtualHere official download page') + '</a>');
		this.map.readonly = !L.hasViewPermission();
		this.serviceButtons = {};
		this.fileButtons = {};
		this.serviceStatus = data[1];
		this.statusRequest = 0;
		this.busy = false;
		this.pendingAction = null;
		this.options = {};
		const s = this.map.section(form.NamedSection, 'main', 'main');
		s.addremove = false;
		s.tab('status', _('Status and actions'));
		s.tab('basic', _('Basic settings'));
		s.tab('file', _('Configuration file'));
		s.tab('logs', _('Runtime log'));

		let o = s.taboption('status', form.Flag, 'enabled', _('Enable'));
		o.default = '0';
		o.rmempty = false;
		this.options.enabled = o;
		for (const field of [
			[ 'binary_path', _('Executable path'), '/usr/bin/vhusbd' ],
			[ 'config_path', _('Configuration file path'), '/etc/vhusbd.conf' ]
		]) {
			o = s.taboption('basic', form.Value, field[0], field[1]);
			o.placeholder = field[2];
			o.rmempty = false;
			o.validate = (section, value) => /^\/[^\x00-\x1f\x7f]+$/.test(value) && !value.endsWith('/') ? true : errors.invalid_path;
			this.options[field[0]] = o;
		}
		this.statusNode = E('div');
		this.checkNode = E('span');
		o = s.taboption('status', form.DummyValue, '_status', _('Current status'));
		o.renderWidget = () => this.statusNode;
		o = s.taboption('status', form.DummyValue, '_check', _('Executable check'));
		o.renderWidget = () => this.checkNode;
		this.controlHint = E('div', { 'class': 'virtualhere-action-footer' });
		const controls = [];
		[
			[ 'start', _('Start'), 'cbi-button-apply' ],
			[ 'stop', _('Stop'), 'cbi-button-reset' ],
			[ 'restart', _('Restart'), 'cbi-button-reload' ]
		].forEach(action => {
			const button = E('button', {
				'class': 'cbi-button ' + action[2], type: 'button', disabled: true,
				click: () => this.serviceAction(action[0]).catch(error => {
					ui.addNotification(null, E('p', {}, error.message));
				})
			}, action[1]);
			this.serviceButtons[action[0]] = { button: button, style: action[2] };
			controls.push(button);
		});
		o = s.taboption('status', form.DummyValue, '_actions', _('Service control'));
		o.renderWidget = () => E('div', {}, [
			E('div', { 'class': 'virtualhere-action-group' }, controls), this.controlHint
		]);

		this.editor = E('textarea', {
			'class': 'cbi-input-textarea', rows: 24, style: 'width:100%;font-family:monospace',
			'aria-label': _('Configuration file contents'), spellcheck: 'false'
		});
		this.filePath = E('code');
		this.fileHint = E('p');
		const fileControls = [
			[ 'reload', _('Reload file'), 'cbi-button-action', () => this.reloadFile() ],
			[ 'save', _('Save file'), 'cbi-button-save', () => this.saveFile(false) ],
			[ 'apply', _('Save & Apply file'), 'cbi-button-apply', () => this.saveFile(true) ]
		].map(([action, label, style, handler]) => {
			const button = E('button', {
				'class': 'cbi-button ' + style, type: 'button',
				click: () => handler().catch(error => ui.addNotification(null, E('p', {}, error.message)))
			}, label);
			this.fileButtons[action] = button;
			return button;
		});
		o = s.taboption('file', form.DummyValue, '_editor', _('Configuration file contents'));
		o.renderWidget = () => E('div', {}, [
			this.filePath, this.fileHint,
			E('p', {}, _('VirtualHere writes its configuration while running. Save & Apply stops it before writing, then starts it only when Enable is saved as on. Save requires a stopped service.')),
			this.editor,
			E('div', { 'class': 'virtualhere-action-group' }, fileControls)
		]);
		this.logContent = null;
		this.logLoading = false;
		this.logNode = E('textarea', {
			'class': 'cbi-input-textarea', readonly: '', rows: 40, wrap: 'off',
			style: 'width:100%;font-family:monospace',
			'aria-label': _('Runtime log'), spellcheck: 'false'
		}, _('Logs have not been loaded.'));
		this.logHint = E('p', { 'role': 'status' });
		this.logRefresh = E('button', {
			'class': 'cbi-button cbi-button-reload', type: 'button', click: () => this.refreshLogs()
		}, _('Refresh'));
		o = s.taboption('logs', form.DummyValue, '_logs');
		o.renderWidget = () => E('div', { 'class': 'virtualhere-log-view' }, [
			E('p', {}, _('Shows the latest 200 log lines. Refreshes every 5 seconds while this tab is open.')),
			this.logNode, this.logHint,
			E('div', { 'class': 'virtualhere-action-group' }, this.logRefresh)
		]);
		this.showFile(data[2]);
		this.renderStatus(this.serviceStatus);
		this.updateButtons();
		window.addEventListener('beforeunload', event => {
			if (this.fileDirty() || this.settingsDirty()) {
				event.preventDefault();
				event.returnValue = '';
			}
		});
		poll.add(() => Promise.all([this.refreshStatus(), this.refreshLogs()]), 5);
		return this.map.render().then(node => {
			// Capture LuCI's non-bubbling event, including after a form reset.
			node.addEventListener('cbi-tab-active', event => {
				if (event.detail.tab === 'logs')
					this.refreshLogs();
			}, true);
			return this.refreshStatus().then(() => {
				// The restored active tab needs scroll geometry after insertion.
				window.requestAnimationFrame(() => this.refreshLogs());
				return node;
			});
		});
	},

	handleSave: function() { return this.saveSettings(false); },
	handleSaveApply: function() { return this.saveSettings(true); },
	handleReset: function() {
		if (this.busy)
			return Promise.resolve();
		if ((this.fileDirty() || this.settingsDirty()) && !window.confirm(_('Discard all unsaved changes?')))
			return Promise.resolve();
		Object.keys(this.options).forEach(key => this.map.data.set('json', 'main', key, this.settings[key]));
		this.showFile(this.file);
		return this.map.reset();
	}
});
