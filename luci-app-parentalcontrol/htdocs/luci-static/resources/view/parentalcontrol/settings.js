'use strict';
'require view';
'require rpc';
'require ui';
'require poll';

var callGetStatus = rpc.declare({ object: 'parentalcontrol', method: 'get_status', expect: {} });
var callListDevices = rpc.declare({ object: 'parentalcontrol', method: 'list_devices', expect: {} });
var callToggleGlobal = rpc.declare({ object: 'parentalcontrol', method: 'toggle_global', params: ['enabled'] });
var callToggleRule = rpc.declare({ object: 'parentalcontrol', method: 'toggle_rule', params: ['section', 'enabled'] });
var callSetOverride = rpc.declare({ object: 'parentalcontrol', method: 'set_override', params: ['section', 'minutes'] });
var callCancelOverride = rpc.declare({ object: 'parentalcontrol', method: 'cancel_override', params: ['section'] });
var callAddRule = rpc.declare({ object: 'parentalcontrol', method: 'add_rule', params: ['name', 'mac', 'schedules', 'enabled'] });
var callUpdateRule = rpc.declare({ object: 'parentalcontrol', method: 'update_rule', params: ['section', 'name', 'schedules', 'enabled'] });
var callDeleteRule = rpc.declare({ object: 'parentalcontrol', method: 'delete_rule', params: ['section'] });
var callMoveRule = rpc.declare({ object: 'parentalcontrol', method: 'move_rule', params: ['section', 'direction'] });
var callReorderRule = rpc.declare({ object: 'parentalcontrol', method: 'reorder_rule', params: ['section', 'position'] });

var DAY_NAMES = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];
var DAY_LABELS = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

