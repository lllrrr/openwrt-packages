'use strict';
// Copyright (C) 2026 permails <https://github.com/permails/luci-app-diskbox>
// Licensed under the GNU General Public License v3.0
'require view';
'require rpc';
'require ui';
'require dom';

var callListDevices = rpc.declare({
	object: 'luci.diskbox',
	method: 'list_devices',
	expect: { devices: {} }
});

var callGetDiskInfo = rpc.declare({
	object: 'luci.diskbox',
	method: 'get_disk_info',
	params: ['device']
});

var callGetSmartAttr = rpc.declare({
	object: 'luci.diskbox',
	method: 'get_smart_attr',
	params: ['device']
});

var callGetFormatCmd = rpc.declare({
	object: 'luci.diskbox',
	method: 'get_format_cmd',
	expect: { formats: {} }
});

var callFormatPartition = rpc.declare({
	object: 'luci.diskbox',
	method: 'format_partition',
	params: ['partition', 'filesystem']
});

var callMkPartitionTable = rpc.declare({
	object: 'luci.diskbox',
	method: 'mk_partition_table',
	params: ['device', 'table']
});

var callCreatePartition = rpc.declare({
	object: 'luci.diskbox',
	method: 'create_partition',
	params: ['device', 'start_sec', 'end_sec', 'type']
});

var callRemovePartition = rpc.declare({
	object: 'luci.diskbox',
	method: 'remove_partition',
	params: ['device', 'number']
});

var callEjectDevice = rpc.declare({
	object: 'luci.diskbox',
	method: 'eject_device',
	params: ['device']
});

var callRescanDisks = rpc.declare({
	object: 'luci.diskbox',
	method: 'rescan_disks'
});

var callGetMountPoints = rpc.declare({
	object: 'luci.diskbox',
	method: 'get_mount_points',
	expect: { mount_points: [] }
});

var callMount = rpc.declare({
	object: 'luci.diskbox',
	method: 'mount',
	params: ['device', 'point', 'fs', 'options']
});

var callUmount = rpc.declare({
	object: 'luci.diskbox',
	method: 'umount',
	params: ['point']
});

var callListRaidDevices = rpc.declare({
	object: 'luci.diskbox',
	method: 'list_raid_devices',
	expect: { raid_devices: {} }
});

var callCreateRaid = rpc.declare({
	object: 'luci.diskbox',
	method: 'create_raid',
	params: ['name', 'level', 'members']
});

var callListBtrfsDevices = rpc.declare({
	object: 'luci.diskbox',
	method: 'list_btrfs_devices',
	expect: { btrfs_devices: {} }
});

var callGetBtrfsInfo = rpc.declare({
	object: 'luci.diskbox',
	method: 'get_btrfs_info',
	params: ['uuid']
});

var callGetBtrfsSubvolumes = rpc.declare({
	object: 'luci.diskbox',
	method: 'get_btrfs_subvolumes',
	params: ['uuid'],
	expect: { subvolumes: [] }
});

var callCreateBtrfs = rpc.declare({
	object: 'luci.diskbox',
	method: 'create_btrfs',
	params: ['label', 'level', 'members']
});

var callBtrfsSetLabel = rpc.declare({
	object: 'luci.diskbox',
	method: 'btrfs_set_label',
	params: ['uuid', 'label']
});

var callBtrfsSubvolCreate = rpc.declare({
	object: 'luci.diskbox',
	method: 'btrfs_subvol_create',
	params: ['uuid', 'path']
});

var callBtrfsSubvolDelete = rpc.declare({
	object: 'luci.diskbox',
	method: 'btrfs_subvol_delete',
	params: ['uuid', 'path']
});

var callBtrfsSubvolSetDefault = rpc.declare({
	object: 'luci.diskbox',
	method: 'btrfs_subvol_set_default',
	params: ['uuid', 'path']
});

var callBtrfsSnapshotCreate = rpc.declare({
	object: 'luci.diskbox',
	method: 'btrfs_snapshot_create',
	params: ['uuid', 'source', 'dest', 'readonly']
});

function translatePowerStatus(status) {
	if (!status || status === '-') return '-';
	var map = {
		'ACTIVE': _('Active'),
		'STANDBY': _('Standby'),
		'SLEEP': _('Sleep')
	};
	return map[status] || status;
}

function translateHealth(health) {
	if (!health || health === '-') return '-';
	var map = {
		'Normal': _('Normal'),
		'PASSED': _('Passed'),
		'Warning': _('Warning'),
		'Urgent': _('Urgent'),
		'FAILED': _('Failed')
	};
	return map[health] || health;
}

function translateFs(fs, type) {
	if (type === 'extended' || fs === 'extended') return _('Extended Partition');
	if (fs === 'Free Space' || type === 'free') return _('Free Space');
	if (fs === 'raw') return _('Unformatted');
	if (!fs || fs === '-') return '-';
	return fs.toUpperCase();
}

