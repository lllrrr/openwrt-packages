	function panelUrl(port) {
		var host = window.location.hostname;
		if (host.indexOf(':') >= 0 && host.charAt(0) !== '[') host = '[' + host + ']';
		return 'http://' + host + ':' + (port || 13800) + '/';
	}

	function modeLabel(mode, flavor) {
		if (mode === 'takeover') return '接管 53 端口';
		if (mode === 'passwall') return (flavor === '2' ? 'PassWall2' : 'PassWall') + ' 前置';
		if (mode === 'openclash') return 'Clash 串联（已下线）';
		if (mode === 'clashfirst') return 'Clash 前置（Clash → AGH → 真实 DNS）';
		if (mode === 'none') return '仅面板（不接管 DNS）';
		return 'DNSMasq 上游';
	}

	function modeChain(d) {
		var cdp = d.clash_dns_port || '7874';
		if (d.dns_mode === 'takeover') {
			return d.openclash_running
				? '客户端 → 53 AGH → 1745 DNSMasq → Clash / WAN DNS'
				: '客户端 → 53 AGH → 1745 DNSMasq → WAN DNS';
		}
		if (d.dns_mode === 'passwall') {
			return '客户端 → 53 AGH → ' + (d.passwall_dns_port || '11400') + ' PassWall DNS → 分流';
		}
		if (d.dns_mode === 'openclash') return '客户端 → 53 DNSMasq → 5333 AGH → ' + cdp + ' Clash DNS';
		if (d.dns_mode === 'clashfirst') return '客户端 → Clash 劫持 → ' + cdp + ' Clash DNS → 5335 AGH → 真实 DNS';
		if (d.dns_mode === 'none') return '不接管 DNS，仅保留管理面板';
		return '客户端 → 53 DNSMasq → 5333 AGH → 自动选择上游';
	}

	function channelLabel(channel) {
		if (channel === 'beta') return '预发布版';
		if (channel === 'legacy') return '旧版本';
		return '正式版';
	}

	// AdGuard Home 预发布版本号形如 v1.0.0-b.2
	function isBetaVersion(version) {
		return /(^|-)b\.?\d/i.test(String(version || ''));
	}

	// 安装通道优先用安装时记录的值；旧安装没有记录时按版本号兜底
	function isCoreBeta(d) {
		var ch = d && d.core_channel;
		if (ch === 'beta') return true;
		if (ch === 'stable' || ch === 'legacy') return false;
		return isBetaVersion(d && d.version);
	}

	function coreUpdateBadge(d) {
		var u = d && d.core_update;
		if (!u || !u.update || !u.latest) return '';
		return ' <a href="#" class="agh-update-tip agh-core-update" title="点击前往安装">可更新 v' +
			esc(u.latest) + (u.beta ? '（预发布版）' : '') + '</a>';
	}

	function renderCoreVersion(d) {
		if (!d.core) return '<span class="agh-bad">未安装</span>';
		var version = d.version || '已安装';
		var html = '<span class="agh-ok">' + esc(version) + '</span>';
		if (isCoreBeta(d)) {
			html += ' <span class="agh-beta-tag">预发布版</span>';
		}
		html += coreUpdateBadge(d);
		return html;
	}

	function updatePluginVersion(d) {
		var ver = $('agh-plugin-version');
		var tip = $('agh-plugin-update');
		var p = d && d.plugin;
		if (ver && !state.pluginChecking) ver.textContent = (p && p.current) ? 'v' + p.current : '未知';
		if (!tip) return;

		if (state.pluginUpdating) {
			tip.textContent = '更新中...';
			tip.hidden = false;
			tip.disabled = true;
			return;
		}
		tip.disabled = false;
		if (p && p.url) state.pluginUrl = p.url;
		if (p && p.update && p.latest) {
			state.pluginLatest = p.latest;
			tip.textContent = '发现 v' + p.latest + '，立即更新';
			tip.hidden = false;
		} else {
			tip.hidden = true;
		}
	}

	// 点击版本号手动检测更新：清缓存后触发后台检查，轮询状态等结果
	async function checkPluginUpdate() {
		if (state.pluginChecking || state.pluginUpdating) return;
		state.pluginChecking = true;

		var ver = $('agh-plugin-version');
		var original = ver ? ver.textContent : '';
		if (ver) {
			ver.classList.add('is-checking');
			ver.textContent = '检测中…';
		}

		try {
			await apiPost(U.pluginCheck, {});
			var found = null;
			// 后台最多串行尝试 3 个节点（每节点 6 秒），这里等 36 秒再判定超时
			for (var i = 0; i < 24; i++) {
				await new Promise(function (resolve) { setTimeout(resolve, 1500); });
				var d = await apiGet(U.status);
				if (d && d.plugin && d.plugin.latest) {
					found = d.plugin;
					break;
				}
			}

			state.pluginChecking = false;
			if (ver) {
				ver.classList.remove('is-checking');
				if (!found) ver.textContent = original;
			}

			if (!found) {
				showToast('检测超时，请检查网络或 GitHub 反代设置', 'bad');
				return;
			}

			refreshStatus(true);
			showToast(found.update ? ('发现新版本 v' + found.latest) : '已是最新版本', 'ok');
		} catch (err) {
			state.pluginChecking = false;
			if (ver) {
				ver.classList.remove('is-checking');
				ver.textContent = original;
			}
			handleApiError(err);
		}
	}

	function updateHeaderStatus() {
		var el = $('agh-header-status');
		if (!el) return;
		var d = state.status;
		if (!d) {
			el.className = 'agh-pill';
			el.textContent = '读取中';
			return;
		}
		if (d.update_running) {
			el.className = 'agh-pill agh-pill-warn';
			el.textContent = '内核安装中';
			return;
		}
		if (d.running) {
			el.className = 'agh-pill agh-pill-ok';
			el.textContent = '运行中';
			return;
		}
		if (d.enabled) {
			el.className = 'agh-pill agh-pill-warn';
			el.textContent = '已启用 / 未运行';
			return;
		}
		el.className = 'agh-pill agh-pill-bad';
		el.textContent = '已停止';
	}

	function attachCoreUpdateAction() {
		var links = document.querySelectorAll('.agh-core-update');
		for (var i = 0; i < links.length; i++) {
			links[i].onclick = function (e) {
				e.preventDefault();
				var btn = $('agh-install-btn');
				if (btn) btn.scrollIntoView({ behavior: 'smooth', block: 'center' });
			};
		}
	}

