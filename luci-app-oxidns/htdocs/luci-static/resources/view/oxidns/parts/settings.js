'use strict';
'require baseclass';
'require rpc';
'require ui';

var callSettingsRead = rpc.declare({
	object: 'luci.oxidns',
	method: 'settings_read',
	expect: {}
});

var callSettingsSave = rpc.declare({
	object: 'luci.oxidns',
	method: 'settings_save',
	params: [
		'core_repository',
		'core_bundle',
		'config_path',
		'working_dir',
		'download_proxy',
		'github_token',
		'clear_download_proxy',
		'clear_github_token',
		'log_syslog',
		'persist_core',
		'allow_core_upload'
	],
	expect: {}
});

var callCredentialsStatus = rpc.declare({
	object: 'luci.oxidns',
	method: 'credentials_status',
	expect: {}
});

var callCredentialsGenerate = rpc.declare({
	object: 'luci.oxidns',
	method: 'credentials_generate',
	expect: {}
});

var callCredentialsSet = rpc.declare({
	object: 'luci.oxidns',
	method: 'credentials_set',
	params: ['username', 'password'],
	expect: {}
});

var callCredentialsReveal = rpc.declare({
	object: 'luci.oxidns',
	method: 'credentials_reveal',
	expect: {}
});

var callCredentialsMigrate = rpc.declare({
	object: 'luci.oxidns',
	method: 'credentials_migrate',
	params: ['username'],
	expect: {}
});

var callCredentialsClear = rpc.declare({
	object: 'luci.oxidns',
	method: 'credentials_clear',
	expect: {}
});

var BACKEND_ERRORS = {
	invalid_core_repository: _('The core repository must use the owner/repository format.'),
	invalid_core_bundle: _('The core bundle must be full, standard or minimal.'),
	invalid_config_path: _('The configuration path is invalid.'),
	invalid_working_dir: _('The working directory is invalid.'),
	invalid_log_syslog: _('The system log setting is invalid.'),
	invalid_persist_core: _('The persistent storage setting is invalid.'),
	invalid_allow_core_upload: _('The core upload setting is invalid.'),
	settings_save_failed: _('Failed to save settings.'),
	invalid_credentials: _('The username or password does not meet the requirements.'),
	credentials_write_failed: _('Failed to write the credential file.'),
	credentials_migrate_failed: _('Credentials were written but the old UCI password remains.'),
	credentials_missing: _('No credential file is configured.'),
	credentials_clear_failed: _('Failed to remove the credential file.'),
	random_failed: _('Could not generate credentials.'),
	nothing_to_migrate: _('No legacy UCI password was found.'),
	rpc_unavailable: _('The LuCI backend is unavailable.')
};

function field(id) {
	var node = document.getElementById(id);
	return node ? node.value : '';
}

function checked(id) {
	var node = document.getElementById(id);
	return !!(node && node.checked);
}

function row(label, input) {
	return E('div', { 'class': 'tr' }, [
		E('div', { 'class': 'td left', 'style': 'width: 240px' }, label),
		E('div', { 'class': 'td left' }, input)
	]);
}

function textInput(id, value, password, placeholder) {
	return E('input', {
		'id': id,
		'class': 'cbi-input-text',
		'type': password ? 'password' : 'text',
		'value': value || '',
		'placeholder': placeholder || null
	});
}

function option(value, label, selected) {
	return E('option', {
		'value': value,
		'selected': selected ? 'selected' : null
	}, label || value);
}

function bundleSelect(id, value) {
	var selected = value || 'full';
	return E('select', { 'id': id, 'class': 'cbi-input-select' }, [
		/* 选项文案必须可翻译 */
		option('full', _('full'), selected === 'full'),
		option('standard', _('standard'), selected === 'standard'),
		option('minimal', _('minimal'), selected === 'minimal')
	]);
}

function setStatus(message, danger) {
	var node = document.getElementById('oxidns-settings-status');
	if (!node)
		return;
	node.textContent = message || '';
	node.className = danger ? 'alert-message error' : 'alert-message info';
}

function setDescription(id, message) {
	var node = document.getElementById(id);
	if (node)
		node.textContent = message || '';
}

function setClearOptionVisible(id, visible) {
	var row = document.getElementById('%s-row'.format(id));
	var input = document.getElementById(id);

	if (row)
		row.style.display = visible ? 'block' : 'none';
	if (input)
		input.checked = false;
}

