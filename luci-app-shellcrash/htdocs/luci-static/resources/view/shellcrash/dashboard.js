'use strict';
'require view';
'require fs';
'require uci';
'require ui';
'require shellcrash.panel as panelHelper';

return view.extend({
	load: function() {
		return Promise.all([
			fs.exec('/usr/libexec/luci-app-shellcrash/dashboard.sh', ['status']),
			fs.exec('/usr/libexec/luci-app-shellcrash/ctl.sh', ['status']),
			uci.load('shellcrash')
		]);
	},

	render: function(data) {
		var dashRaw = data[0] || {};
		var statusRaw = data[1] || {};
		var dash = {};
		var status = {};

		try { dash = JSON.parse(dashRaw.stdout || '{}'); } catch(e) {}
		try { status = JSON.parse(statusRaw.stdout || '{}'); } catch(e) {}

		var uciData = uci.get_first('shellcrash', 'main') || {};

		var viewRoot = E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('Web 控制面板管理')),
			E('div', { 'class': 'cbi-map-descr' }, _('部署与管理基于 Web 的可视化面板（Zashboard / Metacubexd / Yacd），直观管理节点分组与连接'))
		]);

		// Section 1: Dashboard Status & Launch
		var coreInstalled = dash.core_installed === true;
		var localInstalled = dash.local_installed === true;

		var secStatus = E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('面板部署状态')),
			E('table', { 'class': 'table' }, [
				E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td', 'style': 'width: 25%; font-weight: bold;' }, _('内核内置面板 (Core UI)')),
					E('td', { 'class': 'td' }, [
						E('span', {
							'style': 'display: inline-block; padding: 2px 8px; border-radius: 4px; color: #fff; font-weight: bold; background-color: ' + (coreInstalled ? '#28a745' : '#6c757d')
						}, coreInstalled ? _('已安装') : _('未部署')),
						coreInstalled ? E('span', { 'style': 'margin-left: 10px; color: #666;' }, '(' + dash.core_type + ' - ' + dash.core_path + ')') : ''
					])
				]),
				E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td', 'style': 'font-weight: bold;' }, _('LuCI 本地站点面板')),
					E('td', { 'class': 'td' }, [
						E('span', {
							'style': 'display: inline-block; padding: 2px 8px; border-radius: 4px; color: #fff; font-weight: bold; background-color: ' + (localInstalled ? '#28a745' : '#6c757d')
						}, localInstalled ? _('已安装') : _('未部署')),
						localInstalled ? E('span', { 'style': 'margin-left: 10px; color: #666;' }, '(' + dash.local_type + ' - ' + dash.local_path + ')') : ''
					])
				])
			]),
			E('div', { 'style': 'margin-top: 15px;' }, [
				E('button', {
					'class': 'btn cbi-button cbi-button-positive',
					'click': function() {
						var url = panelHelper.resolveUrl(uciData, status);
						window.open(url, '_blank');
					}
				}, _('立即打开 Web 控制面板 ↗'))
			])
		]);
		viewRoot.appendChild(secStatus);

		// Section 2: Deployment Actions
		var secDeploy = E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('一键下载与部署')),
			E('p', { 'style': 'color: #666;' }, _('选择需要部署的面板类型，插件将自动从最新 Release 下载静态资源并解压：')),
			E('div', { 'style': 'display: flex; gap: 10px; flex-wrap: wrap; margin-top: 10px;' }, [
				E('button', {
					'class': 'btn cbi-button cbi-button-action',
					'click': function() {
						ui.showModal(_('正在部署 Zashboard'), [
							E('p', { 'class': 'spinning' }, _('正在下载并部署 Zashboard 至内核面板目录，请稍候...'))
						]);
						return fs.exec('/usr/libexec/luci-app-shellcrash/dashboard.sh', ['install', 'core', 'zashboard']).then(function(res) {
							ui.hideModal();
							ui.addNotification(null, E('p', {}, _('Zashboard 部署完成！')));
							setTimeout(function() { window.location.reload(); }, 1200);
						}).catch(function(err) {
							ui.hideModal();
							ui.addNotification(null, E('p', {}, _('部署失败: ') + err.message));
						});
					}
				}, _('部署 Zashboard (推荐)')),
				E('button', {
					'class': 'btn cbi-button cbi-button-neutral',
					'click': function() {
						ui.showModal(_('正在部署 Metacubexd'), [
							E('p', { 'class': 'spinning' }, _('正在下载并部署 Metacubexd 至内核面板目录，请稍候...'))
						]);
						return fs.exec('/usr/libexec/luci-app-shellcrash/dashboard.sh', ['install', 'core', 'metacubexd']).then(function(res) {
							ui.hideModal();
							ui.addNotification(null, E('p', {}, _('Metacubexd 部署完成！')));
							setTimeout(function() { window.location.reload(); }, 1200);
						}).catch(function(err) {
							ui.hideModal();
							ui.addNotification(null, E('p', {}, _('部署失败: ') + err.message));
						});
					}
				}, _('部署 Metacubexd')),
				(coreInstalled || localInstalled) ? E('button', {
					'class': 'btn cbi-button cbi-button-negative',
					'click': function() {
						if (!confirm(_('确定卸载已部署的本地面板吗？'))) return;
						return Promise.all([
							fs.exec('/usr/libexec/luci-app-shellcrash/dashboard.sh', ['uninstall', 'core']),
							fs.exec('/usr/libexec/luci-app-shellcrash/dashboard.sh', ['uninstall', 'local'])
						]).then(function() {
							window.location.reload();
						});
					}
				}, _('卸载本地面板')) : ''
			])
		]);
		viewRoot.appendChild(secDeploy);

		return viewRoot;
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
