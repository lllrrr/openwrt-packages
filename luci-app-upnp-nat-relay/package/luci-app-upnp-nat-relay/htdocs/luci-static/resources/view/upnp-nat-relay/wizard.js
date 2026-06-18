'use strict';
'require view';
'require ui';
'require rpc';
'require uci';
'require form';
'require network';
'require upnp-nat-relay/utils as utils';

var callStatus = rpc.declare({
	object: 'upnp_nat_relay',
	method: 'status',
	expect: { '': {} }
});

var callCheckEnv = rpc.declare({
	object: 'upnp_nat_relay',
	method: 'check-env',
	expect: { '': {} }
});

var callCheckNetwork = rpc.declare({
	object: 'upnp_nat_relay',
	method: 'check-network',
	expect: { '': {} }
});

var callDryRun = rpc.declare({
	object: 'upnp_nat_relay',
	method: 'dry-run',
	expect: { '': {} }
});

var callSetupInterface = rpc.declare({
	object: 'upnp_nat_relay',
	method: 'setup-interface',
	expect: { '': {} }
});

var callFixZone = rpc.declare({
	object: 'upnp_nat_relay',
	method: 'fix-zone',
	expect: { '': {} }
});

var callSetupOpenclash = rpc.declare({
	object: 'upnp_nat_relay',
	method: 'setup-openclash',
	expect: { '': {} }
});

var callInitAction = rpc.declare({
	object: 'luci',
	method: 'setInitAction',
	params: ['name', 'action'],
	expect: { result: false }
});

function initAction(action) {
	return callInitAction('upnp_nat_relay', action);
}