var CSS = '\
.pc-header { display:flex; align-items:center; gap:12px; padding:12px 16px; border:1px solid rgba(255,255,255,0.08); border-radius:6px; margin-bottom:20px; }\
.pc-header-label { font-weight:600; font-size:15px; }\
.pc-header-status { font-size:13px; font-weight:600; }\
.pc-mac { font-family:monospace; font-size:12px; opacity:0.5; }\
.pc-sched-line { display:block; font-size:13px; line-height:1.6; }\
.pc-badge { display:inline-block; padding:3px 10px; border-radius:12px; color:#fff; font-size:11px; font-weight:600; text-transform:uppercase; letter-spacing:0.3px; white-space:nowrap; }\
.pc-badge-blocked { background:#c62828; }\
.pc-badge-override { background:#e65100; }\
.pc-badge-inactive { background:#546e7a; }\
.pc-badge-scheduled { background:#1565c0; }\
.pc-actions { display:flex; gap:4px; align-items:center; }\
.pc-btn { padding:4px 12px; border:1px solid rgba(255,255,255,0.15); border-radius:4px; background:rgba(255,255,255,0.06); cursor:pointer; font-size:12px; white-space:nowrap; }\
.pc-btn:hover { background:rgba(255,255,255,0.12); border-color:rgba(255,255,255,0.25); }\
.pc-btn-danger { border-color:#c62828; color:#ef5350; }\
.pc-btn-danger:hover { background:#c62828; color:#fff; }\
.pc-btn-warn { border-color:#e65100; color:#ff9800; }\
.pc-btn-warn:hover { background:#e65100; color:#fff; }\
.pc-btn-primary { border-color:#1565c0; color:#42a5f5; }\
.pc-btn-primary:hover { background:#1565c0; color:#fff; }\
.pc-btn-success { border-color:#2e7d32; color:#66bb6a; }\
.pc-btn-success:hover { background:#2e7d32; color:#fff; }\
.pc-btn-lg { padding:8px 24px; font-size:14px; }\
.pc-select { padding:4px 8px; border:1px solid rgba(255,255,255,0.15); border-radius:4px; background:rgba(255,255,255,0.06); font-size:12px; cursor:pointer; }\
.pc-checkbox { width:18px; height:18px; cursor:pointer; accent-color:#42a5f5; }\
.pc-override-cell { display:flex; flex-direction:row; gap:6px; align-items:center; flex-wrap:wrap; }\
.pc-override-info { font-size:13px; color:#ff9800; font-weight:600; }\
.pc-section-title { font-size:16px; font-weight:600; margin:20px 0 10px; }\
\
.pc-toast { position:fixed; bottom:24px; right:24px; padding:10px 20px; border-radius:6px; color:#fff; font-size:13px; font-weight:500; z-index:20000; opacity:0; transform:translateY(10px); transition:all 0.3s ease; pointer-events:none; }\
.pc-toast.show { opacity:1; transform:translateY(0); }\
.pc-toast-success { background:#2e7d32; }\
.pc-toast-error { background:#c62828; }\
.pc-toast-info { background:#1565c0; }\
\
.pc-modal-overlay { position:fixed; top:0; left:0; right:0; bottom:0; background:rgba(0,0,0,0.6); z-index:10000; display:flex; align-items:center; justify-content:center; overflow:hidden; }\
body.pc-modal-open { overflow:hidden !important; }\
.pc-modal { background:var(--background-color-high, #2d2d2d); border:1px solid rgba(255,255,255,0.15); border-radius:8px; padding:0; width:560px; max-width:90vw; max-height:85vh; overflow-y:auto; box-shadow:0 8px 32px rgba(0,0,0,0.5); }\
.pc-modal-header { display:flex; align-items:center; justify-content:space-between; padding:16px 20px; border-bottom:1px solid rgba(255,255,255,0.08); }\
.pc-modal-title { font-size:16px; font-weight:600; }\
.pc-modal-close { background:none; border:none; font-size:22px; cursor:pointer; opacity:0.5; padding:0 4px; line-height:1; }\
.pc-modal-close:hover { opacity:1; }\
.pc-modal-body { padding:20px; }\
.pc-modal-footer { display:flex; gap:8px; justify-content:flex-end; padding:16px 20px; border-top:1px solid rgba(255,255,255,0.08); }\
\
.pc-form-row { margin-bottom:14px; }\
.pc-form-label { display:block; font-weight:600; font-size:13px; opacity:0.6; margin-bottom:5px; }\
.pc-form-input { padding:6px 10px; border:1px solid rgba(255,255,255,0.15); border-radius:4px; background:rgba(255,255,255,0.06); font-size:13px; width:100%; box-sizing:border-box; }\
.pc-form-input-inline { width:auto; }\
.pc-device-row { display:flex; gap:10px; align-items:center; flex-wrap:wrap; }\
.pc-device-row select { flex:1 1 250px; min-width:0; }\
.pc-device-row input { flex:0 0 160px; }\
\
.pc-sched-block { padding:12px; border:1px solid rgba(255,255,255,0.08); border-radius:4px; margin-bottom:8px; }\
.pc-sched-block-header { display:flex; align-items:center; justify-content:space-between; margin-bottom:8px; }\
.pc-sched-block-title { font-size:12px; font-weight:600; opacity:0.4; text-transform:uppercase; letter-spacing:0.5px; }\
.pc-sched-block-remove { font-size:12px; color:#ef5350; cursor:pointer; background:none; border:none; padding:0; opacity:0.7; }\
.pc-sched-block-remove:hover { opacity:1; }\
.pc-day-checks { display:flex; gap:4px; flex-wrap:wrap; }\
.pc-day-btn { padding:4px 8px; border:1px solid rgba(255,255,255,0.15); border-radius:3px; background:rgba(255,255,255,0.04); cursor:pointer; font-size:12px; user-select:none; transition:all 0.15s; }\
.pc-day-btn.active { background:#1565c0; border-color:#1565c0; color:#fff; }\
.pc-day-btn:hover { border-color:rgba(255,255,255,0.3); }\
.pc-time-row { display:flex; align-items:center; gap:8px; margin-top:8px; }\
.pc-time-label { font-size:12px; opacity:0.5; font-weight:600; }\
.pc-time-input { width:120px; }\
\
.pc-drag-handle { cursor:grab; opacity:0.4; font-size:16px; user-select:none; display:flex; flex-direction:column; align-items:center; gap:2px; }\
.pc-drag-handle:hover { opacity:0.8; }\
.pc-drag-handle:active { cursor:grabbing; }\
.pc-table .tr[draggable="true"]:hover .pc-drag-handle { opacity:0.7; }\
.pc-table .tr.pc-drag-over { border-top:3px solid #42a5f5 !important; margin-top:-1px; }\
.pc-table .tr.pc-drag-over-below { border-bottom:3px solid #42a5f5 !important; margin-bottom:-1px; }\
.pc-table .tr.pc-dragging { opacity:0.3; }\
.pc-reorder-cell { display:flex; flex-direction:column; align-items:center; gap:2px; }\
.pc-btn-arrow { padding:1px 4px; font-size:10px; line-height:1; min-width:20px; text-align:center; border:1px solid rgba(255,255,255,0.1); border-radius:2px; background:rgba(255,255,255,0.04); cursor:pointer; opacity:0.4; }\
.pc-btn-arrow:hover { opacity:0.8; background:rgba(255,255,255,0.1); }\
.pc-btn-arrow[disabled] { opacity:0.1; cursor:default; pointer-events:none; }\
.pc-stats { font-size:12px; line-height:1.5; }\
.pc-stats-packets { font-weight:600; }\
.pc-stats-bytes { opacity:0.5; }\
.pc-modal-error { padding:8px 12px; margin-bottom:12px; border-radius:4px; background:rgba(198,40,40,0.15); border:1px solid rgba(198,40,40,0.3); color:#ef5350; font-size:13px; }\
\
@media screen and (max-device-width: 600px) {\
  .pc-header { flex-wrap:wrap; gap:8px; padding:10px 12px; }\
  .pc-modal { width:95vw; max-height:90vh; }\
  .pc-modal-body { padding:14px; }\
  .pc-modal-header { padding:12px 14px; }\
  .pc-modal-footer { padding:12px 14px; }\
  .pc-modal-title { font-size:14px; }\
  .pc-device-row { flex-direction:column; align-items:stretch; }\
  .pc-device-row select { flex:1 1 auto !important; width:100%; }\
  .pc-device-row input { flex:1 1 auto !important; width:100% !important; }\
  .pc-time-row { flex-wrap:wrap; }\
  .pc-time-input { width:100px; }\
  .pc-toast { bottom:12px; right:12px; left:12px; text-align:center; }\
  .pc-table .tr .td.pc-reorder-td { flex:0 0 30px !important; display:flex !important; align-items:center; justify-content:center; }\
  .pc-table .tr .td.pc-reorder-td .pc-btn-arrow { display:none; }\
  .pc-drag-handle { font-size:20px; touch-action:none; }\
  .pc-table .tr { padding:4px 6px; margin-bottom:4px; }\
  .pc-table .tr .td[data-title=\"Device\"] { flex:1 1 calc(100% - 40px); }\
  .pc-table .tr .td[data-title=\"Schedule\"] { flex:1 1 50%; }\
  .pc-table .tr .td[data-title=\"Status\"] { flex:1 1 50%; }\
  .pc-table .tr .td[data-title=\"Blocked\"]:not(.pc-stats-empty) { flex:1 1 100%; }\
  .pc-table .tr .td[data-title=\"Enabled\"] { flex:1 1 50%; text-align:left !important; }\
  .pc-table .tr .td[data-title=\"Override\"] { flex:1 1 50%; }\
  .pc-table .tr .td[data-title=\"Blocked\"].pc-stats-empty { display:none; }\
  .pc-table .tr .td.cbi-section-actions { border-top:none !important; }\
  .pc-actions { justify-content:stretch; gap:8px; }\
  .pc-actions .pc-btn { flex:1; text-align:center; padding:8px 12px; }\
}\
';

