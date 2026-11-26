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
var RE_MAC = /^([0-9a-f]{2}:){5}[0-9a-f]{2}$/i;

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
	/* Top-level grouping tabs & rule hit counters */
	'.ho-top-tabs{margin:0 0 12px 0 !important}',
	'.ho-tab-hidden{display:none !important}',
	'.ho-hits{display:inline-block;min-width:26px;text-align:center;padding:1px 7px;border-radius:10px;font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:.88em;font-weight:600;border:1px solid rgba(127,127,127,.28);background:rgba(127,127,127,.08)}',
	'.ho-hits.active{color:#0052ab;border-color:rgba(0,105,214,.4);background:rgba(0,105,214,.12)}',
	'.ho-hits.zero{opacity:.6}',
	/* Device multi-select picker */
	'.ho-picker{display:flex;flex-direction:column;gap:8px;max-width:560px}',
	'.ho-picker-bar{display:flex;align-items:center;gap:6px;flex-wrap:wrap}',
	'.ho-picker-search{flex:1;min-width:150px}',
	'.ho-picker-count{font-size:.9em;font-weight:600;padding:2px 8px;border-radius:10px;background:rgba(0,105,214,.12);color:#0052ab;white-space:nowrap}',
	'.ho-picker-list{max-height:240px;overflow-y:auto;border:1px solid rgba(127,127,127,.32);border-radius:4px;background:rgba(127,127,127,.02)}',
	'.ho-dev-item{display:flex;align-items:flex-start;gap:8px;padding:7px 10px;border-bottom:1px solid rgba(127,127,127,.14);cursor:pointer;user-select:none;margin:0}',
	'.ho-dev-item:last-child{border-bottom:none}',
	'.ho-dev-item:hover{background:rgba(0,105,214,.06)}',
	'.ho-dev-item.ho-dev-checked{background:rgba(0,105,214,.1)}',
	'.ho-dev-item input[type="checkbox"]{margin:3px 0 0 0;flex-shrink:0}',
	'.ho-dev-main{display:flex;flex-direction:column;gap:2px;min-width:0;flex:1}',
	'.ho-dev-top{display:flex;align-items:center;gap:6px;flex-wrap:wrap}',
	'.ho-dev-name{font-weight:600;word-break:break-all}',
	'.ho-dev-meta{font-size:.86em;opacity:.78;display:flex;gap:8px;flex-wrap:wrap;font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}',
	'.ho-dev-pill{font-size:.78em;padding:0 5px;border-radius:3px;border:1px solid rgba(127,127,127,.35);opacity:.82}',
	'.ho-dev-pill-warn{border-color:rgba(212,136,6,.45);background:rgba(212,136,6,.1);color:#b26b00;opacity:1}',
	'.ho-picker-empty{padding:14px 10px;text-align:center;opacity:.62;font-size:.92em}',
	'.ho-picker-manual{display:flex;gap:6px;align-items:flex-start}',
	'.ho-picker-manual textarea{flex:1;min-height:42px;resize:vertical;font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:.9em}',
	'.ho-picker-err{color:#c43c35;font-size:.9em;font-weight:600}',
	'@media (max-width:600px){.ho-status{flex-direction:column;align-items:flex-start}}',
	'@media (prefers-color-scheme:dark){.ho-ok,.ho-badge.ok{color:#66d98c}.ho-err,.ho-badge.err,.ho-picker-err{color:#ff8a80}.ho-warn,.ho-badge.warn,.ho-dev-pill-warn{color:#ffc46b}.ho-tag-group,.ho-target-gw,.ho-picker-count,.ho-hits.active{color:#7cb7ff}.ho-tag-geoip{color:#7ee0a2}.ho-tag-ipgroup{color:#c4b5fd}}',
	'[data-darkmode="true"] .ho-ok,[data-darkmode="true"] .ho-badge.ok{color:#66d98c}',
	'[data-darkmode="true"] .ho-err,[data-darkmode="true"] .ho-badge.err,[data-darkmode="true"] .ho-picker-err{color:#ff8a80}',
	'[data-darkmode="true"] .ho-warn,[data-darkmode="true"] .ho-badge.warn,[data-darkmode="true"] .ho-dev-pill-warn{color:#ffc46b}',
	'[data-darkmode="true"] .ho-tag-group,[data-darkmode="true"] .ho-target-gw,[data-darkmode="true"] .ho-picker-count,[data-darkmode="true"] .ho-hits.active{color:#7cb7ff}',
	'[data-darkmode="true"] .ho-tag-geoip{color:#7ee0a2}',
	'[data-darkmode="true"] .ho-tag-ipgroup{color:#c4b5fd}'
].join('\n');

