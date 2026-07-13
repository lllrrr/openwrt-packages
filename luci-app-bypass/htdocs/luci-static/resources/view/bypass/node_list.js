'use strict';
'require view';
'require uci';
'require fs';
'require ui';

// Node List — JS-rendered table, laid out like passwall2's node_list.htm but
// trimmed to bypass's single protocol (NaiveProxy). Columns: Remarks / TCPing /
// Actions (Use / Edit / Copy / Delete). TCPing is a "Test" link that calls
// api.sh node_tcping; results are cached in localStorage for 60s (same as
// passwall2). The row matching the current global node is highlighted.

var COL = { green: '#2dce89', red: '#fb6340', yellow: '#fb9a05' };

function api(/* action, ...args */) {
	return fs.exec('/usr/share/bypass/api.sh', Array.prototype.slice.call(arguments)).then(function (res) {
		try { return JSON.parse(res.stdout || '{}'); }
		catch (e) { return { code: -1, error: 'bad JSON' }; }
	}).catch(function (e) { return { code: -1, error: String(e) }; });
}

// TCPing latency color thresholds (passwall2: <100 green, <200 yellow, else red).
function latencyColor(ms) {
	if (ms == null) return COL.red;
	if (ms < 100) return COL.green;
	if (ms < 200) return COL.yellow;
	return COL.red;
}

