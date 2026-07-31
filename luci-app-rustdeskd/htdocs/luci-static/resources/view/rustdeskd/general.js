

'use strict';
'require view';
'require form';
'require fs';
'require ui';
'require uci';
'require rpc';
'require poll';

/*
 * Constants - only frontend-relevant values
 */
const CONSTANTS = {
	// Default ports (used in placeholders)
	HBBS_DEFAULT_PORT: '21116',
	HBBR_DEFAULT_PORT: '21117',

	// Polling interval (seconds)
	POLL_INTERVAL: 3,

	// Colors for status display
	COLORS: {
		SUCCESS: 'green',
		ERROR: 'red',
		MUTED: 'gray',
		INFO: '#888'
	}
};

/*
 * RPC declarations
 */
const callGetStatus = rpc.declare({
	object: 'luci.rustdeskd',
	method: 'get_status'
});

const callGetPublicKey = rpc.declare({
	object: 'luci.rustdeskd',
	method: 'get_public_key'
});

const callGetVersion = rpc.declare({
	object: 'luci.rustdeskd',
	method: 'get_version'
});

const callRegenerateKey = rpc.declare({
	object: 'luci.rustdeskd',
	method: 'regenerate_key'
});

const callUpdateCore = rpc.declare({
	object: 'luci.rustdeskd',
	method: 'update_core'
});

const callCreateBackup = rpc.declare({
	object: 'luci.rustdeskd',
	method: 'create_backup'
});

const callRestoreBackup = rpc.declare({
	object: 'luci.rustdeskd',
	method: 'restore_backup',
	params: ['data']
});

const callServiceAction = rpc.declare({
	object: 'luci.rustdeskd',
	method: 'service_action',
	params: ['action']
});

/*
 * Helper functions
 */
function handleAction(action) {
	return fs.exec_direct('/etc/init.d/rustdeskd', [action]);
}


/**
 * Shell metacharacters regex - prevents command injection
 */
