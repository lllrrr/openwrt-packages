'use strict';
'require view';
'require uci';
'require ui';
'require dom';
'require smartroute.common as sr';

const C = 'smartroute';

return view.extend({
	load() {
		return Promise.all([uci.load(C), sr.callScan(), sr.callStatus()]);
	},

	render(data) {
		sr.css();
		this.scan = data[1] || [];
		this.links = {};
		(((data[2] || {}).state || {}).Links || []).forEach(l => { if (l.MAC) this.links[l.IP] = l.MAC; });
		this.sel = new Set();
		// 收起的设备组记在浏览器里（读写失败时全部展开）
		try { this.closed = new Set(JSON.parse(localStorage.getItem('sr-groups-closed') || '[]')); } catch (e) { this.closed = new Set(); }
		this.grpDel = null;
		this.root = E('div', { 'class': 'cbi-map sr' });
		this.draw();
		return this.root;
	},

	change(msg) {
		return sr.commit(msg).then(() => this.draw());
	},

	undoable(msg, fn) {
		return sr.undoable(msg, fn, () => this.draw());
	},

	// ---------- live device information ----------
	typeOf(d) { return d.type || (d.mac ? 'mac' : 'ip'); },
	isCidr(d) { return this.typeOf(d) == 'ip' && (d.ip || '').indexOf('/') >= 0; },
	scanBy(k, v) { return v ? this.scan.find(s => s[k] == String(v).toLowerCase()) : null; },
	scanOf(d) { return this.typeOf(d) == 'mac' ? this.scanBy('mac', d.mac) : this.scanBy('ip', d.ip); },
	curIp(d) { if (this.typeOf(d) == 'mac') { const s = this.scanBy('mac', d.mac); return s ? s.ip : d.ip; } return d.ip; },
	linkedMac(d) {
		if (this.typeOf(d) == 'mac') return d.mac;
		if (this.isCidr(d)) return null;
		const s = this.scanBy('ip', d.ip);
		return this.links[d.ip] || (s && s.mac) || null;
	},
	online(d) {
		if (this.isCidr(d)) return null;
		const s = this.scanOf(d);
		return !!(s && s.online);
	},
	vendorCell(mac, s) {
		if (sr.isRandomMac(mac)) return E('span', {}, [sr.pill('warn', _('Random MAC')), sr.tip('random', 'right')]);
		return sr.t('span', { 'class': 'sr-muted' }, (s && s.vendor) || '—');
	},
	// Devices selected directly in policies
	referenced(did) { return sr.all('policy').some(p => sr.list(p['.name'], 'source').indexOf(did) >= 0); },

	draw() {
		const groups = sr.all('group');
		dom.content(this.root, [sr.section(_('Device groups'), 'groups', [sr.btn(_('New device group'), 'cbi-button-add', () => this.groupDialog())],
			[this.bulkBar(groups)].concat(groups.length ? [] : [E('p', { 'class': 'sr-muted' }, [_('No device groups yet. Create one, then add devices to it.')])]))]
			.concat(groups.map(g => this.group(g))));
	},

	group(g) {
		const gid = g['.name'], ms = sr.members(gid), closed = this.closed.has(gid);
		const title = sr.name(gid) + ' · ' + _('%s device(s)').format(ms.length);
		const actions = this.grpDel == gid
			? [E('strong', { 'class': 'sr-grow' }, [_('Delete "%s"? Devices only in this group are no longer remembered (their network access is not affected).').format(sr.name(gid))]),
				sr.btn(_('Delete'), 'cbi-button-negative', () => this.deleteGroup(gid)), sr.btn(_('Cancel'), '', () => { this.grpDel = null; this.draw(); })]
			: [sr.btn(closed ? _('Expand') : _('Collapse'), '', () => {
					closed ? this.closed.delete(gid) : this.closed.add(gid);
					try { localStorage.setItem('sr-groups-closed', JSON.stringify([...this.closed])); } catch (e) {}
					this.draw();
				}, { 'aria-expanded': closed ? 'false' : 'true' }),
				sr.btn(_('Add devices'), 'cbi-button-add', () => this.addDialog(gid)),
				sr.btn(_('Rename'), '', () => this.groupDialog(gid)),
				sr.btn(_('Delete'), 'cbi-button-remove', () => {
					if (sr.all('policy').some(p => sr.list(p['.name'], 'source').indexOf(gid) >= 0)) { sr.notify(_('This device group is used by policies; change those policies first'), 'warning'); return; }
					this.grpDel = gid; this.draw();
				})];
		if (closed) return sr.section(title, null, actions, []);
		if (!ms.length) return sr.section(title, null, actions, [E('p', { 'class': 'sr-muted' }, [_('No devices in this group. Click "Add devices" to choose from the scan.')])]);
		const key = d => gid + '|' + d['.name'];
		const allSel = ms.every(d => this.sel.has(key(d)));
		const rows = ms.map(d => {
			const k = key(d), on = this.online(d), mac = this.linkedMac(d), typ = this.typeOf(d);
			const others = sr.list(d['.name'], 'group').filter(x => x != gid);
			return sr.tr('', [
				sr.td(null, E('input', { 'type': 'checkbox', 'aria-label': _('Select %s').format(sr.devLabel(d)), 'checked': this.sel.has(k) ? '' : null,
					'change': ev => { ev.target.checked ? this.sel.add(k) : this.sel.delete(k); this.draw(); } })),
				sr.td(_('Name'), [
					d.name ? sr.t('span', {}, d.name) : E('span', { 'class': 'sr-muted' }, [_('Unnamed')]),
					E('button', { 'class': 'sr-iconbtn', 'type': 'button', 'title': d.name ? _('Rename') : _('Name'), 'aria-label': (d.name ? _('Rename %s') : _('Name %s')).format(sr.devLabel(d)), 'click': () => this.nameDialog(d) }, ['✎']),
					others.length ? sr.t('span', { 'class': 'sr-muted sr-small' }, ' ' + _('+%s group(s)').format(others.length)) : ''], '', { 'title': others.length ? _('Also in: %s').format(others.map(x => sr.name(x)).join(', ')) : '' }),
				sr.td(_('Rule type'), this.typeCell(d)),
				sr.td('MAC', typ == 'mac' ? (d.mac || '') : mac ? sr.t('span', { 'class': 'sr-muted', 'title': _('MAC linked through the IP') }, mac) : '—', 'sr-mono'),
				sr.td(_('Current IP / range'), this.curIp(d) || '—', 'sr-mono'),
				sr.td('IPv6', this.v6Cell(d, mac)),
				sr.td(_('Device vendor'), mac ? this.vendorCell(mac, this.scanBy('mac', mac)) : '—'),
				sr.td(_('Status'), on === null ? sr.pill('', _('Range')) : on ? sr.pill('good', _('Online')) : sr.pill('', _('Offline')))]);
		});
		return sr.section(title, null, actions, [sr.table([
			E('input', { 'type': 'checkbox', 'aria-label': _('Select all of "%s"').format(sr.name(gid)), 'checked': allSel ? '' : null,
				'change': ev => { ms.forEach(d => ev.target.checked ? this.sel.add(key(d)) : this.sel.delete(key(d))); this.draw(); } }),
			_('Name'), E('span', {}, [_('Rule type'), sr.tip('ident')]), 'MAC', E('span', {}, [_('Current IP / range'), sr.tip('curip')]),
			E('span', {}, ['IPv6', sr.tip('v6col')]), E('span', {}, [_('Device vendor'), sr.tip('vendor')]), _('Status')], rows)]);
	},

	typeCell(d) {
		if (this.isCidr(d)) return sr.pill('', _('IP rule (range)'));
		const mac = this.linkedMac(d), ip = this.curIp(d), typ = this.typeOf(d);
		return E('select', { 'class': 'cbi-input-select', 'aria-label': _('Rule type'), 'change': ev => this.setType(d, ev.target.value) }, [
			E('option', { 'value': 'mac', 'selected': typ == 'mac' ? '' : null, 'disabled': mac ? null : '' }, [_('MAC rule')]),
			E('option', { 'value': 'ip', 'selected': typ == 'ip' ? '' : null, 'disabled': ip && ip.indexOf('/') < 0 ? null : '' }, [_('IP rule')])]);
	},

	v6Cell(d, mac) {
		if (this.typeOf(d) == 'mac') return [sr.pill('good', _('Matched by MAC'))];
		if (this.isCidr(d)) return [sr.pill('', d.ip.indexOf(':') >= 0 ? _('Matched by range') : _('IPv4 range only'))];
		return mac ? [sr.pill('good', _('Linked')), ' ', E('button', { 'class': 'sr-iconbtn', 'type': 'button', 'click': () => this.setType(d, 'mac') }, [_('Change to MAC rule')])]
			: [E('span', {}, [sr.pill('warn', _('IPv4 only')), sr.tip('v6none', 'right')])];
	},

	setType(d, type) {
		const sid = d['.name'];
		const v = type == 'mac' ? this.linkedMac(d) : this.curIp(d);
		if (!v || (type == 'ip' && v.indexOf('/') >= 0)) {
			sr.notify(type == 'mac' ? _('The MAC of this device is unknown, it cannot be changed to a MAC rule') : _('This device has no usable IP address'), 'warning');
			return this.draw();
		}
		return this.undoable(type == 'mac' ? _('Changed to MAC rule') : _('Changed to IP rule'), () => {
			uci.set(C, sid, type, v);
			uci.set(C, sid, 'type', type);
		});
	},

	nameUsed(name, exceptSid) {
		return sr.all('device').some(d => d['.name'] != exceptSid && d.name == name);
	},

	nameDialog(d) {
		const inp = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'value': d.name || '', 'placeholder': _('Enter a name') });
		sr.modal(d.name ? _('Rename device') : _('Name device'), [sr.field(d.mac || d.ip || '', inp)], _('OK'), () => {
			const v = inp.value.trim();
			if (v && this.nameUsed(v, d['.name'])) { sr.notify(_('The name is used by another device'), 'warning'); return false; }
			if (!v && this.referenced(d['.name'])) { sr.notify(_('This device is selected directly in a policy, its name cannot be empty'), 'warning'); return false; }
			if (v) uci.set(C, d['.name'], 'name', v); else uci.unset(C, d['.name'], 'name');
			return this.change(_('Name saved'));
		});
		setTimeout(() => inp.focus(), 50);
	},

	groupDialog(gid) {
		const inp = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'value': gid ? sr.name(gid) : '', 'placeholder': _('For example: TV boxes') });
		sr.modal(gid ? _('Rename device group') : _('New device group'), [sr.field(_('Name'), inp)], _('OK'), () => {
			const v = inp.value.trim();
			if (!v) { sr.notify(_('The name cannot be empty'), 'warning'); return false; }
			if (sr.all('group').some(g => g['.name'] != gid && sr.name(g['.name']) == v)) { sr.notify(_('A device group with this name already exists'), 'warning'); return false; }
			const id = gid || uci.add(C, 'group', sr.newName('g'));
			uci.set(C, id, 'name', v);
			return this.change(gid ? _('Renamed') : _('Device group "%s" created').format(v));
		});
		setTimeout(() => inp.focus(), 50);
	},

	// Remove [group, device] pairs; a device in no group is forgotten. Devices selected directly in policies must stay in at least one group
	takeOut(pairs) {
		const after = {};
		sr.all('device').forEach(d => { after[d['.name']] = sr.list(d['.name'], 'group'); });
		pairs.forEach(([g, did]) => { after[did] = (after[did] || []).filter(x => x != g); });
		const blocked = Object.keys(after).find(did => !after[did].length && this.referenced(did));
		if (blocked) { sr.notify(_('"%s" is selected directly in a policy and must stay in at least one device group').format(sr.devLabel(uci.get(C, blocked))), 'warning'); return null; }
		return () => Object.keys(after).forEach(did => { if (after[did].length) sr.setList(did, 'group', after[did]); else uci.remove(C, did); });
	},

	deleteGroup(gid) {
		const out = this.takeOut(sr.members(gid).map(d => [gid, d['.name']]));
		if (!out) return;
		this.grpDel = null;
		[...this.sel].filter(k => k.startsWith(gid + '|')).forEach(k => this.sel.delete(k));
		this.undoable(_('Device group "%s" deleted').format(sr.name(gid)), () => { out(); uci.remove(C, gid); });
	},

	bulkBar(groups) {
		const n = this.sel.size;
		if (!n) return E([]);
		const pairs = () => [...this.sel].map(k => k.split('|'));
		const pick = (label, fn) => E('select', { 'class': 'cbi-input-select', 'aria-label': label, 'change': ev => { if (ev.target.value) fn(ev.target.value); } },
			[E('option', { 'value': '' }, [label + '…'])].concat(groups.map(g => E('option', { 'value': g['.name'] }, [sr.name(g['.name'])]))));
		const copyTo = to => {
			const ps = pairs();
			this.sel.clear();
			this.undoable(_('%s device(s) copied to "%s"').format(n, sr.name(to)),
				() => ps.forEach(([, did]) => { const gs = sr.list(did, 'group'); if (gs.indexOf(to) < 0) sr.setList(did, 'group', gs.concat([to])); }));
		};
		const moveTo = to => {
			const ps = pairs();
			this.sel.clear();
			this.undoable(_('%s device(s) moved to "%s"').format(n, sr.name(to)),
				() => ps.forEach(([g, did]) => { const gs = sr.list(did, 'group').filter(x => x != g); if (gs.indexOf(to) < 0) gs.push(to); sr.setList(did, 'group', gs); }));
		};
		return E('div', { 'class': 'sr-actions' }, [E('strong', { 'class': 'sr-grow' }, [_('%s selected').format(n)]), pick(_('Copy to'), copyTo), pick(_('Move to'), moveTo),
			sr.btn(_('Remove from group'), 'cbi-button-negative', () => {
				const out = this.takeOut(pairs());
				if (!out) return;
				this.sel.clear();
				this.undoable(_('%s device(s) removed from their group').format(n), out);
			}),
			sr.btn(_('Clear selection'), '', () => { this.sel.clear(); this.draw(); })]);
	},

	addDialog(gid) {
		const devs = sr.all('device');
		const findDev = s => devs.find(d => (this.typeOf(d) == 'mac' && (d.mac || '').toLowerCase() == s.mac) || (this.typeOf(d) == 'ip' && d.ip == s.ip));
		const body = E('div', {});
		const rows = E('tbody', {});
		const fill = () => {
			dom.content(rows, this.scan.map((s, i) => {
				const d = findDev(s), inThis = d && sr.list(d['.name'], 'group').indexOf(gid) >= 0;
				return sr.tr('', [
					sr.td(null, E('input', { 'type': 'checkbox', 'name': 's', 'value': String(i), 'checked': inThis ? '' : null, 'disabled': inThis ? '' : null, 'aria-label': _('Select %s').format(s.mac) })),
					sr.td(_('Name'), d ? [d.name ? sr.t('span', {}, d.name) : E('span', { 'class': 'sr-muted' }, [_('Unnamed')]), ' ', sr.t('span', { 'class': 'sr-muted sr-small' }, inThis ? _('Already in this group') : _('In another group'))]
						: [E('input', { 'type': 'text', 'class': 'cbi-input-text', 'name': 'n' + i, 'value': s.host || '', 'placeholder': _('Optional'), 'aria-label': _('Name of %s').format(s.mac),
							'input': ev => { const cb = ev.target.closest('tr').querySelector('input[name=s]'); if (ev.target.value.trim()) cb.checked = true; } })]),
					sr.td(_('Rule type'), d ? sr.pill('', this.typeOf(d) == 'mac' ? _('MAC rule') : _('IP rule'))
						: E('select', { 'class': 'cbi-input-select', 'name': 't' + i, 'aria-label': _('Rule type of %s').format(s.mac) }, [E('option', { 'value': 'mac' }, [_('MAC rule')]), E('option', { 'value': 'ip' }, [_('IP rule')])])),
					sr.td('MAC', s.mac, 'sr-mono'),
					sr.td('IP', s.ip || '—', 'sr-mono'),
					sr.td(_('Device vendor'), this.vendorCell(s.mac, s)),
					sr.td(_('Status'), s.online ? sr.pill('good', _('Online')) : sr.pill('', _('Offline')))], { 'data-k': [s.host, s.mac, s.ip, s.vendor, d ? d.name : ''].join(' ').toLowerCase() });
			}));
			if (!this.scan.length) dom.content(rows, sr.tr('placeholder', [sr.td(null, _('No devices found'), 'sr-muted', { 'colspan': '7' })]));
		};
		fill();
		const rescan = sr.btn(_('Scan again'), '', ev => {
			ev.target.disabled = true;
			return sr.callScan().then(r => { this.scan = r || []; fill(); sr.notify(_('Scan finished, %s device(s) found').format(this.scan.length)); }).finally(() => { ev.target.disabled = false; });
		});
		const text = E('textarea', { 'class': 'cbi-input-textarea', 'style': 'min-height:80px', 'placeholder': _('Format: address name (name optional)') + '\n192.168.1.201 ' + _('Printer') + '\n10.8.0.0/24 ' + _('Office VPN') });
		const count = E('div', { 'class': 'cbi-value-description' }, [_('MAC, IP or range, one per line; paste several at once. MAC addresses are added as MAC rules, IPs and ranges as IP rules.'), sr.tip('cidr', 'left')]);
		const parse = () => text.value.split('\n').map(l => l.trim()).filter(Boolean).map(l => {
			const p = l.split(/\s+/), a = p.shift();
			return { a: a.toLowerCase(), name: p.join(' '), kind: sr.addrKind(a) };
		});
		text.addEventListener('input', () => {
			const p = parse(), bad = p.filter(x => !x.kind);
			dom.content(count, [_('%s line(s)').format(p.length) + (bad.length ? _(', %s not recognised: %s').format(bad.length, bad.slice(0, 2).map(x => x.a).join(', ')) : '')]);
			count.classList.toggle('sr-lint-bad', bad.length > 0);
		});
		dom.content(body, [
			sr.field([_('Devices found'), sr.tip('scan', 'left')], [
				E('div', { 'class': 'sr-actions' }, [E('input', { 'type': 'text', 'class': 'cbi-input-text sr-grow', 'placeholder': _('Search name, MAC, IP or vendor'), 'input': ev => {
					const q = ev.target.value.trim().toLowerCase();
					rows.querySelectorAll('tr[data-k]').forEach(tr => { tr.hidden = q && tr.dataset.k.indexOf(q) < 0; });
				} }), rescan]),
				// 不放进可滚动的容器：有的主题让表头吸顶，在滚动容器里会压住第一行；对话框本身可滚动
				E('table', { 'class': 'table cbi-section-table' }, [
					E('thead', {}, [E('tr', { 'class': 'tr table-titles cbi-section-table-titles' }, ['', _('Name'), E('span', {}, [_('Rule type'), sr.tip('ident')]), 'MAC', 'IP', _('Device vendor'), _('Status')].map(h => E('th', { 'class': 'th' }, [h])))]),
					rows])], null, _('Names default to the host name reported by the device and can be changed.')),
			sr.field(_('Add manually'), [text, count])]);

		sr.modal(_('Add devices to "%s"').format(sr.name(gid)), [body], _('Add'), () => {
			const picks = [...body.querySelectorAll('input[name=s]:checked:not(:disabled)')].map(i => +i.value);
			const p = parse();
			if (!picks.length && !p.length) { sr.notify(_('Select scanned devices or add them manually'), 'warning'); return false; }
			if (p.some(x => !x.kind)) { sr.notify(_('Some manual lines are not recognised; correct them first'), 'warning'); return false; }
			const nameOf = i => { const el = body.querySelector('[name=n' + i + ']'); return el ? el.value.trim() : ''; };
			const names = picks.map(nameOf).concat(p.map(x => x.name)).filter(Boolean);
			const dup = names.find((n, i) => names.indexOf(n) != i || this.nameUsed(n));
			if (dup) { sr.notify(_('The name "%s" is already used').format(dup), 'warning'); return false; }
			const types = picks.map(i => { const el = body.querySelector('[name=t' + i + ']'); return el ? el.value : null; });
			let added = 0, skipped = 0;
			const join = did => { const gs = sr.list(did, 'group'); if (gs.indexOf(gid) >= 0) { skipped++; return; } sr.setList(did, 'group', gs.concat([gid])); added++; };
			const create = (type, mac, ip, name) => {
				const id = uci.add(C, 'device', sr.newName('d'));
				uci.set(C, id, 'type', type);
				if (mac) uci.set(C, id, 'mac', mac);
				if (ip) uci.set(C, id, 'ip', ip);
				if (name) uci.set(C, id, 'name', name);
				sr.setList(id, 'group', [gid]);
				added++;
			};
			this.closed.delete(gid);
			return this.undoable(_('Devices added to "%s"').format(sr.name(gid)), () => {
				picks.forEach((i, j) => {
					const s = this.scan[i], d = findDev(s);
					if (d) return join(d['.name']);
					create(types[j], types[j] == 'mac' ? s.mac : null, s.ip, nameOf(i));
				});
				p.forEach(x => {
					const d = sr.all('device').find(d => x.kind == 'mac' ? (d.mac || '').toLowerCase() == x.a && this.typeOf(d) == 'mac' : d.ip == x.a && this.typeOf(d) == 'ip');
					if (d) return join(d['.name']);
					create(x.kind, x.kind == 'mac' ? x.a : null, x.kind == 'ip' ? x.a : null, x.name);
				});
			});
		});
	},

	handleSaveApply(ev, mode) { return sr.saveApply(mode); },
	handleSave: null,
	handleReset: null
});
