// SPDX-License-Identifier: Apache-2.0
'use strict';
'require view';
'require ui';
'require uci';
'require form';
'require poll';
'require fs';
'require request';
'require rpc';

var callHostHints = rpc.declare({
	object: 'luci-rpc',
	method: 'getHostHints',
	expect: { '': {} }
});

function parseServiceStatus(text) {
	var status = {
		running: false,
		pid: null
	};

	try {
		var data = JSON.parse(String(text || '').trim() || '{}');
		status.running = !!data.running;
		status.pid = data.pid || null;
	} catch (e) {
		var value = String(text || '').trim();

		if (value === 'running') {
			status.running = true;
		}
	}

	return status;
}

function getServiceStatus() {
	return L.resolveDefault(fs.exec_direct('/etc/init.d/devgate', ['actual']), '')
		.then(parseServiceStatus)
		.catch(function () {
			return {
				running: false,
				pid: null
			};
		});
}

function setServiceRunning(running) {
	return fs.exec_direct('/etc/init.d/devgate', [running ? 'start' : 'stop']);
}

function getPackageVersion() {
	return L.resolveDefault(fs.read_direct('/usr/lib/opkg/status'), '')
		.then(function (status) {
			var block = String(status || '').match(/(^|\n)Package:\s*luci-app-devgate\n([\s\S]*?)(\n\n|$)/);
			var version = block ? block[2].match(/(^|\n)Version:\s*([^\s]+)/) : null;

			return version ? version[2] : 'unknown';
		})
		.catch(function () {
			return 'unknown';
		});
}

function syncServiceSwitch(input, status) {
	var running = !!(status && status.running);

	input.checked = running;
	input.disabled = false;
	input.setAttribute('aria-checked', running ? 'true' : 'false');
	input.title = running ? _('点击停止设备门禁') : _('点击启动设备门禁');
}

function refreshServiceSwitch(input) {
	return getServiceStatus()
		.then(function (status) {
			syncServiceSwitch(input, status);
		});
}

function renderServiceSwitch(initialStatus) {
	var input = E('input', {
		type: 'checkbox',
		role: 'switch',
		'class': 'cbi-input-checkbox',
		'aria-label': _('设备门禁开关')
	});

	syncServiceSwitch(input, initialStatus);

	input.addEventListener('change', function () {
		var running = input.checked;

		input.disabled = true;
		input.setAttribute('aria-checked', running ? 'true' : 'false');

		setServiceRunning(running)
			.then(function () {
				return refreshServiceSwitch(input);
			})
			.catch(function (err) {
				input.checked = !running;
				input.disabled = false;
				input.setAttribute('aria-checked', input.checked ? 'true' : 'false');
				ui.addNotification(null, E('p', running ? _('启动失败') : _('停止失败')), 'error');
				console.error('服务切换失败:', err);
			});
	});

	poll.add(function () {
		if (input.disabled) {
			return Promise.resolve();
		}

		return refreshServiceSwitch(input);
	}, 5);
	poll.start();

	return E('div', { 'class': 'devgate-service-switch' }, [
		_('启动'),
		input
	]);
}

function renderPageHeader(version, initialStatus) {
	return E('div', { 'class': 'devgate-page-header' }, [
		E('h2', {}, [
			E('a', {
				href: 'https://github.com/Antecer/luci-app-devgate',
				target: '_blank',
				rel: 'noreferrer noopener'
			}, 'DevGate v%s'.format(version || 'unknown')),
			renderServiceSwitch(initialStatus)
		])
	]);
}

function renderStylesheet() {
	return E('link', {
		rel: 'stylesheet',
		href: L.resource('view/devgate/custom.css')
	});
}

function takeRulesAddButton(section) {
	var create = section.querySelector('div.cbi-section-create');
	var addButton = create ? create.querySelector('.cbi-button') : null;

	if (create && create.parentNode) {
		create.parentNode.removeChild(create);
	}

	return addButton;
}

function renderRulesTitle(section) {
	var oldTitle = section.querySelector('h3, legend, .cbi-section-title');
	var titleChildren = [
		_('设备规则')
	];
	var addButton = takeRulesAddButton(section);

	if (addButton) {
		titleChildren.push(addButton);
	}

	var title = E('h3', { 'class': 'devgate-rules-title' }, titleChildren);

	if (oldTitle && oldTitle.parentNode) {
		oldTitle.parentNode.insertBefore(title, oldTitle);
		oldTitle.parentNode.removeChild(oldTitle);
	} else {
		section.insertBefore(title, section.firstChild);
	}

	return title;
}

