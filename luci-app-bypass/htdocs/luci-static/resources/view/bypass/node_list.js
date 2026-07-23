'use strict';
'require view';
'require uci';
'require fs';
'require ui';

// Node List — JS-rendered table for NaiveProxy and native WireGuard nodes:
//   • A top "URL Test Address" dropdown (browser-session only)
//   • BypassCore TCP Connect + URL Test latency columns (no ICMP Ping)
//   • Per-row Edit / Copy / Delete actions. Nodes are assigned per shunt rule.
//   • A single "Add" button at the bottom.

var COL = { green: '#2dce89', red: '#fb6340', yellow: '#fb9a05' };

// Preset probe URLs for the URL Test column (mirrors passwall2).
var URL_TEST_PRESETS = [
	['https://cp.cloudflare.com/', 'Cloudflare'],
	['https://www.gstatic.com/generate_204', 'Gstatic'],
	['https://www.google.com/generate_204', 'Google'],
	['https://www.youtube.com/generate_204', 'YouTube'],
	['https://connect.rom.miui.com/generate_204', 'MIUI (CN)'],
	['https://connectivitycheck.platform.hicloud.com/generate_204', 'HiCloud (CN)'],
	['https://wifi.vivo.com.cn/generate_204', 'VIVO (CN)']
];

function api(/* action, ...args */) {
	return fs.exec('/usr/share/bypass/api.sh', Array.prototype.slice.call(arguments)).then(function (res) {
		try { return JSON.parse(res.stdout || '{}'); }
		catch (e) { return { code: -1, error: 'bad JSON' }; }
	}).catch(function (e) { return { code: -1, error: String(e) }; });
}

function latencyColor(ms) {
	if (ms == null) return COL.red;
	if (ms < 100) return COL.green;
	if (ms < 200) return COL.yellow;
	return COL.red;
}

// URL Test uses a more lenient threshold than TCP Connect (the request traverses
// the full proxy path + remote TLS + HTTP).
function urltestColor(ms) {
	if (ms == null) return COL.red;
	if (ms < 1000) return COL.green;
	if (ms < 2000) return COL.yellow;
	return COL.red;
}

function tcpProbeCacheKey(sid) { return 'bypass_tcp_probe_' + sid; }
function getCachedTcpProbe(sid) {
	try {
		var raw = localStorage.getItem(tcpProbeCacheKey(sid));
		if (!raw) return null;
		var entry = JSON.parse(raw);
		if (Date.now() - entry.t > 60000) return null;
		return entry.ms;
	} catch (e) { return null; }
}
function setCachedTcpProbe(sid, ms) {
	try { localStorage.setItem(tcpProbeCacheKey(sid), JSON.stringify({ ms: ms, t: Date.now() })); } catch (e) {}
}

function urltestCacheKey(sid, url) { return 'bypass_urltest_' + sid + '_' + encodeURIComponent(url); }
function getCachedUrltest(sid, url) {
	try {
		var raw = localStorage.getItem(urltestCacheKey(sid, url));
		if (!raw) return null;
		var entry = JSON.parse(raw);
		if (Date.now() - entry.t > 60000) return null;
		return entry.ms;
	} catch (e) { return null; }
}
function setCachedUrltest(sid, url, ms) {
	try { localStorage.setItem(urltestCacheKey(sid, url), JSON.stringify({ ms: ms, t: Date.now() })); } catch (e) {}
}

