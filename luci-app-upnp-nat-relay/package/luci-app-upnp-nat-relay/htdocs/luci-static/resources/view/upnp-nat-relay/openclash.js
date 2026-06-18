'use strict';
'require view';
'require ui';
'require rpc';
'require uci';
'require form';
'require upnp-nat-relay/utils as utils';

var OPENCLASH_RULE_COMMENT = 'upnp_nat_relay_openclash';

var callStatus = rpc.declare({
	object: 'upnp_nat_relay',
	method: 'status',
	expect: { '': {} }
});

var callCheckEnv = rpc.declare({
	object: 'upnp_nat_relay',
	method: 'check-env',
	expect: { '': {} }
});

var callSetupOpenclash = rpc.declare({
	object: 'upnp_nat_relay',
	method: 'setup-openclash',
	expect: { '': {} }
});

var callRestartOpenclash = rpc.declare({
	object: 'upnp_nat_relay',
	method: 'restart-openclash',
	expect: { '': {} }
});

var callRemoveOpenclashRule = rpc.declare({
	object: 'upnp_nat_relay',
	method: 'remove-openclash-rule',
	expect: { '': {} }
});

var callGenerateOpenclashRule = rpc.declare({
	object: 'upnp_nat_relay',
	method: 'generate-openclash-rule',
	expect: { '': {} }
});

var callOpenclashRuleCache = rpc.declare({
	object: 'upnp_nat_relay',
	method: 'openclash-rule-cache',
	expect: { '': {} }
});

var callSyncOpenclash = rpc.declare({
	object: 'upnp_nat_relay',
	method: 'sync-openclash',
	expect: { '': {} }
});

