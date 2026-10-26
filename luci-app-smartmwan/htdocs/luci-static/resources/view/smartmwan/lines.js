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

function call(method) {
	return rpc.declare({ object: 'smartmwan', method: method });
}

return view.extend({
	load: function() {
		return call('getLines')().catch(function(e) {
			return { __error: String(e && e.message || e) };
		});
	},

	render: function(data) {
		var smw = smartmwan;   /* LuCI require 返回单例实例，不可再 new */
		var parsed = data && data.__error == null ? smw.parse(data) : null;

		if (parsed == null || parsed.state == 'error')
			return 'lines', E('div', { 'id': ROOT }, smw.states(
				parsed || { state: 'error', error: { message: data && data.__error } },
				{ loadingText: '正在读取线路…', emptyText: '没有配置任何线路' }));

		if (parsed.state != 'ready')
			return E('div', { 'id': ROOT }, smw.states(parsed, { emptyText: '没有配置任何线路' }));

		var self = this;
		var root = E('div', { 'id': ROOT, 'class': 'smw-panel' }, [
			E('h2', {}, [ '线路管理' ])
		]);

		/* 概览：一眼看出有几条线路、多少条可用 —— 卡片比翻表格快。 */
		var lines = parsed.data.lines || [];
		var usable = lines.filter(function(l) {
			return l.state === 'healthy' || l.state === 'degraded';
		}).length;
		root.appendChild(E('div', { 'class': 'smw-cards' }, [
			smw.stat('线路总数', String(lines.length), ''),
			smw.stat('可用', String(usable), usable === 0 ? '没有可用出口' : '',
				usable === 0 ? 'bad' : 'ok'),
			smw.stat('已完成首轮探测', parsed.data.measured ? '是' : '否',
				parsed.data.measured ? '' : '状态尚未可判定',
				parsed.data.measured ? '' : 'warn')
		]));

		lines.forEach(function(l) {
			var m = l.metrics || {};
			var card = E('div', { 'class': 'smw-line-card' }, [
				E('div', { 'class': 'smw-line-head' }, [
					E('strong', {}, [ l.name ]),
					smw.stateBadge(l.state, l.state_label),
					l.enabled ? '' : E('span', { 'class': 'smw-badge smw-badge-muted' }, [ '已停用' ]),
					l.maintenance ? E('span', { 'class': 'smw-badge smw-badge-warn' }, [ '维护模式' ]) : '',
					l.slot ? E('span', { 'class': 'smw-badge smw-badge-info' },
						[ '槽位 ' + l.slot + ' / 表 ' + l.table ]) : ''
				]),
				smw.kv([
					[ '设备 / 链路', (l.device || '—') + '（' + (l.link_up ? 'up' : 'down') + '）' ],
					[ '地址 / 网关', (l.address || '—') + ' / ' + (l.gateway || '—') ],
					[ 'RTT / 抖动',
						(m.rtt_ms != null ? m.rtt_ms + ' ms' : '—') + ' / ' +
						(m.jitter_ms != null ? m.jitter_ms + ' ms' : '—') ],
					[ '丢包', m.loss_pmm != null ? smw.pmm(m.loss_pmm) : '—' ],
					[ '并发连接', String(l.conns) ],
					[ '阻断原因', l.blocked_reason || '无' ],
					[ '最近探测', l.last_outcome || '—' ]
				]),
				l.resolve_notes && l.resolve_notes.length
					? E('ul', { 'class': 'smw-notes' },
						l.resolve_notes.map(function(n) { return E('li', {}, [ n ]); }))
					: ''
			]);

			/* 维护模式开关：写方法，守护进程审计。
			 * 注意：createHandlerFn 自动禁用/恢复触发按钮（spinning + disabled），
			 * 并把 event 追加为 handler 最后一个参数——不要自己传/管理 btn。 */
			card.appendChild(E('div', { 'class': 'smw-line-actions' }, [
				E('button', {
					'class': 'btn cbi-button',
					'click': ui.createHandlerFn(self, 'handleMaintenance', l.name, !l.maintenance)
				}, [ l.maintenance ? '退出维护模式' : '进入维护模式' ])
			]));
			root.appendChild(card);
		});

		if (!parsed.data.measured)
			root.appendChild(E('p', { 'class': 'smw-muted' }, [
				'尚未完成首轮探测：上面的状态是「未测量」而不是「正常」。'
			]));

		return root;
	},

	handleMaintenance: function(wan, on) {
		var self = this;
		call('setMaintenance')({ wan: wan, on: on }).then(function(env) {
			if (env && env.ok)
				ui.addNotification(null, E('p', [
					'线路 ' + wan + (on ? ' 已进入' : ' 已退出') + '维护模式'
				]), 'info');
			else
				ui.addNotification(null, E('p', [
					'操作失败：' + ((env && env.error && env.error.message) || '未知错误')
				]), 'error');
			smartmwan.refresh(self, ROOT);
		}).catch(function(e) {
			ui.addNotification(null, E('p', [ 'RPC 失败：' + e ]), 'error');
		});
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
