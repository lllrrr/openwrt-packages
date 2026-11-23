'use strict';
'require view';
'require uci';
'require ui';
'require dom';
'require smartroute.common as sr';

const C = 'smartroute';

return view.extend({
	load() {
		return Promise.all([uci.load(C), uci.load('firewall'), sr.callStatus(), sr.callInfo(), sr.callScan()]);
	},

	render(data) {
		sr.css();
		this.status = data[2] || {};
		this.info = data[3] || {};
		this.scan = data[4] || [];
		return E('div', { 'class': 'cbi-map sr' }, [this.checks(), this.tracePanel(), this.dnsPanel(), this.events()]);
	},

	// Device name for a MAC: named device in a group, else host name from the scan
	devName(mac) {
		const d = sr.all('device').find(d => (d.mac || '').toLowerCase() == mac);
		const s = this.scan.find(s => s.mac == mac);
		return (d && d.name) || (s && s.host) || mac;
	},

	checks() {
		const st = this.status, s = st.state || {}, stats = st.stats || {}, on = sr.get('main', 'enabled') == '1';
		const fw = k => uci.get('firewall', '@defaults[0]', k);
		const word = { good: _('Normal'), warn: _('Attention'), bad: _('Abnormal'), '': _('Not in use') };
		const row = (kind, title, detail) => sr.field(title, [sr.pill(kind, word[kind]), detail ? [' ', sr.t('span', {}, detail)] : '']);
		const health = s.Health || {};
		const skipped = (s.Rules || {}).skipped || {};
		// 数据文件自带的 regexp: / keyword: 用户无法改动，只作普通提示；其余（用户写的规则、缺文件或分类）才提示注意
		const sum = keys => keys.reduce((a, k) => a + skipped[k], 0);
		const userKeys = Object.keys(skipped).filter(k => k.indexOf('dat:') != 0), datKeys = Object.keys(skipped).filter(k => k.indexOf('dat:') == 0);
		const nSkipped = sum(userKeys), nDat = sum(datKeys);
		const datNote = nDat ? _('%s %s rule(s) in the rule data files are not supported on the router and are filtered out').format(nDat, datKeys.map(k => k.slice(4) + ':').join(' / ')) : '';
		// 需要 TCX（6.6+）；不需要内核 BTF：程序没有 CO-RE 重定位
		const kv = (this.info.kernel || '').split('.').map(Number), kernelOK = kv[0] > 6 || (kv[0] == 6 && kv[1] >= 6);
		const items = [
			row(kernelOK ? 'good' : 'bad', [_('Kernel support')], kernelOK ? _('eBPF available · kernel %s').format(this.info.kernel) : _('Kernel %s is too old, the steering program requires 6.6 or later').format(this.info.kernel)),
			row(st.running ? 'good' : on ? 'bad' : '', [_('Steering program')], st.running ? _('Attached to %s').format((s.Interfaces || []).join(', ')) : on ? _('Not running; see the system log (logread -e smartroute)') : _('SmartRoute is disabled, nothing is loaded')),
			row(st.running ? 'good' : '', [_('Domain records'), sr.tip('dnsrec', 'left')], st.running ? _('%s records · %s DNS answers read').format(sr.fmt(stats.dns_entries), sr.fmt(stats.dns_responses)) + (stats.dns_steered ? ' · ' + _('%s DNS queries steered').format(sr.fmt(stats.dns_steered)) : '') + (stats.dns_failed ? ' ' + _('(%s could not be parsed)').format(sr.fmt(stats.dns_failed)) : '') + (stats.aaaa_blocked ? ' · ' + _('%s AAAA records blocked').format(sr.fmt(stats.aaaa_blocked)) : '') : ''),
			row(st.running ? 'good' : '', [_('Connection records')], st.running ? _('%s connections keeping their exit · %s new connections, %s through an exit').format(sr.fmt(stats.conn_entries), sr.fmt(stats.new_flows), sr.fmt(stats.steered_flows)) : ''),
			row(st.running ? 'good' : '', [_('Policy routing')], st.running ? _('%s routing tables ready').format((s.Exits || []).length) : '')
		];
		(s.Exits || []).filter(x => x.Type == 'gateway' || x.Type == 'interface').forEach(x => {
			const h = health[x.ID];
			const parts = [];
			if (h) parts.push(h.Up ? _('IPv4 check OK · %s ms').format(h.RTTms.toFixed(1)) : _('IPv4 check failed, using the fallback exit'));
			if (h && h.Up6 != null) parts.push(h.Up6 ? _('IPv6 check OK · %s ms').format(h.RTT6ms.toFixed(1)) : _('IPv6 check failed, IPv6 rejected'));
			if (h && h.DNSUp != null) parts.push(h.DNSUp ? _('DNS normal') : _('DNS not responding'));
			if (h && h.DNS6Up != null) parts.push(h.DNS6Up ? _('IPv6 DNS normal') : _('IPv6 DNS not responding'));
			if (x.Type == 'gateway') parts.push('MAC ' + (x.MAC || _('not found')), _('IPv6 next hop %s').format(x.LL || (x.V6Mode == 'follow' ? _('not found') : _('not needed'))));
			else parts.push(_('Device %s').format(x.Dev || _('down')));
			items.push(row(!h ? '' : !h.Up ? 'bad' : h.Up6 === false || h.DNSUp === false || h.DNS6Up === false ? 'warn' : 'good', [sr.exitLabel(x.ID)], parts.join(' · ')));
		});
		const di = fw('drop_invalid') == '1', fix = sr.get('main', 'fix_invalid') != '0';
		items.push(row(di && !fix ? 'warn' : 'good', [_('Firewall compatibility'), sr.tip('invalid', 'left')],
			di ? (fix ? _('"Drop invalid packets" is on; traffic forwarded to gateways is allowed automatically') : _('"Drop invalid packets" is on and traffic forwarded to gateways is dropped; enable automatic allowing in Settings')) : _('Normal')));
		items.push(row('good', [_('Flow offloading')], fw('flow_offloading') == '1' ? _('Software flow offloading is on (compatible)') : _('Not enabled')));
		items.push(row('good', [_('Encrypted DNS'), sr.tip('dot', 'left')], sr.get('main', 'block_dot') == '1' ? _('DNS over TLS / QUIC (port 853) is rejected') : _('Not blocked; devices using encrypted DNS are matched by IP rules only')));
		items.push(row(nSkipped ? 'warn' : 'good', [_('Rule groups')], [nSkipped
			? _('%s rule(s) unsupported or unavailable, skipped: %s').format(nSkipped, userKeys.map(k => sr.skipText(k)).join(', '))
			: st.running ? _('All rules loaded (%s)').format(sr.fmt((s.Rules || {}).count)) : '', datNote].filter(x => x).join(' · ')));
		if ((s.Warnings || []).length)
			items.push(row('warn', [_('Configuration problems')], s.Warnings.map(w => sr.msg(w)).join('; ')));

		return sr.section(_('Status'), null, [sr.btn(_('Copy diagnostics'), '', () => this.copy())], items);
	},

	copy() {
		const text = JSON.stringify({ info: this.info, status: this.status }, null, 2);
		const fallback = () => ui.showModal(_('Diagnosis'), [E('p', {}, [_('Copying failed; copy the text below manually:')]),
			E('textarea', { 'readonly': '', 'style': 'width:100%;min-height:300px;font-family:monospace' }, [text]),
			E('div', { 'class': 'right' }, [sr.btn(_('Close'), '', ui.hideModal)])]);
		if (navigator.clipboard && window.isSecureContext)
			navigator.clipboard.writeText(text).then(() => sr.notify(_('Diagnostics copied')), fallback);
		else
			fallback();
	},

	tracePanel() {
		const devs = sr.all('device');
		const opts = devs.map(d => {
			const v = (d.type || (d.mac ? 'mac' : 'ip')) == 'mac' ? d.mac : d.ip;
			return v && v.indexOf('/') < 0 ? E('option', { 'value': v }, [sr.devLabel(d) + ' (' + v + ')']) : null;
		}).filter(Boolean).concat(this.scan.filter(s => !devs.some(d => (d.mac || '').toLowerCase() == s.mac)).map(s =>
			E('option', { 'value': s.mac }, [_('Not in a device group (%s)').format((s.host ? s.host + ' ' : '') + (s.ip || s.mac))])));
		const dev = E('select', { 'class': 'cbi-input-select', 'aria-label': _('Device') }, opts.length ? opts : [E('option', { 'value': '' }, [_('No devices to choose from')])]);
		const dst = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'placeholder': _('Domain or IP, for example www.google.com'), 'aria-label': _('Target') });
		const out = E('div', {});
		const go = () => {
			const t = dst.value.trim();
			if (!dev.value || !t) { sr.notify(_('Select a device and enter a target'), 'warning'); return; }
			return sr.callTrace(dev.value, t).then(r => dom.content(out, this.traceResult(r || {})));
		};
		dst.addEventListener('keydown', ev => { if (ev.key == 'Enter') go(); });
		return sr.section(_('Traffic path test'), null, null, [
			E('p', { 'class': 'sr-muted' }, [_('Simulates a device connecting to an address and shows the matching policy and exit, without sending traffic. Uses the saved configuration; unapplied changes are not included.')]),
			sr.field(_('Device'), dev), sr.field(_('Target'), [dst, ' ', sr.btn(_('Test'), 'cbi-button-action', go)]), out]);
	},

	traceResult(r) {
		if (r.error) return [sr.t('p', { 'class': 'sr-lint-bad' }, _(r.error))];
		const flows = sr.all('policy').map(p => p['.name']);
		const reasons = { device: _('device does not match'), rules: _('rule groups do not match'), rules_neg: _('rule groups do not match (inverted)') };
		const notes = { no_record: _('No record of this domain for the device: domain rules apply once the device has resolved it through DNS'), protected: _('The target is a protected address (private, multicast or local network) and is never steered') };
		const steps = [];
		steps.push(E('li', {}, [_('Device: '), sr.t('b', {}, r.Device + (r.IP && r.IP != r.Device ? ' (' + r.IP + ')' : '')), ' ',
			r.Groups && r.Groups.length ? _('in %s').format(r.Groups.join(', ')) : _('not in any device group')]));
		steps.push(E('li', {}, [_('Target: '), sr.t('b', {}, r.Target), ' ',
			r.Addr && r.Addr != r.Target ? _('→ %s (domain record)').format(r.Addr) + ' ' : '',
			r.Domain && r.FromRecord ? _('← %s (domain record)').format(r.Domain) + ' ' : '',
			r.RuleGroups && r.RuleGroups.length ? _('in rule groups %s').format(r.RuleGroups.join(', ')) : _('not in any rule group')]));
		if (r.Note) steps.push(E('li', { 'class': 'sr-lint-warn' }, [notes[r.Note] || r.Note]));
		(r.Steps || []).forEach(s => {
			const n = flows.indexOf(s.Policy) + 1;
			steps.push(E('li', { 'class': s.Match ? 'hit' : 'miss' }, [_('Policy %s: %s').format(n, s.Match ? _('match') : reasons[s.Reason] || s.Reason)]));
		});
		flows.forEach((id, i) => { if (!sr.enabled(id)) steps.push(E('li', { 'class': 'miss' }, [_('Policy %s: disabled, skipped').format(i + 1)])); });
		steps.push(E('li', {}, [_('Exit: '), sr.t('b', {}, r.Policy ? sr.exitLabel(r.Exit) : _('no policy matches, forwarded as usual by this router')),
			r.Actual ? E('span', { 'class': 'sr-lint-bad' }, [' ' + _('(check failed, %s is used)').format(sr.exitLabel(r.Actual))]) : '']));
		const via = id => id && id != (r.Actual || r.Exit) ? ' ' + _('(through %s)').format(sr.exitLabel(id)) : '';
		if (r.DNS4) steps.push(E('li', {}, [_('DNS: '), sr.t('span', { 'class': 'sr-mono' }, r.DNS4), via(r.DNS4Exit)]));
		if (r.DNS6) steps.push(E('li', {}, [_('IPv6 DNS: '), sr.t('span', { 'class': 'sr-mono' }, r.DNS6), via(r.DNS6Exit)]));
		else if (r.DNS6Reject) steps.push(E('li', {}, [_('IPv6 DNS: '), _('rejected, the device queries over IPv4 instead')]));
		return [E('ol', { 'class': 'sr-steps' }, steps)];
	},

	dnsPanel() {
		const q = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'placeholder': _('Domain or IP'), 'aria-label': _('Domain or IP') });
		const out = E('div', {});
		const go = () => sr.callDNS(q.value.trim()).then(r => {
			r = r || {};
			if (r.error) return dom.content(out, sr.t('p', { 'class': 'sr-lint-bad' }, r.error == 'not running' ? _('The steering service is not running.') : _(r.error)));
			const recs = r.records || [];
			if (!recs.length) return dom.content(out, E('p', { 'class': 'sr-muted' }, [_('No records. A record is created when a device resolves the domain through DNS.')]));
			dom.content(out, sr.table([_('Domain'), 'IP', _('Device'), [_('Kept for'), 'sr-n']], recs.slice(0, 500).map(x => sr.tr('', [
				sr.td(_('Domain'), sr.t('span', {}, x.Name)), sr.td('IP', sr.t('span', {}, x.IP), 'sr-mono'),
				sr.td(_('Device'), sr.t('span', {}, this.devName(x.MAC)), '', { 'title': x.MAC }),
				sr.td(_('Kept for'), _('%s min %s s').format(Math.floor(x.TTLLeft / 60), x.TTLLeft % 60), 'sr-n')]))));
		});
		q.addEventListener('keydown', ev => { if (ev.key == 'Enter') go(); });
		return sr.section(_('Domain records'), null, null, [
			sr.field(_('Domain or IP'), [q, ' ', sr.btn(_('Search'), '', go)], null, _('Records are kept per device. Leave empty to list all records (at most 500 are shown).')), out]);
	},

	events() {
		const evs = (((this.status || {}).state || {}).Events || []).slice().reverse();
		return sr.section(_('Recent events'), null, null, [
			evs.length ? E('div', { 'class': 'sr-log' }, evs.map(e => E('div', {}, [
				sr.t('span', { 'class': 'sr-muted sr-mono' }, new Date(e.Time).toLocaleString()),
				sr.t('span', { 'class': e.Bad ? 'sr-lint-bad' : '' }, sr.msg(e))])))
				: E('p', { 'class': 'sr-muted' }, [_('No events')])]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
