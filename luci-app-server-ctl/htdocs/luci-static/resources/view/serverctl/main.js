'use strict';
'require form';
'require rpc';
'require ui';
'require uci';
'require view';

const callPing = rpc.declare({
	object: 'serverctl',
	method: 'ping',
	params: [ 'server' ],
	expect: {}
});

const callSSHTest = rpc.declare({
	object: 'serverctl',
	method: 'sshtest',
	params: [ 'server' ],
	expect: {}
});

const callWake = rpc.declare({
	object: 'serverctl',
	method: 'wake',
	params: [ 'server' ],
	expect: {}
});

const callSuspend = rpc.declare({
	object: 'serverctl',
	method: 'suspend',
	params: [ 'server' ],
	expect: {}
});

const callPoweroff = rpc.declare({
	object: 'serverctl',
	method: 'poweroff',
	params: [ 'server' ],
	expect: {}
});

const actionRPC = {
	ping: callPing,
	sshtest: callSSHTest,
	wake: callWake,
	suspend: callSuspend,
	poweroff: callPoweroff
};

function actionLabel(action) {
	switch (action) {
	case 'ping': return _('Ping Test');
	case 'sshtest': return _('SSH Test');
	case 'wake': return _('Wake');
	case 'suspend': return _('Suspend');
	case 'poweroff': return _('Power Off');
	}
	return action;
}

function confirmDialog(title, body) {
	return new Promise((resolve, reject) => {
		ui.showModal(title, [
			E('p', {}, body),
			E('div', { 'class': 'button-row' }, [
				E('button', {
					'class': 'btn cbi-button',
					'click': () => {
						ui.hideModal();
						reject(new Error('cancelled'));
					}
				}, _('Cancel')), ' ',
				E('button', {
					'class': 'btn cbi-button cbi-button-negative important',
					'click': () => {
						ui.hideModal();
						resolve();
					}
				}, _('Run'))
			])
		]);
	});
}

function pad2(v) {
	return ('0' + String(v)).slice(-2);
}

function nowStamp() {
	const d = new Date();
	return '%s-%s-%s %s:%s:%s'.format(
		d.getFullYear(), pad2(d.getMonth() + 1), pad2(d.getDate()),
		pad2(d.getHours()), pad2(d.getMinutes()), pad2(d.getSeconds()));
}

function getServers() {
	const list = uci.sections('serverctl', 'server').filter((s) => s['name']);

	list.sort((a, b) => (a['name'] > b['name'] ? 1 : -1));
	return list;
}

function findServer(name) {
	const list = getServers();
	for (const s of list) {
		if (s['name'] == name)
			return s;
	}
	return null;
}

/* Local stylesheet for the manual control board (scoped by .ctl-manual) */
const CTL_CSS = `
.ctl-tabs-menu,
.ctl-tabs-menu > li > a {
	color: inherit;
}

/* Argon-like themes turn both .cbi-section and the tab panes (they carry
 * data-tab-title) into shadowed cards; nested, their edges stack into a
 * double border around each tab page. Flatten the sections inside the
 * panes so only the pane keeps one card layer, separated by a hairline. */
.ctl-tabs-pane .cbi-section {
	background-color: transparent;
	border: 0;
	border-radius: 0;
	box-shadow: none;
}

.ctl-tabs-pane .cbi-section + .cbi-section {
	border-top: 1px solid rgba(128, 128, 128, 0.25);
}

/* The tab label already reads "Server Maintenance", so the section title
 * band inside that pane is redundant; drop it and keep the description. */
.ctl-tabs-pane[data-tab="servers"] .cbi-section > h3 {
	display: none;
}

/* Fuse the tab strip with the pane like argon's own tab pages do:
 * argon pulls the node following ".cbi-map > .cbi-tabmenu" up under the
 * tabs (-0.4375rem); drop the gap so the active tab rests on a single
 * continuous card, keeping the card's own rounded top corners. */
.ctl-tabs-menu {
	margin-bottom: 0;
}

.ctl-tabs-pane[data-tab-title] {
	margin-top: 0;
	padding-top: 0;
}

/* Flat tab look as in stock argon tab pages: only the active tab is a
 * raised shape resting on the card, inactive tabs are plain labels on
 * the page background. */
.ctl-tabs-menu > li {
	background-color: transparent;
	border-radius: 0.25rem 0.25rem 0 0;
}

.ctl-tabs-menu > .cbi-tab {
	background-color: var(--surface-color, rgba(128, 128, 128, 0.16));
}

/* Keep the theme's own underline, which it draws on the active/hovered
 * li itself: the li is positioned, so its border always paints above the
 * raised card. Our own anchor underline was painted below the card and
 * disappeared on desktop widths, so no extra underline is added here. */

.ctl-manual {
	margin-bottom: 1.25em;
}

.ctl-manual .ctl-body {
	max-width: 720px;
	margin: 0 auto;
	text-align: center;
}

.ctl-manual .ctl-server-row {
	display: flex;
	justify-content: center;
	align-items: center;
	gap: 0.75em;
	margin: 1.5em 0;
}

.ctl-manual .ctl-info {
	margin: 0 auto 1.5em auto;
	border-collapse: separate;
	border-spacing: 0;
	text-align: left;
	background: rgba(128, 128, 128, 0.08);
	border: 1px solid rgba(128, 128, 128, 0.4);
	border-radius: 8px;
}

.ctl-manual .ctl-info th,
.ctl-manual .ctl-info td {
	padding: 0.55em 1.25em;
	line-height: 1.8;
	font-weight: normal;
	border-bottom: 1px solid rgba(128, 128, 128, 0.25);
}

.ctl-manual .ctl-info tr:last-child th,
.ctl-manual .ctl-info tr:last-child td {
	border-bottom: 0;
}

.ctl-manual .ctl-info th {
	width: 1%;
	padding-right: 0.9em;
	text-align: right;
	white-space: nowrap;
	font-weight: bold;
}

.ctl-manual .ctl-info td {
	padding-left: 0.9em;
	padding-right: 1.4em;
	word-break: break-all;
}

.ctl-manual .ctl-info .ctl-info-value {
	font-family: monospace;
}

.ctl-manual .ctl-pass-toggle {
	margin-left: 0.75em;
}

.ctl-manual .ctl-actions {
	display: flex;
	flex-wrap: wrap;
	justify-content: center;
	gap: 0.6em;
	margin: 0 0 1.5em 0;
}

.ctl-manual .ctl-output {
	text-align: left;
	background: #1c2128;
	color: #d6e2f0;
	border: 1px solid #4a5568;
	border-radius: 6px;
	box-shadow: none;
	text-shadow: none;
	padding: 1em 1.25em;
	margin: 0 0 0.5em 0;
	min-height: 8em;
	max-height: 22em;
	overflow-y: auto;
	white-space: pre-wrap;
	word-break: break-all;
	line-height: 1.6;
}
`;