function clearOption(id, label, enabled) {
	return E('label', {
		'id': '%s-row'.format(id),
		'style': 'display: %s; margin-top: .35em;'.format(enabled ? 'block' : 'none')
	}, [
		E('input', {
			'id': id,
			'type': 'checkbox',
			'style': 'margin-right: .5em;'
		}),
		label
	]);
}

function secretSettingInput(input, descriptionId, description, clearId, clearLabel, clearEnabled) {
	return E('div', {}, [
		input,
		E('div', {
			'id': descriptionId,
			'class': 'cbi-value-description'
		}, description),
		clearOption(clearId, clearLabel, clearEnabled)
	]);
}

function proxyDescription() {
	return _('Format: http://host:port, https://host:port, socks5://host:port, or socks5h://host:port. Use http://user:pass@host:port when authentication is required.');
}

function backendMessage(err, fallback) {
	var code = err && err.code;
	if (code && BACKEND_ERRORS[code])
		return BACKEND_ERRORS[code];
	return fallback || _('Operation failed');
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

/* 已配置的代理可能含用户名密码：用 password 输入框 + 占位提示，不回显明文 */
function proxyInput(configured) {
	return textInput('oxidns-setting-download-proxy', '', configured,
		configured
			? _('A proxy is currently configured. Enter a new value to replace it.')
			: _('Example: http://127.0.0.1:7890'));
}

function updateProxyInput(configured) {
	var proxy = document.getElementById('oxidns-setting-download-proxy');
	if (!proxy)
		return;

	proxy.type = configured ? 'password' : 'text';
	proxy.value = '';
	proxy.placeholder = configured
		? _('A proxy is currently configured. Enter a new value to replace it.')
		: _('Example: http://127.0.0.1:7890');
}

function saveSettings() {
	var payload = {
		core_repository: field('oxidns-setting-core-repository') || 'svenshi/oxidns',
		core_bundle: field('oxidns-setting-core-bundle') || 'full',
		config_path: field('oxidns-setting-config-path') || '/etc/oxidns/config.yaml',
		working_dir: field('oxidns-setting-working-dir') || '/var/lib/oxidns',
		download_proxy: field('oxidns-setting-download-proxy'),
		github_token: field('oxidns-setting-github-token'),
		clear_download_proxy: checked('oxidns-setting-clear-download-proxy'),
		clear_github_token: checked('oxidns-setting-clear-github-token'),
		log_syslog: checked('oxidns-setting-log-syslog') ? '1' : '0',
		persist_core: checked('oxidns-setting-persist-core') ? '1' : '0',
		allow_core_upload: checked('oxidns-setting-allow-core-upload') ? '1' : '0'
	};

	ui.showModal(_('OxiDNS'), [
		E('p', {}, _('Saving settings...'))
	]);
	focusModal();

	return Promise.resolve(callSettingsSave(
		payload.core_repository,
		payload.core_bundle,
		payload.config_path,
		payload.working_dir,
		payload.download_proxy,
		payload.github_token,
		payload.clear_download_proxy,
		payload.clear_github_token,
		payload.log_syslog,
		payload.persist_core,
		payload.allow_core_upload
	)).then(function(result) {
		ui.hideModal();
		if (!result || result.ok === false) {
			setStatus(backendMessage(result, _('Failed to save settings')), true);
			return;
		}
		setStatus(_('Settings saved.'), false);
		var logSyslog = document.getElementById('oxidns-setting-log-syslog');
		if (logSyslog)
			logSyslog.checked = result.log_syslog !== false;
		var persistCore = document.getElementById('oxidns-setting-persist-core');
		if (persistCore)
			persistCore.checked = result.persist_core !== false;
		var allowUpload = document.getElementById('oxidns-setting-allow-core-upload');
		if (allowUpload)
			allowUpload.checked = result.allow_core_upload === true;

		updateProxyInput(!!result.download_proxy_set);
		var token = document.getElementById('oxidns-setting-github-token');
		if (token)
			token.value = '';
		var clearProxy = document.getElementById('oxidns-setting-clear-download-proxy');
		if (clearProxy)
			clearProxy.checked = false;
		var clearToken = document.getElementById('oxidns-setting-clear-github-token');
		if (clearToken)
			clearToken.checked = false;
		setClearOptionVisible('oxidns-setting-clear-download-proxy', result.download_proxy_set);
		setClearOptionVisible('oxidns-setting-clear-github-token', result.github_token_set);
		setDescription('oxidns-setting-download-proxy-description',
			proxyDescription());
		setDescription('oxidns-setting-github-token-description',
			result.github_token_set ? _('A token is currently configured. Enter a new value to replace it.') : _('Optional. The token is never shown after saving.'));
	}).catch(function(err) {
		ui.hideModal();
		setStatus(backendMessage(err, _('Failed to save settings')), true);
	});
}

function credentialNode(id) {
	return document.getElementById(id);
}

function applyCredentialStatus(result) {
	if (!result || result.ok === false)
		return;
	var configured = credentialNode('oxidns-cred-configured');
	if (configured)
		configured.textContent = result.configured
			? _('Credentials are configured') : _('No credentials configured');
	var user = credentialNode('oxidns-cred-user');
	if (user)
		user.textContent = result.user_masked || '';
	var fingerprint = credentialNode('oxidns-cred-fingerprint');
	if (fingerprint)
		fingerprint.textContent = result.fingerprint || '';
	var source = credentialNode('oxidns-cred-source');
	if (source)
		source.textContent = result.source === 'file' ? _('Root-only file')
			: result.source === 'legacy' ? _('Legacy UCI value') : _('Not set');
	var path = credentialNode('oxidns-cred-path');
	if (path)
		path.textContent = result.auth_file || '';
	var warning = credentialNode('oxidns-cred-warning');
	if (warning) {
		var messages = [];
		if (result.file_present && !result.file_safe)
			messages.push(_('The credential file has unsafe permissions. It was ignored.'));
		if (result.legacy_plain)
			messages.push(_('A plaintext password is still stored in UCI. Migrate it to the credential file.'));
		if (result.expose_warning)
			messages.push(_('The API listens outside loopback without TLS. Basic Auth sends credentials as Base64.'));
		warning.textContent = messages.join(' ');
		warning.style.display = messages.length ? 'block' : 'none';
	}
	var migrate = credentialNode('oxidns-cred-migrate');
	if (migrate)
		migrate.disabled = !result.legacy_plain;
	var clear = credentialNode('oxidns-cred-clear');
	if (clear)
		clear.disabled = !result.configured;
}

function refreshCredentials() {
	return Promise.resolve(callCredentialsStatus()).then(function(result) {
		applyCredentialStatus(result);
		return result;
	}).catch(function(err) {
		setCredentialStatus(backendMessage(err, _('Failed to read credentials')), true);
	});
}

function setCredentialStatus(message, danger) {
	var node = credentialNode('oxidns-credentials-status');
	if (!node)
		return;
	node.textContent = message || '';
	node.className = danger ? 'alert-message error' : 'alert-message info';
}

function showCredentialModal(title, content) {
	ui.showModal(title, content);
	focusModal();
}

function generateCredentials() {
	return Promise.resolve(callCredentialsGenerate()).then(function(result) {
		if (!result || result.ok === false) {
			setCredentialStatus(backendMessage(result, _('Could not generate credentials.')), true);
			return;
		}
		showCredentialModal(_('Save these credentials now'), [
			E('p', {}, _('They are shown once. Copy them before closing this dialog.')),
			row(_('Username'), E('input', {
				'id': 'oxidns-generated-user',
				'class': 'cbi-input-text',
				'value': result.username || ''
			})),
			row(_('Password'), E('input', {
				'id': 'oxidns-generated-password',
				'class': 'cbi-input-text',
				'value': result.password || ''
			})),
			E('div', { 'class': 'cbi-button-row' }, [
				E('button', {
					'type': 'button',
					'class': 'btn cbi-button cbi-button-positive',
					'click': function(ev) {
						ev.preventDefault();
						return Promise.resolve(callCredentialsSet(
							field('oxidns-generated-user'),
							field('oxidns-generated-password')
						)).then(function(saved) {
							ui.hideModal();
							if (!saved || saved.ok === false) {
								setCredentialStatus(backendMessage(saved, _('Failed to write the credential file.')), true);
								return;
							}
							setCredentialStatus(_('Credentials saved.'), false);
							applyCredentialStatus(saved);
						}).catch(function(err) {
							ui.hideModal();
							setCredentialStatus(backendMessage(err, _('Failed to write the credential file.')), true);
						});
					}
				}, _('Save credentials')),
				E('button', {
					'type': 'button',
					'click': function(ev) { ev.preventDefault(); ui.hideModal(); }
				}, _('Cancel'))
			])
		]);
	}).catch(function(err) {
		setCredentialStatus(backendMessage(err, _('Could not generate credentials.')), true);
	});
}

function revealCredentials() {
	return Promise.resolve(callCredentialsReveal()).then(function(result) {
		if (!result || result.ok === false) {
			setCredentialStatus(backendMessage(result, _('Failed to read credentials')), true);
			return;
		}
		showCredentialModal(_('Current credentials'), [
			row(_('Username'), E('input', {
				'class': 'cbi-input-text',
				'readonly': 'readonly',
				'value': result.username || ''
			})),
			row(_('Password'), E('input', {
				'class': 'cbi-input-text',
				'readonly': 'readonly',
				'value': result.password || ''
			})),
			E('div', { 'class': 'cbi-button-row' }, [
				E('button', {
					'type': 'button',
					'click': function(ev) { ev.preventDefault(); ui.hideModal(); }
				}, _('Close'))
			])
		]);
	}).catch(function(err) {
		setCredentialStatus(backendMessage(err, _('Failed to read credentials')), true);
	});
}

function migrateCredentials() {
	return Promise.resolve(callCredentialsMigrate('admin')).then(function(result) {
		if (!result || result.ok === false) {
			setCredentialStatus(backendMessage(result, _('Failed to migrate credentials')), true);
			return;
		}
		setCredentialStatus(_('Migrated to the credential file.'), false);
		applyCredentialStatus(result);
	}).catch(function(err) {
		setCredentialStatus(backendMessage(err, _('Failed to migrate credentials')), true);
	});
}

function clearCredentials() {
	if (!window.confirm(_('Remove the credential file? OxiDNS will fail closed until new credentials are set.')))
		return;
	return Promise.resolve(callCredentialsClear()).then(function(result) {
		if (!result || result.ok === false) {
			setCredentialStatus(backendMessage(result, _('Failed to remove the credential file.')), true);
			return;
		}
		setCredentialStatus(_('Credential file removed.'), false);
		applyCredentialStatus(result);
	}).catch(function(err) {
		setCredentialStatus(backendMessage(err, _('Failed to remove the credential file.')), true);
	});
}

return baseclass.extend({
	load: function() {
		return Promise.all([
			Promise.resolve(callSettingsRead()).catch(function(err) {
				console.warn('oxidns settings load:', err);
				return { ok: false, code: 'rpc_unavailable' };
			}),
			Promise.resolve(callCredentialsStatus()).catch(function(err) {
				console.warn('oxidns credentials load:', err);
				return { ok: false, code: 'rpc_unavailable' };
			})
		]).then(function(results) {
			return { settings: results[0], credentials: results[1] };
		});
	},

	render: function(data) {
		data = data || {};
		var settings = data.settings || data;
		var credentials = data.credentials || {};

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('OxiDNS Settings')),
			E('div', { 'class': 'cbi-map-descr' },
				_('Configure OxiDNS core download sources, runtime paths, and optional download credentials.')),
			E('div', { 'class': 'cbi-section' }, [
				E('div', { 'class': 'table cbi-section-table' }, [
					row(_('Core repository'), textInput('oxidns-setting-core-repository', settings.core_repository || 'svenshi/oxidns')),
					row(_('Core bundle'), bundleSelect('oxidns-setting-core-bundle', settings.core_bundle || 'full')),
					row(_('Config path'), textInput('oxidns-setting-config-path', settings.config_path || '/etc/oxidns/config.yaml')),
					row(_('Working directory'), textInput('oxidns-setting-working-dir', settings.working_dir || '/var/lib/oxidns')),
					row(_('Persist core across upgrades'), E('div', {}, [
						E('input', {
							'id': 'oxidns-setting-persist-core',
							'type': 'checkbox',
							'checked': settings.persist_core !== false ? 'checked' : null
						}),
						E('div', { 'class': 'cbi-value-description' },
							_('Store the core binary and webui under /etc/oxidns/core, which is kept during firmware upgrades. Requires enough free space on the overlay partition.'))
					])),
					row(_('Allow manually uploaded cores'), E('div', {}, [
						E('input', {
							'id': 'oxidns-setting-allow-core-upload',
							'type': 'checkbox',
							'checked': settings.allow_core_upload === true ? 'checked' : null
						}),
						E('div', { 'class': 'cbi-value-description' },
							_('Disabled by default. Enabling it permits installing an uploaded core archive; the upload permission is also controlled by the separate luci-app-oxidns-core-upload ACL group. Only enable it for trusted administrators.'))
					])),
					row(_('Write to system log'), E('div', {}, [
						E('input', {
							'id': 'oxidns-setting-log-syslog',
							'type': 'checkbox',
							'checked': settings.log_syslog !== false ? 'checked' : null
						}),
						E('div', { 'class': 'cbi-value-description' },
							_('When disabled, the LuCI log page no longer shows new runtime logs. Restart OxiDNS after changing this setting.'))
					])),
					row(_('Download proxy'), secretSettingInput(
						proxyInput(!!settings.download_proxy_set),
						'oxidns-setting-download-proxy-description',
						proxyDescription(),
						'oxidns-setting-clear-download-proxy',
						_('Clear configured download proxy'),
						settings.download_proxy_set)),
					row(_('GitHub token'), secretSettingInput(
						textInput('oxidns-setting-github-token', '', true,
							settings.github_token_set ? _('A token is currently configured. Enter a new value to replace it.') : null),
						'oxidns-setting-github-token-description',
						settings.github_token_set ? _('A token is currently configured. Enter a new value to replace it.') : _('Optional. The token is never shown after saving.'),
						'oxidns-setting-clear-github-token',
						_('Clear configured GitHub token'),
						settings.github_token_set))
				]),
				E('div', { 'class': 'cbi-button-row' }, [
					E('button', {
						'type': 'button',
						'class': 'btn cbi-button cbi-button-positive',
						'click': function(ev) {
							ev.preventDefault();
							return saveSettings();
						}
					}, _('Save Settings'))
				]),
				E('div', {
					'id': 'oxidns-settings-status',
					'aria-live': 'polite',
					'style': 'margin-top: 1em;'
				})
			]),
			E('h3', { 'id': 'api-credentials' }, _('API credentials')),
			E('div', { 'class': 'cbi-map-descr' },
				_('Basic Auth credentials are kept in a root-only file and injected into OxiDNS at runtime. They are never written to UCI.')),
			E('div', { 'class': 'cbi-section' }, [
				E('div', { 'class': 'table cbi-section-table' }, [
					row(_('Status'), E('div', {
						'id': 'oxidns-cred-configured',
						'aria-live': 'polite'
					}, credentials.configured ? _('Credentials are configured') : _('No credentials configured'))),
					row(_('Storage'), E('div', {}, [
						E('div', { 'id': 'oxidns-cred-source' },
							credentials.source === 'file' ? _('Root-only file')
								: credentials.source === 'legacy' ? _('Legacy UCI value') : _('Not set')),
						E('div', { 'id': 'oxidns-cred-path', 'class': 'cbi-value-description' }, credentials.auth_file || '')
					])),
					row(_('Username'), E('div', {
						'id': 'oxidns-cred-user',
						'class': 'cbi-value-description'
					}, credentials.user_masked || '')),
					row(_('Fingerprint'), E('div', {
						'id': 'oxidns-cred-fingerprint',
						'class': 'cbi-value-description'
					}, credentials.fingerprint || ''))
				]),
				E('div', {
					'id': 'oxidns-cred-warning',
					'class': 'alert-message warning',
					'aria-live': 'polite',
					'style': 'display: none; margin-top: 1em;'
				}),
				E('div', { 'class': 'cbi-button-row' }, [
					E('button', {
						'type': 'button',
						'class': 'btn cbi-button cbi-button-positive',
						'click': function(ev) { ev.preventDefault(); return generateCredentials(); }
					}, _('Generate credentials')),
					E('button', {
						'type': 'button',
						'click': function(ev) { ev.preventDefault(); return revealCredentials(); }
					}, _('View credentials')),
					E('button', {
						'id': 'oxidns-cred-migrate',
						'type': 'button',
						'disabled': credentials.legacy_plain ? null : 'disabled',
						'click': function(ev) { ev.preventDefault(); return migrateCredentials(); }
					}, _('Migrate UCI password')),
					E('button', {
						'id': 'oxidns-cred-clear',
						'type': 'button',
						'disabled': credentials.configured ? null : 'disabled',
						'click': function(ev) { ev.preventDefault(); return clearCredentials(); }
					}, _('Remove credentials'))
				]),
				E('div', {
					'id': 'oxidns-credentials-status',
					'aria-live': 'polite',
					'style': 'margin-top: 1em;'
				})
			])
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
