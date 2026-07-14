'use strict';
'require view';
'require uci';
'require fs';
'require ui';

// Node List — JS-rendered table, passwall2-style but trimmed:
//   • No top options row (no url_test_url / auto_detection_time / show_node_info)
//   • No toolbar (no Add-via-link / Clear-all / Select-all / Reassign)
//   • Single TCPing latency column (no Ping / URL Test columns)
//   • Per-row Edit / Copy / Delete actions. Nodes are assigned per shunt rule.
//   • A single "Add" button at the bottom.

var COL = { green: '#2dce89', red: '#fb6340', yellow: '#fb9a05' };

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

function tcpingCacheKey(sid) { return 'bypass_tcping_' + sid; }
function getCachedTcping(sid) {
	try {
		var raw = localStorage.getItem(tcpingCacheKey(sid));
		if (!raw) return null;
		var entry = JSON.parse(raw);
		if (Date.now() - entry.t > 60000) return null;
		return entry.ms;
	} catch (e) { return null; }
}
function setCachedTcping(sid, ms) {
	try { localStorage.setItem(tcpingCacheKey(sid), JSON.stringify({ ms: ms, t: Date.now() })); } catch (e) {}
}

return view.extend({
	load: function () {
		return uci.load('bypass');
	},

	render: function () {
		var nodes = uci.sections('bypass', 'nodes');

		var container = E('div', { class: 'cbi-map' }, [
			E('div', { class: 'cbi-section-descr' }, _('NaiveProxy nodes (HTTPS/QUIC).'))
		]);

		var fieldset = E('fieldset', { class: 'cbi-section cbi-tblsection' });
		var table = E('table', { class: 'table cbi-section-table' }, [
			E('tr', { class: 'tr cbi-section-table-titles' }, [
				E('th', { class: 'th cbi-section-table-cell', style: 'width:50%' }, _('Remarks')),
				E('th', { class: 'th cbi-section-table-cell', style: 'width:15%' }, _('TCPing')),
				E('th', { class: 'th cbi-section-table-cell', style: 'width:35%' }, _('Actions'))
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
			var tcpingCell = E('td', { class: 'td cbi-value-field', style: 'white-space:nowrap' });
			var tcpingResult = E('span', { style: 'margin-left:6px;font-weight:bold' });
			var tcpingLink = E('a', {
				href: '#',
				style: 'cursor:pointer',
				click: function (ev) {
					ev.preventDefault();
					tcpingLink.textContent = _('Testing…');
					tcpingLink.style.color = COL.yellow;
					tcpingResult.textContent = '';
					api('node_tcping', sid).then(function (r) {
						tcpingLink.textContent = _('Test');
						tcpingLink.style.color = '';
						if (r.code === 0 && r.latency_ms != null) {
							var ms = parseInt(r.latency_ms, 10);
							setCachedTcping(sid, ms);
							renderTcping(ms);
						} else {
							tcpingResult.textContent = '---';
							tcpingResult.style.color = COL.red;
						}
					});
				}
			}, _('Test'));

			function renderTcping(ms) {
				if (ms == null) {
					tcpingResult.textContent = '';
					return;
				}
				tcpingResult.textContent = ms + ' ms';
				tcpingResult.style.color = latencyColor(ms);
			}

			tcpingCell.appendChild(tcpingLink);
			tcpingCell.appendChild(tcpingResult);

			var cached = getCachedTcping(sid);
			if (cached != null) renderTcping(cached);

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

			table.appendChild(E('tr', { class: 'tr cbi-section-table-row' }, [
				E('td', { class: 'td cbi-value-field' }, [
					E('strong', {}, sec.remarks || sid),
					E('div', { style: 'font-size:11px;color:#8898aa' },
						(sec.address || '—') + ':' + (sec.port || '—'))
				]),
				tcpingCell,
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
			['protocol', 'remarks', 'address', 'port', 'egress_interface', 'username', 'password'].forEach(function (opt) {
				if (src[opt] != null) uci.set('bypass', newSid, opt, src[opt]);
			});
			uci.set('bypass', newSid, 'remarks', (src.remarks || sid) + ' ' + _('(copy)'));
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
