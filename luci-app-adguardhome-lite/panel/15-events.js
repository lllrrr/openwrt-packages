	function initEvents() {
		var tabs = document.querySelectorAll('.agh-tab');
		for (var i = 0; i < tabs.length; i++) {
			tabs[i].onclick = function () {
				switchTab(this.getAttribute('data-tab'));
			};
		}
		var gotoButtons = document.querySelectorAll('[data-goto]');
		for (var j = 0; j < gotoButtons.length; j++) {
			gotoButtons[j].onclick = function () {
				switchTab(this.getAttribute('data-goto'));
			};
		}
		var subTabs = document.querySelectorAll('#agh-settings-tabs .agh-subtab');
		for (var k = 0; k < subTabs.length; k++) {
			subTabs[k].onclick = function () {
				switchSettingsTab(this.getAttribute('data-subtab'));
			};
		}
		var logTabs = document.querySelectorAll('#agh-logs-tabs .agh-subtab');
		for (var m = 0; m < logTabs.length; m++) {
			logTabs[m].onclick = function () {
				switchLogTab(this.getAttribute('data-logtab'));
			};
		}

		if ($('agh-refresh-status')) $('agh-refresh-status').onclick = function () { refreshStatus(); };
		if ($('agh-stats-clear')) $('agh-stats-clear').onclick = clearStats;
		if ($('agh-theme-toggle')) $('agh-theme-toggle').onclick = toggleTheme;
		if ($('agh-legacy-clean')) $('agh-legacy-clean').onclick = cleanLegacy;
		if ($('agh-selftest-btn')) $('agh-selftest-btn').onclick = runSelftest;
		if ($('agh-selftest-close')) $('agh-selftest-close').onclick = closeSelftestModal;
		if ($('agh-selftest-mask')) $('agh-selftest-mask').onclick = closeSelftestModal;
		if ($('agh-selftest-retry')) $('agh-selftest-retry').onclick = runSelftest;
		document.addEventListener('keydown', function (e) {
			var selftest = $('agh-selftest-modal');
			if (e.key === 'Escape' && selftest && !selftest.hidden) closeSelftestModal();
		});
		if ($('agh-install-btn')) $('agh-install-btn').onclick = installCore;
		if ($('agh-enable-btn')) $('agh-enable-btn').onclick = function () {
			postService('bootstrap', '将启动 AdGuard Home 并接管路由器 DNS。确定继续？');
		};
		if ($('agh-start-btn')) $('agh-start-btn').onclick = function () { postService('start'); };
		if ($('agh-stop-btn')) $('agh-stop-btn').onclick = function () {
			postService('stop', '将停止 AdGuard Home 并关闭面板，同时恢复 DNSMasq 原始设置。确定继续？');
		};
		if ($('agh-restart-btn')) $('agh-restart-btn').onclick = function () {
			postService('restart', '将重启 AdGuard Home 服务。确定继续？');
		};
		if ($('agh-settings-form')) $('agh-settings-form').onsubmit = saveSettings;
		if ($('agh-cache-form')) $('agh-cache-form').onsubmit = saveSettings;
		if ($('agh-upstream-form')) $('agh-upstream-form').onsubmit = saveSettings;
		if ($('agh-crypto-form')) $('agh-crypto-form').onsubmit = saveSettings;

		if ($('agh-plugin-update')) $('agh-plugin-update').onclick = openPluginUpdateModal;
		if ($('agh-plugin-version')) {
			$('agh-plugin-version').onclick = checkPluginUpdate;
			$('agh-plugin-version').onkeydown = function (e) {
				if (e.key === 'Enter' || e.key === ' ') {
					e.preventDefault();
					checkPluginUpdate();
				}
			};
		}
		if ($('agh-plugin-update-cancel')) $('agh-plugin-update-cancel').onclick = closePluginUpdateModal;
		if ($('agh-plugin-update-mask')) $('agh-plugin-update-mask').onclick = closePluginUpdateModal;
		if ($('agh-plugin-update-start')) $('agh-plugin-update-start').onclick = startPluginUpdate;
		if ($('agh-plugin-force')) $('agh-plugin-force').onchange = togglePluginForce;
		if ($('agh-plugin-version-input')) $('agh-plugin-version-input').oninput = syncPluginNotes;
		if ($('agh-plugin-update-dismiss')) $('agh-plugin-update-dismiss').onclick = hidePluginProgress;
		document.addEventListener('keydown', function (e) {
			if (e.key !== 'Escape') return;
			var modal = $('agh-plugin-update-modal');
			if (modal && !modal.hidden) closePluginUpdateModal();
		});

		bindFilterSwitch('agh-filter-enabled', 'filtering');
		bindParentalSwitch();
		bindFilterSwitch('agh-filter-safesearch', 'safesearch');
		bindFilterSwitch('agh-filter-safebrowsing', 'safebrowsing');
		bindMemoryTrim();
		bindPresetSource();

		// 成人内容拦截与家长控制功能重叠，开启其中一个时自动关闭另一个
		if ($('agh-filter-adult')) {
			$('agh-filter-adult').onchange = async function () {
				var el = this;
				var parental = $('agh-filter-parental');
				var parentalWasOn = !!(parental && parental.checked);
				if (el.checked && parentalWasOn) {
					if (parental) parental.checked = false;
					var ok = await filtersAction({ action: 'feature', feature: 'parental', value: '0' });
					if (!ok) {
						el.checked = false;
						return;
					}
				}
				toggleAdultFilter(el.checked);
			};
		}

		if ($('agh-filter-add-form')) {
			$('agh-filter-add-form').onsubmit = function (e) {
				e.preventDefault();
				var url = ($('agh-filter-url') ? $('agh-filter-url').value : '').trim();
				if (!url) {
					setMsg($('agh-filters-msg'), '请填写订阅地址。', 'bad');
					return;
				}
				filtersAction({
					action: 'add',
					name: ($('agh-filter-name') ? $('agh-filter-name').value : '').trim(),
					url: url,
					whitelist: ($('agh-filter-whitelist') && $('agh-filter-whitelist').value === '1') ? '1' : '0'
				});
			};
		}
		if ($('agh-filter-rules-form')) {
			$('agh-filter-rules-form').onsubmit = async function (e) {
				e.preventDefault();
				var ok = await filtersAction({ action: 'rules', rules: $('agh-filter-rules') ? $('agh-filter-rules').value : '' });
				if (ok) state.rulesDirty = false;
			};
		}
		if ($('agh-filter-rules')) {
			$('agh-filter-rules').oninput = function () {
				state.rulesDirty = true;
			};
		}
		if ($('agh-filter-doh')) {
			$('agh-filter-doh').onchange = function () {
				toggleDohBlock(this.checked).then(function () {
					updateSwitchStates();
				});
			};
		}
		if ($('agh-retention-form')) {
			$('agh-retention-form').onsubmit = async function (e) {
				e.preventDefault();
				var msg = $('agh-retention-msg');
				var btn = $('agh-save-retention-btn');
				if (btn) btn.disabled = true;
				try {
					await apiPost(U.retention, {
						days: $('agh-set-stats-days') ? $('agh-set-stats-days').value : '30',
						query_days: $('agh-set-querylog-days') ? $('agh-set-querylog-days').value : '30'
					});
					showToast('保留周期已保存，正在应用...', 'ok');
					pollAction(function () {
						if (btn) btn.disabled = false;
					});
				} catch (err) {
					if (btn) btn.disabled = false;
					handleApiError(err, msg);
				}
			};
		}
		if ($('agh-querylog-refresh')) {
			$('agh-querylog-refresh').onclick = function () { resetQueryLog(); };
		}
		if ($('agh-querylog-prev')) {
			$('agh-querylog-prev').onclick = function () { loadQueryPage(state.queryPage - 1); };
		}
		if ($('agh-querylog-next')) {
			$('agh-querylog-next').onclick = function () { loadQueryPage(state.queryPage + 1); };
		}
		var qfilter = document.querySelectorAll('#agh-querylog-filter button');
		for (var qi = 0; qi < qfilter.length; qi++) {
			qfilter[qi].onclick = function () {
				state.queryStatus = this.getAttribute('data-qstatus') || '';
				for (var k = 0; k < qfilter.length; k++) {
					qfilter[k].classList.toggle('is-active', qfilter[k] === this);
				}
				resetQueryLog();
			};
		}
		var qsearchTimer = null;
		if ($('agh-querylog-search')) {
			$('agh-querylog-search').oninput = function () {
				var value = this.value;
				if (qsearchTimer) clearTimeout(qsearchTimer);
				qsearchTimer = setTimeout(function () {
					state.querySearch = value.replace(/^\s+|\s+$/g, '');
					resetQueryLog();
				}, 400);
			};
		}
		if ($('agh-querylog-auto')) {
			var startQueryTimer = function () {
				if (state.queryTimer) {
					clearInterval(state.queryTimer);
					state.queryTimer = null;
				}
				if (state.queryAuto > 0) {
					state.queryTimer = setInterval(function () {
						if (document.hidden || state.logSubtab !== 'query') return;
						var panel = $('agh-tab-logs');
						if (!panel || !panel.classList.contains('is-active')) return;
						reloadQueryPage();
					}, state.queryAuto * 1000);
				}
			};
			$('agh-querylog-auto').onchange = function () {
				state.queryAuto = Number(this.value) || 0;
				startQueryTimer();
			};
			// 默认每 5 秒自动刷新
			state.queryAuto = Number($('agh-querylog-auto').value) || 0;
			startQueryTimer();
		}
		if ($('agh-set-cache-enabled')) $('agh-set-cache-enabled').onchange = applyCacheLocks;
		if ($('agh-set-upstream-source')) $('agh-set-upstream-source').onchange = applyUpstreamLocks;
		if ($('agh-set-dns-crypto')) $('agh-set-dns-crypto').onchange = applyCryptoLocks;
		if ($('agh-set-dns-mode')) {
			$('agh-set-dns-mode').onchange = function () {
				applyModeLocks(this.value);
			};
		}
		if ($('agh-bypass-iface-toggle')) {
			$('agh-bypass-iface-toggle').onclick = function (e) {
				e.stopPropagation();
				var menu = $('agh-bypass-iface-menu');
				if (menu) menu.hidden = !menu.hidden;
			};
			document.addEventListener('click', function (e) {
				var menu = $('agh-bypass-iface-menu');
				var dd = $('agh-bypass-iface-dd');
				if (menu && !menu.hidden && dd && !dd.contains(e.target)) menu.hidden = true;
			});
		}
		if ($('agh-password-form')) $('agh-password-form').onsubmit = savePassword;
		if ($('agh-yaml-load')) $('agh-yaml-load').onclick = async function () {
			if (state.yamlLoaded && !(await aghConfirm('重新加载会丢弃当前未保存的修改。确定继续？'))) return;
			loadYaml();
		};
		if ($('agh-yaml-save')) $('agh-yaml-save').onclick = saveYaml;
		if ($('agh-yaml-editor')) $('agh-yaml-editor').oninput = updateYamlCount;

		if ($('agh-log-refresh')) {
			$('agh-log-refresh').onclick = async function () {
				var btn = this;
				if (btn.disabled) return;
				var label = btn.textContent;
				btn.disabled = true;
				btn.textContent = '刷新中...';
				try {
					await loadLogs();
				} finally {
					btn.disabled = false;
					btn.textContent = label;
				}
			};
		}
		if ($('agh-log-level')) {
			$('agh-log-level').onchange = function () {
				state.logLevel = this.value || '';
				loadLogs();
			};
		}
		if ($('agh-log-download')) $('agh-log-download').onclick = downloadLogs;
		if ($('agh-log-auto')) {
			$('agh-log-auto').onchange = function () {
				if (state.logTimer) {
					clearInterval(state.logTimer);
					state.logTimer = null;
				}
				if (this.checked) {
					state.logTimer = setInterval(function () {
						if (document.hidden || state.logSubtab !== 'sys') return;
						var panel = $('agh-tab-logs');
						if (!panel || !panel.classList.contains('is-active')) return;
						loadLogs();
					}, 5000);
				}
			};
			// 默认开启 5 秒自动刷新
			if ($('agh-log-auto').checked) {
				state.logTimer = setInterval(function () {
					if (document.hidden || state.logSubtab !== 'sys') return;
					var panel = $('agh-tab-logs');
					if (!panel || !panel.classList.contains('is-active')) return;
					loadLogs();
				}, 5000);
			}
		}

		window.addEventListener('hashchange', function () {
			switchTab((window.location.hash || '#overview').replace('#', ''), false);
		});

		document.addEventListener('change', function (e) {
			if (e.target && e.target.type === 'checkbox') updateSwitchStates();
		});
	}

