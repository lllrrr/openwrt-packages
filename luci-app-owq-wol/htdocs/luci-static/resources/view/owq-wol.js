'use strict';
'require view';
'require fs';
'require ui';
'require uci';
'require poll';

return view.extend({
	icons: {
		desktop: 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHdpZHRoPSI2NCIgaGVpZ2h0PSI2NCIgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9IiMzMzMiIHN0cm9rZS13aWR0aD0iMiIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIiBzdHJva2UtbGluZWpvaW49InJvdW5kIj48cmVjdCB4PSIyIiB5PSIzIiB3aWR0aD0iMjAiIGhlaWdodD0iMTQiIHJ4PSIyIiByeT0iMiI+PC9yZWN0PjxsaW5lIHgxPSI4IiB5MT0iMjEiIHgyPSIxNiIgeTI9IjIxIj48L2xpbmU+PGxpbmUgeDE9IjEyIiB5MT0iMTciIHgyPSIxMiIgeTI9IjIxIj48L2xpbmU+PC9zdmc+',
		nas: 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHdpZHRoPSI2NCIgaGVpZ2h0PSI2NCIgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9IiMzMzMiIHN0cm9rZS13aWR0aD0iMiIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIiBzdHJva2UtbGluZWpvaW49InJvdW5kIj48cmVjdCB4PSIyIiB5PSIyIiB3aWR0aD0iMjAiIGhlaWdodD0iOCIgcng9IjIiIHJ5PSIyIj48L3JlY3Q+PHJlY3QgeD0iMiIgeT0iMTQiIHdpZHRoPSIyMCIgaGVpZ2h0PSI4IiByeD0iMiIgcnk9IjIiPjwvcmVjdD48bGluZSB4MT0iNiIgeTE9IjYiIHgyPSI2LjAxIiB5Mj0iNiI+PC9saW5lPjxsaW5lIHgxPSI2IiB5MT0iMTgiIHgyPSI2LjAxIiB5Mj0iMTgiPjwvbGluZT48L3N2Zz4=',
		laptop: 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHdpZHRoPSI2NCIgaGVpZ2h0PSI2NCIgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9IiMzMzMiIHN0cm9rZS13aWR0aD0iMiIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIiBzdHJva2UtbGluZWpvaW49InJvdW5kIj48cmVjdCB4PSIyIiB5PSIzIiB3aWR0aD0iMjAiIGhlaWdodD0iMTQiIHJ4PSIyIiByeT0iMiI+PC9yZWN0PjxsaW5lIHgxPSIyIiB5MT0iMjAiIHgyPSIyMiIgeTI9IjIwIj48L2xpbmU+PC9zdmc+',
		trash: 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHdpZHRoPSIyNCIgaGVpZ2h0PSIyNCIgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9IiNlNzRjM2MiIHN0cm9rZS13aWR0aD0iMiIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIiBzdHJva2UtbGluZWpvaW49InJvdW5kIj48cG9seWxpbmUgcG9pbnRzPSIzIDYgNSA2IDIxIDYiPjwvcG9seWxpbmU+PHBhdGggZD0iTTE5IDZ2MTRhMiAyIDAgMCAxLTIgMmgtOGEyIDIgMCAwIDEtMi0yVjZtMyAwdjE4Ij48L3BhdGg+PGxpbmUgeDE9IjEwIiB5MT0iMTEiIHgyPSIxMCIgeTI9IjE3Ij48L2xpbmU+PGxpbmUgeDE9IjE0IiB5MT0iMTEiIHgyPSIxNCIgeTI9IjE3Ij48L2xpbmU+PC9zdmc+'
	},

	css: `
		.wol-container { display: flex; flex-wrap: wrap; gap: 1.5rem; justify-content: center; margin-top: 2rem; }
		.wol-card { background: #fff; border: 1px solid #eee; border-radius: 12px; padding: 20px; width: 220px; text-align: center; position: relative; box-shadow: 0 4px 6px rgba(0,0,0,0.05); transition: all 0.2s; display: flex; flex-direction: column; align-items: center; }
		.wol-card:hover { transform: translateY(-3px); box-shadow: 0 8px 15px rgba(0,0,0,0.1); }
		.device-icon { width: 64px; height: 64px; margin-bottom: 15px; opacity: 0.9; }
		.device-name { font-weight: bold; font-size: 1.1rem; color: #333; margin-bottom: 5px; width: 100%; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
		.device-info { font-size: 0.85rem; color: #888; margin-bottom: 3px; }
		.device-iface { font-size: 0.75rem; color: #aaa; margin-bottom: 8px; font-family: monospace; }
		.btn-group { margin-top: 10px; width: 100%; display: flex; gap: 10px; align-items: center; }
		.btn-wake { flex: 1; }
		.btn-del { flex: 0 0 36px; height: 36px; padding: 6px !important; border: 1px solid #ffcccc !important; background: #fff5f5 !important; display: flex; align-items: center; justify-content: center; }
		.btn-del img { width: 20px; height: 20px; }
		.btn-del:hover { background: #ffebeb !important; }
		.status-dot { position: absolute; top: 15px; right: 15px; width: 12px; height: 12px; border-radius: 50%; background-color: #e0e0e0; border: 2px solid #fff; box-shadow: 0 0 2px rgba(0,0,0,0.2); transition: all 0.5s; }
		.status-online { background-color: #2ecc71; box-shadow: 0 0 8px #2ecc71; }
		.wol-card-add { border: 2px dashed #ddd; background: transparent; cursor: pointer; justify-content: center; color: #aaa; }
		.wol-card-add:hover { border-color: #0079D3; color: #0079D3; }
		.add-icon { font-size: 64px; line-height: 64px; margin-bottom: 10px; }
		.add-form-grid { display: grid; grid-template-columns: 100px 1fr; gap: 15px; align-items: center; margin-bottom: 20px; }
		.add-form-grid label { font-weight: bold; color: #555; text-align: right; }
		.add-form-grid input, .add-form-grid select { width: 100%; }
		.scan-list { max-height: 200px; overflow-y: auto; border: 1px solid #eee; border-radius: 6px; margin-top: 10px; display: none; }
		.scan-item { padding: 8px 10px; border-bottom: 1px solid #f0f0f0; cursor: pointer; display: flex; justify-content: space-between; align-items: center; font-size: 0.9rem; }
		.scan-item:hover { background-color: #f9f9f9; color: #0079D3; }
		.scan-item:last-child { border-bottom: none; }
		.scan-info { display: flex; flex-direction: column; }
		.scan-mac { font-size: 0.8rem; color: #999; }
		.scan-error { color: #e74c3c; padding: 10px; text-align: center; }
		.owq-footer { margin-top: 60px; text-align: center; font-size: 0.85rem; color: #999; width: 100%; }
		.owq-footer a { color: #999; text-decoration: none; font-weight: bold; transition: color 0.2s; }
		.owq-footer a:hover { color: #0079D3; }
		:host-context([data-theme="dark"]) .wol-card { background: #2a2a2a; border-color: #444; }
		:host-context([data-theme="dark"]) .device-name { color: #eee; }
		:host-context([data-theme="dark"]) .status-dot { border-color: #2a2a2a; }
		:host-context([data-theme="dark"]) .add-form-grid label { color: #ccc; }
		:host-context([data-theme="dark"]) .btn-del { background: #4a2a2a !important; border-color: #663333 !important; }
		:host-context([data-theme="dark"]) .scan-list { border-color: #444; background: #333; }
		:host-context([data-theme="dark"]) .scan-item { border-bottom-color: #444; color: #eee; }
		:host-context([data-theme="dark"]) .scan-item:hover { background-color: #444; }
	`,

	isValidMac: function(mac) {
		return /^([0-9A-Fa-f]{2}[:-]){5}([0-9A-Fa-f]{2})$/.test(mac);
	},

	isValidIP: function(ip) {
		return /^(?:[0-9]{1,3}\.){3}[0-9]{1,3}$/.test(ip);
	},

	handleWake: function(mac, name, iface) {
		var targetIface = iface || 'br-lan';
		ui.showModal(_('Waking up...'), [
			E('p', { 'class': 'spinning' }, _('Sending Magic Packet to %s...').format(name))
		]);
		fs.exec('/usr/bin/etherwake', ['-i', targetIface, '-b', mac]).then(function() {
			window.setTimeout(function() {
				ui.addNotification(null, E('p', _('Wake-up packet sent to %s via %s').format(name, targetIface)));
				ui.hideModal();
			}, 1000);
		}).catch(function(e) {
			ui.addNotification(null, E('p', _('Failed: ') + e.message));
			ui.hideModal();
		});
	},

	handleDelete: function(section_id, name) {
		ui.showModal(_('Confirm Delete'), [
			E('p', {}, _('Are you sure you want to delete device "%s"?').format(name)),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Cancel')),
				' ',
				E('button', {
					'class': 'btn cbi-button-negative',
					'click': function() {
						ui.showModal(_('Deleting...'), [ E('p', { 'class': 'spinning' }, _('Processing...')) ]);
						uci.remove('owq-wol', section_id);
						uci.save().then(function() {
							fs.exec('/sbin/uci', ['commit', 'owq-wol']).then(function() {
								window.setTimeout(function() { location.reload(); }, 300);
							});
						});
					}
				}, _('Delete'))
			])
		]);
	},

	getLanDevices: function() {
		return Promise.all([
			fs.read_direct('/proc/net/arp'),
			fs.read_direct('/tmp/dhcp.leases')
		]).then(function(data) {
			var arpData = data[0] || '';
			var dhcpData = data[1] || '';
			var leases = {};
			dhcpData.split('\n').forEach(function(line) {
				var parts = line.split(' ');
				if (parts.length >= 4) { leases[parts[1]] = parts[3]; }
			});
			var devices = [];
			var seen = {};
			arpData.split('\n').forEach(function(line) {
				var parts = line.trim().split(/\s+/);
				if (parts.length > 3 && parts[2] == '0x2' && parts[3] != '00:00:00:00:00:00') {
					var ip = parts[0];
					var mac = parts[3];
					if (!seen[mac]) {
						devices.push({ ip: ip, mac: mac, name: leases[mac] || 'Unknown Device' });
						seen[mac] = true;
					}
				}
			});
			return devices;
		});
	},

	handleAdd: function() {
		var nameInput, macInput, ipInput, iconInput, ifaceInput, scanListDiv;
		var fillForm = function(name, mac, ip) { nameInput.value = name; macInput.value = mac; ipInput.value = ip; };

		// --- 核心修复：正确处理 fs.list 返回的对象数组 ---
		fs.list('/sys/class/net').then(function(ifaces) {
			var ifaceOptions = [];
			if (ifaces && ifaces.length > 0) {
				// 按名称排序
				ifaces.sort(function(a, b) { return a.name > b.name ? 1 : -1; });
				
				ifaces.forEach(function(iface) {
					// 关键点：使用 iface.name 获取字符串名称
					var name = iface.name; 
					if (name !== 'lo') {
						var isDefault = (name === 'br-lan');
						ifaceOptions.push(E('option', { 'value': name, 'selected': isDefault ? 'selected' : null }, name));
					}
				});
			} else {
				ifaceOptions.push(E('option', { 'value': 'br-lan' }, 'br-lan'));
			}

			var handleScan = ui.createHandlerFn(this, function() {
				scanListDiv.style.display = 'block';
				scanListDiv.innerHTML = '<div class="scan-item spinning">' + _('Scanning...') + '</div>';
				this.getLanDevices().then(function(devices) {
					scanListDiv.innerHTML = '';
					if (devices.length === 0) {
						scanListDiv.appendChild(E('div', { 'class': 'scan-item' }, _('No active devices found.')));
						return;
					}
					devices.forEach(function(dev) {
						var item = E('div', { 
							'class': 'scan-item',
							'click': function() { fillForm(dev.name, dev.mac, dev.ip); }
						}, [
							E('div', { 'class': 'scan-info' }, [ E('b', {}, dev.name), E('span', { 'class': 'scan-mac' }, dev.ip) ]),
							E('div', {}, dev.mac)
						]);
						scanListDiv.appendChild(item);
					});
				}).catch(function(e) {
					scanListDiv.innerHTML = '';
					scanListDiv.appendChild(E('div', { 'class': 'scan-error' }, _('Scan failed: ') + e.message));
				});
			});

			ui.showModal(_('Add New Device'), [
				E('div', { 'class': 'add-form-grid' }, [
					E('label', {}, _('Device Name')), nameInput = E('input', { 'class': 'cbi-input-text', 'placeholder': 'e.g. My NAS' }),
					E('label', {}, _('MAC Address')), macInput = E('input', { 'class': 'cbi-input-text', 'placeholder': '00:11:22:33:44:55' }),
					E('label', {}, _('IP Address')), ipInput = E('input', { 'class': 'cbi-input-text', 'placeholder': '192.168.1.x' }),
					E('label', {}, _('Interface')), ifaceInput = E('select', { 'class': 'cbi-input-select' }, ifaceOptions),
					E('label', {}, _('Icon Type')), iconInput = E('select', { 'class': 'cbi-input-select' }, [
						E('option', { 'value': 'desktop' }, _('Desktop PC')),
						E('option', { 'value': 'nas' }, _('NAS Server')),
						E('option', { 'value': 'laptop' }, _('Laptop'))
					])
				]),
				E('div', { 'style': 'text-align: right; margin-bottom: 5px;' }, [
					E('button', { 'class': 'btn cbi-button-neutral', 'click': handleScan }, '🔍 ' + _('Scan LAN Devices'))
				]),
				scanListDiv = E('div', { 'class': 'scan-list' }),
				E('div', { 'class': 'right', 'style': 'margin-top: 20px;' }, [
					E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Cancel')), ' ',
					E('button', {
						'class': 'btn cbi-button-action',
						'click': function() {
							var name = nameInput.value.trim();
							var mac = macInput.value.trim();
							var ip = ipInput.value.trim();
							var iface = ifaceInput.value;

							if (!name) { alert(_('Device Name is required!')); return; }
							if (!this.isValidMac(mac)) { alert(_('Invalid MAC Address! Format: XX:XX:XX:XX:XX:XX')); return; }
							if (ip && !this.isValidIP(ip)) { alert(_('Invalid IP Address!')); return; }

							ui.showModal(_('Processing...'), [ E('p', { 'class': 'spinning' }, _('Saving settings...')) ]);

							var sid = uci.add('owq-wol', 'device');
							uci.set('owq-wol', sid, 'name', name);
							uci.set('owq-wol', sid, 'mac', mac);
							uci.set('owq-wol', sid, 'ip', ip);
							uci.set('owq-wol', sid, 'iface', iface);
							uci.set('owq-wol', sid, 'icon', iconInput.value);
							
							uci.save().then(function() {
								fs.exec('/sbin/uci', ['commit', 'owq-wol']).then(function() {
									location.reload();
								});
							});
						}.bind(this)
					}, _('Add Device'))
				])
			]);

		}.bind(this));
	},

	updateStatus: function(devices) {
		var tasks = [];
		devices.forEach(function(dev) {
			if (!dev.ip) return;
			var p = fs.exec('/bin/ping', ['-c', '1', '-W', '1', dev.ip]).then(function(res) {
				var isOnline = (res.code === 0);
				var dot = document.getElementById('status-' + dev['.name']);
				if (dot) { if (isOnline) dot.classList.add('status-online'); else dot.classList.remove('status-online'); }
			});
			tasks.push(p);
		});
		return Promise.all(tasks);
	},

	render: function() {
		var self = this;
		return uci.load('owq-wol').then(function() {
			var sections = uci.sections('owq-wol', 'device');
			var cards = [];
			sections.forEach(function(dev) {
				var iconSrc = self.icons[dev.icon] || self.icons['desktop'];
				var card = E('div', { 'class': 'wol-card' }, [
					E('div', { 'class': 'status-dot', 'id': 'status-' + dev['.name'] }),
					E('img', { 'class': 'device-icon', 'src': iconSrc }),
					E('div', { 'class': 'device-name', 'title': dev.name }, dev.name || 'Unknown'),
					E('div', { 'class': 'device-info' }, dev.mac),
					E('div', { 'class': 'device-info' }, dev.ip || _('No IP')),
					E('div', { 'class': 'device-iface' }, dev.iface || 'br-lan'),
					E('div', { 'class': 'btn-group' }, [
						E('button', { 'class': 'btn cbi-button-action btn-wake', 'click': ui.createHandlerFn(self, 'handleWake', dev.mac, dev.name, dev.iface) }, _('Wake')),
						E('button', { 'class': 'btn btn-del', 'click': ui.createHandlerFn(self, 'handleDelete', dev['.name'], dev.name) }, E('img', { 'src': self.icons.trash }))
					])
				]);
				cards.push(card);
			});
			var addCard = E('div', { 'class': 'wol-card wol-card-add', 'click': ui.createHandlerFn(self, 'handleAdd') }, [
				E('div', { 'class': 'add-icon' }, '+'), E('div', {}, _('Add Device'))
			]);
			cards.push(addCard);
			poll.add(function() { return self.updateStatus(sections); }, 5);
			return E('div', {}, [
				E('style', {}, self.css),
				E('h2', {}, _('OWQ Visual WOL')),
				E('div', { 'class': 'cbi-map-descr' }, _('Manage and wake up your LAN devices visually.')),
				E('div', { 'class': 'wol-container' }, cards),
				E('div', { 'class': 'owq-footer' }, [ E('span', {}, 'Developed by '), E('a', { 'href': 'https://github.com/isalikai', 'target': '_blank' }, '@github-isalikai') ])
			]);
		});
	}
});