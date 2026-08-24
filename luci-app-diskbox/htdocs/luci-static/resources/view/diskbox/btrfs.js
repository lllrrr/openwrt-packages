'use strict';
// Copyright (C) 2026 permails <https://github.com/permails/luci-app-diskbox>
// Licensed under the GNU General Public License v3.0
'require view';
'require rpc';
'require ui';
'require dom';

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

var callListBtrfsDevices = rpc.declare({
	object: 'luci.diskbox',
	method: 'list_btrfs_devices',
	expect: { btrfs_devices: {} }
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

return view.extend({
	load: function() {
		var uuid = (L.env && L.env.requestpath && L.env.requestpath[4]);
		if (!uuid) {
			return Promise.all([
				Promise.resolve({}),
				Promise.resolve([]),
				Promise.resolve(null),
				callListBtrfsDevices()
			]);
		}
		return Promise.all([
			callGetBtrfsInfo(uuid),
			callGetBtrfsSubvolumes(uuid),
			Promise.resolve(uuid),
			callListBtrfsDevices()
		]);
	},

	render: function(data) {
		var info = data[0] || {};
		var subvolumes = data[1] || [];
		var uuid = data[2];
		var btrfsList = data[3] || {};

		var viewRoot = E('div', { 'class': 'cbi-map' });

		// If no UUID was passed in URL or filesystem not found, show list of available Btrfs devices
		if (!uuid || !info.uuid) {
			var headerDiv = E('div', { 'style': 'margin-bottom:1rem;' }, [
				E('h2', { 'style': 'margin-bottom:0.25rem;' }, _('Btrfs Management')),
				E('div', { 'class': 'cbi-map-descr' }, _('Select a Btrfs filesystem to manage.'))
			]);
			viewRoot.appendChild(headerDiv);

			var btrfsKeys = Object.keys(btrfsList);
			if (btrfsKeys.length === 0) {
				viewRoot.appendChild(E('div', { 'class': 'cbi-section' }, [
					E('div', { 'style': 'padding:2rem; text-align:center;' }, [
						E('p', { 'style': 'font-size:1.1rem; color:#888;' }, _('No Btrfs filesystems found on this system.')),
						E('a', {
							'class': 'btn cbi-button cbi-button-add',
							'href': L.url('admin/system/diskbox'),
							'style': 'margin-top:1rem;'
						}, _('Go to DiskBox to Create Btrfs'))
					])
				]));
				var errFooter = E('div', { 'class': 'cbi-page-actions' }, [
					E('a', {
						'class': 'btn cbi-button cbi-button-link',
						'href': L.url('admin/system/diskbox')
					}, _('Back to Overview'))
				]);
				viewRoot.appendChild(errFooter);
				return viewRoot;
			}

			var btrfsSection = E('div', { 'class': 'cbi-section' }, [
				E('legend', {}, _('Available Btrfs Filesystems'))
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
				var b = btrfsList[uKey];
				btrfsTable.appendChild(E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td' }, E('code', {}, b.uuid)),
					E('td', { 'class': 'td' }, b.label || '-'),
					E('td', { 'class': 'td' }, b.members || '-'),
					E('td', { 'class': 'td' }, b.used_formated || '-'),
					E('td', { 'class': 'td center' }, [
						E('a', {
							'class': 'btn cbi-button cbi-button-action',
							'href': L.url('admin/system/diskbox/btrfs', b.uuid)
						}, _('Edit'))
					])
				]));
			});
			btrfsSection.appendChild(btrfsTable);
			viewRoot.appendChild(btrfsSection);

			var footerDiv = E('div', { 'class': 'cbi-page-actions' }, [
				E('a', {
					'class': 'btn cbi-button cbi-button-link',
					'href': L.url('admin/system/diskbox')
				}, _('Back to Overview'))
			]);
			viewRoot.appendChild(footerDiv);

			return viewRoot;
		}

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
					location.reload();
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
						location.reload();
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
						location.reload();
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
					location.reload();
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
							location.reload();
						});
					}
				}, _('Create Snapshot'))
			])
		]));

		viewRoot.appendChild(snapSection);

		// Footer Action Bar
		var footerDiv = E('div', { 'class': 'cbi-page-actions' }, [
			E('a', {
				'class': 'btn cbi-button cbi-button-link',
				'href': L.url('admin/system/diskbox')
			}, _('Back to Overview'))
		]);
		viewRoot.appendChild(footerDiv);

		return viewRoot;
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
