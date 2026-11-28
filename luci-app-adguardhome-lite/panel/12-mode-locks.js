	function applyModeLocks(mode) {
		var takeover = mode === 'takeover';
		var group = $('agh-bypass-group');
		if (group) {
			group.classList.toggle('is-locked', !takeover);
			Array.prototype.slice.call(group.querySelectorAll('input, button, select')).forEach(function (el) {
				el.disabled = !takeover;
			});
			if (!takeover) {
				var menu = $('agh-bypass-iface-menu');
				if (menu) menu.hidden = true;
			}
		}
		var note = $('agh-bypass-note');
		if (note) note.style.display = takeover ? 'none' : '';

		var clashOption = document.querySelector('#agh-set-dns-mode option[value="clashfirst"]');
		if (clashOption) {
			clashOption.disabled = !state.openclash;
			clashOption.textContent = state.openclash
				? 'Clash 前置（Clash 7874 → AGH 5335 → 真实 DNS）'
				: 'Clash 前置（未安装 Clash，不可用）';
		}

		var passwallOption = document.querySelector('#agh-set-dns-mode option[value="passwall"]');
		if (passwallOption) {
			passwallOption.disabled = !state.passwall;
			passwallOption.textContent = state.passwall
				? 'PassWall / PassWall2 前置（AGH 53 → PassWall DNS 分流，保留劫持）'
				: 'PassWall / PassWall2 前置（未安装 PassWall，不可用）';
		}

		var modeNote = $('agh-dns-mode-note');
		if (modeNote) {
			var text = '';
			if (state.openclash && mode === 'upstream') {
				text = '检测到 Clash：该模式会改写 DNSMasq 上游，重启 Clash 后可能被覆盖，建议改用「接管 53 端口」。';
			} else if (!state.openclash && mode === 'clashfirst') {
				text = 'Clash 未安装，「Clash 前置」模式不会生效，请改用「接管 53 端口」。';
			} else if (mode === 'passwall' && !state.passwallEnabled) {
				text = 'PassWall / PassWall2 当前未启用：AdGuard Home 会把查询转给本机 DNSMasq（1745）。启用后会在 10 秒内自动切回 PassWall 分流。';
			} else if (mode === 'passwall') {
				text = 'PassWall DNS 端口：' + (state.passwallDnsPort || '11400') + '，保存后自动写入 AdGuard Home 上游，端口变化会自动跟随。';
			}
			modeNote.textContent = text;
			modeNote.style.display = text ? '' : 'none';
		}
		applyUpstreamLocks();
		applyCryptoLocks();
	}

	async function loadSettings() {
		var msgEl = $('agh-settings-msg');
		try {
			var d = await apiGet(U.settingsGet);
			if (d && d.ok === false) throw new Error(d.error || '读取设置失败');
			state.settings = d;
			var enabled = $('agh-set-enabled');
			if (enabled) enabled.checked = !!d.enabled;
			setSelectValue('agh-set-dns-mode', d.dns_mode);
			var port = $('agh-set-webport');
			if (port) port.value = d.webport;
			setSelectValue('agh-set-webaddr', d.webaddr || '0.0.0.0');
			setSelectValue('agh-set-binpath', d.binpath);
			setSelectValue('agh-set-workdir', d.workdir);
			setSelectValue('agh-set-channel', d.channel);
			setSelectValue('agh-set-github-proxy', d.github_proxy);
			var cacheEnabled = $('agh-set-cache-enabled');
			if (cacheEnabled) cacheEnabled.checked = !!d.cache_enabled;
			var cacheSize = $('agh-set-cache-size');
			if (cacheSize) {
				var sizeValue = String(d.cache_size_mb || 16);
				var hasSize = Array.prototype.slice.call(cacheSize.options).some(function (opt) {
					return opt.value === sizeValue;
				});
				if (!hasSize) {
					var extra = document.createElement('option');
					extra.value = sizeValue;
					extra.textContent = sizeValue + ' MB（当前）';
					cacheSize.appendChild(extra);
				}
				setSelectValue('agh-set-cache-size', sizeValue);
			}
			var cacheTtlMin = $('agh-set-cache-ttl-min');
			if (cacheTtlMin) cacheTtlMin.value = (d.cache_ttl_min != null ? d.cache_ttl_min : 0);
			var cacheTtlMax = $('agh-set-cache-ttl-max');
			if (cacheTtlMax) cacheTtlMax.value = (d.cache_ttl_max != null ? d.cache_ttl_max : 0);
			var cacheOptimistic = $('agh-set-cache-optimistic');
			if (cacheOptimistic) cacheOptimistic.checked = !!d.cache_optimistic;
			applyCacheLocks();
			var upSource = $('agh-set-upstream-source');
			if (upSource) setSelectValue('agh-set-upstream-source', d.upstream_source || 'auto');
			var upCustom = $('agh-set-upstream-custom');
			if (upCustom) upCustom.value = (d.upstream_custom || '').split(' ').filter(Boolean).join('\n');
			var upCurrent = $('agh-upstream-current');
			if (upCurrent) upCurrent.textContent = d.upstream_current || '—';
			applyUpstreamLocks();
			setSelectDays('agh-set-stats-days', d.stats_retention_days, 30);
			setSelectDays('agh-set-querylog-days', d.querylog_retention_days, 30);
			var cryptoSelect = $('agh-set-dns-crypto');
			if (cryptoSelect) setSelectValue('agh-set-dns-crypto', d.dns_crypto || 'off');
			var cryptoCustom = $('agh-set-dns-crypto-custom');
			if (cryptoCustom) cryptoCustom.value = d.dns_crypto_custom || '';
			state.cryptoBlocked = !!d.crypto_blocked;
			applyCryptoLocks();
			renderBypassIfaces(d.devices, d.bypass_ifaces);
			var bypassClients = $('agh-set-bypass-clients');
			if (bypassClients) bypassClients.value = d.bypass_clients || '';
			state.openclash = !!d.openclash_installed;
			state.passwall = !!d.passwall_installed;
			state.passwallEnabled = !!d.passwall_enabled;
			state.passwallDnsPort = d.passwall_dns_port || '';
			applyModeLocks(d.dns_mode);
			var path = $('agh-yaml-path');
			if (path && d.config_path) path.textContent = d.config_path;
			setMsg(msgEl, '', '');
			var cacheMsg = $('agh-cache-msg');
			if (cacheMsg) setMsg(cacheMsg, '', '');
			var cryptoMsg = $('agh-crypto-msg');
			if (cryptoMsg) setMsg(cryptoMsg, '', '');
			updateSwitchStates();
		} catch (err) {
			handleApiError(err, msgEl);
		}
	}

	async function saveSettings(event) {
		event.preventDefault();
		var fromCacheForm = event.target && event.target.id === 'agh-cache-form';
		var fromCryptoForm = event.target && event.target.id === 'agh-crypto-form';
		var fromUpstreamForm = event.target && event.target.id === 'agh-upstream-form';
		var msgEl = fromCacheForm ? $('agh-cache-msg')
			: (fromCryptoForm ? $('agh-crypto-msg')
				: (fromUpstreamForm ? $('agh-upstream-msg') : $('agh-settings-msg')));
		var btn = fromCacheForm ? $('agh-save-cache-btn')
			: (fromCryptoForm ? $('agh-save-crypto-btn')
				: (fromUpstreamForm ? $('agh-save-upstream-btn') : $('agh-save-settings-btn')));
		var port = $('agh-set-webport');
		var portValue = port ? port.value.trim() : '';
		var n = Number(portValue);

		if (!portValue || !Number.isInteger(n) || n < 1 || n > 65535) {
			setMsg(msgEl, '管理面板端口必须是 1-65535 之间的整数。', 'bad');
			return;
		}
		if (n === 53 || n === 1745 || n === 5333 || n === 5335) {
			setMsg(msgEl, '管理面板端口不能使用 53、1745、5333 或 5335。', 'bad');
			return;
		}

		var cacheEnabled = !$('agh-set-cache-enabled') || $('agh-set-cache-enabled').checked;
		var cacheSizeRaw = $('agh-set-cache-size') ? $('agh-set-cache-size').value : '16';
		var cacheSize = Number(cacheSizeRaw);
		if (!cacheSizeRaw || !Number.isInteger(cacheSize) || cacheSize < 1 || cacheSize > 256) {
			setMsg(msgEl, '缓存大小必须是 1-256MB 之间的整数。', 'bad');
			return;
		}
		var ttlMinRaw = $('agh-set-cache-ttl-min') ? $('agh-set-cache-ttl-min').value.trim() : '60';
		var ttlMaxRaw = $('agh-set-cache-ttl-max') ? $('agh-set-cache-ttl-max').value.trim() : '0';
		var ttlMin = Number(ttlMinRaw);
		var ttlMax = Number(ttlMaxRaw);
		if (ttlMinRaw === '' || !Number.isInteger(ttlMin) || ttlMin < 0 || ttlMin > 604800) {
			setMsg(msgEl, '最小 TTL 必须是 0-604800 秒之间的整数。', 'bad');
			return;
		}
		if (ttlMaxRaw === '' || !Number.isInteger(ttlMax) || ttlMax < 0 || ttlMax > 604800) {
			setMsg(msgEl, '最大 TTL 必须是 0-604800 秒之间的整数。', 'bad');
			return;
		}
		if (ttlMax > 0 && ttlMin > ttlMax) {
			setMsg(msgEl, '最小 TTL 不能大于最大 TTL；最大 TTL 为 0 表示不限制。', 'bad');
			return;
		}

		var dnsCrypto = $('agh-set-dns-crypto') ? $('agh-set-dns-crypto').value : 'off';
		var dnsCryptoCustom = $('agh-set-dns-crypto-custom') ? $('agh-set-dns-crypto-custom').value.trim() : '';
		if (['off', 'alidns', 'dnspod', 'cloudflare', 'custom'].indexOf(dnsCrypto) < 0) {
			setMsg(msgEl, '加密上游参数不正确。', 'bad');
			return;
		}
		if (dnsCrypto === 'custom') {
			if (!dnsCryptoCustom) {
				setMsg(msgEl, '请填写自定义加密上游地址。', 'bad');
				return;
			}
			if (!/^(https:\/\/|tls:\/\/|quic:\/\/|sdns:\/\/)\S+$/.test(dnsCryptoCustom)) {
				setMsg(msgEl, '自定义加密上游需以 https://、tls://、quic:// 或 sdns:// 开头，且不能包含空格。', 'bad');
				return;
			}
		}

		var upSource = $('agh-set-upstream-source') ? $('agh-set-upstream-source').value : 'auto';
		var upRaw = $('agh-set-upstream-custom') ? $('agh-set-upstream-custom').value : '';
		var upItems = upRaw.replace(/\s+/g, ' ').trim().split(' ').filter(Boolean);
		if (upSource === 'custom') {
			if (!upItems.length) {
				setMsg(msgEl, '请填写自定义上游 DNS，或把来源改回「自动」。', 'bad');
				return;
			}
			for (var ui = 0; ui < upItems.length; ui++) {
				var addr = upItems[ui].replace(/^\[[^\]]*\]/, '');
				var valid = /^(https:\/\/|tls:\/\/|quic:\/\/|sdns:\/\/)\S+$/.test(addr) || /^[A-Za-z0-9._:-]+$/.test(addr);
				if (!valid) {
					setMsg(msgEl, '上游 DNS 格式不正确：' + upItems[ui], 'bad');
					return;
				}
			}
		}

		var data = {
			enabled: $('agh-set-enabled').checked ? '1' : '0',
			dns_mode: $('agh-set-dns-mode').value,
			webport: String(n),
			webaddr: $('agh-set-webaddr') ? $('agh-set-webaddr').value : '0.0.0.0',
			binpath: $('agh-set-binpath').value,
			workdir: $('agh-set-workdir').value,
			channel: $('agh-set-channel').value,
			github_proxy: $('agh-set-github-proxy').value,
			cache_enabled: cacheEnabled ? '1' : '0',
			cache_size_mb: String(cacheSize),
			cache_ttl_min: String(ttlMin),
			cache_ttl_max: String(ttlMax),
			cache_optimistic: (cacheEnabled && $('agh-set-cache-optimistic') && $('agh-set-cache-optimistic').checked) ? '1' : '0',
			dns_crypto: dnsCrypto,
			dns_crypto_custom: dnsCryptoCustom,
			upstream_source: upSource,
			upstream_custom: upItems.join(' '),
			bypass_ifaces: pickedBypassIfaces(),
			bypass_clients: $('agh-set-bypass-clients') ? $('agh-set-bypass-clients').value.trim() : ''
		};

		if (btn) btn.disabled = true;
		setMsg(msgEl, '正在保存并应用设置...', '');
		try {
			await apiPost(U.settingsSave, data);
			setMsg(msgEl, '设置已保存，正在应用...', 'ok');
			showToast('设置已保存，正在重启服务...', 'ok');
			pollAction(function () {
				if (btn) btn.disabled = false;
				loadSettings();
				refreshStatus(true);
			});
		} catch (err) {
			if (btn) btn.disabled = false;
			applyCryptoLocks();
			handleApiError(err, msgEl);
		}
	}

	async function loadYaml() {
		var msgEl = $('agh-yaml-msg');
		var editor = $('agh-yaml-editor');
		if (!editor) return;
		try {
			var d = await apiGet(U.yamlGet);
			editor.value = d.yaml || '';
			updateYamlCount();
			var path = $('agh-yaml-path');
			if (path && d.path) path.textContent = d.path;
			state.yamlLoaded = true;
			state.yamlHash = d.hash || '';
			setMsg(msgEl, d.yaml ? '' : '配置文件尚未生成，请先启用服务。', d.yaml ? '' : 'bad');
		} catch (err) {
			handleApiError(err, msgEl);
		}
	}

