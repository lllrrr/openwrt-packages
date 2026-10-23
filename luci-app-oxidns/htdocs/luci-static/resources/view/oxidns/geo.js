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
	params: [ 'geoip_url', 'geosite_url', 'geo_dir' ],
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

function textInput(id, value) {
	return E('input', {
		'id': id,
		'class': 'cbi-input-text',
		'type': 'text',
		'style': 'width: 100%',
		'value': value || ''
	});
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

function fileRows(name, info) {
	var cells = [
		E('div', { 'class': 'td left', 'style': 'width: 120px' }, name)
	];
	if (!info || !info.exists) {
		cells.push(E('div', { 'class': 'td left', 'colspan': '3' }, _('not present')));
		return E('div', { 'class': 'tr' }, cells);
	}
	cells.push(E('div', { 'class': 'td left', 'style': 'width: 120px' }, fmtSize(info.size)));
	cells.push(E('div', { 'class': 'td left', 'style': 'width: 200px' }, info.mtime || '-'));
	cells.push(E('div', { 'class': 'td left' },
		E('span', { 'style': 'font-family: monospace; font-size: 85%; word-break: break-all;' }, info.sha256 || '-')));
	return E('div', { 'class': 'tr' }, cells);
}

function refreshFileRows(state) {
	var wrap = document.getElementById('oxidns-geo-files');
	if (!wrap)
		return;
	wrap.innerHTML = '';
	wrap.appendChild(fileRows('geoip.dat', state.geoip));
	wrap.appendChild(fileRows('geosite.dat', state.geosite));
}

function applyState(state) {
	if (!state || state.ok === false)
		return;
	var ip = document.getElementById('oxidns-geo-ip-url');
	var site = document.getElementById('oxidns-geo-site-url');
	var dir = document.getElementById('oxidns-geo-dir');
	if (ip)
		ip.value = state.geoip_url || '';
	if (site)
		site.value = state.geosite_url || '';
	if (dir)
		dir.value = state.geo_dir || '';
	refreshFileRows(state);
}

var pollTimer = null;

function stopPoll() {
	if (pollTimer) {
		window.clearTimeout(pollTimer);
		pollTimer = null;
	}
}

function pollTick() {
	if (pollTimer) {
		window.clearTimeout(pollTimer);
		pollTimer = null;
	}
	L.resolveDefault(callGeoProgress(), {}).then(function(progress) {
		var node = document.getElementById('oxidns-geo-progress');
		if (node && progress)
			node.textContent = progress.text || '';
		return L.resolveDefault(callGeoGet(), {});
	}).then(function(state) {
		if (!state || state.ok === false) {
			pollTimer = null;
			return;
		}
		refreshFileRows(state);
		if (state.running) {
			pollTimer = window.setTimeout(pollTick, 2000);
		}
		else {
			pollTimer = null;
			setStatus(_('Download finished.'));
			var btn = document.getElementById('oxidns-geo-download-btn');
			if (btn)
				btn.disabled = false;
		}
	}).catch(function() {
		pollTimer = null;
	});
}

function saveGeoSettings(silent) {
	var payload = {
		geoip_url: field('oxidns-geo-ip-url'),
		geosite_url: field('oxidns-geo-site-url'),
		geo_dir: field('oxidns-geo-dir')
	};

	if (!silent)
		ui.showModal(_('Geo Data'), [ E('p', {}, _('Saving geo settings...')) ]);

	return L.resolveDefault(callGeoSave(payload.geoip_url, payload.geosite_url, payload.geo_dir), null).then(function(result) {
		if (!silent)
			ui.hideModal();
		if (!result || result.ok === false) {
			setStatus((result && (result.message || result.error)) || _('Failed to save geo settings'), true);
			return false;
		}
		applyState(result);
		if (!silent)
			setStatus(_('Geo settings saved.'));
		return true;
	}).catch(function(err) {
		if (!silent)
			ui.hideModal();
		setStatus(err.message || String(err), true);
		return false;
	});
}

function downloadGeo() {
	var btn = document.getElementById('oxidns-geo-download-btn');
	/* 下载用后端保存的值：先把输入框里的 URL / 目录存下去，再触发下载，
	   避免「改了没保存、下载的还是旧地址」的困惑。 */
	saveGeoSettings(true).then(function(saved) {
		if (!saved)
			return;
		if (btn)
			btn.disabled = true;
		ui.showModal(_('Geo Data'), [ E('p', {}, _('Starting download...')) ]);
		return L.resolveDefault(callGeoDownload(checked('oxidns-geo-restart')), null).then(function(result) {
			ui.hideModal();
			if (!result || result.ok === false) {
				if (btn)
					btn.disabled = false;
				setStatus((result && (result.message || result.error)) || _('Failed to start the download'), true);
				return;
			}
			setStatus(_('Download started.'));
			if (pollTimer)
				window.clearTimeout(pollTimer);
			pollTimer = window.setTimeout(pollTick, 1500);
		});
	});
}

function resetGeo() {
	ui.showModal(_('Geo Data'), [ E('p', {}, _('Restoring defaults...')) ]);
	return L.resolveDefault(callGeoReset(), null).then(function(result) {
		ui.hideModal();
		if (!result || result.ok === false) {
			setStatus((result && (result.message || result.error)) || _('Failed to restore defaults'), true);
			return;
		}
		applyState(result);
		setStatus(_('Geo settings restored to defaults.'));
	}).catch(function(err) {
		ui.hideModal();
		setStatus(err.message || String(err), true);
	});
}

return view.extend({
	load: function() {
		return L.resolveDefault(callGeoGet(), {});
	},

	render: function(state) {
		state = state || {};
		var running = state.running === true;

		var map = E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('Geo Data')),
			E('div', { 'class': 'cbi-map-descr' },
				_('Download and update geoip.dat / geosite.dat shared by OxiDNS and mihomo. Defaults fetch the Loyalsoldier enhanced rules via the jsDelivr CDN; URLs and the storage directory can be customized and restored to defaults.')),
			E('div', { 'class': 'cbi-section' }, [
				E('div', { 'class': 'table cbi-section-table' }, [
					row(_('GeoIP download URL'), textInput('oxidns-geo-ip-url', state.geoip_url || '')),
					row(_('GeoSite download URL'), textInput('oxidns-geo-site-url', state.geosite_url || '')),
					row(_('Storage directory'), textInput('oxidns-geo-dir', state.geo_dir || ''))
				]),
				E('label', { 'style': 'display: block; margin: .5em 0 1em 0;' }, [
					E('input', {
						'id': 'oxidns-geo-restart',
						'type': 'checkbox',
						'checked': 'checked',
						'style': 'margin-right: .5em;'
					}),
					_('Restart OxiDNS after the download')
				]),
				E('div', { 'class': 'table cbi-section-table', 'id': 'oxidns-geo-files' }, [
					E('div', { 'class': 'tr table-titles' }, [
						E('div', { 'class': 'td left' }, ''),
						E('div', { 'class': 'td left' }, _('Size')),
						E('div', { 'class': 'td left' }, _('Modified')),
						E('div', { 'class': 'td left' }, _('SHA-256'))
					]),
					fileRows('geoip.dat', state.geoip),
					fileRows('geosite.dat', state.geosite)
				]),
				E('div', { 'class': 'cbi-button-row', 'style': 'margin-top: 1em;' }, [
					E('button', {
						'id': 'oxidns-geo-download-btn',
						'class': 'btn cbi-button cbi-button-positive',
						'disabled': running ? 'disabled' : null,
						'click': function(ev) {
							ev.preventDefault();
							return downloadGeo();
						}
					}, _('Download / Update')),
					E('button', {
						'class': 'btn cbi-button cbi-button-action',
						'style': 'margin-left: .5em;',
						'click': function(ev) {
							ev.preventDefault();
							return saveGeoSettings(false);
						}
					}, _('Save')),
					E('button', {
						'class': 'btn cbi-button cbi-button-negative',
						'style': 'margin-left: .5em;',
						'click': function(ev) {
							ev.preventDefault();
							return resetGeo();
						}
					}, _('Restore defaults'))
				]),
				E('pre', {
					'id': 'oxidns-geo-progress',
					'style': 'margin-top: 1em; max-height: 16em; overflow: auto; font-size: 85%;'
				}),
				E('div', { 'id': 'oxidns-geo-status', 'style': 'margin-top: 1em;' })
			])
		]);

		if (running)
			pollTimer = window.setTimeout(pollTick, 1500);

		return map;
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
