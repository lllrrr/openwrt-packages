'use strict';
'require view';
'require rpc';
'require ui';
'require dom';

var callDiagnose = rpc.declare({
	object: 'luci.ups-manager',
	method: 'diagnose',
	expect: { '': {} }
});

var callGetLogs = rpc.declare({
	object: 'luci.ups-manager',
	method: 'get_logs',
	expect: { '': {} }
});

return view.extend({
	load: function() {
		return Promise.all([
			callDiagnose(),
			callGetLogs()
		]);
	},

	render: function(data) {
		var self = this;
		var diag = data[0] || {};
		var logs = data[1] || {};

		var container = E('div', { 'class': 'cbi-map' }, [
			E('h2', { 'class': 'cbi-map-title' }, _('运行日志与系统维护诊断')),
			E('div', { 'class': 'cbi-map-descr' }, _('实时检查 NUT 守护进程、驱动进程、USB 总线节点挂载与安全监听状态。诊断过程为纯只读操作，不会重启服务或切断电源。'))
		]);

		// Diagnosis items
		var checkSection = E('div', { 'class': 'cbi-section' }, [
			E('div', { 'style': 'display:flex;justify-content:space-between;align-items:center;margin-bottom:1rem;' }, [
				E('h3', { 'class': 'cbi-section-title', 'style': 'margin:0;' }, _('系统健康状态诊断')),
				E('button', {
					'class': 'cbi-button cbi-button-action',
					'click': function() {
						return callDiagnose().then(function(newDiag) {
							var body = document.getElementById('diag-table-body');
							if (body) dom.content(body, self.renderDiagRows(newDiag));
							ui.addNotification(null, E('p', {}, _('诊断完成，已更新检测状态。')), 'info');
						});
					}
				}, _('重新运行诊断'))
			]),
			E('table', { 'class': 'table cbi-section-table', 'style': 'width:100%;' }, [
				E('thead', {}, [
					E('tr', { 'class': 'tr cbi-section-table-titles' }, [
						E('th', { 'class': 'th', 'style': 'width:25%;' }, _('诊断检查项')),
						E('th', { 'class': 'th', 'style': 'width:15%;' }, _('结果状态')),
						E('th', { 'class': 'th', 'style': 'width:60%;' }, _('诊断详细信息与建议'))
					])
				]),
				E('tbody', { 'id': 'diag-table-body' }, self.renderDiagRows(diag))
			])
		]);

		// Logs section
		var logSection = E('div', { 'class': 'cbi-section', 'style': 'margin-top:2rem;' }, [
			E('div', { 'style': 'display:flex;justify-content:space-between;align-items:center;margin-bottom:1rem;' }, [
				E('h3', { 'class': 'cbi-section-title', 'style': 'margin:0;' }, _('系统事件与通信日志')),
				E('div', { 'style': 'display:flex;gap:0.5rem;' }, [
					E('a', {
						'class': 'cbi-button cbi-button-action',
						'href': L.url('admin/services/ups_manager/events')
					}, _('⏱️ 查看事件历史流')),
					E('button', {
						'class': 'cbi-button cbi-button-neutral',
						'click': function() {
							return callGetLogs().then(function(newLogs) {
								var pre = document.getElementById('log-viewer-pre');
								if (pre) pre.innerText = (newLogs.logs && newLogs.logs.length) ? newLogs.logs.join('\n') : _('暂无日志数据');
							});
						}
					}, _('刷新日志')),
					E('button', {
						'class': 'cbi-button cbi-button-action',
						'click': function() {
							var pre = document.getElementById('log-viewer-pre');
							var text = pre ? pre.innerText : '';
							var blob = new Blob([text], { type: 'text/plain' });
							var url = URL.createObjectURL(blob);
							var a = document.createElement('a');
							a.href = url;
							a.download = 'ups_manager_events_' + Math.floor(Date.now() / 1000) + '.log';
							a.click();
							URL.revokeObjectURL(url);
						}
					}, _('导出日志文本'))
				])
			]),
			E('pre', {
				'id': 'log-viewer-pre',
				'style': 'background:#0f172a;color:#e2e8f0;padding:1.25rem;border-radius:0.5rem;font-size:0.85rem;max-height:400px;overflow-y:auto;line-height:1.5;'
			}, (logs.logs && logs.logs.length) ? logs.logs.join('\n') : _('暂无日志数据'))
		]);

		dom.append(container, [checkSection, logSection]);
		return container;
	},

	renderDiagRows: function(diag) {
		var checks = (diag && diag.checks) ? diag.checks : [];
		if (checks.length === 0) {
			return [
				E('tr', {}, [
					E('td', { 'colspan': '3', 'style': 'text-align:center;padding:1rem;' }, _('未获取到诊断数据'))
				])
			];
		}

		var rows = [];
		for (var i = 0; i < checks.length; i++) {
			var c = checks[i];
			var badgeClass = 'cbi-button-apply';
			var badgeText = '✓ 正常';
			if (c.status === 'warning') {
				badgeClass = 'cbi-button-neutral';
				badgeText = '⚠ 警告';
			} else if (c.status === 'error') {
				badgeClass = 'cbi-button-reset';
				badgeText = '✕ 异常';
			}

			rows.push(E('tr', { 'class': 'tr cbi-section-table-row' }, [
				E('td', { 'class': 'td', 'style': 'font-weight:600;' }, c.title),
				E('td', { 'class': 'td' }, [
					E('span', { 'class': 'cbi-button ' + badgeClass, 'style': 'padding:2px 8px;font-size:0.75rem;cursor:default;' }, badgeText)
				]),
				E('td', { 'class': 'td' }, c.message)
			]));
		}

		return rows;
	}
});
