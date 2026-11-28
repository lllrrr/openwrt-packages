	function renderStatus() {
		var d = state.status;
		updateHeaderStatus();
		updatePluginVersion(d);
		if (!d) {
			var grid = $('agh-status-grid');
			if (grid) grid.innerHTML = '<div class="agh-empty">无法读取状态</div>';
			return;
		}

		var panel = panelUrl(d.web_port);
		var passHtml;
		if (d.admin_pass_default) {
			passHtml = '<span class="agh-warn">仍是默认密码，请在下方「基础设置」-「修改密码」中重设</span>';
		} else if (d.admin_pass_set) {
			passHtml = '<span class="agh-ok">已设置（忘记可在下方重设）</span>';
		} else {
			passHtml = '<span class="agh-warn">未设置</span>';
		}

		var rows = [
			['服务状态', d.running ? '<span class="agh-ok">运行中</span>' : '<span class="agh-bad">已停止</span>'],
			['内核版本', renderCoreVersion(d)],
			['DNS 接管', esc(modeLabel(d.dns_mode, d.passwall_flavor)) + ((d.mode_applied && d.mode_applied !== d.dns_mode) ? ' <span class="agh-warn">（待应用）</span>' : '')],
			['当前链路', '<span class="agh-path">' + esc(modeChain(d)) + '</span>'],
			['更新通道', esc(channelLabel(d.channel))]
		];

		rows.push(
			['面板地址', '<a href="' + esc(panel) + '" target="_blank" rel="noopener">' + esc(panel.replace(/^http:\/\//, '')) + '</a>'],
			['管理员', esc(d.admin_user || 'admin')],
			['面板密码', passHtml],
			['配置文件', d.config_exists ? '<span class="agh-ok">已生成</span>' : '<span class="agh-warn">未生成</span>'],
			['工作目录', '<span class="agh-path">' + esc(d.workdir || '') + '</span>']
		);

		if (d.dns_mode === 'takeover' && d.openclash_hijack && !d.dns_redirect) {
			rows.push(['配置建议', '<span class="agh-warn">检测到 Clash DNS 劫持，但把查询收回 53 的规则没有生效，查询可能绕过 AdGuard Home。请在「基础设置」重新保存一次「接管 53 端口」，或检查防火墙状态。</span>']);
		}
		// DNSMasq 内置劫持被固件或其它插件重新打开时，过滤会静默失效
		if ((d.dns_mode === 'takeover' || d.dns_mode === 'passwall') && String(d.dnsmasq_redirect || '') === '1') {
			rows.push(['配置建议', '<span class="agh-warn">DNSMasq 内置的 DNS 劫持（dns_redirect=1）被重新开启了，它会抢在插件规则之前把查询送到 1745，导致过滤失效。请在「基础设置」重新保存一次当前接管方式。</span>']);
		}
		if (d.dns_mode === 'passwall') {
			if (!d.passwall_enabled) {
				rows.push(['配置建议', '<span class="agh-warn">未检测到启用中的 PassWall / PassWall2，查询会经 AdGuard Home 转给本机 DNSMasq（1745），不走 PassWall 分流。</span>']);
			} else if (!d.dns_redirect) {
				rows.push(['配置建议', '<span class="agh-warn">把查询收回 53 的规则没有生效，查询可能被 PassWall 的劫持抢走。请在「基础设置」重新保存一次「PassWall 前置」。</span>']);
			} else {
				// PassWall 自带的 dnsmasq 只接受局域网来源，上游可能是 127.0.0.1 或局域网 IP，
				// 这里只比较端口，避免误报。
				var pswPort = String(d.passwall_dns_port || '');
				var ups = String(d.upstream_current || '');
				var upsPort = (ups.match(/:(\d+)\s*$/) || [])[1] || '';
				if (pswPort && d.upstream_source !== 'custom' && upsPort !== pswPort) {
					rows.push(['配置建议', '<span class="agh-warn">AdGuard Home 上游未指向当前 PassWall DNS 端口（' + esc(pswPort) +
						'），插件会在端口稳定约 25 秒后自动跟随（短暂重启一次 AdGuard Home）。</span>']);
				}
			}
		}
		if (d.dns_mode === 'openclash' && d.openclash_hijack_port &&
			d.openclash_hijack_port !== '53' && d.openclash_hijack_port !== String(d.dns_port)) {
			rows.push(['配置建议', '<span class="agh-warn">Clash 把 53 直接劫持到 ' + esc(d.openclash_hijack_port) +
				'，查询不经过 DNSMasq，AdGuard Home 被绕过。请改用「Clash 前置」。</span>']);
		}
		if (d.dns_mode === 'openclash' && !d.openclash_running) {
			rows.push(['配置建议', '<span class="agh-warn">Clash 内核未运行，AdGuard Home 的上游 ' + esc(d.clash_dns_port || '7874') + ' 不可用，DNS 会解析失败。</span>']);
		}
		if (d.dns_mode === 'clashfirst') {
			if (!d.openclash_running) {
				rows.push(['配置建议', '<span class="agh-warn">Clash 内核未运行，前置链路无法生效。</span>']);
			} else if (!d.openclash_redirect || d.openclash_redirect === '0') {
				rows.push(['配置建议', '<span class="agh-warn">Clash 的 DNS 劫持未开启，客户端查询会绕过 AdGuard Home。</span>']);
			} else if (!d.openclash_upstream_agh) {
				rows.push(['配置建议', '<span class="agh-warn">未检测到指向 127.0.0.1:' + String(d.dns_port) + ' 的 Clash 上游，可保存一次设置或重启 Clash 使其生效。</span>']);
			}
		}
		if (d.parental_auto_disabled) {
			rows.push(['配置建议', '<span class="agh-warn">连不上 AdGuard 家长控制服务（family.adguard-dns.com），家长控制已自动关闭，避免全屋断网；代理可用后再开启。</span>']);
			if (!state.parentalNotified) {
				state.parentalNotified = true;
				showToast('家长控制已自动关闭：连不上 AdGuard 服务端，继续开启会导致断网', 'bad');
			}
		} else {
			state.parentalNotified = false;
			if (d.parental_enabled && d.parental_service_ok === false) {
				rows.push(['配置建议', '<span class="agh-warn">家长控制已开启，但连不上 AdGuard 家长控制服务，正在尝试自动关闭；若网络异常请手动关闭家长控制。</span>']);
			}
		}

		var wide = { '当前链路': 1, '面板地址': 1 };
		var html = '';
		for (var i = 0; i < rows.length; i++) {
			var label = rows[i][0];
			var cls = 'agh-status-item';
			if (wide[label]) cls += ' agh-status-wide';
			if (label === '配置建议') cls += ' agh-status-full';
			if (label === 'DNS 接管') cls += ' agh-status-nowrap';
			html += '<div class="' + cls + '"><span class="agh-k">' + esc(label) + '</span><span class="agh-v">' + rows[i][1] + '</span></div>';
		}
		var grid = $('agh-status-grid');
		if (grid) grid.innerHTML = html;

		attachCoreUpdateAction();
		updateSteps(d);

		if (d.update_running && !state.updateTimer) {
			showProgress();
			startProgressPoll();
		}
	}

	function updateSteps(d) {
		if (!d) return;
		var busy = state.busy || d.action_running || d.update_running || state.pluginUpdating;

		var installBtn = $('agh-install-btn');
		var enableBtn = $('agh-enable-btn');
		var panelLink = $('agh-panel-link');
		var noLegacyTarget = d.channel === 'legacy' && !(d.core_update && d.core_update.latest);
		var legacyRisk = d.channel === 'legacy' && d.legacy_config_risk;

		if (installBtn) {
			installBtn.disabled = busy || noLegacyTarget;
			installBtn.textContent = d.core ? '重新安装/更新内核' : '安装内核';
		}
		var coreHint = $('agh-core-hint');
		if (coreHint) {
			var cu = d.core_update;
			var hintText = '';
			var hintWarn = false;
			if (d.core) {
				if (cu && cu.update && cu.latest) {
					hintText = '已安装 ' + (d.version || '未知') + '，发现新版本 v' + cu.latest +
						(cu.beta ? '（预发布版）' : '（正式版）') + '，点击「安装/更新内核」升级';
					hintWarn = true;
				} else {
					var installedChannel = d.core_channel || (isCoreBeta(d) ? 'beta' : 'stable');
					if (d.channel && d.channel !== installedChannel) {
						// 通道已切换但目标版本不高于当前版本时不会有更新提示，这里明确给出切换入口
						hintText = '已安装 ' + (d.version || '未知') + '（' + channelLabel(installedChannel) +
							'），当前为' + channelLabel(d.channel) + '通道' +
							(cu && cu.latest ? '（目标 v' + cu.latest + '）' : '') +
							'，点击「重新安装/更新内核」切换';
						hintWarn = true;
					} else {
						hintText = '已安装，当前版本：' + (d.version || '未知');
						if (isCoreBeta(d)) hintText += '（预发布版，升级大版本前会自动备份配置）';
					}
				}
			} else {
				hintText = d.update_running ? '正在安装...' : '尚未安装内核';
			}
			if (noLegacyTarget && !d.update_running) {
				hintText = '旧版本通道暂无可用目标版本（版本检查未完成或只有一条正式版本线），请稍后刷新';
				hintWarn = true;
			}
			if (legacyRisk && d.config_schema) {
				hintText += '；当前配置为 schema ' + d.config_schema + '，且没有更旧的备份，旧版本内核会拒绝安装';
				hintWarn = true;
			}
			coreHint.className = hintWarn ? 'agh-hint agh-warn' : 'agh-hint';
			coreHint.textContent = hintText;
		}

		if (enableBtn) {
			enableBtn.disabled = !d.core || busy;
			enableBtn.textContent = d.running ? '重新应用设置' : '一键启用';
		}
		var enableHint = $('agh-enable-hint');
		if (enableHint) {
			if (!d.core) enableHint.textContent = '请先完成第 1 步。';
			else if (d.running) enableHint.textContent = '服务正在运行。';
			else if (d.enabled) enableHint.textContent = '已启用但当前未运行，请点击启动或查看日志。';
			else enableHint.textContent = '内核已就绪，可以启用。';
		}

		if (panelLink) {
			if (d.running) {
				panelLink.href = panelUrl(d.web_port);
				panelLink.className = 'agh-btn agh-btn-secondary';
				panelLink.textContent = '打开 AGH 面板';
				panelLink.removeAttribute('aria-disabled');
			} else {
				panelLink.href = '#';
				panelLink.className = 'agh-btn agh-btn-secondary is-disabled';
				panelLink.textContent = '服务未运行';
				panelLink.setAttribute('aria-disabled', 'true');
			}
		}
		var consoleHint = $('agh-console-hint');
		if (consoleHint) {
			consoleHint.textContent = d.running
				? '面板地址：' + panelUrl(d.web_port)
				: '启用服务后即可打开面板。';
		}

		var headerConsole = $('agh-header-console');
		if (headerConsole) {
			if (d.running) {
				headerConsole.href = panelUrl(d.web_port);
				headerConsole.className = 'agh-badge agh-badge-link';
				headerConsole.removeAttribute('aria-disabled');
			} else {
				headerConsole.href = '#';
				headerConsole.className = 'agh-badge agh-badge-link is-disabled';
				headerConsole.setAttribute('aria-disabled', 'true');
			}
		}

		var startBtn = $('agh-start-btn');
		var stopBtn = $('agh-stop-btn');
		var restartBtn = $('agh-restart-btn');
		if (startBtn) startBtn.disabled = busy || d.running;
		if (stopBtn) stopBtn.disabled = busy || (!d.running && !d.enabled);
		if (restartBtn) restartBtn.disabled = busy || !d.core;
	}

