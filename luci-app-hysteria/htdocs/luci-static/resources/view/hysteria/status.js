'use strict';
'require view';
'require poll';
'require rpc';
'require dom';

var callGetStatus = rpc.declare({
	object: 'luci.hysteria',
	method: 'get_status',
	expect: { }
});

var callGetLog = rpc.declare({
	object: 'luci.hysteria',
	method: 'get_log',
	params: ['lines'],
	expect: { log: '' }
});

function renderStatus(status) {
	var running = status && status.running;
	var badge = E('span', {
		'class': running ? 'badge success' : 'badge warning'
	}, running ? _('Running') : _('Stopped'));

	var items = [
		E('div', { 'class': 'tr' }, [
			E('div', { 'class': 'td left', 'style': 'width:33%' }, _('Service status')),
			E('div', { 'class': 'td left' }, badge)
		])
	];

	if (running && status.pid) {
		items.push(E('div', { 'class': 'tr' }, [
			E('div', { 'class': 'td left', 'style': 'width:33%' }, _('PID')),
			E('div', { 'class': 'td left' }, String(status.pid))
		]));
	}

	return E('div', { 'class': 'table' }, items);
}

return view.extend({
	load: function () {
		return Promise.all([
			callGetStatus(),
			callGetLog(50)
		]);
	},

	render: function (data) {
		var status = data[0] || {};
		var logText = data[1] || '';

		var statusTable = renderStatus(status);
		var logPre = E('pre', {
			'class': 'cbi-section',
			'style': 'font-size:12px;overflow-x:auto;white-space:pre-wrap;word-wrap:break-word;max-height:500px;overflow-y:auto;'
		}, logText.replace(/\\n/g, '\n'));

		var view = E('div', { 'class': 'cbi-map' }, [
			E('h2', _('Hysteria2 Status')),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', _('Service')),
				statusTable
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', _('Log')),
				logPre
			])
		]);

		poll.add(function () {
			return Promise.all([
				callGetStatus(),
				callGetLog(50)
			]).then(function (results) {
				var newStatus = results[0] || {};
				var newLog = results[1] || '';

				dom.content(statusTable, renderStatus(newStatus).childNodes);
				dom.content(logPre, document.createTextNode(
					newLog.replace(/\\n/g, '\n')
				));
			});
		}, 5);

		return view;
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