const ManualSection = form.NamedSection.extend({
	selectEl: null,
	outputEl: null,
	infoEls: null,
	passShown: false,
	buttons: null,

	render() {
		const self = this;
		const servers = getServers();

		/* Use an h3 heading rather than a legend: argon-like themes
		 * hide ".cbi-section > legend" outright, which would drop the
		 * section title from the page. */
		const heading = E('h3', {}, _('Manual Control'));

		self.buttons = [];

		if (servers.length === 0) {
			const empty = E('div', { 'class': 'alert-message warning' },
				_('No servers configured yet. Please add servers on the "%s" tab first.')
					.format(_('Server Maintenance')));

			const root = E('div', { 'class': 'cbi-section' }, [ heading, empty ]);
			root.setAttribute('data-ctl-area', this.ctlArea);
			return root;
		}

		const options = [ E('option', { value: '' }, _('— Select a server —')) ];
		for (const s of servers)
			options.push(E('option', { value: s['name'] }, s['name']));

		const select = E('select', {
			'class': 'cbi-input-select',
			'style': 'max-width:320px',
			'change': () => self.updateInfo()
		}, options);
		self.selectEl = select;

		self.infoEls = {};
		const mkrow = (key, label) => {
			const v = E('span', { 'class': 'ctl-info-value' }, '—');
			self.infoEls[key] = v;
			return E('tr', {}, [ E('th', {}, label), E('td', {}, v) ]);
		};

		const infoRows = [
			mkrow('name', _('Name')),
			mkrow('ip', _('IP Address')),
			mkrow('mac', _('MAC Address')),
			mkrow('user', _('Username'))
		];

		const passToggle = E('button', {
			'class': 'btn cbi-button-link ctl-pass-toggle',
			'click': () => {
				self.passShown = !self.passShown;
				self.updateInfo();
			}
		}, _('Show'));

		const passRow = mkrow('password', _('Password'));
		passRow.lastElementChild.appendChild(passToggle);
		infoRows.push(passRow);

		const infoTable = E('table', { 'class': 'ctl-info' }, [
			E('tbody', {}, infoRows)
		]);

		const mkbtn = (action, cls) => {
			const b = E('button', {
				'class': 'btn cbi-button cbi-button-' + cls,
				'click': () => self.handleAction(action)
			}, actionLabel(action));
			self.buttons.push(b);
			return b;
		};

		const output = E('pre', { 'class': 'ctl-output' }, '');
		self.outputEl = output;

		const body = E('div', { 'class': 'ctl-body' }, [
			E('div', { 'class': 'ctl-server-row' }, [
				E('b', {}, _('Server')), select
			]),
			infoTable,
			E('div', { 'class': 'ctl-actions' }, [
				mkbtn('ping', 'action'),
				mkbtn('sshtest', 'action'),
				mkbtn('wake', 'positive'),
				mkbtn('suspend', 'negative'),
				mkbtn('poweroff', 'negative')
			]),
			output
		]);

		const root = E('div', { 'class': 'cbi-section ctl-manual' },
			[ heading, body ]);
		root.setAttribute('data-ctl-area', this.ctlArea);
		return root;
	},

	updateInfo() {
		const name = this.selectEl.value;
		const s = name ? findServer(name) : null;
		const els = this.infoEls;

		els.name.textContent = s ? (s['name'] || '—') : '—';
		els.ip.textContent = s ? (s['ip'] || '—') : '—';
		els.mac.textContent = s ? (s['mac'] || '—') : '—';
		els.user.textContent = s ? (s['user'] || 'root') : '—';

		if (s && s['password'])
			els.password.textContent = this.passShown ? s['password'] : '••••••';
		else
			els.password.textContent = '—';

		const toggle = els.password.parentNode.querySelector('button');
		if (toggle)
			toggle.textContent = this.passShown ? _('Hide') : _('Show');
	},

	appendLine(text) {
		this.outputEl.textContent += text;
		this.outputEl.scrollTop = this.outputEl.scrollHeight;
	},

	setBusy(busy) {
		for (const b of this.buttons)
			b.disabled = busy;
	},

	handleAction(action) {
		const self = this;
		const name = this.selectEl.value;

		if (!name) {
			this.appendLine('[%s] %s\n'.format(nowStamp(), _('Please select a server first.')));
			return;
		}

		const run = () => {
			self.setBusy(true);
			self.appendLine('[%s] %s → %s\n'.format(nowStamp(), actionLabel(action), name));

			return actionRPC[action](name)
				.then((res) => {
					const code = (res && typeof res.code === 'number') ? res.code : -1;
					const out = (res && res.output) ? res.output : '';
					self.appendLine('%s (exit code %d)\n\n'.format(out, code));
				})
				.catch((err) => {
					self.appendLine('%s: %s\n\n'.format(_('Error'), err));
				})
				.then(() => {
					self.setBusy(false);
				});
		};

		if (action === 'suspend' || action === 'poweroff') {
			confirmDialog(
				_('Confirm %s').format(actionLabel(action)),
				_('Are you sure you want to %s the server "%s"?').format(actionLabel(action), name)
			).then(run, () => null);
		}
		else {
			run();
		}
	}
});

