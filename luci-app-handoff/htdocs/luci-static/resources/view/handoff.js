'use strict';
'require view';
'require form';
'require uci';
'require fs';
'require poll';
'require dom';
'require ui';
'require network';
'require tools.widgets as widgets';

var DEFAULT_GEOIP_URL = 'https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@meta/geo/geoip/{}.list';
var RE_PROBE = /^https?:\/\/(25[0-5]|2[0-4]\d|1?\d?\d)(\.(25[0-5]|2[0-4]\d|1?\d?\d)){3}(?::(\d{1,5}))?(\/[^\s]*)?$/;
var RE_CAT = /^[a-z0-9_]{1,40}$/;

var CSS = [
	'.ho-status{display:flex;align-items:center;justify-content:space-between;gap:12px;padding:10px 12px;margin-bottom:12px;border:1px solid rgba(127,127,127,.28);border-left:3px solid #2e8b57;border-radius:3px;background:rgba(127,127,127,.04)}',
	'.ho-status.ho-warn-box{border-left-color:#d48806}',
	'.ho-status.ho-err-box{border-left-color:#c43c35}',
	'.ho-status.ho-off-box{border-left-color:rgba(127,127,127,.5)}',
	'.ho-status-items{display:flex;flex-direction:column;gap:4px;min-width:0;flex:1}',
	'.ho-status-actions{flex-shrink:0}',
	'.ho-row{display:flex;align-items:center;gap:6px;line-height:1.5;flex-wrap:wrap}',
	'.ho-dot{width:8px;height:8px;border-radius:50%;flex-shrink:0;display:inline-block}',
	'.ho-dot.ok{background:#2e8b57;box-shadow:0 0 0 2px rgba(46,139,87,.18)}',
	'.ho-dot.err{background:#c43c35;box-shadow:0 0 0 2px rgba(196,60,53,.18)}',
	'.ho-dot.warn{background:#d48806;box-shadow:0 0 0 2px rgba(212,136,6,.18)}',
	'.ho-dot.info{background:#0069d6;box-shadow:0 0 0 2px rgba(0,105,214,.16)}',
	'.ho-dot.off{background:#888}',
	'.ho-mono{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:.92em;padding:0 5px;margin:0 4px;border-radius:3px;border:1px solid rgba(127,127,127,.28);background:rgba(127,127,127,.08)}',
	'.ho-mono-plain{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:.95em}',
	'.ho-ok{color:#1f7a44;font-weight:600}',
	'.ho-err{color:#c43c35;font-weight:600}',
	'.ho-warn{color:#b26b00;font-weight:600}',
	'.ho-muted{opacity:.72}',
	'.ho-badge{display:inline-flex;align-items:center;gap:5px;padding:1px 8px;border-radius:10px;font-size:.88em;font-weight:600;line-height:1.5;white-space:nowrap;border:1px solid rgba(127,127,127,.3)}',
	'.ho-badge-dot{width:6px;height:6px;border-radius:50%;flex-shrink:0;background:currentColor}',
	'.ho-badge.ok{color:#1f7a44;border-color:rgba(46,139,87,.45);background:rgba(46,139,87,.12)}',
	'.ho-badge.err{color:#c43c35;border-color:rgba(196,60,53,.45);background:rgba(196,60,53,.12)}',
	'.ho-badge.warn{color:#b26b00;border-color:rgba(212,136,6,.45);background:rgba(212,136,6,.12)}',
	'.ho-badge.off{opacity:.72;background:rgba(127,127,127,.08)}',
	'.ho-tags{display:inline-flex;flex-wrap:wrap;gap:4px;align-items:center}',
	'.ho-tag{display:inline-block;padding:1px 6px;border-radius:3px;font-size:.9em;line-height:1.45;border:1px solid rgba(127,127,127,.3);background:rgba(127,127,127,.08)}',
	'.ho-tag-mono{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}',
	'.ho-tag-group{border-color:rgba(0,105,214,.35);background:rgba(0,105,214,.1);color:#0052ab}',
	'.ho-tag-geoip{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;border-color:rgba(46,139,87,.35);background:rgba(46,139,87,.1);color:#1f5f3b}',
	'.ho-tag-ipgroup{border-color:rgba(124,58,237,.35);background:rgba(124,58,237,.1);color:#6d28d9}',
	'.ho-any{opacity:.68;font-style:italic}',
	'.ho-empty{opacity:.55}',
	'.ho-target-gw{font-weight:600;color:#0052ab}',
	'@media (max-width:600px){.ho-status{flex-direction:column;align-items:flex-start}}',
	'@media (prefers-color-scheme:dark){.ho-ok,.ho-badge.ok{color:#66d98c}.ho-err,.ho-badge.err{color:#ff8a80}.ho-warn,.ho-badge.warn{color:#ffc46b}.ho-tag-group,.ho-target-gw{color:#7cb7ff}.ho-tag-geoip{color:#7ee0a2}.ho-tag-ipgroup{color:#c4b5fd}}',
	'[data-darkmode="true"] .ho-ok,[data-darkmode="true"] .ho-badge.ok{color:#66d98c}',
	'[data-darkmode="true"] .ho-err,[data-darkmode="true"] .ho-badge.err{color:#ff8a80}',
	'[data-darkmode="true"] .ho-warn,[data-darkmode="true"] .ho-badge.warn{color:#ffc46b}',
	'[data-darkmode="true"] .ho-tag-group,[data-darkmode="true"] .ho-target-gw{color:#7cb7ff}',
	'[data-darkmode="true"] .ho-tag-geoip{color:#7ee0a2}',
	'[data-darkmode="true"] .ho-tag-ipgroup{color:#c4b5fd}'
].join('\n');

