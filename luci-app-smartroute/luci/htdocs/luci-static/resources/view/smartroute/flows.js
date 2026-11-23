'use strict';
'require view';
'require uci';
'require ui';
'require dom';
'require smartroute.common as sr';

const C = 'smartroute';

return view.extend({
	load() {
		return Promise.all([uci.load(C), sr.callStatus()]);
	},

	render(data) {
		sr.css();
		this.hits = (data[1] || {}).hits || {};
		this.sel = new Set();
		this.confirmDel = null;
		this.bulkDel = false;
		this.root = E('div', { 'class': 'cbi-map sr' });
		this.draw();
		return this.root;
	},

	draw() {
		dom.content(this.root, sr.section(_('Policies'), 'order', [
			E('span', { 'class': 'sr-grow sr-muted' }, [_('Changes only affect new connections; established connections keep their exit.')]),
			sr.btn(_('New policy'), 'cbi-button-add', () => this.dialog())], [this.bulkBar(), this.table()]));
	},

	change(msg) {
		return sr.commit(msg).then(() => this.draw());
	},

	undoable(msg, fn) {
		return sr.undoable(msg, fn, () => this.draw());
	},

	flows() { return sr.all('policy').map(s => s['.name']); },

	bulkBar() {
		const n = this.sel.size;
		if (!n) return E([]);
		const ids = [...this.sel];
		if (this.bulkDel)
			return E('div', { 'class': 'sr-actions' }, [E('strong', { 'class': 'sr-grow' }, [_('Delete the %s selected policies?').format(n)]),
				sr.btn(_('Delete'), 'cbi-button-negative', () => {
					this.sel.clear();
					this.bulkDel = false;
					this.undoable(_('%s policies deleted').format(n), () => ids.forEach(id => uci.remove(C, id)));
				}),
				sr.btn(_('Cancel'), '', () => { this.bulkDel = false; this.draw(); })]);
		const exitSel = E('select', { 'class': 'cbi-input-select', 'aria-label': _('Change exit of selected'), 'change': ev => {
			const v = ev.target.value;
			if (v) this.undoable(_('Exit of %s policies changed').format(n), () => ids.forEach(id => uci.set(C, id, 'exit', v)));
		} }, [E('option', { 'value': '' }, [_('Change exit…')])].concat(sr.exits().map(e => E('option', { 'value': e.id }, [sr.exitLabel(e.id)]))));
		return E('div', { 'class': 'sr-actions' }, [E('strong', { 'class': 'sr-grow' }, [_('%s selected').format(n)]), exitSel,
			sr.btn(_('Enable'), '', () => this.undoable(_('%s policies enabled').format(n), () => ids.forEach(id => uci.unset(C, id, 'enabled')))),
			sr.btn(_('Disable'), '', () => this.undoable(_('%s policies disabled').format(n), () => ids.forEach(id => uci.set(C, id, 'enabled', '0')))),
			sr.btn(_('Delete'), 'cbi-button-negative', () => { this.bulkDel = true; this.draw(); }),
			sr.btn(_('Clear selection'), '', () => { this.sel.clear(); this.draw(); })]);
	},

	table() {
		const ids = this.flows();
		if (!ids.length) return E('p', { 'class': 'sr-muted' }, [_('No policies yet.')]);
		const all = ids.every(id => this.sel.has(id));
		const heads = [E('input', { 'type': 'checkbox', 'aria-label': _('Select all'), 'checked': all ? '' : null, 'change': ev => { ids.forEach(id => ev.target.checked ? this.sel.add(id) : this.sel.delete(id)); this.draw(); } }),
			'', '#', _('Devices'), E('span', {}, [_('Rule groups'), sr.tip('rg')]), _('Exit'), [_('Matches today'), 'sr-n'], _('Enabled'), ''];
		const rows = ids.map((id, i) => {
			const en = sr.enabled(id);
			const ops = this.confirmDel == id
				? [E('span', { 'class': 'sr-muted' }, [_('Delete?'), ' ']),
					sr.btn(_('Delete'), 'cbi-button-negative', () => {
						this.sel.delete(id);
						this.confirmDel = null;
						this.undoable(_('Policy %s deleted').format(i + 1), () => uci.remove(C, id));
					}), ' ',
					sr.btn(_('Cancel'), '', () => { this.confirmDel = null; this.draw(); })]
				: [sr.btn('↑', '', () => this.move(i, -1), { 'aria-label': _('Move up'), 'disabled': i == 0 ? '' : null }), ' ',
					sr.btn('↓', '', () => this.move(i, 1), { 'aria-label': _('Move down'), 'disabled': i == ids.length - 1 ? '' : null }), ' ',
					sr.btn(_('Edit'), 'cbi-button-edit', () => this.dialog(id)), ' ',
					sr.btn(_('Delete'), 'cbi-button-remove', () => { this.confirmDel = id; this.draw(); })];
			const tr = sr.tr(en ? '' : 'sr-off', [
				sr.td(null, E('input', { 'type': 'checkbox', 'aria-label': _('Select policy %s').format(i + 1), 'checked': this.sel.has(id) ? '' : null,
					'change': ev => { ev.target.checked ? this.sel.add(id) : this.sel.delete(id); this.draw(); } })),
				sr.td(null, '⋮⋮', 'sr-handle', { 'title': _('Drag to reorder'), 'aria-hidden': 'true' }),
				sr.td('#', String(i + 1)),
				sr.td(_('Devices'), sr.srcChips(id)),
				sr.td(_('Rule groups'), sr.rgChips(id)),
				sr.td(_('Exit'), sr.chip(sr.exitLabel(sr.get(id, 'exit')))),
				sr.td(_('Matches today'), en ? sr.fmt(this.hits[id]) : '—', 'sr-n'),
				sr.td(_('Enabled'), E('input', { 'type': 'checkbox', 'aria-label': _('Enable policy %s').format(i + 1), 'checked': en ? '' : null, 'change': ev => {
					if (ev.target.checked) uci.unset(C, id, 'enabled'); else uci.set(C, id, 'enabled', '0');
					this.change(ev.target.checked ? _('Policy enabled') : _('Policy disabled'));
				} })),
				sr.td(null, E('div', {}, ops), 'cbi-section-actions nowrap')], { 'draggable': 'true', 'data-id': id });
			// Drag to reorder: dropping on the upper half moves before the row, lower half after it
			tr.addEventListener('dragstart', ev => { ev.dataTransfer.setData('text/plain', id); ev.dataTransfer.effectAllowed = 'move'; });
			tr.addEventListener('dragover', ev => ev.preventDefault());
			tr.addEventListener('drop', ev => {
				ev.preventDefault();
				const src = ev.dataTransfer.getData('text/plain');
				if (!src || src == id) return;
				const r = tr.getBoundingClientRect();
				uci.move(C, src, id, ev.clientY > r.top + r.height / 2);
				this.change();
			});
			return tr;
		});
		return sr.table(heads, rows);
	},

	move(i, d) {
		const ids = this.flows();
		uci.move(C, ids[i], ids[i + d], d > 0);
		this.change();
	},

	dialog(sid) {
		const isNew = !sid;
		const src = isNew ? ['all'] : sr.list(sid, 'source');
		const rgs = isNew ? [] : sr.list(sid, 'rule_group');
		const all = src.indexOf('all') >= 0;
		const groups = sr.all('group'), named = sr.all('device').filter(d => d.name);
		const pickItem = (name, value, checked, label, extra, key) => E('label', { 'data-k': key.toLowerCase() }, [
			E('input', { 'type': 'checkbox', 'name': name, 'value': value, 'checked': checked ? '' : null }), sr.t('span', {}, label), sr.t('span', { 'class': 'sr-muted sr-small' }, extra)]);
		const firstExit = sr.exits().find(e => e.type != 'builtin');
		const curExit = isNew ? (firstExit ? firstExit.id : 'direct') : (sr.get(sid, 'exit') || 'direct');

		const whoBox = E('div', {}, [
			E('input', { 'type': 'text', 'class': 'cbi-input-text', 'placeholder': _('Search device groups or devices'), 'input': ev => {
				const q = ev.target.value.trim().toLowerCase();
				whoBox.querySelectorAll('.sr-pick label').forEach(l => { l.hidden = q && l.dataset.k.indexOf(q) < 0; });
			} }),
			E('div', { 'class': 'sr-pick' }, [E('h4', {}, [_('Device groups')])]
				.concat(groups.length ? groups.map(g => pickItem('g', g['.name'], src.indexOf(g['.name']) >= 0, sr.name(g['.name']), _('%s device(s)').format(sr.members(g['.name']).length), sr.name(g['.name']))) : [E('p', { 'class': 'sr-muted' }, [_('No device groups yet')])])
				.concat([E('h4', {}, [_('Named devices')])])
				.concat(named.length ? named.map(d => pickItem('d', d['.name'], src.indexOf(d['.name']) >= 0, d.name, d.mac || d.ip || '', d.name + (d.mac || '') + (d.ip || ''))) : [E('p', { 'class': 'sr-muted' }, [_('No named devices yet')])])),
			E('div', { 'class': 'cbi-value-description' }, [_('Devices must be in a device group first; unnamed devices can only be selected through their group.')])]);
		const rgBox = E('div', {}, [
			E('div', { 'class': 'sr-pick' }, sr.all('rule_group').map(r => pickItem('r', r['.name'], rgs.indexOf(r['.name']) >= 0, sr.name(r['.name']), sr.list(r['.name'], 'rule').slice(0, 2).join(', '), sr.name(r['.name'])))),
			E('label', {}, [E('input', { 'type': 'checkbox', 'id': 'sr-not', 'checked': sr.get(sid || '', 'invert') == '1' ? '' : null }), ' ', _('Invert'), sr.tip('not')])]);
		const exitSel = E('select', { 'class': 'cbi-input-select', 'id': 'sr-exit' }, sr.exits().map(e => E('option', { 'value': e.id, 'selected': e.id == curExit ? '' : null }, [sr.exitLabel(e.id)])));
		let allDev = all, someRg = rgs.length > 0;
		const sync = () => { whoBox.hidden = allDev; rgBox.hidden = !someRg; };
		const body = E('div', {}, [
			sr.field(_('Devices'), [sr.radios('sr-who', all ? 'all' : 'some', { all: E('span', {}, [_('All devices'), sr.tip('all', 'left')]), some: _('Selected device groups or devices') },
				v => { allDev = v == 'all'; sync(); }), whoBox]),
			sr.field(_('Rule groups'), [sr.radios('sr-rgm', someRg ? 'some' : 'all', { all: _('All'), some: _('Selected rule groups') },
				v => { someRg = v == 'some'; sync(); }), rgBox], 'rg'),
			sr.field(_('Exit'), exitSel, 'exit')]);
		sync();

		sr.modal(isNew ? _('New policy') : _('Edit policy'), [body], isNew ? _('Add') : _('Save'), () => {
			const checked = n => [...body.querySelectorAll('input[name=' + n + ']:checked')].map(i => i.value);
			const nsrc = allDev ? ['all'] : checked('g').concat(checked('d'));
			const nrg = someRg ? checked('r') : [];
			if (!nsrc.length) { sr.notify(_('Select at least one device group or device, or "All devices"'), 'warning'); return false; }
			if (someRg && !nrg.length) { sr.notify(_('Select at least one rule group, or "All"'), 'warning'); return false; }
			const id = sid || uci.add(C, 'policy');
			sr.setList(id, 'source', nsrc);
			sr.setList(id, 'rule_group', nrg);
			if (someRg && body.querySelector('#sr-not').checked) uci.set(C, id, 'invert', '1'); else uci.unset(C, id, 'invert');
			uci.set(C, id, 'exit', exitSel.value);
			return this.change(isNew ? _('Added; takes effect after Save & Apply') : _('Changed; takes effect after Save & Apply'));
		});
	},

	handleSaveApply(ev, mode) { return sr.saveApply(mode); },
	handleSave: null,
	handleReset: null
});
