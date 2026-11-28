'use strict';
'require view';
'require rpc';
'require ui';

var callListProfiles = rpc.declare({
	object: 'luci.wrtbox',
	method: 'list_profiles'
});

var callGetProfileContent = rpc.declare({
	object: 'luci.wrtbox',
	method: 'get_profile_content',
	params: ['id']
});

var callSaveProfile = rpc.declare({
	object: 'luci.wrtbox',
	method: 'save_profile',
	params: ['id', 'name', 'type', 'url', 'content']
});

var callDeleteProfile = rpc.declare({
	object: 'luci.wrtbox',
	method: 'delete_profile',
	params: ['id']
});

var callActivateProfile = rpc.declare({
	object: 'luci.wrtbox',
	method: 'activate_profile',
	params: ['id']
});

var callUpdateSubscription = rpc.declare({
	object: 'luci.wrtbox',
	method: 'update_subscription',
	params: ['id']
});

var callSaveSubSettings = rpc.declare({
	object: 'luci.wrtbox',
	method: 'save_sub_settings',
	params: ['auto_update', 'cron', 'user_agent']
});

function formatSize(bytes) {
	if (!bytes) return '-';
	if (bytes >= 1024) return (bytes / 1024).toFixed(1) + ' KB';
	return bytes + ' B';
}