const TaggedGridSection = form.GridSection.extend({
	render() {
		return form.GridSection.prototype.render.apply(this, arguments)
			.then((node) => {
				if (node && node.setAttribute)
					node.setAttribute('data-ctl-area', this.ctlArea);
				return node;
			});
	}
});

const ServerCtlMap = form.Map.extend({
	/*
	 * Group the rendered section nodes into the two tab panes while the
	 * child nodes are being rendered, so that re-rendering the whole map
	 * (e.g. after saving a modal dialog) keeps the tab layout intact.
	 */
	renderChildren(tab_name) {
		return form.Map.prototype.renderChildren.apply(this, arguments).then((nodes) => {
			const pane1 = E('div', {
				'class': 'ctl-tabs-pane',
				'data-tab': 'ctl',
				'data-tab-title': _('Manual/Scheduled Control'),
				'data-tab-active': 'true'
			});
			const pane2 = E('div', {
				'class': 'ctl-tabs-pane',
				'data-tab': 'servers',
				'data-tab-title': _('Server Maintenance')
			});

			for (const n of nodes) {
				if (n == null)
					continue;

				if (n.nodeType === 1 && n.getAttribute('data-ctl-area') == 'server')
					pane2.appendChild(n);
				else
					pane1.appendChild(n);
			}

			const wrap = E('div', {});
			/* Inject the local stylesheet here rather than inside
			 * ManualSection: the section renders a bare "no servers"
			 * placeholder when the list is empty, which would leave
			 * the page unstyled; the map wrapper always renders. */
			wrap.appendChild(E('style', {}, CTL_CSS));
			wrap.appendChild(pane1);
			wrap.appendChild(pane2);

			this.tabPanes = [pane1, pane2];
			return [wrap];
		});
	},

	renderContents() {
		return form.Map.prototype.renderContents.apply(this, arguments).then((mapEl) => {
			if (this.tabPanes != null) {
				ui.tabs.initTabGroup(this.tabPanes);

				/* Tag the tab menu which initTabGroup() prepended right
				 * before the pane wrapper, so the local stylesheet can
				 * keep its labels readable in dark themes. */
				const menu = this.tabPanes[0].parentNode.previousElementSibling;
				if (menu != null && menu.classList != null)
					menu.classList.add('ctl-tabs-menu');

				this.tabPanes = null;
			}

			return mapEl;
		});
	}
});

