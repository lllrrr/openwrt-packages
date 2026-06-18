'use strict';
'require view';
'require ui';
'require rpc';
'require dom';
'require form';
'require uci';
'require upnp-nat-relay/utils as utils';

var callStatus = rpc.declare({
	object: 'upnp_nat_relay',
	method: 'status',
	expect: { '': {} }
});

var callServiceRestart = rpc.declare({
	object: 'upnp_nat_relay',
	method: 'restart',
	expect: { '': {} }
});

var callServiceStart = rpc.declare({
	object: 'upnp_nat_relay',
	method: 'start',
	expect: { '': {} }
});

return view.extend({
	load: function() {
		return uci.load('upnp_nat_relay');
	},

	render: function() {
		utils.loadSharedCSS();
		var m, s, o;

		m = new form.Map('upnp_nat_relay', _('Settings'));

		s = m.section(form.TypedSection, 'service', _('Service & Sync'));
		s.anonymous = true;

		o = s.option(form.Flag, 'enabled', _('Enable Automatic Sync'),
			_('Run the background service and periodically synchronize accepted UPnP mappings.'));
		o.default = '0';
		o.rmempty = false;

		o = s.option(form.Value, 'interval', _('Sync Interval (seconds)'),
			_('How often the background service checks the downstream router.'));
		o.datatype = 'range(10,86400)';
		o.placeholder = '60';
		o.rmempty = false;

		o = s.option(form.ListValue, 'backend', _('UPnP Backend'),
			_('Command used to read UPnP mappings from the downstream router.'));
		o.value('upnpc', 'upnpc');
		o.value('custom', _('Custom'));
		o.default = 'upnpc';
		o.rmempty = false;

		o = s.option(form.Flag, 'dry_run', _('Dry Run Mode'),
			_('Read and filter mappings without creating DNAT rules.'));
		o.default = '0';

		o = s.option(form.Flag, 'clear_on_stop', _('Clear Rules on Stop'),
			_('Remove dynamic DNAT rules when the service stops.'));
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.Value, 'failure_grace_count', _('Failure Grace Count'),
			_('Clear rules after this many consecutive sync failures. Set to 0 to never clear because of failures.'));
		o.datatype = 'range(0,100)';
		o.placeholder = '3';
		o.rmempty = false;

		s = m.section(form.TypedSection, 'service', _('Automation'));
		s.anonymous = true;

		o = s.option(form.Flag, 'show_advanced_config', _('Show Advanced Configuration'),
			_('Allow setup flows to change network, firewall, and OpenClash configuration.'));
		o.default = '0';
		o.rmempty = false;

		o = s.option(form.Flag, 'auto_config_network', _('Auto Configure Network'),
			_('Permit setup flows to create or repair the read interface before testing.'));
		o.default = '0';
		o.depends('show_advanced_config', '1');

		o = s.option(form.Flag, 'auto_config_firewall_zone', _('Auto Configure Firewall Zone'),
			_('Permit setup flows to create or repair the independent firewall zone before testing.'));
		o.default = '0';
		o.depends('show_advanced_config', '1');

		o = s.option(form.Flag, 'openclash_auto_restart', _('Auto Restart OpenClash After Rule Write'),
			_('Restart OpenClash after rules are written so changes take effect immediately.'));
		o.default = '0';
		o.depends('show_advanced_config', '1');

		s = m.section(form.TypedSection, 'service', _('Logging'));
		s.anonymous = true;

		o = s.option(form.ListValue, 'log_level', _('Log Level'),
			_('Controls the verbosity of system log output.'));
		o.value('debug', _('Debug'));
		o.value('info', _('Info'));
		o.value('warn', _('Warning'));
		o.value('error', _('Error'));
		o.default = 'info';
		o.rmempty = false;

		return utils.renderWithFooter(m.render(), {
			project: 'UPnP NAT Relay',
			repoUrl: 'https://github.com/hello-yunshu/luci-app-upnp-nat-relay'
		});
	},

	handleSave: function(ev) {
		var tasks = [];

		document.getElementById('maincontent')
			.querySelectorAll('.cbi-map').forEach(function(map) {
				tasks.push(dom.callClassMethod(map, 'save'));
			});

		return Promise.all(tasks);
	},

	handleSaveApply: function(ev, mode) {
		var oldEnabled = uci.get('upnp_nat_relay', 'main', 'enabled') || '0';
		var oldBackend = uci.get('upnp_nat_relay', 'main', 'backend') || '';

		return this.handleSave(ev).then(function() {
			return utils.safeApply();
		}).then(function() {
			return uci.load('upnp_nat_relay');
		}).then(function() {
			var newEnabled = uci.get('upnp_nat_relay', 'main', 'enabled') || '0';
			var newBackend = uci.get('upnp_nat_relay', 'main', 'backend') || '';
			var backendChanged = oldBackend !== newBackend;

			if (newEnabled !== '1') {
				if (oldEnabled === '1') {
					ui.addNotification(null, E('p', _('Configuration saved. Service has been stopped.')), 'info');
				} else {
					ui.addNotification(null, E('p', _('Configuration saved and applied.')), 'info');
				}
				utils.reloadSoon(600);
				return;
			}

			if (oldEnabled !== '1') {
				ui.addNotification(null, E('p', _('Configuration saved. Starting service and waiting for first sync...')), 'info');
				return callServiceStart().then(utils.requireSuccess).then(function() {
					return utils.waitForServiceReady(callStatus);
				}).then(function(status) {
					if (status && status.last_result === 'starting')
						ui.addNotification(null, E('p', _('Service started, but the first sync is still in progress. Refreshing current status.')), 'warning');
					else
						ui.addNotification(null, E('p', _('Configuration applied and service is ready.')), 'info');
					utils.reloadSoon(300);
				});
			}

			if (backendChanged) {
				ui.addNotification(null, E('p', _('Configuration saved. Restarting service (backend changed)...')), 'info');
				return callServiceRestart().then(utils.requireSuccess).then(function() {
					return utils.waitForServiceReady(callStatus);
				}).then(function(status) {
					if (status && status.last_result === 'starting')
						ui.addNotification(null, E('p', _('Service restarted, but the first sync is still in progress. Refreshing current status.')), 'warning');
					else
						ui.addNotification(null, E('p', _('Configuration applied and service is ready.')), 'info');
					utils.reloadSoon(300);
				});
			}

			ui.addNotification(null, E('p', _('Configuration saved. The running service will pick up changes on the next sync cycle.')), 'info');
			utils.reloadSoon(600);
		}).catch(function(e) {
			ui.addNotification(null, E('p', _('Failed to apply configuration: ') + e.message), 'error');
		});
	}
});
