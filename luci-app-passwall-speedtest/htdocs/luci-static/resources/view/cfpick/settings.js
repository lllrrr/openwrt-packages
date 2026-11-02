'use strict';
'require view';
'require form';
'require poll';
'require rpc';
'require ui';
'require uci';

const callReset = rpc.declare({
	object: 'cfpick',
	method: 'api_web_reset',
	expect: {}
});

const callStatus = rpc.declare({
	object: 'cfpick',
	method: 'api_status',
	expect: {}
});

const callUpdateStatus = rpc.declare({
	object: 'cfpick',
	method: 'api_update_status',
	expect: {}
});

const callUpdateStart = rpc.declare({
	object: 'cfpick',
	method: 'api_update_start',
	expect: {}
});

const callUpdateCheck = rpc.declare({
	object: 'cfpick',
	method: 'api_update_check',
	expect: {}
});

function updateSection(initialStatus, initialUpdate) {
	const state = {
		running: !!(initialStatus && initialStatus.running),
		update: initialUpdate || {},
		checking: false,
		check: { checked: false, latest: '', available: false, error: '' }
	};

	const statusText = E('span', {}, _('Ready to update.'));
	const versionText = E('span', { 'class': 'cbi-value-description' }, '');
	const checkButton = E('button', {
		type: 'button',
		'class': 'btn cbi-button'
	}, _('Check for updates'));
	const button = E('button', {
		type: 'button',
		'class': 'btn cbi-button cbi-button-apply'
	}, _('Online update'));
	const reloadButton = E('button', {
		type: 'button',
		'class': 'btn cbi-button',
		style: 'display:none'
	}, _('Refresh page'));

	reloadButton.addEventListener('click', function() {
		window.location.reload();
	});

	function render() {
		const update = state.update || {};
		const busy = !!update.updating;
		const current = update.current_version || '';

		button.disabled = state.running || busy || !state.check.available;
		button.textContent = busy ? _('Updating…') : _('Online update');
		checkButton.disabled = state.running || busy || state.checking;
		checkButton.textContent = state.checking ? _('Checking…') : _('Check for updates');

		statusText.textContent = update.message
			|| (state.running
				? _('A speed test is running; stop it before updating.')
				: _('Ready to update.'));

		let info = _('Current version') + ': ' + (current || '—');
		if (state.check.checked) {
			if (state.check.error)
				info += ' · ' + state.check.error;
			else
				info += ' · ' + _('Latest version') + ': ' + (state.check.latest || '—') +
					' · ' + (state.check.available ? _('Update available') : _('Already up to date'));
		}
		versionText.textContent = info;
		reloadButton.style.display = (!busy && update.ok === true) ? '' : 'none';
	}

	function refresh() {
		return Promise.all([
			L.resolveDefault(callStatus(), null),
			L.resolveDefault(callUpdateStatus(), null)
		]).then(function(results) {
			const status = results[0] || {};
			const update = results[1] || {};
			const wasUpdating = !!(state.update && state.update.updating);

			state.running = !!(status.ok === true && status.data && status.data.running);
			state.update = (update.ok === true && update.data) ? update.data : {};

			if (wasUpdating && !state.update.updating && state.update.ok) {
				state.check = { checked: false, latest: '', available: false, error: '' };
				ui.addNotification(null, E('p', {},
					_('Update finished. Refresh the page to use the new version.')));
				runCheck();
			}

			render();
		}).catch(function() {});
	}

	function runCheck() {
		if (state.running || state.checking || (state.update && state.update.updating))
			return Promise.resolve();

		state.checking = true;
		state.check = { checked: false, latest: '', available: false, error: '' };
		render();

		return callUpdateCheck().then(function(result) {
			if (!result || result.ok !== true)
				throw new Error((result && result.error) || _('Request failed'));

			const data = result.data || {};
			if (data.ok === false)
				throw new Error(data.error || _('Check failed'));

			state.check = {
				checked: true,
				latest: data.latest || '',
				available: !!data.available,
				error: ''
			};
		}).catch(function(e) {
			state.check = {
				checked: true,
				latest: '',
				available: false,
				error: (e && e.message) || _('Check failed')
			};
		}).then(function() {
			state.checking = false;
			render();
		});
	}

	checkButton.addEventListener('click', runCheck);

	button.addEventListener('click', function() {
		if (!state.check.available || state.running || (state.update && state.update.updating))
			return;

		if (!confirm(_('Download and install the latest GitHub release? The page may reload after the update.')))
			return;

		button.disabled = true;
		callUpdateStart().then(function(result) {
			if (!result || result.ok !== true)
				throw new Error((result && result.error) || _('Request failed'));
			if (result.data && result.data.started === false)
				throw new Error(result.data.error || _('Update refused'));

			ui.addNotification(null, E('p', {}, _('Update started.')));
			state.update = { updating: true, message: _('Starting…') };
			render();
			return refresh();
		}).catch(function(e) {
			ui.addNotification(null, E('p', {}, e.message || _('Request failed')));
			render();
		});
	});

	poll.add(refresh, 3);
	render();

	return E('div', { 'class': 'cbi-section' }, [
		E('h3', {}, _('Online update')),
		E('p', { 'class': 'cbi-section-descr', style: 'margin-bottom:8px' },
			_('Check the latest GitHub release; the update button is enabled only when a newer version is available.')),
		E('div', { 'class': 'cbi-value' }, [
			E('label', { 'class': 'cbi-value-title' }, _('Update status')),
			E('div', { 'class': 'cbi-value-field' }, [
				E('div', { style: 'display:flex;flex-wrap:wrap;align-items:center;gap:4px 12px' }, [
					statusText,
					versionText
				]),
				E('div', { style: 'display:flex;flex-wrap:wrap;gap:8px;margin-top:8px' }, [
					checkButton,
					button,
					reloadButton
				])
			])
		])
	]);
}