function wrapRulesTable(section) {
	var table = section.querySelector('.cbi-section-table');

	if (!table) {
		return;
	}

	var scroller = table.parentNode && table.parentNode.classList.contains('devgate-rules-table-scroll')
		? table.parentNode
		: null;

	if (!scroller) {
		scroller = E('div', { 'class': 'devgate-rules-table-scroll' });
		table.parentNode.insertBefore(scroller, table);
		scroller.appendChild(table);
	}
}

function getOptionControl(row, option) {
	return row.querySelector('select[name$=".%s"], input[type="checkbox"][name$=".%s"], input[name$=".%s"], [id$=".%s"]'.format(option, option, option, option));
}

function getOptionCell(row, option) {
	var control = getOptionControl(row, option);

	return control ? control.closest('.cbi-section-table-cell, td, th') : null;
}

function getControlValue(row, option) {
	var control = getOptionControl(row, option);

	if (!control) {
		return null;
	}

	if (control.type === 'checkbox') {
		return control.checked ? '1' : '0';
	}

	return control.value;
}

function getRuleRows(table) {
	return Array.prototype.filter.call(table.querySelectorAll('.cbi-section-table-row'), function (row) {
		return !!getOptionControl(row, 'time_mode');
	});
}

function rowUsesColumn(row, option) {
	var mode = getControlValue(row, 'time_mode') || 'period';

	switch (option) {
	case 'time_from':
	case 'time_over':
		return mode === 'period' || mode === 'combined';

	case 'duration':
	case 'reset_cycle':
		return mode === 'duration' || (mode === 'combined' && getControlValue(row, 'use_duration') === '1');

	case 'use_duration':
		return mode === 'combined';
	}

	return true;
}

function getOptionColumnIndexes(rows, options) {
	var indexes = {};

	rows.some(function (row) {
		var cells = Array.prototype.slice.call(row.children);

		options.forEach(function (option) {
			var cell = getOptionCell(row, option);
			var index = cell ? cells.indexOf(cell) : -1;

			if (index !== -1) {
				indexes[option] = index;
			}
		});

		return Object.keys(indexes).length === options.length;
	});

	return indexes;
}

function setColumnHidden(table, index, hidden) {
	var rows = table.querySelectorAll('.cbi-section-table-titles, .cbi-section-table-row');

	Array.prototype.forEach.call(rows, function (row) {
		var cell = row.children[index];

		if (cell) {
			cell.classList.toggle('devgate-column-hidden', hidden);
		}
	});
}

function updateModeColumns(table) {
	var options = ['time_from', 'time_over', 'duration', 'reset_cycle', 'use_duration'];
	var rows = getRuleRows(table);
	var indexes = getOptionColumnIndexes(rows, options);

	if (rows.length === 0) {
		options.forEach(function (option) {
			if (indexes[option] != null) {
				setColumnHidden(table, indexes[option], false);
			}
		});
		return;
	}

	options.forEach(function (option) {
		if (indexes[option] == null) {
			return;
		}

		var used = rows.some(function (row) {
			return rowUsesColumn(row, option);
		});

		setColumnHidden(table, indexes[option], !used);
	});
}

function setupModeColumns(section) {
	var table = section.querySelector('.cbi-section-table');

	if (!table) {
		return;
	}

	var scheduleUpdate = function () {
		window.setTimeout(function () {
			updateModeColumns(table);
		}, 0);
	};

	table.addEventListener('change', function (ev) {
		var target = ev.target;

		if (target && target.name && /\.(time_mode|use_duration)$/.test(target.name)) {
			scheduleUpdate();
		}
	});

	if (window.MutationObserver) {
		var observer = new window.MutationObserver(scheduleUpdate);
		observer.observe(table, {
			childList: true,
			subtree: true
		});
	}

	scheduleUpdate();
}

function setupRulesLayout(mapEl) {
	var section = mapEl.querySelector('.cbi-section');

	if (!section) {
		return mapEl;
	}

	section.classList.add('devgate-rules-section');

	renderRulesTitle(section);

	wrapRulesTable(section);

	setupModeColumns(section);

	return mapEl;
}

