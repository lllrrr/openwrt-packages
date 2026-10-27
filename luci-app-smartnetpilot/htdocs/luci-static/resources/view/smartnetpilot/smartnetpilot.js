'use strict';
'require view';
'require form';
'require network';
'require uci';
'require ui';
'require dom';
'require rpc';
'require request';
'require tools.widgets as widgets';

var callGetIp = rpc.declare({
	object: 'luci.smartnetpilot',
	method: 'get_ip',
	expect: { ip: '' }
});

var callArmApply = rpc.declare({
	object: 'luci.smartnetpilot',
	method: 'arm_apply',
	params: [ 'rollback', 'timeout' ]
});

var callApplyStatus = rpc.declare({
	object: 'luci.smartnetpilot',
	method: 'apply_status',
	params: [ 'token' ]
});

var callConfirmApply = rpc.declare({
	object: 'luci.smartnetpilot',
	method: 'confirm_apply',
	params: [ 'token' ]
});

var callCancelApply = rpc.declare({
	object: 'luci.smartnetpilot',
	method: 'cancel_apply',
	params: [ 'token' ]
});

var callRollbackApply = rpc.declare({
	object: 'luci.smartnetpilot',
	method: 'rollback_apply',
	params: [ 'token' ]
});

// Board-declared physical ports; used to keep the switch CPU port out of the
// WAN device list.
var callPhysicalPorts = rpc.declare({
	object: 'luci.smartnetpilot',
	method: 'physical_ports'
});

// Seconds the device waits for a confirmation before restoring the snapshot.
var APPLY_TIMEOUT = 120;

var MODES = {
	pppoe: {
		title: _('PPPoE Dial-up'),
		description: _('Dial up with the broadband account and password supplied by your ISP. Choose this when the line requires PPPoE authentication.'),
		accent: 'snp-accent-violet',
		icon: 'key'
	},
	dhcp: {
		title: _('DHCP Client'),
		description: _('Obtain an address automatically from an upstream modem or router. Choose this when the new router joins an existing network as an extension node.'),
		accent: 'snp-accent-cyan',
		icon: 'link'
	},
	siderouter: {
		title: _('Side Router'),
		description: _('Keep the existing main router and use this device for additional services. Choose this when LAN clients need to use this device as their gateway.'),
		accent: 'snp-accent-emerald',
		icon: 'topology'
	}
};

var ICONS = {
	logo: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M12 3l7 4v5c0 4.4-3 7.6-7 9-4-1.4-7-4.6-7-9V7l7-4z"/><path d="M9.5 12.5l1.8 1.8 3.4-3.6"/></svg>',
	key: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="8" cy="15" r="4"/><path d="M11 12l8-8"/><path d="M16 7l2 2"/><path d="M18 5l2 2"/></svg>',
	link: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M9.5 14.5l5-5"/><path d="M7.2 16.8l-1.1 1.1a3.4 3.4 0 01-4.8-4.8l3.4-3.4a3.4 3.4 0 014.8 0"/><path d="M16.8 7.2l1.1-1.1a3.4 3.4 0 014.8 4.8l-3.4 3.4a3.4 3.4 0 01-4.8 0"/></svg>',
	topology: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="3" y="3" width="6" height="5" rx="1.5"/><rect x="15" y="3" width="6" height="5" rx="1.5"/><rect x="9" y="16" width="6" height="5" rx="1.5"/><path d="M6 8v3.5h12V8"/><path d="M12 11.5V16"/></svg>',
	arrow: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M5 12h14"/><path d="M14 7l5 5-5 5"/></svg>',
	refresh: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M20 11a8 8 0 10-2.3 5.7"/><path d="M20 4v7h-7"/></svg>',
	sliders: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M4 6h9"/><path d="M17 6h3"/><circle cx="15" cy="6" r="2"/><path d="M4 12h3"/><path d="M11 12h9"/><circle cx="9" cy="12" r="2"/><path d="M4 18h9"/><path d="M17 18h3"/><circle cx="15" cy="18" r="2"/></svg>',
	check:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M20 6L9 17l-5-5"/></svg>',
	alert: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M10.3 3.7L2.3 17a2 2 0 001.7 3h16a2 2 0 001.7-3l-8-13.3a2 2 0 00-3.4 0z"/><path d="M12 9v4"/><path d="M12 17h.01"/></svg>',
	wifi: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M2 8.8a15 15 0 0120 0"/><path d="M5 12.4a10.5 10.5 0 0114 0"/><path d="M8.5 16a5.5 5.5 0 017 0"/><circle cx="12" cy="19.5" r="1"/></svg>',
	shield: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M12 3l7 3v5.5c0 4.2-2.9 7.3-7 8.5-4.1-1.2-7-4.3-7-8.5V6l7-3z"/></svg>',
	info: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="12" cy="12" r="9"/><path d="M12 11v5"/><path d="M12 8h.01"/></svg>'
};

var appliedListenerBound = false;
var themeListenerBound = false;

function icon(name, className) {
	// E() sets unknown properties with setAttribute(), so innerHTML has to be
	// assigned on the node itself for the SVG markup to be parsed.
	var node = E('span', { 'class': className || '' });
	node.innerHTML = ICONS[name] || '';
	return node;
}

// Argon draws a 2rem band under its header that overlaps the first row of the
// content area; the view adds top spacing on that theme only.
function themeClass() {
	var header = document.querySelector('.main-right > header');
	return (header && header.classList.contains('bg-primary')) ? ' snp-on-argon' : '';
}

function stripCidr(value) {
	if (typeof value !== 'string')
		return '';

	return value.split('/')[0];
}

function currentScriptPage() {
	return window.location.pathname + window.location.search;
}

function buildOrigin(host, useHttps) {
	if (!host)
		return null;

	var protocol = useHttps ? 'https:' : 'http:';
	var port = window.location.port;

	if (!port || port === '80' || port === '443')
		port = '';

	return protocol + '//' + host + (port ? ':' + port : '');
}

function parseColor(value) {
	var match = /^rgba?\(\s*([\d.]+)[,\s]+([\d.]+)[,\s]+([\d.]+)(?:[,\s/]+([\d.]+))?\s*\)$/.exec(value || '');
	if (!match)
		return null;

	return {
		r: Number(match[1]),
		g: Number(match[2]),
		b: Number(match[3]),
		a: match[4] != null ? Number(match[4]) : 1
	};
}

function luminance(color) {
	function channel(value) {
		value /= 255;
		return value <= 0.03928 ? value / 12.92 : Math.pow((value + 0.055) / 1.055, 2.4);
	}

	return 0.2126 * channel(color.r) + 0.7152 * channel(color.g) + 0.0722 * channel(color.b);
}

