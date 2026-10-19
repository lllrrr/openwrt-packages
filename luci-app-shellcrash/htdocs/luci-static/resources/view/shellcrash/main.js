'use strict';
'require view';
'require dom';
'require fs';
'require uci';
'require ui';
'require poll';
'require shellcrash.panel as panelHelper';

return view.extend({
	load: function() {
		return Promise.all([
			fs.exec('/usr/libexec/luci-app-shellcrash/ctl.sh', ['status']),
			uci.load('shellcrash')
		]);
	},

	render: function(data) {
		var statusRaw = data[0] || {};
		var status = {};
		try {
			status = JSON.parse(statusRaw.stdout || '{}');
		} catch (e) {
			status = {};
		}

		var uciData = uci.get_first('shellcrash', 'main') || {};
		var m, s, o;

		var viewRoot = E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('ShellCrash 运行控制')),
			E('div', { 'class': 'cbi-map-descr' }, _('基于 ShellCrash 的透明代理核心管理与状态看板'))
		]);

		// Card 1: Installation check
		if (!status.installed) {
			var installCard = E('div', { 'class': 'alert-message warning' }, [
				E('h4', {}, _('未检测到 ShellCrash 环境')),
				E('p', {}, _('系统目录（/etc/ShellCrash 等）中未发现 ShellCrash 安装文件。插件已内置离线安装包，点击下方按钮即可一键初始化部署。')),
				E('div', { 'style': 'margin-top: 10px;' }, [
					E('button', {
						'class': 'btn cbi-button cbi-button-action',
						'click': function(ev) {
							ui.showModal(_('正在初始化 ShellCrash'), [
								E('p', { 'class': 'spinning' }, _('正在解压内置安装包并初始化环境，请稍候...'))
							]);
							return fs.exec('/usr/libexec/luci-app-shellcrash/ctl.sh', ['install']).then(function(res) {
								ui.hideModal();
								window.location.reload();
							}).catch(function(err) {
								ui.hideModal();
								ui.addNotification(null, E('p', {}, _('初始化失败: ') + err.message));
							});
						}
					}, _('一键初始化 ShellCrash 环境'))
				])
			]);
			viewRoot.appendChild(installCard);
			return viewRoot;
		}

		// Card 2: Status Grid
		var isRunning = status.running === true;
		var statusText = isRunning ? _('运行中') : _('已停止');
		var statusColor = isRunning ? '#28a745' : '#dc3545';

		var statusTable = E('table', { 'class': 'table', 'style': 'margin-bottom: 20px;' }, [
			E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td', 'style': 'width: 25%; font-weight: bold;' }, _('服务状态')),
				E('td', { 'class': 'td' }, [
					E('span', {
						'id': 'sc-status-badge',
						'style': 'display: inline-block; padding: 2px 8px; border-radius: 4px; color: #fff; font-weight: bold; background-color: ' + statusColor
					}, statusText),
					isRunning ? E('span', { 'style': 'margin-left: 10px; color: #666;' }, '(PID: ' + status.pid + ' | 内存: ' + status.mem_mb + ' | 运行时间: ' + status.uptime + ')') : ''
				])
			]),
			E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td', 'style': 'font-weight: bold;' }, _('内核类型与版本')),
				E('td', { 'class': 'td' }, (status.core_type || '-') + ' (' + (status.core_version || '-') + ')')
			]),
			E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td', 'style': 'font-weight: bold;' }, _('运行模式')),
				E('td', { 'class': 'td' }, status.run_mode || 'Redir')
			]),
			E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td', 'style': 'font-weight: bold;' }, _('监听端口')),
				E('td', { 'class': 'td' }, [
					_('混合端口: '), E('strong', {}, String(status.mix_port || '-')),
					' | ', _('透明代理: '), E('strong', {}, String(status.tproxy_port || status.redir_port || '-')),
					' | ', _('DNS: '), E('strong', {}, String(status.dns_port || '-')),
					' | ', _('API: '), E('strong', {}, String(status.api_port || '-'))
				])
			]),
			E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td', 'style': 'font-weight: bold;' }, _('开机自启')),
				E('td', { 'class': 'td' }, status.autostart ? _('已启用') : _('已禁用'))
			])
		]);

		var statusSection = E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('服务运行状态')),
			statusTable
		]);
		viewRoot.appendChild(statusSection);

		// Card 3: Action Buttons
		var actionSection = E('div', { 'class': 'cbi-section', 'style': 'margin-bottom: 25px;' }, [
			E('h3', {}, _('操作控制')),
			E('div', { 'style': 'display: flex; gap: 10px; flex-wrap: wrap;' }, [
				E('button', {
					'class': 'btn cbi-button cbi-button-action',
					'disabled': isRunning,
					'click': function() {
						ui.showModal(_('正在启动'), [E('p', { 'class': 'spinning' }, _('正在启动 ShellCrash 服务...'))]);
						return fs.exec('/usr/libexec/luci-app-shellcrash/ctl.sh', ['start']).then(function() {
							setTimeout(function() { window.location.reload(); }, 1500);
						});
					}
				}, _('启动服务')),
				E('button', {
					'class': 'btn cbi-button cbi-button-negative',
					'disabled': !isRunning,
					'click': function() {
						ui.showModal(_('正在停止'), [E('p', { 'class': 'spinning' }, _('正在停止 ShellCrash 服务...'))]);
						return fs.exec('/usr/libexec/luci-app-shellcrash/ctl.sh', ['stop']).then(function() {
							setTimeout(function() { window.location.reload(); }, 1500);
						});
					}
				}, _('停止服务')),
				E('button', {
					'class': 'btn cbi-button cbi-button-neutral',
					'click': function() {
						ui.showModal(_('正在重启'), [E('p', { 'class': 'spinning' }, _('正在重启 ShellCrash 服务...'))]);
						return fs.exec('/usr/libexec/luci-app-shellcrash/ctl.sh', ['restart']).then(function() {
							setTimeout(function() { window.location.reload(); }, 1500);
						});
					}
				}, _('重启服务')),
				E('button', {
					'class': 'btn cbi-button cbi-button-neutral',
					'disabled': !isRunning,
					'click': function() {
						ui.showModal(_('热重载配置'), [E('p', { 'class': 'spinning' }, _('正在重载内核运行配置...'))]);
						return fs.exec('/usr/libexec/luci-app-shellcrash/ctl.sh', ['reload']).then(function(res) {
							ui.hideModal();
							ui.addNotification(null, E('p', {}, _('配置重载请求已发出')));
						});
					}
				}, _('热重载配置')),
				E('button', {
					'class': 'btn cbi-button ' + (status.autostart ? 'cbi-button-neutral' : 'cbi-button-save'),
					'click': function() {
						var action = status.autostart ? 'disable' : 'enable';
						return fs.exec('/usr/libexec/luci-app-shellcrash/ctl.sh', [action]).then(function() {
							window.location.reload();
						});
					}
				}, status.autostart ? _('禁用开机自启') : _('启用开机自启')),
				E('button', {
					'class': 'btn cbi-button cbi-button-positive',
					'click': function() {
						var targetUrl = panelHelper.resolveUrl(uciData, status);
						window.open(targetUrl, '_blank');
					}
				}, _('打开 Web 控制面板 ↗'))
			])
		]);
		viewRoot.appendChild(actionSection);

		// Card 4: Connectivity & Latency Ping
		var pingContainer = E('div', { 'id': 'sc-ping-container', 'style': 'display: flex; gap: 15px; flex-wrap: wrap; margin-top: 10px;' });
		var pingSection = E('div', { 'class': 'cbi-section' }, [
			E('div', { 'style': 'display: flex; justify-content: space-between; align-items: center;' }, [
				E('h3', {}, _('网络连通性与分流延迟')),
				E('button', {
					'class': 'btn cbi-button cbi-button-action',
					'id': 'sc-btn-reping',
					'click': function() {
						var btn = this;
						btn.disabled = true;
						btn.textContent = _('测速中...');
						return fs.exec('/usr/libexec/luci-app-shellcrash/ctl.sh', ['ping']).then(function(res) {
							btn.disabled = false;
							btn.textContent = _('重新测试');
							try {
								var pingData = JSON.parse(res.stdout || '{}');
								renderPingCards(pingData.results || []);
							} catch (e) {}
						}).catch(function() {
							btn.disabled = false;
							btn.textContent = _('重新测试');
						});
					}
				}, _('重新测试'))
			]),
			E('p', { 'style': 'color: #777; font-size: 13px; margin-top: -5px;' }, _('国内外站点经透明代理与规则分流后的真实往返延迟：')),
			pingContainer
		]);
		viewRoot.appendChild(pingSection);

		function renderPingCards(results) {
			dom.content(pingContainer, []);
			if (!results || results.length === 0) {
				pingContainer.appendChild(E('span', { 'style': 'color: #999;' }, _('点击“重新测试”开始检测网络延迟')));
				return;
			}
			for (var i = 0; i < results.length; i++) {
				var r = results[i];
				var delayText = (r.delay > 0) ? r.delay + ' ms' : _('超时');
				var delayColor = '#dc3545';
				if (r.delay > 0 && r.delay < 150) delayColor = '#28a745';
				else if (r.delay >= 150 && r.delay < 500) delayColor = '#ffc107';

				var card = E('div', {
					'style': 'flex: 1; min-width: 140px; padding: 12px; border: 1px solid #ddd; border-radius: 6px; background: #fafafa; text-align: center;'
				}, [
					E('div', { 'style': 'font-weight: bold; font-size: 14px; margin-bottom: 6px;' }, r.name),
					E('div', { 'style': 'font-size: 18px; font-weight: bold; color: ' + delayColor }, delayText)
				]);
				pingContainer.appendChild(card);
			}
		}

		// Initial ping
		fs.exec('/usr/libexec/luci-app-shellcrash/ctl.sh', ['ping']).then(function(res) {
			try {
				var pingData = JSON.parse(res.stdout || '{}');
				renderPingCards(pingData.results || []);
			} catch (e) {}
		});

		return viewRoot;
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