// --- Toast ---

function showToast(message, type) {
	type = type || 'success';
	var existing = document.querySelector('.pc-toast');
	if (existing) existing.remove();

	var toast = document.createElement('div');
	toast.className = 'pc-toast pc-toast-' + type;
	toast.textContent = message;
	document.body.appendChild(toast);

	requestAnimationFrame(function() {
		requestAnimationFrame(function() { toast.classList.add('show'); });
	});

	setTimeout(function() {
		toast.classList.remove('show');
		setTimeout(function() { toast.remove(); }, 300);
	}, 2500);
}

function showModalError(body, message) {
	var existing = body.querySelector('.pc-modal-error');
	if (existing) existing.remove();
	var err = E('div', { 'class': 'pc-modal-error' }, message);
	body.insertBefore(err, body.firstChild);
}

// --- Helpers ---

function formatDuration(seconds) {
	if (seconds <= 0) return '';
	var h = Math.floor(seconds / 3600);
	var m = Math.floor((seconds % 3600) / 60);
	if (h > 0 && m > 0) return h + 'h ' + m + 'm';
	if (h > 0) return h + 'h';
	return m + 'm';
}

function formatBytes(bytes) {
	if (bytes === 0) return '0 B';
	var units = ['B', 'KB', 'MB', 'GB'];
	var i = 0;
	while (bytes >= 1024 && i < units.length - 1) { bytes /= 1024; i++; }
	return (i === 0 ? bytes : bytes.toFixed(1)) + ' ' + units[i];
}

function formatPackets(packets) {
	if (packets >= 1000000) return (packets / 1000000).toFixed(1) + 'M';
	if (packets >= 1000) return (packets / 1000).toFixed(1) + 'K';
	return packets.toString();
}

function compactDays(dayList) {
	var order = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];
	var labels = { mon: 'Mon', tue: 'Tue', wed: 'Wed', thu: 'Thu', fri: 'Fri', sat: 'Sat', sun: 'Sun' };
	var sorted = dayList.slice().sort(function(a, b) { return order.indexOf(a) - order.indexOf(b); });
	if (sorted.length === 7) return 'Every day';
	if (sorted.length === 5 && sorted.join(',') === 'mon,tue,wed,thu,fri') return 'Mon-Fri';
	if (sorted.length === 2 && sorted.join(',') === 'sat,sun') return 'Sat-Sun';
	var ranges = [], i = 0;
	while (i < sorted.length) {
		var start = i;
		while (i + 1 < sorted.length && order.indexOf(sorted[i + 1]) === order.indexOf(sorted[i]) + 1) i++;
		if (i - start >= 2) ranges.push(labels[sorted[start]] + '-' + labels[sorted[i]]);
		else for (var j = start; j <= i; j++) ranges.push(labels[sorted[j]]);
		i++;
	}
	return ranges.join(', ');
}

function formatScheduleLines(scheduleStr) {
	if (!scheduleStr) return ['-'];
	return scheduleStr.split('|').map(function(s) {
		var parts = s.trim().split(' ');
		if (parts.length < 2) return s;
		return compactDays(parts[0].split(',')) + ' ' + parts[1];
	});
}

function statusBadge(status, overrideRemaining) {
	var cls, text;
	switch (status) {
		case 'active': cls = 'pc-badge pc-badge-blocked'; text = 'Blocked'; break;
		case 'override': cls = 'pc-badge pc-badge-override'; text = 'Paused (' + formatDuration(overrideRemaining) + ')'; break;
		case 'scheduled': cls = 'pc-badge pc-badge-scheduled'; text = 'Scheduled'; break;
		default: cls = 'pc-badge pc-badge-inactive'; text = 'Inactive';
	}
	return E('span', { 'class': cls }, text);
}

