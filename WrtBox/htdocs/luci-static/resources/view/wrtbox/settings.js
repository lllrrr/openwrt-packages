'use strict';
'require view';
'require form';
'require rpc';

var callSyncCron = rpc.declare({
	object: 'luci.wrtbox',
	method: 'sync_cron'
});

var callGetStatus = rpc.declare({
	object: 'luci.wrtbox',
	method: 'get_status'
});

var callCheckCoreUpdate = rpc.declare({
	object: 'luci.wrtbox',
	method: 'check_core_update',
	params: ['channel']
});

var callInstallCore = rpc.declare({
	object: 'luci.wrtbox',
	method: 'install_core',
	params: ['channel', 'tag']
});

var callUninstallCore = rpc.declare({
	object: 'luci.wrtbox',
	method: 'uninstall_core'
});

var callGetCoreTask = rpc.declare({
	object: 'luci.wrtbox',
	method: 'get_core_task'
});

var callSaveCdn = rpc.declare({
	object: 'luci.wrtbox',
	method: 'save_cdn',
	params: ['enabled', 'url']
});

var callTestCdn = rpc.declare({
	object: 'luci.wrtbox',
	method: 'test_cdn',
	params: ['url']
});

return view.extend({
	taskPollTimer: null,
	latestRelease: null,
	mapObj: null,

	load: function() {
		return Promise.all([
			callGetStatus(),
			callGetCoreTask()
		]);
	},

	syncCdnFromForm: function() {
		if (!this.mapObj) return Promise.resolve();
		var enabledOpt = this.mapObj.lookupOption('cdn_enabled', 'main');
		var urlOpt = this.mapObj.lookupOption('cdn_url', 'main');

		var enabled = enabledOpt && enabledOpt[0] ? enabledOpt[0].formvalue('main') : '1';
		var url = urlOpt && urlOpt[0] ? (urlOpt[0].formvalue('main') || '').trim() : '';

		return callSaveCdn(enabled || '0', url);
	},

	getChannelFromForm: function() {
		if (!this.mapObj) return 'stable';
		var chOpt = this.mapObj.lookupOption('core_channel', 'main');
		return (chOpt && chOpt[0] && chOpt[0].formvalue('main')) || 'stable';
	},

	render: function(data) {
		var self = this;
		var st = (data && data[0]) || {};
		var task = (data && data[1]) || {};
		var m, s, o;

		m = new form.Map('wrtbox');
		this.mapObj = m;

		s = m.section(form.NamedSection, 'main', 'main', _('Core Settings'));
		s.anonymous = true;
		s.addremove = false;

		o = s.option(form.Value, 'core_path', _('Core Binary Path'),
			_('Independent installation path for sing-box. Does not overwrite /usr/bin/sing-box.'));
		o.value('/usr/libexec/wrtbox/sing-box', '/usr/libexec/wrtbox/sing-box (' + _('Flash') + ')');
		o.value('/tmp/wrtbox/sing-box', '/tmp/wrtbox/sing-box (' + _('RAM') + ')');
		o.value('/opt/wrtbox/sing-box', '/opt/wrtbox/sing-box (' + _('External') + ')');
		o.default = '/usr/libexec/wrtbox/sing-box';
		o.rmempty = false;

		o = s.option(form.ListValue, 'core_channel', _('Release Channel'));
		o.value('stable', _('Stable'));
		o.value('prerelease', _('Testing'));
		o.default = 'stable';

		o = s.option(form.Flag, 'cdn_enabled', _('CDN Acceleration'),
			_('Accelerate GitHub downloads for core binary installation and updates.'));
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.Value, 'cdn_url', _('CDN URL'));
		o.value('https://ghfast.top/', 'https://ghfast.top/');
		o.value('https://gh-proxy.com/', 'https://gh-proxy.com/');
		o.value('https://gh-proxy.org/', 'https://gh-proxy.org/');
		o.value('https://ghproxy.net/', 'https://ghproxy.net/');
		o.value('https://gh.llkk.cc/', 'https://gh.llkk.cc/');
		o.value('https://ghproxy.cc/', 'https://ghproxy.cc/');
		o.value('https://mirror.ghproxy.com/', 'https://mirror.ghproxy.com/');
		o.value('https://gh.ddlc.top/', 'https://gh.ddlc.top/');
		o.value('https://v6.gh-proxy.com/', 'https://v6.gh-proxy.com/');
		o.value('https://edgeone.gh-proxy.com/', 'https://edgeone.gh-proxy.com/');
		o.default = 'https://ghfast.top/';
		o.depends('cdn_enabled', '1');

		var cdnTestResultEl = E('div', { 'style': 'margin-top:8px;font-size:12px;' });
		var updateInfoEl = E('div', { 'style': 'margin-top:8px;font-size:12px;' },
			st.core_exists
				? _('Current: %s (%s)').format(st.core_version || st.core_tag || _('Installed'), st.arch || '-')
				: _('Core binary not installed yet (%s).').format(st.arch || '-'));
		var progressBoxEl = E('div', { 'style': 'display:none;margin-top:8px;' });
		var pendingUninstall = false;
		var uninstallBtnEl = E('button', {
			'type': 'button',
			'class': 'cbi-button cbi-button-negative',
			'style': st.core_exists ? '' : 'display:none;',
			'click': function() {
				if (!pendingUninstall) {
					pendingUninstall = true;
					uninstallBtnEl.textContent = _('Confirm Uninstall');
					setTimeout(function() {
						if (pendingUninstall) {
							pendingUninstall = false;
							uninstallBtnEl.textContent = _('Uninstall Core');
						}
					}, 4000);
					return;
				}
				pendingUninstall = false;
				uninstallBtnEl.disabled = true;
				uninstallBtnEl.textContent = _('Uninstall Core');
				callUninstallCore().then(function(res) {
					uninstallBtnEl.disabled = false;
					if (!res || !res.ok) {
						updateInfoEl.style.color = '#c0392b';
						updateInfoEl.textContent = _('Failed: %s').format((res && res.error) || 'unknown');
						return;
					}
					self.latestRelease = null;
					uninstallBtnEl.style.display = 'none';
					installBtnEl.textContent = _('Install Core');
					progressBoxEl.style.display = 'none';
					updateInfoEl.style.color = '';
					updateInfoEl.textContent = _('Core uninstalled.');
				});
			}
		}, _('Uninstall Core'));

		var installBtnEl = E('button', {
			'type': 'button',
			'class': 'cbi-button cbi-button-apply',
			'click': function() {
				var ch = self.getChannelFromForm();
				var tag = (self.latestRelease && self.latestRelease.tag) ? self.latestRelease.tag : '';
				self.syncCdnFromForm().then(function() {
					return callInstallCore(ch, tag);
				}).then(function(res) {
					if (!res || !res.ok) {
						updateInfoEl.style.color = '#c0392b';
						updateInfoEl.textContent = _('Failed: %s').format((res && res.error) || 'unknown');
						return;
					}
					startPolling();
				});
			}
		}, st.core_exists ? _('Update Core') : _('Install Core'));

		function startPolling() {
			if (self.taskPollTimer) clearInterval(self.taskPollTimer);
			var tick = function() {
				callGetCoreTask().then(function(t) {
					if (!t || (t.status === 'idle' && !t.message)) {
						progressBoxEl.style.display = 'none';
						return;
					}
					progressBoxEl.style.display = 'block';
					var barColor = t.status === 'error' ? '#c0392b' : (t.status === 'success' ? '#27ae60' : '#2980b9');
					progressBoxEl.innerHTML = '';
					progressBoxEl.appendChild(E('div', {}, [
						E('div', { 'style': 'background:#e0e0e0;border-radius:4px;overflow:hidden;height:8px;margin-bottom:6px;' }, [
							E('div', { 'style': 'height:100%;transition:width 0.3s;width:' + (t.progress || 0) + '%;background:' + barColor + ';' })
						]),
						E('div', { 'style': 'font-size:12px;' }, t.message || '')
					]));

					if (t.status === 'success' || t.status === 'error') {
						clearInterval(self.taskPollTimer);
						self.taskPollTimer = null;
						if (t.status === 'success') {
							callGetStatus().then(function(ns) {
								if (ns && ns.core_exists) {
									installBtnEl.textContent = _('Update Core');
									uninstallBtnEl.style.display = '';
									updateInfoEl.style.color = '';
									updateInfoEl.textContent = _('Current: %s (%s)').format(ns.core_version || ns.core_tag || _('Installed'), ns.arch || '-');
								}
							});
						}
					}
				});
			};
			tick();
			self.taskPollTimer = setInterval(tick, 1500);
		}

		o = s.option(form.DummyValue, '_core_actions', _('Core Management'));
		o.renderWidget = function() {
			return E('div', {}, [
				E('div', { 'style': 'display:flex;flex-wrap:wrap;gap:8px;align-items:center;' }, [
					E('button', {
						'type': 'button',
						'class': 'cbi-button cbi-button-action',
						'click': function() {
							var ch = self.getChannelFromForm();
							updateInfoEl.style.color = '';
							updateInfoEl.innerHTML = '';
							updateInfoEl.appendChild(E('span', { 'class': 'spinning' }, _('Checking...')));
							self.syncCdnFromForm().then(function() {
								return callCheckCoreUpdate(ch);
							}).then(function(res) {
								updateInfoEl.innerHTML = '';
								if (!res || !res.ok) {
									updateInfoEl.style.color = '#c0392b';
									updateInfoEl.textContent = _('Check failed: %s').format((res && res.error) || 'unknown');
									return;
								}
								self.latestRelease = res;
								var badge = res.prerelease
									? E('span', { 'style': 'background:#e67e22;color:#fff;padding:2px 6px;border-radius:3px;font-size:11px;margin-left:6px;' }, _('Testing'))
									: E('span', { 'style': 'background:#27ae60;color:#fff;padding:2px 6px;border-radius:3px;font-size:11px;margin-left:6px;' }, _('Stable'));
								updateInfoEl.appendChild(E('div', {}, [
									E('strong', {}, _('Latest: ')),
									E('code', {}, res.tag),
									badge,
									E('span', { 'style': 'margin-left:8px;opacity:0.8;' }, res.asset_name)
								]));
								installBtnEl.textContent = _('Install (%s)').format(res.tag);
							});
						}
					}, _('Check')),
					installBtnEl,
					uninstallBtnEl,
					E('button', {
						'type': 'button',
						'class': 'cbi-button',
						'click': function(ev) {
							var btn = ev.currentTarget;
							var urlOpt = self.mapObj.lookupOption('cdn_url', 'main');
							var enabledOpt = self.mapObj.lookupOption('cdn_enabled', 'main');
							var url = urlOpt && urlOpt[0] ? (urlOpt[0].formvalue('main') || '').trim() : '';
							btn.disabled = true;
							cdnTestResultEl.style.color = '';
							cdnTestResultEl.innerHTML = '';
							cdnTestResultEl.appendChild(E('span', { 'class': 'spinning' }, _('Testing all CDNs...')));
							callTestCdn(url).then(function(res) {
								btn.disabled = false;
								cdnTestResultEl.innerHTML = '';
								if (res && res.ok && res.best_url) {
									if (enabledOpt && enabledOpt[0] && enabledOpt[0].getUIElement) {
										var enEl = enabledOpt[0].getUIElement('main');
										if (enEl && enEl.setValue) enEl.setValue('1');
									}
									if (urlOpt && urlOpt[0] && urlOpt[0].getUIElement) {
										var urlEl = urlOpt[0].getUIElement('main');
										if (urlEl && urlEl.setValue) urlEl.setValue(res.best_url);
									}
									cdnTestResultEl.appendChild(E('div', { 'style': 'color:#27ae60;font-weight:bold;margin-bottom:6px;' },
										_('Fastest: %s (%d ms, %d/%d available)').format(
											res.best_url,
											res.best_latency_ms || 0,
											res.available || 0,
											res.tested || 0
										)));
									if (res.results && res.results.length > 0) {
										cdnTestResultEl.appendChild(E('div', { 'style': 'display:flex;flex-wrap:wrap;gap:6px;' },
											res.results.map(function(item) {
												var isBest = item.url === res.best_url;
												var label = item.url.replace(/^https?:\/\//, '').replace(/\/$/, '');
												var txt = item.ok ? (label + ' (' + item.latency_ms + 'ms)') : (label + ' (' + _('Failed') + ')');
												var bg = isBest ? '#27ae60' : (item.ok ? '#34495e' : '#95a5a6');
												return E('span', {
													'style': 'display:inline-block;padding:2px 6px;border-radius:3px;font-size:11px;color:#fff;background:' + bg + ';opacity:' + (item.ok ? '1' : '0.65') + ';'
												}, txt);
											})
										));
									}
								} else {
									cdnTestResultEl.style.color = '#c0392b';
									cdnTestResultEl.textContent = (res && res.error) || _('All CDN nodes failed or timed out');
								}
							}).catch(function(err) {
								btn.disabled = false;
								cdnTestResultEl.innerHTML = '';
								cdnTestResultEl.style.color = '#c0392b';
								cdnTestResultEl.textContent = _('Failed: %s').format(err && err.message ? err.message : (err || 'unknown'));
							});
						}
					}, _('Test CDN'))
				]),
				cdnTestResultEl,
				updateInfoEl,
				progressBoxEl
			]);
		};

		o = s.option(form.Flag, 'core_auto_update', _('Auto-Update Core'));
		o.default = '0';

		o = s.option(form.Value, 'core_update_cron', _('Cron Schedule'));
		o.default = '0 4 * * 1';
		o.depends('core_auto_update', '1');

		if (task && task.status === 'running') {
			startPolling();
		}

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
				'.cbi-page-actions { display: flex; justify-content: flex-end; flex-wrap: wrap; gap: 8px; padding: 14px 18px; background: rgba(0,0,0,0.12); border-top: 1px solid var(--border, #33363f); }',
				'@media (max-width: 720px) { .cbi-section .cbi-value { flex-direction: column; gap: 6px; } .cbi-value-title { width: auto; padding-top: 0; } }'
			].join('\n')),
			m.render()
		]);
	},

	handleSaveApply: function(ev, mode) {
		return this.super('handleSaveApply', [ev, mode]).then(function() {
			return callSyncCron();
		});
	}
});
