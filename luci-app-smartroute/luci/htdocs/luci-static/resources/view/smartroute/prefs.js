'use strict';
'require view';
'require form';
'require uci';
'require ui';
'require tools.widgets as widgets';
'require smartroute.common as sr';

return view.extend({
	load() {
		return uci.load('smartroute');
	},

	render() {
		sr.css();
		const m = new form.Map('smartroute', _('Settings'));
		const s = m.section(form.NamedSection, 'main', 'global');
		s.addremove = false;
		s.tab('general', _('General'));
		s.tab('dns', _('Domain records'));
		s.tab('conn', _('Connections'));
		s.tab('dat', _('Rule data files'));
		s.tab('compat', _('Compatibility'));
		s.tab('backup', _('Backup'));
		let o;

		o = s.taboption('general', widgets.DeviceSelect, 'interface', _('Working interfaces'),
			_('The LAN bridges where DNS answers are read and traffic is steered, usually br-lan. Add other LAN bridges (for example a guest network) to steer their devices too.'));
		o.multiple = true;
		o.noaliases = true;
		o.nocreate = true;
		o.default = 'br-lan';
		o.rmempty = false;
		o = s.taboption('general', form.Flag, 'ipv6', _('Handle IPv6'), _('When off, IPv6 traffic is not steered.'));
		o.default = '1';
		o.rmempty = false;

		o = s.taboption('dns', form.ListValue, 'dns_keep', _('Minimum keep time'),
			_('Domain records are kept at least this long even if the DNS answer expires sooner. Plain DNS answers passing this router are recorded per device; encrypted DNS (DoH/DoT) cannot be read.'));
		[['60', _('1 minute')], ['300', _('5 minutes')], ['1800', _('30 minutes')]].forEach(x => o.value(x[0], x[1]));
		o.default = '300';
		o = s.taboption('dns', form.Flag, 'dns_persist', _('Keep across restarts'), _('Domain records are restored after a router or service restart, so devices need not resolve again.'));
		o.default = '1';
		o.rmempty = false;
		o = s.taboption('dns', form.Flag, 'block_dot', _('Block encrypted DNS (DoT)'),
			_('Rejects DNS over TLS / QUIC (port 853) from devices so that they fall back to plain DNS and domain rules apply. Devices with a fixed private DNS hostname (for example on Android) can then no longer resolve names. DNS over HTTPS cannot be blocked this way; turn it off on the device.'));
		o.default = '0';

		o = s.taboption('conn', form.ListValue, 'idle_timeout', _('UDP idle timeout'),
			_('A connection keeps the exit chosen when it started, so changing policies does not interrupt it. A UDP flow idle for longer than this chooses its exit again; TCP connections keep their exit until they close (or 2 hours of idleness).'));
		[['300', _('5 minutes')], ['600', _('10 minutes')], ['1800', _('30 minutes')]].forEach(x => o.value(x[0], x[1]));
		o.default = '600';

		const url = (sid, v) => !v || /^https?:\/\/[^\s]+$/.test(v) || _('Only http:// or https:// addresses are allowed');
		o = s.taboption('dat', form.Value, 'geosite_url', _('geosite.dat address'), sr.TIPS.dat);
		o.placeholder = 'https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat';
		o.validate = url;
		o = s.taboption('dat', form.Value, 'geoip_url', _('geoip.dat address'));
		o.placeholder = 'https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat';
		o.validate = url;
		o = s.taboption('dat', form.ListValue, 'update_hour', _('Automatic update time'), _('Updated daily at this time; the old version is kept if an update fails.'));
		o.value('-1', _('No automatic update'));
		for (let h = 0; h < 24; h++) o.value(String(h), (h < 10 ? '0' : '') + h + ':00');
		o.default = '4';
		o = s.taboption('dat', form.ListValue, 'download_exit', _('Download exit'),
			_('The exit used to download the rule data files, for when GitHub cannot be reached directly. If it fails, its fallback exit is used.'));
		o.value('', _('Direct'));
		sr.exits().filter(x => x.type != 'builtin').forEach(x => o.value(x.id, sr.exitLabel(x.id)));

		o = s.taboption('compat', form.Flag, 'fix_invalid', _('Allow traffic forwarded to gateways'),
			_('Keeps forwarding working when the firewall drops invalid packets: only forwarded traffic marked by SmartRoute and taken as invalid is allowed; other protection is unchanged.'));
		o.default = '1';
		o.rmempty = false;
		o = s.taboption('compat', form.Value, 'mark_mask', _('Traffic mark mask'),
			_('The internal mark set on traffic; each exit uses one value of it. Change it only if it conflicts with another plugin (such as OpenClash); it must be contiguous bits.'));
		o.placeholder = '0x1f000000';
		o.validate = (sid, v) => {
			if (!v) return true;
			const n = Number(v);
			if (!/^(0x[0-9a-f]+|\d+)$/i.test(v) || !n || n > 0xffffffff) return _('Enter a non-zero number, for example 0x1f000000');
			let low = n;   // without trailing zero bits it must be 2^k-1 (contiguous); no bit operators, bit 31 would turn negative
			while (low % 2 == 0) low /= 2;
			return Number.isInteger(Math.log2(low + 1)) || _('The mask must be contiguous bits');
		};
		o = s.taboption('compat', form.Value, 'table_base', _('First routing table number'),
			_('Each exit uses one routing table and one policy routing rule, numbered from this value plus 1. Change it only if it conflicts with another plugin.'));
		o.placeholder = '3100';
		o.datatype = 'range(1,2147483000)';

		o = s.taboption('backup', form.Button, '_export', _('Export configuration'), _('Includes device groups, policies, exits, rule groups and settings.'));
		o.inputtitle = _('Export');
		o.onclick = () => sr.callExport().then(data => {
			const a = E('a', { 'href': URL.createObjectURL(new Blob([data], { 'type': 'text/plain' })), 'download': 'smartroute.conf' });
			document.body.appendChild(a);
			a.click();
			a.remove();
		});
		o = s.taboption('backup', form.Button, '_import', _('Import configuration'), _('Replaces the whole configuration with an exported file; takes effect immediately.'));
		o.inputtitle = _('Import');
		o.onclick = () => {
			const f = E('input', { 'type': 'file', 'accept': '.conf,text/plain' });
			f.addEventListener('change', () => {
				if (!f.files.length) return;
				f.files[0].text().then(text => {
					if (!confirm(_('Replace the whole configuration with this file and apply it now? Unapplied changes are lost.'))) return;
					return sr.callImport(text).then(r => {
						if (r && r.error) { sr.notify(_(r.error), 'danger'); return; }
						sr.notify(_('Imported'));
						setTimeout(() => location.reload(), 1000);
					});
				});
			});
			f.click();
		};

		return m.render();
	}
});