function formatHits(n) {
	var v = Number(n);
	if (!isFinite(v) || v < 0)
		return '0';
	if (v >= 1000000)
		return (v / 1000000).toFixed(1).replace(/\.0$/, '') + 'M';
	if (v >= 10000)
		return (v / 1000).toFixed(1).replace(/\.0$/, '') + 'K';
	return String(Math.floor(v));
}

function bindSectionTab(sec, tabName) {
	var origRender = sec.render;
	sec.render = function() {
		return origRender.apply(this, arguments).then(function(el) {
			if (el)
				el.setAttribute('data-ho-tab', tabName);
			return el;
		});
	};
}

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

function normMac(mac) {
	return String(mac || '').trim().toLowerCase();
}

function buildHostCatalog(hosts) {
	var byMac = {};
	var add = function(mac, name, ip4, ip6) {
		var m = normMac(mac);
		if (!RE_MAC.test(m))
			return;
		if (!byMac[m]) {
			byMac[m] = {
				mac: m,
				displayMac: m.toUpperCase(),
				name: '',
				ip4s: [],
				ip6s: []
			};
		}
		var rec = byMac[m];
		if (name && !rec.name && normMac(name) !== m)
			rec.name = String(name).trim();
		if (ip4 && rec.ip4s.indexOf(ip4) === -1)
			rec.ip4s.push(ip4);
		if (ip6 && rec.ip6s.indexOf(ip6) === -1)
			rec.ip6s.push(ip6);
	};

	if (hosts && hosts.hosts && typeof hosts.hosts === 'object') {
		Object.keys(hosts.hosts).forEach(function(mac) {
			var info = hosts.hosts[mac] || {};
			add(mac, info.name || '', null, null);
			L.toArray(info.ipaddrs).forEach(function(ip) { add(mac, '', ip, null); });
			L.toArray(info.ip6addrs).forEach(function(ip6) { add(mac, '', null, ip6); });
		});
	}
	if (hosts && typeof hosts.getMACHints === 'function') {
		forEachHint(hosts.getMACHints(false), function(mac, label) {
			var ip4 = typeof hosts.getIPAddrByMACAddr === 'function' ? hosts.getIPAddrByMACAddr(mac) : null;
			var ip6 = typeof hosts.getIP6AddrByMACAddr === 'function' ? hosts.getIP6AddrByMACAddr(mac) : null;
			var name = typeof hosts.getHostnameByMACAddr === 'function' ? hosts.getHostnameByMACAddr(mac) : label;
			add(mac, name || label || '', ip4, ip6);
		});
	}

	var list = Object.keys(byMac).map(function(m) { return byMac[m]; });
	list.sort(function(a, b) {
		if (a.name && !b.name) return -1;
		if (!a.name && b.name) return 1;
		var na = (a.name || a.mac).toLowerCase();
		var nb = (b.name || b.mac).toLowerCase();
		return na.localeCompare(nb);
	});
	return { list: list, byMac: byMac };
}

function v6FallbackLabel(fb) {
	if (fb === 'direct')
		return _('direct');
	if (fb === 'blackhole')
		return _('blackhole');
	return _('fallback to IPv4');
}

function splitMacInput(text) {
	var tokens = String(text || '').split(/[\s,;]+/).map(function(s) {
		return s.trim();
	}).filter(Boolean);
	var valid = [];
	var invalid = [];
	tokens.forEach(function(tok) {
		var m = normMac(tok);
		if (RE_MAC.test(m)) {
			if (valid.indexOf(m) === -1)
				valid.push(m);
		} else {
			invalid.push(tok);
		}
	});
	return { valid: valid, invalid: invalid };
}