function parseSchedules(scheduleStr) {
	if (!scheduleStr) return [];
	return scheduleStr.split('|').map(function(s) {
		var parts = s.trim().split(' ');
		var days = parts[0] ? parts[0].split(',') : [];
		var times = parts[1] ? parts[1].split('-') : ['22:00', '07:00'];
		return { days: days, start: times[0], end: times[1] || '07:00' };
	});
}

// --- Schedule editor ---

function renderScheduleBlock(prefix, idx, sched, showRemove) {
	var block = E('div', { 'class': 'pc-sched-block', 'data-sched-idx': idx });
	var header = E('div', { 'class': 'pc-sched-block-header' });
	header.appendChild(E('span', { 'class': 'pc-sched-block-title' }, 'Schedule ' + (idx + 1)));
	if (showRemove) {
		header.appendChild(E('button', {
			'class': 'pc-sched-block-remove',
			'click': function() { var c = block.parentNode; block.remove(); renumberBlocks(c, prefix); }
		}, 'Remove'));
	}
	block.appendChild(header);

	var dayRow = E('div', { 'class': 'pc-day-checks' });
	DAY_NAMES.forEach(function(d, i) {
		var active = sched.days.indexOf(d) >= 0;
		var btn = E('span', {
			'class': 'pc-day-btn' + (active ? ' active' : ''), 'data-day': d,
			'click': function() { btn.classList.toggle('active'); hi.value = btn.classList.contains('active') ? '1' : ''; }
		}, DAY_LABELS[i]);
		var hi = E('input', { 'type': 'hidden', 'name': prefix + '_day_' + idx + '_' + d, 'value': active ? '1' : '' });
		dayRow.appendChild(btn);
		dayRow.appendChild(hi);
	});
	block.appendChild(dayRow);

	block.appendChild(E('div', { 'class': 'pc-time-row' }, [
		E('span', { 'class': 'pc-time-label' }, 'From'),
		E('input', { 'type': 'time', 'name': prefix + '_start_' + idx, 'value': sched.start, 'class': 'pc-form-input pc-form-input-inline pc-time-input' }),
		E('span', { 'class': 'pc-time-label' }, 'to'),
		E('input', { 'type': 'time', 'name': prefix + '_end_' + idx, 'value': sched.end, 'class': 'pc-form-input pc-form-input-inline pc-time-input' })
	]));
	return block;
}

function renumberBlocks(container, prefix) {
	var blocks = container.querySelectorAll('.pc-sched-block');
	blocks.forEach(function(block, newIdx) {
		block.setAttribute('data-sched-idx', newIdx);
		var title = block.querySelector('.pc-sched-block-title');
		if (title) title.textContent = 'Schedule ' + (newIdx + 1);
		DAY_NAMES.forEach(function(d) {
			var inp = block.querySelector('[name*="_day_"][name$="_' + d + '"]');
			if (inp) inp.name = prefix + '_day_' + newIdx + '_' + d;
		});
		var s = block.querySelector('[name*="_start_"]');
		if (s) s.name = prefix + '_start_' + newIdx;
		var e = block.querySelector('[name*="_end_"]');
		if (e) e.name = prefix + '_end_' + newIdx;
		var rb = block.querySelector('.pc-sched-block-remove');
		if (rb) rb.style.display = blocks.length <= 1 ? 'none' : '';
	});
}

function renderScheduleEditor(prefix, schedules) {
	if (!schedules || schedules.length === 0)
		schedules = [{ days: ['mon', 'tue', 'wed', 'thu', 'fri'], start: '22:00', end: '07:00' }];
	var wrapper = E('div');
	var bd = E('div', { 'class': 'pc-sched-blocks' });
	schedules.forEach(function(sched, idx) {
		bd.appendChild(renderScheduleBlock(prefix, idx, sched, schedules.length > 1));
	});
	wrapper.appendChild(bd);
	wrapper.appendChild(E('button', {
		'class': 'pc-btn pc-btn-primary', 'style': 'margin-top:4px;',
		'click': function(ev) {
			ev.preventDefault();
			var n = bd.querySelectorAll('.pc-sched-block').length;
			bd.appendChild(renderScheduleBlock(prefix, n, { days: ['sat', 'sun'], start: '22:00', end: '08:00' }, true));
			renumberBlocks(bd, prefix);
		}
	}, '+ Add Schedule'));
	return wrapper;
}

function collectSchedules(container, prefix) {
	var schedules = [], idx = 0;
	while (true) {
		var si = container.querySelector('[name="' + prefix + '_start_' + idx + '"]');
		if (!si) break;
		var ei = container.querySelector('[name="' + prefix + '_end_' + idx + '"]');
		var days = [];
		DAY_NAMES.forEach(function(d) {
			var inp = container.querySelector('[name="' + prefix + '_day_' + idx + '_' + d + '"]');
			if (inp && inp.value === '1') days.push(d);
		});
		if (days.length > 0 && si.value && ei.value)
			schedules.push(days.join(',') + ' ' + si.value + '-' + ei.value);
		idx++;
	}
	return schedules.join('|');
}

