'use strict';
'require view';
'require uci';
'require ui';
'require dom';
'require smartroute.common as sr';

const C = 'smartroute';

return view.extend({
	load() {
		return Promise.all([uci.load(C), sr.callStatus(), sr.callCats()]);
	},

	render(data) {
		sr.css();
		this.counts = (((data[1] || {}).state || {}).Rules || {}).groups || {};
		this.setCats(data[2]);
		this.root = E('div', { 'class': 'cbi-map sr' });
		this.draw();
		return this.root;
	},

	setCats(r) {
		r = r || {};
		this.dat = r;
		this.cats = { geosite: (r.geosite || {}).codes || [], geoip: (r.geoip || {}).codes || [] };
	},

	change(msg) {
		return sr.commit(msg).then(() => this.draw());
	},

	draw() {
		dom.content(this.root, [this.datPanel(), this.groupPanel()]);
	},

	datPanel() {
		const info = f => {
			const d = this.dat[f] || {};
			return d.mtime ? [sr.pill('good', new Date(d.mtime * 1000).toLocaleString()), ' ', sr.t('span', { 'class': 'sr-muted' }, _('%s MB · %s categories').format((d.size / 1048576).toFixed(1), d.codes.length))]
				: [sr.pill('warn', _('Not downloaded yet'))];
		};
		const hour = sr.get('main', 'update_hour') || '4';
		return sr.section(_('Rule data files'), 'dat', [sr.btn(_('Update now'), 'cbi-button-action', ev => this.update(ev.target))], [
			sr.field('geosite.dat', info('geosite')),
			sr.field('geoip.dat', info('geoip')),
			sr.field(_('Automatic update'), hour == '-1' ? _('Not enabled') : _('Daily at %s:00; the old version is kept if an update fails').format(hour), null,
				_('Download addresses, update time and download exit are in the Settings tab.'))]);
	},

	// Downloads in the background; finished when the file times change (waits up to 3 minutes)
	update(btn) {
		const before = JSON.stringify([(this.dat.geosite || {}).mtime, (this.dat.geoip || {}).mtime]);
		btn.disabled = true;
		dom.content(btn, [_('Updating…')]);
		return sr.callUpdate().then(() => {
			const poll = n => new Promise(r => setTimeout(r, 3000)).then(() => sr.callCats()).then(r => {
				const now = JSON.stringify([((r || {}).geosite || {}).mtime, ((r || {}).geoip || {}).mtime]);
				if (now != before) { this.setCats(r); this.draw(); sr.notify(_('Rule data files updated')); return; }
				if (n > 0) return poll(n - 1);
				this.draw();
				sr.notify(_('No new version: already up to date, or the download failed (see Diagnostics → Recent events and the system log)'), 'warning');
			});
			return poll(60);
		});
	},

	groupPanel() {
		const groups = sr.all('rule_group');
		const used = id => sr.all('policy').filter(p => sr.list(p['.name'], 'rule_group').indexOf(id) >= 0).length;
		const rows = groups.map(g => {
			const id = g['.name'], lines = sr.list(id, 'rule'), u = used(id);
			const skipped = lines.filter(l => sr.lint(l, this.cats).k == 'skip').length;
			return sr.tr('', [
				sr.td(_('Name'), sr.t('strong', {}, sr.name(id))),
				sr.td(_('Rules'), [sr.t('span', { 'class': 'sr-mono sr-small' }, lines.slice(0, 3).join(', ') + (lines.length > 3 ? ' ' + _('… (%s in total)').format(lines.length) : '')),
					skipped ? E('div', { 'class': 'sr-lint-warn sr-small' }, [_('%s unsupported, skipped').format(skipped), sr.tip('unsupported')]) : '']),
				sr.td(_('Entries'), this.counts[id] != null ? sr.fmt(this.counts[id]) : '—', 'sr-n'),
				sr.td(_('Used by'), u ? _('%s policies').format(u) : E('span', { 'class': 'sr-muted' }, [_('Unused')]), 'sr-n'),
				sr.td(null, E('div', {}, [sr.btn(_('Edit'), 'cbi-button-edit', () => this.dialog(id)), ' ',
					sr.btn(_('Delete'), 'cbi-button-remove', () => {
						if (u) { sr.notify(_('This rule group is used by %s policies; change those policies first').format(u), 'warning'); return; }
						sr.undoable(_('Rule group "%s" deleted').format(sr.name(id)), () => uci.remove(C, id), () => this.draw());
					})]), 'cbi-section-actions nowrap')]);
		});
		return sr.section(_('Rule groups'), 'sources', [sr.btn(_('New rule group'), 'cbi-button-add', () => this.dialog())], [
			groups.length ? sr.table([_('Name'), _('Rules'), [_('Entries'), 'sr-n'], [_('Used by'), 'sr-n'], ''], rows) : E('p', { 'class': 'sr-muted' }, [_('No rule groups yet.')]),
			E('p', { 'class': 'sr-muted sr-small' }, [_('"Entries" is the number of rules after expanding categories; it is updated after Save & Apply.')])]);
	},

	dialog(id) {
		const name = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'value': id ? sr.name(id) : '', 'placeholder': _('For example: Streaming') });
		const text = E('textarea', { 'class': 'cbi-input-textarea', 'placeholder': 'geosite:netflix\ngeoip:netflix\ndomain:example.com\nfull:www.example.com\n203.0.113.0/24' });
		text.value = id ? sr.list(id, 'rule').join('\n') : '';
		const lintOut = E('div', { 'class': 'cbi-value-description' });
		const lines = () => text.value.split('\n').map(x => x.trim()).filter(x => x && x[0] != '#');
		const show = () => {
			const res = lines().map(l => Object.assign({ l: l }, sr.lint(l, this.cats)));
			const by = k => res.filter(x => x.k == k);
			const parts = [E('span', {}, [_('%s rule(s)').format(res.length)])];
			if (by('warn').length) parts.push(E('span', { 'class': 'sr-lint-warn' }, ['　' + _('%s full: treated as domain:').format(by('warn').length), sr.tip('full')]));
			if (by('skip').length) parts.push(E('span', { 'class': 'sr-lint-warn' }, ['　' + _('%s skipped: %s').format(by('skip').length, by('skip').slice(0, 2).map(x => x.l).join(', ')), sr.tip('unsupported')]));
			if (by('bad').length) parts.push(E('span', { 'class': 'sr-lint-bad' }, ['　' + _('%s invalid: %s').format(by('bad').length, by('bad').slice(0, 2).map(x => x.l + ' (' + x.msg + ')').join(', '))]));
			dom.content(lintOut, parts);
		};
		text.addEventListener('input', show);
		show();
		const template = id ? '' : sr.field(_('Start from a template'),
			E('select', { 'class': 'cbi-input-select', 'change': ev => {
				const t = sr.TEMPLATES[+ev.target.value];
				if (!t) return;
				if (!name.value.trim()) name.value = t.name;
				text.value = t.rules.join('\n');
				show();
			} }, [E('option', { 'value': '' }, [_('None')])].concat(sr.TEMPLATES.map((t, i) => E('option', { 'value': String(i) }, [t.name + ' (' + t.rules.join(', ') + ')'])))));
		const catBox = E('div', { 'class': 'sr-cats' });
		const allCats = this.cats.geosite.map(c => 'geosite:' + c).concat(this.cats.geoip.map(c => 'geoip:' + c));
		const fillCats = q => dom.content(catBox, allCats.filter(c => !q || c.indexOf(q) >= 0).slice(0, 200).map(c => E('button', { 'type': 'button', 'class': 'cbi-button', 'click': () => {
			if (lines().indexOf(c) >= 0) { sr.notify(_('Already in the list')); return; }
			text.value = (text.value.trim() ? text.value.replace(/\s+$/, '') + '\n' : '') + c;
			show();
		} }, [c])));
		fillCats('');
		sr.modal(id ? _('Edit "%s"').format(sr.name(id)) : _('New rule group'), [
			template,
			sr.field(_('Name'), name),
			sr.field(_('Rules'), [text, lintOut], 'rgfmt', _('xray routing rule format, one per line; domain and IP rules can be mixed.')),
			sr.field(_('Insert a category from the data files'), [
				allCats.length ? E('input', { 'type': 'text', 'class': 'cbi-input-text', 'placeholder': _('Search categories, for example netflix or cn'), 'input': ev => fillCats(ev.target.value.trim().toLowerCase()) })
					: E('p', { 'class': 'sr-muted' }, [_('The rule data files have not been downloaded yet.')]),
				catBox])
		], _('Save'), () => {
			const n = name.value.trim(), ls = lines();
			if (!n) { sr.notify(_('Enter a name'), 'warning'); return false; }
			if (!ls.length) { sr.notify(_('Enter at least one rule'), 'warning'); return false; }
			if (ls.some(l => sr.lint(l, this.cats).k == 'bad')) { sr.notify(_('Some rules are invalid; correct them before saving'), 'warning'); return false; }
			if (sr.all('rule_group').some(g => g['.name'] != id && sr.name(g['.name']) == n)) { sr.notify(_('A rule group with this name already exists'), 'warning'); return false; }
			const sid = id || uci.add(C, 'rule_group', sr.newName('r'));
			uci.set(C, sid, 'name', n);
			sr.setList(sid, 'rule', ls);
			return this.change(_('Saved; takes effect after Save & Apply'));
		});
	},

	handleSaveApply(ev, mode) { return sr.saveApply(mode); },
	handleSave: null,
	handleReset: null
});
