'use strict';
'require view';
'require fs';
'require ui';

return view.extend({
	load: function() {
		return fs.exec('/usr/libexec/luci-app-shellcrash/ctl.sh', ['sub-get']);
	},

	render: function(subRaw) {
		var subData = {};
		try {
			subData = JSON.parse(subRaw.stdout || '{}');
		} catch (e) {
			subData = {};
		}
		var list = subData.subscriptions || [];

		var viewRoot = E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('订阅与节点管理')),
			E('div', { 'class': 'cbi-map-descr' }, _('管理 ShellCrash 的订阅源、在线拉取节点规则并重载代理核心'))
		]);

		// Section 1: Subscriptions Table
		var tableRows = [];
		if (list.length === 0) {
			tableRows.push(E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td', 'colspan': '3', 'style': 'text-align: center; color: #888;' }, _('暂未配置任何订阅，请在下方添加或在 ShellCrash 命令行导入'))
			]));
		} else {
			for (var i = 0; i < list.length; i++) {
				var item = list[i];
				tableRows.push(E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td', 'style': 'font-weight: bold;' }, item.name),
					E('td', { 'class': 'td', 'style': 'word-break: break-all; font-family: monospace; font-size: 12px;' }, item.url),
					E('td', { 'class': 'td' }, item.interval || _('默认周期'))
				]));
			}
		}

		var secList = E('div', { 'class': 'cbi-section' }, [
			E('div', { 'style': 'display: flex; justify-content: space-between; align-items: center; margin-bottom: 10px;' }, [
				E('h3', {}, _('已配置的订阅源')),
				E('button', {
					'class': 'btn cbi-button cbi-button-action',
					'click': function() {
						ui.showModal(_('正在更新订阅'), [
							E('p', { 'class': 'spinning' }, _('正在下载最新订阅节点与规则并生成核心配置，这可能需要几十秒...'))
						]);
						return fs.exec('/usr/libexec/luci-app-shellcrash/ctl.sh', ['sub-update']).then(function(res) {
							ui.hideModal();
							ui.addNotification(null, E('p', {}, _('订阅更新任务执行完成')));
							setTimeout(function() { window.location.reload(); }, 1500);
						}).catch(function(err) {
							ui.hideModal();
							ui.addNotification(null, E('p', {}, _('更新失败: ') + err.message));
						});
					}
				}, _('立即更新全部订阅并重载'))
			]),
			E('table', { 'class': 'table' }, [
				E('tr', { 'class': 'tr table-titles' }, [
					E('th', { 'class': 'th', 'style': 'width: 20%;' }, _('订阅名称')),
					E('th', { 'class': 'th', 'style': 'width: 65%;' }, _('订阅链接 (URL)')),
					E('th', { 'class': 'th', 'style': 'width: 15%;' }, _('更新周期'))
				])
			].concat(tableRows))
		]);
		viewRoot.appendChild(secList);

		// Section 2: Instructions and Tips
		var secTips = E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('订阅维护提示')),
			E('ul', { 'style': 'line-height: 1.8; color: #555;' }, [
				E('li', {}, _('ShellCrash 支持通用 Clash/Meta 格式订阅以及 Base64 订阅转换。')),
				E('li', {}, _('如需更细粒度的分流规则分流、节点测速或节点排序，亦可点击顶部的“运行控制 -> 打开 Web 控制面板”直接在 Zashboard / Metacubexd 中可视化切换节点。')),
				E('li', {}, _('若订阅包含国内域名规则或直连规则，请在“内核与参数”中确保模式为 Rule (规则分流)。'))
			])
		]);
		viewRoot.appendChild(secTips);

		return viewRoot;
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