// --- Modal ---

function showModal(title, contentFn, footerFn) {
	var overlay = E('div', { 'class': 'pc-modal-overlay' });
	var modal = E('div', { 'class': 'pc-modal' });

	document.body.classList.add('pc-modal-open');

	var closeModal = function() {
		document.body.classList.remove('pc-modal-open');
		overlay.remove();
	};

	overlay.addEventListener('wheel', function(ev) { ev.stopPropagation(); }, { passive: false });
	overlay.addEventListener('touchmove', function(ev) {
		if (!modal.contains(ev.target)) ev.preventDefault();
	}, { passive: false });

	modal.appendChild(E('div', { 'class': 'pc-modal-header' }, [
		E('span', { 'class': 'pc-modal-title' }, title),
		E('button', { 'class': 'pc-modal-close', 'click': closeModal }, '×')
	]));
	var body = E('div', { 'class': 'pc-modal-body' });
	contentFn(body);
	modal.appendChild(body);
	var footer = E('div', { 'class': 'pc-modal-footer' });
	footerFn(footer, body, closeModal);
	modal.appendChild(footer);
	overlay.appendChild(modal);
	document.body.appendChild(overlay);
	return { close: closeModal };
}

// --- Main view ---

var _cachedDevices = [];
var _tableContainer = null;
var _globalContainer = null;

function refreshView() {
	return Promise.all([callGetStatus(), callListDevices()]).then(function(data) {
		var status = data[0] || {};
		var deviceData = data[1] || {};
		if (_globalContainer) renderGlobal(_globalContainer, status.global_enabled);
		if (_tableContainer) renderTable(_tableContainer, status.rules || [], status.global_enabled);
		_cachedDevices = (deviceData.devices || []).slice().sort(function(a, b) {
			var an = a.hostname || '', bn = b.hostname || '';
			if (an && !bn) return -1;
			if (!an && bn) return 1;
			return an.localeCompare(bn);
		});
	});
}

function renderGlobal(container, globalEnabled) {
	container.innerHTML = '';
	container.appendChild(E('span', { 'class': 'pc-header-label' }, 'Parental Control:'));
	container.appendChild(E('button', {
		'class': globalEnabled ? 'pc-btn pc-btn-danger' : 'pc-btn pc-btn-success',
		'click': function() {
			callToggleGlobal(globalEnabled ? 0 : 1).then(function() {
				showToast(globalEnabled ? 'Parental control disabled' : 'Parental control enabled');
				refreshView();
			});
		}
	}, globalEnabled ? 'Disable' : 'Enable'));
	container.appendChild(E('span', {
		'class': 'pc-header-status',
		'style': 'color:' + (globalEnabled ? '#66bb6a' : '#888')
	}, globalEnabled ? 'Active' : 'Disabled'));
}

