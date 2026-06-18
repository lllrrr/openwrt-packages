'use strict';
'require view';
'require ui';
'require rpc';
'require uci';
'require form';
'require upnp-nat-relay/utils as utils';

var callStatus = rpc.declare({
	object: 'upnp_nat_relay',
	method: 'status',
	expect: { '': {} }
});

var callSyncNow = rpc.declare({
	object: 'upnp_nat_relay',
	method: 'sync-now',
	expect: { '': {} }
});

var callRefreshEnv = rpc.declare({
	object: 'upnp_nat_relay',
	method: 'refresh-env',
	expect: { '': {} }
});

var callClear = rpc.declare({
	object: 'upnp_nat_relay',
	method: 'clear',
	expect: { '': {} }
});

var callServiceStart = rpc.declare({
	object: 'upnp_nat_relay',
	method: 'start',
	expect: { '': {} }
});

var callServiceStop = rpc.declare({
	object: 'upnp_nat_relay',
	method: 'stop',
	expect: { '': {} }
});

var callServiceRestart = rpc.declare({
	object: 'upnp_nat_relay',
	method: 'restart',
	expect: { '': {} }
});

function waitReadyAndReload() {
	return utils.waitForServiceReady(callStatus).then(function(status) {
		if (status && !status.running && status.last_result === 'stopped') {
			var errMsg = status.last_error ? _('Service stopped unexpectedly: ') + status.last_error : _('Service stopped unexpectedly. Check logs for details.');
			ui.addNotification(null, E('p', errMsg), 'error');
			utils.reloadSoon(500);
		} else if (status && status.last_result === 'starting') {
			ui.addNotification(null, E('p', _('Service action completed, but the first sync is still starting. Refreshing current status.')), 'warning');
			utils.reloadSoon(300);
		} else {
			utils.reloadSoon(300);
		}
		return status;
	});
}

function makeNftBadge(status) {
	if (status === 'present') {
		return E('span', { 'class': 'ubr-badge green' }, '\u2714 ' + _('Present'));
	} else if (status === '-' || status === 'not_present') {
		return E('span', { 'class': 'ubr-badge orange' }, '\u26A0 ' + _('Missing'));
	} else {
		return E('span', { 'class': 'ubr-badge orange' }, '\u26A0 ' + status);
	}
}

function makeOcBadge(status) {
	if (status === 'running') {
		return E('span', { 'class': 'ubr-badge green' }, '\u2714 ' + _('Running'));
	} else if (status === 'installed') {
		return E('span', { 'class': 'ubr-badge orange' }, '\u26A0 ' + _('Installed (Stopped)'));
	} else if (status === 'not_installed') {
		return E('span', { 'class': 'ubr-badge orange' }, '\u2718 ' + _('Not Installed'));
	} else if (status === '-') {
		return E('span', { 'class': 'ubr-badge orange' }, '\u26A0 ' + '-');
	} else {
		return E('span', { 'class': 'ubr-badge orange' }, '\u26A0 ' + status);
	}
}

function buildDepSection(missingDeps, pkgManager) {
	var section = E('div', { 'class': 'cbi-section ubr-section' });
	section.appendChild(E('h3', {}, _('Missing Dependencies & Fix Commands')));
	if (missingDeps.length > 0) {
		var installCmd = pkgManager === 'apk' ?
			'apk add --allow-untrusted ' + missingDeps.join(' ') :
			'opkg install ' + missingDeps.join(' ');
		section.appendChild(E('p', { 'class': 'ubr-text-warning', 'style': 'margin-bottom:0.5em' },
			'\u2718 ' + _('Missing dependencies: ') + missingDeps.join(', ')));
		section.appendChild(E('div', { 'class': 'ubr-cmd-box' }, installCmd));
	} else {
		section.appendChild(E('p', { 'class': 'ubr-text-success' },
			'\u2714 ' + _('All dependencies are installed.')));
	}
	return section;
}

