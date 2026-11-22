'use strict';
'require view';
'require ui';
'require rpc';
'require uci';
'require form';
'require upnp-nat-relay/utils as utils';

var OPENCLASH_RULE_COMMENT = 'upnp_nat_relay_openclash';

var callCheckEnv = rpc.declare({
	object: 'upnp_nat_relay',
	method: 'check-env',
	expect: { '': {} }
});

var callRemoveOpenclashRule = rpc.declare({
	object: 'upnp_nat_relay',
	method: 'remove-openclash-rule',
	expect: { '': {} }
});

function htmlEscape(value) {
	return String(value == null ? '' : value)
		.replace(/&/g, '&amp;')
		.replace(/</g, '&lt;')
		.replace(/>/g, '&gt;')
		.replace(/"/g, '&quot;')
		.replace(/'/g, '&#39;');
}

return view.extend({
	load: function() {
		return Promise.all([
			uci.load('openclash').catch(function() {}),
			callCheckEnv()
		]).then(function(results) {
			return { env: results[1] };
		}).catch(utils.loadFailed('openclash'));
	},

	render: function(data) {
		utils.loadSharedCSS();
		if (data && data._loadError)
			return E('div', { 'class': 'cbi-map' }, [
				E('h2', { 'name': 'content' }, _('OpenClash Compatibility')),
				utils.errorPanel(_('Unable to load OpenClash status'), _('Retry the page; if it keeps failing, check the service log.'), data._loadError)
			]);

		var env = data.env || {};
		var m = new form.Map('upnp_nat_relay', _('OpenClash Compatibility'));
		var s = m.section(form.TypedSection, 'service', _('OpenClash Status'));
		s.anonymous = true;

		var o = s.option(form.DummyValue, '_oc_installed', _('OpenClash Installed'));
		o.rawhtml = true;
		o.cfgvalue = function() {
			return env.openclash_installed === 1 || env.openclash_installed === true ?
				'<span>&#10004; ' + _('Installed') + '</span>' :
				'<span>&#10008; ' + _('Not Installed') + '</span>';
		};

		o = s.option(form.DummyValue, '_oc_running', _('OpenClash Running'));
		o.rawhtml = true;
		o.cfgvalue = function() {
			return env.openclash_running === 1 || env.openclash_running === true ?
				'<span>&#10004; ' + _('Running') + '</span>' :
				'<span>&#10008; ' + _('Not Running') + '</span>';
		};

		o = s.option(form.DummyValue, '_oc_access_control', _('Source Access Control Detected'));
		o.rawhtml = true;
		o.cfgvalue = function() {
			return env.openclash_has_access_control === 1 || env.openclash_has_access_control === true ?
				'<span>&#10004; ' + _('Detected') + '</span>' :
				'<span>&#10008; ' + _('Not Detected') + '</span>';
		};

		o = s.option(form.DummyValue, '_oc_compatibility', _('Inbound Mapping Compatibility'));
		o.rawhtml = true;
		o.cfgvalue = function() {
			return '<div class="alert-message warning">' + htmlEscape(_('The relay applies DNAT in its own nftables table and does not change or restart OpenClash. OpenClash lan_ac_traffic matches source IP and source port, so it cannot bypass inbound UPnP mappings. Proxy bypass is conditional on the original destination being in OpenClash runtime localnetwork; public aliases outside that set may still be intercepted. This was verified only for the router WAN IPv4 on OpenClash 0.47.156.')) + '</div>';
		};

		var ruleSections = uci.sections('openclash', 'lan_ac_traffic') || [];
		var hasPluginRule = ruleSections.some(function(section) {
			return (section.comment || '') === OPENCLASH_RULE_COMMENT;
		});
		if (hasPluginRule) {
			s = m.section(form.TypedSection, 'service', _('Legacy OpenClash Cleanup'));
			s.anonymous = true;
			o = s.option(form.Button, '_remove_legacy_oc_rule', _('Clean Up Legacy OpenClash Changes'));
			o.inputtitle = _('Clean Up Legacy OpenClash Changes');
			o.inputstyle = 'reset';
			o.description = _('This restores the saved OpenClash backup when available; that replaces the whole persistent OpenClash config with the saved copy. Without a backup, it removes only relay-owned rules. Either operation changes persistent UCI only; running rules may remain until OpenClash applies its configuration through its normal controls.');
			o.onclick = function() {
				return callRemoveOpenclashRule().then(function(result) {
					if (!result || result.error || (result.method !== 'backup_restored' && result.removed == null)) {
						ui.addNotification(null, E('p', _('Unable to remove legacy rules:') + ' ' + ((result && result.error) || _('unknown'))), 'error');
						return;
					}
					var message = result.method === 'backup_restored' ?
						_('The saved OpenClash config backup was restored. This replaced the persistent config; apply it through OpenClash normal controls if the running rules still need updating.') :
						_('Removed %d relay-owned rules from persistent OpenClash UCI. Apply OpenClash configuration through its normal controls if its running rules still contain them.').format(result.removed || 0);
					ui.addNotification(null, E('p', message), 'info');
					utils.reloadSoon(600);
				}).catch(function(e) {
					ui.addNotification(null, E('p', _('Unable to remove legacy rules:') + ' ' + e.message), 'error');
				});
			};
		}

		return m.render().then(function(node) {
			return utils.appendFooter(node, utils.FOOTER_OPTIONS);
		});
	}
});