function normalizeIp(ip) {
	if (ip == null) {
		return null;
	}

	ip = String(ip).trim();

	if (ip === '') {
		return null;
	}

	if (ip.indexOf(',') !== -1) {
		ip = ip.split(',')[0].trim();
	}

	if (ip.indexOf('::ffff:') === 0) {
		ip = ip.substring(7);
	}

	if (/^\[[0-9a-fA-F:]+\](?::\d+)?$/.test(ip)) {
		return ip.replace(/^\[/, '').replace(/\](?::\d+)?$/, '').toLowerCase();
	}

	if (/^([0-9]{1,3}\.){3}[0-9]{1,3}:\d+$/.test(ip)) {
		ip = ip.replace(/:\d+$/, '');
	}

	if (/^([0-9]{1,3}\.){3}[0-9]{1,3}\/[0-9]{1,2}$/.test(ip)) {
		ip = ip.replace(/\/[0-9]{1,2}$/, '');
	} else if (/^[0-9a-fA-F:]+\/[0-9]{1,3}$/.test(ip)) {
		ip = ip.replace(/\/[0-9]{1,3}$/, '');
	}

	return ip.toLowerCase();
}

function normalizeMac(mac) {
	if (mac == null) {
		return null;
	}

	mac = String(mac).trim().toLowerCase();

	return /^([0-9a-f]{2}:){5}[0-9a-f]{2}$/.test(mac) ? mac : null;
}

function getEnvRemoteAddress() {
	var keys = ['remote_addr', 'REMOTE_ADDR', 'peeraddr', 'client_ip'];

	for (var i = 0; i < keys.length; i++) {
		var value = normalizeIp(L.env && L.env[keys[i]]);

		if (value) {
			return value;
		}
	}

	return null;
}

function addClientIp(ips, value) {
	var ip = normalizeIp(value);

	if (ip) {
		ips[ip] = true;
	}
}

function parseClientIps(text) {
	var ips = {};

	String(text || '').split(/[\r\n]+/).forEach(function (line) {
		line = line.trim();

		if (!line) {
			return;
		}

		line.split(',').forEach(function (part) {
			var forwarded = String(part || '').match(/for="?([^;,"]+)/i);

			addClientIp(ips, forwarded ? forwarded[1] : part);
		});
	});

	return ips;
}

function responseText(res) {
	if (!res) {
		return '';
	}

	if (typeof res.text === 'function') {
		return res.text();
	}

	if (typeof res.text === 'string') {
		return res.text;
	}

	if (typeof res.responseText === 'string') {
		return res.responseText;
	}

	if (res.xhr && typeof res.xhr.responseText === 'string') {
		return res.xhr.responseText;
	}

	return '';
}

function parseRemoteAddressResponse(text) {
	var ips = parseClientIps(text);

	try {
		var data = JSON.parse(text);
		['ipaddr', 'ip', 'remote_addr', 'address'].forEach(function (field) {
			addClientIp(ips, data && data[field]);
		});

		L.toArray(data && data.ips).forEach(function (ip) {
			addClientIp(ips, ip);
		});
	} catch (e) {
	}

	return Object.keys(ips);
}

function normalizeClient(value) {
	var ips = {};

	L.toArray(value && value.ips).forEach(function (ip) {
		addClientIp(ips, ip);
	});

	addClientIp(ips, value && value.ip);

	return {
		ips: Object.keys(ips)
	};
}

function appendCurrentClientIp(client, ip) {
	if (!ip) {
		return;
	}

	client.ips = client.ips || [];

	if (client.ips.indexOf(ip) === -1) {
		client.ips.push(ip);
	}
}

function requestRemoteAddress(path) {
	return request.get(L.url(path))
		.then(function (res) {
			if (res && typeof res.json === 'function') {
				try {
					var data = res.json();
					var jsonIps = {};

					['ipaddr', 'ip', 'remote_addr', 'address'].forEach(function (field) {
						addClientIp(jsonIps, data && data[field]);
					});

					L.toArray(data && data.ips).forEach(function (ip) {
						addClientIp(jsonIps, ip);
					});

					if (Object.keys(jsonIps).length > 0) {
						return Object.keys(jsonIps);
					}
				} catch (e) { }
			}

			return Promise.resolve(responseText(res)).then(function (text) {
				return parseRemoteAddressResponse(text);
			});
		})
		.catch(function () {
			return null;
		});
}