var callRollback = rpc.declare({
	object: 'upnp_nat_relay',
	method: 'rollback',
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

function buildFallbackRuleText(strategy, downstreamWanIp, allowedPorts, remark, iface) {
	var ifaceLine = iface ? ('\n' + _('Interface') + ': ' + iface) : '';
	if (strategy === 'per_mapping') {
		return _('Strategy:') + ' ' + _('Per-Mapping') + '\n' +
			_('Internal Address:') + ' ' + downstreamWanIp + '\n' +
			_('Internal Ports:') + ' ' + _('<dynamic, comma-separated per protocol>') + '\n' +
			_('Protocol') + ': ' + _('1 rule for TCP, 1 rule for UDP') + '\n' +
			_('Action') + ': RETURN' + ifaceLine + '\n' +
			_('Remark') + ': ' + remark + ' [TCP] / ' + remark + ' [UDP]\n\n' +
			_('Example (3 TCP + 2 UDP mappings):') + '\n' +
			'  ' + _('Rule') + ' 1: ports=54321,54322,54323  proto=tcp  remark="' + remark + ' [TCP]"\n' +
			'  ' + _('Rule') + ' 2: ports=54324,54325        proto=udp  remark="' + remark + ' [UDP]"';
	}

	return _('Strategy:') + ' ' + _('Port Pool') + '\n' +
		_('Internal Address:') + ' ' + downstreamWanIp + '\n' +
		_('Internal Ports:') + ' ' + allowedPorts + '\n' +
		_('Protocol') + ': TCP/UDP' + ifaceLine + '\n' +
		_('Action') + ': RETURN\n' +
		_('Remark') + ': ' + remark;
}

function buildSuggestedRuleHtml(strategy, downstreamWanIp, allowedPorts, remark, dryRun) {
	var suggestion = dryRun && dryRun.openclash_suggestion ? dryRun.openclash_suggestion : null;

	function cbiValue(title, value, valueClass) {
		return '<div class="cbi-value">' +
			'<label class="cbi-value-title">' + title + '</label>' +
			'<div class="cbi-value-field">' + (valueClass ? ('<span class="' + valueClass + '">' + value + '</span>') : value) + '</div>' +
			'</div>';
	}

	function ruleBlock(title, srcIp, srcPort, proto, iface, target, ruleRemark) {
		return '<div class="cbi-section" style="margin-bottom:0.8em">' +
			'<h3>' + title + '</h3>' +
			cbiValue(_('Source Address'), htmlEscape(srcIp)) +
			cbiValue(_('Source Ports'), htmlEscape(srcPort), 'ubr-text-primary') +
			cbiValue(_('Protocol'), htmlEscape(proto)) +
			(iface ? cbiValue(_('Interface'), htmlEscape(iface)) : '') +
			cbiValue(_('Action'), htmlEscape(target), 'ubr-text-success') +
			cbiValue(_('Remark'), htmlEscape(ruleRemark)) +
			'</div>';
	}

	if (suggestion && suggestion.strategy === 'per_mapping' && Array.isArray(suggestion.rules) && suggestion.rules.length > 0) {
		var html = '<div id="ubr-oc-suggested-rule"><b>' + _('Strategy:') + '</b> <span class="ubr-text-primary">' + _('Per-Mapping') + '</span></div>';
		for (var i = 0; i < suggestion.rules.length; i++) {
			var rule = suggestion.rules[i] || {};
			var srcIp = rule.src_ip || rule.internal_address || downstreamWanIp;
			var srcPort = rule.src_port || rule.internal_ports || '-';
			var proto = rule.proto || rule.protocols || '-';
			var iface = rule.interface || '';
			var protoLabel = (proto || '').toUpperCase();
			html += ruleBlock(protoLabel + ' ' + _('Rule'), srcIp, srcPort, proto, iface, rule.target || _('return'), rule.remark || '');
		}
		return html;
	}

	if (suggestion && suggestion.strategy === 'port_pool') {
		var poolSrcIp = suggestion.src_ip || suggestion.internal_address || downstreamWanIp;
		var poolSrcPort = suggestion.src_port || suggestion.internal_ports || allowedPorts;
		var poolProto = suggestion.proto || suggestion.protocols || _('both');
		var poolIface = suggestion.interface || '';
		return '<div id="ubr-oc-suggested-rule">' +
			'<b>' + _('Strategy:') + '</b> <span class="ubr-text-primary">' + _('Port Pool') + '</span>' +
			'</div>' +
			ruleBlock(_('Port Pool Rule'), poolSrcIp, poolSrcPort, poolProto, poolIface, suggestion.target || _('return'), suggestion.remark || remark);
	}

	if (strategy === 'per_mapping') {
		return '<div id="ubr-oc-suggested-rule">' +
			'<b>' + _('Strategy:') + '</b> <span class="ubr-text-primary">' + _('Per-Mapping') + '</span>' +
			'</div>' +
			ruleBlock('TCP ' + _('Rule'), downstreamWanIp, _('Dynamic (comma-separated)'), 'tcp', '', _('return'), remark + ' [TCP]') +
			ruleBlock('UDP ' + _('Rule'), downstreamWanIp, _('Dynamic (comma-separated)'), 'udp', '', _('return'), remark + ' [UDP]');
	}

	return '<div id="ubr-oc-suggested-rule">' +
		'<b>' + _('Strategy:') + '</b> <span class="ubr-text-primary">' + _('Port Pool') + '</span>' +
		'</div>' +
		ruleBlock(_('Port Pool Rule'), downstreamWanIp, allowedPorts, _('both'), '', _('return'), remark);
}

function formatOpenclashSyncStatus(status) {
	var lastOcSync = status ? status.last_oc_sync : null;
	if (!lastOcSync)
		return '<span class="ubr-text-muted">' + _('Not yet synced') + '</span>';

	var syncInterval = uci.get('upnp_nat_relay', 'main', 'openclash_sync_interval') || '0';
	var ts = parseInt(lastOcSync, 10);
	if (isNaN(ts) || ts === 0)
		return '<span class="ubr-text-muted">' + _('Not yet synced') + '</span>';

	var d = new Date(ts * 1000);
	var timeStr = d.toLocaleString();
	if (syncInterval !== '0') {
		var now = Math.floor(Date.now() / 1000);
		var elapsed = now - ts;
		var remaining = parseInt(syncInterval, 10) - elapsed;
		if (remaining > 0) {
			return '<span class="ubr-text-success">' + timeStr + '</span>' +
				' <span class="ubr-text-muted">(' + _('next in %ds').format(remaining) + ')</span>';
		}
		return '<span class="ubr-text-success">' + timeStr + '</span>' +
			' <span class="ubr-text-primary">(' + _('due now') + ')</span>';
	}

	return '<span class="ubr-text-success">' + timeStr + '</span>';
}

return view.extend({
	load: function() {
		return Promise.all([
			uci.load('upnp_nat_relay'),
			uci.load('openclash').catch(function() {}),
			callStatus(),
			callOpenclashRuleCache()
		]).then(function(results) {
			return {
				status: results[2],
				env: results[2],
				ruleCache: results[3]
			};
		});
	},

	render: function(data) {
		utils.loadSharedCSS();
		var m, s, o;
		var status = data.status || {};
		var env = data.env || {};
		var ruleCache = data.ruleCache || {};

		m = new form.Map('upnp_nat_relay', _('OpenClash Compatibility'));

		s = m.section(form.TypedSection, 'service', _('OpenClash Status'));
		s.anonymous = true;

		o = s.option(form.DummyValue, '_oc_installed', _('OpenClash Installed'));
		o.rawhtml = true;
		o.cfgvalue = function() {
			if (env.openclash_installed === 1 || env.openclash_installed === true) {
				return '<span class="ubr-text-success">&#10004; ' + _('Installed') + '</span>';
			}
			return '<span class="ubr-text-warning">&#10008; ' + _('Not Installed') + '</span>';
		};

		o = s.option(form.DummyValue, '_oc_running', _('OpenClash Running'));
		o.rawhtml = true;
		o.cfgvalue = function() {
			if (env.openclash_running === 1 || env.openclash_running === true) {
				return '<span class="ubr-text-success">&#10004; ' + _('Running') + '</span>';
			}
			return '<span class="ubr-text-warning">&#10008; ' + _('Not Running') + '</span>';
		};

		o = s.option(form.DummyValue, '_oc_access_control', _('Source Access Control Detected'));
		o.rawhtml = true;
		o.cfgvalue = function() {
			if (env.openclash_has_access_control === 1 || env.openclash_has_access_control === true) {
				return '<span class="ubr-text-success">&#10004; ' + _('Detected') + '</span>';
			}
			return '<span class="ubr-text-warning">&#10008; ' + _('Not Detected') + '</span>';
		};

		o = s.option(form.DummyValue, '_oc_existing_rule', _('Existing Matching Rule'));
		o.rawhtml = true;
		o.cfgvalue = function() {
			var found = false;
			var sections = uci.sections('openclash', 'lan_ac_traffic');
			if (sections) {
				for (var i = 0; i < sections.length; i++) {
					if ((sections[i].comment || '') === OPENCLASH_RULE_COMMENT) {
						found = true;
						break;
					}
				}
			}
			if (found) {
				return '<span class="ubr-text-success">&#10004; ' + _('Rule exists') + '</span>';
			}
			return '<span class="ubr-text-warning">&#10008; ' + _('No matching rule found') + '</span>';
		};

		o = s.option(form.DummyValue, '_oc_last_sync', _('Last OpenClash Sync'));
		o.rawhtml = true;
		o.cfgvalue = function() {
			return '<span id="ubr-oc-last-sync-value">' + formatOpenclashSyncStatus(status) + '</span>';
		};

		s = m.section(form.TypedSection, 'service', _('Rule Preview'));
		s.anonymous = true;

		o = s.option(form.DummyValue, '_oc_suggested_rule', _('Rule Preview'));
		o.rawhtml = true;
		o.cfgvalue = function() {
			var strategy = uci.get('upnp_nat_relay', 'main', 'openclash_return_strategy') || 'per_mapping';
			var downstreamWanIp = uci.get('upnp_nat_relay', 'main', 'downstream_wan_ip') || '-';
			var allowedPorts = uci.get('upnp_nat_relay', 'main', 'allowed_external_ports') || '40000-65535';
			var remark = uci.get('upnp_nat_relay', 'main', 'openclash_rule_remark') || 'UPnP NAT Relay Auto RETURN';
			return buildSuggestedRuleHtml(strategy, downstreamWanIp, allowedPorts, remark, ruleCache);
		};

		s = m.section(form.TypedSection, 'service', _('OpenClash Configuration'));
		s.anonymous = true;

		o = s.option(form.ListValue, 'openclash_mode', _('Auto Write Mode'),
			_('Control how OpenClash RETURN rules are handled.'));
		o.value('off', _('Off - Do not handle OpenClash'));
		o.value('prompt', _('Prompt - Show suggested rules only'));
		o.value('auto', _('Auto - Automatically write rules'));
		o.default = 'prompt';

		o = s.option(form.ListValue, 'openclash_return_strategy', _('RETURN Strategy'),
			_('Per-Mapping: one rule per UPnP mapping. Port Pool: one rule for the entire port range.'));
		o.value('per_mapping', _('Per-Mapping RETURN (recommended)'));
		o.value('port_pool', _('Port Pool RETURN'));

		o = s.option(form.Value, 'openclash_rule_remark', _('Rule Remark'),
			_('Remark text for the OpenClash RETURN rule.'));
		o.datatype = 'string';
		o.placeholder = 'UPnP NAT Relay Auto RETURN';

		o = s.option(form.Flag, 'openclash_backup', _('Backup Before Write'),
			_('Create a backup of OpenClash configuration before writing rules.'));
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.Flag, 'openclash_auto_restart', _('Auto Restart OpenClash After Rule Write'),
			_('Restart OpenClash after rules are written so changes take effect immediately.'));
		o.default = '0';
		o.rmempty = false;

		o = s.option(form.Value, 'openclash_sync_interval', _('OpenClash Sync Interval (seconds)'),
			_('Set to 0 to sync every main cycle. Higher values reduce config writes when mappings change frequently.'));
		o.datatype = 'range(0,86400)';
		o.placeholder = '0';
		o.rmempty = false;

		o = s.option(form.DummyValue, '_oc_backup_status', _('Backup Status'));
		o.rawhtml = true;
		o.cfgvalue = function() {
			return '<span class="ubr-text-muted">' + _('Auto-created before each rule write') + '</span>';
		};

		s = m.section(form.TypedSection, 'service', _('OpenClash Actions'));
		s.anonymous = true;

		o = s.option(form.Button, '_sync_oc_now', _('Sync OpenClash Now'));
		o.inputtitle = _('Sync OpenClash');
		o.inputstyle = 'apply';
		o.onclick = function() {
			var btn = this;
			if (btn.node) {
				btn.node.disabled = true;
				btn.node.textContent = _('Syncing...');
			}
			return callSyncOpenclash().then(function(result) {
				result = result || {};
				if (result.success === true) {
					var action = result.action || 'updated';
					var rulesCount = result.rules_count || 0;
					if (action === 'unchanged') {
						ui.addNotification(null, E('p', _('OpenClash rules are already up to date (%d rules).').format(rulesCount)), 'info');
					} else {
						ui.addNotification(null, E('p', _('OpenClash rules synced successfully (%d rules).').format(rulesCount)), 'info');
					}
					return callStatus().then(function(freshStatus) {
						var lastSyncEl = document.getElementById('ubr-oc-last-sync-value');
						if (lastSyncEl)
							lastSyncEl.innerHTML = formatOpenclashSyncStatus(freshStatus || {});
					}).catch(function() {
						var lastSyncEl = document.getElementById('ubr-oc-last-sync-value');
						if (lastSyncEl)
							lastSyncEl.innerHTML = formatOpenclashSyncStatus({ last_oc_sync: Math.floor(Date.now() / 1000) });
					});
				} else {
					var errorMsg = result.message || result.error || _('unknown');
					if (result.error === 'main_sync_running') {
						ui.addNotification(null, E('p', _('Main sync is currently running, please try again later.')), 'warning');
					} else if (result.error === 'openclash_operation_running') {
						ui.addNotification(null, E('p', _('Another OpenClash operation is currently running.')), 'warning');
					} else {
						ui.addNotification(null, E('p', _('Failed to sync OpenClash: ') + errorMsg), 'error');
					}
				}
			}).catch(function(e) {
				ui.addNotification(null, E('p', _('Failed to sync OpenClash: ') + e.message), 'error');
			}).finally(function() {
				if (btn.node) {
					btn.node.disabled = false;
					btn.node.textContent = _('Sync OpenClash');
				}
			});
		};

		o = s.option(form.Button, '_generate_rule', _('Generate Rule'));
		o.inputtitle = _('Generate RETURN Rule');
		o.inputstyle = 'apply';
		o.onclick = function() {
			var strategy = uci.get('upnp_nat_relay', 'main', 'openclash_return_strategy') || 'per_mapping';
			var downstreamWanIp = uci.get('upnp_nat_relay', 'main', 'downstream_wan_ip') || '-';
			var allowedPorts = uci.get('upnp_nat_relay', 'main', 'allowed_external_ports') || '40000-65535';
			var remark = uci.get('upnp_nat_relay', 'main', 'openclash_rule_remark') || 'UPnP NAT Relay Auto RETURN';
			var preview = document.getElementById('ubr-oc-suggested-rule');

			if (preview)
				preview.innerHTML = '<span class="ubr-text-muted">' + _('Generating...') + '</span>';

			return callGenerateOpenclashRule().then(function(result) {
				if (preview)
					preview.outerHTML = buildSuggestedRuleHtml(strategy, downstreamWanIp, allowedPorts, remark, result);
				ui.addNotification(null, E('p', _('Rule preview refreshed.')), 'info');
			}).catch(function(e) {
				if (preview)
					preview.outerHTML = buildSuggestedRuleHtml(strategy, downstreamWanIp, allowedPorts, remark);
				var wanIface = uci.get('upnp_nat_relay', 'main', 'upstream_wan_if') || '';
				ui.addNotification(null, E('div', { 'class': 'ubr-cmd-box' }, buildFallbackRuleText(strategy, downstreamWanIp, allowedPorts, remark, wanIface)), 'warning');
			});
		};

		o = s.option(form.Button, '_write_oc', _('Write to OpenClash'));
		o.inputtitle = _('Write OpenClash Rule');
		o.inputstyle = 'apply';
		o.onclick = function() {
			return callSetupOpenclash().then(function(result) {
				var strategy = uci.get('upnp_nat_relay', 'main', 'openclash_return_strategy') || 'per_mapping';
				var autoRestart = uci.get('upnp_nat_relay', 'main', 'openclash_auto_restart');
				var msg;
				if (strategy === 'per_mapping') {
					if (result && result.action === 'already_exists') {
						msg = _('Per-mapping rules already exist in OpenClash.');
					} else if (result && result.action === 'updated') {
						if (autoRestart === '1' && result.restart && result.restart.restarted) {
							msg = _('Per-mapping rules written (%d rules) and OpenClash restarted.').format(result.rules_count || 0);
						} else if (autoRestart === '1' && result.restart && result.restart.error === 'not_running') {
							msg = _('Per-mapping rules written (%d rules). OpenClash is not running, so it was not restarted.').format(result.rules_count || 0);
						} else if (autoRestart === '1' && result.restart && result.restart.error === 'disabled_by_other_tool') {
							msg = _('Per-mapping rules written (%d rules). OpenClash is currently disabled, so it was not restarted.').format(result.rules_count || 0);
						} else {
							msg = _('Per-mapping rules written (%d rules). You need to restart OpenClash for changes to take effect.').format(result.rules_count || 0);
						}
					} else if (result && result.action === 'unchanged') {
						msg = _('Per-mapping rules are already up to date (%d rules).').format(result.rules_count || 0);
					} else if (!result || result.success !== true) {
						msg = _('Failed to write per-mapping rules: ') + (result.error || _('unknown'));
					} else {
						msg = _('Per-mapping rules written. You need to restart OpenClash for changes to take effect.');
					}
				} else {
					if (autoRestart === '1') {
						if (result && result.restart && result.restart.restarted) {
							msg = _('OpenClash rule written and service restarted. Changes are now active.');
						} else if (result && result.restart && result.restart.error === 'not_running') {
							msg = _('OpenClash rule written. OpenClash is not running, so it was not restarted. The rule will take effect when OpenClash starts.');
						} else if (result && result.restart && result.restart.error === 'disabled_by_other_tool') {
							msg = _('OpenClash rule written. OpenClash is currently disabled (possibly by another tool like CloudflareSpeedTest), so it was not restarted to avoid interference.');
						} else {
							msg = _('OpenClash rule written, but restart may have failed. Please check OpenClash status manually.');
						}
					} else {
						msg = _('OpenClash rule written. You need to restart OpenClash for changes to take effect.');
					}
				}
				ui.addNotification(null, E('p', msg), 'info');
			}).catch(function(e) {
				ui.addNotification(null, E('p', _('Failed to write OpenClash rule: ') + e.message), 'error');
			});
		};

		o = s.option(form.Button, '_remove_oc', _('Remove Plugin Rule'));
		o.inputtitle = _('Remove Plugin Rule');
		o.inputstyle = 'reset';
		o.onclick = function() {
			return callRemoveOpenclashRule().then(function(result) {
				result = result || {};
				if (result.success !== true) {
					ui.addNotification(null, E('p', _('Operation failed: ') + (result.error || _('unknown'))), 'error');
					return;
				}
				ui.addNotification(null, E('p', _('Plugin rule removed from OpenClash.')), 'info');
			}).catch(function(e) {
				ui.addNotification(null, E('p', _('Failed to remove rule: ') + e.message), 'error');
			});
		};

		o = s.option(form.Button, '_restart_oc', _('Restart OpenClash'));
		o.inputtitle = _('Restart OpenClash');
		o.inputstyle = 'apply';
		o.onclick = function() {
			return callRestartOpenclash().then(function(result) {
				var msg;
				if (result && result.restarted) {
					msg = _('OpenClash restarted successfully.');
					ui.addNotification(null, E('p', msg), 'info');
				} else if (result && result.error === 'core_not_running_after_restart') {
					msg = _('OpenClash restart command completed, but the core process was not detected after 30 seconds.');
					ui.addNotification(null, E('p', msg), 'warning');
				} else if (result && result.error === 'init_script_not_found') {
					msg = _('OpenClash init script was not found.');
					ui.addNotification(null, E('p', msg), 'error');
				} else if (result && result.error === 'init_restart_failed') {
					msg = _('OpenClash init restart failed.');
					ui.addNotification(null, E('p', msg), 'error');
				} else {
					msg = _('OpenClash restart failed: ') + ((result && result.error) || _('unknown'));
					ui.addNotification(null, E('p', msg), 'error');
				}
			}).catch(function(e) {
				ui.addNotification(null, E('p', _('Failed to restart OpenClash: ') + e.message), 'error');
			});
		};

		o = s.option(form.Button, '_backup_oc', _('Backup OpenClash Config'));
		o.inputtitle = _('Backup');
		o.inputstyle = 'apply';
		o.onclick = function() {
			var backupPath = '/etc/config/openclash.bak.upnp_nat_relay';
			ui.addNotification(null, E('p', _('Backup is created automatically before writing rules.')), 'info');
		};

		o = s.option(form.Button, '_restore_oc', _('Restore Backup'));
		o.inputtitle = _('Restore');
		o.inputstyle = 'reset';
		o.onclick = function() {
			return callRemoveOpenclashRule().then(function(result) {
				if (result && result.method === 'backup_restored') {
					ui.addNotification(null, E('p', _('OpenClash configuration restored from backup.')), 'info');
				} else if (result && result.removed === 0) {
					ui.addNotification(null, E('p', _('No backup found and no matching rules to remove.')), 'warning');
				} else {
					ui.addNotification(null, E('p', _('Plugin rules removed from OpenClash via UCI.')), 'info');
				}
			}).catch(function(e) {
				ui.addNotification(null, E('p', _('Restore failed: ') + e.message), 'error');
			});
		};

		return utils.renderWithFooter(m.render(), {
			project: 'UPnP NAT Relay',
			repoUrl: 'https://github.com/hello-yunshu/luci-app-upnp-nat-relay'
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
