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
	const initial = initialUpdate || {};
	const state = {
		running: !!(initialStatus && initialStatus.running),
		stage: initial.updating ? 'updating' : 'idle',
		current: initial.current_version || '',
		latest: '',
		justUpdated: false,
		error: ''
	};

	const currentText = E('span', { style: 'font-variant-numeric:tabular-nums' }, state.current || '—');
	const latestText = E('span', { style: 'font-variant-numeric:tabular-nums' }, '—');
	const actionButton = E('button', {
		type: 'button',
		'class': 'btn cbi-button cbi-button-apply'
	}, _('Check for updates'));
	const hintText = E('span', { 'class': 'cbi-value-description' });
	hintText.hidden = true;

	function render() {
		const busy = state.stage === 'checking' || state.stage === 'updating';
		let label = '';
		let disabled = busy || state.stage === 'done';
		let hint = '';

		switch (state.stage) {
		case 'idle':
			label = _('Check for updates');
			break;
		case 'checking':
			label = _('Checking…');
			break;
		case 'available':
			label = _('Online update');
			if (state.running) {
				hint = _('A speed test is running; stop it before updating.');
				disabled = true;
			}
			break;
		case 'updating':
			label = _('Updating…');
			break;
		case 'done':
			label = _('Update finished');
			hint = state.justUpdated ? _('Refresh the page to use the new version.') : '';
			break;
		case 'error':
			label = _('Check for updates');
			hint = state.error || _('Check failed');
			break;
		}

		currentText.textContent = state.current || '—';
		latestText.textContent = state.latest || '—';
		actionButton.textContent = label;
		actionButton.disabled = disabled;
		actionButton.className = 'btn cbi-button ' +
			((state.stage === 'idle' || state.stage === 'available' || state.stage === 'error')
				? 'cbi-button-apply' : '');
		hintText.textContent = hint;
		hintText.hidden = !hint;
	}

	function refresh() {
		return Promise.all([
			L.resolveDefault(callStatus(), null),
			L.resolveDefault(callUpdateStatus(), null)
		]).then(function(results) {
			const status = results[0] || {};
			const update = results[1] || {};
			const data = (update.ok === true && update.data) ? update.data : {};

			state.running = !!(status.ok === true && status.data && status.data.running);
			if (data.current_version)
				state.current = data.current_version;

			if (data.updating) {
				state.stage = 'updating';
			}
			else if (state.stage === 'updating') {
				if (data.ok) {
					state.stage = 'done';
					state.justUpdated = true;
					state.latest = state.latest || state.current;
					ui.addNotification(null, E('p', {},
						_('Update finished. Refresh the page to use the new version.')));
				}
				else {
					state.stage = 'error';
					state.error = data.message || _('Update failed');
				}
			}

			render();
		}).catch(function() {});
	}

	function runCheck() {
		if (state.stage !== 'idle' && state.stage !== 'error')
			return Promise.resolve();

		state.stage = 'checking';
		state.error = '';
		render();

		return callUpdateCheck().then(function(result) {
			if (!result || result.ok !== true)
				throw new Error((result && result.error) || _('Request failed'));

			const data = result.data || {};
			if (data.ok === false)
				throw new Error(data.error || _('Check failed'));

			state.latest = data.latest || '';
			if (data.current)
				state.current = data.current;
			state.justUpdated = false;
			state.stage = data.available ? 'available' : 'done';
		}).catch(function(e) {
			state.stage = 'error';
			state.error = (e && e.message) || _('Check failed');
		}).then(function() {
			render();
		});
	}

	function startUpdate() {
		if (state.stage !== 'available' || state.running)
			return Promise.resolve();

		if (!confirm(_('Download and install the latest GitHub release? The page may reload after the update.')))
			return Promise.resolve();

		state.stage = 'updating';
		render();

		return callUpdateStart().then(function(result) {
			if (!result || result.ok !== true)
				throw new Error((result && result.error) || _('Request failed'));
			if (result.data && result.data.started === false)
				throw new Error(result.data.error || _('Update refused'));

			ui.addNotification(null, E('p', {}, _('Update started.')));
			return refresh();
		}).catch(function(e) {
			state.stage = 'error';
			state.error = (e && e.message) || _('Update failed');
			render();
		});
	}

	actionButton.addEventListener('click', function() {
		if (state.stage === 'available')
			return startUpdate();

		return runCheck();
	});

	poll.add(refresh, 3);
	render();

	return E('div', { 'class': 'cbi-section' }, [
		E('h3', {}, _('Online update')),
		E('div', { 'class': 'cbi-value' }, [
			E('label', { 'class': 'cbi-value-title' }, _('Current version')),
			E('div', { 'class': 'cbi-value-field' }, [ currentText ])
		]),
		E('div', { 'class': 'cbi-value' }, [
			E('label', { 'class': 'cbi-value-title' }, _('Latest version')),
			E('div', { 'class': 'cbi-value-field' }, [ latestText ])
		]),
		E('div', { 'class': 'cbi-value' }, [
			E('label', { 'class': 'cbi-value-title' }, _('Update status')),
			E('div', { 'class': 'cbi-value-field' }, [
				actionButton,
				hintText
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