return view.extend({
	lastStatus: null,
	statusBox: null,
	statusItems: null,
	tabBar: null,
	activeTab: 'gateways',
	mapNode: null,
	hostCatalog: { list: [], byMac: {} },

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
		if (gw.ip6_mode !== 'off' && gw.ip6 && gw.up6 === false)
			return E('span', { 'class': 'ho-badge warn' }, [
				E('span', { 'class': 'ho-badge-dot' }),
				_('Normal · v6 down')
			]);
		return E('span', { 'class': 'ho-badge ok' }, [
			E('span', { 'class': 'ho-badge-dot' }),
			_('Normal')
		]);
	},

	renderRuleHits: function(st, ruleId) {
		if (!st || !st.running || !st.stats || !st.stats.rules ||
			!Object.prototype.hasOwnProperty.call(st.stats.rules, ruleId))
			return E('span', { 'class': 'ho-empty' }, ['—']);
		var n = Number(st.stats.rules[ruleId]) || 0;
		return E('span', {
			'class': 'ho-hits ' + (n > 0 ? 'active' : 'zero'),
			'title': _('%d new connections matched').format(n)
		}, [formatHits(n)]);
	},

	applyTab: function(mapEl, tabName) {
		this.activeTab = tabName || 'gateways';
		if (this.tabBar) {
			var lis = this.tabBar.querySelectorAll('li[data-tab]');
			for (var i = 0; i < lis.length; i++) {
				var active = lis[i].getAttribute('data-tab') === this.activeTab;
				lis[i].classList.toggle('cbi-tab', active);
				lis[i].classList.toggle('cbi-tab-disabled', !active);
			}
		}
		if (mapEl) {
			var secs = mapEl.querySelectorAll('[data-ho-tab]');
			for (var j = 0; j < secs.length; j++) {
				var show = secs[j].getAttribute('data-ho-tab') === this.activeTab;
				secs[j].classList.toggle('ho-tab-hidden', !show);
			}
		}
	},

	updateStatusUI: function(st) {
		this.lastStatus = st;

		if (this.statusBox && this.statusItems) {
			var rows = [];
			var gws = (st && Array.isArray(st.gateways)) ? st.gateways : [];
			var geoips = (st && Array.isArray(st.geoip)) ? st.geoip : [];
			var missing = (st && Array.isArray(st.missing)) ? st.missing : [];
			var stats = (st && st.stats && typeof st.stats === 'object') ? st.stats : null;
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
						var m6 = gw.ip6_mode || (gw.ip6 ? 'manual' : 'auto');
						var fbDesc = v6FallbackLabel(gw.v6_fallback);
						if (m6 === 'off') {
							parts.push(E('span', { 'class': 'ho-muted' }, [' · ' + _('IPv6 disabled (%s)').format(fbDesc)]));
						} else if (!gw.ip6) {
							var noV6Msg = (m6 === 'auto')
								? _('IPv6 not discovered (%s)').format(fbDesc)
								: _('IPv6 not set (%s)').format(fbDesc);
							parts.push(E('span', { 'class': 'ho-muted' }, [' · ' + noV6Msg]));
						} else if (gw.up6 === true) {
							var srcTag = (m6 === 'auto') ? _('auto') : _('manual');
							parts.push(' · ', E('span', { 'class': 'ho-muted' }, [_('IPv6 normal (%s)').format(srcTag)]),
								E('span', { 'class': 'ho-mono' }, [gw.ip6]));
						} else if (gw.up6 === false) {
							warnCount++;
							dotCls = 'warn';
							parts.push(' · ', E('span', { 'class': 'ho-warn' }, [_('IPv6 unreachable (%s)').format(fbDesc)]));
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

			if (st && st.running && stats) {
				var matchedN = Number(stats.matched) || 0;
				var defaultN = Number(stats.default) || 0;
				var activeRules = stats.rules ? Object.keys(stats.rules).length : 0;
				rows.push(E('div', { 'class': 'ho-row' }, [
					E('span', { 'class': 'ho-dot info' }),
					E('span', {}, [
						E('span', { 'class': 'ho-muted' }, [_('Rule hits:')]),
						E('span', { 'class': 'ho-mono', 'title': _('%d new connections matched').format(matchedN) }, [formatHits(matchedN)]),
						E('span', { 'class': 'ho-muted' }, [_('matched (%d active rules)').format(activeRules) + ' · ' + _('Default direct:')]),
						E('span', { 'class': 'ho-mono', 'title': _('%d new connections fell through to direct').format(defaultN) }, [formatHits(defaultN)])
					])
				]));
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

		var hitEls = document.querySelectorAll('.ho-rule-hits[data-rule-id]');
		for (var j = 0; j < hitEls.length; j++) {
			var ruleId = hitEls[j].getAttribute('data-rule-id');
			dom.content(hitEls[j], this.renderRuleHits(st, ruleId));
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
		this.hostCatalog = buildHostCatalog(hosts);

		var m = new form.Map(
			'handoff',
			_('Gateway Routing'),
			_('Routes each new connection by device group and destination (GeoIP category or IP group): matching traffic is sent to a gateway (along with DNS queries from those devices), and everything else goes direct. When a gateway is unreachable, its fallback setting applies.')
		);

		var s, o;

		// ============================================================
		// Tab 1 (Gateways): Enable switch + Gateways GridSection
		// ============================================================
		s = m.section(form.NamedSection, 'main', 'handoff', _('Service'));
		s.addremove = false;
		bindSectionTab(s, 'gateways');

		o = s.option(form.Flag, 'enabled', _('Enable'));
		o.default = '0';
		o.rmempty = false;

		s = m.section(form.GridSection, 'gateway', _('Gateways'),
			_('Other gateways (e.g. side routers) on the LAN. Traffic routed to a gateway and DNS queries from those devices are sent to it; the gateway\'s own traffic is never looped back. IPv6 is auto-discovered by MAC by default; click Edit to customize IPv6 mode, fallback behavior, DNS port, and probe URL.'));
		s.addremove = true;
		s.anonymous = true;
		bindSectionTab(s, 'gateways');
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

		o = s.option(form.ListValue, 'ip6_mode', _('IPv6 mode'),
			_('Auto-discover matches the gateway\'s IPv6 address by its MAC and tracks prefix changes automatically (only on-link ULA/GUA matching the LAN /64 prefix are accepted).'));
		o.value('auto', _('Auto-discover (by MAC)'));
		o.value('manual', _('Manual'));
		o.value('off', _('Disabled'));
		o.default = 'auto';
		o.modalonly = true;
		o.rmempty = false;
		o.cfgvalue = function(section_id) {
			var mode = uci.get('handoff', section_id, 'ip6_mode');
			if (mode === 'auto' || mode === 'manual' || mode === 'off')
				return mode;
			var ip6 = uci.get('handoff', section_id, 'ip6');
			return ip6 ? 'manual' : 'auto';
		};

		o = s.option(form.ListValue, 'ip6_prefer', _('IPv6 priority'),
			_('Address preference when auto-discovering: ULA and link-local (fe80::) stay stable across ISP prefix changes; when fe80:: is used, IPv6 DNS falls back to gateway IPv4 DNS.'));
		o.value('ula_lla_gua', _('ULA > Link-local (fe80::) > GUA (Recommended)'));
		o.value('lla_ula_gua', _('Link-local (fe80::) > ULA > GUA'));
		o.value('gua_ula_lla', _('GUA > ULA > Link-local (fe80::)'));
		o.default = 'ula_lla_gua';
		o.modalonly = true;
		o.rmempty = false;
		o.depends('ip6_mode', 'auto');

		o = s.option(form.Value, 'ip6', _('IPv6 address'),
			_('Static IPv6 address of this gateway (without prefix length).'));
		o.datatype = 'ip6addr';
		o.placeholder = '2001:db8::3';
		o.modalonly = true;
		o.rmempty = true;
		o.depends('ip6_mode', 'manual');
		if (hosts && typeof hosts.getIPv6Hints === 'function') {
			forEachHint(hosts.getIPv6Hints(), function(ip6, label) {
				o.value(ip6, label ? '%s (%s)'.format(ip6, label) : ip6);
			});
		}
		o.validate = function(section_id, value) {
			if (value && value.indexOf('/') >= 0)
				return _('Enter an IPv6 address without prefix length');
			return true;
		};

		o = s.option(form.ListValue, 'v6_fallback', _('When IPv6 is unavailable'),
			_('Action for routed IPv6 connections when IPv6 is disabled, not discovered, or unreachable. DNS queries still go to this gateway via IPv4.'));
		o.value('reject', _('Reject (fall back to IPv4)'));
		o.value('direct', _('Direct'));
		o.value('blackhole', _('Blackhole (drop silently)'));
		o.default = 'reject';
		o.modalonly = true;
		o.rmempty = false;

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
			_('Fallback gateway when this gateway is unreachable (switches once; goes direct if the backup is also unreachable).'));
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
		// Tab 3 (Devices & IP Groups): Device Groups (GridSection group)
		// ============================================================
		s = m.section(form.GridSection, 'group', _('Device Groups'),
			_('Identified by MAC address, which also matches IPv6 privacy addresses; click Edit to batch-select multiple LAN devices at once. IP addresses or CIDR subnets are also supported.'));
		s.addremove = true;
		s.anonymous = true;
		bindSectionTab(s, 'groups');
		s.modaltitle = function(section_id) {
			var name = uci.get('handoff', section_id, 'name');
			return name ? _('Edit device group: %s').format(name) : _('Edit device group');
		};

		o = s.option(form.Value, 'name', _('Name'));
		o.placeholder = _('e.g. Kids');
		o.rmempty = false;

		o = s.option(form.Value, 'mac', _('Devices (MAC)'),
			_('Check multiple LAN devices at once, or paste MAC addresses for offline devices below.'));
		o.rmempty = true;
		o.cfgvalue = function(section_id) {
			return L.toArray(uci.get('handoff', section_id, 'mac')).filter(Boolean).map(normMac);
		};
		o.renderWidget = function(section_id, option_index, cfgvalue) {
			var widgetId = this.cbid(section_id);
			var selectedSet = {};
			L.toArray(cfgvalue).filter(Boolean).forEach(function(m) {
				var nm = normMac(m);
				if (RE_MAC.test(nm))
					selectedSet[nm] = true;
			});

			// Record which MACs belong to other device groups so user sees overlaps clearly
			var otherGroupMap = {};
			uci.sections('handoff', 'group').forEach(function(g) {
				if (g['.name'] === section_id)
					return;
				var gname = g.name || g['.name'];
				L.toArray(g.mac).forEach(function(m) {
					var nm = normMac(m);
					if (!nm)
						return;
					if (!otherGroupMap[nm])
						otherGroupMap[nm] = [];
					if (otherGroupMap[nm].indexOf(gname) === -1)
						otherGroupMap[nm].push(gname);
				});
			});

			// Build merged list: discovered LAN hosts + already-selected offline MACs
			var items = self.hostCatalog.list.map(function(h) {
				return {
					mac: h.mac,
					displayMac: h.displayMac,
					name: h.name,
					ip4s: h.ip4s,
					ip6s: h.ip6s,
					offline: false
				};
			});
			var knownMap = {};
			items.forEach(function(it) { knownMap[it.mac] = true; });
			Object.keys(selectedSet).sort().forEach(function(m) {
				if (!knownMap[m]) {
					items.push({
						mac: m,
						displayMac: m.toUpperCase(),
						name: '',
						ip4s: [],
						ip6s: [],
						offline: true
					});
					knownMap[m] = true;
				}
			});

			var searchInput = E('input', {
				'type': 'text',
				'class': 'cbi-input-text ho-picker-search',
				'placeholder': _('Filter by hostname, IP or MAC...')
			});
			var countBadge = E('span', { 'class': 'ho-picker-count' });
			var listBox = E('div', { 'class': 'ho-picker-list' });
			var manualBox = E('textarea', {
				'class': 'cbi-input-textarea',
				'rows': 2,
				'placeholder': _('Batch add offline MACs (separated by space, comma or newline)')
			});
			var errBox = E('div', { 'class': 'ho-picker-err', 'style': 'display:none' });

			var setErr = function(msg) {
				if (msg) {
					dom.content(errBox, [msg]);
					errBox.style.display = '';
				} else {
					dom.content(errBox, []);
					errBox.style.display = 'none';
				}
			};

			var updateCount = function() {
				var n = Object.keys(selectedSet).filter(function(k) { return selectedSet[k]; }).length;
				dom.content(countBadge, [_('%d selected').format(n)]);
			};

			var matchesFilter = function(it, q) {
				if (!q)
					return true;
				var hay = [it.name, it.mac, it.ip4s.join(' '), it.ip6s.join(' ')].join(' ').toLowerCase();
				return hay.indexOf(q) !== -1;
			};

			var renderList = function() {
				var q = String(searchInput.value || '').trim().toLowerCase();
				var filtered = items.filter(function(it) { return matchesFilter(it, q); });
				// Show selected items first when not searching so user sees current group members immediately
				if (!q) {
					filtered.sort(function(a, b) {
						var sa = selectedSet[a.mac] ? 1 : 0;
						var sb = selectedSet[b.mac] ? 1 : 0;
						if (sa !== sb) return sb - sa;
						if (a.offline !== b.offline) return a.offline ? 1 : -1;
						if (a.name && !b.name) return -1;
						if (!a.name && b.name) return 1;
						return (a.name || a.mac).toLowerCase().localeCompare((b.name || b.mac).toLowerCase());
					});
				}
				if (!filtered.length) {
					dom.content(listBox, [E('div', { 'class': 'ho-picker-empty' }, [
						items.length ? _('No matching devices') : _('No LAN devices discovered yet; paste MAC addresses below.')
					])]);
					updateCount();
					return;
				}
				var nodes = filtered.map(function(it) {
					var checked = !!selectedSet[it.mac];
					var cb = E('input', {
						'type': 'checkbox',
						'value': it.mac,
						'checked': checked ? 'checked' : null
					});
					var rowEl = E('label', { 'class': 'ho-dev-item' + (checked ? ' ho-dev-checked' : '') });
					cb.addEventListener('change', function() {
						if (cb.checked) {
							selectedSet[it.mac] = true;
							rowEl.classList.add('ho-dev-checked');
						} else {
							delete selectedSet[it.mac];
							rowEl.classList.remove('ho-dev-checked');
						}
						updateCount();
					});

					var topParts = [
						E('span', { 'class': 'ho-dev-name' }, [it.name || _('Unnamed device')])
					];
					if (it.offline)
						topParts.push(E('span', { 'class': 'ho-dev-pill' }, [_('Offline / Manual')]));
					if (otherGroupMap[it.mac])
						topParts.push(E('span', { 'class': 'ho-dev-pill ho-dev-pill-warn' }, [
							_('In: %s').format(otherGroupMap[it.mac].join(', '))
						]));

					var metaParts = [E('span', {}, [it.displayMac])];
					if (it.ip4s.length)
						metaParts.push(E('span', {}, [it.ip4s.join(', ')]));
					if (it.ip6s.length)
						metaParts.push(E('span', {}, [it.ip6s[0]]));

					rowEl.appendChild(cb);
					rowEl.appendChild(E('span', { 'class': 'ho-dev-main' }, [
						E('span', { 'class': 'ho-dev-top' }, topParts),
						E('span', { 'class': 'ho-dev-meta' }, metaParts)
					]));
					return rowEl;
				});
				dom.content(listBox, nodes);
				updateCount();
			};

			var addManualMacs = function() {
				var parsed = splitMacInput(manualBox.value);
				parsed.valid.forEach(function(m) {
					selectedSet[m] = true;
					if (!knownMap[m]) {
						items.push({
							mac: m,
							displayMac: m.toUpperCase(),
							name: '',
							ip4s: [],
							ip6s: [],
							offline: true
						});
						knownMap[m] = true;
					}
				});
				if (parsed.invalid.length) {
					manualBox.value = parsed.invalid.join('\n');
					setErr(_('Invalid MAC address: %s').format(parsed.invalid.join(', ')));
				} else {
					manualBox.value = '';
					setErr('');
				}
				renderList();
			};

			searchInput.addEventListener('input', renderList);

			var btnSelectAll = E('button', {
				'type': 'button',
				'class': 'cbi-button',
				'click': function() {
					var q = String(searchInput.value || '').trim().toLowerCase();
					items.forEach(function(it) {
						if (matchesFilter(it, q))
							selectedSet[it.mac] = true;
					});
					renderList();
				}
			}, [_('Select all')]);

			var btnClear = E('button', {
				'type': 'button',
				'class': 'cbi-button',
				'click': function() {
					selectedSet = {};
					renderList();
				}
			}, [_('Clear')]);

			var btnAddManual = E('button', {
				'type': 'button',
				'class': 'cbi-button cbi-button-add',
				'click': addManualMacs
			}, [_('Add')]);

			var root = E('div', { 'id': widgetId, 'class': 'ho-picker' }, [
				E('div', { 'class': 'ho-picker-bar' }, [searchInput, btnSelectAll, btnClear, countBadge]),
				listBox,
				E('div', { 'class': 'ho-picker-manual' }, [manualBox, btnAddManual]),
				errBox
			]);

			// Expose state collector on DOM element for parse()
			root._hoCollectMacs = function() {
				var extra = splitMacInput(manualBox.value);
				if (extra.invalid.length) {
					setErr(_('Invalid MAC address: %s').format(extra.invalid.join(', ')));
					return { ok: false, invalid: extra.invalid, macs: [] };
				}
				extra.valid.forEach(function(m) { selectedSet[m] = true; });
				manualBox.value = '';
				setErr('');
				var out = Object.keys(selectedSet).filter(function(k) { return selectedSet[k]; }).sort();
				return { ok: true, invalid: [], macs: out };
			};

			renderList();
			return root;
		};
		o.parse = function(section_id) {
			var root = document.getElementById(this.cbid(section_id));
			if (!root || typeof root._hoCollectMacs !== 'function')
				return Promise.resolve();
			var res = root._hoCollectMacs();
			if (!res.ok)
				return Promise.reject(new TypeError(_('Invalid MAC address: %s').format(res.invalid.join(', '))));
			if (res.macs.length)
				return uci.set('handoff', section_id, 'mac', res.macs);
			return uci.unset('handoff', section_id, 'mac');
		};
		o.textvalue = function(section_id) {
			var vals = L.toArray(this.cfgvalue(section_id)).filter(Boolean);
			if (!vals.length)
				return E('span', { 'class': 'ho-empty' }, ['—']);
			return E('span', { 'class': 'ho-tags' }, vals.map(function(mac) {
				var rec = self.hostCatalog.byMac[normMac(mac)];
				if (rec && rec.name) {
					var tip = rec.displayMac + (rec.ip4s.length ? ' · ' + rec.ip4s.join(', ') : '');
					return E('span', { 'class': 'ho-tag', 'title': tip }, [
						rec.name,
						' ',
						E('span', { 'class': 'ho-muted ho-tag-mono' }, ['(' + rec.displayMac + ')'])
					]);
				}
				return E('span', { 'class': 'ho-tag ho-tag-mono' }, [mac.toUpperCase()]);
			}));
		};

		o = s.option(form.DynamicList, 'ip', _('IP / Subnet'),
			_('Optional: IPv4 or IPv6 addresses or CIDR subnets, e.g. 192.168.99.50 or 192.168.99.64/28.'));
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
		// Tab 3 (Devices & IP Groups): Destination IP Groups (GridSection ipgroup)
		// ============================================================
		s = m.section(form.GridSection, 'ipgroup', _('Destination IP Groups'),
			_('Custom destination address lists that can be used alongside GeoIP categories in routing rules, such as corporate subnets (e.g. 10.20.0.0/16), your own VPS, or game servers.'));
		s.addremove = true;
		s.anonymous = true;
		bindSectionTab(s, 'groups');
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
		// Tab 2 (Routing Rules): Routing Rules (GridSection rule, sortable)
		// ============================================================
		s = m.section(form.GridSection, 'rule', _('Routing Rules'),
			_('Matched from top to bottom; the first matching rule applies, otherwise traffic goes direct. Local, loopback, multicast, and unreferenced private traffic goes direct (explicit Destination IP Groups may match private subnets such as corporate VPN ranges). Rule changes only affect new connections. Drag rows to reorder.'));
		s.addremove = true;
		s.anonymous = true;
		s.sortable = true;
		bindSectionTab(s, 'rules');
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
			_('Leave empty to match all devices.'));
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
				return E('em', { 'class': 'ho-empty' }, [_('No device groups yet; add one above first.')]);
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
			_('Combined with GeoIP categories (matches either). Leave both empty to match any destination.'));
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
				return E('em', { 'class': 'ho-empty' }, [_('No destination IP groups yet; add one above first.')]);
			return form.MultiValue.prototype.renderWidget.apply(this, arguments);
		};

		o = s.option(form.Flag, 'invert', _('Invert'),
			_('Match when the destination is NOT in the selected GeoIP categories and IP groups.'));
		o.default = '0';
		o.rmempty = false;
		o.editable = true;

		o = s.option(form.ListValue, 'target', _('Route to'));
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

		o = s.option(form.DummyValue, '_hits', _('Hits'));
		o.modalonly = false;
		o.textvalue = function(section_id) {
			return E('span', { 'class': 'ho-rule-hits', 'data-rule-id': section_id }, [
				self.renderRuleHits(self.lastStatus, section_id)
			]);
		};

		// ============================================================
		// Tab 4 (System Settings): Low-frequency global options
		// ============================================================
		s = m.section(form.NamedSection, 'main', 'handoff', _('System Settings'));
		s.addremove = false;
		bindSectionTab(s, 'settings');

		o = s.option(widgets.NetworkSelect, 'lan', _('LAN interface'));
		o.multiple = false;
		o.nocreate = true;
		o.noaliases = true;
		o.default = 'lan';
		o.rmempty = false;

		o = s.option(form.Value, 'interval', _('Check interval'),
			_('Seconds between gateway health checks (minimum 2).'));
		o.datatype = 'and(uinteger,min(2))';
		o.placeholder = '10';
		o.default = '10';
		o.rmempty = false;

		o = s.option(form.Value, 'url', _('GeoIP download URL'),
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

		// Build persistent top status box and 4-tab navigation bar
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

		var tabs = [
			['gateways', _('Gateways')],
			['rules', _('Routing Rules')],
			['groups', _('Devices & IP Groups')],
			['settings', _('System Settings')]
		];
		this.tabBar = E('ul', { 'class': 'cbi-tabmenu ho-top-tabs' }, tabs.map(function(t) {
			return E('li', {
				'data-tab': t[0],
				'class': (t[0] === self.activeTab) ? 'cbi-tab' : 'cbi-tab-disabled'
			}, [
				E('a', {
					'href': '#',
					'click': function(ev) {
						ev.preventDefault();
						self.applyTab(self.mapNode, t[0]);
					}
				}, [t[1]])
			]);
		}));

		var placeChrome = L.bind(function(mapEl) {
			this.mapNode = mapEl;
			var firstSec = mapEl.querySelector('.cbi-section');
			if (firstSec) {
				mapEl.insertBefore(this.statusBox, firstSec);
				mapEl.insertBefore(this.tabBar, firstSec);
			} else {
				mapEl.insertBefore(this.tabBar, mapEl.firstChild);
				mapEl.insertBefore(this.statusBox, this.tabBar);
			}
			this.applyTab(mapEl, this.activeTab);
			this.updateStatusUI(this.lastStatus);
			return mapEl;
		}, this);

		// 弹窗里点「保存」后 LuCI 会 reset() → renderContents() 重画整张表单：重放状态栏、标签栏并保持当前标签页
		var renderContents = m.renderContents;
		m.renderContents = function() {
			return renderContents.apply(this, arguments).then(placeChrome);
		};

		return m.render().then(L.bind(function(mapEl) {
			this.mapNode = mapEl;
			this.updateStatusUI(initStatus);
			poll.add(L.bind(function() {
				return this.refreshStatus();
			}, this), 5);

			return mapEl;
		}, this));
	}
});
