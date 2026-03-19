'use strict';
'require view';
'require rpc';
'require poll';
'require ui';

var callGetNeighbours = rpc.declare({
	object: 'luci.connected',
	method: 'get_neighbours',
	expect: { result: [] }
});

var callFlushArp = rpc.declare({
	object: 'luci.connected',
	method: 'flush_arp',
	expect: { result: 0 }
});

function ipCompare(a, b) {
	var ap = a.split('.').map(Number);
	var bp = b.split('.').map(Number);
	for (var i = 0; i < 4; i++) {
		if (ap[i] !== bp[i]) return ap[i] - bp[i];
	}
	return 0;
}

function groupByDevice(entries) {
	var devices = {};
	(entries || []).forEach(function(e) {
		if (!devices[e.device]) devices[e.device] = [];
		devices[e.device].push(e);
	});
	Object.keys(devices).forEach(function(dev) {
		devices[dev].sort(function(a, b) { return ipCompare(a.ip, b.ip); });
	});
	return devices;
}

return view.extend({
	load: function() {
		return callGetNeighbours();
	},

	pollData: function() {
		return callGetNeighbours().then(L.bind(function(entries) {
			var devices = groupByDevice(entries);
			var container = document.querySelector('#connected-devices');
			if (container) {
				container.innerHTML = '';
				container.appendChild(this.renderTable(devices));
			}
		}, this));
	},

	handleFlush: function(ev) {
		return callFlushArp().then(function() {
			return callGetNeighbours();
		}).then(L.bind(function(entries) {
			var devices = groupByDevice(entries);
			var container = document.querySelector('#connected-devices');
			if (container) {
				container.innerHTML = '';
				container.appendChild(this.renderTable(devices));
			}
		}, this)).catch(function(err) {
			ui.addNotification(null, E('p', _('Failed to flush ARP cache: ') + err.message));
		});
	},

	renderTable: function(devices) {
		var frag = document.createDocumentFragment();
		var keys = Object.keys(devices).sort();

		if (!keys.length) {
			frag.appendChild(E('p', {}, _('No connected devices found.')));
			return frag;
		}

		keys.forEach(function(dev) {
			var clients = devices[dev];
			frag.appendChild(E('h3', {}, '%s — %d %s'.format(dev, clients.length, _('client(s)'))));
			frag.appendChild(E('table', { 'class': 'table cbi-section-table' }, [
				E('tr', { 'class': 'tr table-titles' }, [
					E('th', { 'class': 'th' }, _('IP Address')),
					E('th', { 'class': 'th' }, _('MAC Address')),
					E('th', { 'class': 'th' }, _('Hostname')),
					E('th', { 'class': 'th' }, _('State'))
				])
			].concat(clients.map(function(c) {
				return E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td' }, c.ip),
					E('td', { 'class': 'td' }, c.mac),
					E('td', { 'class': 'td' }, c.hostname),
					E('td', { 'class': 'td' }, c.state)
				]);
			}))));
		});

		return frag;
	},

	render: function(entries) {
		var devices = groupByDevice(entries);

		poll.add(L.bind(this.pollData, this), 5);

		return E([], [
			E('div', { 'style': 'display:flex;align-items:center;justify-content:space-between;margin-bottom:1em;' }, [
				E('h2', { 'style': 'margin:0' }, _('Connected')),
				E('button', {
					'class': 'btn',
					'click': ui.createHandlerFn(this, 'handleFlush')
				}, _('Flush ARP Cache'))
			]),
			E('div', { 'class': 'cbi-section', 'id': 'connected-devices' },
				this.renderTable(devices)
			)
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