const SHELL_METACHARS = /[;&|$`(){}[\]<>'"\\!]/;

/**
 * Validates a safe string value (no shell metacharacters)
 * Used for URL and path validation
 * @param {string} value - The value to check
 * @returns {boolean|string} True if safe, error message if not
 */
function containsShellMetachars(value) {
	if (SHELL_METACHARS.test(value))
		return _('Invalid characters detected');
	return true;
}

/**
 * Validates a key string (alphanumeric and base64 characters only)
 * @param {string} section_id - The section ID
 * @param {string} value - The key value
 * @returns {boolean|string} True if valid, error message if invalid
 */
function validateKey(section_id, value) {
	if (!value || value.length === 0)
		return true;
	if (/[^A-Za-z0-9+/=]/.test(value))
		return _('Invalid characters.') + ' ' + _('Only alphanumeric and base64 characters (+/=) allowed.');
	return true;
}

/**
 * Validates a URL (must start with http:// or https://)
 * @param {string} section_id - The section ID
 * @param {string} value - The URL value
 * @returns {boolean|string} True if valid, error message if invalid
 */
function validateURL(section_id, value) {
	if (!value || value.length === 0)
		return true;
	const shellCheck = containsShellMetachars(value);
	if (shellCheck !== true)
		return shellCheck;
	if (!/^https?:\/\//.test(value))
		return _('URL must start with http:// or https://');
	return true;
}


/**
 * Creates a status indicator HTML string
 * @param {boolean} isActive - Whether the status is active/good
 * @param {string} activeText - Text to show when active
 * @param {string} inactiveText - Text to show when inactive
 * @param {string} [suffix] - Optional suffix to append
 * @returns {string} HTML string
 */
function createStatusIndicator(isActive, activeText, inactiveText, suffix) {
	const color = isActive ? CONSTANTS.COLORS.SUCCESS : CONSTANTS.COLORS.ERROR;
	const symbol = isActive ? '●' : '○';
	const text = isActive ? activeText : inactiveText;
	let html = '<span style="color:' + color + '">' + symbol + ' ' + text + '</span>';

	if (suffix) {
		html += ' <small style="color:' + CONSTANTS.COLORS.INFO + '">' + suffix + '</small>';
	}

	return html;
}

/**
 * Creates a checkmark status indicator
 * @param {boolean} isActive - Whether the status is active/good
 * @param {string} activeText - Text to show when active
 * @param {string} inactiveText - Text to show when inactive
 * @returns {string} HTML string
 */
function createCheckIndicator(isActive, activeText, inactiveText) {
	const color = isActive ? CONSTANTS.COLORS.SUCCESS : CONSTANTS.COLORS.MUTED;
	const symbol = isActive ? '✓' : '✗';
	const text = isActive ? activeText : inactiveText;
	return '<span style="color:' + color + '">' + symbol + ' ' + text + '</span>';
}

// Track if key exists globally for button state
let keyExistsGlobal = false;
// Track if any server is enabled in config
let anyServerEnabledGlobal = false;
// Track boot enabled state
let bootEnabledGlobal = false;

function handleUpdateCore(ev) {
	if (!confirm(_('This will download and install the official RustDesk server core. It may take a minute or two. Continue?'))) {
		return;
	}
	
	const btn = document.getElementById('download_core_btn');
	let originalText = '';
	if (btn) {
		originalText = btn.textContent;
		btn.disabled = true;
		btn.textContent = _('Downloading...');
	}

	L.resolveDefault(callUpdateCore(), {}).then((res) => {
		if (res && res.success) {
			ui.addTimeLimitedNotification(null, E('p', _('Core downloaded and installed successfully!')), 5000, 'notice');
		} else {
			const errorOutput = (res && res.output) ? res.output : _('Unknown error');
			ui.addNotification(null, E('p', _('Failed to update core: ') + errorOutput), 'error');
		}
	}).catch((e) => {
		ui.addNotification(null, E('p', _('Failed to execute update: ') + e.message), 'error');
	}).finally(() => {
		if (btn) {
			btn.disabled = false;
			btn.textContent = originalText;
		}
	});
}








function handleCreateBackup(ev) {
	const btn = document.getElementById('download_backup_btn');
	let originalText = '';
	if (btn) {
		originalText = btn.textContent;
		btn.disabled = true;
		btn.textContent = _('Creating Backup...');
	}
	L.resolveDefault(callCreateBackup(), {}).then((res) => {
		if (res && res.success && res.data) {
			const a = document.createElement('a');
			a.href = 'data:application/gzip;base64,' + res.data;
			a.download = 'rustdesk_backup.tar.gz';
			document.body.appendChild(a);
			a.click();
			document.body.removeChild(a);
			ui.addTimeLimitedNotification(null, E('p', _('Backup downloaded successfully')), 5000, 'notice');
		} else {
			ui.addTimeLimitedNotification(null, E('p', _('Failed to create backup')), 5000, 'error');
		}
	}).catch((err) => {
		ui.addTimeLimitedNotification(null, E('p', _('Error: ') + err.message), 5000, 'error');
	}).finally(() => {
		if (btn) {
			btn.disabled = false;
			btn.textContent = originalText;
		}
	});
}


return view.extend({
	render() {
		let m, s, o;

		m = new form.Map('rustdeskd', _('RustDesk Server'),
			_('Remote Desktop Software Server configuration.') + ' ' +
			'<a href="https://github.com/rustdesk/rustdesk" target="_blank">' + _('Client') + '</a>');

		/*
			Firewall Notice
		*/
		s = m.section(form.NamedSection, 'firewall_info');
		s.render = () => E('div', { 'class': 'alert-message notice' }, [
			E('h4', {}, _('Firewall Configuration Required')),
			E('p', {}, _('Required ports (when using default settings): TCP 21115-21119, UDP 21116.')),
			E('p', {}, _('Configure in Network → Firewall → Traffic Rules.'))
		]);

		
		/*
			Main Section with Tabs
		*/
		s = m.section(form.TypedSection, 'rustdeskd');
		s.anonymous = true;
		s.addremove = false;

		s.tab('general', _('General'));
		s.tab('hbbs', _('ID Server (hbbs)'));
		s.tab('hbbr', _('Relay Server (hbbr)'));
		s.tab('backup', _('Backup & Restore'));
		s.tab('log', _('Log'));

		/* General Settings (Custom UI) */
		o = s.taboption('general', form.DummyValue, '_custom_status');
		o.render = function() {
			return E('div', [

				E('h3', { 'style': 'margin-top: 20px;' }, _('Core Management')),

				// Core Management (Vertical Layout)
				E('div', { 'style': 'margin-top: 8px; margin-bottom: 25px;' }, [
					E('div', { 'style': 'margin-bottom: 12px;' }, [
						E('button', {
							'class': 'btn cbi-button cbi-button-action',
							'id': 'download_core_btn',
							'style': 'min-width: 200px; font-weight: bold; color: #28a745; border-color: #28a745; background-color: transparent;',
							'click': handleUpdateCore
						}, _('Download / Update Core'))
					]),
					E('div', { 'class': 'cbi-value-description', 'style': 'color: #666; font-size: 0.9em; margin-top: 4px;' }, [
						E('em', {}, [
							_('Download and install the official RustDesk server core binaries for your OpenWrt architecture.')
						])
					])
				]),

				// Service Status Title
				E('h3', _('Service Status')),
				// Status Table for HBBS and HBBR
				E('table', { 'class': 'table cbi-section-table', 'id': 'status_table' }, [
					E('tr', { 'class': 'tr table-titles' }, [
						E('th', { 'class': 'th' }, _('Component')),
						E('th', { 'class': 'th' }, _('Service Status')),
						E('th', { 'class': 'th' }, _('Binary')),
						E('th', { 'class': 'th' }, _('Enabled'))
					]),
					E('tr', { 'class': 'tr', 'id': 'hbbs_row' }, [
						E('td', { 'class': 'td' }, _('HBBS (ID Server)')),
						E('td', { 'class': 'td', 'id': 'hbbs_status' }, '-'),
						E('td', { 'class': 'td', 'id': 'hbbs_binary' }, '-'),
						E('td', { 'class': 'td', 'id': 'hbbs_enabled' }, '-')
					]),
					E('tr', { 'class': 'tr', 'id': 'hbbr_row' }, [
						E('td', { 'class': 'td' }, _('HBBR (Relay Server)')),
						E('td', { 'class': 'td', 'id': 'hbbr_status' }, '-'),
						E('td', { 'class': 'td', 'id': 'hbbr_binary' }, '-'),
						E('td', { 'class': 'td', 'id': 'hbbr_enabled' }, '-')
					])
				]),

				E('hr', { 'style': 'margin: 20px 0; border: 0; border-top: 1px solid #eee;' }),

				E('div', { 'style': 'margin-left: 0; padding-left: 0;' }, [
					// Row 1: Public Key
					E('div', { 'style': 'display: flex; align-items: center; margin-bottom: 20px;' }, [
						E('div', { 'style': 'flex: 0 0 130px; text-align: left; padding-right: 20px; font-weight: bold; color: #0066cc;' }, _('Public Key')),
						E('div', { 'style': 'display: flex; align-items: center; gap: 8px;' }, [
							E('div', { 'id': 'public_key', 'style': 'width: 380px; word-break: break-all; background: #f5f5f5; padding: 5px 10px; border: 1px solid #ddd; border-radius: 4px; font-family: monospace; color: #333;' }, '-'),
							E('button', {
								'class': 'btn cbi-button',
								'style': 'color: #1890ff; border: 1px solid #1890ff; background: transparent; white-space: nowrap;',
								'click': () => {
									const pk = document.getElementById('public_key').innerText;
									if(pk && pk !== '-') {
										navigator.clipboard.writeText(pk).then(() => {
											ui.addTimeLimitedNotification(null, E('p', _('Copied to clipboard')), 2000, 'notice');
										});
									}
								}
							}, _('Copy')),
							E('button', {
								'class': 'btn cbi-button',
								'id': 'regenerate_key_btn',
								'disabled': true,
								'style': 'color: #f5222d; border: 1px solid #f5222d; background: transparent; white-space: nowrap;',
								'title': _('Regenerate the key pair (requires existing key)'),
								'click': (ev) => {
									if (!keyExistsGlobal) {
										ui.addTimeLimitedNotification(null, E('p', _('Cannot regenerate: No public key exists yet.') + ' ' + _('Start the service first to generate the initial key.')), 5000, 'warning');
										return;
									}
									if (!confirm(_('This will regenerate the key pair and restart the service.') + ' ' + _('All existing clients will need to be reconfigured.') + ' ' + _('Continue?'))) {
										return;
									}
									ev.target.disabled = true;
									ev.target.textContent = _('Regenerating...');
	
									L.resolveDefault(callRegenerateKey(), {}).then((res) => {
										if (res && res.success) {
											ui.addTimeLimitedNotification(null, E('p', _('Keys deleted. Starting service to generate new keys...')), 5000, 'notice');
											return new Promise((resolve) => {
												setTimeout(resolve, 1000);
											}).then(() => L.resolveDefault(callServiceAction('start'), {}));
										} else {
											ui.addTimeLimitedNotification(null, E('p', _('Key regeneration failed: ') + (res.message || 'Could not delete keys')), 5000, 'error');
											throw new Error('Regeneration failed');
										}
									}).then((startRes) => {
										if (startRes && startRes.success) {
											ui.addTimeLimitedNotification(null, E('p', _('Service started with new key')), 5000, 'notice');
										} else if (startRes) {
											ui.addTimeLimitedNotification(null, E('p', _('Service start may have failed. Check status above.')), 5000, 'warning');
										}
									}).catch((err) => {
										if (err.message !== 'Regeneration failed') {
											ui.addTimeLimitedNotification(null, E('p', _('Error: ') + err.message), 5000, 'error');
										}
									}).finally(() => {
										const btn = document.getElementById('regenerate_key_btn');
										if (btn) {
											btn.disabled = !keyExistsGlobal;
											btn.textContent = _('Regenerate Key');
										}
									});
								}
							}, _('Regenerate Key'))
						])
					]),
	
					// Row 2: Start at Boot
					E('div', { 'style': 'display: flex; align-items: center; margin-bottom: 20px;' }, [
						E('div', { 'style': 'flex: 0 0 130px; text-align: left; padding-right: 20px; font-weight: bold; color: #0066cc;' }, _('Start at Boot')),
						E('div', { 'style': 'display: flex; align-items: center; gap: 8px;' }, [
							E('span', { 'id': 'boot_status', 'style': 'font-weight: bold;' }, '-'),
							E('button', {
								'class': 'btn cbi-button',
								'id': 'enable_boot_btn',
								'style': 'color: #1890ff; border: 1px solid #1890ff; background: transparent; white-space: nowrap;',
								'click': (ev) => {
									const action = bootEnabledGlobal ? 'disable' : 'enable';
									ev.target.disabled = true;
									ev.target.textContent = _('Processing...');
	
									L.resolveDefault(callServiceAction(action), {}).then((res) => {
										if (res && res.success) {
											bootEnabledGlobal = !bootEnabledGlobal;
											ui.addTimeLimitedNotification(null, E('p',
												bootEnabledGlobal ? _('Service enabled at boot') : _('Service disabled at boot')
											), 5000, 'notice');
										} else {
											const errMsg = res.error || res.message || (res.exit_code !== undefined ? 'Exit code: ' + res.exit_code : JSON.stringify(res));
											ui.addTimeLimitedNotification(null, E('p', _('Failed: ') + errMsg), 5000, 'error');
										}
									}).catch((err) => {
										ui.addTimeLimitedNotification(null, E('p', _('Error: ') + err.message), 5000, 'error');
									}).finally(() => {
										const btn = document.getElementById('enable_boot_btn');
										const statusEl = document.getElementById('boot_status');
										if (btn) {
											btn.disabled = false;
											btn.textContent = bootEnabledGlobal ? _('Disable') : _('Enable');
										}
										if (statusEl) {
											statusEl.innerHTML = createCheckIndicator(bootEnabledGlobal, _('Enabled'), _('Disabled'));
										}
									});
								}
							}, _('Loading...'))
						])
					]),
	
					// Row 3: Service Control
					E('div', { 'style': 'display: flex; align-items: flex-start; margin-bottom: 20px;' }, [
						E('div', { 'style': 'flex: 0 0 130px; text-align: left; padding-right: 20px; font-weight: bold; color: #0066cc; margin-top: 6px;' }, _('Service Control')),
						E('div', { 'style': 'display: flex; flex-direction: column; gap: 8px;' }, [
							E('div', { 'style': 'display: flex; align-items: center; gap: 8px;' }, [
								E('button', {
									'class': 'btn cbi-button',
									'id': 'start_btn',
									'disabled': true,
									'style': 'color: #1890ff; border: 1px solid #1890ff; background: transparent; min-width: 60px;',
									'title': _('Enable ID Server or Relay Server first'),
									'click': (ev) => {
										if (!anyServerEnabledGlobal) {
											ui.addTimeLimitedNotification(null, E('p', _('Cannot start service: Enable the ID Server or Relay Server in the configuration first.') + ' ' + _('Check "Enable ID Server" or "Enable Relay Server" below and click "Save & Apply".')), 5000, 'error');
											return;
										}
	
										ev.target.disabled = true;
										handleAction('start').then(() => {
											ev.target.disabled = !anyServerEnabledGlobal;
										}).catch((err) => {
											ui.addTimeLimitedNotification(null, E('p', _('Failed to start service: ') + err.message), 5000, 'error');
											ev.target.disabled = !anyServerEnabledGlobal;
										});
									}
								}, _('Start')),
								E('button', {
									'class': 'btn cbi-button',
									'style': 'color: #f5222d; border: 1px solid #f5222d; background: transparent; min-width: 60px;',
									'click': (ev) => {
										ev.target.disabled = true;
										handleAction('stop').then(() => {
											ev.target.disabled = false;
										}).catch((err) => {
											ui.addTimeLimitedNotification(null, E('p', _('Failed to stop service: ') + err.message), 5000, 'error');
											ev.target.disabled = false;
										});
									}
								}, _('Stop')),
								E('button', {
									'class': 'btn cbi-button',
									'style': 'color: #1890ff; border: 1px solid #1890ff; background: transparent; min-width: 60px;',
									'click': (ev) => {
										ev.target.disabled = true;
										handleAction('restart').then(() => {
											ev.target.disabled = false;
										}).catch((err) => {
											ui.addTimeLimitedNotification(null, E('p', _('Failed to restart service: ') + err.message), 5000, 'error');
											ev.target.disabled = false;
										});
									}
								}, _('Restart'))
							]),
							// Info message about Start requirement
							E('div', {
								'class': 'cbi-value-description',
								'style': 'color: #666; font-size: 0.9em; margin-top: 4px;'
							}, [
								E('em', {}, [
									_('Start will only work if at least "Enable ID Server" or "Enable Relay Server" is checked in the Configuration section below.')
								])
							])
						])
					])
				]),

				E('hr', { 'style': 'margin: 20px 0; border: 0; border-top: 1px solid #eee;' })

			]);
		};

		/*
			Polling for status updates
		*/
		poll.add(() => {
			return Promise.all([
				L.resolveDefault(callGetStatus(), {}),
				L.resolveDefault(callGetPublicKey(), {}),
				L.resolveDefault(callGetVersion(), {}),
				uci.load('rustdeskd')
			]).then(([status = {}, keyInfo = {}, verInfo = {}]) => {

				// Get enabled status from UCI
				const sections = uci.sections('rustdeskd', 'rustdeskd');
				let hbbsEnabled = false;
				let hbbrEnabled = false;
				if (sections && sections.length > 0) {
					hbbsEnabled = (sections[0].enabled == '1');
					hbbrEnabled = (sections[0].enabled_relay == '1');
				}

				// HBBS Status (Service Status column)
				const hbbsStatusEl = document.getElementById('hbbs_status');
				if (hbbsStatusEl) {
					let suffix = '';
					if (status.hbbs_pid) {
						suffix = '(PID: ' + status.hbbs_pid + ')';
						if (verInfo.hbbs_version) suffix += ' [' + verInfo.hbbs_version + ']';
					}
					hbbsStatusEl.innerHTML = createStatusIndicator(
						!!status.hbbs_pid, _('Running'), _('Stopped'), suffix
					);
				}

				// HBBS Binary column
				const hbbsBinaryEl = document.getElementById('hbbs_binary');
				if (hbbsBinaryEl) {
					hbbsBinaryEl.innerHTML = createCheckIndicator(status.hbbs_exists, _('Found'), _('Not Found'));
				}

				// HBBS Enabled column
				const hbbsEnabledEl = document.getElementById('hbbs_enabled');
				if (hbbsEnabledEl) {
					hbbsEnabledEl.innerHTML = createCheckIndicator(hbbsEnabled, _('Yes'), _('No'));
				}

				// HBBR Status (Service Status column)
				const hbbrStatusEl = document.getElementById('hbbr_status');
				if (hbbrStatusEl) {
					let suffix = '';
					if (status.hbbr_pid) {
						suffix = '(PID: ' + status.hbbr_pid + ')';
						if (verInfo.hbbr_version) suffix += ' [' + verInfo.hbbr_version + ']';
					}
					hbbrStatusEl.innerHTML = createStatusIndicator(
						!!status.hbbr_pid, _('Running'), _('Stopped'), suffix
					);
				}

				// HBBR Binary column
				const hbbrBinaryEl = document.getElementById('hbbr_binary');
				if (hbbrBinaryEl) {
					hbbrBinaryEl.innerHTML = createCheckIndicator(status.hbbr_exists, _('Found'), _('Not Found'));
				}

				// HBBR Enabled column
				const hbbrEnabledEl = document.getElementById('hbbr_enabled');
				if (hbbrEnabledEl) {
					hbbrEnabledEl.innerHTML = createCheckIndicator(hbbrEnabled, _('Yes'), _('No'));
				}

				// Public Key - update global state
				keyExistsGlobal = !!(keyInfo.key_exists && keyInfo.public_key);

				const keyEl = document.getElementById('public_key');
				const regenBtn = document.getElementById('regenerate_key_btn');

				if (keyEl) {
					if (keyInfo.key_exists && keyInfo.public_key) {
						keyEl.textContent = keyInfo.public_key;
					} else {
						keyEl.innerHTML = '<em style="color:' + CONSTANTS.COLORS.MUTED + '">' + _('Not generated yet') + '</em>';
					}
				}

				// Update regenerate button state
				if (regenBtn) {
					regenBtn.disabled = !keyExistsGlobal;
					if (!keyExistsGlobal) {
						regenBtn.title = _('Start the service first to generate the initial key');
					} else {
						regenBtn.title = _('Regenerate the key pair (will restart service)');
					}
				}

				// Update Start button state based on config
				anyServerEnabledGlobal = hbbsEnabled || hbbrEnabled;
				const startBtn = document.getElementById('start_btn');
				if (startBtn) {
					startBtn.disabled = !anyServerEnabledGlobal;
					if (!anyServerEnabledGlobal) {
						startBtn.title = _('Enable ID Server or Relay Server in Configuration first');
					} else {
						startBtn.title = _('Start the service');
					}
				}

				// Update boot enabled status
				bootEnabledGlobal = status.boot_enabled || false;
				const bootStatusEl = document.getElementById('boot_status');
				const bootBtn = document.getElementById('enable_boot_btn');
				if (bootStatusEl) {
					bootStatusEl.innerHTML = createCheckIndicator(bootEnabledGlobal, _('Enabled'), _('Disabled'));
				}
				if (bootBtn) {
					bootBtn.textContent = bootEnabledGlobal ? _('Disable') : _('Enable');
				}
			});
		}, CONSTANTS.POLL_INTERVAL);

		

		/* HBBS Settings */
		o = s.taboption('hbbs', form.Flag, 'enabled', _('Enable'));
		o.rmempty = false;

		o = s.taboption('hbbs', form.Value, 'server_port', _('Port (-p, --port)'));
		o.datatype = 'port';
		o.placeholder = CONSTANTS.HBBS_DEFAULT_PORT;
		o.description = _('Sets the listening port for the ID/Rendezvous server');

		o = s.taboption('hbbs', form.Value, 'server_key', _('Key (-k, --key)'));
		o.description = _('Only allow clients with the same key. If empty, uses auto-generated key');
		o.validate = validateKey;

		o = s.taboption('hbbs', form.DynamicList, 'server_relay_servers', _('Relay Servers (-r, --relay-servers)'));
		o.description = _('Default relay servers. Add one server per entry (hostname or hostname:port)');
		o.datatype = 'or(host,hostport)';

		o = s.taboption('hbbs', form.DynamicList, 'server_rendezvous_servers', _('Rendezvous Servers (-R, --rendezvous-servers)'));
		o.description = _('Additional rendezvous servers. Add one server per entry (hostname or hostname:port)');
		o.datatype = 'or(host,hostport)';

		o = s.taboption('hbbs', form.Value, 'server_mask', _('LAN Mask (--mask)'));
		o.description = _('Determine if the connection comes from LAN. Use CIDR notation.');
		o.placeholder = '192.168.0.0/16';
		o.datatype = 'cidr4';

		o = s.taboption('hbbs', form.Value, 'server_rmem', _('UDP Recv Buffer (-M, --rmem)'));
		o.datatype = 'uinteger';
		o.placeholder = '0';
		o.description = _('Sets UDP receive buffer size (0 = system default)');

		o = s.taboption('hbbs', form.Value, 'server_serial', _('Serial Number (-s, --serial)'));
		o.datatype = 'uinteger';
		o.placeholder = '0';
		o.description = _('Sets configure update serial number');

		o = s.taboption('hbbs', form.Value, 'server_software_url', _('Software Download URL (-u, --software-url)'));
		o.description = _('Sets the download URL of RustDesk software for clients');
		o.validate = validateURL;

		/* HBBS Settings - Environment Variables */
		o = s.taboption('hbbs', form.Flag, 'server_env_always_use_relay', _('ALWAYS_USE_RELAY'));
		o.description = _('Force all connections to use relay servers');
		o.default = o.disabled;

		o = s.taboption('hbbs', form.ListValue, 'server_env_rust_log', _('RUST_LOG'));
		o.description = _('Logging level for the ID server');
		o.value('', _('Default'));
		o.value('error', _('Error'));
		o.value('warn', _('Warning'));
		o.value('info', _('Info'));
		o.value('debug', _('Debug'));
		o.value('trace', _('Trace'));
		o.default = '';

		/* HBBR Settings */
		o = s.taboption('hbbr', form.Flag, 'enabled_relay', _('Enable'));
		o.rmempty = false;

		o = s.taboption('hbbr', form.Value, 'relay_port', _('Port (-p, --port)'));
		o.datatype = 'port';
		o.placeholder = CONSTANTS.HBBR_DEFAULT_PORT;
		o.description = _('Sets the listening port for the relay server');

		o = s.taboption('hbbr', form.Value, 'relay_key', _('Key (-k, --key)'));
		o.description = _('Only allow clients with the same key. If empty, uses auto-generated key');
		o.validate = validateKey;

		/* HBBR Settings - Environment Variables */
		o = s.taboption('hbbr', form.ListValue, 'relay_env_rust_log', _('RUST_LOG'));
		o.description = _('Logging level for the relay server');
		o.value('', _('Default'));
		o.value('error', _('Error'));
		o.value('warn', _('Warning'));
		o.value('info', _('Info'));
		o.value('debug', _('Debug'));
		o.value('trace', _('Trace'));
		o.default = '';

		o = s.taboption('hbbr', form.Value, 'relay_env_limit_speed', _('LIMIT_SPEED'));
		o.datatype = 'uinteger';
		o.description = _('Speed limit per connection in Mb/s (0 = default)');
		o.placeholder = '0';

		o = s.taboption('hbbr', form.Value, 'relay_env_single_bandwidth', _('SINGLE_BANDWIDTH'));
		o.datatype = 'uinteger';
		o.description = _('Bandwidth limit per single connection in MB/s (0 = default)');
		o.placeholder = '0';

		o = s.taboption('hbbr', form.Value, 'relay_env_total_bandwidth', _('TOTAL_BANDWIDTH'));
		o.datatype = 'uinteger';
		o.description = _('Total bandwidth limit in MB/s (0 = default)');
		o.placeholder = '0';

		o = s.taboption('hbbr', form.Value, 'relay_env_downgrade_threshold', _('DOWNGRADE_THRESHOLD'));
		o.datatype = 'uinteger';
		o.description = _('Threshold for connection downgrade');

		o = s.taboption('hbbr', form.Value, 'relay_env_downgrade_start_check', _('DOWNGRADE_START_CHECK'));
		o.datatype = 'uinteger';
		o.description = _('Start check time for connection downgrade');

		
		/* Backup & Restore Tab */
		o = s.taboption('backup', form.Button, 'dl_backup', _('Download backup'), _('Download an archive containing your RustDesk public/private keys, device lists, address books, and configurations.'));
		o.inputstyle = 'action important';
		o.inputtitle = _('Generate archive');
		o.onclick = handleCreateBackup;

		o = s.taboption('backup', form.Button, 'restore_backup', _('Restore backup'), _('Restore your RustDesk data from a previously downloaded .tar.gz backup archive.') + ' ' + _('This will overwrite current data and restart the service.'));
		o.inputstyle = 'action important';
		o.inputtitle = _('Upload archive...');
		o.onclick = function(ev) {
			ev.preventDefault();
			var fileInput = document.createElement('input');
			fileInput.type = 'file';
			fileInput.accept = '.tar.gz';
			fileInput.style.display = 'none';
			
			fileInput.onchange = function(e) {
				if (e.target.files.length > 0) {
					var file = e.target.files[0];
					if (!confirm(_('This will overwrite your existing RustDesk data and restart the service. Are you sure?'))) {
						return;
					}

					var btn = ev.target;
					var originalText = btn.textContent;
					btn.disabled = true;
					btn.textContent = _('Restoring...');

					var reader = new FileReader();
					reader.onload = function(evt) {
						var data = evt.target.result;
						var commaIndex = data.indexOf(',');
						if (commaIndex > -1) {
							data = data.substring(commaIndex + 1);
						}
						L.resolveDefault(callRestoreBackup(data), {}).then(function(res) {
							if (res && res.code === 0) {
								ui.addTimeLimitedNotification(null, E('p', _('Restore successful. Service restarted.')), 5000, 'success');
							} else {
								ui.addTimeLimitedNotification(null, E('p', _('Restore failed: ') + (res ? res.stderr : 'Unknown error')), 5000, 'error');
							}
						}).catch(function(err) {
							ui.addTimeLimitedNotification(null, E('p', _('Restore request failed: ') + err.message), 5000, 'error');
						}).finally(function() {
							btn.disabled = false;
							btn.textContent = originalText;
						});
					};
					reader.readAsDataURL(file);
				}
			};
			document.body.appendChild(fileInput);
			fileInput.click();
			document.body.removeChild(fileInput);
		};

		/* Log Tab */
		o = s.taboption('log', form.DummyValue, '_syslog');
		o.render = function() {
			var logTextarea = E('textarea', {
				'id': 'rustdesk_syslog',
				'style': 'width: 100%; min-height: 400px; padding: 10px; font-family: monospace; background: #f8f9fa; color: #333; border: 1px solid #ccc; border-radius: 4px; resize: vertical;',
				'readonly': 'readonly'
			}, _('Collecting data...'));

			var scrollBtn = E('button', {
				'class': 'btn cbi-button',
				'style': 'margin-top: 10px;',
				'click': function(ev) {
					ev.preventDefault();
					if (logTextarea) {
						logTextarea.scrollTop = logTextarea.scrollHeight;
					}
				}
			}, _('Scroll to bottom'));

			poll.add(function() {
				return fs.exec_direct('/sbin/logread', ['-e', 'rustdesk']).then(function(res) {
					if (logTextarea) {
						var isScrolledToBottom = logTextarea.scrollHeight - logTextarea.clientHeight <= logTextarea.scrollTop + 20;
						
						var lines = res ? res.trim().split(/\r?\n/) : [];
						if (lines.length > 500) {
							lines = lines.slice(-500);
						}
						var text = lines.join('\n');
						
						if (text !== logTextarea.value) {
							logTextarea.value = text || _('No log entries found.');
							if (isScrolledToBottom) {
								logTextarea.scrollTop = logTextarea.scrollHeight;
							}
						}
					}
				}).catch(function(err) {
					if (logTextarea && !logTextarea.value.includes('Error')) {
						logTextarea.value = _('Failed to load log data: ') + err.message;
					}
				});
			}, CONSTANTS.POLL_INTERVAL);

			return E('div', { 'style': 'width: 100%;' }, [
				logTextarea,
				E('div', { 'style': 'text-align: right;' }, [ scrollBtn ])
			]);
		};

		return m.render();

	}
});