function getCurrentClient() {
	var envIp = getEnvRemoteAddress();
	var client = { ips: [] };

	if (envIp) {
		appendCurrentClientIp(client, envIp);
	}

	return requestRemoteAddress('admin/services/devgate/remote_addr')
		.then(function (ips) {
			L.toArray(ips).forEach(function (ip) {
				appendCurrentClientIp(client, ip);
			});

			return normalizeClient(client);
		});
}

function getHostEntries(hostHints) {
	if (!hostHints) {
		return {};
	}

	return hostHints.hosts || hostHints;
}

function getHostHints() {
	return L.resolveDefault(callHostHints(), {});
}

function normalizeHostIp(value) {
	if (value && typeof value === 'object') {
		value = value.address || value.ipaddr || value.ip || value.addr || value[0];
	}

	return normalizeIp(value);
}

function getHostIps(host) {
	var seen = {};
	var ips = [];
	var fields = ['ipaddrs', 'ipaddr', 'ipv4', 'ipv4-address', 'ip6addrs', 'ip6addr', 'ipv6', 'ipv6-address'];

	fields.forEach(function (field) {
		L.toArray(host && host[field]).forEach(function (value) {
			var ip = normalizeHostIp(value);

			if (ip && !seen[ip]) {
				seen[ip] = true;
				ips.push(ip);
			}
		});
	});

	return ips;
}

function isIpv4(ip) {
	return /^([0-9]{1,3}\.){3}[0-9]{1,3}$/.test(ip);
}

function ipv4ToInt(ip) {
	var parts = String(ip || '').split('.');

	if (parts.length !== 4) {
		return null;
	}

	var value = 0;

	for (var i = 0; i < parts.length; i++) {
		var part = Number(parts[i]);

		if (!Number.isInteger(part) || part < 0 || part > 255) {
			return null;
		}

		value = (value << 8) + part;
	}

	return value >>> 0;
}

function maskToPrefix(mask) {
	var value = ipv4ToInt(mask);
	var prefix = 0;
	var seenZero = false;

	if (value == null) {
		return null;
	}

	for (var i = 31; i >= 0; i--) {
		if (value & (1 << i)) {
			if (seenZero) {
				return null;
			}

			prefix++;
		} else {
			seenZero = true;
		}
	}

	return prefix;
}

function getLanNetworks() {
	var ipaddr = uci.get('network', 'lan', 'ipaddr');
	var netmask = uci.get('network', 'lan', 'netmask');
	var ipaddrs = L.toArray(ipaddr);
	var networks = [];

	ipaddrs.forEach(function (value) {
		var ip = String(value || '').trim();
		var prefix = null;
		var slash = ip.indexOf('/');

		if (slash !== -1) {
			prefix = Number(ip.substring(slash + 1));
			ip = ip.substring(0, slash);
		} else {
			prefix = maskToPrefix(netmask || '255.255.255.0');
		}

		var addr = ipv4ToInt(ip);

		if (addr == null || !Number.isInteger(prefix) || prefix < 0 || prefix > 32) {
			return;
		}

		var mask = prefix === 0 ? 0 : (0xffffffff << (32 - prefix)) >>> 0;

		networks.push({
			network: addr & mask,
			mask: mask
		});
	});

	return networks;
}

function isInNetworks(ip, networks) {
	var addr = ipv4ToInt(ip);

	if (addr == null || networks.length === 0) {
		return false;
	}

	for (var i = 0; i < networks.length; i++) {
		if ((addr & networks[i].mask) === networks[i].network) {
			return true;
		}
	}

	return false;
}

function getHostIpv4s(host) {
	return getHostIps(host).filter(isIpv4);
}

function formatHostOption(mac, host, ipv4s) {
	var normalizedMac = normalizeMac(mac) || String(mac || '').trim();
	var ipText = ipv4s.length > 0 ? ipv4s.join(', ') : _('未知IP');
	var name = String(host && host.name || '').trim() || _('未知设备');

	return E('span', { 'class': 'devgate-host-option' }, [
		name,
		E('br'),
		normalizedMac.toUpperCase(),
		E('br'),
		ipText
	]);
}

function formatHostSortText(mac, host, ipv4s) {
	var normalizedMac = normalizeMac(mac) || String(mac || '').trim();
	var ipText = ipv4s.length > 0 ? ipv4s.join(', ') : _('未知IP');
	var name = String(host && host.name || '').trim() || _('未知设备');

	return '%s %s %s'.format(name, normalizedMac.toUpperCase(), ipText);
}

