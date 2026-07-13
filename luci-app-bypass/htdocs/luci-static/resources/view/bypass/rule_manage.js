'use strict';
'require view';
'require form';
'require uci';
'require fs';
'require ui';

// Rule Manage — mirrors passwall2's client/rule.lua layout:
//   1. "Rule status" section (global_rules): geoip/geosite update URLs, asset
//      path, auto-update schedule, a file-status line and a "Manually update"
//      button.
//   2. "Shunt Rule" table section (shunt_rules): list-first — shows only the
//      Remarks + Summary columns; clicking a row opens the rule editor
//      (rule_edit?rule=<sid>), exactly like passwall2's extedit → shunt_rules.

return view.extend({
	load: function () {
		return Promise.all([
			uci.load('bypass'),
			fs.stat('/usr/share/v2ray/geoip.dat').catch(function () { return {}; }),
			fs.stat('/usr/share/v2ray/geosite.dat').catch(function () { return {}; })
		]).then(function (res) {
			return { geoip: res[1], geosite: res[2] };
		});
	},

	render: function (stats) {
		var m = new form.Map('bypass', _('Rule Manage'));

		/* ------------------------------------------------------------------
		 * Section 1 — global_rules (geodata sources + auto-update + manual btn)
		 * ------------------------------------------------------------------ */
		var gs = m.section(form.TypedSection, 'global_rules', _('Rule status'));
		gs.anonymous = true;

		var o;

		o = gs.option(form.Value, 'geoip_url', _('GeoIP Update URL'));
		o.value('https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat', _('Loyalsoldier/geoip'));
		o.value('https://gh-proxy.org/https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat', _('Loyalsoldier/geoip (gh-proxy)'));
		o.value('https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geoip.dat', _('Loyalsoldier/geoip (CDN)'));
		o.value('https://github.com/MetaCubeX/meta-rules-dat/releases/latest/download/geoip.dat', _('MetaCubeX/geoip'));

		o = gs.option(form.Value, 'geosite_url', _('Geosite Update URL'));
		o.value('https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat', _('Loyalsoldier/geosite'));
		o.value('https://gh-proxy.org/https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat', _('Loyalsoldier/geosite (gh-proxy)'));
		o.value('https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geosite.dat', _('Loyalsoldier/geosite (CDN)'));
		o.value('https://github.com/MetaCubeX/meta-rules-dat/releases/latest/download/geosite.dat', _('MetaCubeX/geosite'));

		o = gs.option(form.Value, 'v2ray_location_asset', _('Location of Geo rule files'),
			_('Directory where geoip.dat and geosite.dat live.'));
		o.default = '/usr/share/v2ray/';
		o.placeholder = o.default;
		o.rmempty = false;

		o = gs.option(form.ListValue, 'geosite_update', _('Auto Update'));
		o.value('1', _('Enable'));
		o.value('0', _('Disable'));
		o.default = '1';

		o = gs.option(form.Value, 'auto_update_minute', _('Auto Update Time'),
			_('Minute of the hour for the periodic cron update (0-59). The cron job runs hourly when auto update is enabled.'));
		o.datatype = 'range(0,59)';
		o.default = '30';
		o.placeholder = '30';
		o.depends('geosite_update', '1');

		o = gs.option(form.ListValue, 'domainStrategy', _('Domain Strategy'),
			_('BypassCore resolve strategy: AsIs (no DNS), IpIfNonMatch (resolve on domain miss), IpOnDemand (resolve on demand).'));
		o.value('AsIs', 'AsIs');
		o.value('IpIfNonMatch', 'IpIfNonMatch');
		o.value('IpOnDemand', 'IpOnDemand');
		o.default = 'IpIfNonMatch';

		/* geoip/geosite file status + manual update button, appended via a
		 * DummyValue rendered as raw HTML (mirrors passwall2 rule_version.htm). */
		var statLine = E('div', {}, [
			E('div', {}, _('geoip.dat: %s · %s').format(
				stats.geoip.size ? String(stats.geoip.size) + ' bytes' : '—',
				stats.geoip.mtime ? new Date(stats.geoip.mtime * 1000).toLocaleString() : '—'
			)),
			E('div', {}, _('geosite.dat: %s · %s').format(
				stats.geosite.size ? String(stats.geosite.size) + ' bytes' : '—',
				stats.geosite.mtime ? new Date(stats.geosite.mtime * 1000).toLocaleString() : '—'
			)),
			E('div', { style: 'margin-top:8px' }, [
				E('button', {
					class: 'cbi-button cbi-button-apply',
					click: function (ev) {
						var btn = ev.target;
						btn.disabled = true;
						btn.textContent = _('Updating…');
						fs.exec('/usr/share/bypass/api.sh', ['rule_update']).then(function (res) {
							btn.disabled = false;
							btn.textContent = _('Manually update');
							ui.addNotification(null, E('p', {}, (res.stdout || '').trim() || _('Done')));
						});
					}
				}, _('Manually update'))
			])
		]);
		o = gs.option(form.DummyValue, '_rule_status', _('Rule files'));
		o.rawhtml = true;
		o.cfgvalue = function () { return statLine; };

		/* ------------------------------------------------------------------
		 * Section 2 — shunt_rules (list-first table; extedit opens editor)
		 * ------------------------------------------------------------------ */
		var ss = m.section(form.TableSection, 'shunt_rules',
			_('Shunt Rule'),
			// Red priority warning, same as passwall2.
			E('span', { style: 'color: red' },
				_('Note the priority: the higher the order, the higher the priority.'))
		);
		ss.addremove = true;
		ss.anonymous = false;          // show the section name as an identifier
		ss.sortable = true;            // order = priority
		ss.extedit = function (sid) {
			return 'rule_edit?rule=' + encodeURIComponent(sid);
		};

		o = ss.option(form.DummyValue, 'remarks', _('Remarks'));
		// Show a short summary (outbound + network) next to the remarks so the
		// table is informative without being fully expanded.
		o = ss.option(form.DummyValue, '_summary', _('Summary'));
		o.cfgvalue = function (sid) {
			var outbound = uci.get('bypass', sid, 'outbound') || '—';
			var network = uci.get('bypass', sid, 'network') || '';
			var map = { _direct: _('Direct'), _proxy: _('Proxy (naive)'), _block: _('Block') };
			var label = map[outbound] || outbound;
			if (network) label += ' · ' + network.toUpperCase();
			return label;
		};

		return m.render();
	}
});