function renderTable(container, rules, globalEnabled) {
	container.innerHTML = '';

	if (rules.length === 0) {
		container.appendChild(E('p', { 'style': 'opacity:0.5;padding:8px 0;' }, 'No parental control rules configured.'));
		return;
	}

	var table = E('div', { 'class': 'table cbi-section-table pc-table' });
	table.appendChild(E('div', { 'class': 'tr table-titles' }, [
		E('div', { 'class': 'th', 'style': 'width:30px;' }, ''),
		E('div', { 'class': 'th' }, 'Device'),
		E('div', { 'class': 'th' }, 'Schedule'),
		E('div', { 'class': 'th', 'style': 'width:120px;' }, 'Status'),
		E('div', { 'class': 'th', 'style': 'width:100px;' }, 'Blocked'),
		E('div', { 'class': 'th', 'style': 'text-align:center;width:60px;' }, 'Enabled'),
		E('div', { 'class': 'th', 'style': 'width:200px;' }, 'Override'),
		E('div', { 'class': 'th cbi-section-actions' }, '')
	]));

	var dragState = { dragIdx: -1 };

	rules.forEach(function(rule, ruleIdx) {
		var row = E('div', { 'class': 'tr', 'draggable': 'true', 'data-rule-idx': ruleIdx, 'data-rule-section': rule.section });

		row.addEventListener('dragstart', function(ev) {
			dragState.dragIdx = ruleIdx;
			row.classList.add('pc-dragging');
			ev.dataTransfer.effectAllowed = 'move';
			ev.dataTransfer.setData('text/plain', ruleIdx.toString());
		});
		row.addEventListener('dragend', function() {
			row.classList.remove('pc-dragging');
			table.querySelectorAll('.pc-drag-over, .pc-drag-over-below').forEach(function(el) {
				el.classList.remove('pc-drag-over', 'pc-drag-over-below');
			});
			dragState.dragIdx = -1;
		});
		row.addEventListener('dragover', function(ev) {
			ev.preventDefault();
			ev.dataTransfer.dropEffect = 'move';
			if (dragState.dragIdx === ruleIdx) return;
			table.querySelectorAll('.pc-drag-over, .pc-drag-over-below').forEach(function(el) {
				el.classList.remove('pc-drag-over', 'pc-drag-over-below');
			});
			if (dragState.dragIdx < ruleIdx) {
				row.classList.add('pc-drag-over-below');
			} else {
				row.classList.add('pc-drag-over');
			}
		});
		row.addEventListener('dragleave', function() {
			row.classList.remove('pc-drag-over', 'pc-drag-over-below');
		});
		row.addEventListener('drop', function(ev) {
			ev.preventDefault();
			row.classList.remove('pc-drag-over', 'pc-drag-over-below');
			var fromIdx = dragState.dragIdx;
			var toIdx = ruleIdx;
			if (fromIdx === toIdx || fromIdx < 0) return;
			var fromRule = rules[fromIdx];
			callReorderRule(fromRule.section, toIdx).then(function() {
				showToast('Moved "' + fromRule.name + '"');
				refreshView();
			});
		});

		// Reorder cell
		var reorderCell = E('div', { 'class': 'td pc-reorder-td', 'style': 'padding:4px;flex:0 0 30px;' });
		var cellContent = E('div', { 'class': 'pc-reorder-cell' });
		cellContent.appendChild(E('button', {
			'class': 'pc-btn-arrow', 'title': 'Move up',
			'disabled': ruleIdx === 0 ? '' : null,
			'click': function() {
				callMoveRule(rule.section, 'up').then(function() {
					showToast('Moved "' + rule.name + '" up');
					refreshView();
				});
			}
		}, '▲'));
		var dragHandle = E('span', { 'class': 'pc-drag-handle', 'title': 'Drag to reorder' }, '⠿');

		// Touch drag-and-drop for mobile
		(function(handle, srcIdx, srcRule) {
			var touchTarget = null;

			handle.addEventListener('touchstart', function(ev) {
				ev.preventDefault();
				dragState.dragIdx = srcIdx;
				row.classList.add('pc-dragging');
			}, { passive: false });

			handle.addEventListener('touchmove', function(ev) {
				ev.preventDefault();
				var touch = ev.touches[0];
				var el = document.elementFromPoint(touch.clientX, touch.clientY);
				if (!el) return;

				var targetRow = el.closest('.tr[data-rule-idx]');
				table.querySelectorAll('.pc-drag-over, .pc-drag-over-below').forEach(function(r) {
					r.classList.remove('pc-drag-over', 'pc-drag-over-below');
				});

				if (targetRow && targetRow !== row) {
					var targetIdx = parseInt(targetRow.getAttribute('data-rule-idx'));
					touchTarget = targetIdx;
					if (srcIdx < targetIdx) {
						targetRow.classList.add('pc-drag-over-below');
					} else {
						targetRow.classList.add('pc-drag-over');
					}
				} else {
					touchTarget = null;
				}
			}, { passive: false });

			handle.addEventListener('touchend', function() {
				row.classList.remove('pc-dragging');
				table.querySelectorAll('.pc-drag-over, .pc-drag-over-below').forEach(function(r) {
					r.classList.remove('pc-drag-over', 'pc-drag-over-below');
				});
				dragState.dragIdx = -1;

				if (touchTarget !== null && touchTarget !== srcIdx) {
					callReorderRule(srcRule.section, touchTarget).then(function() {
						showToast('Moved "' + srcRule.name + '"');
						refreshView();
					});
				}
				touchTarget = null;
			});
		})(dragHandle, ruleIdx, rule);

		cellContent.appendChild(dragHandle);
		cellContent.appendChild(E('button', {
			'class': 'pc-btn-arrow', 'title': 'Move down',
			'disabled': ruleIdx === rules.length - 1 ? '' : null,
			'click': function() {
				callMoveRule(rule.section, 'down').then(function() {
					showToast('Moved "' + rule.name + '" down');
					refreshView();
				});
			}
		}, '▼'));
		reorderCell.appendChild(cellContent);
		row.appendChild(reorderCell);

		// Device
		row.appendChild(E('div', { 'class': 'td', 'data-title': 'Device' }, [
			E('div', { 'style': 'font-weight:600;' }, rule.name || '-'),
			E('div', { 'class': 'pc-mac' }, rule.mac || '')
		]));

		// Schedule
		var schedCell = E('div', { 'class': 'td', 'data-title': 'Schedule' });
		formatScheduleLines(rule.schedules).forEach(function(line) {
			schedCell.appendChild(E('span', { 'class': 'pc-sched-line' }, line));
		});
		row.appendChild(schedCell);

		// Status
		row.appendChild(E('div', { 'class': 'td', 'data-title': 'Status' }, [statusBadge(rule.status, rule.override_remaining)]));

		// Blocked stats
		var packets = rule.blocked_packets || 0;
		var bytes = rule.blocked_bytes || 0;
		var statsCell = E('div', { 'class': 'td' + (packets === 0 && bytes === 0 ? ' pc-stats-empty' : ''), 'data-title': 'Blocked' });
		if (packets > 0 || bytes > 0) {
			statsCell.appendChild(E('div', { 'class': 'pc-stats' }, [
				E('span', { 'class': 'pc-stats-packets' }, formatPackets(packets) + ' pkts'),
				E('br'),
				E('span', { 'class': 'pc-stats-bytes' }, formatBytes(bytes))
			]));
		} else {
			statsCell.appendChild(E('span', { 'style': 'opacity:0.3;font-size:12px;' }, '—'));
		}
		row.appendChild(statsCell);

		// Enabled
		var enableCell = E('div', { 'class': 'td', 'data-title': 'Enabled', 'style': 'text-align:center;' });
		enableCell.appendChild(E('input', {
			'type': 'checkbox', 'class': 'pc-checkbox',
			'checked': rule.enabled ? '' : null,
			'change': (function(r) {
				return function(ev) {
					var enabling = ev.target.checked;
					callToggleRule(r.section, enabling ? 1 : 0).then(function() {
						showToast('"' + r.name + '" ' + (enabling ? 'enabled' : 'disabled'));
						refreshView();
					});
				};
			})(rule)
		}));
		row.appendChild(enableCell);

		// Override
		var overrideCell = E('div', { 'class': 'td', 'data-title': 'Override' });
		var oc = E('div', { 'class': 'pc-override-cell' });
		if (rule.enabled && rule.status === 'active') {
			oc.appendChild(E('select', {
				'class': 'pc-select',
				'change': (function(r) {
					return function(ev) {
						var m = parseInt(ev.target.value);
						if (m > 0) {
							callSetOverride(r.section, m).then(function() {
								showToast('"' + r.name + '" paused for ' + (m >= 60 ? (m/60) + 'h' : m + 'm'));
								refreshView();
							});
						}
					};
				})(rule)
			}, [
				E('option', { 'value': '0' }, 'Pause...'),
				E('option', { 'value': '30' }, '30 min'),
				E('option', { 'value': '60' }, '1 hour'),
				E('option', { 'value': '120' }, '2 hours')
			]));
		} else if (rule.status === 'override') {
			oc.appendChild(E('span', { 'class': 'pc-override-info' }, 'Paused ' + formatDuration(rule.override_remaining)));
			oc.appendChild(E('button', {
				'class': 'pc-btn pc-btn-warn',
				'click': (function(r) {
					return function() {
						callCancelOverride(r.section).then(function() {
							showToast('"' + r.name + '" blocking resumed');
							refreshView();
						});
					};
				})(rule)
			}, 'Resume'));
		} else {
			oc.appendChild(E('span', { 'style': 'opacity:0.3;font-size:12px;' }, '—'));
		}
		overrideCell.appendChild(oc);
		row.appendChild(overrideCell);

		// Actions
		var actions = E('div', { 'class': 'td cbi-section-actions' });
		var ar = E('div', { 'class': 'pc-actions' });
		ar.appendChild(E('button', {
			'class': 'pc-btn pc-btn-primary',
			'click': (function(r) { return function() { openEditModal(r); }; })(rule)
		}, 'Edit'));
		ar.appendChild(E('button', {
			'class': 'pc-btn pc-btn-danger',
			'click': (function(r) {
				return function() {
					if (confirm('Delete rule "' + (r.name || r.mac) + '"?')) {
						callDeleteRule(r.section).then(function() {
							showToast('"' + r.name + '" deleted');
							refreshView();
						});
					}
				};
			})(rule)
		}, 'Delete'));
		actions.appendChild(ar);
		row.appendChild(actions);
		table.appendChild(row);
	});

	container.appendChild(table);
}