function protectHost(protectedClient, mac, host) {
	var normalizedMac = normalizeMac(mac);
	var ips = getHostIps(host);

	if (normalizedMac) {
		protectedClient.macs[normalizedMac] = true;
	}

	for (var i = 0; i < ips.length; i++) {
		protectedClient.ips[ips[i]] = true;
	}
}

function buildProtectedClient(hostHints, currentClient) {
	var protectedClient = {
		ips: {},
		macs: {}
	};
	var hosts = getHostEntries(hostHints);

	L.toArray(currentClient && currentClient.ips).forEach(function (ip) {
		protectedClient.ips[ip] = true;
	});

	if (hostHints && typeof hostHints.getMACAddrByIPAddr === 'function') {
		L.toArray(currentClient && currentClient.ips).forEach(function (ip) {
			var matchedMac = normalizeMac(hostHints.getMACAddrByIPAddr(ip));

			if (matchedMac) {
				if (hosts[matchedMac]) {
					protectHost(protectedClient, matchedMac, hosts[matchedMac]);
				} else {
					protectedClient.macs[matchedMac] = true;
				}
			}
		});
	}

	Object.keys(hosts).forEach(function (mac) {
		var host = hosts[mac];
		var ips = getHostIps(host);
		var isCurrentHost = false;

		for (var i = 0; i < ips.length; i++) {
			if (protectedClient.ips[ips[i]]) {
				isCurrentHost = true;
				break;
			}
		}

		if (isCurrentHost) {
			protectHost(protectedClient, mac, host);
		}
	});

	return protectedClient;
}

function isProtectedTarget(value, protectedClient) {
	var ip = normalizeIp(value);
	var mac = normalizeMac(value);

	return !!((ip && protectedClient.ips[ip]) || (mac && protectedClient.macs[mac]));
}

function isProtectedHost(mac, ips, protectedClient) {
	var normalizedMac = normalizeMac(mac);

	if (normalizedMac && protectedClient.macs[normalizedMac]) {
		return true;
	}

	for (var i = 0; i < ips.length; i++) {
		if (protectedClient.ips[ips[i]]) {
			return true;
		}
	}

	return false;
}