return view.extend({
	load() {
		return uci.load('serverctl');
	},

	render() {
		let m, s, o;

		m = new ServerCtlMap('serverctl', _('Server Control'),
			_('Manually or on a schedule: wake, suspend or power off your LAN servers.'));

		/* --- tab 1: manual control -------------------------------- */
		s = m.section(ManualSection, 'defaults', 'serverctl', _('Manual Control'));
		s.ctlArea = 'manual';

		/* --- tab 1: scheduled tasks ------------------------------- */
		s = m.section(TaggedGridSection, 'task', _('Scheduled Tasks'),
			_('Run wake, suspend or power off actions on a server at a given time.'));
		s.ctlArea = 'task';
		s.anonymous = true;
		s.addremove = true;
		s.addbtntitle = _('Add task');
		s.modaltitle = (sid) => sid ? _('Edit task') : _('Add task');

		o = s.option(form.ListValue, 'server', _('Server'));
		o.rmempty = false;
		o.placeholder = _('— Select a server —');
		for (const srv of getServers())
			o.value(srv['name'], srv['name']);

		o = s.option(form.ListValue, 'action', _('Action'));
		o.rmempty = false;
		o.value('wake', _('Wake'));
		o.value('suspend', _('Suspend'));
		o.value('poweroff', _('Power Off'));

		o = s.option(form.ListValue, 'schedule', _('Schedule'));
		o.rmempty = false;
		o.default = 'daily';
		o.value('daily', _('Daily'));
		o.value('weekly', _('Weekly'));
		o.value('once', _('Once'));

		o = s.option(form.ListValue, 'weekday', _('Weekday'));
		o.depends('schedule', 'weekly');
		o.value('1', _('Monday'));
		o.value('2', _('Tuesday'));
		o.value('3', _('Wednesday'));
		o.value('4', _('Thursday'));
		o.value('5', _('Friday'));
		o.value('6', _('Saturday'));
		o.value('0', _('Sunday'));

		o = s.option(form.Value, 'date', _('Date (YYYY-MM-DD)'));
		o.depends('schedule', 'once');
		o.rmempty = false;
		o.validate = (sid, value) => {
			if (/^\d{4}-\d{2}-\d{2}$/.test(value || ''))
				return true;
			return _('Invalid date, expected format YYYY-MM-DD');
		};

		o = s.option(form.Value, 'hour', _('Hour (0-23)'));
		o.rmempty = false;
		o.datatype = 'range(0,23)';
		o.default = '8';

		o = s.option(form.Value, 'minute', _('Minute (0-59)'));
		o.rmempty = false;
		o.datatype = 'range(0,59)';
		o.default = '0';

		o = s.option(form.Flag, 'enabled', _('Enabled'));
		o.default = o.enabled;

		o = s.option(form.DummyValue, '_time', _('Time'));
		o.modalonly = false;
		o.textvalue = (sid) => {
			const hh = uci.get('serverctl', sid, 'hour') || '8';
			const mm = uci.get('serverctl', sid, 'minute') || '0';
			return '%s:%s'.format(pad2(hh), pad2(mm));
		};

		/* Re-read the server list from the UCI store each time the task
		 * modal opens, so servers added on the "Server Maintenance" tab
		 * without a page reload are offered right away. */
		s.addModalOptions = (modalSection) => {
			for (const opt of modalSection.children) {
				if (opt.option !== 'server')
					continue;

				opt.keylist = [];
				opt.vallist = [];

				for (const srv of getServers())
					opt.value(srv['name'], srv['name']);
			}
		};

		/* --- tab 2: server maintenance ---------------------------- */
		s = m.section(TaggedGridSection, 'server', _('Server Maintenance'),
			_('Manage the server inventory used by manual and scheduled control.'));
		s.ctlArea = 'server';
		s.anonymous = true;
		s.addremove = true;
		s.addbtntitle = _('Add server');
		s.modaltitle = (sid) => sid ? _('Edit server') : _('Add server');

		o = s.option(form.Value, 'name', _('Name'));
		o.rmempty = false;
		o.datatype = 'string';
		o.validate = (sid, value) => {
			const v = (value || '').trim();
			for (const srv of getServers()) {
				if (srv['name'] === v && srv['.name'] !== sid)
					return _('Duplicate server name');
			}
			return true;
		};

		o = s.option(form.Value, 'ip', _('IP Address'));
		o.rmempty = false;
		o.datatype = 'or(ip4addr,hostname)';

		o = s.option(form.Value, 'mac', _('MAC Address'));
		o.rmempty = false;
		o.datatype = 'macaddr';

		o = s.option(form.Value, 'user', _('Username'));
		o.default = 'root';

		o = s.option(form.Value, 'password', _('Password'));

		return m.render();
	}
});
