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
const callSaveSettings = rpc.declare({
	object: 'luci.virtualhere', method: 'save_settings',
	params: [ 'binary_path', 'config_path', 'autostart', 'apply' ]
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
			message += ' ' + _('The file was saved, but restoring the service failed.');
		if (reply.detail)
			message += ' ' + reply.detail;
		throw new Error(message);
	}
	return reply;
}

return view.extend({
	load: function() {
		return Promise.all([ callSettings(), callStatus(), callRead() ]);
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
				(action === 'stop' && !status.active) ||
				(action !== 'stop' && !!status.binary_error);
			item.button.disabled = !!disabled;
			item.button.className = 'btn cbi-button' + (disabled ? '' : ' ' + item.style);
		});
		dom.content(this.controlHint, this.map.readonly ? _('Your account has read-only access. Service control is unavailable.') :
			unavailable ? _('Unable to query the service manager.') :
			status.binary_error ? _('Install the server executable at the configured path and grant execution permission before starting.') :
			_('Service actions use saved settings. The page footer saves basic settings only.'));
	},

	refreshStatus: function() {
		const request = ++this.statusRequest;
		return callStatus().then(status => {
			if (request !== this.statusRequest)
				return;
			this.serviceStatus = status;
			dom.content(this.statusNode, status.error ? errors[status.error] || status.error :
				status.running ? _('Running') : status.active ? _('Not running (service is registered)') : _('Stopped'));
			this.statusNode.style.color = status.error ? '' : status.running ? 'green' : 'red';
			dom.content(this.checkNode, status.binary_error ? (errors[status.binary_error] || status.binary_error) + ' ' + this.settings.binary_path :
				_('File check passed: the executable exists, is non-empty and has execution permission. Architecture and startup are not verified.'));
			this.checkNode.style.color = status.binary_error ? 'red' : 'green';
		}).catch(error => {
			if (request !== this.statusRequest)
				return;
			this.serviceStatus = { error: 'service_unavailable' };
			dom.content(this.statusNode, error.message);
			this.statusNode.style.color = '';
			dom.content(this.checkNode, _('Unable to query the service manager.'));
			this.checkNode.style.color = '';
		}).finally(() => this.updateButtons());
	},

	reloadFile: function() {
		if (this.options.config_path.formvalue('main') !== this.settings.config_path)
			return Promise.reject(new Error(errors.path_changed));
		if (this.fileDirty() && !window.confirm(_('Discard unsaved file changes and reload?')))
			return Promise.resolve();
		return callRead().then(checked).then(file => this.showFile(file));
	},

	saveFile: function(apply) {
		if (!this.file || this.file.error)
			return Promise.reject(new Error(_('Load a readable configuration file before saving.')));
		if (this.options.config_path.formvalue('main') !== this.file.path)
			return Promise.reject(new Error(errors.path_changed));
		const content = this.editor.value;
		if (new TextEncoder().encode(content).length > 16384)
			return Promise.reject(new Error(errors.too_large));
		return callWrite(this.file.path, content, this.file.content, this.file.exists, apply)
			.then(reply => {
				if (reply.saved) {
					this.file.content = content;
					this.file.exists = true;
					dom.content(this.fileHint, _('The file is loaded. Use the buttons below to save its contents.'));
				}
				checked(reply);
				ui.addNotification(null, E('p', {}, _('Configuration file saved.')), 'info');
				return this.refreshStatus();
			});
	},

	saveSettings: function(apply) {
		const pathChanged = this.options.config_path.formvalue('main') !== this.settings.config_path;
		if (pathChanged && this.fileDirty())
			return Promise.reject(new Error(_('Save or discard file edits before changing the configuration path.')));
		// Parse only; keeping the existing DOM preserves unsaved file contents.
		return this.map.parse().then(() => {
			const data = this.map.data.get('json', 'main');
			return callSaveSettings(data.binary_path, data.config_path, data.autostart, apply);
		}).then(checked).then(() => callSettings()).then(settings => {
			this.settings = settings;
			ui.addNotification(null, E('p', {}, _('Basic settings saved.')), 'info');
			return pathChanged ? callRead().then(file => this.showFile(file)) : null;
		}).then(() => this.refreshStatus());
	},

	serviceAction: function(action) {
		if (this.busy || this.map.readonly || this.serviceButtons[action].button.disabled)
			return Promise.resolve();
		if (this.settingsDirty() || this.fileDirty())
			return Promise.reject(new Error(_('Save or discard pending edits before controlling the service.')));
		this.busy = true;
		++this.statusRequest;
		this.updateButtons();
		return callAction(action).then(checked).finally(() => this.refreshStatus().finally(() => {
			this.busy = false;
			this.updateButtons();
		}));
	},

	render: function(data) {
		this.settings = checked(data[0]);
		this.map = new form.JSONMap({ main: Object.assign({}, this.settings) }, _('VirtualHere'),
			_('Manage a separately installed VirtualHere USB Server. Download the executable for your router from the official website.') + ' ' +
			'<a href="https://www.virtualhere.com/usb_server_software" target="_blank" rel="noopener noreferrer">' +
			_('VirtualHere official download page') + '</a>');
		this.map.readonly = !L.hasViewPermission();
		this.serviceButtons = {};
		this.serviceStatus = null;
		this.statusRequest = 0;
		this.busy = false;
		this.options = {};
		const s = this.map.section(form.NamedSection, 'main', 'main');
		s.addremove = false;
		s.tab('basic', _('Basic settings'));
		s.tab('file', _('Configuration file'));

		let o = s.taboption('basic', form.Flag, 'autostart', _('Start on boot'));
		o.default = '0';
		o.rmempty = false;
		this.options.autostart = o;
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
		this.statusNode = E('span');
		this.checkNode = E('span');
		o = s.taboption('basic', form.DummyValue, '_status', _('Service status'));
		o.renderWidget = () => this.statusNode;
		o = s.taboption('basic', form.DummyValue, '_check', _('Executable check'));
		o.renderWidget = () => this.checkNode;
		this.controlHint = E('p');
		const controls = [];
		[
			[ 'start', _('Start'), 'cbi-button-positive' ],
			[ 'stop', _('Stop'), 'cbi-button-negative' ],
			[ 'restart', _('Restart'), 'cbi-button-reload' ]
		].forEach(action => {
			const button = E('button', {
				'class': 'btn cbi-button', type: 'button', disabled: true,
				click: () => this.serviceAction(action[0]).catch(error => {
					ui.addNotification(null, E('p', {}, error.message));
				})
			}, action[1]);
			this.serviceButtons[action[0]] = { button: button, style: action[2] };
			controls.push(button, ' ');
		});
		o = s.taboption('basic', form.DummyValue, '_actions', _('Service control'));
		o.renderWidget = () => E('div', {}, [ ...controls, this.controlHint ]);

		this.editor = E('textarea', {
			'class': 'cbi-input-textarea', rows: 24, style: 'width:100%;font-family:monospace',
			'aria-label': _('Configuration file contents'), spellcheck: 'false'
		});
		this.filePath = E('code');
		this.fileHint = E('p');
		o = s.taboption('file', form.DummyValue, '_editor', _('Configuration file contents'));
		o.renderWidget = () => E('div', {}, [
			this.filePath, this.fileHint,
			E('p', {}, _('VirtualHere writes its configuration while running. Save & Apply stops the service before writing and restores it afterwards. Save requires a stopped service.')),
			this.editor,
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'cbi-button cbi-button-action', type: 'button', click: ui.createHandlerFn(this, 'reloadFile') }, _('Reload file')),
				E('button', {
					'class': 'cbi-button cbi-button-save', type: 'button', disabled: this.map.readonly || null,
					click: ui.createHandlerFn(this, () => this.saveFile(false))
				}, _('Save file')),
				E('button', {
					'class': 'cbi-button cbi-button-apply', type: 'button', disabled: this.map.readonly || null,
					click: ui.createHandlerFn(this, () => this.saveFile(true))
				}, _('Save & Apply file'))
			])
		]);
		this.showFile(data[2]);
		window.addEventListener('beforeunload', event => {
			if (this.fileDirty() || this.settingsDirty()) {
				event.preventDefault();
				event.returnValue = '';
			}
		});
		poll.add(() => this.refreshStatus(), 5);
		return this.map.render().then(node => this.refreshStatus().then(() => node));
	},

	handleSave: function() { return this.saveSettings(false); },
	handleSaveApply: function() { return this.saveSettings(true); },
	handleReset: function() {
		if ((this.fileDirty() || this.settingsDirty()) && !window.confirm(_('Discard all unsaved changes?')))
			return Promise.resolve();
		Object.keys(this.options).forEach(key => this.map.data.set('json', 'main', key, this.settings[key]));
		this.showFile(this.file);
		return this.map.reset();
	}
});