return view.extend({
	load: function () {
		return Promise.all([
			uci.load('devgate'),
			uci.load('network'),
			getHostHints(),
			getCurrentClient(),
			getPackageVersion(),
			getServiceStatus()
		]);
	},

	render: function (data) {
		var m, s, o;
		var hostHints = data[2];
		var hosts = getHostEntries(hostHints);
		var protectedClient = buildProtectedClient(hostHints, data[3]);
		var lanNetworks = getLanNetworks();

		m = new form.Map('devgate');

		var s = m.section(form.TableSection, 'device', _('设备规则'));
		s.addremove = true;
		s.anonymous = true;
		s.sortable = false;

		o = s.option(form.Value, 'comment', _('备注'));
		o.optional = true;
		o.placeholder = _('可选备注');

		o = s.option(form.Flag, 'enable', _('启用'));
		o.rmempty = false;
		o.default = '1';

		o = s.option(form.Value, 'mac', _('目标设备'));
		o.rmempty = false;
		// o.description = _('以MAC识别设备，IP仅用于辅助辨认。');
		o.validate = function (section_id, value) {
			if (isProtectedTarget(value, protectedClient)) {
				return _('不能选择当前登录设备。');
			}

			if (!normalizeMac(value)) {
				return _('请选择或输入设备MAC。');
			}

			return true;
		};

		if (hosts) {
			var hostOptions = {};
			var hostSortText = {};

			Object.keys(hosts).forEach(function (mac) {
				var host = hosts[mac];
				var ips = getHostIps(host);
				var lanIpv4s = getHostIpv4s(host).filter(function (ip) {
					return isInNetworks(ip, lanNetworks);
				});

				if (lanIpv4s.length === 0 || isProtectedHost(mac, ips, protectedClient)) {
					return;
				}

				hostOptions[mac] = formatHostOption(mac, host, lanIpv4s);
				hostSortText[mac] = formatHostSortText(mac, host, lanIpv4s);
			});
			var sortedKeys = Object.keys(hostOptions).sort(function (a, b) {
				return hostSortText[a].localeCompare(hostSortText[b]);
			});

			sortedKeys.forEach(function (key) {
				o.value(key, hostOptions[key]);
			});
		}

		o = s.option(form.ListValue, 'chain', _('管控强度'));
		o.value('forward', _('禁止访问公共网络'));
		o.value('input', _('禁止访问全部网络'));
		o.default = 'forward';
		o.rmempty = false;

		// 控制方式选择
		o = s.option(form.ListValue, 'time_mode', _('管控方式'));
		o.value('period', _('按时段'));
		o.value('duration', _('按时长'));
		o.value('combined', _('时段 + 时长'));
		o.default = 'period';
		o.rmempty = false;

		// 时间段控制字段
		o = s.option(form.Value, 'time_from', _('开始时间'));
		o.placeholder = '00:00';
		o.default = '00:00';
		o.depends({ 'time_mode': 'period', '!contains': true });
		o.depends({ 'time_mode': 'combined', '!contains': true });

		o = s.option(form.Value, 'time_over', _('结束时间'));
		o.placeholder = '00:00';
		o.default = '00:00';
		o.depends({ 'time_mode': 'period', '!contains': true });
		o.depends({ 'time_mode': 'combined', '!contains': true });

		// 可用时长字段
		o = s.option(form.Value, 'duration', _('可用时长（分钟）'));
		o.placeholder = '60';
		o.default = '60';
		o.datatype = 'min(1)';
		o.depends({ 'time_mode': 'duration', '!contains': true });
		o.depends({ 'time_mode': 'combined', '!contains': true });
		// o.description = _('上线后累计可用分钟数。');

		// 重置周期
		o = s.option(form.ListValue, 'reset_cycle', _('重置周期'));
		o.value('daily', _('每日重置'));
		o.value('weekly', _('每周重置'));
		o.value('monthly', _('每月重置'));
		o.value('never', _('不重置'));
		o.default = 'daily';
		o.depends({ 'time_mode': 'duration', '!contains': true });
		o.depends({ 'time_mode': 'combined', '!contains': true });
		// o.description = _('清零已用时长的周期。');

		// 组合控制：是否在时间段内启用时长限制
		o = s.option(form.Flag, 'use_duration', _('叠加时长限制'));
		o.default = '0';
		o.depends({ 'time_mode': 'combined', '!contains': true });
		// o.description = _('在允许时段内继续限制可用时长。');

		o = s.option(form.Value, 'week', _('生效日期'));
		o.value('0', _('每天'));
		o.value('1', _('周一'));
		o.value('2', _('周二'));
		o.value('3', _('周三'));
		o.value('4', _('周四'));
		o.value('5', _('周五'));
		o.value('6', _('周六'));
		o.value('7', _('周日'));
		o.value('1,2,3,4,5', _('工作日'));
		o.value('6,7', _('休息日'));
		o.default = '0';
		o.rmempty = false;
		// o.description = _('规则生效的日期。');

		return m.render().then(function (mapEl) {
			setupRulesLayout(mapEl);

			var pageEl = E('div', { 'class': 'devgate-page' }, [
				renderStylesheet(),
				renderPageHeader(data[4], data[5]),
				mapEl
			]);

			(async () => {
				function sleep(ms) {
					return new Promise((resolve) => setTimeout(resolve, ms));
				}
				// 计算容器外部元素占用高度
				var pageOffset = 0;
				var offsetSelectors = ['.bg-primary', '.mobile-hide', '.cbi-page-actions'];
				while (!document.querySelector('.cbi-page-actions')) await sleep(100);
				for (let selector of offsetSelectors) {
					let node = document.querySelector(selector);
					if (node) {
						let style = window.getComputedStyle(node);
						if (style.display === 'none' || style.visibility === 'hidden') continue;
						let rect = node.getBoundingClientRect();
						pageOffset += rect.height + (parseFloat(style.marginTop) || 0) + (parseFloat(style.marginBottom) || 0);
					}
				}
				let container = document.querySelector('#maincontent>.container');
				if (container) {
					let style = window.getComputedStyle(container);
					pageOffset += (parseFloat(style.marginTop) || 0) + (parseFloat(style.marginBottom) || 0);
				}
				pageOffset = Math.ceil(pageOffset);
				if (pageOffset > 0) {
					pageEl.style.setProperty('--devgate-page-offset', '%dpx'.format(pageOffset));
				}
			})();

			return pageEl;
		});
	}
});
