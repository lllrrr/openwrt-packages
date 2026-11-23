'use strict';
'require view';
'require uci';
'require poll';
'require dom';
'require smartroute.common as sr';

return view.extend({
	load() {
		return Promise.all([uci.load('smartroute'), uci.load('firewall'), sr.callStatus()]);
	},

	render(data) {
		sr.css();
		const root = E('div', { 'class': 'cbi-map sr' });
		const draw = st => dom.content(root, this.build(st || {}));
		draw(data[2]);
		poll.add(() => sr.callStatus().then(draw), 5);
		return root;
	},

	build(st) {
		const on = sr.get('main', 'enabled') == '1';
		const s = st.state || {};
		const health = s.Health || {};
		const actual = id => ((s.Routes || {})[id] || {}).Actual || 'direct';
		const out = [];

		// Main switch
		const sw = E('input', { 'type': 'checkbox', 'id': 'sr-enabled', 'checked': on ? '' : null, 'change': ev => {
			uci.set('smartroute', 'main', 'enabled', ev.target.checked ? '1' : '0');
			sr.commit(ev.target.checked ? _('Enabled; takes effect after Save & Apply') : _('Disabled; takes effect after Save & Apply'));
		} });
		out.push(sr.section(null, null, null, [sr.field(_('Enable SmartRoute'), sw, null,
			_('When disabled, all traffic is forwarded as usual by this router and no rules are left behind.'))]));

		// Issues
		if (!on)
			out.push(sr.alert('notice', [E('strong', {}, [_('SmartRoute is disabled.')]), ' ', _('All traffic is forwarded as usual by this router.')]));
		else if (!st.running)
			out.push(sr.alert('warning', [E('strong', {}, [_('The steering service is not running.')]), ' ', _('If the configuration was just changed, click "Save & Apply"; otherwise see the Diagnostics tab.')]));
		(s.Exits || []).forEach(x => {
			const h = health[x.ID];
			if (on && h && !h.Up)
				out.push(sr.alert('error', [E('strong', {}, [_('Exit %s failed its checks and new connections use %s.').format(sr.exitLabel(x.ID), sr.exitLabel(actual(x.ID)))]), ' ',
					_('Existing connections through it are interrupted; it is used again automatically once it recovers.')]));
			else if (on && h && h.Up6 === false)
				out.push(sr.alert('warning', [E('strong', {}, [_('IPv6 through exit %s failed its checks.').format(sr.exitLabel(x.ID))]), ' ',
					_('IPv6 through it is rejected for now so that devices use IPv4; this ends once IPv6 recovers.')]));
			if (on && h && h.DNSUp === false)
				out.push(sr.alert('warning', [E('strong', {}, [_('The DNS server of exit %s is not responding.').format(sr.exitLabel(x.ID))]), ' ',
					_('DNS queries are handled as set for the exit until it recovers.')]));
		});
		if (on && uci.get('firewall', '@defaults[0]', 'drop_invalid') == '1' && sr.get('main', 'fix_invalid') == '0')
			out.push(sr.alert('warning', [E('strong', {}, [_('The firewall drops invalid packets'), sr.tip('invalid'), _(', so traffic forwarded to gateways is dropped.')]), ' ',
				_('The fix only allows traffic forwarded to gateways; other protection is unchanged.'), ' ',
				sr.btn(_('Fix'), 'cbi-button-action', () => { uci.set('smartroute', 'main', 'fix_invalid', '1'); sr.commit(_('Fixed; takes effect after Save & Apply')); })]));
		if (on && st.running && (s.Warnings || []).length)
			out.push(sr.alert('warning', [E('strong', {}, [_('%s configuration problem(s), the affected items are not applied:').format(s.Warnings.length)]),
				E('ul', {}, s.Warnings.map(w => sr.t('li', {}, sr.msg(w))))]));

		// Exits
		const exitRows = sr.exits().filter(e => e.id != 'reject').map(e => {
			if (e.type == 'builtin')
				return sr.tr('', [sr.td(_('Exit'), E('strong', {}, [e.name])), sr.td(_('Details'), ''), sr.td(_('Status'), sr.pill(on ? 'good' : '', on ? _('Normal') : _('Not in use')))]);
			const h = health[e.id], live = (s.Exits || []).find(x => x.ID == e.id);
			const pill = !on || !st.running ? sr.pill('', _('Not in use'))
				: !h ? sr.pill('', _('Not checked'))
				: !h.Up ? sr.pill('bad', _('Check failed · using %s').format(sr.exitLabel(actual(e.id))))
				: sr.pill(h.Up6 === false ? 'warn' : 'good', _('Normal · %s ms').format(h.RTTms.toFixed(1)) + (h.Up6 === false ? ' · ' + _('IPv6 failed') : ''));
			const detail = !live ? '' : e.type == 'gateway' ? _('IPv6 next hop %s').format(live.LL || _('not found')) : _('Device %s').format(live.Dev || _('down'));
			return sr.tr('', [sr.td(_('Exit'), [E('strong', {}, [sr.exitLabel(e.id)]), ' ', sr.t('span', { 'class': 'sr-mono sr-muted' }, e.s.ip || e.s.network || '')]),
				sr.td(_('Details'), sr.t('span', { 'class': 'sr-muted' }, detail)), sr.td(_('Status'), pill)]);
		});
		const exitSec = sr.section(_('Exits'), 'exit', null, [sr.table([_('Exit'), _('Details'), _('Status')], exitRows)]);

		// Device groups
		const groups = sr.all('group');
		const unnamed = sr.all('device').filter(d => !d.name).length;
		// 宽屏上出口与设备组并排；跳转用页面顶部的标签页，不再单独占一行放按钮
		out.push(E('div', { 'class': 'sr-cols' }, [exitSec, sr.section(_('Device groups'), 'groups', null,
			(groups.length ? [sr.table([_('Device group'), [_('Devices'), 'sr-n']], groups.map(g => sr.tr('', [
				sr.td(_('Device group'), sr.t('strong', {}, sr.name(g['.name']))), sr.td(_('Devices'), _('%s device(s)').format(sr.members(g['.name']).length), 'sr-n')])))]
				: [E('p', { 'class': 'sr-muted' }, [_('No device groups yet')])])
				.concat(unnamed ? [E('p', { 'class': 'sr-muted' }, [_('%s device(s) have no name and can only be selected through their group in policies').format(unnamed)])] : []))]));

		// Policies
		const flows = sr.all('policy');
		const hits = st.hits || {};
		out.push(sr.section(_('Policies'), 'order', null,
			[flows.length ? sr.table(['#', _('Devices'), _('Rule groups'), _('Exit'), [_('Matches today'), 'sr-n']], flows.map((f, i) => {
				const sid = f['.name'], en = sr.enabled(sid);
				return sr.tr(en ? '' : 'sr-off', [sr.td('#', String(i + 1)), sr.td(_('Devices'), sr.srcChips(sid)), sr.td(_('Rule groups'), sr.rgChips(sid)),
					sr.td(_('Exit'), sr.chip(sr.exitLabel(f.exit))), sr.td(_('Matches today'), en ? sr.fmt(hits[sid]) : _('Disabled'), 'sr-n')]);
			})) : E('p', { 'class': 'sr-muted' }, [_('No policies yet; all traffic is forwarded as usual by this router.')])]));
		return out;
	},

	handleSaveApply(ev, mode) { return sr.saveApply(mode); },
	handleSave: null,
	handleReset: null
});
