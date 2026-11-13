'use strict';
'require view';
'require ui';
'require rpc';
'require uci';
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

return view.extend({
	load: function() {
		return Promise.all([
			callStatus(),
			uci.load('upnp_nat_relay')
		]).then(function(results) {
			return results[0];
		}).catch(utils.loadFailed('mappings'));
	},

	render: function(status) {
		utils.loadSharedCSS();
		if (status && status._loadError)
			return E('div', { 'class': 'cbi-map' }, [
				E('h2', { 'name': 'content' }, _('Mappings')),
				utils.errorPanel(_('Unable to load mappings'), _('Retry the page; if it keeps failing, check the service log.'), status._loadError)
			]);
		var container = E('div', { 'class': 'cbi-map' });

		container.appendChild(E('h2', { 'name': 'content' }, _('Mappings')));

		var btnBar = E('div', { 'class': 'cbi-section' });
		btnBar.appendChild(E('button', {
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
							msg = _('Sync completed: %d read, 0 accepted, %d rejected. Check rejected mappings for details.').format(rc, rj);
							msgType = 'warning';
						} else {
							msg = _('Sync completed: 0 mappings read from downstream router. Ensure the downstream router has UPnP mappings.');
							msgType = 'warning';
						}
					} else if (!result || result.success !== true) {
						msg = _('Sync failed: %s').format(result.error || 'unknown');
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
		}, _('Sync Now')));
		btnBar.appendChild(E('button', {
			'class': 'cbi-button',
			'click': function() {
				window.location.reload();
			}
		}, _('Refresh')));
		container.appendChild(btnBar);

		var rawTableWrap = E('div', { 'class': 'ubr-table-scroll' });
		var rawHeaders = [_('Protocol'), _('External Port'), _('Internal IP'), _('Internal Port'), _('Description'), _('Status')];
		var rawTable = E('table', { 'class': 'table', 'id': 'raw-mappings-table' }, [
			E('thead', {}, E('tr', { 'class': 'tr' }, rawHeaders.map(function(title) {
				return E('th', { 'class': 'th' }, title);
			})))
		]);

		var rawMappings = (status && status.accepted) ? status.accepted.concat(status.rejected || []) : [];
		if (rawMappings && rawMappings.length > 0) {
			var acceptedPorts = {};
			if (status.accepted) {
				for (var i = 0; i < status.accepted.length; i++) {
					var key = status.accepted[i].protocol + ':' + status.accepted[i].external_port;
					acceptedPorts[key] = true;
				}
			}
			for (var i = 0; i < rawMappings.length; i++) {
				var mapping = rawMappings[i];
				var key = mapping.protocol + ':' + mapping.external_port;
				var statusLabel = acceptedPorts[key] ?
					'<span>' + _('Accepted') + '</span>' :
					'<span>' + _('Rejected') + '</span>';
				var statusTd = E('td', { 'class': 'td' });
				statusTd.innerHTML = statusLabel;
				var row = E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td', 'data-title': rawHeaders[0] }, mapping.protocol || '-'),
					E('td', { 'class': 'td', 'data-title': rawHeaders[1] }, String(mapping.external_port || '-')),
					E('td', { 'class': 'td', 'data-title': rawHeaders[2] }, mapping.internal_ip || '-'),
					E('td', { 'class': 'td', 'data-title': rawHeaders[3] }, String(mapping.internal_port || '-')),
					E('td', { 'class': 'td', 'data-title': rawHeaders[4] }, mapping.description || '-'),
					statusTd
				]);
				statusTd.setAttribute('data-title', rawHeaders[5]);
				rawTable.appendChild(row);
			}
		} else {
			rawTable.appendChild(E('tr', { 'class': 'tr' }, E('td', { 'class': 'td', 'colspan': '6', 'data-title': _('Status') }, _('No mappings found.'))));
		}
		var rawSection = E('div', { 'class': 'cbi-section' });
		rawSection.appendChild(E('h3', {}, _('Read UPnP Mappings (Raw)')));
		rawTableWrap.appendChild(rawTable);
		rawSection.appendChild(rawTableWrap);
		container.appendChild(rawSection);

		var syncTableWrap = E('div', { 'class': 'ubr-table-scroll' });
		var syncHeaders = [_('Protocol'), _('Public Port'), _('DNAT Target'), _('Source Mapping'), _('Status')];
		var syncTable = E('table', { 'class': 'table', 'id': 'synced-mappings-table' }, [
			E('thead', {}, E('tr', { 'class': 'tr' }, syncHeaders.map(function(title) {
				return E('th', { 'class': 'th' }, title);
			})))
		]);

		var accepted = (status && status.accepted) ? status.accepted : [];
		if (accepted.length > 0) {
			var downstreamWanIp = uci.get('upnp_nat_relay', 'main', 'downstream_wan_ip') || '-';
			for (var i = 0; i < accepted.length; i++) {
				var mapping = accepted[i];
				var dnatTarget = mapping.dnat_target || (downstreamWanIp + ':' + mapping.external_port);
				var sourceMapping = (mapping.internal_ip || '-') + ':' + (mapping.internal_port || '-') + ' ' + (mapping.description || '');
				var statusTd = E('td', { 'class': 'td' });
				statusTd.innerHTML = '<span>' + _('Active') + '</span>';
				var row = E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td', 'data-title': syncHeaders[0] }, mapping.protocol || '-'),
					E('td', { 'class': 'td', 'data-title': syncHeaders[1] }, String(mapping.external_port || '-')),
					E('td', { 'class': 'td', 'data-title': syncHeaders[2] }, dnatTarget),
					E('td', { 'class': 'td', 'data-title': syncHeaders[3] }, sourceMapping),
					statusTd
				]);
				statusTd.setAttribute('data-title', syncHeaders[4]);
				syncTable.appendChild(row);
			}
		} else {
			syncTable.appendChild(E('tr', { 'class': 'tr' }, E('td', { 'class': 'td', 'colspan': '5', 'data-title': _('Status') }, _('No synced mappings.'))));
		}
		var syncSection = E('div', { 'class': 'cbi-section' });
		syncSection.appendChild(E('h3', {}, _('Synced Mappings (DNAT)')));
		syncTableWrap.appendChild(syncTable);
		syncSection.appendChild(syncTableWrap);
		container.appendChild(syncSection);

		var rejectTableWrap = E('div', { 'class': 'ubr-table-scroll' });
		var rejectHeaders = [_('Protocol'), _('External Port'), _('Internal IP'), _('Internal Port'), _('Reject Reason')];
		var rejectTable = E('table', { 'class': 'table', 'id': 'rejected-mappings-table' }, [
			E('thead', {}, E('tr', { 'class': 'tr' }, rejectHeaders.map(function(title) {
				return E('th', { 'class': 'th' }, title);
			})))
		]);

		var rejected = (status && status.rejected) ? status.rejected : [];
		if (rejected.length > 0) {
			for (var i = 0; i < rejected.length; i++) {
				var mapping = rejected[i];
				var reasonTd = E('td', { 'class': 'td' });
				reasonTd.innerHTML = '<span>' + (mapping.reason || '-') + '</span>';
				var row = E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td', 'data-title': rejectHeaders[0] }, mapping.protocol || '-'),
					E('td', { 'class': 'td', 'data-title': rejectHeaders[1] }, String(mapping.external_port || '-')),
					E('td', { 'class': 'td', 'data-title': rejectHeaders[2] }, mapping.internal_ip || '-'),
					E('td', { 'class': 'td', 'data-title': rejectHeaders[3] }, String(mapping.internal_port || '-')),
					reasonTd
				]);
				reasonTd.setAttribute('data-title', rejectHeaders[4]);
				rejectTable.appendChild(row);
			}
		} else {
			rejectTable.appendChild(E('tr', { 'class': 'tr' }, E('td', { 'class': 'td', 'colspan': '5', 'data-title': _('Status') }, '\u2714 ' + _('No rejected mappings.'))));
		}
		var rejectSection = E('div', { 'class': 'cbi-section' });
		rejectSection.appendChild(E('h3', {}, _('Rejected Mappings')));
		rejectTableWrap.appendChild(rejectTable);
		rejectSection.appendChild(rejectTableWrap);
		container.appendChild(rejectSection);

		utils.appendFooter(container, utils.FOOTER_OPTIONS);

		return container;
	}
});
