'use strict';
'require view';
'require dom';
'require fs';
'require ui';
'require poll';

return view.extend({
	load: function() {
		return fs.exec('/usr/libexec/luci-app-shellcrash/ctl.sh', ['logs', '200']);
	},

	render: function(logRaw) {
		var logText = logRaw.stdout || _('暂无运行日志');

		var logBox = E('pre', {
			'id': 'sc-log-box',
			'style': 'width: 100%; height: 500px; margin: 0; padding: 12px; font-family: monospace; font-size: 12px; line-height: 1.5; background: #222; color: #eee; border-radius: 4px; overflow-y: auto; white-space: pre-wrap; word-break: break-all;'
		}, [logText]);

		var isAutoRefresh = true;

		var viewRoot = E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('ShellCrash 运行日志')),
			E('div', { 'class': 'cbi-map-descr' }, _('实时查看 ShellCrash 与代理核心的运行与连接日志'))
		]);

		var controlBar = E('div', { 'style': 'display: flex; gap: 10px; align-items: center; margin-bottom: 15px;' }, [
			E('button', {
				'class': 'btn cbi-button cbi-button-action',
				'click': function() {
					return fs.exec('/usr/libexec/luci-app-shellcrash/ctl.sh', ['logs', '200']).then(function(res) {
						dom.content(logBox, [res.stdout || _('暂无运行日志')]);
						logBox.scrollTop = logBox.scrollHeight;
					});
				}
			}, _('手动刷新')),
			E('label', { 'style': 'display: flex; align-items: center; gap: 5px; cursor: pointer; user-select: none;' }, [
				E('input', {
					'type': 'checkbox',
					'checked': true,
					'change': function() {
						isAutoRefresh = this.checked;
					}
				}),
				_('自动刷新 (每 3 秒)')
			])
		]);

		var secLog = E('div', { 'class': 'cbi-section' }, [
			controlBar,
			logBox
		]);
		viewRoot.appendChild(secLog);

		// Scroll to bottom initially
		setTimeout(function() {
			logBox.scrollTop = logBox.scrollHeight;
		}, 100);

		// Polling
		poll.add(function() {
			if (!isAutoRefresh) return Promise.resolve();
			return fs.exec('/usr/libexec/luci-app-shellcrash/ctl.sh', ['logs', '200']).then(function(res) {
				dom.content(logBox, [res.stdout || _('暂无运行日志')]);
				logBox.scrollTop = logBox.scrollHeight;
			});
		}, 3);

		return viewRoot;
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