return view.extend({
	load: function() {
		return Promise.all([callGetStatus(), callListDevices()]);
	},

	render: function(data) {
		var status = data[0] || {};
		var deviceData = data[1] || {};
		var rules = status.rules || [];
		var globalEnabled = status.global_enabled;

		_cachedDevices = (deviceData.devices || []).slice().sort(function(a, b) {
			var an = a.hostname || '', bn = b.hostname || '';
			if (an && !bn) return -1;
			if (!an && bn) return 1;
			return an.localeCompare(bn);
		});

		var viewEl = E('div', { 'class': 'cbi-map' });
		viewEl.appendChild(E('style', {}, CSS));
		viewEl.appendChild(E('h2', {}, 'Parental Control'));

		_globalContainer = E('div', { 'class': 'pc-header' });
		renderGlobal(_globalContainer, globalEnabled);
		viewEl.appendChild(_globalContainer);

		var titleRow = E('div', { 'style': 'display:flex; align-items:center; justify-content:space-between; margin:20px 0 10px;' });
		titleRow.appendChild(E('div', { 'class': 'pc-section-title', 'style': 'margin:0;' }, 'Controlled Devices'));
		titleRow.appendChild(E('button', {
			'class': 'pc-btn pc-btn-success',
			'click': function() { openAddModal(); }
		}, '+ Add Rule'));
		viewEl.appendChild(titleRow);

		_tableContainer = E('div');
		renderTable(_tableContainer, rules, globalEnabled);
		viewEl.appendChild(_tableContainer);

		poll.add(function() { refreshView(); });

		return viewEl;
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});

function openAddModal() {
	showModal('Add New Rule', function(body) {
		body.appendChild(E('div', { 'class': 'pc-form-row' }, [
			E('span', { 'class': 'pc-form-label' }, 'Device Name'),
			E('input', { 'type': 'text', 'name': 'rule_name', 'placeholder': 'e.g. Kids iPad', 'class': 'pc-form-input',
				'input': function() { var err = body.querySelector('.pc-modal-error'); if (err) err.remove(); }
			})
		]));
		var devRow = E('div', { 'class': 'pc-form-row' });
		devRow.appendChild(E('span', { 'class': 'pc-form-label' }, 'Device'));
		var dd = E('div', { 'class': 'pc-device-row' });
		var sel = E('select', { 'name': 'rule_mac', 'class': 'pc-form-input pc-form-input-inline',
			'change': function() {
				var opt = sel.options[sel.selectedIndex];
				var nameInput = body.querySelector('[name="rule_name"]');
				if (nameInput && !nameInput.value.trim() && opt.dataset.hostname) {
					nameInput.value = opt.dataset.hostname;
				}
				var err = body.querySelector('.pc-modal-error');
				if (err) err.remove();
			}
		});
		sel.appendChild(E('option', { 'value': '' }, '-- Select a device --'));
		_cachedDevices.forEach(function(dev) {
			var lbl = dev.mac;
			var hostname = '';
			if (dev.hostname && dev.hostname !== 'unknown' && dev.hostname !== '') {
				hostname = dev.hostname;
				lbl = hostname + ' (' + dev.mac + ')';
			}
			if (dev.ip) lbl += ' - ' + dev.ip;
			var opt = E('option', { 'value': dev.mac, 'data-hostname': hostname }, lbl);
			sel.appendChild(opt);
		});
		dd.appendChild(sel);
		dd.appendChild(E('span', { 'style': 'opacity:0.4;font-size:12px;' }, 'or'));
		dd.appendChild(E('input', { 'type': 'text', 'name': 'rule_mac_manual', 'placeholder': 'AA:BB:CC:DD:EE:FF', 'class': 'pc-form-input pc-form-input-inline', 'style': 'width:160px;' }));
		devRow.appendChild(dd);
		body.appendChild(devRow);
		body.appendChild(E('div', { 'class': 'pc-form-row' }, [
			E('span', { 'class': 'pc-form-label' }, 'Block Schedule'),
			renderScheduleEditor('add', null)
		]));
	}, function(footer, body, closeModal) {
		footer.appendChild(E('button', { 'class': 'pc-btn', 'click': closeModal }, 'Cancel'));
		footer.appendChild(E('button', {
			'class': 'pc-btn pc-btn-success pc-btn-lg',
			'click': function() {
				var name = body.querySelector('[name="rule_name"]').value.trim();
				var mac = body.querySelector('[name="rule_mac"]').value;
				var mm = body.querySelector('[name="rule_mac_manual"]').value.trim();
				if (mm) mac = mm;
				if (!name) { showModalError(body, 'Please enter a device name.'); return; }
				if (!mac) { showModalError(body, 'Please select or enter a MAC address.'); return; }
				var scheds = collectSchedules(body, 'add');
				if (!scheds) { showModalError(body, 'Please configure at least one schedule.'); return; }
				callAddRule(name, mac, scheds, 1).then(function() {
					closeModal();
					showToast('"' + name + '" added');
					refreshView();
				});
			}
		}, 'Add Rule'));
	});
}

function openEditModal(rule) {
	showModal('Edit Rule — ' + (rule.name || rule.mac), function(body) {
		body.appendChild(E('div', { 'class': 'pc-form-row' }, [
			E('span', { 'class': 'pc-form-label' }, 'Device Name'),
			E('input', { 'type': 'text', 'name': 'edit_name', 'value': rule.name || '', 'class': 'pc-form-input',
				'input': function() { var err = body.querySelector('.pc-modal-error'); if (err) err.remove(); }
			})
		]));
		body.appendChild(E('div', { 'class': 'pc-form-row' }, [
			E('span', { 'class': 'pc-form-label' }, 'MAC Address'),
			E('input', { 'type': 'text', 'value': rule.mac || '', 'class': 'pc-form-input', 'disabled': '', 'style': 'opacity:0.5;' })
		]));
		body.appendChild(E('div', { 'class': 'pc-form-row' }, [
			E('span', { 'class': 'pc-form-label' }, 'Block Schedule'),
			renderScheduleEditor('edit', parseSchedules(rule.schedules))
		]));
	}, function(footer, body, closeModal) {
		footer.appendChild(E('button', { 'class': 'pc-btn', 'click': closeModal }, 'Cancel'));
		footer.appendChild(E('button', {
			'class': 'pc-btn pc-btn-success pc-btn-lg',
			'click': function() {
				var name = body.querySelector('[name="edit_name"]').value.trim();
				if (!name) { showModalError(body, 'Please enter a device name.'); return; }
				var scheds = collectSchedules(body, 'edit');
				if (!scheds) { showModalError(body, 'Please configure at least one schedule.'); return; }
				callUpdateRule(rule.section, name, scheds, rule.enabled ? 1 : 0).then(function() {
					closeModal();
					showToast('"' + name + '" updated');
					refreshView();
				});
			}
		}, 'Save Changes'));
	});
}