return view.extend({
	step: 1,
	totalSteps: 10,
	wizardMode: 'safe',
	wizardData: {
		bind_ifname: '',
		bind_ip: '',
		downstream_lan_gateway: '',
		downstream_lan_subnet: '',
		downstream_wan_ip: '',
		upstream_wan_if: '',
		allowed_external_ports: '40000-65535',
		openclash_mode: 'prompt',
		enabled: '1'
	},
	pingResult: null,
	upnpcResult: null,
	uciChanges: [],
	devices: [],
	interfaces: [],
	interfaceChoices: [],

	load: function() {
		return uci.load('upnp_nat_relay');
	},

	render: function(data) {
		utils.loadSharedCSS();
		var self = this;
		var container = E('div', { 'class': 'cbi-map' });

		container.appendChild(E('h2', { 'class': 'cbi-map-title' }, _('Setup Wizard')));

		var modeBar = E('div', { 'class': 'cbi-section ubr-mode-bar' });
		var safeBtn = E('button', {
			'class': 'ubr-mode-btn' + (self.wizardMode === 'safe' ? ' active' : ''),
			'click': function() {
				self.wizardMode = 'safe';
				safeBtn.classList.add('active');
				autoBtn.classList.remove('active');
				self.renderStep(container);
			}
		}, _('Safe Mode (Detect Only)'));
		var autoBtn = E('button', {
			'class': 'ubr-mode-btn' + (self.wizardMode === 'auto' ? ' active' : ''),
			'click': function() {
				self.wizardMode = 'auto';
				autoBtn.classList.add('active');
				safeBtn.classList.remove('active');
				self.renderStep(container);
			}
		}, _('Auto Mode (Apply Changes)'));
		modeBar.appendChild(safeBtn);
		modeBar.appendChild(autoBtn);
		container.appendChild(modeBar);

		var stepContainer = E('div', { 'id': 'wizard-step' });
		container.appendChild(stepContainer);

		this.renderStep(container);

		utils.appendFooter(container, {
			project: 'UPnP NAT Relay',
			repoUrl: 'https://github.com/hello-yunshu/luci-app-upnp-nat-relay'
		});

		return container;
	},

	createField: function(label, inputEl, description) {
		var row = E('div', { 'class': 'cbi-value' });
		row.appendChild(E('label', { 'class': 'cbi-value-title' }, label));
		var fieldDiv = E('div', { 'class': 'cbi-value-field' });
		fieldDiv.appendChild(inputEl);
		if (description) {
			fieldDiv.appendChild(E('div', { 'class': 'cbi-value-description' }, description));
		}
		row.appendChild(fieldDiv);
		return row;
	},

	getDeviceName: function(dev) {
		return dev ? (typeof(dev) === 'string' ? dev : (dev.getName ? dev.getName() : dev.name)) : '';
	},

	getInterfaceName: function(iface) {
		return iface ? (typeof(iface) === 'string' ? iface : (iface.getName ? iface.getName() : iface.name)) : '';
	},

	normalizeDeviceAddrs: function(dev) {
		var addrs = dev ? (dev.getIPAddrs ? dev.getIPAddrs() : (dev.ipaddrs || dev.ipaddrs4 || [])) : [];
		if (!Array.isArray(addrs))
			addrs = [ addrs ];
		return addrs;
	},

	ipv4SubnetFromCIDR: function(cidrAddr) {
		var parts = String(cidrAddr || '').split('/');
		var cidr = +parts[1];
		if (!parts[0] || isNaN(cidr) || cidr < 0 || cidr > 32)
			return '';
		var octets = parts[0].split('.');
		if (octets.length !== 4)
			return '';
		for (var k = 0; k < octets.length; k++) {
			octets[k] = +octets[k];
			if (isNaN(octets[k]) || octets[k] < 0 || octets[k] > 255)
				return '';
		}
		if (cidr === 0)
			return '0.0.0.0/0';
		var ipInt = octets[0] * 16777216 + octets[1] * 65536 + octets[2] * 256 + octets[3];
		var block = Math.pow(2, 32 - cidr);
		var netInt = Math.floor(ipInt / block) * block;
		var o1 = Math.floor(netInt / 16777216);
		var rem = netInt % 16777216;
		var o2 = Math.floor(rem / 65536);
		rem = rem % 65536;
		var o3 = Math.floor(rem / 256);
		var o4 = rem % 256;
		return [ o1, o2, o3, o4 ].join('.') + '/' + cidr;
	},

	findDevice: function(name) {
		var devices = this.devices || [];
		for (var i = 0; i < devices.length; i++) {
			if (this.getDeviceName(devices[i]) === name)
				return devices[i];
		}
		return null;
	},

	getInterfaceDeviceName: function(iface) {
		var dev = null;
		if (!iface)
			return '';
		if (iface.getL3Device)
			dev = iface.getL3Device();
		if (!dev && iface.getDevice)
			dev = iface.getDevice();
		return this.getDeviceName(dev) || iface.l3_device || iface.device || '';
	},

	getInterfaceAddrs: function(iface) {
		var addrs = this.normalizeDeviceAddrs(iface);
		var dev = this.findDevice(this.getInterfaceDeviceName(iface));
		if (dev)
			addrs = addrs.concat(this.normalizeDeviceAddrs(dev));
		return addrs;
	},

	formatInterfaceLabel: function(ifName, devName) {
		if (devName && devName !== ifName)
			return '%s (%s)'.format(ifName, devName);
		return ifName;
	},

	buildInterfaceChoices: function() {
		var choices = [];
		var seen = {};
		for (var i = 0; i < (this.interfaces || []).length; i++) {
			var ifName = this.getInterfaceName(this.interfaces[i]);
			if (!ifName || seen[ifName])
				continue;
			var ifDevName = this.getInterfaceDeviceName(this.interfaces[i]);
			seen[ifName] = true;
			choices.push({ name: ifName, label: this.formatInterfaceLabel(ifName, ifDevName), addrs: this.getInterfaceAddrs(this.interfaces[i]) });
		}
		for (var j = 0; j < (this.devices || []).length; j++) {
			var devName = this.getDeviceName(this.devices[j]);
			if (!devName || seen[devName])
				continue;
			seen[devName] = true;
			choices.push({ name: devName, label: '%s (%s)'.format(devName, _('device')), addrs: this.normalizeDeviceAddrs(this.devices[j]) });
		}
		this.interfaceChoices = choices;
		return choices;
	},

	loadInterfaceChoices: function() {
		var self = this;
		var getLogicalInterfaces = network.getNetworks || network.getInterfaces;
		return Promise.all([
			network.getDevices().catch(function() {
				return [];
			}),
			getLogicalInterfaces ? getLogicalInterfaces.call(network).catch(function() {
				return [];
			}) : Promise.resolve([])
		]).then(function(results) {
			self.devices = results[0] || [];
			self.interfaces = results[1] || [];
			return self.buildInterfaceChoices();
		});
	},

	getChoiceAddrs: function(ifname) {
		var choices = this.interfaceChoices || [];
		if (!ifname)
			return [];
		for (var i = 0; i < choices.length; i++) {
			if (choices[i].name === ifname)
				return choices[i].addrs || [];
		}
		return [];
	},

	getDeviceIPv4: function(ifname) {
		var addrs = this.getChoiceAddrs(ifname);
		if (!ifname)
			return '';
		for (var j = 0; j < addrs.length; j++) {
			var addr = addrs[j];
			if (!addr)
				continue;
			if (typeof(addr) === 'string') {
				addr = addr.split('/')[0];
			} else if (addr.address) {
				addr = addr.address;
			} else {
				continue;
			}
			if (/^\d+\.\d+\.\d+\.\d+$/.test(addr))
				return addr;
		}
		return '';
	},

	getDeviceSubnet: function(ifname) {
		var addrs = this.getChoiceAddrs(ifname);
		if (!ifname)
			return '';
		for (var j = 0; j < addrs.length; j++) {
			var addr = addrs[j];
			if (!addr)
				continue;
			if (typeof(addr) === 'string') {
				addr = addr;
			} else if (addr.address && addr.mask) {
				addr = addr.address + '/' + addr.mask;
			} else if (addr.address && addr.prefix) {
				addr = addr.address + '/' + addr.prefix;
			} else {
				continue;
			}
			var subnet = this.ipv4SubnetFromCIDR(addr);
			if (subnet)
				return subnet;
		}
		return '';
	},

	applyDetectedNetwork: function(result) {
		result = result || {};
		var filled = 0;
		var detectedBindIp = result.detected_bind_ip || result.bind_ip || this.getDeviceIPv4(this.wizardData.bind_ifname);
		var detectedSubnet = result.detected_downstream_lan_subnet || this.getDeviceSubnet(this.wizardData.bind_ifname);
		var detectedGateway = result.detected_downstream_lan_gateway || '';
		if (!this.wizardData.bind_ip && detectedBindIp) {
			this.wizardData.bind_ip = detectedBindIp;
			filled++;
		}
		if (!this.wizardData.downstream_lan_gateway && detectedGateway) {
			this.wizardData.downstream_lan_gateway = detectedGateway;
			filled++;
		}
		if (!this.wizardData.downstream_lan_subnet && detectedSubnet) {
			this.wizardData.downstream_lan_subnet = detectedSubnet;
			filled++;
		}
		if (!this.wizardData.downstream_wan_ip && result.detected_downstream_wan_ip) {
			this.wizardData.downstream_wan_ip = result.detected_downstream_wan_ip;
			filled++;
		}
		if (!this.wizardData.upstream_wan_if && result.detected_upstream_wan_if) {
			this.wizardData.upstream_wan_if = result.detected_upstream_wan_if;
			filled++;
		}
		return filled;
	},

	setDetectedInputValue: function(inputEl, value) {
		if (!inputEl || !value)
			return;
		if (inputEl.tagName === 'SELECT') {
			var hasOption = false;
			for (var i = 0; i < inputEl.options.length; i++) {
				if (inputEl.options[i].value === value) {
					hasOption = true;
					break;
				}
			}
			if (!hasOption)
				inputEl.appendChild(E('option', { 'value': value }, value));
		}
		inputEl.value = value;
	},

	createDetectButton: function(self, inputEl, options) {
		options = options || {};
		var detectBtn = E('button', {
			'class': 'cbi-button cbi-button-apply ubr-ml-05',
			'click': function() {
				var btn = this;
				self.collectStepData();
				var setValue = function(value) {
					if (!value)
						return false;
					self.setDetectedInputValue(inputEl, value);
					if (options.field)
						self.wizardData[options.field] = value;
					if (options.afterDetect)
						options.afterDetect(value);
					return true;
				};
				var localValue = options.localValue ? options.localValue() : '';
				if (setValue(localValue)) {
					return;
				}
				btn.disabled = true;
				btn.textContent = _('Detecting...');
				self.applyTempUci().then(function() {
					return callCheckNetwork();
				}).then(function(result) {
					self.applyDetectedNetwork(result);
					var detectedValue = options.valueFromResult ? options.valueFromResult(result || {}) : '';
					if (setValue(detectedValue)) {
						return;
					} else {
						ui.addNotification(null, E('p', options.emptyMessage || _('Could not auto-detect value.')), 'warning');
					}
				}).catch(function(e) {
					ui.addNotification(null, E('p', _('Auto-detect failed: ') + (e.message || e)), 'error');
				}).finally(function() {
					btn.disabled = false;
					btn.textContent = _('Auto Detect');
				});
			}
		}, _('Auto Detect'));
		return detectBtn;
	},

	renderStep: function(container) {
		var stepContainer = container.querySelector('#wizard-step');
		if (!stepContainer) return;

		while (stepContainer.firstChild)
			stepContainer.removeChild(stepContainer.firstChild);

		var self = this;
		var s = E('div', { 'class': 'cbi-section ubr-wizard-step-card' });

		var progressBar = E('div', { 'class': 'ubr-wizard-progress' });
		for (var i = 1; i <= this.totalSteps; i++) {
			var dotClass = 'ubr-wizard-dot';
			if (i < self.step) dotClass += ' done';
			else if (i === self.step) dotClass += ' active';
			progressBar.appendChild(E('span', { 'class': dotClass }, String(i)));
			if (i < this.totalSteps) {
				var lineClass = 'ubr-wizard-line';
				if (i < self.step) lineClass += ' done';
				progressBar.appendChild(E('span', { 'class': lineClass }));
			}
		}
		s.appendChild(progressBar);

		var title = E('h3', {}, _('Step %d of %d').format(self.step, self.totalSteps));
		s.appendChild(title);

		if (self.step === 1) {
			s.appendChild(E('p', {}, _('Select the interface connected to the downstream router LAN side.')));
			s.appendChild(E('p', { 'class': 'ubr-text-warning' },
				_('This interface is only for reading UPnP mappings. Do not set it as default gateway.')));

			var ifSelect = E('select', {
				'class': 'cbi-input-select',
				'id': 'wiz-ifname',
				'change': function(ev) {
					self.wizardData.bind_ifname = ev.target.value;
					var ip = self.getDeviceIPv4(self.wizardData.bind_ifname);
					if (ip)
						self.wizardData.bind_ip = ip;
					var subnet = self.getDeviceSubnet(self.wizardData.bind_ifname);
					if (subnet)
						self.wizardData.downstream_lan_subnet = subnet;
				}
			});
			self.loadInterfaceChoices().then(function(choices) {
				for (var i = 0; i < choices.length; i++) {
					var name = choices[i].name;
					var opt = E('option', { 'value': name }, choices[i].label || name);
					if (name === self.wizardData.bind_ifname)
						opt.selected = true;
					ifSelect.appendChild(opt);
				}
				var ip = self.getDeviceIPv4(self.wizardData.bind_ifname);
				if (ip && !self.wizardData.bind_ip)
					self.wizardData.bind_ip = ip;
				var subnet = self.getDeviceSubnet(self.wizardData.bind_ifname);
				if (subnet && !self.wizardData.downstream_lan_subnet)
					self.wizardData.downstream_lan_subnet = subnet;
			});

			s.appendChild(self.createField(
				_('Interface') + ': ',
				ifSelect,
				_('Select the interface connected to the downstream router LAN side. The underlying device is resolved automatically.')
			));

		} else if (self.step === 2) {
			s.appendChild(E('p', {}, _('Enter or auto-detect the IP address on the selected interface.')));

				var ipInput = E('input', {
					'type': 'text',
					'class': 'cbi-input-text',
					'id': 'wiz-bind-ip',
					'value': self.wizardData.bind_ip || self.getDeviceIPv4(self.wizardData.bind_ifname),
					'placeholder': _('e.g. 192.168.1.50')
				});
			var ipFieldWrap = E('div', { 'class': 'ubr-flex-center' });
			ipFieldWrap.appendChild(ipInput);
			ipFieldWrap.appendChild(self.createDetectButton(self, ipInput, {
				field: 'bind_ip',
				localValue: function() {
					return self.getDeviceIPv4(self.wizardData.bind_ifname);
				},
				valueFromResult: function(result) {
					return result.detected_bind_ip || result.bind_ip || '';
				},
				afterDetect: function() {
					if (!self.wizardData.downstream_lan_subnet)
						self.wizardData.downstream_lan_subnet = self.getDeviceSubnet(self.wizardData.bind_ifname);
				},
				emptyMessage: _('Could not auto-detect IP.')
			}));

			s.appendChild(self.createField(
				_('Interface IP') + ': ',
				ipFieldWrap,
				_('IP address on the read interface. Must be on the same subnet as the downstream router LAN.')
			));

		} else if (self.step === 3) {
			s.appendChild(E('p', {}, _('Enter the downstream router LAN gateway IP address.')));

			var gwInput = E('input', {
				'type': 'text',
				'class': 'cbi-input-text',
				'id': 'wiz-lan-gw',
				'value': self.wizardData.downstream_lan_gateway,
				'placeholder': _('e.g. 192.168.1.1')
			});
			var gwFieldWrap = E('div', { 'class': 'ubr-flex-center' });
			gwFieldWrap.appendChild(gwInput);
			gwFieldWrap.appendChild(self.createDetectButton(self, gwInput, {
				field: 'downstream_lan_gateway',
				valueFromResult: function(result) {
					return result.detected_downstream_lan_gateway || result.downstream_lan_gateway || '';
				},
				emptyMessage: _('Could not auto-detect downstream LAN gateway.')
			}));
			s.appendChild(self.createField(
				_('Downstream LAN Gateway') + ': ',
				gwFieldWrap,
				_('The LAN-side gateway IP address of the downstream router.')
			));

			var subnetInput = E('input', {
				'type': 'text',
				'class': 'cbi-input-text',
				'id': 'wiz-lan-subnet',
				'value': self.wizardData.downstream_lan_subnet || self.getDeviceSubnet(self.wizardData.bind_ifname),
				'placeholder': _('e.g. 192.168.1.0/24')
			});
			var subnetFieldWrap = E('div', { 'class': 'ubr-flex-center' });
			subnetFieldWrap.appendChild(subnetInput);
			subnetFieldWrap.appendChild(self.createDetectButton(self, subnetInput, {
				field: 'downstream_lan_subnet',
				localValue: function() {
					return self.getDeviceSubnet(self.wizardData.bind_ifname);
				},
				valueFromResult: function(result) {
					return result.detected_downstream_lan_subnet || result.downstream_lan_subnet || '';
				},
				emptyMessage: _('Could not auto-detect subnet.')
			}));
			s.appendChild(self.createField(
				_('Downstream LAN Subnet') + ': ',
				subnetFieldWrap,
				_('Downstream router LAN subnet in CIDR format, used for source filtering.')
			));

		} else if (self.step === 4) {
			s.appendChild(E('p', {}, _('Testing ping to downstream LAN gateway...')));

			if (self.wizardMode === 'auto') {
				s.appendChild(E('p', { 'class': 'ubr-text-muted' },
					_('Auto mode: interface and firewall will be configured before testing.')));
			} else {
				s.appendChild(E('p', { 'class': 'ubr-text-muted' },
					_('Safe mode: testing with current network state. If the interface is not configured yet, tests may fail.')));
			}

			var pingResultDiv = E('div', { 'id': 'wiz-ping-result', 'class': 'ubr-mt-1' });
			pingResultDiv.innerHTML = '<span class="ubr-text-muted">' + _('Testing...') + '</span>';
			s.appendChild(pingResultDiv);

			self.applyTempUci().then(function() {
				if (self.wizardMode === 'auto') {
					return callSetupInterface().then(function() {
						return callFixZone();
					});
				}
				}).then(function() {
					return callCheckNetwork();
				}).then(function(result) {
					self.pingResult = result;
					self.applyDetectedNetwork(result);
					if (result && result.error) {
						pingResultDiv.innerHTML = '<span class="ubr-text-danger">&#10008; ' + _('Network check error: ') + result.error + '</span>';
						return;
				}
				if (result && result.gateway_reachable === 1) {
					pingResultDiv.innerHTML = '<span class="ubr-text-success">&#10004; ' + _('Ping to gateway successful') + '</span>';
				} else {
					var detail = '';
					if (result && result.iface_exists === 0) {
						detail += '<br><span class="ubr-text-warning">' + _('Interface does not exist. Check the interface name.') + '</span>';
					} else if (result && result.bind_ip_configured === 0) {
						detail += '<br><span class="ubr-text-warning">' + _('Interface IP is not configured on the interface. Use Auto mode or configure the interface manually.') + '</span>';
					} else {
						detail += '<br><span class="ubr-text-warning">' + _('Check that the interface is connected and the firewall zone allows output.') + '</span>';
					}
					pingResultDiv.innerHTML = '<span class="ubr-text-danger">&#10008; ' + _('Ping to gateway failed') + '</span>' +
					'<p>' + detail + '</p>';
				}
			}).catch(function(e) {
				pingResultDiv.innerHTML = '<span class="ubr-text-danger">&#10008; ' + _('Network check failed') + '</span>' +
				'<p class="ubr-text-warning">' + _('Error: ') + (e.message || e || _('Unknown error')) + '</p>';
			});

		} else if (self.step === 5) {
			s.appendChild(E('p', {}, _('Testing UPnP IGD discovery via upnpc...')));

			var upnpcResultDiv = E('div', { 'id': 'wiz-upnpc-result', 'class': 'ubr-mt-1' });
			upnpcResultDiv.innerHTML = '<span class="ubr-text-muted">' + _('Testing...') + '</span>';
			s.appendChild(upnpcResultDiv);

			self.applyTempUci().then(function() {
				if (self.wizardMode === 'auto') {
					return callSetupInterface().then(function() {
						return callFixZone();
					});
				}
				}).then(function() {
					return callCheckNetwork();
				}).then(function(result) {
					self.upnpcResult = result;
					self.applyDetectedNetwork(result);
					if (result && result.error) {
						upnpcResultDiv.innerHTML = '<span class="ubr-text-danger">&#10008; ' + _('UPnP check error: ') + result.error + '</span>';
						return;
				}
				if (result && result.upnpc_readable === 1) {
					var count = result.upnpc_mapping_count || 0;
					upnpcResultDiv.innerHTML = '<span class="ubr-text-success">&#10004; ' + _('UPnP IGD discovered, %d mapping(s) found').format(count) + '</span>';
				} else {
					var detail = '';
					if (result && result.bind_ip_configured === 0) {
						detail += '<br><span class="ubr-text-warning">' + _('Interface IP is not configured on the interface. UPnP discovery requires a valid interface IP.') + '</span>';
					} else {
						detail += '<br><span class="ubr-text-warning">' + _('Ensure the downstream router has UPnP enabled and the interface IP is on its LAN side.') + '</span>';
					}
					upnpcResultDiv.innerHTML = '<span class="ubr-text-danger">&#10008; ' + _('UPnP IGD discovery failed') + '</span>' +
						'<p>' + detail + '</p>';
				}
			}).catch(function(e) {
				upnpcResultDiv.innerHTML = '<span class="ubr-text-danger">&#10008; ' + _('UPnP check failed') + '</span>' +
				'<p class="ubr-text-warning">' + _('Error: ') + (e.message || e || _('Unknown error')) + '</p>';
			});

		} else if (self.step === 6) {
			s.appendChild(E('p', {}, _('Enter the downstream router WAN IP address (used as DNAT target).')));

			var wanIpInput = E('input', {
				'type': 'text',
				'class': 'cbi-input-text',
				'id': 'wiz-wan-ip',
				'value': self.wizardData.downstream_wan_ip,
				'placeholder': _('e.g. 192.168.2.2')
			});
			var wanIpFieldWrap = E('div', { 'class': 'ubr-flex-center' });
			wanIpFieldWrap.appendChild(wanIpInput);
			wanIpFieldWrap.appendChild(self.createDetectButton(self, wanIpInput, {
				field: 'downstream_wan_ip',
				valueFromResult: function(result) {
					return result.detected_downstream_wan_ip || result.downstream_wan_ip || '';
				},
				emptyMessage: _('Could not auto-detect downstream WAN IP.')
			}));
			s.appendChild(self.createField(
				_('Downstream WAN IP') + ': ',
				wanIpFieldWrap,
				_('Downstream router WAN IP address, used as the DNAT rule target.')
			));

		} else if (self.step === 7) {
			s.appendChild(E('p', {}, _('Select the upstream WAN interface for DNAT rules.')));

			var wanSelect = E('select', { 'class': 'cbi-input-select', 'id': 'wiz-wan-if' });
			self.loadInterfaceChoices().then(function(choices) {
				var hasCurrent = false;
				for (var i = 0; i < choices.length; i++) {
					var name = choices[i].name;
					var opt = E('option', { 'value': name }, choices[i].label || name);
					if (name === self.wizardData.upstream_wan_if) {
						opt.selected = true;
						hasCurrent = true;
					}
					wanSelect.appendChild(opt);
				}
				if (self.wizardData.upstream_wan_if && !hasCurrent)
					wanSelect.appendChild(E('option', { 'value': self.wizardData.upstream_wan_if, 'selected': 'selected' }, self.wizardData.upstream_wan_if));
			});

			var wanIfFieldWrap = E('div', { 'class': 'ubr-flex-center' });
			wanIfFieldWrap.appendChild(wanSelect);
			wanIfFieldWrap.appendChild(self.createDetectButton(self, wanSelect, {
				field: 'upstream_wan_if',
				valueFromResult: function(result) {
					return result.detected_upstream_wan_if || result.upstream_wan_if || '';
				},
				emptyMessage: _('Could not auto-detect upstream WAN interface.')
			}));

			s.appendChild(self.createField(
				_('Upstream WAN Interface') + ': ',
				wanIfFieldWrap,
				_('Select the OpenWrt logical WAN interface for DNAT rules. The underlying device is resolved automatically.')
			));

		} else if (self.step === 8) {
			s.appendChild(E('p', {}, _('Set the allowed external port range for synchronization.')));
			s.appendChild(E('p', { 'class': 'ubr-text-warning' },
				_('It is NOT recommended to use 1-65535 as the allowed range.')));

			var portInput = E('input', {
				'type': 'text',
				'class': 'cbi-input-text',
				'id': 'wiz-port-range',
				'value': self.wizardData.allowed_external_ports,
				'placeholder': _('e.g. 40000-65535')
			});
			s.appendChild(self.createField(
				_('Allowed External Ports') + ': ',
				portInput,
				_('Port range allowed for synchronization. Using 1-65535 is NOT recommended as it effectively creates a DMZ.')
			));

		} else if (self.step === 9) {
			s.appendChild(E('p', {}, _('Configure OpenClash RETURN rule for bypassing transparent proxy on forwarded ports.')));

			var ocSelect = E('select', { 'class': 'cbi-input-select', 'id': 'wiz-oc-mode' });
			var modes = [
				{ value: 'off', text: _('Off (Do not handle OpenClash)') },
				{ value: 'prompt', text: _('Prompt (Show suggested rules only)') },
				{ value: 'auto', text: _('Auto (Automatically write rules)') }
			];
			for (var i = 0; i < modes.length; i++) {
				var opt = E('option', { 'value': modes[i].value }, modes[i].text);
				if (modes[i].value === self.wizardData.openclash_mode)
					opt.selected = true;
				ocSelect.appendChild(opt);
			}
			s.appendChild(self.createField(
				_('OpenClash Mode') + ': ',
				ocSelect,
				_('Control how OpenClash transparent proxy affects forwarded ports.')
			));

			if (self.wizardMode === 'auto') {
				s.appendChild(E('div', { 'class': 'alert-message warning' },
					E('p', {}, _('Auto mode will write RETURN rules to OpenClash configuration. A backup will be created before any changes.'))));
			}

		} else if (self.step === 10) {
			s.appendChild(E('p', {}, _('Review your configuration and enable the service.')));

			var summary = E('div', { 'class': 'cbi-section' });
			summary.innerHTML = '<table class="ubr-summary-table">' +
				'<tr><td><b>' + _('Interface') + '</b></td><td>' + (self.wizardData.bind_ifname || '-') + '</td></tr>' +
				'<tr><td><b>' + _('Interface IP') + '</b></td><td>' + (self.wizardData.bind_ip || '-') + '</td></tr>' +
				'<tr><td><b>' + _('Downstream LAN Gateway') + '</b></td><td>' + (self.wizardData.downstream_lan_gateway || '-') + '</td></tr>' +
				'<tr><td><b>' + _('Downstream LAN Subnet') + '</b></td><td>' + (self.wizardData.downstream_lan_subnet || '-') + '</td></tr>' +
				'<tr><td><b>' + _('Downstream WAN IP') + '</b></td><td>' + (self.wizardData.downstream_wan_ip || '-') + '</td></tr>' +
				'<tr><td><b>' + _('Upstream WAN Interface') + '</b></td><td>' + (self.wizardData.upstream_wan_if || '-') + '</td></tr>' +
				'<tr><td><b>' + _('Allowed Ports') + '</b></td><td>' + (self.wizardData.allowed_external_ports || '-') + '</td></tr>' +
				'<tr><td><b>' + _('OpenClash Mode') + '</b></td><td>' + (self.wizardData.openclash_mode || '-') + '</td></tr>' +
				'</table>';
			s.appendChild(summary);

			if (self.wizardMode === 'auto') {
				var uciPreview = E('div', { 'class': 'alert-message warning' });
				uciPreview.innerHTML = '<h4>' + _('UCI Changes Preview') + '</h4>' +
					'<pre class="ubr-cmd-box">' +
					'uci set upnp_nat_relay.main.bind_ifname=' + (self.wizardData.bind_ifname || '') + '\n' +
					'uci set upnp_nat_relay.main.bind_ip=' + (self.wizardData.bind_ip || '') + '\n' +
					'uci set upnp_nat_relay.main.downstream_lan_gateway=' + (self.wizardData.downstream_lan_gateway || '') + '\n' +
					'uci set upnp_nat_relay.main.downstream_lan_subnet=' + (self.wizardData.downstream_lan_subnet || '') + '\n' +
					'uci set upnp_nat_relay.main.downstream_wan_ip=' + (self.wizardData.downstream_wan_ip || '') + '\n' +
					'uci set upnp_nat_relay.main.upstream_wan_if=' + (self.wizardData.upstream_wan_if || '') + '\n' +
					'uci set upnp_nat_relay.main.allowed_external_ports=' + (self.wizardData.allowed_external_ports || '') + '\n' +
					'uci set upnp_nat_relay.main.openclash_mode=' + (self.wizardData.openclash_mode || '') + '\n' +
					'uci set upnp_nat_relay.main.enabled=1\n' +
					'uci commit upnp_nat_relay\n' +
					'</pre>';
				s.appendChild(uciPreview);
			}

			var enableSelect = E('select', { 'class': 'cbi-input-select', 'id': 'wiz-enable' });
			var optYes = E('option', { 'value': '1' }, _('Yes'));
			var optNo = E('option', { 'value': '0' }, _('No'));
			optYes.selected = true;
			enableSelect.appendChild(optYes);
			enableSelect.appendChild(optNo);
			s.appendChild(self.createField(
				_('Enable Service') + ': ',
				enableSelect,
				_('Enable the UPnP NAT Relay service after saving configuration.')
			));
		}

		var navBar = E('div', { 'class': 'ubr-wizard-nav' });

		if (self.step > 1) {
			navBar.appendChild(E('button', {
				'class': 'cbi-button',
				'click': function() {
					self.collectStepData();
					self.step--;
					self.renderStep(container);
				}
			}, _('Previous')));
		}

		if (self.step < self.totalSteps) {
			navBar.appendChild(E('button', {
				'class': 'cbi-button cbi-button-apply',
				'click': function() {
					self.collectStepData();
					if (!self.validateCurrentStep()) return;
					self.step++;
					self.renderStep(container);
				}
			}, _('Next')));
		}

		if (self.step === self.totalSteps) {
			var applyLabel = self.wizardMode === 'auto' ? _('Apply Configuration') : _('Save Configuration');
			navBar.appendChild(E('button', {
				'class': 'cbi-button cbi-button-apply',
				'id': 'wiz-apply-btn',
				'click': function() {
					var btn = this;
					if (btn.disabled) return;
					self.collectStepData();
					if (!self.validateAllSteps()) return;
					btn.disabled = true;
					btn.textContent = _('Applying...');
					self.applyWizard().finally(function() {
						btn.disabled = false;
						btn.textContent = applyLabel;
					});
				}
			}, applyLabel));
		}

		s.appendChild(navBar);
		stepContainer.appendChild(s);
	},

	validateCurrentStep: function() {
		var self = this;

		if (self.step === 1) {
			if (!self.wizardData.bind_ifname) {
				ui.addNotification(null, E('p', _('Please select an interface.')), 'warning');
				return false;
			}
		} else if (self.step === 2) {
			if (!self.wizardData.bind_ip) {
				ui.addNotification(null, E('p', _('Interface IP is required.')), 'warning');
				return false;
			}
			if (!self.validateIp(self.wizardData.bind_ip)) {
				ui.addNotification(null, E('p', _('Invalid IP address format. Please enter a valid IPv4 address (e.g. 192.168.1.50).')), 'warning');
				return false;
			}
		} else if (self.step === 3) {
			if (!self.wizardData.downstream_lan_gateway) {
				ui.addNotification(null, E('p', _('Downstream LAN Gateway is required.')), 'warning');
				return false;
			}
			if (!self.validateIp(self.wizardData.downstream_lan_gateway)) {
				ui.addNotification(null, E('p', _('Invalid gateway IP address format.')), 'warning');
				return false;
			}
			if (!self.wizardData.downstream_lan_subnet) {
				ui.addNotification(null, E('p', _('Downstream LAN Subnet is required.')), 'warning');
				return false;
			}
			if (!self.validateSubnet(self.wizardData.downstream_lan_subnet)) {
				ui.addNotification(null, E('p', _('Invalid subnet format. Please use CIDR notation (e.g. 192.168.1.0/24).')), 'warning');
				return false;
			}
		} else if (self.step === 6) {
			if (!self.wizardData.downstream_wan_ip) {
				ui.addNotification(null, E('p', _('Downstream WAN IP is required.')), 'warning');
				return false;
			}
			if (!self.validateIp(self.wizardData.downstream_wan_ip)) {
				ui.addNotification(null, E('p', _('Invalid WAN IP address format.')), 'warning');
				return false;
			}
		} else if (self.step === 7) {
			if (!self.wizardData.upstream_wan_if) {
				ui.addNotification(null, E('p', _('Please select an upstream WAN interface.')), 'warning');
				return false;
			}
		} else if (self.step === 8) {
			if (!self.wizardData.allowed_external_ports) {
				ui.addNotification(null, E('p', _('Allowed external ports is required.')), 'warning');
				return false;
			}
			if (!self.validatePortRange(self.wizardData.allowed_external_ports)) {
				ui.addNotification(null, E('p', _('Invalid port range format. Use format like 40000-65535.')), 'warning');
				return false;
			}
		}

		return true;
	},

	validateAllSteps: function() {
		var self = this;
		var requiredFields = [
			{ key: 'bind_ifname', label: _('Interface') },
			{ key: 'bind_ip', label: _('Interface IP') },
			{ key: 'downstream_lan_gateway', label: _('Downstream LAN Gateway') },
			{ key: 'downstream_lan_subnet', label: _('Downstream LAN Subnet') },
			{ key: 'downstream_wan_ip', label: _('Downstream WAN IP') },
			{ key: 'upstream_wan_if', label: _('Upstream WAN Interface') },
			{ key: 'allowed_external_ports', label: _('Allowed External Ports') }
		];

		for (var i = 0; i < requiredFields.length; i++) {
			if (!self.wizardData[requiredFields[i].key]) {
				ui.addNotification(null, E('p', _('%s is required.').format(requiredFields[i].label)), 'warning');
				return false;
			}
		}

		if (!self.validateIp(self.wizardData.bind_ip)) {
			ui.addNotification(null, E('p', _('Invalid Interface IP address format.')), 'warning');
			return false;
		}
		if (!self.validateIp(self.wizardData.downstream_lan_gateway)) {
			ui.addNotification(null, E('p', _('Invalid gateway IP address format.')), 'warning');
			return false;
		}
		if (!self.validateSubnet(self.wizardData.downstream_lan_subnet)) {
			ui.addNotification(null, E('p', _('Invalid subnet format.')), 'warning');
			return false;
		}
		if (!self.validateIp(self.wizardData.downstream_wan_ip)) {
			ui.addNotification(null, E('p', _('Invalid WAN IP address format.')), 'warning');
			return false;
		}
		if (!self.validatePortRange(self.wizardData.allowed_external_ports)) {
			ui.addNotification(null, E('p', _('Invalid port range format.')), 'warning');
			return false;
		}

		return true;
	},

	collectStepData: function() {
		var self = this;
		var el;

		if (self.step === 1) {
			el = document.getElementById('wiz-ifname');
			if (el) self.wizardData.bind_ifname = el.value;
		} else if (self.step === 2) {
			el = document.getElementById('wiz-bind-ip');
			if (el) self.wizardData.bind_ip = el.value;
		} else if (self.step === 3) {
			el = document.getElementById('wiz-lan-gw');
			if (el) self.wizardData.downstream_lan_gateway = el.value;
			el = document.getElementById('wiz-lan-subnet');
			if (el) self.wizardData.downstream_lan_subnet = el.value;
		} else if (self.step === 6) {
			el = document.getElementById('wiz-wan-ip');
			if (el) self.wizardData.downstream_wan_ip = el.value;
		} else if (self.step === 7) {
			el = document.getElementById('wiz-wan-if');
			if (el) self.wizardData.upstream_wan_if = el.value;
		} else if (self.step === 8) {
			el = document.getElementById('wiz-port-range');
			if (el) self.wizardData.allowed_external_ports = el.value;
		} else if (self.step === 9) {
			el = document.getElementById('wiz-oc-mode');
			if (el) self.wizardData.openclash_mode = el.value;
		} else if (self.step === 10) {
			el = document.getElementById('wiz-enable');
			if (el) self.wizardData.enabled = el.value;
		}
	},

	applyTempUci: function() {
		var self = this;
		if (self.wizardMode !== 'auto') {
			return Promise.resolve();
		}
		if (self.wizardData.bind_ifname)
			uci.set('upnp_nat_relay', 'main', 'bind_ifname', self.wizardData.bind_ifname);
		if (self.wizardData.bind_ip)
			uci.set('upnp_nat_relay', 'main', 'bind_ip', self.wizardData.bind_ip);
		if (self.wizardData.downstream_lan_gateway)
			uci.set('upnp_nat_relay', 'main', 'downstream_lan_gateway', self.wizardData.downstream_lan_gateway);
		if (self.wizardData.downstream_lan_subnet)
			uci.set('upnp_nat_relay', 'main', 'downstream_lan_subnet', self.wizardData.downstream_lan_subnet);
		if (self.wizardData.downstream_wan_ip)
			uci.set('upnp_nat_relay', 'main', 'downstream_wan_ip', self.wizardData.downstream_wan_ip);
		if (self.wizardData.upstream_wan_if)
			uci.set('upnp_nat_relay', 'main', 'upstream_wan_if', self.wizardData.upstream_wan_if);
		return uci.save().then(function() {
			return utils.safeApply();
		});
	},

	validateIp: function(value) {
		if (!value) return false;
		return /^(\d{1,3}\.){3}\d{1,3}$/.test(value) &&
			value.split('.').every(function(octet) { return parseInt(octet, 10) <= 255; });
	},

	validateSubnet: function(value) {
		if (!value) return false;
		var parts = value.split('/');
		if (parts.length !== 2) return false;
		if (!/^(\d{1,3}\.){3}\d{1,3}$/.test(parts[0])) return false;
		if (!parts[0].split('.').every(function(octet) { return parseInt(octet, 10) <= 255; })) return false;
		var mask = parseInt(parts[1], 10);
		return mask >= 0 && mask <= 32;
	},

	validatePortRange: function(value) {
		if (!value) return false;
		if (!/^\d+-\d+$/.test(value)) return false;
		var lo = parseInt(value.split('-')[0], 10);
		var hi = parseInt(value.split('-')[1], 10);
		return lo >= 1 && lo <= 65535 && hi >= 1 && hi <= 65535 && lo <= hi;
	},

	applyWizard: function() {
		var self = this;

		uci.set('upnp_nat_relay', 'main', 'bind_ifname', self.wizardData.bind_ifname);
		uci.set('upnp_nat_relay', 'main', 'bind_ip', self.wizardData.bind_ip);
		uci.set('upnp_nat_relay', 'main', 'downstream_lan_gateway', self.wizardData.downstream_lan_gateway);
		uci.set('upnp_nat_relay', 'main', 'downstream_lan_subnet', self.wizardData.downstream_lan_subnet);
		uci.set('upnp_nat_relay', 'main', 'downstream_wan_ip', self.wizardData.downstream_wan_ip);
		uci.set('upnp_nat_relay', 'main', 'upstream_wan_if', self.wizardData.upstream_wan_if);
		uci.set('upnp_nat_relay', 'main', 'allowed_external_ports', self.wizardData.allowed_external_ports);
		uci.set('upnp_nat_relay', 'main', 'openclash_mode', self.wizardData.openclash_mode);
		uci.set('upnp_nat_relay', 'main', 'enabled', self.wizardData.enabled);

		return uci.save()
			.then(function() {
				return utils.safeApply();
			})
			.then(function() {
				if (self.wizardMode === 'auto') {
					return callSetupInterface().then(function() {
						return callFixZone();
					}).then(function() {
						if (self.wizardData.openclash_mode === 'auto') {
							return callSetupOpenclash();
						}
					}).then(function() {
						if (self.wizardData.enabled === '1') {
							return initAction('enable').then(function() {
								return initAction('start');
							});
						}
					});
				}
			})
			.then(function() {
				ui.addNotification(null, E('p', _('Configuration saved successfully.')), 'info');
				if (self.wizardMode === 'auto') {
					ui.addNotification(null, E('p', _('Auto configuration applied.')), 'info');
				}
			})
			.catch(function(e) {
				ui.addNotification(null, E('p', _('Configuration failed: ') + e.message), 'error');
			});
	}
});
