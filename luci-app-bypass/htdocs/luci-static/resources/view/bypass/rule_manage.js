'use strict';
'require view';
'require form';
'require uci';
'require fs';
'require ui';

// Rule Manage — mirrors passwall2's client/rule.lua:
//   1. "Rule status" section (global_rules): geoip/geosite update URLs, asset
//      path, auto-update schedule (week/time/interval mode, passwall2-style),
//      a file-status line and a "Manually update" button.
//   2. "Shunt Rule" table section (shunt_rules): list-first — Remarks +
//      Summary columns; clicking a row opens the rule editor.

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

		/* ---- Section 1: global_rules ---- */
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

		o = gs.option(form.ListValue, 'update_week_mode', _('Auto Update Mode'));
		o.value('', _('Disable'));
		o.value('8', _('Loop Mode'));
		o.value('7', _('Every day'));
		o.value('1', _('Every Monday'));
		o.value('2', _('Every Tuesday'));
		o.value('3', _('Every Wednesday'));
		o.value('4', _('Every Thursday'));
		o.value('5', _('Every Friday'));
		o.value('6', _('Every Saturday'));
		o.value('0', _('Every Sunday'));

		o = gs.option(form.Value, 'update_time_mode', _('Update Time'));
		o.value('0:00');
		for (var t = 0; t <= 23; t++) {
			if (t === 12) o.value('12:30');
			else if (t === 23) o.value('23:59');
			else o.value(t + ':00');
		}
		o.default = '0:00';
		o.depends('update_week_mode', '0');
		o.depends('update_week_mode', '1');
		o.depends('update_week_mode', '2');
		o.depends('update_week_mode', '3');
		o.depends('update_week_mode', '4');
		o.depends('update_week_mode', '5');
		o.depends('update_week_mode', '6');
		o.depends('update_week_mode', '7');

		o = gs.option(form.ListValue, 'update_interval_mode', _('Update Interval(hour)'));
		for (var h = 1; h <= 24; h++) o.value(String(h), h + ' ' + _('hour'));
		o.default = '2';
		o.depends('update_week_mode', '8');

		o = gs.option(form.Flag, 'geoip_update', _('Update GeoIP'));
		o.rmempty = false;
		o = gs.option(form.Flag, 'geosite_update', _('Update Geosite'));
		o.rmempty = false;

		// File status + manual update button.
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

		/* ---- Section 2: shunt_rules (list-first table) ---- */
		var ss = m.section(form.TableSection, 'shunt_rules',
			_('Shunt Rule'),
			E('span', { style: 'color: red' },
				_('Note the priority: the higher the order, the higher the priority.'))
		);
		ss.addremove = true;
		ss.anonymous = false;
		ss.sortable = true;
		ss.extedit = function (sid) {
			return 'rule_edit?rule=' + encodeURIComponent(sid);
		};

		o = ss.option(form.DummyValue, 'remarks', _('Remarks'));
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
