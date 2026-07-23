'use strict';
'require view';
'require form';
'require uci';

// Rule Manage — mirrors passwall2's client/rule.lua:
//   1. "Rule status" section (global_rules): geoip/geosite update URLs and the
//      auto-update schedule (week/time/interval mode, passwall2-style).
//   2. "Shunt Rule" table section (shunt_rules): list-first — Remarks +
//      Summary columns; clicking a row opens the rule editor.

function validateTime(_sid, value) {
	var match = /^(\d{1,2}):(\d{2})$/.exec(value || '');
	return match && +match[1] <= 23 && +match[2] <= 59
		? true : _('Enter a valid time in HH:MM format.');
}

return view.extend({
	load: function () {
		return uci.load('bypass');
	},

	render: function () {
		var m = new form.Map('bypass');

		/* ---- Section 1: global_rules ---- */
		var gs = m.section(form.TypedSection, 'global_rules', _('Rule status'));
		gs.anonymous = true;

		var o;

		o = gs.option(form.Value, 'geoip_url', _('GeoIP Update URL'));
		o.value('https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat', _('Loyalsoldier/geoip'));
		o.value('https://gh-proxy.org/https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat', _('Loyalsoldier/geoip (gh-proxy)'));
		o.value('https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geoip.dat', _('Loyalsoldier/geoip (CDN)'));
		o.value('https://github.com/MetaCubeX/meta-rules-dat/releases/latest/download/geoip.dat', _('MetaCubeX/geoip'));
		o.value('https://gh-proxy.org/https://github.com/MetaCubeX/meta-rules-dat/releases/latest/download/geoip.dat', _('MetaCubeX/geoip (gh-proxy)'));
		o.value('https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geoip.dat', _('MetaCubeX/geoip (CDN)'));
		o.default = 'https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat';

		o = gs.option(form.Value, 'geosite_url', _('Geosite Update URL'));
		o.value('https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat', _('Loyalsoldier/geosite'));
		o.value('https://gh-proxy.org/https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat', _('Loyalsoldier/geosite (gh-proxy)'));
		o.value('https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geosite.dat', _('Loyalsoldier/geosite (CDN)'));
		o.value('https://github.com/MetaCubeX/meta-rules-dat/releases/latest/download/geosite.dat', _('MetaCubeX/geosite'));
		o.value('https://gh-proxy.org/https://github.com/MetaCubeX/meta-rules-dat/releases/latest/download/geosite.dat', _('MetaCubeX/geosite (gh-proxy)'));
		o.value('https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geosite.dat', _('MetaCubeX/geosite (CDN)'));
		o.default = 'https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat';

		o = gs.option(form.ListValue, 'update_week_mode', _('Auto Update Mode'));
		o.default = '';
		// Disable is represented by an empty UCI value.  Allow the form to
		// persist that value instead of rejecting it during Save & Apply.
		o.rmempty = true;
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
		o.validate = validateTime;
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
		o.default = '1';
		o.depends('update_week_mode', '8');

		/* ---- Section 2: shunt_rules (list-first table) ---- */
		var ss = m.section(form.TableSection, 'shunt_rules',
			_('Shunt Rule'),
			_('Note the priority: the higher the order, the higher the priority.')
		);
		ss.addremove = true;
		ss.anonymous = false;
		ss.sortable = true;
		ss.extedit = L.url('admin/services/bypass/rule_edit') + '?rule=%s';
		ss.filter = function (sid) {
			return uci.get('bypass', sid, 'is_default') !== '1';
		};
		// Keep an explicit order marker in addition to LuCI's native UCI section
		// move. Older LuCI builds can move the DOM row without committing the UCI
		// order; sort_order makes the rendered and runtime order deterministic.
		ss.cfgsections = function () {
			return uci.sections('bypass', 'shunt_rules')
				.filter(function (section) { return section.is_default !== '1'; })
				.sort(function (a, b) {
					var ahas = /^\d+$/.test(a.sort_order || '');
					var bhas = /^\d+$/.test(b.sort_order || '');
					if (ahas !== bhas) return ahas ? -1 : 1;
					var ao = ahas ? +a.sort_order : (+a['.index'] || 0);
					var bo = bhas ? +b.sort_order : (+b['.index'] || 0);
					return ao - bo || (+a['.index'] || 0) - (+b['.index'] || 0);
				})
				.map(function (section) { return section['.name']; });
		};
		function rememberOrder(table) {
			if (!table) return;
			table.querySelectorAll('tr[data-sid]').forEach(function (row, index) {
				var rule = row.getAttribute('data-sid');
				if (rule) uci.set('bypass', rule, 'sort_order', String(index));
			});
		}
		var inheritedDrop = ss.handleDrop;
		ss.handleDrop = function (ev) {
			var table = ev.target && ev.target.closest ? ev.target.closest('table') : null;
			var result = inheritedDrop.call(this, ev);
			rememberOrder(table);
			return result;
		};
		var inheritedTouchEnd = ss.handleTouchEnd;
		ss.handleTouchEnd = function (ev) {
			var table = ev.target && ev.target.closest ? ev.target.closest('table') : null;
			var result = inheritedTouchEnd.call(this, ev);
			rememberOrder(table);
			return result;
		};
		ss.handleAdd = function (_ev, name) {
			var sid = uci.add('bypass', 'shunt_rules', name);
			uci.set('bypass', sid, 'remarks', name);
			uci.set('bypass', sid, 'network', 'tcp,udp');
			// A newly created rule has no match criteria yet. Keep it closed until
			// the user assigns an outbound in Basic Settings, otherwise the empty
			// rule becomes an accidental catch-all during this intermediate apply.
			uci.set('bypass', sid, 'outbound', '');
			return uci.save().then(function () {
				return uci.apply();
			}).then(function () {
				window.location.assign(L.url('admin/services/bypass/rule_edit') + '?rule=' + encodeURIComponent(sid));
			});
		};
		ss.handleRemove = function (sid) {
			if (!confirm(_('Delete rule: %s ?').format(uci.get('bypass', sid, 'remarks') || sid)))
				return Promise.resolve();
			uci.remove('bypass', sid);
			return uci.save().then(function () {
				return uci.apply();
			}).then(function () {
				window.location.reload();
			});
		};

		return m.render();
	}
});
