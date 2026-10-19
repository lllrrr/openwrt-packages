'use strict';
'require view';
'require fs';
'require ui';

return view.extend({
	load: function() {
		return Promise.all([
			fs.exec('/usr/libexec/luci-app-shellcrash/ctl.sh', ['kernel-get']),
			fs.exec('/usr/libexec/luci-app-shellcrash/ctl.sh', ['cfg-read'])
		]);
	},

	render: function(data) {
		var kernelRaw = data[0] || {};
		var cfgRaw = data[1] || {};

		var kernel = {};
		try {
			kernel = JSON.parse(kernelRaw.stdout || '{}');
		} catch (e) {
			kernel = {};
		}

		var cfgContent = cfgRaw.stdout || '';

		var viewRoot = E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('内核参数与 ShellCrash 配置')),
			E('div', { 'class': 'cbi-map-descr' }, _('通过 RESTful API 即时调整内核分流状态，以及在线维护 ShellCrash.cfg 配置文件'))
		]);

		// Section 1: Realtime Kernel API Settings
		var curMode = (kernel.mode || 'Rule').toLowerCase();
		var curLogLevel = (kernel['log-level'] || 'info').toLowerCase();
		var allowLan = kernel['allow-lan'] === true;
		var ipv6 = kernel['ipv6'] === true;
		var tcpConcurrent = kernel['tcp-concurrent'] === true;

		var secApi = E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('内核运行时即时调整 (Clash API)')),
			E('table', { 'class': 'table' }, [
				E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td', 'style': 'width: 25%; font-weight: bold;' }, _('分流模式 (Mode)')),
					E('td', { 'class': 'td' }, [
						E('button', {
							'class': 'btn cbi-button ' + (curMode === 'rule' ? 'cbi-button-action' : 'cbi-button-neutral'),
							'style': 'margin-right: 8px;',
							'click': function() {
								return fs.exec('/usr/libexec/luci-app-shellcrash/ctl.sh', ['mode-rule']).then(function() {
									ui.addNotification(null, E('p', {}, _('分流模式已切换为：规则分流 (Rule)')));
									setTimeout(function() { window.location.reload(); }, 800);
								});
							}
						}, _('规则分流 (Rule)')),
						E('button', {
							'class': 'btn cbi-button ' + (curMode === 'global' ? 'cbi-button-action' : 'cbi-button-neutral'),
							'style': 'margin-right: 8px;',
							'click': function() {
								return fs.exec('/usr/libexec/luci-app-shellcrash/ctl.sh', ['mode-global']).then(function() {
									ui.addNotification(null, E('p', {}, _('分流模式已切换为：全局代理 (Global)')));
									setTimeout(function() { window.location.reload(); }, 800);
								});
							}
						}, _('全局代理 (Global)')),
						E('button', {
							'class': 'btn cbi-button ' + (curMode === 'direct' ? 'cbi-button-action' : 'cbi-button-neutral'),
							'click': function() {
								return fs.exec('/usr/libexec/luci-app-shellcrash/ctl.sh', ['mode-direct']).then(function() {
									ui.addNotification(null, E('p', {}, _('分流模式已切换为：直连模式 (Direct)')));
									setTimeout(function() { window.location.reload(); }, 800);
								});
							}
						}, _('全局直连 (Direct)'))
					])
				]),
				E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td', 'style': 'font-weight: bold;' }, _('日志级别 (Log Level)')),
					E('td', { 'class': 'td' }, [
						['silent', 'error', 'warning', 'info', 'debug'].map(function(lvl) {
							return E('button', {
								'class': 'btn cbi-button ' + (curLogLevel === lvl ? 'cbi-button-action' : 'cbi-button-neutral'),
								'style': 'margin-right: 6px;',
								'click': function() {
									return fs.exec('/usr/libexec/luci-app-shellcrash/ctl.sh', ['log-' + lvl]).then(function() {
										ui.addNotification(null, E('p', {}, _('日志级别已更改为：') + lvl));
										setTimeout(function() { window.location.reload(); }, 800);
									});
								}
							}, lvl.toUpperCase());
						})
					])
				]),
				E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td', 'style': 'font-weight: bold;' }, _('局域网连接 (Allow LAN)')),
					E('td', { 'class': 'td' }, [
						E('button', {
							'class': 'btn cbi-button ' + (allowLan ? 'cbi-button-positive' : 'cbi-button-neutral'),
							'click': function() {
								var act = allowLan ? 'allow-lan-off' : 'allow-lan-on';
								return fs.exec('/usr/libexec/luci-app-shellcrash/ctl.sh', [act]).then(function() {
									window.location.reload();
								});
							}
						}, allowLan ? _('已允许局域网连接') : _('已禁止局域网连接'))
					])
				]),
				E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td', 'style': 'font-weight: bold;' }, _('IPv6 分流支持 (IPv6)')),
					E('td', { 'class': 'td' }, [
						E('button', {
							'class': 'btn cbi-button ' + (ipv6 ? 'cbi-button-positive' : 'cbi-button-neutral'),
							'click': function() {
								var act = ipv6 ? 'ipv6-off' : 'ipv6-on';
								return fs.exec('/usr/libexec/luci-app-shellcrash/ctl.sh', [act]).then(function() {
									window.location.reload();
								});
							}
						}, ipv6 ? _('已启用 IPv6 代理') : _('未启用 IPv6 代理'))
					])
				]),
				E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td', 'style': 'font-weight: bold;' }, _('TCP 并发 (TCP Concurrent)')),
					E('td', { 'class': 'td' }, [
						E('button', {
							'class': 'btn cbi-button ' + (tcpConcurrent ? 'cbi-button-positive' : 'cbi-button-neutral'),
							'click': function() {
								var act = tcpConcurrent ? 'tcp-concurrent-off' : 'tcp-concurrent-on';
								return fs.exec('/usr/libexec/luci-app-shellcrash/ctl.sh', [act]).then(function() {
									window.location.reload();
								});
							}
						}, tcpConcurrent ? _('已开启 TCP 并发') : _('已关闭 TCP 并发'))
					])
				])
			])
		]);
		viewRoot.appendChild(secApi);

		// Section 2: ShellCrash.cfg Online Editor
		var editor = E('textarea', {
			'class': 'cbi-input-textarea',
			'style': 'width: 100%; height: 350px; font-family: monospace; font-size: 13px; line-height: 1.4; border-radius: 4px; padding: 8px;'
		}, [cfgContent]);

		var secEditor = E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('ShellCrash.cfg 在线配置编辑器')),
			E('div', { 'class': 'cbi-section-descr' }, _('可在此直接编辑 ShellCrash 的配置文件。点击保存前会自动备份至 ShellCrash.cfg.bak，以便随时还原。')),
			E('div', { 'style': 'margin-bottom: 12px;' }, [editor]),
			E('div', { 'style': 'display: flex; gap: 10px;' }, [
				E('button', {
					'class': 'btn cbi-button cbi-button-save',
					'click': function() {
						var val = editor.value;
						ui.showModal(_('正在保存'), [E('p', { 'class': 'spinning' }, _('正在保存配置文件并生成备份...'))]);
						return fs.exec_direct('/usr/libexec/luci-app-shellcrash/ctl.sh', ['cfg-write'], 'stdin', val).then(function() {
							ui.hideModal();
							ui.addNotification(null, E('p', {}, _('配置文件保存成功并已备份')));
						}).catch(function(err) {
							ui.hideModal();
							ui.addNotification(null, E('p', {}, _('保存失败: ') + err.message));
						});
					}
				}, _('保存配置')),
				E('button', {
					'class': 'btn cbi-button cbi-button-reset',
					'click': function() {
						if (!confirm(_('确定从最近的备份文件恢复配置吗？当前未保存的修改将被覆盖。'))) return;
						ui.showModal(_('正在恢复'), [E('p', { 'class': 'spinning' }, _('正在还原配置...'))]);
						return fs.exec('/usr/libexec/luci-app-shellcrash/ctl.sh', ['cfg-restore']).then(function(res) {
							ui.hideModal();
							window.location.reload();
						});
					}
				}, _('从备份还原'))
			])
		]);
		viewRoot.appendChild(secEditor);

		return viewRoot;
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
