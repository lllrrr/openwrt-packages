'use strict';
'require view';
'require poll';
'require rpc';
'require uci';

const callStatus = rpc.declare({
	object: 'cfpick',
	method: 'status',
	expect: {}
});

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
			callStatus()
		]);
	},

	render: function(data) {
		const status = data[1] || {};
		const enabled = uci.get('cfpick', 'global', 'web_enabled') === '1';
		const url = consoleUrl();

		const statusNode = E('span', { id: 'cfpick-console-status' });

		const update = (st) => {
			st = st || {};
			statusNode.replaceChildren(
				E('b', { style: 'color:%s'.format(st.running ? 'green' : 'red') },
					st.running ? _('RUNNING') : _('NOT RUNNING')),
				'  ',
				E('b', { style: 'color:%s'.format(st.cron ? 'green' : 'red') },
					st.cron ? _('Crontab enabled') : _('Crontab disabled'))
			);
		};

		update(status);

		const openButton = E('button', {
			type: 'button',
			'class': 'btn cbi-button cbi-button-apply'
		}, _('Open web console'));

		openButton.disabled = !enabled;
		openButton.addEventListener('click', function() {
			window.open(url, '_blank');
		});

		poll.add(function() {
			return callStatus().then(update).catch(function() {});
		}, 3);

		return E([], [
			E('h2', {}, _('Operations Console')),
			E('div', { 'class': 'cbi-section' }, [
				E('p', { 'class': 'cbi-section-descr' },
					_('The standalone console is the main operations and configuration UI: overview, nodes, IP lists, settings, logs and third-party integrations. This LuCI page only shows its status and opens it.')),
				E('div', { 'class': 'cbi-section' }, [
					E('p', {}, [ E('strong', {}, _('Run status') + ': '), statusNode ]),
					E('p', {}, [
						E('strong', {}, _('Web console') + ': '),
						enabled ? E('code', {}, url) : _('Disabled')
					]),
					enabled ? E('p', { 'class': 'muted' },
						_('The console has its own login. On first open it asks you to create the admin password.'))
						: E('p', { 'class': 'muted' },
						_('Enable it in Settings and save.')),
					E('p', {}, [ openButton ]),
					E('p', { 'class': 'muted' }, [
						_('Console service settings (enable, port, username, password reset) are in '),
						E('a', { href: L.url('admin/services/cfpick/settings') }, _('Settings')),
						'.'
					])
				])
			])
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