function themeFromNode(node) {
	if (!node)
		return null;

	var tokens = String(node.className || '').toLowerCase().split(/\s+/);
	var darkClasses = [ 'dark', 'dark-mode', 'darkmode', 'theme-dark', 'dark-theme', 'night' ];
	var lightClasses = [ 'light', 'light-mode', 'lightmode', 'theme-light', 'light-theme', 'day' ];
	var i;

	for (i = 0; i < darkClasses.length; i++)
		if (tokens.indexOf(darkClasses[i]) >= 0)
			return 'dark';

	for (i = 0; i < lightClasses.length; i++)
		if (tokens.indexOf(lightClasses[i]) >= 0)
			return 'light';

	var attrs = [ 'data-theme', 'data-mode', 'data-bs-theme', 'data-color-mode' ];
	for (i = 0; i < attrs.length; i++) {
		var value = String(node.getAttribute(attrs[i]) || '').toLowerCase();
		if (value === 'dark' || value === 'night')
			return 'dark';
		if (value === 'light' || value === 'day')
			return 'light';
	}

	return null;
}

function detectTheme() {
	var nodes = [
		document.documentElement,
		document.body,
		document.getElementById('maincontent'),
		document.querySelector('.main-content'),
		document.querySelector('#app'),
		document.querySelector('.app')
	];

	for (var i = 0; i < nodes.length; i++) {
		var marked = themeFromNode(nodes[i]);
		if (marked)
			return marked;
	}

	var probe = document.body;
	while (probe) {
		var color = parseColor(window.getComputedStyle(probe).backgroundColor);
		if (color && color.a >= 0.5)
			return luminance(color) < 0.42 ? 'dark' : 'light';
		probe = probe.parentElement;
	}

	return window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
}

function syncTheme() {
	document.documentElement.setAttribute('data-snp-theme', detectTheme());
}

function bindThemeWatchers() {
	if (themeListenerBound)
		return;

	themeListenerBound = true;
	syncTheme();

	var observer = new MutationObserver(syncTheme);
	var options = {
		attributes: true,
		attributeFilter: [ 'class', 'style', 'data-theme', 'data-mode', 'data-bs-theme', 'data-color-mode' ]
	};

	observer.observe(document.documentElement, options);
	if (document.body)
		observer.observe(document.body, options);

	var main = document.getElementById('maincontent');
	if (main)
		observer.observe(main, options);

	if (window.matchMedia) {
		var media = window.matchMedia('(prefers-color-scheme: dark)');
		if (media.addEventListener)
			media.addEventListener('change', syncTheme);
		else if (media.addListener)
			media.addListener(syncTheme);
	}

	window.addEventListener('load', syncTheme);
}

function ensureStyles() {
	if (document.getElementById('snp-styles'))
		return;

	document.head.appendChild(E('link', {
		'id': 'snp-styles',
		'rel': 'stylesheet',
		'href': L.resource('view/smartnetpilot/smartnetpilot.css')
	}));
}

function bindAppliedListener() {
	if (appliedListenerBound)
		return;

	appliedListenerBound = true;

	document.addEventListener('uci-applied', function() {
		var app = document.querySelector('.snp-app');

		if (!app)
			return;

		var toast = E('div', { 'class': 'snp-toast is-success' }, [
			icon('check'),
			E('span', {}, _('Configuration applied successfully.'))
		]);

		app.appendChild(toast);
		window.setTimeout(function() {
			if (toast.parentNode)
				toast.parentNode.removeChild(toast);
		}, 4000);
	});
}

function modeInfo(mode) {
	return MODES[mode] || MODES.siderouter;
}

function modeNameFromNetwork(proto) {
	if (proto === 'pppoe')
		return 'pppoe';

	if (proto === 'dhcp' || proto === 'static')
		return 'dhcp';

	return 'siderouter';
}

function sectionValue(config, type, option) {
	var sections = uci.sections(config, type) || [];

	for (var i = 0; i < sections.length; i++)
		if (sections[i][option] != null)
			return sections[i][option];

	return null;
}

