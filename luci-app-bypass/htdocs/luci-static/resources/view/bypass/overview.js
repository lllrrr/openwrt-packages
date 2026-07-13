'use strict';
'require view';
'require fs';
'require ui';

function api(/* action, ...args */) {
	return fs.exec('/usr/share/bypass/api.sh', Array.prototype.slice.call(arguments)).then(function (res) {
		try { return JSON.parse(res.stdout || '{}'); }
		catch (e) { return { code: -1, error: 'bad JSON: ' + res.stdout }; }
	});
}

function badge(label, ok, okText, badText) {
	return E('span', {
		class: 'ifacebadge',
		style: 'display:inline-block;margin:4px 8px 4px 0'
	}, [
		E('strong', {}, label + ': '),
		E('span', { style: 'color:' + (ok ? '#0c0' : '#c00') }, ok ? okText : badText)
	]);
}

return view.extend({
	load: function () {
		return api('status');
	},

	render: function (status) {
		status = status || {};

		var container = E('div', { class: 'cbi-map' }, [
			E('h2', { name: 'content' }, _('Bypass — Overview')),
			E('div', { class: 'cbi-section', style: 'display:flex;flex-wrap:wrap' }, [
				badge(_('Running'), status.running === 1, _('yes'), _('no')),
				badge(_('naive'), status.naive_present === 1, _('present'), _('missing')),
				badge(_('chinadns-ng'), status.chinadns_present === 1, _('present'), _('missing')),
				badge(_('bypasscore'), status.bypasscore_present === 1, _('present'), _('missing')),
				badge(_('bypasscore ELF'),
					status.bypasscore_linux_elf === 1,
					_('Linux ELF'), _('not Linux ELF')),
				badge(_('Firewall'), !!status.use_tables, status.use_tables || '—', 'none'),
				badge(_('Egress'), !!status.egress_iface, status.egress_iface || _('default'), _('default')),
				badge(_('Node'), true, status.node || '—', '—'),
				badge(_('Redir port'), true, status.redir_port || '—', '—')
			])
		]);

		/* ---- Route test (BypassCore -test) ---- */
		var rtInput = E('input', {
			type: 'text',
			class: 'cbi-input-text',
			placeholder: 'tcp:www.google.com:443',
			style: 'width:340px'
		});
		var rtResult = E('pre', { style: 'white-space:pre-wrap;min-height:40px;font-size:11px' }, _('Results appear here.'));

		container.appendChild(E('div', { class: 'cbi-section' }, [
			E('h3', {}, _('BypassCore route test')),
			E('p', {}, _('Preview which shunt rule / outbound a destination matches, using the BypassCore routing engine. Requires the BypassCore Linux ELF binary.')),
			E('div', { style: 'margin-bottom:8px' }, [
				rtInput, ' ',
				E('button', {
					class: 'cbi-button cbi-button-apply',
					click: function () {
						var dest = (rtInput.value || '').trim();
						if (!dest) { ui.addNotification(null, E('p', {}, _('Enter a destination like tcp:www.google.com:443'))); return; }
						api('route_test', dest).then(function (r) {
							while (rtResult.firstChild) rtResult.removeChild(rtResult.firstChild);
							if (r.code === 0 || r.code === undefined) {
								rtResult.appendChild(document.createTextNode(
									(r.matched ? _('Matched: ') + r.matched + '\n\n' : '') +
									(r.raw || _('(no output)'))));
							} else {
								rtResult.appendChild(document.createTextNode(_('Error: ') + (r.error || r.raw || _('unknown'))));
							}
						});
					}
				}, _('Test')),
				' ',
				E('button', {
					class: 'cbi-button cbi-button-neutral',
					click: function () {
						api('observe').then(function (r) {
							while (rtResult.firstChild) rtResult.removeChild(rtResult.firstChild);
							rtResult.appendChild(document.createTextNode(r.raw || r.error || _('(no output)')));
						});
					}
				}, _('Observatory'))
			]),
			rtResult
		]));

		/* ---- DNS resolve (BypassCore -resolve) ---- */
		var dnsInput = E('input', {
			type: 'text',
			class: 'cbi-input-text',
			placeholder: 'example.com',
			style: 'width:340px'
		});
		var dnsResult = E('pre', { style: 'white-space:pre-wrap;min-height:40px;font-size:11px' }, _('Resolved IPs appear here.'));
		container.appendChild(E('div', { class: 'cbi-section' }, [
			E('h3', {}, _('DNS resolve (BypassCore)')),
			E('p', {}, _('Resolve a domain via BypassCore\'s DNS subsystem (the split-DNS engine; ChinaDNS-NG remains the live resolver).')),
			E('div', { style: 'margin-bottom:8px' }, [
				dnsInput, ' ',
				E('button', {
					class: 'cbi-button cbi-button-apply',
					click: function () {
						var dom = (dnsInput.value || '').trim();
						if (!dom) { ui.addNotification(null, E('p', {}, _('Enter a domain to resolve.'))); return; }
						api('resolve', dom).then(function (r) {
							while (dnsResult.firstChild) dnsResult.removeChild(dnsResult.firstChild);
							if (r.code === 0) {
								dnsResult.appendChild(document.createTextNode(r.raw || _('(no output)')));
							} else {
								dnsResult.appendChild(document.createTextNode(_('Error: ') + (r.error || r.raw || _('unknown'))));
							}
						});
					}
				}, _('Resolve'))
			]),
			dnsResult
		]));

		/* ---- Config preview (generated config.json) ---- */
		var cfgPre = E('pre', { style: 'white-space:pre-wrap;max-height:420px;overflow:auto;font-size:11px' }, _('Click to generate/preview.'));
		container.appendChild(E('div', { class: 'cbi-section' }, [
			E('h3', {}, _('BypassCore config.json preview')),
			E('p', {}, _('The config generated from your shunt rules and fed to BypassCore (the routing engine). Traffic itself is carried by naiveproxy.')),
			E('button', {
				class: 'cbi-button cbi-button-action',
				click: function () {
					api('config_preview').then(function (r) {
						while (cfgPre.firstChild) cfgPre.removeChild(cfgPre.firstChild);
						cfgPre.appendChild(document.createTextNode(r.config || r.error || _('(none)')));
					});
				}
			}, _('Generate & preview')),
			cfgPre
		]));

		return container;
	}
});
