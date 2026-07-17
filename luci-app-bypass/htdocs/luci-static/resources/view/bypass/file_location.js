'use strict';
'require view';
'require form';

// File Location — centralizes every binary / asset path in one place:
//   • Core Binaries (global): bypasscore / naive
//   • Geo Rule Files (global_rules): v2ray_location_asset

return view.extend({
	render: function () {
		var m = new form.Map('bypass');
		var o;

		/* ---- Core binaries (global section) ---- */
		var sBin = m.section(form.TypedSection, 'global', _('Core Binaries'));
		sBin.anonymous = true;

		o = sBin.option(form.Value, 'bypasscore_file', _('BypassCore binary'));
		o.placeholder = '/usr/bin/bypasscore';

		o = sBin.option(form.Value, 'naive_file', _('naive binary'));
		o.placeholder = '/usr/bin/naive';

		/* ---- Geo rule files (global_rules section) ---- */
		var sGeo = m.section(form.TypedSection, 'global_rules', _('Geo Rule Files'));
		sGeo.anonymous = true;

		o = sGeo.option(form.Value, 'v2ray_location_asset', _('Location of Geo rule files'),
			_('Directory where geoip.dat and geosite.dat live.'));
		o.default = '/usr/share/v2ray/';
		o.placeholder = o.default;
		o.rmempty = false;

		return m.render();
	}
});
