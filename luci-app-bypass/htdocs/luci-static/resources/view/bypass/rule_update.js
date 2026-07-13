'use strict';
'require view';
'require fs';
'require ui';

return view.extend({
	load: function () {
		return fs.stat('/usr/share/v2ray/geoip.dat').catch(function () { return {}; }).then(function (s) {
			return fs.stat('/usr/share/v2ray/geosite.dat').catch(function () { return {}; }).then(function (s2) {
				return { geoip: s, geosite: s2 };
			});
		});
	},

	render: function (stats) {
		var container = E('div', { class: 'cbi-map' }, [
			E('h2', { name: 'content' }, _('Rule Update')),
			E('p', { class: 'cbi-section-descr' }, _('Download / refresh geoip.dat and geosite.dat (Loyalsoldier) used by BypassCore geosite:/geoip: rules and the firewall ipset/nftset plane.'))
		]);

		/* Geoip card */
		container.appendChild(E('div', { class: 'cbi-section' }, [
			E('h3', {}, _('geoip.dat')),
			E('p', {}, _('Size: %s bytes · Last modified: %s').format(
				stats.geoip.size ? String(stats.geoip.size) : '—',
				stats.geoip.mtime ? new Date(stats.geoip.mtime * 1000).toLocaleString() : '—')),
			E('button', {
				class: 'cbi-button cbi-button-apply',
				click: function (ev) {
					var btn = ev.target;
					btn.disabled = true;
					btn.textContent = _('Updating…');
					fs.exec('/usr/share/bypass/api.sh', ['rule_update']).then(function (res) {
						btn.disabled = false;
						btn.textContent = _('Update geoip/geosite');
						ui.addNotification(null, E('p', {}, (res.stdout || '').trim() || _('Done')));
					});
				}
			}, _('Update geoip/geosite'))
		]));

		/* Auto-update toggle reminder */
		container.appendChild(E('div', { class: 'cbi-section' }, [
			E('h3', {}, _('Automatic updates')),
			E('p', {}, _('Periodic update is enabled when global_rules.geosite_update = 1 (cron, default 04:30 daily). Toggle it and the auto-update minute on the Basic Settings page (future).'))
		]));

		return container;
	}
});