function consoleUrl() {
	const port = uci.get('cfpick', 'global', 'web_port') || '17544';
	const host = window.location.hostname.indexOf(':') >= 0
		? '[' + window.location.hostname + ']' : window.location.hostname;

	return 'http://' + host + ':' + port + '/';
}

return view.extend({
	load: function() {
		return Promise.all([
			uci.load('cfpick'),
			L.resolveDefault(callStatus(), null),
			L.resolveDefault(callUpdateStatus(), null)
		]);
	},

	render: function(data) {
		let m, s, o;
		const status = (data[1] && data[1].ok === true) ? data[1].data : {};
		const update = (data[2] && data[2].ok === true) ? data[2].data : {};

		m = new form.Map('cfpick', _('Settings'),
			_('This page only configures the standalone web console entry. All speed-test settings and operations are in the console.'));

		s = m.section(form.NamedSection, 'global', 'global');
		s.addremove = false;

		o = s.option(form.Flag, 'web_enabled', _('Enable standalone console'),
			_('Starts the separate console on its own port with its own admin login.'));
		o.default = o.disabled;
		o.rmempty = false;

		o = s.option(form.Value, 'web_port', _('Console port'),
			_('Default 17544 avoids the LuCI web port and Lucky\'s usual 17543.'));
		o.datatype = 'port';
		o.default = '17544';
		o.rmempty = false;

		o = s.option(form.Value, 'web_bind', _('Listen address'),
			_('0.0.0.0 listens on all interfaces (LAN access; WAN is still blocked by the firewall).'));
		o.default = '0.0.0.0';
		o.rmempty = false;

		o = s.option(form.Value, 'web_user', _('Console username'),
			_('The password is created on the console\'s first-run page and changed from the console settings.'));
		o.default = 'admin';
		o.rmempty = false;

		o = s.option(form.Value, 'web_timeout', _('Session timeout (seconds)'),
			_('How long a console login stays valid. Default 3600 seconds.'));
		o.datatype = 'uinteger';
		o.default = '3600';

		o = s.option(form.Button, '_open', _('Open web console'),
			_('Opens the standalone console in a new tab.'));
		o.onclick = function() {
			const input = document.querySelector('[name="cbid.cfpick.global.web_port"]');
			const port = (input && input.value) || '17544';
			const host = window.location.hostname.indexOf(':') >= 0
				? '[' + window.location.hostname + ']' : window.location.hostname;

			window.open('http://' + host + ':' + port + '/', '_blank');
		};

		o = s.option(form.Button, '_reset', _('Reset console password'),
			_('Forgets the console admin password and invalidates existing console sessions. The next console visit asks you to create a new password.'));
		o.onclick = function() {
			if (!confirm(_('Reset the console password? The next console visit will ask for a new one.')))
				return;

			return callReset().then(function(result) {
				if (!result || result.ok !== true)
					throw new Error((result && result.error) || _('Request failed'));

				ui.addNotification(null, E('p', {},
					_('Console password reset. Open the console to create a new one.')));
			}).catch(function(e) {
				ui.addNotification(null, E('p', {}, e.message || _('Request failed')));
			});
		};

		const section = updateSection(status, update);
		const rendered = m.render();

		// LuCI's form.Map.render() returns a Promise in some releases and a
		// DOM node in others; support both instead of calling appendChild
		// blindly (that produced "node.appendChild is not a function").
		if (rendered && typeof rendered.appendChild === 'function') {
			rendered.appendChild(section);
			return rendered;
		}

		return Promise.resolve(rendered).then(function(node) {
			node.appendChild(section);
			return node;
		});
	}
});