function tcpingCacheKey(sid) {
	return 'bypass_tcping_' + sid;
}
function getCachedTcping(sid) {
	try {
		var raw = localStorage.getItem(tcpingCacheKey(sid));
		if (!raw) return null;
		var entry = JSON.parse(raw);
		if (Date.now() - entry.t > 60000) return null; // 60s cache
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
		var currentNode = uci.get('bypass', '@global[0]', 'node') || '';

		var container = E('div', { class: 'cbi-map' }, [
			E('h2', { name: 'content' }, _('Node List')),
			E('div', { class: 'cbi-section-descr' }, _('NaiveProxy nodes (https). Click TCPing "Test" to measure latency.'))
		]);

		var fieldset = E('fieldset', { class: 'cbi-section cbi-tblsection' });

		// Header row.
		fieldset.appendChild(E('table', { class: 'table cbi-section-table' }, [
			E('tr', { class: 'tr cbi-section-table-titles' }, [
				E('th', { class: 'th cbi-section-table-cell', style: 'width:50%' }, _('Remarks')),
				E('th', { class: 'th cbi-section-table-cell', style: 'width:15%' }, _('TCPing')),
				E('th', { class: 'th cbi-section-table-cell', style: 'width:35%' }, _('Actions'))
			])
		]));

		if (nodes.length === 0) {
			fieldset.appendChild(E('div', { class: 'cbi-section-create' }, [
				E('em', {}, _('No nodes yet. Add one below.'))
			]));
		}

		var tableBody = fieldset.querySelector('table');

		// One row per node.
		nodes.forEach(function (sec) {
			var sid = sec['.name'];
			var isCurrent = (sid === currentNode);

			var tcpingCell = E('td', { class: 'td cbi-value-field', style: 'white-space:nowrap' });
			var tcpingLink = E('a', {
				href: '#',
				style: 'cursor:pointer',
				click: function (ev) {
					ev.preventDefault();
					tcpingLink.textContent = _('Testing…');
					tcpingLink.style.color = COL.yellow;
					api('node_tcping', sid).then(function (r) {
						if (r.code === 0 && r.latency_ms != null) {
							var ms = parseInt(r.latency_ms, 10);
							setCachedTcping(sid, ms);
							renderTcping(ms);
						} else {
							tcpingLink.textContent = '---';
							tcpingLink.style.color = COL.red;
						}
					});
				}
			}, _('Test'));

			function renderTcping(ms) {
				if (ms == null) {
					tcpingCell.textContent = '';
					tcpingCell.appendChild(tcpingLink);
					return;
				}
				tcpingCell.textContent = '';
				tcpingCell.appendChild(E('span', { style: 'color:' + latencyColor(ms) + ';font-weight:bold' }, ms + ' ms'));
			}

			// Render from cache if available, else show the Test link.
			var cached = getCachedTcping(sid);
			if (cached != null) renderTcping(cached);
			else tcpingCell.appendChild(tcpingLink);

			// Actions: Use / Edit / Copy / Delete (passwall2 button group).
			var actions = E('td', { class: 'td cbi-section-table-cell cbi-section-actions', style: 'white-space:nowrap' }, [
				E('div', { style: 'display:inline-flex;gap:4px' }, [
					E('button', {
						class: 'cbi-button cbi-button-apply',
						style: isCurrent ? 'opacity:1' : '',
						disabled: isCurrent,
						click: function () { useNode(sid, sec.remarks || sid); }
					}, isCurrent ? _('In use') : _('Use')),
					E('button', {
						class: 'cbi-button cbi-button-edit',
						click: function () { location.href = L.url('admin/services/bypass/node_config') + '?section=' + encodeURIComponent(sid); }
					}, _('Edit')),
					E('button', {
						class: 'cbi-button cbi-button-add',
						click: function () { copyNode(sid); }
					}, _('Copy')),
					E('button', {
						class: 'cbi-button cbi-button-remove',
						click: function () { deleteNode(sid, sec.remarks || sid); }
					}, _('Delete'))
				])
			]);

			var row = E('tr', {
				class: 'tr cbi-section-table-row' + (isCurrent ? ' _now_use_bg' : ''),
				id: 'cbi-bypass-nodes-' + sid,
				style: isCurrent ? 'background-color:rgba(94,114,228,0.27)' : ''
			}, [
				E('td', { class: 'td cbi-value-field' }, [
					E('strong', {}, sec.remarks || sid),
					E('div', { style: 'font-size:11px;color:#8898aa' },
						(sec.address || '—') + ':' + (sec.port || '—'))
				]),
				tcpingCell,
				actions
			]);
			tableBody.appendChild(row);
		});

		// Add button (creates a new nodes section, then opens the editor).
		fieldset.appendChild(E('div', { class: 'cbi-section-create', style: 'margin-top:8px' }, [
			E('button', {
				class: 'cbi-button cbi-button-add',
				click: function () {
					var newSid = uci.add('bypass', 'nodes');
					uci.set('bypass', newSid, 'type', 'NaiveProxy');
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

		// --- node actions -------------------------------------------------
		function useNode(sid, label) {
			// Simple confirm modal, then set global.node and apply.
			var modal = E('div', {
				style: 'position:fixed;inset:0;background:rgba(0,0,0,0.4);display:flex;align-items:center;justify-content:center;z-index:9999'
			}, [
				E('div', { style: 'background:#fff;padding:1.5rem;border-radius:.375rem;min-width:20rem;text-align:center' }, [
					E('p', {}, _('Use node: %s ?').format(label)),
					E('div', { style: 'margin-top:1rem' }, [
						E('button', {
							class: 'cbi-button cbi-button-apply',
							click: function () {
								document.body.removeChild(modal);
								uci.set('bypass', '@global[0]', 'node', sid);
								uci.save().then(function () {
									uci.apply().then(function () { location.reload(); });
								});
							}
						}, _('Confirm')),
						' ',
						E('button', {
							class: 'cbi-button cbi-button-reset',
							click: function () { document.body.removeChild(modal); }
						}, _('Cancel'))
					])
				])
			]);
			document.body.appendChild(modal);
		}

		function copyNode(sid) {
			var src = uci.sections('bypass', 'nodes').filter(function (s) { return s['.name'] === sid; })[0];
			if (!src) return;
			var newSid = uci.add('bypass', 'nodes');
			['type', 'remarks', 'address', 'port', 'username', 'password', 'egress_interface'].forEach(function (opt) {
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
							class: 'cbi-button cbi-button-remove',
							click: function () {
								document.body.removeChild(modal);
								uci.del('bypass', sid);
								// If it was the current node, clear the selection.
								if (sid === currentNode) {
									uci.set('bypass', '@global[0]', 'node', '');
								}
								uci.save().then(function () { uci.apply().then(function () { location.reload(); }); });
							}
						}, _('Delete')),
						' ',
						E('button', {
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
