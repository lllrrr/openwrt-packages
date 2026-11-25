'use strict';
'require view';
'require rpc';
'require ui';

var callGeoGet = rpc.declare({
	object: 'luci.oxidns',
	method: 'geo_get',
	expect: {}
});

var callGeoSave = rpc.declare({
	object: 'luci.oxidns',
	method: 'geo_save',
	params: [ 'geoip_url', 'geosite_url', 'geo_dir', 'geoip_sha256', 'geosite_sha256' ],
	expect: {}
});

var callGeoReset = rpc.declare({
	object: 'luci.oxidns',
	method: 'geo_reset',
	expect: {}
});

var callGeoDownload = rpc.declare({
	object: 'luci.oxidns',
	method: 'geo_download',
	params: [ 'restart' ],
	expect: {}
});

var callGeoProgress = rpc.declare({
	object: 'luci.oxidns',
	method: 'geo_progress',
	expect: {}
});

var BACKEND_ERRORS = {
	invalid_geo_settings: _('The configured GeoIP URL, GeoSite URL, directory or SHA-256 checksum is invalid.'),
	geo_save_failed: _('Failed to save the geo settings.'),
	geo_reset_failed: _('Failed to restore the default geo settings.'),
	geo_download_busy: _('A geo data download is already running.'),
	geo_dir_create_failed: _('The geo data directory could not be created.')
};

var viewRoot = null;
var cleanupTasks = [];
var viewObserver = null;

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