return view.extend({
	load: function() {
		ensureStyles();
		bindThemeWatchers();
		bindAppliedListener();

		return Promise.all([
			L.resolveDefault(network.getDevices(), []),
			L.resolveDefault(uci.load('wireless'), null),
			uci.load('network'),
			uci.load('smartnetpilot'),
			L.resolveDefault(callGetIp(), { ip: '' }),
			L.resolveDefault(callApplyStatus(), null),
			L.resolveDefault(callPhysicalPorts(), null)
		]);
	},

	render: function(data) {
		var self = this;
		var applyStatus = data[5] || null;
		var boardPorts = (data[6] && data[6].known && Array.isArray(data[6].ports))
			? data[6].ports : null;
		var devices = data[0] || [];
		var lanIp = (data[4] && data[4].ip) ? data[4].ip : stripCidr(uci.get('network', 'lan', 'ipaddr'));
		var networkProto = uci.get('network', 'wan', 'proto');
		var storedMode = uci.get('smartnetpilot', 'default', 'wan_proto');
		var currentMode = MODES[storedMode] ? storedMode : modeNameFromNetwork(networkProto);
		var wifiSections = uci.sections('wireless', 'wifi-iface') || [];
		var wifiDeviceSections = uci.sections('wireless', 'wifi-device') || [];
		var ap = null;

		for (var i = 0; i < wifiSections.length; i++) {
			if (wifiSections[i].mode === 'ap') {
				ap = wifiSections[i];
				break;
			}
		}

		if (!ap && wifiSections.length)
			ap = wifiSections[0];

		this._devices = devices;
		this._boardPorts = boardPorts;
		this._lanIp = lanIp || '';
		this._wanFace = uci.get('network', 'wan', 'device') ||
			uci.get('network', 'wan', 'ifname') ||
			uci.get('smartnetpilot', 'default', 'wan_interface') || '';
		this._hasWifi = wifiSections.length > 0 || wifiDeviceSections.length > 0;
		this._currentMode = currentMode;
		this._wifiSsid = ap ? (ap.ssid || '') : '';
		this._wifiKey = ap ? (ap.key || '') : '';
		this._initialHttps = uci.get('smartnetpilot', 'default', 'https') === '1';
		this._initial = {
			lanIp: this._lanIp,
			https: this._initialHttps,
			wifiSsid: this._wifiSsid,
			wifiKey: this._wifiKey
		};

		var params = new URLSearchParams(window.location.search);
		var requested = params.get('mode');

		// A pending apply survives page loads and IP changes: reopening the
		// wizard on the new address must still offer the confirmation.
		if (applyStatus && applyStatus.status === 'pending') {
			window.setTimeout(function() {
				self._showRollbackModal(applyStatus);
			}, 400);
		}
		else if (applyStatus && applyStatus.status === 'armed') {
			this._watchArmedApply(20);
		}

		if (requested && MODES[requested])
			return this.renderConfig(requested, params.get('tab'));

		return this.renderChooser(currentMode);
	},

	renderChooser: function(currentMode) {
		var info = modeInfo(currentMode);
		var root = E('div', { 'class': 'snp-app snp-chooser' + themeClass() });
		var wifiLabel = this._hasWifi ? (this._wifiSsid || _('Not configured')) : _('No wireless card detected');
		var httpsLabel = this._initialHttps ? _('Enabled') : _('Disabled');

		this._root = root;

		root.appendChild(E('section', { 'class': 'snp-hero' }, [
			E('div', { 'class': 'snp-hero-copy' }, [
				E('div', { 'class': 'snp-brand' }, [
					icon('logo', 'snp-logo'),
					E('div', {}, [
						E('div', { 'class': 'snp-brand-name' }, _('Smart NetPilot')),
						E('div', { 'class': 'snp-chip' }, _('Network setup'))
					])
				]),
				E('div', { 'class': 'snp-kicker' }, _('Guided setup')),
				E('h1', {}, _('Choose the type of network setup you need and follow the wizard to finish the configuration quickly.')),
				E('div', { 'class': 'snp-hero-meta' }, [
					E('span', { 'class': 'snp-chip' }, [ E('span', { 'class': 'snp-chip-dot' }), _('Automatic light and dark theme') ]),
					E('span', { 'class': 'snp-chip' }, [ icon('shield'), _('Validated before apply') ]),
					E('span', { 'class': 'snp-chip' }, [ icon('refresh'), _('Rollback within 120 s') ]),
					E('span', { 'class': 'snp-chip' }, [ icon('wifi'), _('IPv4 and IPv6') ])
				])
			]),
			E('div', { 'class': 'snp-status' }, [
				this._stat(_('Current mode'), info.title),
				this._stat(_('Management address'), this._lanIp || _('Unknown')),
				this._stat(_('Wireless'), wifiLabel),
				this._stat(_('HTTPS management'), httpsLabel)
			])
		]));

		root.appendChild(E('section', { 'class': 'snp-section' }, [
			E('div', { 'class': 'snp-mode-grid' }, [
				this._modeCard('pppoe', currentMode),
				this._modeCard('dhcp', currentMode),
				this._modeCard('siderouter', currentMode)
			]),
			E('div', { 'class': 'snp-help-strip' }, [
				icon('info'),
				E('span', {}, _('Not sure which to choose? Pick “PPPoE Dial-up” if you need to sign in with the broadband account and password from your ISP; pick “DHCP Client” if this device joins an existing network as an auxiliary or extension node.'))
			])
		]));

		window.setTimeout(syncTheme, 120);

		return root;
	},

	_stat: function(label, value) {
		return E('div', { 'class': 'snp-stat' }, [
			E('span', { 'class': 'snp-stat-label' }, label),
			E('span', { 'class': 'snp-stat-value' }, value)
		]);
	},

	_modeCard: function(mode, currentMode) {
		var info = MODES[mode];
		var self = this;

		return E('button', {
			'type': 'button',
			'class': 'snp-mode-card ' + info.accent + (mode === currentMode ? ' is-current' : ''),
			'aria-pressed': mode === currentMode ? 'true' : 'false',
			'click': function(ev) {
				return self._selectMode(mode, ev.currentTarget);
			}
		}, [
			E('div', { 'class': 'snp-mode-card-top' }, [
				icon(info.icon, 'snp-mode-icon'),
				mode === currentMode ? E('span', { 'class': 'snp-current-pill' }, _('Current')) : E('span')
			]),
			E('div', { 'class': 'snp-mode-body' }, [
				E('h3', { 'class': 'snp-mode-title' }, info.title),
				E('p', { 'class': 'snp-mode-desc' }, info.description)
			]),
			E('div', { 'class': 'snp-mode-foot' }, [
				E('span', {}, _('Configure %s').format(info.title)),
				icon('arrow', 'snp-mode-arrow')
			])
		]);
	},

	_selectMode: function(mode, button) {
		if (this._selecting)
			return;

		this._selecting = true;
		button.classList.add('is-busy');
		button.disabled = true;

		uci.set('smartnetpilot', 'default', 'wan_proto', mode);

		return uci.save().then(function() {
			window.location.href = L.url('admin/network/smartnetpilot') +
				'?mode=' + encodeURIComponent(mode) + '&tab=wansetup';
		}).catch(function(err) {
			this._selecting = false;
			button.classList.remove('is-busy');
			button.disabled = false;
			this._toast(_('Could not save the selected mode. %s').format(err && err.message ? err.message : ''), 'error');
		}.bind(this));
	},

	renderConfig: function(mode, requestedTab) {
		if (requestedTab === 'modesetup')
			requestedTab = 'wansetup';

		var info = modeInfo(mode);
		var self = this;
		var showAdvanced = (requestedTab === 'othersetup');
		var root = E('div', {
			'class': 'snp-app snp-config snp-mode-' + mode + themeClass() +
				(showAdvanced ? ' snp-show-advanced' : '')
		});

		this._root = root;
		this._mode = mode;

		root.appendChild(E('section', { 'class': 'snp-hero' }, [
			E('div', { 'class': 'snp-hero-copy' }, [
				E('div', { 'class': 'snp-brand' }, [
					icon('logo', 'snp-logo'),
					E('div', {}, [
						E('div', { 'class': 'snp-brand-name' }, _('Smart NetPilot')),
						E('div', { 'class': 'snp-chip' }, _('Guided setup'))
					])
				]),
				E('div', { 'class': 'snp-kicker' }, _('Configuration')),
				E('h1', {}, info.title),
				E('p', { 'class': 'snp-hero-subtitle' }, info.description)
			]),
			E('div', { 'class': 'snp-hero-actions' }, [
				E('div', { 'class': 'snp-mode-summary ' + info.accent }, [
					icon(info.icon, 'snp-mode-icon'),
					E('div', { 'class': 'snp-mode-summary-text' }, [
						E('strong', {}, _('Selected mode')),
						E('span', {}, info.title)
					])
				]),
				E('button', {
					'type': 'button',
					'class': 'snp-btn snp-btn-ghost snp-advanced-toggle',
					'aria-expanded': showAdvanced ? 'true' : 'false',
					'click': function(ev) {
						self._toggleAdvanced(ev.currentTarget);
					}
				}, [
					icon('sliders'),
					E('span', { 'class': 'snp-advanced-label' },
						showAdvanced ? _('Hide advanced settings') : _('Advanced settings'))
				]),
				E('a', {
					'class': 'snp-btn snp-btn-ghost',
					'href': L.url('admin/network/smartnetpilot'),
					'click': function(ev) {
						self._handleChangeMode(ev, ev.currentTarget.href);
					}
				}, [ icon('refresh'), _('Back to home') ])
			])
		]));

		var m = new form.Map('smartnetpilot', null, null);
		var s = m.section(form.NamedSection, 'default', 'smartnetpilot', null);
		s.addremove = false;
		s.anonymous = true;

		s.tab('wansetup', _('WAN Settings'));
		if (this._hasWifi)
			s.tab('wifisetup', _('Wireless Settings'), _('Set the wireless name and password. For advanced options, open Network → Wireless.'));
		s.tab('othersetup', _('Other Settings'));

		this._addModeFields(s, mode);
		this._addWanFields(s);
		if (this._hasWifi)
			this._addWirelessFields(s);
		this._addOtherFields(s);

		this._map = m;

		var shell = E('div', { 'class': 'snp-form-shell' });
		root.appendChild(shell);

		return m.render().then(function(mapNode) {
			dom.append(shell, mapNode);

			self._decorateForm(root);
			self._activateTab(root, requestedTab || 'wansetup');
			self._buildHeroTabs(root);
			window.setTimeout(syncTheme, 120);

			return root;
		});
	},

	_decorateForm: function(root) {
		var proto = root.querySelector('select[id$=".wan_proto"], input[id$=".wan_proto"]');
		if (proto) {
			var row = proto.closest('.cbi-value');
			if (row)
				row.classList.add('snp-hidden');
		}
	},

	// The hero already carries the mode summary, so the form's own tab menu is
	// hidden and mirrored as pills inside the hero. Clicking a pill drives the
	// original (hidden) tab link, which keeps LuCI's tab logic authoritative.
	_buildHeroTabs: function(root) {
		var menu = root.querySelector('.cbi-tabmenu');
		var hero = root.querySelector('.snp-hero');
		if (!menu || !hero || hero.querySelector('.snp-hero-tabs'))
			return;

		var self = this;
		var nav = E('nav', {
			'class': 'snp-hero-tabs',
			'role': 'tablist',
			'aria-label': _('Configuration')
		});

		menu.querySelectorAll('li[data-tab]').forEach(function(li) {
			var tab = li.getAttribute('data-tab');
			var link = li.querySelector('a');
			if (!tab || !link || li.style.display === 'none')
				return;

			nav.appendChild(E('button', {
				'type': 'button',
				'class': 'snp-tab-btn',
				'data-tab': tab,
				'role': 'tab',
				'aria-selected': 'false',
				'click': function(ev) {
					self._activateTab(root, tab);
					self._syncHeroTabs(root);
					ev.currentTarget.blur();
				}
			}, link.textContent));
		});

		hero.appendChild(nav);
		this._syncHeroTabs(root);
	},

	_syncHeroTabs: function(root) {
		var menu = root.querySelector('.cbi-tabmenu');
		if (!menu)
			return;

		root.querySelectorAll('.snp-hero-tabs .snp-tab-btn').forEach(function(btn) {
			var li = menu.querySelector('li[data-tab="' + btn.getAttribute('data-tab') + '"]');
			var active = !!(li && li.classList.contains('cbi-tab'));
			btn.classList.toggle('is-active', active);
			btn.setAttribute('aria-selected', active ? 'true' : 'false');
		});
	},

	// The original tab menu is hidden, so its per-tab error badge is invisible
	// too. After a failed save, reveal the first pane that holds an invalid
	// field instead of leaving the user on a tab that looks fine.
	_showFirstErrorTab: function(root) {
		var invalid = root.querySelector('.cbi-input-invalid');
		var pane = invalid ? invalid.closest('[data-tab]') : null;
		if (!pane)
			return;

		this._activateTab(root, pane.getAttribute('data-tab'));
		this._syncHeroTabs(root);
	},

	_toggleAdvanced: function(button) {
		var root = this._root;
		if (!root)
			return;

		var show = !root.classList.contains('snp-show-advanced');

		root.classList.toggle('snp-show-advanced', show);
		button.setAttribute('aria-expanded', show ? 'true' : 'false');

		var label = button.querySelector('.snp-advanced-label');
		if (label)
			label.textContent = show ? _('Hide advanced settings') : _('Advanced settings');

		var active = root.querySelector('.cbi-tabmenu li.cbi-tab[data-tab]');
		if (!show && active && active.getAttribute('data-tab') === 'othersetup')
			this._activateTab(root, 'wansetup');

		this._syncHeroTabs(root);
	},

	_activateTab: function(root, tab) {
		if (!tab)
			return;

		var link = root.querySelector('.cbi-tabmenu li[data-tab="' + tab + '"] > a');
		if (link && !link.parentNode.classList.contains('cbi-tab'))
			link.click();
	},

	_addModeFields: function(s, mode) {
		var o = s.taboption('wansetup', form.ListValue, 'wan_proto', _('Network Mode'));
		o.default = mode;
		o.value('dhcp', MODES.dhcp.title);
		o.value('pppoe', MODES.pppoe.title);
		o.value('siderouter', MODES.siderouter.title);
		o.readonly = true;
		o.rmempty = false;
		o.forcewrite = true;
		o.cfgvalue = function() {
			return mode;
		};
	},

	// PPPoE and DHCP pages show the LAN settings the router currently uses, so
	// the user edits real values instead of whatever the wizard stored last
	// time. Side-router mode keeps its own stored values.
	_lanLive: function(option) {
		switch (option) {
			case 'lan_ipaddr':
				return stripCidr(uci.get('network', 'lan', 'ipaddr')) || '';
			case 'lan_netmask':
				return uci.get('network', 'lan', 'netmask') || '';
			case 'lan_gateway':
				return uci.get('network', 'lan', 'gateway') || '';
			case 'lan_dns':
				return L.toArray(uci.get('network', 'lan', 'dns'));
		}

		return '';
	},

	_useLiveLan: function(o, option) {
		var self = this;

		o.cfgvalue = function() {
			return self._lanLive(option);
		};
		o.forcewrite = true;
		// An empty field means "keep the current setting"; the server only
		// writes the entries that actually differ from the live configuration.
		o.rmempty = true;
	},

	_addWanFields: function(s) {
		var self = this;
		var side = (this._mode === 'siderouter');
		var o;

		o = s.taboption('wansetup', widgets.DeviceSelect, 'wan_interface', _('WAN device'),
			_('Physical network port used for the internet connection.'));
		o.default = this._wanFace || '';
		o.nobridges = false;
		o.rmempty = false;
		o.validate = function(section_id, value) {
			if (!value || !self._boardPorts || !self._boardPorts.length)
				return true;

			if (!/^eth[0-9]+$/.test(value) && !/^en[op][0-9]/.test(value))
				return true;

			for (var i = 0; i < self._boardPorts.length; i++)
				if (self._boardPorts[i] === value)
					return true;

			return _('This is the switch CPU port, not a physical network port.');
		};
		o.depends('wan_proto', 'pppoe');
		o.depends('wan_proto', 'dhcp');

		o = s.taboption('wansetup', form.Value, 'wan_pppoe_user', _('PPPoE username'));
		o.rmempty = false;
		o.depends('wan_proto', 'pppoe');

		o = s.taboption('wansetup', form.Value, 'wan_pppoe_pass', _('PPPoE password'));
		o.password = true;
		o.rmempty = false;
		o.depends('wan_proto', 'pppoe');

		o = s.taboption('wansetup', form.ListValue, 'dhcp_proto', _('WAN address mode'),
			_('Choose how the WAN interface obtains its address.'));
		o.default = 'dhcp';
		o.value('static', _('Static IPv4 address'));
		o.value('dhcp', _('DHCP client'));
		o.rmempty = false;
		o.depends('wan_proto', 'dhcp');

		o = s.taboption('wansetup', form.Value, 'wan_ipaddr', _('WAN IPv4 address'));
		o.datatype = 'ip4addr';
		o.rmempty = false;
		o.depends({ 'wan_proto': 'dhcp', 'dhcp_proto': 'static' });

		o = s.taboption('wansetup', form.Value, 'wan_netmask', _('WAN IPv4 netmask'));
		o.default = '255.255.255.0';
		o.datatype = 'ip4addr';
		o.value('255.255.255.0');
		o.value('255.255.0.0');
		o.value('255.0.0.0');
		o.rmempty = false;
		o.depends({ 'wan_proto': 'dhcp', 'dhcp_proto': 'static' });

		o = s.taboption('wansetup', form.Value, 'wan_gateway', _('WAN IPv4 gateway'));
		o.datatype = 'ip4addr';
		o.rmempty = false;
		o.depends({ 'wan_proto': 'dhcp', 'dhcp_proto': 'static' });

		o = s.taboption('wansetup', form.DynamicList, 'wan_dns', _('Custom DNS servers'),
			_('Leave empty to obtain DNS servers automatically.'));
		o.datatype = 'ip4addr';
		o.depends('wan_proto', 'pppoe');
		o.depends('wan_proto', 'dhcp');

		o = s.taboption('wansetup', form.ListValue, 'lan_proto', _('LAN address mode'),
			_('DHCP client mode takes the LAN address from the upstream router. Check the upstream lease table to find the new address.'));
		o.default = 'static';
		o.value('static', _('Static IPv4 address'));
		o.value('dhcp', _('DHCP client (assigned upstream)'));
		o.depends('wan_proto', 'siderouter');
		o.rmempty = false;

		o = s.taboption('wansetup', form.Value, 'lan_ipaddr', _('LAN IPv4 address'),
			_('The management address of this router. Choose an address outside the upstream DHCP pool.'));
		o.default = this._lanIp || '192.168.1.1';
		o.datatype = 'ip4addr';
		o.rmempty = false;
		o.depends({ 'wan_proto': 'siderouter', 'lan_proto': 'static' });
		o.depends('wan_proto', 'pppoe');
		o.depends('wan_proto', 'dhcp');
		if (!side)
			this._useLiveLan(o, 'lan_ipaddr');

		o = s.taboption('wansetup', form.Value, 'lan_netmask', _('LAN IPv4 netmask'));
		o.default = uci.get('smartnetpilot', 'default', 'lan_netmask') || '255.255.255.0';
		o.datatype = 'ip4addr';
		o.value('255.255.255.0');
		o.value('255.255.0.0');
		o.value('255.0.0.0');
		o.rmempty = false;
		o.depends({ 'wan_proto': 'siderouter', 'lan_proto': 'static' });
		o.depends('wan_proto', 'pppoe');
		o.depends('wan_proto', 'dhcp');
		if (!side)
			this._useLiveLan(o, 'lan_netmask');

		o = s.taboption('wansetup', form.Value, 'lan_gateway', _('LAN IPv4 gateway'),
			side
				? _('Side router only: enter the address of the main router. It must be in the same subnet as this router.')
				: _('Optional. It must be in the same subnet as the LAN address above. Only set it when the LAN needs an explicit gateway.'));
		o.datatype = 'ip4addr';
		o.rmempty = false;
		o.depends({ 'wan_proto': 'siderouter', 'lan_proto': 'static' });
		o.depends('wan_proto', 'dhcp');
		if (!side)
			this._useLiveLan(o, 'lan_gateway');

		o = s.taboption('wansetup', form.DynamicList, 'lan_dns', _('LAN DNS servers'),
			_('DNS servers handed to LAN clients. Leave empty to use the defaults.'));
		o.default = '223.5.5.5';
		o.datatype = 'ip4addr';
		o.rmempty = false;
		o.depends('wan_proto', 'siderouter');
		o.depends('wan_proto', 'pppoe');
		o.depends('wan_proto', 'dhcp');
		if (!side)
			this._useLiveLan(o, 'lan_dns');

		o = s.taboption('wansetup', form.Flag, 'ipv6', _('Enable IPv6'),
			_('Configure IPv6 on the WAN and LAN interfaces. Disable it if your ISP does not provide IPv6.'));
		o.default = '0';
		o.rmempty = false;

		o = s.taboption('wansetup', form.Flag, 'lan_dhcp', _('Disable the LAN DHCP server'),
			_('Only one DHCP server should run on a network. Disable this router’s server when the main router already provides one.'));
		o.default = '0';
		o.rmempty = false;

		o = s.taboption('wansetup', form.Flag, 'dnsset', _('Advertise a DNS server to LAN clients'),
			_('Force LAN clients to use the DNS server selected below.'));
		o.default = '0';
		o.rmempty = false;
		o.depends('lan_dhcp', '0');

		o = s.taboption('wansetup', form.ListValue, 'dns_tables', _('DNS server to advertise'));
		o.value('1', _('Use this router’s LAN address'));
		o.value('223.5.5.5', _('Ali DNS: 223.5.5.5'));
		o.value('180.76.76.76', _('Baidu DNS: 180.76.76.76'));
		o.value('114.114.114.114', _('114 DNS: 114.114.114.114'));
		o.value('8.8.8.8', _('Google DNS: 8.8.8.8'));
		o.value('1.1.1.1', _('Cloudflare DNS: 1.1.1.1'));
		o.rmempty = false;
		o.depends('dnsset', '1');

		o = s.taboption('wansetup', form.Flag, 'https', _('Redirect management to HTTPS'),
			_('Generate a local certificate and redirect HTTP requests to HTTPS.'));
		o.default = '0';
		o.rmempty = false;
	},

	_addWirelessFields: function(s) {
		var o = s.taboption('wifisetup', form.Value, 'wifi_ssid', _('Wireless name (SSID)'));
		o.default = this._wifiSsid || '';
		o.datatype = 'maxlength(32)';
		o.placeholder = _('Enter a wireless name');
		o.rmempty = true;

		o = s.taboption('wifisetup', form.Value, 'wifi_key', _('Wireless password'));
		o.default = this._wifiKey || '';
		o.password = true;
		o.datatype = 'wpakey';
		o.placeholder = _('At least 8 characters');
		o.rmempty = true;
	},

	_addOtherFields: function(s) {
		var o = s.taboption('othersetup', form.Flag, 'synflood', _('Enable SYN-flood protection'),
			_('Recommended. Protects the router and LAN clients from SYN-flood attacks.'));
		o.default = '1';
		o.rmempty = false;
	},

	_buildApplyPlan: function() {
		var mode = this._mode || uci.get('smartnetpilot', 'default', 'wan_proto') || 'siderouter';
		var lanProto = uci.get('smartnetpilot', 'default', 'lan_proto') || 'static';
		var lanIp = uci.get('smartnetpilot', 'default', 'lan_ipaddr') || '';
		var https = uci.get('smartnetpilot', 'default', 'https') === '1';
		var ssid = uci.get('smartnetpilot', 'default', 'wifi_ssid') || '';
		var key = uci.get('smartnetpilot', 'default', 'wifi_key') || '';
		var initial = this._initial || {};
		var initialIp = initial.lanIp || window.location.hostname || '';
		var lanMode = (mode === 'siderouter');
		var lanDhcp = lanMode && lanProto === 'dhcp';
		// PPPoE and DHCP pages can change the LAN addressing from the advanced
		// settings, so such a change gets the same confirmation, redirect and
		// rollback window as the side-router page.
		var lanApplies = !lanDhcp && !!lanIp;
		var desiredIp = lanApplies ? lanIp : null;
		var ipChanged = !lanDhcp && desiredIp && initialIp && desiredIp !== initialIp;
		var httpsChanged = https !== !!initial.https;
		var wifiChanged = this._hasWifi &&
			((ssid && ssid !== initial.wifiSsid) || (key && key !== initial.wifiKey));
		var warnings = [];
		var targetIp = null;

		if (ipChanged) {
			targetIp = desiredIp;
			warnings.push(_('The management address will change from %s to %s. The current page will disconnect and then open the new address.').format(initialIp, desiredIp));
		}
		else if (lanDhcp) {
			warnings.push(_('The LAN interface will become a DHCP client. Its new address is assigned by the upstream router, so it cannot be predicted. Find the lease in the upstream router after applying.'));
		}
		else if (httpsChanged) {
			targetIp = initialIp;
			warnings.push(https
				? _('Management access will switch to HTTPS after the configuration is applied.')
				: _('HTTPS redirection will be disabled. Management access will return to HTTP after the configuration is applied.'));
		}

		if (wifiChanged)
			warnings.push(_('The wireless name or password changed. Wireless clients will need to reconnect.'));

		var redirectTarget = null;
		if (targetIp && (ipChanged || httpsChanged))
			redirectTarget = buildOrigin(targetIp, https) + currentScriptPage();

		return {
			ipChanged: !!ipChanged,
			lanDhcp: lanDhcp,
			httpsChanged: httpsChanged,
			wifiChanged: wifiChanged,
			warnings: warnings,
			unchecked: !!(ipChanged || lanDhcp),
			redirectTarget: redirectTarget
		};
	},

	_handleChangeMode: function(ev, target) {
		// Leave clicks that ask the browser to open a new tab or window alone.
		if (ev.button !== 0 || ev.ctrlKey || ev.metaKey || ev.shiftKey || ev.altKey)
			return;

		ev.preventDefault();
		this._discardAndLeave(target);
	},

	// LuCI keeps the edited widget values in the form until they are saved, so
	// re-rendering the form from the saved configuration is what clears them.
	// The full page load that follows resets the in-memory UCI buffer as well.
	_discardAndLeave: function(target) {
		var navigate = function() {
			window.location.href = target;
		};

		var reset = null;

		if (this._map && typeof this._map.reset == 'function') {
			try {
				reset = this._map.reset();
			}
			catch (e) {
				reset = null;
			}
		}

		if (reset && typeof reset.then == 'function')
			reset.then(navigate, navigate);
		else
			navigate();
	},

	_hasPendingChanges: function() {
		return L.resolveDefault(uci.changes(), {}).then(function(changes) {
			if (!changes)
				return false;

			for (var conf in changes)
				if (Object.prototype.hasOwnProperty.call(changes, conf) &&
				    changes[conf] && changes[conf].length)
					return true;

			return false;
		});
	},

	handleSaveApply: function(ev, mode) {
		var self = this;
		var force = (mode == '1');

		this._applying = true;

		return this.handleSave(ev).then(function() {
			var plan = self._buildApplyPlan();

			self._applying = false;

			var run = function(forceApply) {
				return self._applyChanges(plan, forceApply);
			};

			if (force || !plan.warnings.length)
				return run(force);

			return self._confirmApply(plan).then(function(choice) {
				if (choice === 'force')
					return run(true);

				if (choice === 'apply')
					return run(false);

				self._toast(_('Apply cancelled.'), 'error');
			});
		}).catch(function(err) {
			self._applying = false;
			self._toast(_('Configuration could not be saved. %s').format(err && err.message ? err.message : ''), 'error');
			throw err;
		});
	},

	// 两阶段提交的第二阶段：先让设备拍快照并写入 token，再提交配置。
	// 这里刻意绕开 LuCI 自带的 apply_rollback：它的快照只覆盖会话里
	// 暂存的配置，不包含 init 脚本写入的 network/dhcp 等文件。
	_applyChanges: function(plan, force) {
		var self = this;

		return this._hasPendingChanges().then(function(pending) {
			if (!pending) {
				self._toast(_('There are no changes to apply.'), 'info');
				return;
			}

			return L.resolveDefault(callArmApply(force ? 0 : 1, APPLY_TIMEOUT), { success: false }).then(function(res) {
				if (!res || res.success !== true) {
					self._toast(_('Could not prepare the configuration apply. Please try again.'), 'error');
					return;
				}

				var token = res.token || '';

				self._applyBase = {
					ip: self._lanIp || '',
					https: !!self._initialHttps,
					performed: true
				};

				return self._postApply().then(function(status) {
					if (status >= 200 && status < 300) {
						self._afterApply(plan, force, token);
						return;
					}

					self._toast(_('Apply request failed with status %s.').format(status), 'error');

					// Nothing was committed; cancel the rollback we armed. If the
					// device already started applying, keep the rollback and offer
					// the confirmation instead.
					if (token) {
						return L.resolveDefault(callCancelApply(token), { success: false }).then(function(res) {
							if (res && res.success === true)
								return;

							return L.resolveDefault(callApplyStatus(token), null).then(function(state) {
								if (state && state.status === 'pending')
									self._showRollbackModal(state, plan);
							});
						});
					}
				});
			});
		});
	},

	_postApply: function() {
		return request.request(L.url('admin/uci', 'apply_unchecked'), {
			method: 'post',
			query: { sid: L.env.sessionid, token: L.env.token }
		}).then(function(res) {
			return res ? res.status : 0;
		}).catch(function() {
			return 0;
		});
	},

	_afterApply: function(plan, force, token) {
		var self = this;

		if (force) {
			this._toast(_('Configuration applied without confirmation.'), 'success');
			this._scheduleRedirect(plan, 2500);
			return;
		}

		this._awaitApplied(plan, token, 15);
	},

	// ucitrack may run the init script a moment after the commit returns.
	// Poll briefly so the countdown reflects the device state instead of
	// offering confirmation before the apply actually started.
	_awaitApplied: function(plan, token, attempts) {
		var self = this;

		L.resolveDefault(callApplyStatus(token), null).then(function(status) {
			if (status && status.status === 'failed') {
				self._toast(_('The configuration could not be applied.'), 'error');
				return;
			}

			if (status && status.status === 'confirmed') {
				self._toast(_('Configuration confirmed. The new settings are kept.'), 'success');
				self._scheduleRedirect(plan, 2500);
				return;
			}

			if (status && status.status === 'pending') {
				self._showRollbackModal(status, plan);
				// When the management address changed, follow it so the user
				// can confirm from the new address before the countdown ends.
				self._scheduleRedirect(plan, 3000);
				return;
			}

			if (attempts > 0 && (!status || status.status === 'armed' || status.status === 'idle')) {
				window.setTimeout(function() {
					self._awaitApplied(plan, token, attempts - 1);
				}, 400);
				return;
			}

			self._showRollbackModal(status || {
				token: token,
				remaining: APPLY_TIMEOUT,
				timeout: APPLY_TIMEOUT
			}, plan);
		});
	},

	_scheduleRedirect: function(plan, delay) {
		var target = plan ? plan.redirectTarget : null;

		if (!target)
			return;

		try {
			var next = new URL(target, window.location.href);
			if (next.origin === window.location.origin &&
			    next.pathname === window.location.pathname)
				return;
		}
		catch (e) {
			return;
		}

		window.setTimeout(function() {
			window.location.replace(target);
		}, delay);
	},

	_watchArmedApply: function(attempts) {
		var self = this;

		if (!attempts || attempts <= 0)
			return;

		window.setTimeout(function() {
			L.resolveDefault(callApplyStatus(), null).then(function(status) {
				if (!status)
					return;

				if (status.status === 'pending')
					self._showRollbackModal(status);
				else if (status.status === 'armed')
					self._watchArmedApply(attempts - 1);
			});
		}, 1500);
	},

	_showRollbackModal: function(state, plan) {
		var self = this;
		var token = state && state.token ? state.token : '';

		this._rollbackProgressShown = false;
		var timeout = Number(state && state.timeout) || APPLY_TIMEOUT;
		var remaining = Math.max(Number(state && state.remaining) || 0, 0);
		var finished = false;
		var redirect = plan ? plan.redirectTarget : null;

		if (!token)
			return;

		var countdownNode = E('span', { 'class': 'snp-modal-countdown-value' }, String(remaining));
		var hintNode = E('p', { 'class': 'snp-modal-hint' },
			_('If you do not confirm within %d seconds, the previous configuration is restored automatically.').format(timeout));

		var keepButton = E('button', {
			'type': 'button',
			'class': 'snp-btn snp-btn-primary',
			'click': function() {
				confirmNow();
			}
		}, _('Keep configuration'));

		var rollbackButton = E('button', {
			'type': 'button',
			'class': 'snp-btn snp-btn-ghost',
			'click': function() {
				rollbackNow();
			}
		}, _('Roll back now'));

		var stopTimers = function() {
			finished = true;

			if (self._rollbackTickTimer) {
				window.clearInterval(self._rollbackTickTimer);
				self._rollbackTickTimer = null;
			}

			if (self._rollbackPollTimer) {
				window.clearInterval(self._rollbackPollTimer);
				self._rollbackPollTimer = null;
			}
		};

		var finish = function(message, type) {
			stopTimers();
			self._closeModal();

			if (message)
				self._toast(message, type);
		};

		var confirmNow = function() {
			if (finished)
				return;

			keepButton.disabled = true;
			rollbackButton.disabled = true;
			hintNode.textContent = _('Saving confirmation…');

			L.resolveDefault(callConfirmApply(token), { success: false }).then(function(res) {
				if (res && res.success === true) {
					finish(_('Configuration confirmed. The new settings are kept.'), 'success');
					self._scheduleRedirect(plan, 2500);
					return;
				}

				keepButton.disabled = false;
				rollbackButton.disabled = false;
				hintNode.textContent = _('The device did not confirm the configuration. Please try again.');
			});
		};

		var rollbackNow = function() {
			if (finished)
				return;

			keepButton.disabled = true;
			rollbackButton.disabled = true;
			hintNode.textContent = _('Restoring the previous configuration…');

			// The reply may never arrive when the address changes; the device
			// performs the rollback either way, so show the progress screen.
			L.resolveDefault(callRollbackApply(token), { success: false }).then(function() {
				self._showRollbackProgress();
			});
		};

		var tick = function() {
			remaining = Math.max(remaining - 1, 0);
			countdownNode.textContent = String(remaining);

			if (remaining === 0)
				hintNode.textContent = _('Restoring the previous configuration…');
		};

		var poll = function() {
			L.resolveDefault(callApplyStatus(token), null).then(function(status) {
				if (finished || !status)
					return;

				if (status.status === 'confirmed') {
					finish(_('Configuration confirmed. The new settings are kept.'), 'success');
				}
				else if (status.status === 'rolledback' || status.status === 'rollingback') {
					stopTimers();
					self._closeModal();
					self._showRollbackProgress();
				}
				else if (status.status === 'failed') {
					finish(_('The configuration could not be applied.'), 'error');
				}
				else if (status.status === 'idle') {
					finish(null, null);
				}
				else if (status.status === 'pending') {
					remaining = Math.max(Number(status.remaining) || 0, 0);
					timeout = Number(status.timeout) || timeout;
					countdownNode.textContent = String(remaining);
				}
			});
		};

		var body = [
			E('p', {}, _('The new settings were applied. Keep them, or the previous configuration will be restored automatically.')),
			E('div', { 'class': 'snp-modal-countdown' }, [
				E('span', { 'class': 'snp-modal-countdown-label' }, _('Rollback in')),
				countdownNode,
				E('span', { 'class': 'snp-modal-countdown-unit' }, _('s'))
			]),
			hintNode
		];

		if (redirect)
			body.push(E('p', {}, _('New management address: %s').format(redirect)));

		this._showModal({
			title: _('Confirm the new configuration'),
			icon: 'alert',
			iconClass: 'is-warning',
			body: body,
			actions: [ rollbackButton, keepButton ],
			dismissible: false
		});

		this._rollbackTickTimer = window.setInterval(tick, 1000);
		this._rollbackPollTimer = window.setInterval(poll, 3000);
	},

	_showRollbackProgress: function() {
		if (this._rollbackProgressShown)
			return;

		this._rollbackProgressShown = true;

		var self = this;
		var base = this._applyBase;
		var oldOrigin = base && base.performed && base.ip ? buildOrigin(base.ip, base.https) : null;
		var target = oldOrigin ? oldOrigin + L.url('admin/network/smartnetpilot') : null;
		var actions = [];

		if (this._rollbackTickTimer) {
			window.clearInterval(this._rollbackTickTimer);
			this._rollbackTickTimer = null;
		}

		if (this._rollbackPollTimer) {
			window.clearInterval(this._rollbackPollTimer);
			this._rollbackPollTimer = null;
		}

		if (target) {
			actions.push(E('button', {
				'type': 'button',
				'class': 'snp-btn snp-btn-ghost',
				'click': function() {
					window.location.replace(target);
				}
			}, _('Reconnect to the previous address')));
		}

		actions.push(E('button', {
			'type': 'button',
			'class': 'snp-btn snp-btn-primary',
			'click': function() {
				self._closeModal();
			}
		}, _('Close')));

		this._showModal({
			title: _('Restoring the previous configuration'),
			icon: 'refresh',
			body: [
				E('p', {}, _('The previous network settings are being restored. The connection will be interrupted; reconnect to the router once it is done.')),
				oldOrigin ? E('p', {}, _('Previous management address: %s').format(oldOrigin)) : E('span')
			],
			actions: actions,
			dismissible: false
		});
	},

	_confirmApply: function(plan) {
		var self = this;

		return new Promise(function(resolve) {
			var cancelButton = E('button', {
				'type': 'button',
				'class': 'snp-btn snp-btn-ghost',
				'click': function() {
					self._closeModal();
					resolve(false);
				}
			}, _('Cancel'));

			var forceButton = E('button', {
				'type': 'button',
				'class': 'snp-btn snp-btn-ghost',
				'click': function() {
					self._closeModal();
					resolve('force');
				}
			}, _('Apply without confirmation'));

			var acceptButton = E('button', {
				'type': 'button',
				'class': 'snp-btn snp-btn-primary',
				'click': function() {
					self._closeModal();
					resolve('apply');
				}
			}, plan.lanDhcp ? _('Apply and disconnect') : _('Continue and apply'));

			var notes = E('div', { 'class': 'snp-modal-note' }, [
				E('strong', {}, _('What will happen')),
				E('ul', {}, plan.warnings.map(function(warning) {
					return E('li', {}, warning);
				}))
			]);

			self._showModal({
				title: _('Review before applying'),
				icon: 'alert',
				iconClass: 'is-warning',
				body: [
					E('p', {}, _('These changes affect how you reach this device. Review them before continuing.')),
					notes,
					plan.redirectTarget
						? E('div', {}, [
							E('p', {}, _('New management address')),
							E('span', { 'class': 'snp-modal-address' }, plan.redirectTarget)
						])
						: E('span'),
					E('p', { 'class': 'snp-modal-hint' }, _('“Apply without confirmation” skips the automatic rollback. If the new address is wrong, the device may become unreachable.'))
				],
				actions: [ cancelButton, forceButton, acceptButton ],
				dismissible: true,
				onDismiss: function() {
					resolve(false);
				}
			});

			window.setTimeout(function() {
				if (acceptButton.parentNode)
					acceptButton.focus();
			}, 30);
		});
	},

	_showModal: function(options) {
		this._closeModal();

		var self = this;
		var backdrop = E('div', {
			'class': 'snp-modal-backdrop',
			'role': 'presentation'
		}, [
			E('div', {
				'class': 'snp-modal',
				'role': 'dialog',
				'aria-modal': 'true',
				'aria-label': options.title || ''
			}, [
				E('div', { 'class': 'snp-modal-icon ' + (options.iconClass || '') }, icon(options.icon || 'info')),
				E('h2', {}, options.title || ''),
				E('div', {}, options.body || []),
				E('div', { 'class': 'snp-modal-actions' }, options.actions || [])
			])
		]);

		if (options.dismissible) {
			backdrop.addEventListener('click', function(ev) {
				if (ev.target === backdrop) {
					self._closeModal();
					if (options.onDismiss)
						options.onDismiss();
				}
			});
		}

		this._modalKeyHandler = function(ev) {
			if (ev.key === 'Escape' && options.dismissible) {
				self._closeModal();
				if (options.onDismiss)
					options.onDismiss();
			}
		};

		document.addEventListener('keydown', this._modalKeyHandler);
		this._modalNode = backdrop;
		document.documentElement.style.overflow = 'hidden';
		this._root.appendChild(backdrop);
	},

	_closeModal: function() {
		if (this._rollbackTickTimer) {
			window.clearInterval(this._rollbackTickTimer);
			this._rollbackTickTimer = null;
		}

		if (this._rollbackPollTimer) {
			window.clearInterval(this._rollbackPollTimer);
			this._rollbackPollTimer = null;
		}

		if (this._modalKeyHandler) {
			document.removeEventListener('keydown', this._modalKeyHandler);
			this._modalKeyHandler = null;
		}

		if (this._modalNode && this._modalNode.parentNode)
			this._modalNode.parentNode.removeChild(this._modalNode);

		this._modalNode = null;
		document.documentElement.style.overflow = '';
	},

	_toast: function(message, type) {
		var root = this._root;
		if (!root)
			return;

		var toast = E('div', { 'class': 'snp-toast' + (type === 'error' ? ' is-error' : type === 'success' ? ' is-success' : '') }, [
			icon(type === 'error' ? 'alert' : 'check'),
			E('span', {}, message)
		]);

		root.appendChild(toast);

		window.setTimeout(function() {
			if (toast.parentNode)
				toast.parentNode.removeChild(toast);
		}, 4500);
	},

	addFooter: function() {
		if (!this._mode)
			return E([]);

		return view.prototype.addFooter.call(this);
	},

	_currentTab: function() {
		var root = this._root;
		var item = root ? root.querySelector('.cbi-tabmenu li.cbi-tab') : null;

		return item ? item.getAttribute('data-tab') : null;
	},

	handleSave: function(ev) {
		var self = this;
		var activeTab = this._currentTab();

		return view.prototype.handleSave.call(this, ev).then(function(result) {
			if (self._mode && self._root) {
				self._decorateForm(self._root);
				self._activateTab(self._root, activeTab || 'wansetup');
				self._syncHeroTabs(self._root);
			}

			if (!self._applying)
				self._toast(_('Configuration saved. Use “Save & Apply” to make it active.'), 'success');

			return result;
		}, function(err) {
			if (self._root)
				self._showFirstErrorTab(self._root);

			throw err;
		});
	},

	handleReset: function(ev) {
		if (this._modalNode)
			this._closeModal();

		return view.prototype.handleReset.call(this, ev);
	}
});
