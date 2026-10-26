'use strict';
/*
 * smartmwan —— 主备切换视图（零 Lua）
 * 数据源：smartmwan.getFailover；写操作：forceWan / releaseForced。
 * 强制切换有二次确认（confirm），与后端 require_confirm 语义一致。
 */
'require smartmwan';
'require view';
'require rpc';
'require ui';

var ROOT = 'smw-failover-root';

return view.extend({
	load: function() {
		return rpc.declare({ object: 'smartmwan', method: 'getFailover' })().catch(function(e) {
			return { __error: String(e && e.message || e) };
		});
	},

	render: function(data) {
		var smw = new smartmwan();
		var parsed = data && data.__error == null ? smw.parse(data) : null;

		if (parsed == null || parsed.state == 'error')
			return E('div', { 'id': ROOT }, smw.states(parsed || { state: 'error', error: { message: data && data.__error } }, {
				loadingText: '正在读取主备状态…'
			}));

		if (parsed.state != 'ready')
			return E('div', { 'id': ROOT }, smw.states(parsed, { emptyText: '暂无主备数据' }));

		var f = parsed.data;
		var root = E('div', { 'id': ROOT, 'class': 'smw-panel' }, [ E('h2', {}, [ '主备切换' ]) ]);

		root.appendChild(smw.table(
			[ '项目', '值' ],
			[
				[ '活动线路', f.active || '—' ],
				[ '强制指定', f.forced || '—' ],
				[ '待命线路', f.standby && f.standby.length ? f.standby.join('、') : '—' ],
				[ '等待回切', f.waiting ? (f.waiting.wan + '：' + f.waiting.reason) : '—' ],
				[ '回切策略', f.failback + '（延迟 ' + f.failback_delay_ms + ' ms，连续成功 ' + f.failback_success_threshold + ' 次）' ],
				[ '最小切换间隔', f.min_switch_interval_ms + ' ms' ],
				[ '主线路', f.primary || '—' ]
			]
		));

		root.appendChild(E('h3', {}, [ '切换顺序' ]));
		root.appendChild(E('ol', { 'class': 'smw-order' },
			(f.order || []).map(function(n, i) {
				return E('li', {}, [ n + (n == f.active ? '（当前活动）' : '') ]);
			})
		));

		if (f.forced) {
			root.appendChild(E('div', { 'class': 'smw-block' }, [
				E('button', {
					'class': 'btn cbi-button cbi-button-reset',
					'click': ui.createHandlerFn(this, 'handleRelease')
				}, [ '取消强制，回到自动决策' ])
			]));
		} else {
			root.appendChild(E('h3', {}, [ '强制切换' ]));
			root.appendChild(E('p', { 'class': 'smw-muted' },
				[ '强制切换会把全部普通流量切到指定线路，需要二次确认。目标线路暂不可用时指令保留，恢复后生效。' ]));
			root.appendChild(E('div', { 'class': 'smw-actions' },
				(f.order || []).filter(function(n) { return n != f.active }).map(function(n) {
					return E('button', {
						'class': 'btn cbi-button',
						'click': ui.createHandlerFn(this, 'handleForce', n)
					}, [ '强制切换到 ' + n ]);
				})
			));
		}

		return root;
	},

	handleForce: function(wan) {
		var self = this;
		if (!confirm('确认把全部普通流量强制切换到 ' + wan + ' ？'))
			return;
		rpc.declare({
			object: 'smartmwan',
			method: 'forceWan',
			params: [ 'wan', 'confirm' ]
		})(wan, true).then(function(env) {
			if (env && env.ok) {
				ui.addNotification(null, E('p', [ '已提交强制切换（事务 ' + (env.data && env.data.id) + '）' ]), 'info');
			} else {
				ui.addNotification(null, E('p', [
					'操作失败：' + ((env && env.error && env.error.message) || '未知错误')
				]), 'error');
			}
			self.render(self.load());
		}).catch(function(e) {
			ui.addNotification(null, E('p', [ 'RPC 失败：' + e ]), 'error');
		});
	},

	handleRelease: function() {
		var self = this;
		rpc.declare({ object: 'smartmwan', method: 'releaseForced' })().then(function(env) {
			if (env && env.ok) {
				ui.addNotification(null, E('p', [ '已取消强制，回到自动决策' ]), 'info');
			} else {
				ui.addNotification(null, E('p', [
					'操作失败：' + ((env && env.error && env.error.message) || '未知错误')
				]), 'error');
			}
			self.render(self.load());
		}).catch(function(e) {
			ui.addNotification(null, E('p', [ 'RPC 失败：' + e ]), 'error');
		});
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