return view.extend({
	load: function() {
		return Promise.all([
			callListDevices(),
			callGetMountPoints(),
			callListRaidDevices(),
			callListBtrfsDevices(),
			callGetFormatCmd()
		]);
	},

	showSmartModal: function(dev) {
		ui.showModal(_('S.M.A.R.T Attributes') + ' - /dev/' + dev, [
			E('p', { 'class': 'spinning' }, _('Collecting data...'))
		]);

		callGetSmartAttr(dev).then(function(res) {
			var attrs = (res && res.attributes) ? res.attributes : (Array.isArray(res) ? res : []);
			if (attrs.length === 0) {
				ui.showModal(_('S.M.A.R.T Attributes') + ' - /dev/' + dev, [
					E('p', { 'style': 'font-style:italic; padding:1rem;' }, _('No SMART attributes to display.'))
				]);
				return;
			}

			var modalContent;
			if (attrs[0].key !== undefined) {
				var table = E('table', { 'class': 'table cbi-section-table' }, [
					E('tr', { 'class': 'tr table-titles' }, [
						E('th', { 'class': 'th' }, 'KEY'),
						E('th', { 'class': 'th' }, _('Value'))
					])
				]);
				attrs.forEach(function(item) {
					table.appendChild(E('tr', { 'class': 'tr' }, [
						E('td', { 'class': 'td' }, item.key),
						E('td', { 'class': 'td' }, item.value)
					]));
				});
				modalContent = table;
			} else {
				var table = E('table', { 'class': 'table cbi-section-table' }, [
					E('tr', { 'class': 'tr table-titles' }, [
						E('th', { 'class': 'th' }, 'ID'),
						E('th', { 'class': 'th' }, _('Attribute')),
						E('th', { 'class': 'th' }, _('Flag')),
						E('th', { 'class': 'th' }, _('Value')),
						E('th', { 'class': 'th' }, _('Worst')),
						E('th', { 'class': 'th' }, _('Thresh')),
						E('th', { 'class': 'th' }, _('Type')),
						E('th', { 'class': 'th' }, _('Updated')),
						E('th', { 'class': 'th' }, _('Raw'))
					])
				]);

				attrs.forEach(function(item) {
					var isCritical = ((item.id === '05' || item.id === 'C5') && item.raw !== '0');
					var rowStyle = isCritical ? 'background-color:rgba(245, 54, 92, 0.25) !important;' : '';

					table.appendChild(E('tr', { 'class': 'tr', 'style': rowStyle }, [
						E('td', { 'class': 'td' }, E('code', {}, item.id)),
						E('td', { 'class': 'td' }, item.attrbute || item.attribute),
						E('td', { 'class': 'td' }, item.flag || '-'),
						E('td', { 'class': 'td' }, item.value || '-'),
						E('td', { 'class': 'td' }, item.worst || '-'),
						E('td', { 'class': 'td' }, item.thresh || '-'),
						E('td', { 'class': 'td' }, item.type || '-'),
						E('td', { 'class': 'td' }, item.updated || '-'),
						E('td', { 'class': 'td' }, E('strong', {}, item.raw || '-'))
					]));
				});
				modalContent = table;
			}

			ui.showModal(_('S.M.A.R.T Attributes') + ' - /dev/' + dev, [
				E('div', { 'style': 'max-height:70vh; overflow-y:auto;' }, [ modalContent ]),
				E('div', { 'class': 'right', 'style': 'margin-top:1rem;' }, [
					E('button', {
						'class': 'btn cbi-button cbi-button-neutral',
						'click': ui.hideModal
					}, _('Close'))
				])
			]);
		});
	},

	showFormatModal: function(partName, formatCmds, currentFs, onSuccess) {
		var selFs = E('select', { 'class': 'cbi-input-select', 'style': 'width:100%;' });
		Object.keys(formatCmds).forEach(function(fs) {
			var opt = E('option', { 'value': fs }, fs.toUpperCase());
			if (fs === currentFs) opt.selected = true;
			selFs.appendChild(opt);
		});

		var statusP = E('p', { 'style': 'color:#f5365c; font-weight:bold; margin-top:8px;' });

		ui.showModal(_('Format partition: /dev/%s').format(partName), [
			E('p', {}, _('Formatting partition will ERASE all data stored on it.')),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, _('File System')),
				E('div', { 'class': 'cbi-value-field' }, selFs)
			]),
			statusP,
			E('div', { 'class': 'right', 'style': 'margin-top:1.5rem; display:flex; justify-content:flex-end; gap:8px;' }, [
				E('button', {
					'class': 'btn cbi-button cbi-button-reset',
					'click': ui.hideModal
				}, _('Cancel')),
				E('button', {
					'class': 'btn cbi-button cbi-button-apply',
					'click': function(ev) {
						ev.preventDefault();
						var targetFs = selFs.value;
						dom.content(statusP, [ E('span', { 'class': 'spinning' }, _('Formatting...')) ]);
						this.disabled = true;

						callFormatPartition(partName, targetFs).then(function(res) {
							if (res && res.code === 0) {
								ui.addNotification(null, E('p', {}, _('Partition formatted successfully!')));
								ui.hideModal();
								if (typeof onSuccess === 'function') {
									onSuccess();
								} else {
									location.reload();
								}
							} else {
								dom.content(statusP, res ? res.error : _('Format failed.'));
							}
						});
					}
				}, _('Format'))
			])
		]);
	},

	renderPartitionDetailView: function(container, devName, data) {
		var self = this;
		ui.showModal(_('Loading...'), [ E('p', { 'class': 'spinning' }, _('Loading device info...')) ]);

		callGetDiskInfo(devName).then(function(diskInfo) {
			ui.hideModal();
			dom.content(container, []);

			var viewRoot = E('div', { 'class': 'cbi-map' });

			// Header
			var headerDiv = E('div', { 'style': 'margin-bottom:1rem;' }, [
				E('h2', { 'style': 'margin-bottom:0.25rem;' }, _('Partition Management')),
				E('div', { 'class': 'cbi-map-descr' }, _('Partition disk over LuCI.'))
			]);
			viewRoot.appendChild(headerDiv);

			if (diskInfo.error || !diskInfo.size) {
				viewRoot.appendChild(E('div', { 'class': 'cbi-section' }, [
					E('div', { 'style': 'padding:2rem; text-align:center;' }, [
						E('p', { 'style': 'font-size:1.1rem; color:#f5365c;' }, _('Device /dev/%s not found or has no media.').format(devName))
					])
				]));
				var errFooter = E('div', { 'class': 'cbi-page-actions' }, [
					E('button', {
						'class': 'btn cbi-button cbi-button-link',
						'click': function() { self.renderOverview(container, data); }
					}, _('Back to Overview'))
				]);
				viewRoot.appendChild(errFooter);
				container.appendChild(viewRoot);
				return;
			}

			// Section: Device Info
			var devSection = E('div', { 'class': 'cbi-section' }, [
				E('legend', {}, _('Device Info'))
			]);

			var isRaid = diskInfo.type && diskInfo.type.startsWith('md');

			var devTable = E('table', { 'class': 'table cbi-section-table' }, [
				E('tr', { 'class': 'tr table-titles' }, [
					E('th', { 'class': 'th' }, _('Path')),
					E('th', { 'class': 'th' }, _('Model')),
					E('th', { 'class': 'th' }, _('Serial Number')),
					E('th', { 'class': 'th' }, _('Size')),
					E('th', { 'class': 'th' }, _('Sector Size')),
					E('th', { 'class': 'th' }, _('Partition Table')),
					isRaid ? E('th', { 'class': 'th' }, _('Level')) : E('th', { 'class': 'th' }, _('Temp')),
					isRaid ? E('th', { 'class': 'th' }, _('Members')) : E('th', { 'class': 'th' }, _('SATA Version')),
					isRaid ? E('th', { 'class': 'th' }, _('Status')) : E('th', { 'class': 'th' }, _('Rotation Rate')),
					E('th', { 'class': 'th' }, _('Status')),
					E('th', { 'class': 'th' }, _('Health')),
					E('th', { 'class': 'th center' }, '')
				])
			]);

			var ptCell;
			var hasPartitions = diskInfo.partitions && diskInfo.partitions.some(function(p){ return p.number > 0; });
			if (!hasPartitions && diskInfo.p_table && !diskInfo.p_table.includes('Raid')) {
				var ptSelect = E('select', { 'class': 'cbi-input-select' }, [
					E('option', { 'value': 'GPT', 'selected': diskInfo.p_table === 'GPT' }, 'GPT'),
					E('option', { 'value': 'MBR', 'selected': diskInfo.p_table === 'MBR' }, 'MBR')
				]);
				ptSelect.addEventListener('change', function() {
					var targetTbl = this.value;
					if (confirm(_('Warning !!\nTHIS WILL OVERWRITE EXISTING PARTITIONS!!\nModify the partition table to %s?').format(targetTbl))) {
						ui.showModal(_('Modifying Partition Table'), [ E('p', { 'class': 'spinning' }, _('Applying partition table...')) ]);
						callMkPartitionTable(devName, targetTbl).then(function(res) {
							if (res && res.code !== 0) {
								ui.addNotification(null, E('p', {}, res.error || _('Failed to modify partition table.')));
							}
							self.renderPartitionDetailView(container, devName, data);
						});
					} else {
						self.renderPartitionDetailView(container, devName, data);
					}
				});
				ptCell = ptSelect;
			} else {
				ptCell = diskInfo.p_table || '-';
			}

			var healthBtn = E('button', {
				'class': 'btn cbi-button ' + ((diskInfo.health === 'PASSED' || diskInfo.health === 'Normal') ? 'cbi-button-add' : 'cbi-button-remove'),
				'click': function(ev) {
					ev.preventDefault();
					self.showSmartModal(devName);
				}
			}, translateHealth(diskInfo.health));

			var anyMounted = diskInfo.partitions && diskInfo.partitions.some(function(p){ return p.mount_point !== '-'; });
			var ejectBtn = E('button', {
				'class': 'btn cbi-button cbi-button-remove',
				'disabled': anyMounted,
				'click': function(ev) {
					ev.preventDefault();
					if (anyMounted) {
						ui.addNotification(null, E('p', {}, _('Partition is in use! Please unmount it first!')));
						return;
					}
					if (!confirm(_('Are you sure you want to eject/remove this device?'))) return;
					ui.showModal(_('Ejecting'), [ E('p', { 'class': 'spinning' }, _('Ejecting device...')) ]);
					callEjectDevice(devName).then(function(res) {
						if (res && res.code !== 0) {
							ui.addNotification(null, E('p', {}, res.error || _('Failed to eject device.')));
						}
						self.renderOverview(container, data);
					});
				}
			}, isRaid ? _('Delete') : _('Eject'));

			devTable.appendChild(E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td' }, E('strong', {}, diskInfo.path)),
				E('td', { 'class': 'td' }, diskInfo.model || '-'),
				E('td', { 'class': 'td' }, diskInfo.sn || '-'),
				E('td', { 'class': 'td' }, diskInfo.size_formated || '-'),
				E('td', { 'class': 'td' }, diskInfo.sec_size || '-'),
				E('td', { 'class': 'td' }, ptCell),
				isRaid ? E('td', { 'class': 'td' }, diskInfo.level || '-') : E('td', { 'class': 'td' }, diskInfo.temp || '-'),
				isRaid ? E('td', { 'class': 'td' }, diskInfo.members_str || '-') : E('td', { 'class': 'td' }, diskInfo.sata_ver || '-'),
				isRaid ? E('td', { 'class': 'td' }, diskInfo.status || '-') : E('td', { 'class': 'td' }, diskInfo.rota_rate || '-'),
				E('td', { 'class': 'td' }, translatePowerStatus(diskInfo.status)),
				E('td', { 'class': 'td' }, healthBtn),
				E('td', { 'class': 'td center' }, ejectBtn)
			]));

			devSection.appendChild(devTable);
			viewRoot.appendChild(devSection);

			// Section: Partitions Info
			if (!diskInfo.p_table || !diskInfo.p_table.includes('Raid')) {
				var partSection = E('div', { 'class': 'cbi-section' }, [
					E('legend', {}, _('Partitions Info')),
					E('div', { 'class': 'cbi-section-descr' }, _('Default 2048 sector alignment, support +size{b,k,m,g,t} in End Sector'))
				]);

				var partTable = E('table', { 'class': 'table cbi-section-table' }, [
					E('tr', { 'class': 'tr table-titles' }, [
						E('th', { 'class': 'th' }, _('Name')),
						E('th', { 'class': 'th' }, _('Start Sector')),
						E('th', { 'class': 'th' }, _('End Sector')),
						E('th', { 'class': 'th' }, _('Size')),
						E('th', { 'class': 'th' }, _('Used')),
						E('th', { 'class': 'th' }, _('Free Space')),
						E('th', { 'class': 'th' }, _('Usage')),
						E('th', { 'class': 'th' }, _('Mount Point')),
						E('th', { 'class': 'th' }, _('File System')),
						E('th', { 'class': 'th center' }, '')
					])
				]);

				var partitions = diskInfo.partitions || [];
				partitions.forEach(function(part) {
					var isFree = (part.number === -1 || part.fs === 'Free Space' || part.type === 'free');
					var isMounted = (part.mount_point !== '-');

					if (isFree) {
						var startIn = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'value': part.sec_start });
						var endIn = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'value': part.sec_end });

						var createBtn = E('button', {
							'class': 'btn cbi-button cbi-button-add',
							'click': function(ev) {
								ev.preventDefault();
								var sSec = startIn.value;
								var eSec = endIn.value;
								if (!sSec || !eSec) {
									ui.addNotification(null, E('p', {}, _('Invalid Start or End sector!')));
									return;
								}
								ui.showModal(_('Creating Partition'), [ E('p', { 'class': 'spinning' }, _('Creating new partition...')) ]);
								callCreatePartition(devName, sSec, eSec, 'primary').then(function(res) {
									if (res && res.code !== 0) {
										ui.addNotification(null, E('p', {}, res.error || _('Failed to create partition.')));
									}
									self.renderPartitionDetailView(container, devName, data);
								});
							}
						}, _('New'));

						partTable.appendChild(E('tr', { 'class': 'tr', 'style': 'background-color:rgba(255,255,255,0.03);' }, [
							E('td', { 'class': 'td', 'style': 'font-style:italic; color:#888;' }, _('Free Space')),
							E('td', { 'class': 'td' }, startIn),
							E('td', { 'class': 'td' }, endIn),
							E('td', { 'class': 'td' }, part.size_formated),
							E('td', { 'class': 'td' }, '-'),
							E('td', { 'class': 'td' }, '-'),
							E('td', { 'class': 'td' }, '-'),
							E('td', { 'class': 'td' }, '-'),
							E('td', { 'class': 'td' }, '-'),
							E('td', { 'class': 'td center' }, createBtn)
						]));
					} else {
						var isExtended = (part.type === 'extended' || part.fs === 'extended');
						var formatBtn;
						if (!isMounted && !isExtended && part.type !== 'free') {
							formatBtn = E('button', {
								'class': 'btn cbi-button cbi-button-reset',
								'click': function(ev) {
									ev.preventDefault();
									self.showFormatModal(part.name, formatCmds, part.fs, function() {
										self.renderPartitionDetailView(container, devName, data);
									});
								}
							}, translateFs(part.fs, part.type));
						} else {
							formatBtn = E('span', {}, translateFs(part.fs, part.type));
						}

						var hasLogicals = partitions.some(function(p){ return p.type === 'logical'; });
						var removeDisabled = isMounted || (isExtended && hasLogicals);

						var removeBtn = E('button', {
							'class': 'btn cbi-button cbi-button-remove',
							'disabled': removeDisabled,
							'click': function(ev) {
								ev.preventDefault();
								if (!confirm(_('Are you sure you want to delete partition %s?').format(part.name))) return;
								ui.showModal(_('Deleting Partition'), [ E('p', { 'class': 'spinning' }, _('Removing partition...')) ]);
								callRemovePartition(devName, part.number).then(function(res) {
									if (res && res.code !== 0) {
										ui.addNotification(null, E('p', {}, res.error || _('Failed to remove partition.')));
									}
									self.renderPartitionDetailView(container, devName, data);
								});
							}
						}, _('Delete'));

						partTable.appendChild(E('tr', { 'class': 'tr' }, [
							E('td', { 'class': 'td' }, E('strong', {}, part.name)),
							E('td', { 'class': 'td' }, part.sec_start),
							E('td', { 'class': 'td' }, part.sec_end),
							E('td', { 'class': 'td' }, part.size_formated),
							E('td', { 'class': 'td' }, part.used_formated || '-'),
							E('td', { 'class': 'td' }, part.free_formated || '-'),
							E('td', { 'class': 'td' }, part.usage || '-'),
							E('td', { 'class': 'td' }, part.mount_point !== '-' ? E('code', {}, part.mount_point) : '-'),
							E('td', { 'class': 'td' }, formatBtn),
							E('td', { 'class': 'td center' }, removeBtn)
						]));
					}
				});

				partSection.appendChild(partTable);
				viewRoot.appendChild(partSection);
			}

			// Footer Action Bar
			var footerDiv = E('div', { 'class': 'cbi-page-actions' }, [
				E('button', {
					'class': 'btn cbi-button cbi-button-link',
					'click': function() { self.renderOverview(container, data); }
				}, _('Back to Overview'))
			]);
			viewRoot.appendChild(footerDiv);

			container.appendChild(viewRoot);
		});
	},

	renderBtrfsDetailView: function(container, uuid, data) {
		var self = this;
		ui.showModal(_('Loading...'), [ E('p', { 'class': 'spinning' }, _('Loading Btrfs info...')) ]);

		Promise.all([
			callGetBtrfsInfo(uuid),
			callGetBtrfsSubvolumes(uuid)
		]).then(function(res) {
			ui.hideModal();
			dom.content(container, []);

			var info = res[0] || {};
			var subvolumes = res[1] || [];

			var viewRoot = E('div', { 'class': 'cbi-map' });

			// Header
			var headerDiv = E('div', { 'style': 'margin-bottom:1rem;' }, [
				E('h2', { 'style': 'margin-bottom:0.25rem;' }, _('Btrfs Management') + ' - ' + (info.label || uuid)),
				E('div', { 'class': 'cbi-map-descr' }, _('Manage Btrfs filesystem, subvolumes and snapshots.'))
			]);
			viewRoot.appendChild(headerDiv);

			// Section: Btrfs Info
			var infoSection = E('div', { 'class': 'cbi-section' }, [
				E('legend', {}, _('Btrfs Info'))
			]);

			var labelIn = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'value': info.label || '', 'style': 'max-width:180px; display:inline-block; margin-right:6px;' });
			var updateLabelBtn = E('button', {
				'class': 'btn cbi-button cbi-button-edit',
				'click': function(ev) {
					ev.preventDefault();
					ui.showModal(_('Updating Label'), [ E('p', { 'class': 'spinning' }, _('Updating Btrfs label...')) ]);
					callBtrfsSetLabel(uuid, labelIn.value).then(function(res) {
						if (res && res.code !== 0) {
							ui.addNotification(null, E('p', {}, res.error || _('Failed to update label.')));
						}
						self.renderBtrfsDetailView(container, uuid, data);
					});
				}
			}, _('Update'));

			var infoTable = E('table', { 'class': 'table cbi-section-table' }, [
				E('tr', { 'class': 'tr table-titles' }, [
					E('th', { 'class': 'th' }, _('UUID')),
					E('th', { 'class': 'th' }, _('Members')),
					E('th', { 'class': 'th' }, _('Data')),
					E('th', { 'class': 'th' }, _('Metadata')),
					E('th', { 'class': 'th' }, _('Size')),
					E('th', { 'class': 'th' }, _('Used')),
					E('th', { 'class': 'th' }, _('Free Space')),
					E('th', { 'class': 'th' }, _('Usage')),
					E('th', { 'class': 'th center' }, _('Label'))
				]),
				E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td' }, E('code', {}, info.uuid || '-')),
					E('td', { 'class': 'td' }, info.members || '-'),
					E('td', { 'class': 'td' }, info.data_raid_level || '-'),
					E('td', { 'class': 'td' }, info.metadata_raid_level || '-'),
					E('td', { 'class': 'td' }, info.size_formated || '-'),
					E('td', { 'class': 'td' }, info.used_formated || '-'),
					E('td', { 'class': 'td' }, info.free_formated || '-'),
					E('td', { 'class': 'td' }, info.usage || '-'),
					E('td', { 'class': 'td center' }, [ labelIn, updateLabelBtn ])
				])
			]);
			infoSection.appendChild(infoTable);
			viewRoot.appendChild(infoSection);

			// Section: Subvolumes
			var subvSection = E('div', { 'class': 'cbi-section' }, [
				E('legend', {}, _('Subvolumes'))
			]);

			var subvTable = E('table', { 'class': 'table cbi-section-table' }, [
				E('tr', { 'class': 'tr table-titles' }, [
					E('th', { 'class': 'th' }, _('ID')),
					E('th', { 'class': 'th' }, _('Top Level')),
					E('th', { 'class': 'th' }, _('UUID')),
					E('th', { 'class': 'th' }, _('Path')),
					E('th', { 'class': 'th center' }, _('Set Default')),
					E('th', { 'class': 'th center' }, '')
				])
			]);

			subvolumes.forEach(function(sv) {
				var isRoot = (sv.path === '/' || sv.id === '5');
				var isDefault = sv.default_subvolume;

				var setDefaultBtn = E('button', {
					'class': 'btn cbi-button cbi-button-edit',
					'disabled': isDefault,
					'click': function(ev) {
						ev.preventDefault();
						ui.showModal(_('Setting Default'), [ E('p', { 'class': 'spinning' }, _('Setting default subvolume...')) ]);
						callBtrfsSubvolSetDefault(uuid, sv.path).then(function(res) {
							if (res && res.code !== 0) {
								ui.addNotification(null, E('p', {}, res.error || _('Failed to set default subvolume.')));
							}
							self.renderBtrfsDetailView(container, uuid, data);
						});
					}
				}, isDefault ? _('Default') : _('Set Default'));

				var deleteBtn = E('button', {
					'class': 'btn cbi-button cbi-button-remove',
					'disabled': isRoot || isDefault,
					'click': function(ev) {
						ev.preventDefault();
						if (!confirm(_('Are you sure you want to delete subvolume %s?').format(sv.path))) return;
						ui.showModal(_('Deleting Subvolume'), [ E('p', { 'class': 'spinning' }, _('Deleting subvolume...')) ]);
						callBtrfsSubvolDelete(uuid, sv.path).then(function(res) {
							if (res && res.code !== 0) {
								ui.addNotification(null, E('p', {}, res.error || _('Failed to delete subvolume.')));
							}
							self.renderBtrfsDetailView(container, uuid, data);
						});
					}
				}, _('Delete'));

				subvTable.appendChild(E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td' }, sv.id),
					E('td', { 'class': 'td' }, sv.top_level || '-'),
					E('td', { 'class': 'td' }, sv.uuid ? E('code', {}, sv.uuid) : '-'),
					E('td', { 'class': 'td' }, E('strong', {}, sv.path)),
					E('td', { 'class': 'td center' }, setDefaultBtn),
					E('td', { 'class': 'td center' }, deleteBtn)
				]));
			});

			var newSubvPath = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'placeholder': '/my_subvolume' });
			var createSubvBtn = E('button', {
				'class': 'btn cbi-button cbi-button-add',
				'click': function(ev) {
					ev.preventDefault();
					var p = newSubvPath.value;
					if (!p || !p.startsWith('/')) {
						ui.addNotification(null, E('p', {}, _('Subvolume path must start with \'/\'')));
						return;
					}
					ui.showModal(_('Creating Subvolume'), [ E('p', { 'class': 'spinning' }, _('Creating subvolume...')) ]);
					callBtrfsSubvolCreate(uuid, p).then(function(res) {
						if (res && res.code !== 0) {
							ui.addNotification(null, E('p', {}, res.error || _('Failed to create subvolume.')));
						}
						self.renderBtrfsDetailView(container, uuid, data);
					});
				}
			}, _('Create'));

			subvTable.appendChild(E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td', 'colspan': 3, 'style': 'font-style:italic; color:#888;' }, _('New Subvolume')),
				E('td', { 'class': 'td' }, newSubvPath),
				E('td', { 'class': 'td center' }, '-'),
				E('td', { 'class': 'td center' }, createSubvBtn)
			]));

			subvSection.appendChild(subvTable);
			viewRoot.appendChild(subvSection);

			// Section: New Snapshot
			var snapSection = E('div', { 'class': 'cbi-section' }, [
				E('legend', {}, _('New Snapshot'))
			]);

			var snapSrcIn = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'placeholder': '/data' });
			var snapDstIn = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'placeholder': '/.snapshot/data/20260101' });
			var snapRoCheck = E('input', { 'type': 'checkbox', 'checked': true });

			snapSection.appendChild(E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, _('Source Path')),
				E('div', { 'class': 'cbi-value-field' }, [
					snapSrcIn,
					E('div', { 'class': 'cbi-value-description' }, _('Source path for creating snapshot (must start with \'/\')'))
				])
			]));

			snapSection.appendChild(E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, _('Read-Only')),
				E('div', { 'class': 'cbi-value-field' }, [
					E('label', {}, [
						snapRoCheck,
						' ' + _('Create as read-only snapshot')
					])
				])
			]));

			snapSection.appendChild(E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, _('Destination Path (optional)')),
				E('div', { 'class': 'cbi-value-field' }, [
					snapDstIn,
					E('div', { 'class': 'cbi-value-description' }, _('Destination path where you want to store the snapshot'))
				])
			]));

			snapSection.appendChild(E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, ''),
				E('div', { 'class': 'cbi-value-field' }, [
					E('button', {
						'class': 'btn cbi-button cbi-button-add',
						'click': function(ev) {
							ev.preventDefault();
							var src = snapSrcIn.value;
							if (!src || !src.startsWith('/')) {
								ui.addNotification(null, E('p', {}, _('Source path must start with \'/\'')));
								return;
							}
							ui.showModal(_('Creating Snapshot'), [ E('p', { 'class': 'spinning' }, _('Creating Btrfs snapshot...')) ]);
							callBtrfsSnapshotCreate(uuid, src, snapDstIn.value || '', snapRoCheck.checked).then(function(res) {
								if (res && res.code !== 0) {
									ui.addNotification(null, E('p', {}, res.error || _('Failed to create snapshot.')));
								}
								self.renderBtrfsDetailView(container, uuid, data);
							});
						}
					}, _('Create Snapshot'))
				])
			]));

			viewRoot.appendChild(snapSection);

			// Footer Action Bar
			var footerDiv = E('div', { 'class': 'cbi-page-actions' }, [
				E('button', {
					'class': 'btn cbi-button cbi-button-link',
					'click': function() { self.renderOverview(container, data); }
				}, _('Back to Overview'))
			]);
			viewRoot.appendChild(footerDiv);

			container.appendChild(viewRoot);
		});
	},

	renderOverview: function(container, data) {
		var self = this;
		var devices = data[0] || {};
		var mountPoints = data[1] || [];
		var raidDevices = data[2] || {};
		var btrfsDevices = data[3] || {};

		dom.content(container, []);

		var viewRoot = E('div', { 'class': 'cbi-map' });

		// Page Header
		var headerDiv = E('div', { 'style': 'margin-bottom:1rem;' }, [
			E('h2', { 'style': 'margin-bottom:0.25rem;' }, _('DiskManager')),
			E('div', { 'class': 'cbi-map-descr', 'style': 'margin-bottom:0.75rem;' }, _('Manage disks over LuCI.')),
			E('div', { 'style': 'margin-bottom:1.5rem;' }, [
				E('button', {
					'class': 'cbi-button cbi-button-add',
					'click': function(ev) {
						ev.preventDefault();
						ui.showModal(_('Rescan Disks'), [
							E('p', { 'class': 'spinning' }, _('Rescanning SCSI and RAID devices...'))
						]);
						callRescanDisks().then(function() {
							location.reload();
						});
					}
				}, _('Rescan Disks'))
			])
		]);
		viewRoot.appendChild(headerDiv);

		// Section: Disks
		var diskSection = E('div', { 'class': 'cbi-section' }, [
			E('legend', {}, _('Disks'))
		]);

		var diskTable = E('table', { 'class': 'table cbi-section-table' }, [
			E('tr', { 'class': 'tr table-titles' }, [
				E('th', { 'class': 'th' }, _('Path')),
				E('th', { 'class': 'th' }, _('Model')),
				E('th', { 'class': 'th' }, _('Serial Number')),
				E('th', { 'class': 'th' }, _('Size')),
				E('th', { 'class': 'th' }, _('Temp')),
				E('th', { 'class': 'th' }, _('Partition Table')),
				E('th', { 'class': 'th' }, _('SATA Version')),
				E('th', { 'class': 'th' }, _('Health Status')),
				E('th', { 'class': 'th center' }, '')
			])
		]);

		var devKeys = Object.keys(devices);
		devKeys.forEach(function(dKey) {
			var dev = devices[dKey];
			var colors = ['#2dce89', '#5e72e4', '#11cdef', '#fb6340', '#f5365c', '#8965e0', '#ffd600'];

			var partItems = [];
			var parts = dev.partitions || [];
			var totalSize = dev.size || 1;

			parts.forEach(function(p, idx) {
				var pct = Math.max(((p.size / totalSize) * 100), 2.0).toFixed(2);
				var color = colors[idx % colors.length];
				partItems.push(E('div', {
					'style': 'background-color:' + color + '; width:' + pct + '%; height:100%; display:inline-block; float:left; color:#fff; font-size:10px; font-weight:bold; line-height:22px; text-align:center; overflow:hidden; text-overflow:ellipsis; white-space:nowrap;',
					'title': p.name + ' (' + p.size_formated + ')' + (p.mount_point !== '-' ? ' -> ' + p.mount_point : '')
				}, p.name));
			});

			var partBar = E('div', {
				'style': 'width:100%; height:22px; background:#444; border-radius:4px; overflow:hidden; margin:4px 0;'
			}, partItems);

			diskTable.appendChild(E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td' }, E('strong', {}, dev.path)),
				E('td', { 'class': 'td' }, dev.model || '-'),
				E('td', { 'class': 'td' }, dev.sn || '-'),
				E('td', { 'class': 'td' }, dev.size_formated || '-'),
				E('td', { 'class': 'td' }, dev.temp || '-'),
				E('td', { 'class': 'td' }, dev.p_table || '-'),
				E('td', { 'class': 'td' }, dev.sata_ver || '-'),
				E('td', { 'class': 'td' }, [
					E('span', { 'style': 'margin-right:6px;' }, translateHealth(dev.health_status)),
					E('span', { 'style': 'color:#888; font-size:90%;' }, translatePowerStatus(dev.status))
				]),
				E('td', { 'class': 'td center' }, [
					E('button', {
						'class': 'btn cbi-button cbi-button-action',
						'click': function() { self.renderPartitionDetailView(container, dev.name, data); }
					}, _('Edit'))
				])
			]));

			diskTable.appendChild(E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td', 'colspan': 9, 'style': 'padding-top:0; padding-bottom:12px;' }, partBar)
			]));
		});

		diskSection.appendChild(diskTable);
		viewRoot.appendChild(diskSection);

		// Section: RAID
		var raidKeys = Object.keys(raidDevices);
		if (raidKeys.length > 0) {
			var raidSection = E('div', { 'class': 'cbi-section' }, [
				E('legend', {}, _('RAID Devices'))
			]);
			var raidTable = E('table', { 'class': 'table cbi-section-table' }, [
				E('tr', { 'class': 'tr table-titles' }, [
					E('th', { 'class': 'th' }, _('Device')),
					E('th', { 'class': 'th' }, _('RAID Level')),
					E('th', { 'class': 'th' }, _('Size')),
					E('th', { 'class': 'th' }, _('Status')),
					E('th', { 'class': 'th' }, _('Members')),
					E('th', { 'class': 'th center' }, '')
				])
			]);

			raidKeys.forEach(function(rKey) {
				var r = raidDevices[rKey];
				raidTable.appendChild(E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td' }, E('strong', {}, r.path)),
					E('td', { 'class': 'td' }, r.level || '-'),
					E('td', { 'class': 'td' }, r.size_formated || '-'),
					E('td', { 'class': 'td' }, r.status || '-'),
					E('td', { 'class': 'td' }, r.members_str || '-'),
					E('td', { 'class': 'td center' }, [
						E('button', {
							'class': 'btn cbi-button cbi-button-action',
							'click': function() { self.renderPartitionDetailView(container, r.name, data); }
						}, _('Edit'))
					])
				]));
			});
			raidSection.appendChild(raidTable);
			viewRoot.appendChild(raidSection);
		}

		// Section: Btrfs
		var btrfsKeys = Object.keys(btrfsDevices);
		if (btrfsKeys.length > 0) {
			var btrfsSection = E('div', { 'class': 'cbi-section' }, [
				E('legend', {}, _('Btrfs'))
			]);
			var btrfsTable = E('table', { 'class': 'table cbi-section-table' }, [
				E('tr', { 'class': 'tr table-titles' }, [
					E('th', { 'class': 'th' }, _('UUID')),
					E('th', { 'class': 'th' }, _('Label')),
					E('th', { 'class': 'th' }, _('Members')),
					E('th', { 'class': 'th' }, _('Usage')),
					E('th', { 'class': 'th center' }, '')
				])
			]);

			btrfsKeys.forEach(function(uKey) {
				var b = btrfsDevices[uKey];
				btrfsTable.appendChild(E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td' }, E('code', {}, b.uuid)),
					E('td', { 'class': 'td' }, b.label || '-'),
					E('td', { 'class': 'td' }, b.members || '-'),
					E('td', { 'class': 'td' }, b.used_formated || '-'),
					E('td', { 'class': 'td center' }, [
						E('button', {
							'class': 'btn cbi-button cbi-button-action',
							'click': function() { self.renderBtrfsDetailView(container, b.uuid, data); }
						}, _('Edit'))
					])
				]));
			});
			btrfsSection.appendChild(btrfsTable);
			viewRoot.appendChild(btrfsSection);
		}

		// Section: Mount Points
		var mountSection = E('div', { 'class': 'cbi-section' }, [
			E('legend', {}, _('Mount Points'))
		]);
		var mountTable = E('table', { 'class': 'table cbi-section-table' }, [
			E('tr', { 'class': 'tr table-titles' }, [
				E('th', { 'class': 'th' }, _('Device')),
				E('th', { 'class': 'th' }, _('File System')),
				E('th', { 'class': 'th' }, _('Mount Options')),
				E('th', { 'class': 'th' }, _('Mount Point')),
				E('th', { 'class': 'th center' }, _('Mount'))
			])
		]);

		mountPoints.forEach(function(mp) {
			mountTable.appendChild(E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td' }, mp.device),
				E('td', { 'class': 'td' }, mp.fs),
				E('td', { 'class': 'td', 'style': 'word-break:break-all; max-width:300px;' }, mp.mount_options),
				E('td', { 'class': 'td' }, E('code', {}, mp.mount_point)),
				E('td', { 'class': 'td center' }, [
					E('button', {
						'class': 'btn cbi-button cbi-button-remove',
						'click': function(ev) {
							ev.preventDefault();
							if (!confirm(_('Are you sure you want to unmount %s?').format(mp.mount_point))) return;
							ui.showModal(_('Unmounting'), [ E('p', { 'class': 'spinning' }, _('Unmounting %s...').format(mp.mount_point)) ]);
							callUmount(mp.mount_point).then(function(res) {
								if (res && res.code !== 0) {
									ui.addNotification(null, E('p', {}, res.error || _('Failed to unmount.')));
								}
								location.reload();
							});
						}
					}, _('Unmount'))
				])
			]));
		});

		var devSelect = E('select', { 'class': 'cbi-input-select' });
		devSelect.appendChild(E('option', { 'value': '' }, _('-- Please choose --')));
		devKeys.forEach(function(dKey) {
			var dev = devices[dKey];
			if (dev.partitions && dev.partitions.length > 0) {
				dev.partitions.forEach(function(p) {
					devSelect.appendChild(E('option', { 'value': p.path }, p.path + ' ' + p.size_formated));
				});
			} else {
				devSelect.appendChild(E('option', { 'value': dev.path }, dev.path + ' ' + dev.size_formated));
			}
		});

		var fsSelect = E('select', { 'class': 'cbi-input-select' }, [
			E('option', { 'value': 'auto', 'selected': 'selected' }, 'auto'),
			E('option', { 'value': 'ext4' }, 'ext4'),
			E('option', { 'value': 'ext3' }, 'ext3'),
			E('option', { 'value': 'ext2' }, 'ext2'),
			E('option', { 'value': 'vfat' }, 'vfat'),
			E('option', { 'value': 'exfat' }, 'exfat'),
			E('option', { 'value': 'ntfs' }, 'ntfs'),
			E('option', { 'value': 'btrfs' }, 'btrfs')
		]);
		var optsInput = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'placeholder': 'rw,noauto', 'value': 'rw,noauto' });
		var mpInput = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'placeholder': '/media/diskX' });

		mountTable.appendChild(E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td' }, devSelect),
			E('td', { 'class': 'td' }, fsSelect),
			E('td', { 'class': 'td' }, optsInput),
			E('td', { 'class': 'td' }, mpInput),
			E('td', { 'class': 'td center' }, [
				E('button', {
					'class': 'btn cbi-button cbi-button-add',
					'click': function(ev) {
						ev.preventDefault();
						var d = devSelect.value;
						var p = mpInput.value;
						if (!d || !p) {
							ui.addNotification(null, E('p', {}, _('Please select a device and input mount point!')));
							return;
						}
						ui.showModal(_('Mounting'), [ E('p', { 'class': 'spinning' }, _('Mounting device...')) ]);
						callMount(d, p, fsSelect.value, optsInput.value).then(function(res) {
							if (res && res.code !== 0) {
								ui.addNotification(null, E('p', {}, res.error || _('Failed to mount.')));
							}
							location.reload();
						});
					}
				}, _('Mount'))
			])
		]));

		mountSection.appendChild(mountTable);
		viewRoot.appendChild(mountSection);

		// Section: Creation Tabs (RAID & Btrfs)
		var createSection = E('div', { 'class': 'cbi-section' }, [
			E('legend', {}, _('Creation'))
		]);

		var activeTab = 'raid';
		var tabNav = E('div', { 'class': 'cbi-tabmenu', 'style': 'margin-bottom:1rem;' });
		var tabContent = E('div', { 'class': 'cbi-tabcontainer' });

		function updateTabs() {
			dom.content(tabNav, [
				E('li', { 'class': 'cbi-tab' + (activeTab === 'raid' ? ' cbi-tab-active active' : '') }, [
					E('a', {
						'href': '#',
						'click': function(ev) {
							ev.preventDefault();
							activeTab = 'raid';
							updateTabs();
						}
					}, _('RAID'))
				]),
				E('li', { 'class': 'cbi-tab' + (activeTab === 'btrfs' ? ' cbi-tab-active active' : '') }, [
					E('a', {
						'href': '#',
						'click': function(ev) {
							ev.preventDefault();
							activeTab = 'btrfs';
							updateTabs();
						}
					}, _('Btrfs'))
				])
			]);

			if (activeTab === 'raid') {
				var rNameInput = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'value': '/dev/md0' });
				var rLevelSelect = E('select', { 'class': 'cbi-input-select' }, [
					E('option', { 'value': 'linear' }, 'Linear'),
					E('option', { 'value': '0' }, 'RAID 0'),
					E('option', { 'value': '1' }, 'RAID 1'),
					E('option', { 'value': '5' }, 'RAID 5'),
					E('option', { 'value': '6' }, 'RAID 6'),
					E('option', { 'value': '10' }, 'RAID 10')
				]);

				var rMemberSelect = E('select', { 'class': 'cbi-input-select' });
				rMemberSelect.appendChild(E('option', { 'value': '' }, _('-- Please choose --')));
				var devKeys = Object.keys(devices || {});
				devKeys.forEach(function(dKey) {
					var dev = devices[dKey];
					if (dev.partitions && dev.partitions.length > 0) {
						dev.partitions.forEach(function(p) {
							if (p.name && p.number > 0) {
								rMemberSelect.appendChild(E('option', { 'value': p.path }, p.path + ' ' + p.size_formated));
							}
						});
					} else {
						rMemberSelect.appendChild(E('option', { 'value': dev.path }, dev.path + ' ' + dev.size_formated));
					}
				});

				dom.content(tabContent, [
					E('div', { 'class': 'cbi-tab' }, [
						E('h4', { 'style': 'margin-bottom:1rem;' }, _('Create RAID')),
						E('div', { 'class': 'cbi-value' }, [
							E('label', { 'class': 'cbi-value-title' }, _('RAID Name')),
							E('div', { 'class': 'cbi-value-field' }, rNameInput)
						]),
						E('div', { 'class': 'cbi-value' }, [
							E('label', { 'class': 'cbi-value-title' }, _('RAID Level')),
							E('div', { 'class': 'cbi-value-field' }, rLevelSelect)
						]),
						E('div', { 'class': 'cbi-value' }, [
							E('label', { 'class': 'cbi-value-title' }, _('RAID Members')),
							E('div', { 'class': 'cbi-value-field' }, rMemberSelect)
						]),
						E('div', { 'class': 'cbi-value' }, [
							E('label', { 'class': 'cbi-value-title' }, ''),
							E('div', { 'class': 'cbi-value-field' }, [
								E('button', {
									'class': 'btn cbi-button cbi-button-add',
									'click': function(ev) {
										ev.preventDefault();
										var val = rMemberSelect.value;
										if (!val) {
											ui.addNotification(null, E('p', {}, _('Please select RAID member disks/partitions!')));
											return;
										}
										ui.showModal(_('Creating RAID'), [ E('p', { 'class': 'spinning' }, _('Creating RAID device...')) ]);
										callCreateRaid(rNameInput.value, rLevelSelect.value, [val]).then(function(res) {
											if (res && res.code !== 0) {
												ui.addNotification(null, E('p', {}, res.error || _('Failed to create RAID.')));
											}
											location.reload();
										});
									}
								}, _('Create RAID'))
							])
						])
					])
				]);
			} else {
				var bLabelInput = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'placeholder': 'data' });
				var bLevelSelect = E('select', { 'class': 'cbi-input-select' }, [
					E('option', { 'value': 'single' }, 'single'),
					E('option', { 'value': 'raid0' }, 'raid0'),
					E('option', { 'value': 'raid1' }, 'raid1'),
					E('option', { 'value': 'raid10' }, 'raid10'),
					E('option', { 'value': 'dup' }, 'dup')
				]);

				var bMemberSelect = E('select', { 'class': 'cbi-input-select' });
				bMemberSelect.appendChild(E('option', { 'value': '' }, _('-- Please choose --')));
				var devKeys = Object.keys(devices || {});
				devKeys.forEach(function(dKey) {
					var dev = devices[dKey];
					if (dev.partitions && dev.partitions.length > 0) {
						dev.partitions.forEach(function(p) {
							if (p.name && p.number > 0) {
								bMemberSelect.appendChild(E('option', { 'value': p.path }, p.path + ' ' + p.size_formated));
							}
						});
					} else {
						bMemberSelect.appendChild(E('option', { 'value': dev.path }, dev.path + ' ' + dev.size_formated));
					}
				});

				dom.content(tabContent, [
					E('div', { 'class': 'cbi-tab' }, [
						E('h4', { 'style': 'margin-bottom:1rem;' }, _('Create Btrfs')),
						E('div', { 'class': 'cbi-value' }, [
							E('label', { 'class': 'cbi-value-title' }, _('Btrfs Label')),
							E('div', { 'class': 'cbi-value-field' }, bLabelInput)
						]),
						E('div', { 'class': 'cbi-value' }, [
							E('label', { 'class': 'cbi-value-title' }, _('Btrfs Raid Level')),
							E('div', { 'class': 'cbi-value-field' }, bLevelSelect)
						]),
						E('div', { 'class': 'cbi-value' }, [
							E('label', { 'class': 'cbi-value-title' }, _('Btrfs Member')),
							E('div', { 'class': 'cbi-value-field' }, bMemberSelect)
						]),
						E('div', { 'class': 'cbi-value' }, [
							E('label', { 'class': 'cbi-value-title' }, ''),
							E('div', { 'class': 'cbi-value-field' }, [
								E('button', {
									'class': 'btn cbi-button cbi-button-add',
									'click': function(ev) {
										ev.preventDefault();
										var val = bMemberSelect.value;
										if (!val) {
											ui.addNotification(null, E('p', {}, _('Please select Btrfs member disks/partitions!')));
											return;
										}
										ui.showModal(_('Creating Btrfs'), [ E('p', { 'class': 'spinning' }, _('Creating Btrfs filesystem...')) ]);
										callCreateBtrfs(bLabelInput.value || 'data', bLevelSelect.value, [val]).then(function(res) {
											if (res && res.code !== 0) {
												ui.addNotification(null, E('p', {}, res.error || _('Failed to create Btrfs.')));
											}
											location.reload();
										});
									}
								}, _('Create Btrfs'))
							])
						])
					])
				]);
			}
		}

		updateTabs();
		createSection.appendChild(tabNav);
		createSection.appendChild(tabContent);
		viewRoot.appendChild(createSection);

		container.appendChild(viewRoot);
	},

	render: function(data) {
		var container = E('div', { 'class': 'cbi-map' });
		this.renderOverview(container, data);
		return container;
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