return view.extend({
	tbodyEl: null,
	statusMsgEl: null,
	pendingDeleteId: null,

	load: function() {
		return callListProfiles();
	},

	setStatusMsg: function(text, isError) {
		if (!this.statusMsgEl) return;
		if (!text) {
			this.statusMsgEl.style.display = 'none';
			this.statusMsgEl.textContent = '';
			return;
		}
		this.statusMsgEl.style.display = 'block';
		this.statusMsgEl.style.color = isError ? '#c0392b' : '#27ae60';
		this.statusMsgEl.textContent = text;
	},

	reloadList: function() {
		var self = this;
		return callListProfiles().then(function(res) {
			self.renderTable((res && res.profiles) || []);
		});
	},

	openProfileModal: function(mode, existing) {
		var self = this;
		var isSub = (mode === 'subscription');
		var title = existing
			? _('Edit Profile: %s').format(existing.name)
			: (isSub ? _('Add Subscription') : _('Add Local JSON'));

		var nameInput = E('input', {
			'type': 'text',
			'class': 'cbi-input-text',
			'style': 'width:100%;max-width:100%;box-sizing:border-box;',
			'placeholder': _('Profile Name'),
			'value': existing ? existing.name : ''
		});

		var urlInput = E('input', {
			'type': 'text',
			'class': 'cbi-input-text',
			'style': 'width:100%;max-width:100%;box-sizing:border-box;',
			'placeholder': 'https://example.com/sing-box.json',
			'value': existing ? (existing.url || '') : ''
		});

		var textArea = E('textarea', {
			'class': 'cbi-input-textarea',
			'style': 'width:100%;max-width:100%;box-sizing:border-box;height:300px;font-family:monospace;font-size:12px;',
			'placeholder': '{\n  "inbounds": [...],\n  "outbounds": [...]\n}'
		});

		var fileInput = E('input', {
			'type': 'file',
			'accept': '.json,application/json',
			'style': 'width:100%;box-sizing:border-box;',
			'change': function(ev) {
				var file = ev.target.files && ev.target.files[0];
				if (!file) return;
				if (!nameInput.value) {
					nameInput.value = file.name.replace(/\.json$/i, '');
				}
				var reader = new FileReader();
				reader.onload = function(e) {
					textArea.value = e.target.result || '';
				};
				reader.readAsText(file);
			}
		});

		var modalMsg = E('div', { 'style': 'display:none;margin-top:8px;font-size:12px;color:#c0392b;' });

		function showModalError(msg) {
			modalMsg.style.display = 'block';
			modalMsg.textContent = msg;
		}

		var body = [
			E('div', { 'style': 'margin-bottom:12px;' }, [
				E('label', { 'style': 'display:block;font-weight:bold;margin-bottom:4px;' }, _('Name')),
				nameInput
			])
		];

		if (isSub) {
			body.push(E('div', { 'style': 'margin-bottom:12px;' }, [
				E('label', { 'style': 'display:block;font-weight:bold;margin-bottom:4px;' }, _('Subscription URL')),
				urlInput
			]));
		} else {
			body.push(E('div', { 'style': 'margin-bottom:12px;' }, [
				E('label', { 'style': 'display:block;font-weight:bold;margin-bottom:4px;' }, _('Upload JSON')),
				fileInput
			]));
		}

		if (!isSub || existing) {
			body.push(E('div', { 'style': 'margin-bottom:10px;' }, [
				E('div', { 'style': 'display:flex;justify-content:space-between;align-items:center;margin-bottom:6px;' }, [
					E('label', { 'style': 'font-weight:bold;' }, _('JSON Content')),
					E('button', {
						'type': 'button',
						'class': 'cbi-button cbi-button-action',
						'click': function() {
							modalMsg.style.display = 'none';
							try {
								var parsed = JSON.parse(textArea.value);
								textArea.value = JSON.stringify(parsed, null, 2);
							} catch (err) {
								showModalError(_('Invalid JSON: %s').format(err.message));
							}
						}
					}, _('Format JSON'))
				]),
				textArea
			]));
		}

		body.push(modalMsg);

		if (existing && existing.exists) {
			callGetProfileContent(existing.id).then(function(res) {
				if (res && res.ok) textArea.value = res.content || '';
			});
		}

		var saveBtn = E('button', {
			'type': 'button',
			'class': 'cbi-button cbi-button-positive',
			'click': function() {
				modalMsg.style.display = 'none';
				var name = (nameInput.value || '').trim();
				var url = isSub ? (urlInput.value || '').trim() : '';
				var content = textArea.value || '';

				if (!name) {
					showModalError(_('Please enter a profile name.'));
					return;
				}
				if (isSub && !/^https?:\/\//.test(url)) {
					showModalError(_('Subscription URL must start with http:// or https://'));
					return;
				}
				if (!isSub && !content.trim()) {
					showModalError(_('Please upload or enter sing-box JSON content.'));
					return;
				}
				if (content.trim()) {
					try {
						JSON.parse(content);
					} catch (err) {
						showModalError(_('Invalid JSON syntax: %s').format(err.message));
						return;
					}
				}

				saveBtn.disabled = true;
				var id = existing ? existing.id : '';
				callSaveProfile(id, name, mode, url, content).then(function(res) {
					if (!res || !res.ok) {
						saveBtn.disabled = false;
						showModalError(_('Save failed: %s').format((res && res.error) || 'unknown'));
						return;
					}
					if (isSub && !existing) {
						self.setStatusMsg(_('Fetching "%s"...').format(name), false);
						ui.hideModal();
						callUpdateSubscription(res.id).then(function(fres) {
							if (fres && fres.ok) {
								self.setStatusMsg('', false);
							} else {
								self.setStatusMsg(_('Fetch failed: %s').format((fres && fres.error) || 'unknown'), true);
							}
							self.reloadList();
						});
					} else {
						ui.hideModal();
						self.setStatusMsg('', false);
						self.reloadList();
					}
				}).catch(function(err) {
					saveBtn.disabled = false;
					showModalError(err.message || String(err));
				});
			}
		}, isSub && !existing ? _('Save & Fetch') : _('Save'));

		body.push(E('div', { 'style': 'display:flex;justify-content:flex-end;gap:8px;margin-top:14px;' }, [
			E('button', {
				'type': 'button',
				'class': 'cbi-button',
				'click': ui.hideModal
			}, _('Cancel')),
			saveBtn
		]));

		ui.showModal(title, body);
	},

	handleActivate: function(p) {
		var self = this;
		this.setStatusMsg('');
		return callActivateProfile(p.id).then(function(res) {
			if (!res || !res.ok) {
				self.setStatusMsg(_('Activation failed: %s').format((res && res.error) || 'unknown'), true);
				return;
			}
			self.reloadList();
		});
	},

	handleUpdateSub: function(id, label) {
		var self = this;
		this.setStatusMsg(_('Updating "%s"...').format(label), false);
		return callUpdateSubscription(id).then(function(res) {
			if (!res || !res.ok) {
				self.setStatusMsg(_('Update failed: %s').format((res && res.error) || 'unknown'), true);
			} else {
				self.setStatusMsg('', false);
			}
			self.reloadList();
		});
	},

	handleDelete: function(p, btnEl) {
		var self = this;
		if (this.pendingDeleteId !== p.id) {
			this.pendingDeleteId = p.id;
			btnEl.textContent = _('Confirm Delete');
			setTimeout(function() {
				if (self.pendingDeleteId === p.id) {
					self.pendingDeleteId = null;
					btnEl.textContent = _('Delete');
				}
			}, 4000);
			return;
		}
		this.pendingDeleteId = null;
		return callDeleteProfile(p.id).then(function() {
			self.setStatusMsg('', false);
			self.reloadList();
		});
	},

	renderTable: function(profiles) {
		var self = this;
		if (!this.tbodyEl) return;
		this.tbodyEl.innerHTML = '';

		if (!profiles || profiles.length === 0) {
			this.tbodyEl.appendChild(E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td center', 'colspan': '6' },
					E('em', {}, _('No profiles yet.')))
			]));
			return;
		}

		profiles.forEach(function(p) {
			var modes = (p.summary && p.summary.modes && p.summary.modes.length > 0)
				? p.summary.modes.join(', ')
				: '-';

			var statusBadge = p.active
				? E('span', { 'style': 'background:#27ae60;color:#fff;padding:2px 8px;border-radius:3px;font-size:11px;' }, _('Active'))
				: E('span', { 'style': 'color:#7f8c8d;font-size:12px;' }, _('Inactive'));

			var actions = [
				E('button', {
					'type': 'button',
					'class': 'cbi-button cbi-button-apply',
					'disabled': p.active ? '' : null,
					'click': function() { self.handleActivate(p); }
				}, _('Activate')),
				' '
			];

			if (p.type === 'subscription') {
				actions.push(E('button', {
					'type': 'button',
					'class': 'cbi-button cbi-button-action',
					'click': function() { self.handleUpdateSub(p.id, p.name); }
				}, _('Update')), ' ');
			}

			var delBtn = E('button', {
				'type': 'button',
				'class': 'cbi-button cbi-button-negative',
				'click': function() { self.handleDelete(p, delBtn); }
			}, _('Delete'));

			actions.push(
				E('button', {
					'type': 'button',
					'class': 'cbi-button',
					'click': function() { self.openProfileModal(p.type, p); }
				}, _('Edit')),
				' ',
				delBtn
			);

			self.tbodyEl.appendChild(E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td left' }, [
					E('strong', {}, p.name),
					p.url ? E('div', { 'style': 'font-size:11px;opacity:0.75;word-break:break-all;' }, p.url) : ''
				]),
				E('td', { 'class': 'td left' }, p.type === 'subscription' ? _('Subscription') : _('Local')),
				E('td', { 'class': 'td left' }, modes),
				E('td', { 'class': 'td left' }, [
					E('div', {}, formatSize(p.size)),
					E('div', { 'style': 'font-size:11px;opacity:0.75;' }, p.updated_at || '-')
				]),
				E('td', { 'class': 'td center' }, statusBadge),
				E('td', { 'class': 'td right', 'style': 'white-space:nowrap;' }, actions)
			]));
		});
	},

	render: function(data) {
		var self = this;
		var profiles = (data && data.profiles) || [];
		var subSettings = (data && data.sub_settings) || {
			auto_update: false,
			cron: '0 5 * * *',
			user_agent: 'sing-box'
		};

		this.tbodyEl = E('tbody', { 'id': 'wrtbox-profiles-tbody' });
		this.statusMsgEl = E('div', { 'style': 'display:none;margin-bottom:10px;font-size:12px;' });

		this.renderTable(profiles);

		var subCronRowEl = null;
		var subAutoEl = E('input', {
			'id': 'wrtbox-sub-auto-update',
			'type': 'checkbox',
			'checked': subSettings.auto_update ? 'checked' : null,
			'change': function() {
				if (subCronRowEl) {
					subCronRowEl.style.display = subAutoEl.checked ? '' : 'none';
				}
			}
		});

		var subCronEl = E('input', {
			'id': 'wrtbox-sub-cron',
			'type': 'text',
			'class': 'cbi-input-text',
			'value': subSettings.cron || '0 5 * * *',
			'placeholder': '0 5 * * *'
		});

		var subUaEl = E('input', {
			'id': 'wrtbox-sub-ua',
			'type': 'text',
			'class': 'cbi-input-text',
			'value': subSettings.user_agent || 'sing-box',
			'placeholder': 'sing-box'
		});

		var subSaveStatusEl = E('span', { 'style': 'margin-left:10px;font-size:12px;display:none;' });
		var subSaveBtnEl = E('button', {
			'type': 'button',
			'class': 'cbi-button cbi-button-apply',
			'click': function() {
				subSaveBtnEl.disabled = true;
				subSaveStatusEl.style.display = 'none';
				subSaveStatusEl.textContent = '';
				callSaveSubSettings(
					subAutoEl.checked ? '1' : '0',
					(subCronEl.value || '').trim() || '0 5 * * *',
					(subUaEl.value || '').trim() || 'sing-box'
				).then(function(res) {
					subSaveBtnEl.disabled = false;
					if (!res || !res.ok) {
						subSaveStatusEl.style.display = 'inline';
						subSaveStatusEl.style.color = '#c0392b';
						subSaveStatusEl.textContent = (res && res.error) || _('Failed');
						return;
					}
					if (res.sub_settings) {
						subAutoEl.checked = !!res.sub_settings.auto_update;
						subCronEl.value = res.sub_settings.cron || '0 5 * * *';
						subUaEl.value = res.sub_settings.user_agent || 'sing-box';
						if (subCronRowEl) {
							subCronRowEl.style.display = subAutoEl.checked ? '' : 'none';
						}
					}
					subSaveStatusEl.style.display = 'inline';
					subSaveStatusEl.style.color = '#27ae60';
					subSaveStatusEl.textContent = _('Settings saved.');
				}).catch(function(err) {
					subSaveBtnEl.disabled = false;
					subSaveStatusEl.style.display = 'inline';
					subSaveStatusEl.style.color = '#c0392b';
					subSaveStatusEl.textContent = _('RPC error: %s').format(err && err.message ? err.message : (err || 'unknown'));
				});
			}
		}, _('Save Settings'));

		subCronRowEl = E('div', {
			'class': 'cbi-value',
			'style': subSettings.auto_update ? '' : 'display:none;'
		}, [
			E('label', { 'class': 'cbi-value-title', 'for': 'wrtbox-sub-cron' }, _('Cron Schedule')),
			E('div', { 'class': 'cbi-value-field' }, [subCronEl])
		]);

		return E('div', {}, [
			E('style', {}, [
				'.cbi-section { background: var(--bg-card, #222327); border: 1px solid var(--border, #33363f); border-radius: 6px; overflow: hidden; margin-bottom: 16px; box-shadow: 0 4px 6px -1px rgba(0,0,0,0.1); }',
				'.cbi-section h3 { margin: 0; padding: 14px 18px; background: var(--bg-header, #2a2c32); border-bottom: 1px solid var(--border, #33363f); font-size: 15px; font-weight: 600; color: var(--text, #e4e6eb); }',
				'.cbi-section .cbi-value { display: flex; align-items: flex-start; padding: 14px 18px; border-bottom: 1px solid var(--border, #33363f); gap: 16px; }',
				'.cbi-section .cbi-value:last-child { border-bottom: none; }',
				'.cbi-section .cbi-value:first-of-type { padding-top: 18px !important; }',
				'.cbi-value-title { width: 240px; flex-shrink: 0; padding-top: 6px; font-weight: 500; color: var(--text, #e4e6eb); font-size: 13px; }',
				'.cbi-value-field { flex: 1; min-width: 0; }',
				'.cbi-value-description { margin-top: 6px; font-size: 12px; color: var(--text-muted, #9aa0aa); }',
				'.cbi-input-text, .cbi-input-select { width: 100%; max-width: 420px; background: var(--bg-input, #1b1c20); border: 1px solid var(--border, #33363f); border-radius: 5px; color: var(--text, #e4e6eb); padding: 8px 12px; font-size: 13px; outline: none; transition: border-color 0.15s ease; }',
				'.cbi-input-text:focus, .cbi-input-select:focus { border-color: #5e72e4; }',
				'.cbi-button { display: inline-flex; align-items: center; justify-content: center; gap: 6px; padding: 7px 14px; border-radius: 5px; border: 1px solid var(--border, #33363f); background: #2f323b; color: #fff; font-size: 13px; font-weight: 500; cursor: pointer; text-decoration: none; white-space: nowrap; transition: transform 0.12s ease, filter 0.15s ease; }',
				'.cbi-button:hover:not(:disabled) { filter: brightness(1.1); }',
				'.cbi-button:active:not(:disabled) { transform: scale(0.95); }',
				'.cbi-button:disabled { opacity: 0.55; cursor: not-allowed; }',
				'.cbi-button-positive { background: #27ae60; border-color: #27ae60; }',
				'.cbi-button-negative { background: #d9534f; border-color: #d9534f; }',
				'.cbi-button-apply { background: #5e72e4; border-color: #5e72e4; }',
				'.cbi-button-action { background: #4c5fd7; border-color: #4c5fd7; }',
				'@media (max-width: 720px) { .cbi-section .cbi-value { flex-direction: column; gap: 6px; } .cbi-value-title { width: auto; padding-top: 0; } }'
			].join('\n')),
			E('div', { 'class': 'cbi-map' }, [
				E('div', { 'style': 'margin-bottom:12px;display:flex;flex-wrap:wrap;gap:8px;' }, [
					E('button', {
						'type': 'button',
						'class': 'cbi-button cbi-button-positive',
						'click': function() { self.openProfileModal('local', null); }
					}, _('Upload JSON')),
					E('button', {
						'type': 'button',
						'class': 'cbi-button cbi-button-action',
						'click': function() { self.openProfileModal('subscription', null); }
					}, _('Add Subscription')),
					E('button', {
						'type': 'button',
						'class': 'cbi-button cbi-button-apply',
						'click': function() { self.handleUpdateSub('__all__', _('All')); }
					}, _('Update All'))
				]),

				this.statusMsgEl,

				E('div', { 'class': 'cbi-section' }, [
					E('table', { 'class': 'table cbi-section-table' }, [
						E('tr', { 'class': 'tr table-titles' }, [
							E('th', { 'class': 'th left' }, _('Name')),
							E('th', { 'class': 'th left' }, _('Type')),
							E('th', { 'class': 'th left' }, _('Inbounds')),
							E('th', { 'class': 'th left' }, _('Size')),
							E('th', { 'class': 'th left' }, _('Updated')),
							E('th', { 'class': 'th center' }, _('Status')),
							E('th', { 'class': 'th right' }, _('Actions'))
						]),
						this.tbodyEl
					])
				]),

				E('div', { 'class': 'cbi-section' }, [
					E('h3', {}, _('Subscription Settings')),
					E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title', 'for': 'wrtbox-sub-auto-update' }, _('Auto-Update Subscriptions')),
						E('div', { 'class': 'cbi-value-field' }, [
							E('div', { 'class': 'cbi-checkbox' }, [
								subAutoEl,
								E('label', { 'for': 'wrtbox-sub-auto-update' })
							])
						])
					]),
					subCronRowEl,
					E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title', 'for': 'wrtbox-sub-ua' }, _('User-Agent')),
						E('div', { 'class': 'cbi-value-field' }, [subUaEl])
					]),
					E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, ''),
						E('div', { 'class': 'cbi-value-field' }, [
							subSaveBtnEl,
							subSaveStatusEl
						])
					])
				])
			])
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
