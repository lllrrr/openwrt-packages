'use strict';
/*
 * smartmwan —— 线路管理视图（零 Lua）
 * 数据源：smartmwan.getLines / getLine；写操作：setMaintenance。
 * 写操作全部走 bridge → 守护进程；界面不本地猜测状态。
 */
'require smartmwan';
'require view';
'require rpc';
'require ui';

var ROOT = 'smw-lines-root';

return view.extend({
	load: function() {
		return rpc.declare({ object: 'smartmwan', method: 'getLines' })().catch(function(e) {
			return { __error: String(e && e.message || e) };
		});
	},

	render: function(data) {
		var smw = new smartmwan();
		var parsed = data && data.__error == null ? smw.parse(data) : null;

		if (parsed == null || parsed.state == 'error')
			return E('div', { 'id': ROOT }, smw.states(parsed || { state: 'error', error: { message: data && data.__error } }, {
				loadingText: '正在读取线路…',
				emptyText: '没有配置任何线路'
			}));

		if (parsed.state != 'ready')
			return E('div', { 'id': ROOT }, smw.states(parsed, { emptyText: '没有配置任何线路' }));

		var self = this;
		var root = E('div', { 'id': ROOT, 'class': 'smw-panel' }, [ E('h2', {}, [ '线路管理' ]) ]);

		parsed.data.lines.forEach(function(l) {
			var card = E('div', { 'class': 'smw-line-card' }, [
				E('div', { 'class': 'smw-line-head' }, [
					E('strong', {}, [ l.name ]),
					' ',
					smw.stateBadge(l.state, l.state_label),
					l.enabled ? '' : E('span', { 'class': 'smw-badge smw-badge-muted' }, [ '已停用' ]),
					l.maintenance ? E('span', { 'class': 'smw-badge smw-badge-warn' }, [ '维护模式' ]) : ''
				]),
				smw.table(
					[ '项目', '值' ],
					[
						[ '设备', l.device || '—' ],
						[ '地址 / 网关', (l.address || '—') + ' / ' + (l.gateway || '—') ],
						[ '链路', l.link_up ? 'up' : 'down' ],
						[ '槽位 / 路由表', l.slot ? l.slot + ' / ' + l.table : '—' ],
						[ 'RTT', l.metrics && l.metrics.rtt_ms != null ? l.metrics.rtt_ms + ' ms' : '—' ],
						[ '丢包', l.metrics && l.metrics.loss_pmm != null ? smw.pmm(l.metrics.loss_pmm) : '—' ],
						[ '并发连接', String(l.conns) ],
						[ '阻断原因', l.blocked_reason || '—' ],
						[ '最近探测', l.last_outcome || '—' ]
					]
				),
				l.resolve_notes && l.resolve_notes.length
					? E('ul', { 'class': 'smw-notes' },
						l.resolve_notes.map(function(n) { return E('li', {}, [ n ]) }))
					: ''
			]);

			/* 维护模式开关：写方法，守护进程审计 */
			var btn = E('button', {
				'class': 'btn cbi-button',
				'click': ui.createHandlerFn(self, 'handleMaintenance', l.name, !l.maintenance, btn)
			}, [ l.maintenance ? '退出维护模式' : '进入维护模式' ]);

			card.appendChild(E('div', { 'class': 'smw-line-actions' }, [ btn ]));
			root.appendChild(card);
		});

		return root;
	},

	handleMaintenance: function(wan, on, btn) {
		var self = this;
		btn.disabled = true;
		rpc.declare({
			object: 'smartmwan',
			method: 'setMaintenance',
			params: [ 'wan', 'on' ]
		})(wan, on).then(function(env) {
			if (env && env.ok) {
				ui.addNotification(null, E('p', [ '线路 ' + wan + (on ? ' 已进入' : ' 已退出') + '维护模式' ]), 'info');
			} else {
				ui.addNotification(null, E('p', [
					'操作失败：' + ((env && env.error && env.error.message) || '未知错误')
				]), 'error');
			}
			self.render(self.load());
		}).catch(function(e) {
			ui.addNotification(null, E('p', [ 'RPC 失败：' + e ]), 'error');
			btn.disabled = false;
		});
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
