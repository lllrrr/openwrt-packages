'use strict';
'require view';
'require rpc';
'require poll';

var callGetLogs = rpc.declare({
	object: 'luci.wrtbox',
	method: 'get_logs',
	params: ['type']
});

var callClearLogs = rpc.declare({
	object: 'luci.wrtbox',
	method: 'clear_logs',
	params: ['type']
});

return view.extend({
	currentType: 'service',
	logBoxEl: null,

	load: function() {
		return callGetLogs(this.currentType);
	},

	refreshLogs: function() {
		var self = this;
		if (!this.logBoxEl) return Promise.resolve();
		return callGetLogs(this.currentType).then(function(res) {
			var txt = (res && res.content) ? res.content : _('No log entries available.');
			self.logBoxEl.textContent = txt;
			self.logBoxEl.scrollTop = self.logBoxEl.scrollHeight;
		});
	},

	render: function(initial) {
		var self = this;

		this.logBoxEl = E('pre', {
			'id': 'wrtbox-log-viewer',
			'style': 'background:#1e1e1e;color:#d4d4d4;padding:12px;border-radius:4px;height:480px;overflow:auto;font-family:monospace;font-size:12px;white-space:pre-wrap;word-break:break-all;'
		}, (initial && initial.content) ? initial.content : _('No log entries available.'));

		var clearBtn = E('button', {
			'type': 'button',
			'id': 'wrtbox-clear-log-btn',
			'class': 'cbi-button cbi-button-negative',
			'style': 'display:none;',
			'click': function() {
				callClearLogs('tasks').then(function() {
					self.refreshLogs();
				});
			}
		}, _('Clear'));

		poll.add(function() {
			return self.refreshLogs();
		}, 4);

		return E('div', { 'class': 'cbi-map' }, [
			E('div', { 'style': 'margin-bottom:10px;display:flex;gap:8px;align-items:center;' }, [
				E('select', {
					'class': 'cbi-input-select',
					'change': function(ev) {
						self.currentType = ev.target.value;
						clearBtn.style.display = (self.currentType === 'tasks') ? 'inline-block' : 'none';
						self.refreshLogs();
					}
				}, [
					E('option', { 'value': 'service' }, _('Core Log')),
					E('option', { 'value': 'tasks' }, _('Plugin Log'))
				]),
				E('button', {
					'type': 'button',
					'class': 'cbi-button cbi-button-action',
					'click': function() { self.refreshLogs(); }
				}, _('Refresh')),
				clearBtn
			]),
			this.logBoxEl
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