return view.extend({
	load: function() {
		return Promise.all([
			callStatus(),
			uci.load('upnp_nat_relay')
		]).then(function(results) {
			return results[0];
		});
	},

	render: function(status) {
		utils.loadSharedCSS();
		status = status || {};
		var running = status.running || false;
		var lastSync = status.last_sync || '-';
		var lastResult = status.last_result || '-';
		var readCount = status.read_count || 0;
		var acceptedCount = status.accepted_count || 0;
		var rejectedCount = status.rejected_count || 0;
		var failureCount = status.failure_count || 0;
		var backend = status.backend || uci.get('upnp_nat_relay', 'main', 'backend') || '-';
		var nftStatus = status.nft_table_status || '-';
		var openclashStatus = status.openclash_status || '-';
		var version = status.version || '-';

		var container = E('div', { 'class': 'cbi-map ubr-dashboard' });

		container.appendChild(E('h2', { 'class': 'cbi-map-title' }, _('Overview')));

		var isStarting = running && lastResult === 'starting';
		var banner = E('div', {
			'class': 'cbi-section ubr-status-banner ' + (isStarting ? 'starting' : (running ? 'running' : 'stopped'))
		});
		banner.appendChild(E('div', {
			'class': 'ubr-status-icon ' + (isStarting ? 'starting' : (running ? 'running' : 'stopped'))
		}, isStarting ? '\u23F3' : (running ? '\u25CF' : '\u25CB')));
		var bannerText = E('div', { 'class': 'ubr-status-text' });
		bannerText.appendChild(E('h3', { 'class': isStarting ? 'starting' : (running ? 'running' : 'stopped') },
			isStarting ? _('Service Starting') : (running ? _('Service Running') : _('Service Stopped'))));
		bannerText.appendChild(E('p', {}, isStarting ?
			_('UPnP NAT Relay is starting up. Waiting for first sync...') :
			(running ?
				_('UPnP NAT Relay is active and syncing mappings.') :
				_('UPnP NAT Relay is not running. Click Start to begin.'))));
		banner.appendChild(bannerText);
		container.appendChild(banner);

		if (isStarting) {
			utils.waitForServiceReady(callStatus, {
				isActive: function() { return container.isConnected; }
			}).then(function() {
				if (container.isConnected)
					utils.reloadSoon(300);
			}).catch(function() {});
		}

		var statsGrid = E('div', { 'class': 'ubr-stats-grid' });

		statsGrid.appendChild(E('div', { 'class': 'cbi-section ubr-stat-card' }, [
			E('div', { 'class': 'ubr-stat-value' }, String(readCount)),
			E('div', { 'class': 'ubr-stat-label' }, _('Read Mappings'))
		]));

		var acceptedClass = acceptedCount > 0 ? 'ubr-stat-value green' : 'ubr-stat-value';
		statsGrid.appendChild(E('div', { 'class': 'cbi-section ubr-stat-card' }, [
			E('div', { 'class': acceptedClass }, String(acceptedCount)),
			E('div', { 'class': 'ubr-stat-label' }, _('Synced Mappings'))
		]));

		var rejectedClass = rejectedCount > 0 ? 'ubr-stat-value orange' : 'ubr-stat-value';
		statsGrid.appendChild(E('div', { 'class': 'cbi-section ubr-stat-card' }, [
			E('div', { 'class': rejectedClass }, String(rejectedCount)),
			E('div', { 'class': 'ubr-stat-label' }, _('Rejected Mappings'))
		]));

		var failureClass = failureCount > 0 ? 'ubr-stat-value red' : 'ubr-stat-value';
		statsGrid.appendChild(E('div', { 'class': 'cbi-section ubr-stat-card' }, [
			E('div', { 'class': failureClass }, String(failureCount)),
			E('div', { 'class': 'ubr-stat-label' }, _('Consecutive Failures'))
		]));

		container.appendChild(statsGrid);

			var controlSection = E('div', { 'class': 'cbi-section ubr-section' });
		controlSection.appendChild(E('h3', {}, _('Service Control')));

		var btnGroup = E('div', { 'class': 'ubr-btn-group' });

		if (!running) {
			btnGroup.appendChild(E('button', {
				'class': 'cbi-button cbi-button-apply',
				'click': function() {
					var btn = this;
					utils.setBusy(btn, _('Loading...'));
					return callServiceStart().then(utils.requireSuccess).then(function(result) {
						if (result && result.action === 'oneshot') {
							var sync = result.sync || {};
							var rc = sync.read_count || 0;
							var ac = sync.accepted_count || 0;
							var rj = sync.rejected_count || 0;
							var msg, msgType;
							if (sync.success) {
								msg = _('One-shot sync completed: %d read, %d accepted, %d rejected.').format(rc, ac, rj);
								msgType = ac > 0 ? 'info' : 'warning';
							} else {
								msg = _('One-shot sync failed: %s').format(sync.error || _('unknown'));
								msgType = 'error';
							}
							ui.addNotification(null, E('p', msg), msgType);
							utils.reloadSoon(500);
						} else {
							ui.addNotification(null, E('p', _('Service started. Waiting for first sync...')), 'info');
							return waitReadyAndReload();
						}
					}).catch(function(e) {
						ui.addNotification(null, E('p', _('Failed to start service: ') + e.message), 'error');
						utils.resetBusy(btn);
					});
				}
			}, '\u25B6 ' + _('Start')));
		}

		if (running) {
			btnGroup.appendChild(E('button', {
				'class': 'cbi-button cbi-button-reset',
				'click': function() {
					var btn = this;
					utils.setBusy(btn, _('Loading...'));
					return callServiceStop().then(utils.requireSuccess).then(function() {
						ui.addNotification(null, E('p', _('Service stopped.')), 'info');
						utils.reloadSoon();
					}).catch(function(e) {
						ui.addNotification(null, E('p', _('Failed to stop service: ') + e.message), 'error');
						utils.resetBusy(btn);
					});
				}
			}, '\u25A0 ' + _('Stop')));
		}

		btnGroup.appendChild(E('button', {
			'class': 'cbi-button cbi-button-apply',
			'click': function() {
				var btn = this;
				utils.setBusy(btn, _('Loading...'));
				return callServiceRestart().then(utils.requireSuccess).then(function(result) {
					if (result && result.action === 'oneshot') {
						var sync = result.sync || {};
						var rc = sync.read_count || 0;
						var ac = sync.accepted_count || 0;
						var rj = sync.rejected_count || 0;
						var msg, msgType;
						if (sync.success) {
							msg = _('One-shot sync completed: %d read, %d accepted, %d rejected.').format(rc, ac, rj);
							msgType = ac > 0 ? 'info' : 'warning';
						} else {
							msg = _('One-shot sync failed: %s').format(sync.error || _('unknown'));
							msgType = 'error';
						}
						ui.addNotification(null, E('p', msg), msgType);
						utils.reloadSoon(500);
					} else {
						ui.addNotification(null, E('p', _('Service restarted. Waiting for first sync...')), 'info');
						return waitReadyAndReload();
					}
				}).catch(function(e) {
					ui.addNotification(null, E('p', _('Failed to restart service: ') + e.message), 'error');
					utils.resetBusy(btn);
				});
			}
		}, '\u21BB ' + _('Restart')));

		if (running) {
			btnGroup.appendChild(E('button', {
				'class': 'cbi-button cbi-button-apply',
				'click': function() {
					var btn = this;
					utils.setBusy(btn, _('Loading...'));
					return callSyncNow().then(function(result) {
						var msg;
						var msgType = 'info';
						if (result && result.success === true) {
							var rc = result.read_count || 0;
							var ac = result.accepted_count || 0;
							var rj = result.rejected_count || 0;
							if (ac > 0) {
								msg = _('Sync completed: %d read, %d accepted, %d rejected.').format(rc, ac, rj);
							} else if (rj > 0) {
								msg = _('Sync completed: %d read, 0 accepted, %d rejected. Check Mappings page for details.').format(rc, rj);
								msgType = 'warning';
							} else {
								msg = _('Sync completed: 0 mappings read from downstream router. Ensure the downstream router has UPnP mappings.');
								msgType = 'warning';
							}
						} else if (!result || result.success !== true) {
							msg = _('Sync failed: %s').format(result.error || _('unknown'));
							msgType = 'error';
						} else {
							msg = _('Sync triggered.');
						}
						ui.addNotification(null, E('p', msg), msgType);
						utils.reloadSoon(2500);
					}).catch(function(e) {
						ui.addNotification(null, E('p', _('Sync failed: %s').format(e.message)), 'error');
						utils.resetBusy(btn);
					});
				}
			}, '\u21C4 ' + _('Sync Now')));

			btnGroup.appendChild(E('button', {
				'class': 'cbi-button cbi-button-reset',
				'click': function() {
					var btn = this;
					utils.setBusy(btn, _('Loading...'));
					return callClear().then(function(result) {
						result = result || {};
						if (result.success !== true) {
							ui.addNotification(null, E('p', _('Operation failed: ') + (result.error || _('unknown'))), 'error');
							return;
						}
						ui.addNotification(null, E('p', _('Dynamic rules cleared.')), 'info');
						utils.reloadSoon();
					}).catch(function(e) {
						ui.addNotification(null, E('p', _('Failed to clear rules: ') + e.message), 'error');
						utils.resetBusy(btn);
					});
				}
			}, '\u2716 ' + _('Clear Rules')));
		}

		controlSection.appendChild(btnGroup);
		container.appendChild(controlSection);

			var infoSection = E('div', { 'class': 'cbi-section ubr-section' });
		infoSection.appendChild(E('h3', {}, _('Service Information')));

		var infoTable = E('table', { 'class': 'table ubr-kv-table' });

		var versionTd = E('td', { 'class': 'td' }, version);
		infoTable.appendChild(E('tr', { 'class': 'tr' }, [
			E('th', { 'class': 'th' }, _('Plugin Version')),
			versionTd
		]));

		infoTable.appendChild(E('tr', { 'class': 'tr' }, [
			E('th', { 'class': 'th' }, _('GitHub')),
			E('td', { 'class': 'td' }, E('a', {
				'href': 'https://github.com/hello-yunshu/luci-app-upnp-nat-relay',
				'target': '_blank',
				'rel': 'noopener',
				'class': 'ubr-link'
			}, 'hello-yunshu/luci-app-upnp-nat-relay'))
		]));

		infoTable.appendChild(E('tr', { 'class': 'tr' }, [
			E('th', { 'class': 'th' }, _('Current Backend')),
			E('td', { 'class': 'td' }, backend)
		]));

		infoTable.appendChild(E('tr', { 'class': 'tr' }, [
			E('th', { 'class': 'th' }, _('Last Sync Time')),
			E('td', { 'class': 'td' }, lastSync)
		]));

		var lastResultBadge;
		if (lastResult === 'starting') {
			lastResultBadge = E('span', { 'class': 'ubr-badge orange' }, '\u23F3 ' + _('Starting'));
		} else if (lastResult === 'success' || (typeof lastResult === 'string' && lastResult.indexOf('success') === 0)) {
		lastResultBadge = E('span', { 'class': 'ubr-badge green' }, '\u2714 ' + _('Success'));
	} else if (lastResult === '-') {
		lastResultBadge = E('span', { 'class': 'ubr-badge orange' }, '\u26A0 ' + '-');
	} else if (lastResult === 'partial') {
		lastResultBadge = E('span', { 'class': 'ubr-badge orange' }, '\u26A0 ' + _('Partial'));
	} else {
		lastResultBadge = E('span', { 'class': 'ubr-badge red' }, '\u2718 ' + lastResult);
	}
		infoTable.appendChild(E('tr', { 'class': 'tr' }, [
			E('th', { 'class': 'th' }, _('Last Sync Result')),
			E('td', { 'class': 'td' }, lastResultBadge)
		]));

		var nftBadge = makeNftBadge(nftStatus);
		var nftTd = E('td', { 'class': 'td' }, nftBadge);
		infoTable.appendChild(E('tr', { 'class': 'tr' }, [
			E('th', { 'class': 'th' }, _('nftables Table')),
			nftTd
		]));

		var ocBadge = makeOcBadge(openclashStatus);
		var ocTd = E('td', { 'class': 'td' }, ocBadge);
		infoTable.appendChild(E('tr', { 'class': 'tr' }, [
			E('th', { 'class': 'th' }, _('OpenClash')),
			ocTd
		]));

		var envUpdatedAt = status.updated_at || '';
		var envTimeTd = E('td', { 'class': 'td' }, envUpdatedAt || '-');
		infoTable.appendChild(E('tr', { 'class': 'tr' }, [
			E('th', { 'class': 'th' }, _('Last Env Check')),
			envTimeTd
		]));

		var infoTableWrap = E('div', { 'class': 'ubr-table-wrap' });
		infoTableWrap.appendChild(infoTable);
		infoSection.appendChild(infoTableWrap);
		container.appendChild(infoSection);

		var envSection = E('div', { 'class': 'cbi-section ubr-section' });
		envSection.appendChild(E('h3', {}, _('Environment Detection')));

		var envTable = E('table', { 'class': 'table ubr-kv-table' });

		var envItems = [
			{ label: _('OpenWrt Version'), key: 'openwrt_version', statusKey: 'package_manager', statusFn: function(v) { return v === 'unknown' ? 'orange' : 'green'; } },
			{ label: _('Package Manager'), key: 'package_manager', statusKey: 'package_manager', statusFn: function(v) { return v === 'unknown' ? 'orange' : 'green'; } },
			{ label: _('Firewall'), key: 'firewall', statusKey: 'firewall', statusFn: function(v) { return v !== 'fw4' ? 'orange' : 'green'; } },
			{ label: _('nft'), key: 'nft', statusKey: 'nft', statusFn: function(v) { return v ? 'green' : 'orange'; }, bool: true },
			{ label: _('upnpc'), key: 'upnpc', statusKey: 'upnpc', statusFn: function(v) { return v ? 'green' : 'orange'; }, bool: true },
			{ label: _('LuCI'), key: 'luci', statusKey: 'luci', statusFn: function(v) { return v ? 'green' : 'orange'; }, bool: true },
			{ label: _('OpenClash'), key: 'openclash_installed', statusKey: null, oc: true }
		];

		var envTds = [];
		for (var i = 0; i < envItems.length; i++) {
			var item = envItems[i];
			var val, badgeVal, badgeStatus;
			if (item.oc) {
				var ocInstalled = status.openclash_installed;
				var ocRunning = status.openclash_running;
				if (ocInstalled) {
					badgeVal = ocRunning ? '\u2714 ' + _('Running') : '\u26A0 ' + _('Installed (Stopped)');
				} else {
					badgeVal = '\u2718 ' + _('Not Installed');
				}
				badgeStatus = (ocInstalled && ocRunning) ? 'green' : 'orange';
			} else if (item.bool) {
				var bval = status[item.key];
				badgeVal = bval ? '\u2714 ' + _('Installed') : '\u2718 ' + _('Missing');
				badgeStatus = item.statusFn(bval);
			} else {
				var sval = status[item.key] || '-';
				badgeVal = sval;
				badgeStatus = item.statusFn(status[item.statusKey]);
			}
			var td = E('td', { 'class': 'td' }, E('span', { 'class': 'ubr-badge ' + badgeStatus }, badgeVal));
			envTds.push({ td: td, item: item });
			envTable.appendChild(E('tr', { 'class': 'tr' }, [
				E('th', { 'class': 'th' }, item.label),
				td
			]));
		}

		var envTableWrap = E('div', { 'class': 'ubr-table-wrap' });
		envTableWrap.appendChild(envTable);
		envSection.appendChild(envTableWrap);

		var envBtnBar = E('div', { 'class': 'ubr-btn-group ubr-mt-1' });
		envBtnBar.appendChild(E('button', {
			'class': 'cbi-button cbi-button-apply',
			'click': function() {
				var btn = this;
				utils.setBusy(btn, _('Checking...'));
				return callRefreshEnv().then(function(result) {
					result = result || {};
					for (var j = 0; j < envTds.length; j++) {
						var entry = envTds[j];
						var it = entry.item;
						var newBadgeVal, newBadgeStatus;
						if (it.oc) {
							var oi = result.openclash_installed;
							var or2 = result.openclash_running;
							if (oi) {
								newBadgeVal = or2 ? '\u2714 ' + _('Running') : '\u26A0 ' + _('Installed (Stopped)');
							} else {
								newBadgeVal = '\u2718 ' + _('Not Installed');
							}
							newBadgeStatus = (oi && or2) ? 'green' : 'orange';
						} else if (it.bool) {
							var nbv = result[it.key];
							newBadgeVal = nbv ? '\u2714 ' + _('Installed') : '\u2718 ' + _('Missing');
							newBadgeStatus = it.statusFn(nbv);
						} else {
							newBadgeVal = result[it.key] || '-';
							newBadgeStatus = it.statusFn(result[it.statusKey]);
						}
						while (entry.td.firstChild) entry.td.removeChild(entry.td.firstChild);
						entry.td.appendChild(E('span', { 'class': 'ubr-badge ' + newBadgeStatus }, newBadgeVal));
					}

					while (nftTd.firstChild) nftTd.removeChild(nftTd.firstChild);
					nftTd.appendChild(makeNftBadge(result.nft_table_status || '-'));
					while (ocTd.firstChild) ocTd.removeChild(ocTd.firstChild);
					ocTd.appendChild(makeOcBadge(result.openclash_status || '-'));
					versionTd.textContent = result.version || '-';
					envTimeTd.textContent = result.updated_at || '-';

					var newMissing = [];
					if (!result.nft) newMissing.push('nftables');
					if (!result.upnpc) newMissing.push('miniupnpc');
					var depSectionParent = depSection.parentNode;
					if (depSectionParent) {
						var newDepSection = buildDepSection(newMissing, result.package_manager || 'opkg');
						depSectionParent.replaceChild(newDepSection, depSection);
						depSection = newDepSection;
					}

					utils.resetBusy(btn);
					ui.addNotification(null, E('p', _('Environment detection refreshed.')), 'info');
				}).catch(function(e) {
					ui.addNotification(null, E('p', _('Failed to refresh environment: ') + e.message), 'error');
					utils.resetBusy(btn);
				});
			}
		}, '\u21BB ' + _('Refresh Env')));
		envSection.appendChild(envBtnBar);
		container.appendChild(envSection);

		var missingDeps = [];
		if (!status.nft) missingDeps.push('nftables');
		if (!status.upnpc) missingDeps.push('miniupnpc');
		var depSection = buildDepSection(missingDeps, status.package_manager || 'opkg');
		container.appendChild(depSection);

		utils.appendFooter(container, {
			project: 'UPnP NAT Relay',
			version: version,
			repoUrl: 'https://github.com/hello-yunshu/luci-app-upnp-nat-relay'
		});

		return container;
	}
});
