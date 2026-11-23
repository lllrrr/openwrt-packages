'use strict';
'require view';
'require ui';
'require rpc';
'require uci';
'require form';
'require network';
'require upnp-nat-relay/utils as utils';

var callCheckNetwork = rpc.declare({
	object: 'upnp_nat_relay',
	method: 'check-network',
	expect: { '': {} }
});

var callNetworkCache = rpc.declare({
	object: 'upnp_nat_relay',
	method: 'network-cache',
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

return view.extend({
	load: function() {
		var getLogicalInterfaces = network.getNetworks || network.getInterfaces;
		return Promise.all([
			uci.load('upnp_nat_relay'),
			network.getDevices().catch(function() {
				return [];
			}),
			getLogicalInterfaces ? getLogicalInterfaces.call(network).catch(function() {
				return [];
			}) : Promise.resolve([]),
			callNetworkCache().catch(function() {
				return null;
			})
		]).then(function(results) {
			return {
				devices: results[1],
				interfaces: results[2],
				network: results[3]
			};
		});
	},

	render: function(data) {
		utils.loadSharedCSS();
		var m, s, o;
		var devices = (data && data.devices) || [];
		var interfaces = (data && data.interfaces) || [];
		var getDeviceName = function(dev) {
			return dev ? (typeof(dev) === 'string' ? dev : (dev.getName ? dev.getName() : dev.name)) : '';
		};
		var getInterfaceName = function(iface) {
			return iface ? (typeof(iface) === 'string' ? iface : (iface.getName ? iface.getName() : iface.name)) : '';
		};
		var normalizeDeviceAddrs = function(dev) {
			var addrs = dev ? (dev.getIPAddrs ? dev.getIPAddrs() : (dev.ipaddrs || dev.ipaddrs4 || [])) : [];
			if (!Array.isArray(addrs))
				addrs = [ addrs ];
			return addrs;
		};
		var ipv4SubnetFromCIDR = function(cidrAddr) {
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
		};
		var findDevice = function(name) {
			for (var i = 0; i < devices.length; i++) {
				if (getDeviceName(devices[i]) === name)
					return devices[i];
			}
			return null;
		};
		var getInterfaceDeviceName = function(iface) {
			var dev = null;
			if (!iface)
				return '';
			if (iface.getL3Device)
				dev = iface.getL3Device();
			if (!dev && iface.getDevice)
				dev = iface.getDevice();
			return getDeviceName(dev) || iface.l3_device || iface.device || '';
		};
		var getInterfaceAddrs = function(iface) {
			var addrs = normalizeDeviceAddrs(iface);
			var dev = findDevice(getInterfaceDeviceName(iface));
			if (dev)
				addrs = addrs.concat(normalizeDeviceAddrs(dev));
			return addrs;
		};
		var formatInterfaceLabel = function(ifName, devName) {
			if (devName && devName !== ifName)
				return '%s (%s)'.format(ifName, devName);
			return ifName;
		};
		var buildInterfaceChoices = function() {
			var choices = [];
			var seen = {};
			for (var i = 0; i < interfaces.length; i++) {
				var ifName = getInterfaceName(interfaces[i]);
				if (!ifName || seen[ifName])
					continue;
				var ifDevName = getInterfaceDeviceName(interfaces[i]);
				seen[ifName] = true;
				choices.push({ name: ifName, label: formatInterfaceLabel(ifName, ifDevName), addrs: getInterfaceAddrs(interfaces[i]) });
			}
			for (var j = 0; j < devices.length; j++) {
				var devName = getDeviceName(devices[j]);
				if (!devName || seen[devName])
					continue;
				seen[devName] = true;
				choices.push({ name: devName, label: '%s (%s)'.format(devName, _('device')), addrs: normalizeDeviceAddrs(devices[j]) });
			}
			return choices;
		};
		var interfaceChoices = buildInterfaceChoices();
		var getChoiceAddrs = function(ifname) {
			if (!ifname)
				return [];
			for (var i = 0; i < interfaceChoices.length; i++) {
				if (interfaceChoices[i].name === ifname)
					return interfaceChoices[i].addrs || [];
			}
			return [];
		};
		var getDeviceIPv4 = function(ifname) {
			var addrs = getChoiceAddrs(ifname);
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
		};
		var getDeviceSubnet = function(ifname) {
			var addrs = getChoiceAddrs(ifname);
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
				var subnet = ipv4SubnetFromCIDR(addr);
				if (subnet)
					return subnet;
			}
			return '';
		};
		var setOptionValue = function(section_id, option, value) {
			if (!value)
				return false;
			var current = uci.get('upnp_nat_relay', section_id, option) || '';
			if (current)
				return false;
			uci.set('upnp_nat_relay', section_id, option, value);
			var input = document.getElementById('widget.cbid.upnp_nat_relay.' + section_id + '.' + option);
			if (input) {
				if (input.tagName === 'SELECT') {
					var hasOption = false;
					for (var i = 0; i < input.options.length; i++) {
						if (input.options[i].value === value) {
							hasOption = true;
							break;
						}
					}
					if (!hasOption)
						input.appendChild(E('option', { 'value': value }, value));
				}
				input.value = value;
			}
			return true;
		};
		var applyDetectedSuggestions = function(result) {
			result = result || {};
			var section_id = 'main';
			var count = 0;
			if (setOptionValue(section_id, 'bind_ip', result.detected_bind_ip || result.bind_ip))
				count++;
			if (setOptionValue(section_id, 'downstream_lan_gateway', result.detected_downstream_lan_gateway))
				count++;
			if (setOptionValue(section_id, 'downstream_lan_subnet', result.detected_downstream_lan_subnet))
				count++;
			if (setOptionValue(section_id, 'downstream_wan_ip', result.detected_downstream_wan_ip))
				count++;
			if (setOptionValue(section_id, 'upstream_wan_if', result.detected_upstream_wan_if))
				count++;
			return count;
		};

		m = new form.Map('upnp_nat_relay', _('Network'));

		s = m.section(form.TypedSection, 'service', _('Network Interface'));
		s.anonymous = true;
		s.tab('status', _('Status'));
		s.tab('config', _('Configuration'));

		o = s.taboption('config', form.ListValue, 'bind_ifname', _('Read Interface'),
			_('Select the interface connected to the downstream router LAN side. The underlying device is resolved automatically.'));
		o.value('', _('Select interface'));
		var currentBindIfname = uci.get('upnp_nat_relay', 'main', 'bind_ifname') || '';
		var hasCurrentBindIfname = false;
		for (var i = 0; i < interfaceChoices.length; i++) {
			if (interfaceChoices[i].name === currentBindIfname)
				hasCurrentBindIfname = true;
			o.value(interfaceChoices[i].name, interfaceChoices[i].label);
		}
		if (currentBindIfname && !hasCurrentBindIfname)
			o.value(currentBindIfname, currentBindIfname);
		o.rmempty = false;
		o.onchange = function(ev, section_id, value) {
			var ip = getDeviceIPv4(value);
			var subnet = getDeviceSubnet(value);
			if (ip) {
				uci.set('upnp_nat_relay', section_id, 'bind_ip', ip);
				var ipInput = document.getElementById('widget.cbid.upnp_nat_relay.' + section_id + '.bind_ip');
				if (ipInput)
					ipInput.value = ip;
			}
			if (subnet) {
				uci.set('upnp_nat_relay', section_id, 'downstream_lan_subnet', subnet);
				var subnetInput = document.getElementById('widget.cbid.upnp_nat_relay.' + section_id + '.downstream_lan_subnet');
				if (subnetInput)
					subnetInput.value = subnet;
			}
		};

		o = s.taboption('config', form.Value, 'downstream_lan_gateway', _('Downstream LAN Gateway'),
			_('Downstream router LAN gateway IP. Leave empty to auto-detect from the read interface route.'));
		o.rmempty = true;
		o.datatype = 'ip4addr';
		o.depends('show_advanced_config', '1');
		o.cfgvalue = function(section_id) {
			return uci.get('upnp_nat_relay', section_id, 'downstream_lan_gateway') || '';
		};

		o = s.taboption('config', form.Flag, 'show_advanced_config', _('Show Advanced Configuration'),
			_('Show auto-detectable network fields for special topologies.'));
		o.default = '0';
		o.rmempty = false;

		o = s.taboption('config', form.Value, 'bind_ip', _('Interface IP'),
			_('IP address on the read interface. Leave empty to auto-detect from the selected read interface.'));
		o.rmempty = true;
		o.datatype = 'ip4addr';
		o.depends('show_advanced_config', '1');
		o.cfgvalue = function(section_id) {
			return uci.get('upnp_nat_relay', section_id, 'bind_ip') ||
				getDeviceIPv4(uci.get('upnp_nat_relay', section_id, 'bind_ifname'));
		};
		o.write = function(section_id, value) {
			value = value || getDeviceIPv4(uci.get('upnp_nat_relay', section_id, 'bind_ifname'));
			if (value)
				return uci.set('upnp_nat_relay', section_id, 'bind_ip', value);
			return uci.unset('upnp_nat_relay', section_id, 'bind_ip');
		};

		o = s.taboption('config', form.Value, 'downstream_lan_subnet', _('Downstream LAN Subnet'),
			_('Downstream router LAN subnet (CIDR). Leave empty to auto-detect from the selected read interface.'));
		o.rmempty = true;
		o.datatype = 'cidr4';
		o.depends('show_advanced_config', '1');
		o.cfgvalue = function(section_id) {
			return uci.get('upnp_nat_relay', section_id, 'downstream_lan_subnet') ||
				getDeviceSubnet(uci.get('upnp_nat_relay', section_id, 'bind_ifname'));
		};
		o.write = function(section_id, value) {
			value = value || getDeviceSubnet(uci.get('upnp_nat_relay', section_id, 'bind_ifname'));
			if (value)
				return uci.set('upnp_nat_relay', section_id, 'downstream_lan_subnet', value);
			return uci.unset('upnp_nat_relay', section_id, 'downstream_lan_subnet');
		};

		o = s.taboption('config', form.Value, 'downstream_wan_ip', _('Downstream WAN IP'),
			_('Downstream router WAN IP (DNAT target). Leave empty and run Detect to auto-fill it from UPnP when available.'));
		o.rmempty = true;
		o.datatype = 'ip4addr';
		o.depends('show_advanced_config', '1');

		o = s.taboption('config', form.ListValue, 'upstream_wan_if', _('Upstream WAN Interface'),
			_('Select the OpenWrt logical WAN interface for DNAT rules. Leave empty to auto-detect from the default route; the underlying device is resolved automatically.'));
		o.value('', _('Select interface'));
		var currentUpstreamWanIf = uci.get('upnp_nat_relay', 'main', 'upstream_wan_if') || '';
		var hasCurrentUpstreamWanIf = false;
		for (var j = 0; j < interfaceChoices.length; j++) {
			if (interfaceChoices[j].name === currentUpstreamWanIf)
				hasCurrentUpstreamWanIf = true;
			o.value(interfaceChoices[j].name, interfaceChoices[j].label);
		}
		if (currentUpstreamWanIf && !hasCurrentUpstreamWanIf)
			o.value(currentUpstreamWanIf, currentUpstreamWanIf);
		o.rmempty = true;
		o.depends('show_advanced_config', '1');

		var netCheckData = data ? data.network : null;
		var detecting = false;
		var detectError = '';
		var detectPromise = null;

		var STATUS_ID_PREFIX = 'ubr-net-status-';

		var escapeHtml = function(value) {
			return String(value == null ? '' : value)
				.replace(/&/g, '&amp;')
				.replace(/</g, '&lt;')
				.replace(/>/g, '&gt;');
		};

		/* 后端会自动推导未显式配置的字段（bind_ip、subnet、gateway、WAN、upstream）。
		 * 比对快照时只看用户真正填过的值：否则自动推导出来的结果永远和缓存对不上，
		 * 状态区就会一直停在“点击检测查看状态”。 */
		var matchConfigured = function(cached, configured) {
			configured = configured || '';
			return !configured || (cached || '') === configured;
		};

		var hasNetCheckData = function() {
			if (!netCheckData || netCheckData.cached !== 1)
				return false;
			var cfg = function(option) {
				return uci.get('upnp_nat_relay', 'main', option);
			};
			return (netCheckData.bind_ifname || '') === (cfg('bind_ifname') || '') &&
				matchConfigured(netCheckData.bind_ip, cfg('bind_ip')) &&
				matchConfigured(netCheckData.downstream_lan_gateway, cfg('downstream_lan_gateway')) &&
				matchConfigured(netCheckData.downstream_lan_subnet, cfg('downstream_lan_subnet')) &&
				matchConfigured(netCheckData.downstream_wan_ip, cfg('downstream_wan_ip')) &&
				matchConfigured(netCheckData.upstream_wan_if, cfg('upstream_wan_if')) &&
				(netCheckData.zone_name || '') === (cfg('firewall_zone_name') || 'upnp_nat');
		};

		var flagOn = function(value) {
			return value === 1 || value === '1' || value === 'ok' || value === true;
		};

		/* 结果在多少秒内算“够新”：够新就不再自动检测，反复打开页面、多标签页
		 * 都直接复用刚测过的结果。手动点「检测」不受这个限制，永远强制重测。 */
		var AUTO_DETECT_MAX_AGE = 15;
		var autoDetectIsFresh = function() {
			if (!hasNetCheckData())
				return false;
			var age = netCheckData.age;
			return typeof age === 'number' && age >= 0 && age < AUTO_DETECT_MAX_AGE;
		};

		var pendingStatus = function() {
			if (detecting)
				return '<span>&#8987; ' + _('Detecting...') + '</span>';
			return '<span>' + _('Click "Detect" to check status.') + '</span>';
		};

		/* 每个状态项都是一段可重算的 HTML：首屏渲染一次，检测返回后按 key 原位重绘，
		 * 不用刷新整页就能看到最新结果。 */
		var statusRenderers = {
			last_check: function() {
				if (detecting)
					return '<span>&#8987; ' + _('Detecting...') + '</span>';
				if (detectError)
					return '<span>' + _('Detection failed:') + ' ' + escapeHtml(detectError) + '</span>';
				if (hasNetCheckData() && netCheckData.updated_at)
					return '<span>' + escapeHtml(netCheckData.updated_at) + '</span>';
				return pendingStatus();
			},

			if_status: function() {
				if (!hasNetCheckData())
					return pendingStatus();
				return flagOn(netCheckData.iface_exists)
					? '<span>&#10004; ' + _('Interface exists') + '</span>'
					: '<span>&#10008; ' + _('Interface not found') + '</span>';
			},

			ip_status: function() {
				if (!hasNetCheckData())
					return pendingStatus();
				return flagOn(netCheckData.bind_ip_configured)
					? '<span>&#10004; ' + _('IP configured') + '</span>'
					: '<span>&#10008; ' + _('IP not configured') + '</span>';
			},

			gateway_reachable: function() {
				if (!hasNetCheckData())
					return pendingStatus();
				return flagOn(netCheckData.gateway_reachable)
					? '<span>&#10004; ' + _('Reachable') + '</span>'
					: '<span>&#10008; ' + _('Unreachable') + '</span>';
			},

			upnpc_readable: function() {
				if (!hasNetCheckData())
					return pendingStatus();
				return flagOn(netCheckData.upnpc_readable)
					? '<span>&#10004; ' + _('Readable') + '</span>'
					: '<span>&#10008; ' + _('Failed') + '</span>';
			},

			wan_ip_reachable: function() {
				if (!hasNetCheckData())
					return pendingStatus();
				return flagOn(netCheckData.wan_ip_reachable)
					? '<span>&#10004; ' + _('Reachable') + '</span>'
					: '<span>&#10008; ' + _('Unreachable') + '</span>';
			},

			upstream_wan: function() {
				if (!hasNetCheckData())
					return pendingStatus();
				return flagOn(netCheckData.upstream_wan_exists)
					? '<span>&#10004; ' + _('Exists') + '</span>'
					: '<span>&#10008; ' + _('Not found') + '</span>';
			},

			default_route: function() {
				if (!hasNetCheckData())
					return pendingStatus();
				if (flagOn(netCheckData.default_route_on_bind)) {
					return '<span>&#9888; ' + _('Default route points to read interface!') + '</span>' +
						'<p>' + _('The read interface should NOT be a default gateway.') + '</p>';
				}
				return '<span>&#10004; ' + _('No default route risk') + '</span>';
			},

			gateway_set: function() {
				if (!hasNetCheckData())
					return pendingStatus();
				if (flagOn(netCheckData.gateway_set)) {
					return '<span>&#9888; ' + _('Gateway is set: %s').format(netCheckData.gateway_value || '-') + '</span>' +
						'<p>' + _('The read interface should not have a gateway configured.') + '</p>';
				}
				return '<span>&#10004; ' + _('No gateway set') + '</span>';
			},

			dns_set: function() {
				if (!hasNetCheckData())
					return pendingStatus();
				if (flagOn(netCheckData.dns_set))
					return '<span>&#9888; ' + _('DNS is set: %s').format(netCheckData.dns_value || '-') + '</span>';
				return '<span>&#10004; ' + _('No DNS set') + '</span>';
			},

			forwarding: function() {
				if (!hasNetCheckData())
					return pendingStatus();
				if (flagOn(netCheckData.bad_forwarding))
					return '<span>&#9888; ' + _('Unnecessary forwarding detected') + '</span>';
				return '<span>&#10004; ' + _('No extra forwarding') + '</span>';
			},

			zone_name: function() {
				var zoneName = uci.get('upnp_nat_relay', 'main', 'firewall_zone_name') || 'upnp_nat';
				if (!hasNetCheckData())
					return pendingStatus();
				if (flagOn(netCheckData.zone_exists))
					return '<span>&#10004; ' + escapeHtml(netCheckData.zone_name || zoneName) + '</span>';
				return '<span>&#10008; ' + escapeHtml(zoneName) + ' (' + _('Zone not found') + ')</span>';
			},

			zone_input: function() {
				if (!hasNetCheckData())
					return pendingStatus();
				if (!flagOn(netCheckData.zone_exists))
					return '<span>' + _('Zone not found') + '</span>';
				var input = escapeHtml(netCheckData.zone_input || '-');
				if (netCheckData.zone_input === 'ACCEPT')
					return '<span>' + input + '</span>';
				return '<span>' + input + ' ' + _('(should be ACCEPT)') + '</span>';
			},

			zone_output: function() {
				if (!hasNetCheckData())
					return pendingStatus();
				if (!flagOn(netCheckData.zone_exists))
					return '<span>' + _('Zone not found') + '</span>';
				var output = escapeHtml(netCheckData.zone_output || '-');
				if (netCheckData.zone_output === 'ACCEPT')
					return '<span>' + output + '</span>';
				return '<span>' + output + ' ' + _('(should be ACCEPT)') + '</span>';
			},

			zone_forward: function() {
				if (!hasNetCheckData())
					return pendingStatus();
				if (!flagOn(netCheckData.zone_exists))
					return '<span>' + _('Zone not found') + '</span>';
				var forward = escapeHtml(netCheckData.zone_forward || '-');
				if (netCheckData.zone_forward === 'REJECT')
					return '<span>' + forward + '</span>';
				return '<span>' + forward + ' ' + _('(should be REJECT)') + '</span>';
			},

			zone_masq: function() {
				if (!hasNetCheckData())
					return pendingStatus();
				if (!flagOn(netCheckData.zone_exists))
					return '<span>' + _('Zone not found') + '</span>';
				if ((netCheckData.zone_masq || '0') === '0')
					return '<span>' + _('Disabled') + '</span>';
				return '<span>' + _('Enabled (should be Disabled)') + '</span>';
			}
		};

		var statusField = function(key) {
			return '<span id="' + STATUS_ID_PREFIX + key + '">' + statusRenderers[key]() + '</span>';
		};

		var statusRefreshAttempts = 0;
		var refreshStatusDom = function() {
			var missing = 0;
			for (var key in statusRenderers) {
				if (!statusRenderers.hasOwnProperty(key))
					continue;
				var node = document.getElementById(STATUS_ID_PREFIX + key);
				if (node)
					node.innerHTML = statusRenderers[key]();
				else
					missing++;
			}
			/* 自动检测可能在表单 DOM 落地之前就返回，元素还没进页面时补一次重绘。 */
			if (missing > 0 && statusRefreshAttempts < 20) {
				statusRefreshAttempts++;
				window.setTimeout(refreshStatusDom, 150);
			}
		};

		/* 页面加载自动跑、点“检测”也走这里：同一时刻只发一次请求，
		 * 返回后统一重绘状态区。autoFill 只在用户主动点击时开启，
		 * 免得后台检测就悄悄把表单改成“未保存”状态。 */
		var startDetection = function(options) {
			options = options || {};
			/* 自动检测还没回来时点了“检测”：等它结束后再跑一轮，保证回填生效。 */
			if (detectPromise && options.autoFill) {
				return detectPromise.catch(function() {}).then(function() {
					return startDetection(options);
				});
			}
			if (detectPromise)
				return detectPromise;

			detecting = true;
			detectError = '';
			refreshStatusDom();

			detectPromise = utils.rpcWithRetry(callCheckNetwork, { retries: 2 }).then(function(result) {
				netCheckData = result || null;
				detecting = false;
				detectPromise = null;
				statusRefreshAttempts = 0;
				var filled = options.autoFill ? applyDetectedSuggestions(result) : 0;
				refreshStatusDom();
				return { filled: filled, result: result };
			}).catch(function(e) {
				detecting = false;
				detectPromise = null;
				statusRefreshAttempts = 0;
				detectError = utils.getErrorMessage(e) || String(e);
				refreshStatusDom();
				throw e;
			});

			return detectPromise;
		};

		o = s.taboption('status', form.DummyValue, '_last_check', _('Last Check'));
		o.rawhtml = true;
		o.cfgvalue = function() {
			return statusField('last_check');
		};

		o = s.taboption('status', form.DummyValue, '_if_status', _('Interface Status'));
		o.rawhtml = true;
		o.cfgvalue = function() {
			return statusField('if_status');
		};

		o = s.taboption('status', form.DummyValue, '_ip_status', _('IP Status'));
		o.rawhtml = true;
		o.cfgvalue = function() {
			return statusField('ip_status');
		};

		o = s.taboption('status', form.DummyValue, '_gateway_reachable', _('Downstream LAN Gateway'));
		o.rawhtml = true;
		o.cfgvalue = function() {
			return statusField('gateway_reachable');
		};

		o = s.taboption('status', form.DummyValue, '_upnpc_readable', _('UPnP IGD Read'));
		o.rawhtml = true;
		o.cfgvalue = function() {
			return statusField('upnpc_readable');
		};

		o = s.taboption('status', form.DummyValue, '_wan_ip_reachable', _('Downstream WAN IP'));
		o.rawhtml = true;
		o.cfgvalue = function() {
			return statusField('wan_ip_reachable');
		};

		o = s.taboption('status', form.DummyValue, '_upstream_wan', _('Upstream WAN Interface'));
		o.rawhtml = true;
		o.cfgvalue = function() {
			return statusField('upstream_wan');
		};

		o = s.taboption('status', form.DummyValue, '_default_route', _('Default Route Risk'));
		o.rawhtml = true;
		o.cfgvalue = function() {
			return statusField('default_route');
		};

		o = s.taboption('status', form.DummyValue, '_gateway_set', _('Gateway Setting'));
		o.rawhtml = true;
		o.cfgvalue = function() {
			return statusField('gateway_set');
		};

		o = s.taboption('status', form.DummyValue, '_dns_set', _('DNS Setting'));
		o.rawhtml = true;
		o.cfgvalue = function() {
			return statusField('dns_set');
		};

		o = s.taboption('status', form.DummyValue, '_forwarding', _('Extra Forwarding'));
		o.rawhtml = true;
		o.cfgvalue = function() {
			return statusField('forwarding');
		};

		o = s.taboption('status', form.DummyValue, '_hint', _('Hint'));
		o.rawhtml = true;
		o.cfgvalue = function() {
			return '<div class="alert-message warning">' +
				_('The read interface is only for reading UPnP mappings from the downstream router. ' +
					'It should NOT have a default gateway, DNS, or be bridged with the main LAN.') +
				'</div>';
		};

		s = m.section(form.TypedSection, 'service', _('Network Actions'));
		s.anonymous = true;

		o = s.option(form.Button, '_check_network', _('Detect Network'));
		o.inputtitle = _('Detect');
		o.inputstyle = 'apply';
		o.onclick = function() {
			var btn = this;
			if (btn.node) {
				btn.node.disabled = true;
				btn.node.textContent = _('Detecting...');
			}
			return startDetection({ autoFill: true }).then(function(result) {
				var filled = result.filled;
				var msg = filled > 0
					? _('Network detection completed. %d empty field(s) were auto-filled; save and apply to keep them.').format(filled)
					: _('Network detection completed.');
				ui.addNotification(null, E('p', msg), 'info');
			}).catch(function(e) {
				ui.addNotification(null, E('p', _('Detection failed:') + ' ' + (utils.getErrorMessage(e) || '')), 'error');
			}).finally(function() {
				if (btn.node) {
					btn.node.disabled = false;
					btn.node.textContent = _('Detect');
				}
			});
		};

		o = s.option(form.Button, '_setup_interface', _('Configure Interface'));
		o.inputtitle = _('Auto Configure');
		o.inputstyle = 'apply';
		o.onclick = function() {
			var btn = this;
			if (btn.node) {
				btn.node.disabled = true;
				btn.node.textContent = _('Configuring...');
			}
			return callSetupInterface().then(function(result) {
				result = result || {};
				if (result.success !== true) {
					ui.addNotification(null, E('p', _('Operation failed:') + ' ' + (result.error || _('unknown'))), 'error');
				return;
			}
			return callCheckNetwork().catch(function() {
				return result;
			});
		}).then(function(result) {
			if (!result) return;
			ui.addNotification(null, E('p', _('Interface configured. Click the Status tab to view details.')), 'info');
				utils.reloadSoon();
			}).catch(function(e) {
				ui.addNotification(null, E('p', _('Interface configuration failed:') + ' ' + e.message), 'error');
			}).finally(function() {
				if (btn.node) {
					btn.node.disabled = false;
					btn.node.textContent = _('Auto Configure');
				}
			});
		};

		s = m.section(form.TypedSection, 'service', _('Firewall Zone'));
		s.anonymous = true;
		s.tab('zone_status', _('Zone Status'));
		s.tab('zone_config', _('Zone Configuration'));

		o = s.taboption('zone_status', form.DummyValue, '_zone_name', _('Current Zone'));
		o.rawhtml = true;
		o.cfgvalue = function() {
			return statusField('zone_name');
		};

		o = s.taboption('zone_status', form.DummyValue, '_zone_input', _('Input Policy'));
		o.rawhtml = true;
		o.cfgvalue = function() {
			return statusField('zone_input');
		};

		o = s.taboption('zone_status', form.DummyValue, '_zone_output', _('Output Policy'));
		o.rawhtml = true;
		o.cfgvalue = function() {
			return statusField('zone_output');
		};

		o = s.taboption('zone_status', form.DummyValue, '_zone_forward', _('Forward Policy'));
		o.rawhtml = true;
		o.cfgvalue = function() {
			return statusField('zone_forward');
		};

		o = s.taboption('zone_status', form.DummyValue, '_zone_maq', _('Masquerading'));
		o.rawhtml = true;
		o.cfgvalue = function() {
			return statusField('zone_masq');
		};

		o = s.taboption('zone_status', form.DummyValue, '_zone_recommendation', _('Recommendation'));
		o.rawhtml = true;
		o.cfgvalue = function() {
			return '<div class="alert-message info">' +
				'<b>' + _('Recommended zone settings:') + '</b><br>' +
				_('input: ACCEPT, output: ACCEPT, forward: REJECT, masq: 0') + '<br>' +
				_('This allows the router to access the downstream LAN for UPnP reading while preventing unwanted forwarding.') +
				'</div>';
		};

		s.taboption('zone_config', form.Value, 'firewall_zone_name', _('Zone Name'),
			_('Name of the firewall zone for the read interface.'));

		s = m.section(form.TypedSection, 'service', _('Zone Actions'));
		s.anonymous = true;

		o = s.option(form.Button, '_fix_zone', _('Fix Zone'));
		o.inputtitle = _('Fix Zone Settings');
		o.inputstyle = 'apply';
		o.onclick = function() {
			var btn = this;
			if (btn.node) {
				btn.node.disabled = true;
				btn.node.textContent = _('Applying...');
			}
			return callFixZone().then(function(result) {
				result = result || {};
				if (result.success !== true) {
					ui.addNotification(null, E('p', _('Operation failed:') + ' ' + (result.error || _('unknown'))), 'error');
					return;
				}
				return callCheckNetwork().catch(function() {
					return result;
				});
			}).then(function(result) {
				if (!result) return;
				ui.addNotification(null, E('p', _('Zone settings fixed.')), 'info');
				utils.reloadSoon();
			}).catch(function(e) {
				ui.addNotification(null, E('p', _('Zone fix failed:') + ' ' + e.message), 'error');
			}).finally(function() {
				if (btn.node) {
					btn.node.disabled = false;
					btn.node.textContent = _('Fix Zone Settings');
				}
			});
		};

		o = s.option(form.Button, '_create_zone', _('Create Independent Zone'));
		o.inputtitle = _('Create Zone');
		o.inputstyle = 'apply';
		o.onclick = function() {
			var zoneName = uci.get('upnp_nat_relay', 'main', 'firewall_zone_name') || 'upnp_nat';
			if (hasNetCheckData() && netCheckData.zone_exists === 1) {
				ui.addNotification(null, E('p', _('Zone "%s" already exists. Use "Fix Zone Settings" instead.').format(zoneName)), 'warning');
				return;
			}

			var btn = this;
			if (btn.node) {
				btn.node.disabled = true;
				btn.node.textContent = _('Creating...');
			}
			return callFixZone().then(function(result) {
				result = result || {};
				if (result.success !== true) {
					ui.addNotification(null, E('p', _('Operation failed:') + ' ' + (result.error || _('unknown'))), 'error');
					return;
				}
				return callCheckNetwork().catch(function() {
					return result;
				});
			}).then(function(result) {
				if (!result) return;
				ui.addNotification(null, E('p', _('Zone created successfully.')), 'info');
				utils.reloadSoon();
			}).catch(function(e) {
				ui.addNotification(null, E('p', _('Zone creation failed:') + ' ' + e.message), 'error');
			}).finally(function() {
				if (btn.node) {
					btn.node.disabled = false;
					btn.node.textContent = _('Create Zone');
				}
			});
		};

		/* 打开页面自动跑一次检测：状态区直接出结果，用户不用先点“检测”才看到信息。
		 * 但结果够新（15 秒内）就直接复用，反复打开/刷新页面、多标签页不会一直重复探测；
		 * 没有缓存或缓存对不上当前配置时才显示“检测中”并重新测。 */
		var skipAutoDetect = autoDetectIsFresh();
		if (!skipAutoDetect)
			detecting = true;

		return Promise.resolve(utils.renderWithFooter(m.render(), utils.FOOTER_OPTIONS)).then(function(node) {
			if (skipAutoDetect)
				return node;
			/* 等表单渲染完成再发请求，避免和页面自身的 ubus 调用抢连接。 */
			window.setTimeout(function() {
				startDetection({ autoDetect: true }).catch(function() {
					/* 自动检测失败不打断页面，失败原因已写进状态区。 */
				});
			}, 120);
			return node;
		});
	},

	handleSaveApply: function(ev, mode) {
		return this.handleSave(ev).then(function() {
			return utils.safeApply();
		}).then(function() {
			return uci.load('upnp_nat_relay');
		}).then(function() {
			if (uci.get('upnp_nat_relay', 'main', 'enabled') !== '1') {
				ui.addNotification(null, E('p', _('Configuration saved and applied.')), 'info');
				utils.reloadSoon(600);
				return;
			}

			ui.addNotification(null, E('p', _('Configuration saved. The running service will pick up changes on the next sync cycle.')), 'info');
			utils.reloadSoon(600);
		}).catch(function(e) {
			ui.addNotification(null, E('p', _('Failed to apply configuration:') + ' ' + e.message), 'error');
		});
	}
});