function injectCSS() {
	if (!document.getElementById('handoff-css'))
		document.head.appendChild(E('style', { 'id': 'handoff-css' }, CSS));
}

function formatTime(ts) {
	if (!ts)
		return '—';
	var d = new Date(Number(ts) * 1000);
	if (isNaN(d.getTime()))
		return '—';
	var pad = function(n) { return n < 10 ? '0' + n : String(n); };
	return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate()) + ' ' +
		pad(d.getHours()) + ':' + pad(d.getMinutes());
}

function notify(msg, type) {
	if (typeof ui.addTimeLimitedNotification === 'function')
		ui.addTimeLimitedNotification(null, E('p', {}, [msg]), 4000, type || 'info');
	else
		ui.addNotification(null, E('p', {}, [msg]), type || 'info');
}

function forEachHint(hints, fn) {
	if (!hints)
		return;
	if (Array.isArray(hints)) {
		hints.forEach(function(item) {
			if (Array.isArray(item) && item[0])
				fn(item[0], item[1]);
		});
	} else if (typeof hints === 'object') {
		Object.keys(hints).sort().forEach(function(key) {
			if (key)
				fn(key, hints[key]);
		});
	}
}

return view.extend({
	lastStatus: null,
	statusBox: null,
	statusItems: null,

	fetchStatus: function() {
		return fs.exec('/usr/sbin/handoff', ['status', '--json']).then(function(res) {
			if (!res || res.code !== 0 || !res.stdout)
				return null;
			try {
				return JSON.parse(res.stdout.trim());
			} catch (e) {
				return null;
			}
		}).catch(function() {
			return null;
		});
	},

	gatewayLabel: function(id, statusGateways) {
		if (Array.isArray(statusGateways)) {
			for (var i = 0; i < statusGateways.length; i++) {
				if (statusGateways[i].id === id)
					return statusGateways[i].name || statusGateways[i].ip || id;
			}
		}
		var sec = uci.get('handoff', id);
		if (sec)
			return sec.name || sec.ip || id;
		return id;
	},

	renderGwBadge: function(st, gwId) {
		if (!st || !st.running)
			return E('span', { 'class': 'ho-badge off' }, [
				E('span', { 'class': 'ho-badge-dot' }),
				_('Not running')
			]);
		var gw = null;
		if (Array.isArray(st.gateways)) {
			for (var i = 0; i < st.gateways.length; i++) {
				if (st.gateways[i].id === gwId) {
					gw = st.gateways[i];
					break;
				}
			}
		}
		if (!gw || gw.up == null)
			return E('span', { 'class': 'ho-empty' }, ['—']);
		if (gw.up === false)
			return E('span', { 'class': 'ho-badge err' }, [
				E('span', { 'class': 'ho-badge-dot' }),
				_('Unreachable')
			]);
		if (gw.ip6 && gw.up6 === false)
			return E('span', { 'class': 'ho-badge warn' }, [
				E('span', { 'class': 'ho-badge-dot' }),
				_('Normal · v6 down')
			]);
		return E('span', { 'class': 'ho-badge ok' }, [
			E('span', { 'class': 'ho-badge-dot' }),
			_('Normal')
		]);
	},

	updateStatusUI: function(st) {
		this.lastStatus = st;

		if (this.statusBox && this.statusItems) {
			var rows = [];
			var gws = (st && Array.isArray(st.gateways)) ? st.gateways : [];
			var geoips = (st && Array.isArray(st.geoip)) ? st.geoip : [];
			var missing = (st && Array.isArray(st.missing)) ? st.missing : [];
			var downCount = 0;
			var warnCount = 0;

			if (!st || !st.running) {
				rows.push(E('div', { 'class': 'ho-row' }, [
					E('span', { 'class': 'ho-dot off' }),
					E('span', { 'class': 'ho-muted' }, [_('Not running')])
				]));
			} else if (!gws.length) {
				rows.push(E('div', { 'class': 'ho-row' }, [
					E('span', { 'class': 'ho-dot ok' }),
					E('span', { 'class': 'ho-ok' }, [_('Running (no gateways configured)')])
				]));
			} else {
				gws.forEach(L.bind(function(gw) {
					var label = gw.name || gw.id || '';
					var dotCls = 'off';
					var parts = [E('strong', {}, [label])];
					if (gw.ip)
						parts.push(E('span', { 'class': 'ho-mono' }, [gw.ip]));
					parts.push(': ');

					if (gw.up === false) {
						downCount++;
						dotCls = 'err';
						var fbText;
						if (!gw.via || gw.via === 'direct')
							fbText = _('Unreachable, new connections go direct');
						else
							fbText = _('Unreachable, falling back to %s').format(this.gatewayLabel(gw.via, gws));
						parts.push(E('span', { 'class': 'ho-err' }, [fbText]));
					} else if (gw.up === true) {
						dotCls = 'ok';
						parts.push(E('span', { 'class': 'ho-ok' }, [_('Normal')]));
						if (!gw.ip6) {
							parts.push(E('span', { 'class': 'ho-muted' }, [' · ' + _('IPv6 not set')]));
						} else if (gw.up6 === true) {
							parts.push(E('span', { 'class': 'ho-muted' }, [' · ' + _('IPv6 normal')]));
						} else if (gw.up6 === false) {
							warnCount++;
							dotCls = 'warn';
							parts.push(' · ', E('span', { 'class': 'ho-warn' }, [_('IPv6 unreachable (fallback to IPv4)')]));
						} else {
							parts.push(E('span', { 'class': 'ho-muted' }, [' · ' + _('IPv6 checking')]));
						}
					} else {
						parts.push(E('span', { 'class': 'ho-muted' }, [_('Checking')]));
					}

					rows.push(E('div', { 'class': 'ho-row' }, [
						E('span', { 'class': 'ho-dot ' + dotCls }),
						E('span', {}, parts)
					]));
				}, this));
			}

			if (geoips.length) {
				geoips.slice().sort(function(a, b) {
					return String(a.cat || '').localeCompare(String(b.cat || ''));
				}).forEach(function(g) {
					rows.push(E('div', { 'class': 'ho-row' }, [
						E('span', { 'class': 'ho-dot info' }),
						E('span', {}, [
							E('span', { 'class': 'ho-muted' }, ['GeoIP']),
							E('span', { 'class': 'ho-mono' }, [String(g.cat || '')]),
							': ',
							E('span', { 'class': 'ho-muted' }, [
								_('%d entries, updated at %s').format(Number(g.count) || 0, formatTime(g.mtime))
							])
						])
					]));
				});
			} else if (!missing.length) {
				rows.push(E('div', { 'class': 'ho-row' }, [
					E('span', { 'class': 'ho-dot info' }),
					E('span', { 'class': 'ho-muted' }, [_('GeoIP: no data downloaded yet')])
				]));
			}

			if (missing.length) {
				warnCount++;
				var missParts = [E('span', { 'class': 'ho-warn' }, [_('Missing GeoIP data:')]), ' '];
				missing.forEach(function(cat) {
					missParts.push(E('span', { 'class': 'ho-mono' }, [String(cat)]));
				});
				rows.push(E('div', { 'class': 'ho-row' }, [
					E('span', { 'class': 'ho-dot warn' }),
					E('span', {}, missParts)
				]));
			}

			dom.content(this.statusItems, rows);

			this.statusBox.classList.remove('ho-warn-box', 'ho-err-box', 'ho-off-box');
			if (!st || !st.running)
				this.statusBox.classList.add('ho-off-box');
			else if (gws.length > 0 && downCount === gws.length)
				this.statusBox.classList.add('ho-err-box');
			else if (downCount > 0 || warnCount > 0)
				this.statusBox.classList.add('ho-warn-box');
		}

		var badges = document.querySelectorAll('.ho-gw-status[data-gw-id]');
		for (var i = 0; i < badges.length; i++) {
			var gwId = badges[i].getAttribute('data-gw-id');
			dom.content(badges[i], this.renderGwBadge(st, gwId));
		}
	},

	refreshStatus: function() {
		return this.fetchStatus().then(L.bind(function(st) {
			this.updateStatusUI(st);
		}, this));
	},

	load: function() {
		return Promise.all([
			uci.load('handoff'),
			this.fetchStatus(),
			network.getHostHints().catch(function() { return null; })
		]);
	},

	render: function(data) {
		injectCSS();

		var self = this;
		var initStatus = data[1];
		var hosts = data[2];
		this.lastStatus = initStatus;

		var m = new form.Map(
			'handoff',
			_('Gateway Routing'),
			_('Routes each new connection by device group and destination (GeoIP category or IP group): matching traffic is sent to a gateway (along with DNS queries from those devices), and everything else goes direct. When a gateway is unreachable, its fallback setting applies.')
		);

		var s, o;

		// ============================================================
		// 1. Basic Settings (NamedSection main)
		// ============================================================
		s = m.section(form.NamedSection, 'main', 'handoff', _('Basic Settings'));
		s.addremove = false;
		s.tab('general', _('General'));
		s.tab('advanced', _('Advanced'));

		o = s.taboption('general', form.Flag, 'enabled', _('Enable'));
		o.default = '0';
		o.rmempty = false;

		o = s.taboption('general', widgets.NetworkSelect, 'lan', _('LAN interface'));
		o.multiple = false;
		o.nocreate = true;
		o.noaliases = true;
		o.default = 'lan';
		o.rmempty = false;

		o = s.taboption('general', form.Value, 'interval', _('Check interval'),
			_('Seconds between gateway health checks (minimum 2).'));
		o.datatype = 'and(uinteger,min(2))';
		o.placeholder = '10';
		o.default = '10';
		o.rmempty = false;

		o = s.taboption('advanced', form.Value, 'url', _('GeoIP download URL'),
			_('{} will be replaced with the category name.'));
		o.placeholder = DEFAULT_GEOIP_URL;
		o.default = DEFAULT_GEOIP_URL;
		o.rmempty = true;
		o.validate = function(section_id, value) {
			if (!value)
				return true;
			if (!/^https?:\/\/[^\s]+$/.test(value))
				return _('Only http:// or https:// URLs are allowed');
			if (value.indexOf('{}') === -1)
				return _('URL must contain {} as the category placeholder');
			return true;
		};

		// ============================================================
		// 2. Gateways (GridSection gateway)
		// ============================================================
		s = m.section(form.GridSection, 'gateway', _('Gateways'),
			_('Other gateways (e.g. side routers) on the LAN. Traffic routed to a gateway and DNS queries from those devices are sent to it; the gateway\'s own traffic is never looped back. Click Edit to configure IPv6 address, DNS port and probe URL. Newly added gateways appear in fallback and rule dropdowns after saving.'));
		s.addremove = true;
		s.anonymous = true;
		s.modaltitle = function(section_id) {
			var name = uci.get('handoff', section_id, 'name');
			return name ? _('Edit gateway: %s').format(name) : _('Edit gateway');
		};

		o = s.option(form.Value, 'name', _('Name'));
		o.placeholder = _('e.g. Side Router');
		o.rmempty = false;

		o = s.option(form.Value, 'ip', _('IPv4 address'));
		o.datatype = 'ip4addr';
		o.placeholder = '192.168.99.3';
		o.rmempty = false;
		o.validate = function(section_id, value) {
			if (!value)
				return _('IPv4 address is required');
			if (value.indexOf('/') >= 0)
				return _('Enter an IPv4 address without prefix length');
			return true;
		};
		o.textvalue = function(section_id) {
			var val = this.cfgvalue(section_id);
			return val ? E('span', { 'class': 'ho-mono-plain' }, [val]) : E('span', { 'class': 'ho-empty' }, ['—']);
		};

		o = s.option(form.Value, 'ip6', _('IPv6 address'),
			_('If left empty, IPv6 connections routed to this gateway will be rejected so devices automatically fall back to IPv4.'));
		o.datatype = 'ip6addr';
		o.placeholder = _('Optional');
		o.modalonly = true;
		o.rmempty = true;
		o.validate = function(section_id, value) {
			if (value && value.indexOf('/') >= 0)
				return _('Enter an IPv6 address without prefix length');
			return true;
		};

		o = s.option(form.Value, 'dns_port', _('DNS port'),
			_('DNS queries from devices routed to this gateway are forwarded to gateway:port. The gateway must use real-IP mode (do not enable fake-ip).'));
		o.datatype = 'port';
		o.placeholder = '53';
		o.default = '53';
		o.modalonly = true;
		o.rmempty = true;
		o.validate = function(section_id, value) {
			if (value && Number(value) === 0)
				return _('Port must be between 1 and 65535');
			return true;
		};

		o = s.option(form.Value, 'probe', _('Probe URL'),
			_('Only accepts an IPv4 literal URL, fetched via this gateway to detect proxy process failures; leave empty to only ping the gateway.'));
		o.placeholder = 'http://1.1.1.1/';
		o.modalonly = true;
		o.rmempty = true;
		o.validate = function(section_id, value) {
			if (!value)
				return true;
			var match = value.match(RE_PROBE);
			if (!match)
				return _('Must be an IPv4 literal URL, e.g. http://1.1.1.1/');
			if (match[4] !== undefined) {
				var p = Number(match[4]);
				if (p < 1 || p > 65535)
					return _('Invalid port in probe URL');
			}
			return true;
		};

		o = s.option(form.ListValue, 'fallback', _('When unreachable'),
			_('Fallback gateway when this gateway is unreachable (switches once; goes direct if the backup is also unreachable). Newly added gateways appear here after saving.'));
		o.default = 'direct';
		o.rmempty = false;
		o.value('direct', _('Direct'));
		uci.sections('handoff', 'gateway').forEach(function(g) {
			o.value(g['.name'], _('Use %s').format(g.name || g.ip || g['.name']));
		});
		o.renderWidget = function(section_id, option_index, cfgvalue) {
			this.keylist = [];
			this.vallist = [];
			this.value('direct', _('Direct'));
			uci.sections('handoff', 'gateway').forEach(L.bind(function(g) {
				if (g['.name'] === section_id)
					return;
				this.value(g['.name'], _('Use %s').format(g.name || g.ip || g['.name']));
			}, this));
			return form.ListValue.prototype.renderWidget.apply(this, arguments);
		};
		o.validate = function(section_id, value) {
			if (value === section_id)
				return _('A gateway cannot fall back to itself');
			return true;
		};
		o.textvalue = function(section_id) {
			var val = this.cfgvalue(section_id) || 'direct';
			if (val === 'direct' || val === section_id)
				return _('Direct');
			var g = uci.get('handoff', val);
			if (!g)
				return E('span', { 'class': 'ho-warn' }, [_('%s (deleted)').format(val)]);
			return E('span', { 'class': 'ho-target-gw' }, [_('Use %s').format(g.name || g.ip || val)]);
		};

		o = s.option(form.DummyValue, '_status', _('Status'));
		o.modalonly = false;
		o.textvalue = function(section_id) {
			return E('span', { 'class': 'ho-gw-status', 'data-gw-id': section_id }, [
				self.renderGwBadge(self.lastStatus, section_id)
			]);
		};

		// ============================================================
		// 3. Device Groups (GridSection group)
		// ============================================================
		s = m.section(form.GridSection, 'group', _('Device Groups'),
			_('Identified by MAC address, which also matches IPv6 privacy addresses; IP addresses or CIDR subnets are also supported.'));
		s.addremove = true;
		s.anonymous = true;
		s.modaltitle = function(section_id) {
			var name = uci.get('handoff', section_id, 'name');
			return name ? _('Edit device group: %s').format(name) : _('Edit device group');
		};

		o = s.option(form.Value, 'name', _('Name'));
		o.placeholder = _('e.g. Kids');
		o.rmempty = false;

		o = s.option(form.DynamicList, 'mac', _('MAC addresses'),
			_('Matches both IPv4 and IPv6 traffic of the device by MAC address.'));
		o.datatype = 'macaddr';
		o.placeholder = 'AA:BB:CC:11:22:33';
		o.rmempty = true;
		if (hosts && typeof hosts.getMACHints === 'function') {
			forEachHint(hosts.getMACHints(false), function(mac, label) {
				o.value(mac, label ? '%s (%s)'.format(mac, label) : mac);
			});
		}
		o.textvalue = function(section_id) {
			var vals = L.toArray(this.cfgvalue(section_id)).filter(Boolean);
			if (!vals.length)
				return E('span', { 'class': 'ho-empty' }, ['—']);
			return E('span', { 'class': 'ho-tags' }, vals.map(function(mac) {
				return E('span', { 'class': 'ho-tag ho-tag-mono' }, [mac]);
			}));
		};

		o = s.option(form.DynamicList, 'ip', _('IP / Subnet'),
			_('IPv4 or IPv6 addresses or CIDR subnets, e.g. 192.168.99.50 or 192.168.99.64/28.'));
		o.datatype = 'or(ipaddr,cidr)';
		o.placeholder = '192.168.99.50';
		o.rmempty = true;
		if (hosts && typeof hosts.getIPv4Hints === 'function') {
			forEachHint(hosts.getIPv4Hints(), function(ip, label) {
				o.value(ip, label ? '%s (%s)'.format(ip, label) : ip);
			});
		}
		if (hosts && typeof hosts.getIPv6Hints === 'function') {
			forEachHint(hosts.getIPv6Hints(), function(ip, label) {
				o.value(ip, label ? '%s (%s)'.format(ip, label) : ip);
			});
		}
		o.textvalue = function(section_id) {
			var vals = L.toArray(this.cfgvalue(section_id)).filter(Boolean);
			if (!vals.length)
				return E('span', { 'class': 'ho-empty' }, ['—']);
			return E('span', { 'class': 'ho-tags' }, vals.map(function(ip) {
				return E('span', { 'class': 'ho-tag ho-tag-mono' }, [ip]);
			}));
		};

		// ============================================================
		// 4. Destination IP Groups (GridSection ipgroup)
		// ============================================================
		s = m.section(form.GridSection, 'ipgroup', _('Destination IP Groups'),
			_('Custom destination address lists that can be used alongside GeoIP categories in routing rules, such as corporate subnets, your own VPS, or game servers.'));
		s.addremove = true;
		s.anonymous = true;
		s.modaltitle = function(section_id) {
			var name = uci.get('handoff', section_id, 'name');
			return name ? _('Edit destination IP group: %s').format(name) : _('Edit destination IP group');
		};

		o = s.option(form.Value, 'name', _('Name'));
		o.placeholder = _('e.g. Office');
		o.rmempty = false;

		o = s.option(form.DynamicList, 'ip', _('IP / Subnet'),
			_('IPv4 or IPv6 addresses or CIDR subnets (at least one, can mix IPv4 and IPv6), e.g. 10.20.0.0/16 or 2001:db8:abcd::/48.'));
		o.datatype = 'or(ipaddr,cidr)';
		o.placeholder = '10.20.0.0/16';
		o.rmempty = false;
		o.optional = false;
		o.parse = function(section_id) {
			var uiEl = this.getUIElement(section_id);
			if (uiEl && this.isActive(section_id)) {
				if (!this.isValid(section_id))
					return form.DynamicList.prototype.parse.apply(this, arguments);
				var fval = L.toArray(this.formvalue(section_id)).filter(Boolean);
				var old = uiEl.node.parentNode.querySelector('.ho-ipg-err');
				if (old)
					old.remove();
				if (!fval.length) {
					// 弹窗不会显示 parse 的报错，用户只会觉得「保存」没反应：在输入框下面写明原因
					var msg = _('At least one IP address or subnet is required');
					uiEl.node.parentNode.insertBefore(E('div', { 'class': 'ho-err ho-ipg-err' }, [msg]), uiEl.node.nextSibling);
					return Promise.reject(new TypeError(msg));
				}
			}
			return form.DynamicList.prototype.parse.apply(this, arguments);
		};
		o.textvalue = function(section_id) {
			var vals = L.toArray(this.cfgvalue(section_id)).filter(Boolean);
			if (!vals.length)
				return E('span', { 'class': 'ho-empty' }, ['—']);
			return E('span', { 'class': 'ho-tags' }, vals.map(function(ip) {
				return E('span', { 'class': 'ho-tag ho-tag-mono' }, [ip]);
			}));
		};

		// ============================================================
		// 5. Routing Rules (GridSection rule, sortable)
		// ============================================================
		s = m.section(form.GridSection, 'rule', _('Routing Rules'),
			_('Matched from top to bottom; the first matching rule applies, otherwise traffic goes direct. Private, local and multicast traffic always goes direct. Rule changes only affect new connections. Drag rows to reorder. DNS queries from a device are sent to the gateway specified by the first matching gateway rule for that device. Newly added IP groups appear in routing rule dropdowns after saving.'));
		s.addremove = true;
		s.anonymous = true;
		s.sortable = true;
		s.modaltitle = function(section_id) {
			var name = uci.get('handoff', section_id, 'name');
			return name ? _('Edit routing rule: %s').format(name) : _('Edit routing rule');
		};

		o = s.option(form.Flag, 'enabled', _('Enable'));
		o.default = '1';
		o.rmempty = false;
		o.editable = true;

		o = s.option(form.Value, 'name', _('Name'));
		o.placeholder = _('e.g. Route abroad via gateway');
		o.rmempty = true;

		o = s.option(form.MultiValue, 'group', _('Device groups'),
			_('Leave empty to match all devices. Newly added device groups appear here after saving.'));
		o.placeholder = _('All devices');
		o.rmempty = true;
		uci.sections('handoff', 'group').forEach(function(g) {
			o.value(g['.name'], g.name || g['.name']);
		});
		o.cfgvalue = function(section_id) {
			return L.toArray(uci.get('handoff', section_id, 'group')).filter(Boolean);
		};
		o.write = function(section_id, formvalue) {
			var vals = L.toArray(formvalue).filter(Boolean);
			if (vals.length)
				return uci.set('handoff', section_id, 'group', vals);
			return uci.unset('handoff', section_id, 'group');
		};
		o.renderWidget = function(section_id, option_index, cfgvalue) {
			this.keylist = [];
			this.vallist = [];
			uci.sections('handoff', 'group').forEach(L.bind(function(g) {
				this.value(g['.name'], g.name || g['.name']);
			}, this));
			// 一个选项都没有时 LuCI 的下拉控件会抛错、整个弹窗打不开：改成显示提示
			if (!this.keylist.length)
				return E('em', { 'class': 'ho-empty' }, [_('No device groups yet; add one above and save first.')]);
			return form.MultiValue.prototype.renderWidget.apply(this, arguments);
		};
		o.textvalue = function(section_id) {
			var vals = L.toArray(this.cfgvalue(section_id)).filter(Boolean);
			if (!vals.length)
				return E('span', { 'class': 'ho-any' }, [_('All devices')]);
			return E('span', { 'class': 'ho-tags' }, vals.map(function(gid) {
				var g = uci.get('handoff', gid);
				var label = g ? (g.name || gid) : _('%s (deleted)').format(gid);
				return E('span', { 'class': 'ho-tag ho-tag-group' }, [label]);
			}));
		};

		o = s.option(form.DummyValue, '_destination', _('Destination (GeoIP / IP group)'));
		o.modalonly = false;
		o.textvalue = function(section_id) {
			var geoips = L.toArray(uci.get('handoff', section_id, 'geoip')).filter(Boolean);
			var ipgroups = L.toArray(uci.get('handoff', section_id, 'ipgroup')).filter(Boolean);
			if (!geoips.length && !ipgroups.length)
				return E('span', { 'class': 'ho-any' }, [_('Any destination')]);
			var tags = [];
			geoips.forEach(function(cat) {
				tags.push(E('span', { 'class': 'ho-tag ho-tag-geoip' }, [cat]));
			});
			ipgroups.forEach(function(igid) {
				var ig = uci.get('handoff', igid);
				var label = (ig && ig['.type'] === 'ipgroup') ? (ig.name || igid) : _('%s (deleted)').format(igid);
				tags.push(E('span', { 'class': 'ho-tag ho-tag-ipgroup' }, [label]));
			});
			return E('span', { 'class': 'ho-tags' }, tags);
		};

		o = s.option(form.DynamicList, 'geoip', _('GeoIP categories'),
			_('Leave empty (with no IP groups selected) to match any destination. Lowercase letters, digits and underscores only.'));
		o.modalonly = true;
		o.placeholder = _('Any destination');
		o.rmempty = true;
		[
			['cn', 'cn — ' + _('Mainland China')],
			['private', 'private — ' + _('Private / LAN')],
			['google', 'google'],
			['telegram', 'telegram'],
			['netflix', 'netflix'],
			['facebook', 'facebook'],
			['twitter', 'twitter'],
			['cloudflare', 'cloudflare'],
			['apple', 'apple'],
			['microsoft', 'microsoft'],
			['openai', 'openai'],
			['anthropic', 'anthropic']
		].forEach(function(item) {
			o.value(item[0], item[1]);
		});
		o.validate = function(section_id, value) {
			if (!value || (Array.isArray(value) && !value.length))
				return true;
			var list = Array.isArray(value) ? value : [value];
			for (var i = 0; i < list.length; i++) {
				if (list[i] && !RE_CAT.test(list[i]))
					return _('Use only lowercase letters, digits and underscores (e.g. cn, netflix)');
			}
			return true;
		};

		o = s.option(form.MultiValue, 'ipgroup', _('Destination IP groups'),
			_('Combined with GeoIP categories (matches either). Leave both empty to match any destination. Newly added IP groups appear here after saving.'));
		o.modalonly = true;
		o.placeholder = _('No IP groups selected');
		o.rmempty = true;
		uci.sections('handoff', 'ipgroup').forEach(function(ig) {
			o.value(ig['.name'], ig.name || ig['.name']);
		});
		o.cfgvalue = function(section_id) {
			return L.toArray(uci.get('handoff', section_id, 'ipgroup')).filter(Boolean);
		};
		o.write = function(section_id, formvalue) {
			var vals = L.toArray(formvalue).filter(Boolean);
			if (vals.length)
				return uci.set('handoff', section_id, 'ipgroup', vals);
			return uci.unset('handoff', section_id, 'ipgroup');
		};
		o.renderWidget = function(section_id, option_index, cfgvalue) {
			this.keylist = [];
			this.vallist = [];
			uci.sections('handoff', 'ipgroup').forEach(L.bind(function(ig) {
				this.value(ig['.name'], ig.name || ig['.name']);
			}, this));
			// 一个选项都没有时 LuCI 的下拉控件会抛错、整个弹窗打不开：改成显示提示
			if (!this.keylist.length)
				return E('em', { 'class': 'ho-empty' }, [_('No destination IP groups yet; add one above and save first.')]);
			return form.MultiValue.prototype.renderWidget.apply(this, arguments);
		};

		o = s.option(form.Flag, 'invert', _('Invert'),
			_('Match when the destination is NOT in the selected GeoIP categories and IP groups.'));
		o.default = '0';
		o.rmempty = false;
		o.editable = true;

		o = s.option(form.ListValue, 'target', _('Route to'),
			_('Newly added gateways appear here after saving.'));
		o.default = 'direct';
		o.rmempty = false;
		o.value('direct', _('Direct'));
		uci.sections('handoff', 'gateway').forEach(function(g) {
			o.value(g['.name'], g.name || g.ip || g['.name']);
		});
		o.renderWidget = function(section_id, option_index, cfgvalue) {
			this.keylist = [];
			this.vallist = [];
			this.value('direct', _('Direct'));
			uci.sections('handoff', 'gateway').forEach(L.bind(function(g) {
				this.value(g['.name'], g.name || g.ip || g['.name']);
			}, this));
			return form.ListValue.prototype.renderWidget.apply(this, arguments);
		};
		o.textvalue = function(section_id) {
			var val = this.cfgvalue(section_id) || 'direct';
			if (val === 'direct')
				return _('Direct');
			var g = uci.get('handoff', val);
			if (!g)
				return E('span', { 'class': 'ho-warn' }, [_('%s (deleted)').format(val)]);
			return E('span', { 'class': 'ho-target-gw' }, [g.name || g.ip || val]);
		};

		// Build status box placed at the top of Basic Settings
		this.statusItems = E('div', { 'class': 'ho-status-items' });
		var btnUpdate = E('button', {
			'type': 'button',
			'class': 'cbi-button cbi-button-action',
			'click': function(ev) {
				var btn = ev.currentTarget;
				btn.disabled = true;
				dom.content(btn, [_('Updating...')]);
				fs.exec('/usr/sbin/handoff', ['update']).then(function(res) {
					if (res && res.code === 0) {
						notify(_('GeoIP data updated.'), 'info');
					} else {
						var detail = (res && (res.stderr || res.stdout))
							? (res.stderr || res.stdout).trim()
							: _('exit code %s').format(res ? res.code : '?');
						notify(_('GeoIP update failed: %s').format(detail), 'warning');
					}
					return self.refreshStatus();
				}).catch(function(err) {
					notify(_('GeoIP update failed: %s').format(err && err.message ? err.message : String(err)), 'warning');
				}).finally(function() {
					btn.disabled = false;
					dom.content(btn, [_('Update GeoIP now')]);
				});
			}
		}, [_('Update GeoIP now')]);

		this.statusBox = E('div', { 'class': 'ho-status' }, [
			this.statusItems,
			E('div', { 'class': 'ho-status-actions' }, [btnUpdate])
		]);

		var placeStatus = L.bind(function(mapEl) {
			var firstSec = mapEl.querySelector('.cbi-section');
			if (firstSec) {
				var insertBeforeEl = firstSec.querySelector('.cbi-tabmenu, .cbi-section-node');
				if (insertBeforeEl)
					firstSec.insertBefore(this.statusBox, insertBeforeEl);
				else
					firstSec.appendChild(this.statusBox);
			} else {
				mapEl.insertBefore(this.statusBox, mapEl.firstChild);
			}
			this.updateStatusUI(this.lastStatus);
			return mapEl;
		}, this);

		// 弹窗里点「保存」后 LuCI 会 reset() → renderContents() 重画整张表单，状态框会被冲掉：每次重画后放回去
		var renderContents = m.renderContents;
		m.renderContents = function() {
			return renderContents.apply(this, arguments).then(placeStatus);
		};

		return m.render().then(L.bind(function(mapEl) {
			this.updateStatusUI(initStatus);
			poll.add(L.bind(function() {
				return this.refreshStatus();
			}, this), 5);

			return mapEl;
		}, this));
	}
});
