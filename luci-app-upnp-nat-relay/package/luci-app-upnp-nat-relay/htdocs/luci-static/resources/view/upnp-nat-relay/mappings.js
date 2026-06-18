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
		});
	},

	render: function(status) {
		utils.loadSharedCSS();
		var container = E('div', { 'class': 'cbi-map ubr-mappings' });

		container.appendChild(E('h2', { 'class': 'cbi-map-title' }, _('Mappings')));

		var btnBar = E('div', { 'class': 'cbi-section ubr-btn-bar' });
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

		var rawTableWrap = E('div', { 'class': 'ubr-table-wrap' });
		var rawHeaders = [_('Protocol'), _('External Port'), _('Internal IP'), _('Internal Port'), _('Description'), _('Status')];
		var rawTable = E('table', { 'class': 'table ubr-responsive-table', 'id': 'raw-mappings-table' }, [
			E('thead', {}, E('tr', {}, rawHeaders.map(function(title) {
				return E('th', {}, title);
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
					'<span class="ubr-text-success">' + _('Accepted') + '</span>' :
					'<span class="ubr-text-danger">' + _('Rejected') + '</span>';
				var statusTd = E('td');
				statusTd.innerHTML = statusLabel;
				var row = E('tr', { 'class': 'tr' }, [
					E('td', { 'data-label': rawHeaders[0] }, mapping.protocol || '-'),
					E('td', { 'data-label': rawHeaders[1] }, String(mapping.external_port || '-')),
					E('td', { 'data-label': rawHeaders[2] }, mapping.internal_ip || '-'),
					E('td', { 'data-label': rawHeaders[3] }, String(mapping.internal_port || '-')),
					E('td', { 'data-label': rawHeaders[4] }, mapping.description || '-'),
					statusTd
				]);
				statusTd.setAttribute('data-label', rawHeaders[5]);
				rawTable.appendChild(row);
			}
		} else {
			rawTable.appendChild(E('tr', {}, E('td', { 'colspan': '6', 'class': 'ubr-text-muted' }, _('No mappings found.'))));
		}
		var rawSection = E('div', { 'class': 'cbi-section' });
		rawSection.appendChild(E('h3', {}, _('Read UPnP Mappings (Raw)')));
		rawTableWrap.appendChild(rawTable);
		rawSection.appendChild(rawTableWrap);
		container.appendChild(rawSection);

		var syncTableWrap = E('div', { 'class': 'ubr-table-wrap' });
		var syncHeaders = [_('Protocol'), _('Public Port'), _('DNAT Target'), _('Source Mapping'), _('Status')];
		var syncTable = E('table', { 'class': 'table ubr-responsive-table', 'id': 'synced-mappings-table' }, [
			E('thead', {}, E('tr', {}, syncHeaders.map(function(title) {
				return E('th', {}, title);
			})))
		]);

		var accepted = (status && status.accepted) ? status.accepted : [];
		if (accepted.length > 0) {
			var downstreamWanIp = uci.get('upnp_nat_relay', 'main', 'downstream_wan_ip') || '-';
			for (var i = 0; i < accepted.length; i++) {
				var mapping = accepted[i];
				var dnatTarget = mapping.dnat_target || (downstreamWanIp + ':' + mapping.external_port);
				var sourceMapping = (mapping.internal_ip || '-') + ':' + (mapping.internal_port || '-') + ' ' + (mapping.description || '');
				var statusTd = E('td');
				statusTd.innerHTML = '<span class="ubr-text-success">' + _('Active') + '</span>';
				var row = E('tr', { 'class': 'tr' }, [
					E('td', { 'data-label': syncHeaders[0] }, mapping.protocol || '-'),
					E('td', { 'data-label': syncHeaders[1] }, String(mapping.external_port || '-')),
					E('td', { 'data-label': syncHeaders[2] }, dnatTarget),
					E('td', { 'data-label': syncHeaders[3] }, sourceMapping),
					statusTd
				]);
				statusTd.setAttribute('data-label', syncHeaders[4]);
				syncTable.appendChild(row);
			}
		} else {
			syncTable.appendChild(E('tr', {}, E('td', { 'colspan': '5', 'class': 'ubr-text-muted' }, _('No synced mappings.'))));
		}
		var syncSection = E('div', { 'class': 'cbi-section' });
		syncSection.appendChild(E('h3', {}, _('Synced Mappings (DNAT)')));
		syncTableWrap.appendChild(syncTable);
		syncSection.appendChild(syncTableWrap);
		container.appendChild(syncSection);

		var rejectTableWrap = E('div', { 'class': 'ubr-table-wrap' });
		var rejectHeaders = [_('Protocol'), _('External Port'), _('Internal IP'), _('Internal Port'), _('Reject Reason')];
		var rejectTable = E('table', { 'class': 'table ubr-responsive-table', 'id': 'rejected-mappings-table' }, [
			E('thead', {}, E('tr', {}, rejectHeaders.map(function(title) {
				return E('th', {}, title);
			})))
		]);

		var rejected = (status && status.rejected) ? status.rejected : [];
		if (rejected.length > 0) {
			for (var i = 0; i < rejected.length; i++) {
				var mapping = rejected[i];
				var reasonTd = E('td');
				reasonTd.innerHTML = '<span class="ubr-text-danger">' + (mapping.reason || '-') + '</span>';
				var row = E('tr', { 'class': 'tr' }, [
					E('td', { 'data-label': rejectHeaders[0] }, mapping.protocol || '-'),
					E('td', { 'data-label': rejectHeaders[1] }, String(mapping.external_port || '-')),
					E('td', { 'data-label': rejectHeaders[2] }, mapping.internal_ip || '-'),
					E('td', { 'data-label': rejectHeaders[3] }, String(mapping.internal_port || '-')),
					reasonTd
				]);
				reasonTd.setAttribute('data-label', rejectHeaders[4]);
				rejectTable.appendChild(row);
			}
		} else {
			rejectTable.appendChild(E('tr', {}, E('td', { 'colspan': '5', 'class': 'ubr-text-success' }, '\u2714 ' + _('No rejected mappings.'))));
		}
		var rejectSection = E('div', { 'class': 'cbi-section' });
		rejectSection.appendChild(E('h3', {}, _('Rejected Mappings')));
		rejectTableWrap.appendChild(rejectTable);
		rejectSection.appendChild(rejectTableWrap);
		container.appendChild(rejectSection);

		utils.appendFooter(container, {
			project: 'UPnP NAT Relay',
			repoUrl: 'https://github.com/hello-yunshu/luci-app-upnp-nat-relay'
		});

		return container;
	}
});
