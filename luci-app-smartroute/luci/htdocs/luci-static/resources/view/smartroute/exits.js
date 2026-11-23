'use strict';
'require view';
'require uci';
'require ui';
'require dom';
'require smartroute.common as sr';

const C = 'smartroute';
const RE_IP4 = /^(25[0-5]|2[0-4]\d|1?\d?\d)(\.(25[0-5]|2[0-4]\d|1?\d?\d)){3}$/;
const RE_IP6 = /^[0-9a-f:]*:[0-9a-f:]*$/i;
const RE_DNS4 = /^(25[0-5]|2[0-4]\d|1?\d?\d)(\.(25[0-5]|2[0-4]\d|1?\d?\d)){3}(:\d{1,5})?$/;
const RE_DOMAIN = /^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$/i;

return view.extend({
	load() {
		return Promise.all([uci.load(C), sr.callStatus(), sr.callScan(), sr.callInfo()]);
	},

	render(data) {
		sr.css();
		this.st = (data[1] || {}).state || {};
		this.scan = data[2] || [];
		this.networks = (data[3] || {}).networks || [];
		this.dnsRedirect = !!(data[3] || {}).dns_redirect;
		// 收起的出口记在浏览器里（每台浏览器各自记，读写失败时全部展开）
		try { this.closed = new Set(JSON.parse(localStorage.getItem('sr-exits-closed') || '[]')); } catch (e) { this.closed = new Set(); }
		this.root = E('div', { 'class': 'cbi-map sr' });
		this.draw();
		return this.root;
	},

	change(msg) {
		return sr.commit(msg).then(() => this.draw());
	},

	draw() {
		const cards = sr.exits().map(e => e.type == 'builtin'
			? sr.section(e.name, null, [sr.pill('', _('Built-in'))], [E('p', { 'class': 'sr-muted' }, [e.note])])
			: this.card(e));
		dom.content(this.root, [sr.section(_('Exits'), 'exit', [sr.btn(_('Add exit'), 'cbi-button-add', () => this.addDialog())], [])].concat(cards));
	},

	used(id) {
		return sr.all('policy').filter(p => (p.exit || 'direct') == id).length + sr.all('exit').filter(x => x.fallback == id).length + (sr.get('main', 'download_exit') == id ? 1 : 0);
	},

	card(e) {
		const id = e.id, s = e.s, gw = e.type == 'gateway', live = (this.st.Exits || []).find(x => x.ID == id), h = (this.st.Health || {})[id];
		const interval = s.check_interval != null ? s.check_interval : '5';
		const checked = interval != '0' && (gw || s.check_ip || s.check_ip6);
		const status = !live ? sr.pill('', _('Available after starting')) : !checked ? sr.pill('', _('Not checked')) : !h ? sr.pill('', _('Checking'))
			: !h.Up ? sr.pill('bad', _('Check failed'))
			: E('span', {}, [sr.pill('good', 'IPv4 ' + _('%s ms').format(h.RTTms.toFixed(1))), ' ',
				h.Up6 == null ? '' : h.Up6 ? sr.pill('good', 'IPv6 ' + _('%s ms').format(h.RTT6ms.toFixed(1))) : sr.pill('warn', _('IPv6 check failed')), ' ',
				h.DNSUp == null ? '' : h.DNSUp ? sr.pill('good', _('DNS normal')) : sr.pill('bad', _('DNS not responding')), ' ',
				h.DNS6Up == null ? '' : h.DNS6Up ? sr.pill('good', _('IPv6 DNS normal')) : sr.pill('warn', _('IPv6 DNS not responding'))]);
		const text = (opt, ph, check, bad) => E('input', { 'type': 'text', 'class': 'cbi-input-text' + (/(ip|dns)/.test(opt) ? ' sr-mono' : ''), 'value': s[opt] || '', 'placeholder': ph || '',
			'change': ev => {
				const v = ev.target.value.trim();
				if (v && check && !check(v)) { ev.target.classList.add('sr-invalid'); sr.notify(bad || _('Invalid address'), 'warning'); return; }
				ev.target.classList.remove('sr-invalid');
				if (v) uci.set(C, id, opt, v); else uci.unset(C, id, opt);
				this.change();
			} });
		const sel = (opt, options, def) => E('select', { 'class': 'cbi-input-select', 'change': ev => { uci.set(C, id, opt, ev.target.value); this.change(); } },
			options.map(o => E('option', { 'value': o[0], 'selected': (s[opt] || def) == o[0] ? '' : null }, [o[1]])));
		const v6 = s.ipv6 || 'follow';
		const fallbacks = sr.exits().filter(x => x.id != id && x.id != 'direct').map(x => [x.id, sr.exitLabel(x.id)]);
		const n = this.used(id);
		const pending = msg => sr.pill(live ? 'warn' : '', live ? msg : _('Available after starting'));
		const rows = [
			sr.field(_('Name'), text('name', gw ? _('Defaults to the host name of the gateway') : _('For example: Office VPN'))),
			gw ? sr.field(_('Gateway address (IPv4)'), text('ip', '192.168.1.2', v => RE_IP4.test(v)))
				: sr.field(_('Interface'), sel('network', this.networks.map(x => [x.name, x.name + (x.device ? ' (' + x.device + ')' : '')]), s.network))
		];
		if (gw)
			rows.push(sr.field('MAC', live && live.MAC ? [sr.t('span', { 'class': 'sr-mono' }, live.MAC), ' ', sr.pill('good', _('Found'))] : pending(_('Not found, check that the gateway is online'))),
				sr.field(_('IPv6 next hop'), [live && live.LL ? sr.t('span', { 'class': 'sr-mono' }, live.LL) : pending(v6 == 'follow' ? _('Not found') : _('Not needed')),
					live && live.LL ? [' ', sr.pill('good', _('Found'))] : '', ' ',
					live ? sr.btn(_('Find again'), '', ev => { ev.target.disabled = true; return sr.callReload().then(() => new Promise(r => setTimeout(r, 2500))).then(() => sr.callStatus()).then(r => { this.st = (r || {}).state || {}; this.draw(); }); }) : ''], 'v6addr'));
		else
			rows.push(sr.field(_('Device'), live && live.Dev ? sr.t('span', { 'class': 'sr-mono' }, live.Dev) : pending(_('Interface is down'))),
				sr.field(_('Next hop'), sr.t('span', { 'class': 'sr-mono' }, live ? [live.Gw4, live.Gw6].filter(x => x).join(', ') || _('None (point-to-point)') : '—')));
		rows.push(sr.field(_('IPv6 handling'), sr.radios('v6-' + id, v6, {
			follow: gw ? _('Forward to the gateway (the gateway supports IPv6)') : _('Send through the interface'),
			v4only: _('Reject IPv6 so that devices fall back to IPv4 (recommended if IPv6 is not supported)'),
			none: _('Do not handle')
		}, v => { uci.set(C, id, 'ipv6', v); this.change(); }), 'v6'));
		rows.push(sr.field(_('Fallback'), sel('fallback', [['', _('Direct')]].concat(fallbacks), ''), 'fallback'),
			sr.field(_('Check interval'), sel('check_interval', [['5', _('%s seconds').format(5)], ['10', _('%s seconds').format(10)], ['30', _('%s seconds').format(30)], ['0', _('No checks')]], '5')),
			sr.field(_('Check address'), text('check_ip', gw ? _('Empty: check the gateway itself') : _('Required for checks, for example 8.8.8.8'), v => RE_IP4.test(v)), 'probe'),
			sr.field(_('IPv6 check address'), text('check_ip6', gw ? _('Empty: check the IPv6 next hop') : _('Optional, for example 2001:4860:4860::8888'), v => RE_IP6.test(v)), 'probe6'),
			sr.field(_('DNS server'), text('dns', _('Empty: use the router DNS'), v => RE_DNS4.test(v)), 'dns'));
		if (s.dns)
			rows.push(sr.field(_('When the DNS server fails'), sel('dns_fail', [['fallback', _('Use the DNS of the fallback exit, then the router DNS')], ['router', _('Use the router DNS')], ['keep', _('Keep using this DNS server')]], 'fallback'), 'dnsfail'),
				sr.field(_('Traffic when the DNS server fails'), sel('dns_fail_traffic', [['0', _('Keep using this exit')], ['1', _('Switch to the fallback as well')]], '0')),
				sr.field(_('IPv6 queries without a usable exit'), sel('dns6_none', [['reject', _('Reject, devices query over IPv4 instead')], ['router', _('Use the router DNS')]], 'reject'), 'dns6none'),
				sr.field(_('DNS check domain'), text('dns_check', 'www.google.com', v => RE_DOMAIN.test(v), _('Invalid domain')), 'dnscheck'));
		if (gw)
			rows.push(sr.field(_('DNS queries from the gateway itself'), sel('dns_nohijack', [['1', _('Not redirected by this router')], ['0', _('Redirected as usual')]], '1'), 'nohijack',
				this.dnsRedirect ? null : _('DNS redirection is not enabled on this router, so this option has no effect.')));

		const closed = this.closed.has(id);
		return sr.section(sr.exitLabel(id), gw ? 'gateway' : 'line', [status,
			sr.btn(closed ? _('Expand') : _('Collapse'), '', () => this.toggle(id), { 'aria-expanded': closed ? 'false' : 'true' }),
			sr.btn(_('Delete'), 'cbi-button-remove', () => {
				if (n) { sr.notify(_('This exit is used in %s place(s) (policies, fallback or download exit); change those first').format(n), 'warning'); return; }
				sr.undoable(_('Exit deleted'), () => uci.remove(C, id), () => this.draw());
			})], closed ? [] : rows);
	},

	toggle(id) {
		this.closed.has(id) ? this.closed.delete(id) : this.closed.add(id);
		try { localStorage.setItem('sr-exits-closed', JSON.stringify([...this.closed])); } catch (e) {}
		this.draw();
	},

	addDialog() {
		const ip = E('input', { 'type': 'text', 'class': 'cbi-input-text sr-mono', 'placeholder': '192.168.1.3' });
		const net = E('select', { 'class': 'cbi-input-select' }, this.networks.filter(x => x.name != 'lan').map(x => E('option', { 'value': x.name }, [x.name + (x.device ? ' (' + x.device + ')' : '') + (x.up ? '' : ' · ' + _('down'))])));
		const name = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'placeholder': _('Empty: use the host name or address') });
		const ipBox = sr.field(_('Gateway address (IPv4)'), ip);
		const netBox = sr.field(_('Interface'), net, null, _('The interface must be in a firewall zone with masquerading (for example wan), otherwise traffic through it gets no replies.'), { 'hidden': '' });
		let g = true;
		const types = sr.radios('sr-type', 'gateway', { gateway: E('span', {}, [_('Gateway'), sr.tip('gateway', 'left')]), interface: E('span', {}, [_('Line or tunnel (WireGuard, second WAN…)'), sr.tip('line', 'left')]) },
			v => { g = v == 'gateway'; ipBox.hidden = !g; netBox.hidden = g; });
		sr.modal(_('Add exit'), [sr.field(_('Type'), types), ipBox, netBox, sr.field(_('Name'), name)], _('Add'), () => {
			const a = ip.value.trim();
			if (g && !RE_IP4.test(a)) { sr.notify(_('Enter a valid IPv4 address, for example 192.168.1.3'), 'warning'); return false; }
			if (!g && !net.value) { sr.notify(_('Select an interface'), 'warning'); return false; }
			const n = name.value.trim() || (g ? ((this.scan.find(s => s.ip == a) || {}).host || a) : net.value);
			if (sr.exits().some(x => x.name == n)) { sr.notify(_('An exit with this name already exists'), 'warning'); return false; }
			const id = uci.add(C, 'exit', sr.newName('e'));
			uci.set(C, id, 'type', g ? 'gateway' : 'interface');
			uci.set(C, id, g ? 'ip' : 'network', g ? a : net.value);
			uci.set(C, id, 'name', n);
			return this.change(_('Exit "%s" added; takes effect after Save & Apply').format(n));
		});
		setTimeout(() => ip.focus(), 50);
	},

	handleSaveApply(ev, mode) { return sr.saveApply(mode); },
	handleSave: null,
	handleReset: null
});