return view.extend({
	load: function () {
		return uci.load('bypass');
	},

	render: function () {
		var nodes = uci.sections('bypass', 'nodes');
		var wireguardPeers = uci.sections('bypass', 'wireguard_peer');
		var currentUrl = URL_TEST_PRESETS[2][0];
		try { currentUrl = sessionStorage.getItem('bypass_url_test_url') || currentUrl; } catch (e) {}
		if (!URL_TEST_PRESETS.some(function (pair) { return pair[0] === currentUrl; }))
			currentUrl = URL_TEST_PRESETS[2][0];

		var container = E('div', { class: 'cbi-map' }, [
			E('div', { class: 'cbi-section-descr' }, _('NaiveProxy and WireGuard outbound nodes.'))
		]);

		// This is a diagnostic input, not service configuration. Keeping it out of
		// UCI avoids LuCI's global "Unsaved Changes" state and needless restarts.
		var urlSelect = E('select', {
			class: 'cbi-input-select',
			change: function () {
				currentUrl = urlSelect.value;
				try { sessionStorage.setItem('bypass_url_test_url', currentUrl); } catch (e) {}
				document.querySelectorAll('[data-bypass-urltest-result]').forEach(function (el) {
					el.textContent = '';
				});
			}
		});
		URL_TEST_PRESETS.forEach(function (pair) {
			urlSelect.appendChild(E('option', { value: pair[0] }, _(pair[1])));
		});
		urlSelect.value = currentUrl;
		container.appendChild(E('div', { class: 'cbi-value', style: 'margin-bottom:8px' }, [
			E('label', { class: 'cbi-value-title', style: 'width:auto;padding-right:8px' }, _('URL Test Address')),
			E('div', { class: 'cbi-value-field' }, urlSelect)
		]));

		var fieldset = E('fieldset', { class: 'cbi-section cbi-tblsection' });
		var table = E('table', { class: 'table cbi-section-table' }, [
			E('tr', { class: 'tr cbi-section-table-titles' }, [
				E('th', { class: 'th cbi-section-table-cell', style: 'width:28%' }, _('Remarks')),
				E('th', { class: 'th cbi-section-table-cell', style: 'width:10%' }, _('Type')),
				E('th', { class: 'th cbi-section-table-cell', style: 'width:12%' }, _('TCP Connect')),
				E('th', { class: 'th cbi-section-table-cell', style: 'width:12%' }, _('URL Test')),
				E('th', { class: 'th cbi-section-table-cell', style: 'width:38%' }, _('Actions'))
			])
		]);
		fieldset.appendChild(table);

		if (nodes.length === 0) {
			fieldset.appendChild(E('div', { class: 'cbi-section-create' }, [
				E('em', {}, _('No nodes yet. Add one below.'))
			]));
		}

		nodes.forEach(function (sec) {
			var sid = sec['.name'];
			var nodeType = sec.node_type === 'wireguard' ? 'wireguard' : 'naiveproxy';
			var nodePeers = wireguardPeers.filter(function (peer) { return peer.node === sid; });
			var tcpProbeCell = E('td', { class: 'td cbi-value-field', style: 'white-space:nowrap' });
			var tcpProbeResult = E('span', { style: 'margin-left:6px;font-weight:bold' });
			var tcpProbeLink = E('a', {
				href: '#',
				style: 'cursor:pointer',
				click: function (ev) {
					ev.preventDefault();
					tcpProbeLink.textContent = _('Testing…');
					tcpProbeLink.style.color = COL.yellow;
					tcpProbeResult.textContent = '';
					api('node_tcp_probe', sid).then(function (r) {
						tcpProbeLink.textContent = _('Test');
						tcpProbeLink.style.color = '';
						if (r.code === 0 && r.latency_ms != null) {
							var ms = parseInt(r.latency_ms, 10);
							setCachedTcpProbe(sid, ms);
							renderTcpProbe(ms);
						} else {
							tcpProbeResult.textContent = '---';
							tcpProbeResult.style.color = COL.red;
						}
					});
				}
			}, _('Test'));

			function renderTcpProbe(ms) {
				if (ms == null) {
					tcpProbeResult.textContent = '';
					return;
				}
				tcpProbeResult.textContent = ms + ' ms';
				tcpProbeResult.style.color = latencyColor(ms);
			}

			if (nodeType === 'naiveproxy') {
				tcpProbeCell.appendChild(tcpProbeLink);
				tcpProbeCell.appendChild(tcpProbeResult);
				var cached = getCachedTcpProbe(sid);
				if (cached != null) renderTcpProbe(cached);
			} else {
				tcpProbeCell.appendChild(E('span', { style: 'color:#adb5bd' }, '---'));
			}

			// URL Test column: needs address+port to dial the node. Nodes without
			// them show an inert placeholder.
			var urltestCell = E('td', { class: 'td cbi-value-field', style: 'white-space:nowrap' });
			var hasEndpoint = nodeType === 'naiveproxy' && !!(sec.address && sec.port);
			if (!hasEndpoint) {
				urltestCell.appendChild(E('span', { style: 'color:#adb5bd' }, '---'));
			} else {
				var urltestResult = E('span', {
					style: 'margin-left:6px;font-weight:bold',
					'data-bypass-urltest-result': '1'
				});
				var urltestLink = E('a', {
					href: '#',
					style: 'cursor:pointer',
					click: function (ev) {
						ev.preventDefault();
						urltestLink.textContent = _('Testing…');
						urltestLink.style.color = COL.yellow;
						urltestResult.textContent = '';
						var testUrl = currentUrl;
						api('node_urltest', sid, testUrl).then(function (r) {
							urltestLink.textContent = _('Test');
							urltestLink.style.color = '';
							if (testUrl !== currentUrl) return;
							if (r.code === 0 && r.use_time != null) {
								var ms = parseInt(r.use_time, 10);
								setCachedUrltest(sid, testUrl, ms);
								renderUrltest(ms);
							} else {
								urltestResult.textContent = '---';
								urltestResult.style.color = COL.red;
							}
						});
					}
				}, _('Test'));

				function renderUrltest(ms) {
					if (ms == null) {
						urltestResult.textContent = '';
						return;
					}
					urltestResult.textContent = ms + ' ms';
					urltestResult.style.color = urltestColor(ms);
				}

				urltestCell.appendChild(urltestLink);
				urltestCell.appendChild(urltestResult);

				var urlCached = getCachedUrltest(sid, currentUrl);
				if (urlCached != null) renderUrltest(urlCached);
			}

			var actions = E('td', { class: 'td cbi-section-table-cell cbi-section-actions', style: 'white-space:nowrap' }, [
				E('div', { style: 'display:inline-flex;gap:4px' }, [
					E('button', {
						type: 'button',
						class: 'cbi-button cbi-button-edit',
						click: function () { location.href = L.url('admin/services/bypass/node_config') + '?section=' + encodeURIComponent(sid); }
					}, _('Edit')),
					E('button', {
						type: 'button',
						class: 'cbi-button cbi-button-add',
						click: function () { copyNode(sid); }
					}, _('Copy')),
					E('button', {
						type: 'button',
						class: 'cbi-button cbi-button-remove',
						click: function () { deleteNode(sid, sec.remarks || sid); }
					}, _('Delete'))
				])
			]);

			var endpointText = nodeType === 'wireguard'
				? (nodePeers[0] ? nodePeers[0].endpoint : '—')
				: (sec.address || '—') + ':' + (sec.port || '—');
			table.appendChild(E('tr', { class: 'tr cbi-section-table-row' }, [
				E('td', { class: 'td cbi-value-field' }, [
					E('strong', {}, sec.remarks || sid),
					E('div', { style: 'font-size:11px;color:#8898aa' }, endpointText)
				]),
				E('td', { class: 'td cbi-value-field' }, nodeType === 'wireguard' ? 'WireGuard' : 'NaiveProxy'),
				tcpProbeCell,
				urltestCell,
				actions
			]));
		});

		// Single Add button at the bottom (no toolbar above the table).
		fieldset.appendChild(E('div', { class: 'cbi-section-create', style: 'margin-top:8px' }, [
			E('button', {
				type: 'button',
				class: 'cbi-button cbi-button-add',
				click: function () {
					var newSid = 'node_' + Date.now().toString(36);
					uci.add('bypass', 'nodes', newSid);
					uci.set('bypass', newSid, 'node_type', 'naiveproxy');
					uci.set('bypass', newSid, 'protocol', 'https');
					uci.set('bypass', newSid, 'remarks', _('New Node'));
					uci.save().then(function () {
						uci.apply().then(function () {
							location.href = L.url('admin/services/bypass/node_config') + '?section=' + encodeURIComponent(newSid);
						});
					});
				}
			}, _('Add'))
		]));

		container.appendChild(fieldset);

		function copyNode(sid) {
			var src = uci.sections('bypass', 'nodes').filter(function (s) { return s['.name'] === sid; })[0];
			if (!src) return;
			var newSid = uci.add('bypass', 'nodes');
			['node_type', 'protocol', 'remarks', 'address', 'port', 'egress_interface',
				'username', 'password', 'secret_key', 'public_key', 'wireguard_address', 'mtu'].forEach(function (opt) {
				if (src[opt] != null) uci.set('bypass', newSid, opt, src[opt]);
			});
			uci.set('bypass', newSid, 'remarks', (src.remarks || sid) + ' ' + _('(copy)'));
			wireguardPeers.filter(function (peer) { return peer.node === sid; }).forEach(function (peer) {
				var newPeer = uci.add('bypass', 'wireguard_peer');
				uci.set('bypass', newPeer, 'node', newSid);
				['public_key', 'endpoint', 'allowed_ips', 'pre_shared_key', 'keep_alive'].forEach(function (opt) {
					if (peer[opt] != null) uci.set('bypass', newPeer, opt, peer[opt]);
				});
			});
			uci.save().then(function () { uci.apply().then(function () { location.reload(); }); });
		}

		function deleteNode(sid, label) {
			var modal = E('div', {
				style: 'position:fixed;inset:0;background:rgba(0,0,0,0.4);display:flex;align-items:center;justify-content:center;z-index:9999'
			}, [
				E('div', { style: 'background:#fff;padding:1.5rem;border-radius:.375rem;min-width:20rem;text-align:center' }, [
					E('p', {}, _('Delete node: %s ?').format(label)),
					E('div', { style: 'margin-top:1rem' }, [
						E('button', {
							type: 'button',
							class: 'cbi-button cbi-button-remove',
							click: function () {
								document.body.removeChild(modal);
								uci.sections('bypass', 'shunt_rules').forEach(function (rule) {
									if (rule.outbound === sid)
										uci.set('bypass', rule['.name'], 'outbound', '');
								});
								var globalRules = uci.sections('bypass', 'global_rules')[0];
								if (globalRules && globalRules.default_node === sid)
									uci.set('bypass', globalRules['.name'], 'default_node', '_direct');
								uci.sections('bypass', 'wireguard_peer').forEach(function (peer) {
									if (peer.node === sid)
										uci.remove('bypass', peer['.name']);
								});
								uci.remove('bypass', sid);
								uci.save().then(function () { uci.apply().then(function () { location.reload(); }); });
							}
						}, _('Delete')),
						' ',
						E('button', {
							type: 'button',
							class: 'cbi-button cbi-button-reset',
							click: function () { document.body.removeChild(modal); }
						}, _('Cancel'))
					])
				])
			]);
			document.body.appendChild(modal);
		}

		return container;
	}
});
