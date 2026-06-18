'use strict';
'require view';
'require ui';
'require uci';
'require form';
'require upnp-nat-relay/utils as utils';

return view.extend({
	load: function() {
		return uci.load('upnp_nat_relay');
	},

	render: function() {
		utils.loadSharedCSS();
		var m, s, o;

		m = new form.Map('upnp_nat_relay', _('Security'));

		s = m.section(form.TypedSection, 'service', _('Port Range & Protocol'));
		s.anonymous = true;

		o = s.option(form.Value, 'allowed_external_ports', _('Allowed External Port Range'),
			_('Port range allowed for synchronization (e.g. 40000-65535).'));
		o.datatype = 'string';
		o.placeholder = '40000-65535';
		o.rmempty = false;
		o.validate = function(section_id, value) {
			if (!value) return _('Port range is required.');
			if (!/^\d+-\d+$/.test(value)) return _('Invalid format. Use format like 40000-65535.');
			var lo = parseInt(value.split('-')[0], 10);
			var hi = parseInt(value.split('-')[1], 10);
			if (lo < 1 || lo > 65535 || hi < 1 || hi > 65535) return _('Port values must be between 1 and 65535.');
			if (lo > hi) return _('Start port must not exceed end port.');
			return true;
		};

		o = s.option(form.MultiValue, 'protocols', _('Allowed Protocols'),
			_('Select which protocols to allow for synchronization.'));
		o.value('tcp', 'TCP');
		o.value('udp', 'UDP');
		o.delimiter = ' ';

		s = m.section(form.TypedSection, 'service', _('Deny Rules'));
		s.anonymous = true;

		o = s.option(form.TextValue, '_deny_ports', _('Denied Ports'),
			_('Enter ports separated by commas, e.g. 22,23,80,443.'));
		o.rows = 3;
		o.placeholder = '22,23,25,53,80,110,143,443,445';

		var denyPorts = uci.get('upnp_nat_relay', 'default', 'port');
		if (denyPorts) {
			if (typeof denyPorts === 'string') {
				o.cfgvalue = function() {
					return denyPorts.split(/[\s,]+/).filter(function(port) {
						return port !== '';
					}).join(',');
				};
			} else if (Array.isArray(denyPorts)) {
				o.cfgvalue = function() {
					return denyPorts.join(',');
				};
			}
		}
		o.validate = function(section_id, value) {
			var ports = (value || '').split(/[\s,]+/).filter(function(port) {
				return port !== '';
			});
			for (var i = 0; i < ports.length; i++) {
				var n = +ports[i];
				if (!/^\d+$/.test(ports[i]) || n < 1 || n > 65535)
					return _('Invalid denied port: %s').format(ports[i]);
			}
			return true;
		};
		o.write = function(section_id, value) {
			var ports = (value || '').split(/[\s,]+/).filter(function(port) {
				return port !== '';
			});
			if (ports.length > 0)
				uci.set('upnp_nat_relay', 'default', 'port', ports);
			else
				uci.unset('upnp_nat_relay', 'default', 'port');
		};

		o = s.option(form.Flag, '_deny_low_ports', _('Deny Low Ports (0-1023)'),
			_('Deny all privileged ports (0-1023). It is NOT recommended to sync these ports.'));
		o.uciconfig = 'upnp_nat_relay';
		o.ucisection = 'main';
		o.ucioption = 'deny_low_ports';
		o.default = '1';
		o.rmempty = false;

		s = m.section(form.TypedSection, 'service', _('Source Filtering'));
		s.anonymous = true;

		o = s.option(form.Flag, '_restrict_subnet', _('Restrict to Downstream LAN Subnet'),
			_('Only allow mappings with internal IPs in the downstream LAN subnet.'));
		o.uciconfig = 'upnp_nat_relay';
		o.ucisection = 'main';
		o.ucioption = 'restrict_to_subnet';
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.Flag, '_deny_empty_desc', _('Deny Empty Description Mappings'),
			_('Reject mappings without a description. These may be suspicious.'));
		o.uciconfig = 'upnp_nat_relay';
		o.ucisection = 'main';
		o.ucioption = 'deny_empty_description';
		o.default = '0';

		o = s.option(form.Flag, '_log_rejected', _('Log Rejected Mappings'),
			_('Write rejected mappings to the system log.'));
		o.uciconfig = 'upnp_nat_relay';
		o.ucisection = 'main';
		o.ucioption = 'log_rejected';
		o.default = '1';
		o.rmempty = false;

		s = m.section(form.TypedSection, 'service', _('Security Warnings'));
		s.anonymous = true;

		o = s.option(form.DummyValue, '_warn1', _('Low Port Warning'));
		o.rawhtml = true;
		o.cfgvalue = function() {
			return '<div class="alert-message danger">' +
				_('It is NOT recommended to synchronize ports 0-1023. These are privileged ports and should not be exposed via UPnP.') +
				'</div>';
		};

		o = s.option(form.DummyValue, '_warn2', _('Sensitive Port Warning'));
		o.rawhtml = true;
		o.cfgvalue = function() {
			return '<div class="alert-message danger">' +
				_('It is NOT recommended to synchronize sensitive ports such as 80, 443, 22, 53, 445, 3389. ' +
					'These are commonly used for web servers, SSH, DNS, file sharing, and remote desktop.') +
				'</div>';
		};

		o = s.option(form.DummyValue, '_warn3', _('Wide Range Warning'));
		o.rawhtml = true;
		o.cfgvalue = function() {
			return '<div class="alert-message danger">' +
				_('It is NOT recommended to use 1-65535 as the allowed port range. ' +
					'This would effectively create a DMZ, which defeats the purpose of this plugin.') +
				'</div>';
		};

		return m.render().then(function(node) {
			node.classList.add('ubr-security');
			return utils.appendFooter(node, {
				project: 'UPnP NAT Relay',
				repoUrl: 'https://github.com/hello-yunshu/luci-app-upnp-nat-relay'
			});
		});
	},

	handleSaveApply: function(ev, mode) {
		return this.handleSave(ev).then(function() {
			return utils.safeApply();
		}).then(function() {
			return uci.load('upnp_nat_relay');
		}).then(function() {
			if (uci.get('upnp_nat_relay', 'main', 'enabled') !== '1') {
				ui.addNotification(null, E('p', _('Configuration saved and applied.')), 'info');
				utils.reloadSoon(600);
				return;
			}

			ui.addNotification(null, E('p', _('Configuration saved. The running service will pick up changes on the next sync cycle.')), 'info');
			utils.reloadSoon(600);
		}).catch(function(e) {
			ui.addNotification(null, E('p', _('Failed to apply configuration: ') + e.message), 'error');
		});
	}
});