function backendMessage(result, fallback) {
	var code = result && result.code;

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

function field(id) {
	var node = document.getElementById(id);
	return node ? node.value : '';
}

function normalizeSha(value) {
	return String(value || '').trim().toLowerCase();
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

function textInput(id, value) {
	return E('input', {
		'id': id,
		'class': 'cbi-input-text',
		'type': 'text',
		'style': 'width: 100%',
		'value': value || ''
	});
}

function showError(message) {
	var node = document.getElementById('oxidns-geo-error');
	if (!node)
		return;

	node.textContent = message || '';
	node.style.display = message ? 'block' : 'none';
}

function setStatus(message, danger) {
	var node = document.getElementById('oxidns-geo-status');
	if (!node)
		return;
	node.textContent = message || '';
	node.className = danger ? 'alert-message error' : 'alert-message info';
}

function fmtSize(bytes) {
	if (!bytes || bytes <= 0)
		return '-';
	if (bytes >= 1048576)
		return '%.1f MiB'.format(bytes / 1048576);
	return '%d B'.format(bytes);
}

/* 后端给的是 Unix 秒（stat_mtime），这里换算成本地时间显示，与规则页一致 */
function fmtTime(mtime) {
	var value = parseInt(mtime, 10);

	if (isNaN(value) || value <= 0)
		return '-';

	var date = new Date(value * 1000);

	return '%04d-%02d-%02d %02d:%02d:%02d'.format(
		date.getFullYear(), date.getMonth() + 1, date.getDate(),
		date.getHours(), date.getMinutes(), date.getSeconds());
}

function fileRows(name, info) {
	var cells = [
		E('div', { 'class': 'td left', 'style': 'width: 120px' }, name)
	];
	if (!info || !info.exists) {
		cells.push(E('div', { 'class': 'td left', 'colspan': '3' }, _('not present')));
		return E('div', { 'class': 'tr' }, cells);
	}
	cells.push(E('div', { 'class': 'td left', 'style': 'width: 120px' }, fmtSize(info.size)));
	cells.push(E('div', { 'class': 'td left', 'style': 'width: 200px' }, fmtTime(info.mtime)));
	cells.push(E('div', { 'class': 'td left' },
		E('span', { 'style': 'font-family: monospace; font-size: 85%; word-break: break-all;' }, info.sha256 || '-')));
	return E('div', { 'class': 'tr' }, cells);
}

/* 只清除数据行，保留 render() 创建的表头 */
function refreshFileRows(state) {
	var wrap = document.getElementById('oxidns-geo-file-rows');
	if (!wrap)
		return;

	while (wrap.firstChild)
		wrap.removeChild(wrap.firstChild);

	wrap.appendChild(fileRows('geoip.dat', state && state.geoip));
	wrap.appendChild(fileRows('geosite.dat', state && state.geosite));
}

function applyState(state) {
	if (!state || state.ok === false)
		return;
	var ip = document.getElementById('oxidns-geo-ip-url');
	var site = document.getElementById('oxidns-geo-site-url');
	var dir = document.getElementById('oxidns-geo-dir');
	var ipSha = document.getElementById('oxidns-geo-ip-sha');
	var siteSha = document.getElementById('oxidns-geo-site-sha');
	if (ip)
		ip.value = state.geoip_url || '';
	if (site)
		site.value = state.geosite_url || '';
	if (dir)
		dir.value = state.geo_dir || '';
	if (ipSha)
		ipSha.value = state.geoip_sha256 || '';
	if (siteSha)
		siteSha.value = state.geosite_sha256 || '';
	refreshFileRows(state);
}

/*
 * 单一可取消的轮询管理器：generation 在每次 stop 时递增，旧请求回来时
 * 发现 token 不匹配就直接丢弃，不会重复排定时器，也不会写已卸载的 DOM。
 */
var pollState = { generation: 0, timer: null, failures: 0 };

function stopPoll() {
	pollState.generation++;
	if (pollState.timer !== null) {
		window.clearTimeout(pollState.timer);
		pollState.timer = null;
	}
	pollState.failures = 0;
}

function schedulePoll(delay) {
	var token = pollState.generation;

	if (pollState.timer !== null)
		window.clearTimeout(pollState.timer);

	pollState.timer = window.setTimeout(function() {
		pollTick(token);
	}, delay);
}

function pollFailure(err) {
	if (pollState.failures < 4) {
		pollState.failures++;
		showError(_('Could not refresh geo data status. Retrying...'));
		schedulePoll(Math.min(30000, 1000 * Math.pow(2, pollState.failures)));
	}
	else {
		showError(_('Could not refresh geo data status. Use Refresh to try again.'));
	}

	if (err)
		console.warn('oxidns geo poll:', err);
}

function pollTick(token) {
	pollState.timer = null;

	if (token !== pollState.generation || !isAttached(viewRoot))
		return;

	return Promise.resolve(callGeoProgress()).then(function(progress) {
		if (token !== pollState.generation || !isAttached(viewRoot))
			return null;

		var node = document.getElementById('oxidns-geo-progress');
		if (node && progress && progress.ok !== false)
			node.textContent = progress.text || '';

		return callGeoGet();
	}).then(function(state) {
		if (token !== pollState.generation || !isAttached(viewRoot) || !state)
			return;

		if (state.ok === false) {
			pollFailure(state);
			return;
		}

		pollState.failures = 0;
		showError('');
		refreshFileRows(state);

		if (state.running) {
			var btn = document.getElementById('oxidns-geo-download-btn');
			if (btn)
				btn.disabled = true;
			schedulePoll(2000);
		}
		else {
			setStatus(_('Download finished.'));
			var button = document.getElementById('oxidns-geo-download-btn');
			if (button)
				button.disabled = false;
		}
	}).catch(pollFailure);
}

function saveGeoSettings(silent) {
	var payload = {
		geoip_url: field('oxidns-geo-ip-url'),
		geosite_url: field('oxidns-geo-site-url'),
		geo_dir: field('oxidns-geo-dir'),
		geoip_sha256: normalizeSha(field('oxidns-geo-ip-sha')),
		geosite_sha256: normalizeSha(field('oxidns-geo-site-sha'))
	};

	showError('');

	if (!silent) {
		ui.showModal(_('Geo Data'), [ E('p', {}, _('Saving geo settings...')) ]);
		focusModal();
	}

	return Promise.resolve(callGeoSave(payload.geoip_url, payload.geosite_url, payload.geo_dir,
		payload.geoip_sha256, payload.geosite_sha256)).then(function(result) {
		if (!silent)
			ui.hideModal();
		if (!result || result.ok === false) {
			var message = backendMessage(result, _('Failed to save geo settings'));
			setStatus(message, true);
			if (result && result.code === 'invalid_geo_settings')
				showError(message);
			return false;
		}
		applyState(result);
		if (!silent)
			setStatus(_('Geo settings saved.'));
		return true;
	}).catch(function(err) {
		if (!silent)
			ui.hideModal();
		var message = _('Failed to save geo settings');
		setStatus(message, true);
		showError(message);
		console.warn('oxidns geo save:', err);
		return false;
	});
}

function downloadGeo() {
	var btn = document.getElementById('oxidns-geo-download-btn');

	/* 下载用后端保存的值：先把输入框里的 URL / 目录存下去，再触发下载，
	   避免「改了没保存、下载的还是旧地址」的困惑。 */
	return saveGeoSettings(true).then(function(saved) {
		if (!saved)
			return;

		if (btn)
			btn.disabled = true;
		ui.showModal(_('Geo Data'), [ E('p', {}, _('Starting download...')) ]);
		focusModal();

		return Promise.resolve(callGeoDownload(checked('oxidns-geo-restart'))).then(function(result) {
			ui.hideModal();
			if (!result || result.ok === false) {
				if (btn)
					btn.disabled = false;
				var message = backendMessage(result, _('Failed to start the download'));
				setStatus(message, true);
				showError(message);
				return;
			}
			setStatus(_('Download started.'));
			showError('');
			stopPoll();
			schedulePoll(1500);
		}).catch(function(err) {
			ui.hideModal();
			if (btn)
				btn.disabled = false;
			setStatus(_('Failed to start the download'), true);
			showError(_('Failed to start the download'));
			console.warn('oxidns geo download:', err);
		});
	}).catch(function(err) {
		ui.hideModal();
		if (btn)
			btn.disabled = false;
		setStatus(_('Failed to save geo settings'), true);
		showError(_('Failed to save geo settings'));
		console.warn('oxidns geo save before download:', err);
	});
}

function resetGeo() {
	ui.showModal(_('Geo Data'), [ E('p', {}, _('Restoring defaults...')) ]);
	focusModal();

	return Promise.resolve(callGeoReset()).then(function(result) {
		ui.hideModal();
		if (!result || result.ok === false) {
			var message = backendMessage(result, _('Failed to restore defaults'));
			setStatus(message, true);
			showError(message);
			return;
		}
		applyState(result);
		setStatus(_('Geo settings restored to defaults.'));
		showError('');
	}).catch(function(err) {
		ui.hideModal();
		setStatus(_('Failed to restore defaults'), true);
		showError(_('Failed to restore defaults'));
		console.warn('oxidns geo reset:', err);
	});
}

return view.extend({
	load: function() {
		return Promise.resolve(callGeoGet()).then(function(state) {
			return state || {};
		}).catch(function(err) {
			console.warn('oxidns geo load:', err);
			return { ok: false, code: 'rpc_unavailable' };
		});
	},

	render: function(state) {
		state = state || {};
		var running = state.running === true;

		addCleanup(stopPoll);

		var map = E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('Geo Data')),
			E('div', { 'class': 'cbi-map-descr' },
				_('Download and update the geoip.dat / geosite.dat used by OxiDNS. Defaults fetch the self-maintained NetForgeCN rules (Loyalsoldier full set plus extra ad tags); URLs and the storage directory can be customized and restored to defaults.')),
			E('div', { 'class': 'cbi-section' }, [
				E('div', { 'class': 'table cbi-section-table' }, [
					row(_('GeoIP download URL'), textInput('oxidns-geo-ip-url', state.geoip_url || '')),
					row(_('GeoSite download URL'), textInput('oxidns-geo-site-url', state.geosite_url || '')),
					row(_('Storage directory'), textInput('oxidns-geo-dir', state.geo_dir || '')),
					row(_('GeoIP SHA-256 pin'), textInput('oxidns-geo-ip-sha', state.geoip_sha256 || '')),
					row(_('GeoSite SHA-256 pin'), textInput('oxidns-geo-site-sha', state.geosite_sha256 || ''))
				]),
				E('div', { 'class': 'cbi-value-description' },
					_('Optional 64-hex SHA-256 pins. When set, downloads are verified before they are published; a mismatch aborts the update and keeps the current data.')),
				E('label', { 'style': 'display: block; margin: .5em 0 1em 0;' }, [
					E('input', {
						'id': 'oxidns-geo-restart',
						'type': 'checkbox',
						'checked': 'checked',
						'style': 'margin-right: .5em;'
					}),
					_('Restart OxiDNS after the download')
				]),
				E('div', { 'class': 'table cbi-section-table' }, [
					E('div', { 'class': 'tr table-titles' }, [
						E('div', { 'class': 'td left' }, ''),
						E('div', { 'class': 'td left' }, _('Size')),
						E('div', { 'class': 'td left' }, _('Modified')),
						E('div', { 'class': 'td left' }, _('SHA-256'))
					]),
					E('div', { 'id': 'oxidns-geo-file-rows' }, [
						fileRows('geoip.dat', state.geoip),
						fileRows('geosite.dat', state.geosite)
					])
				]),
				E('div', { 'class': 'cbi-button-row', 'style': 'margin-top: 1em;' }, [
					E('button', {
						'id': 'oxidns-geo-download-btn',
						'type': 'button',
						'class': 'btn cbi-button cbi-button-positive',
						'disabled': running ? 'disabled' : null,
						'click': function(ev) {
							ev.preventDefault();
							return confirmAction(_('Geo Data'), _('Start the geo data download now?'),
								downloadGeo);
						}
					}, _('Download / Update')),
					E('button', {
						'type': 'button',
						'class': 'btn cbi-button cbi-button-action',
						'style': 'margin-left: .5em;',
						'click': function(ev) {
							ev.preventDefault();
							return saveGeoSettings(false);
						}
					}, _('Save')),
					E('button', {
						'type': 'button',
						'class': 'btn cbi-button cbi-button-negative',
						'style': 'margin-left: .5em;',
						'click': function(ev) {
							ev.preventDefault();
							return confirmAction(_('Restore defaults'),
								_('Restore the default GeoIP and GeoSite URLs and storage directory?'),
								resetGeo);
						}
					}, _('Restore defaults'))
				]),
				E('pre', {
					'id': 'oxidns-geo-progress',
					'aria-label': _('Geo download progress'),
					'style': 'margin-top: 1em; max-height: 16em; overflow: auto; font-size: 85%;'
				}),
				E('div', {
					'id': 'oxidns-geo-status',
					'aria-live': 'polite',
					'style': 'margin-top: 1em;'
				}),
				E('div', {
					'id': 'oxidns-geo-error',
					'class': 'alert-message error',
					'aria-live': 'polite',
					'style': 'margin-top: .5em; display: none;'
				})
			])
		]);

		watchView(map);

		if (running && state.ok !== false)
			schedulePoll(1500);

		return map;
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
