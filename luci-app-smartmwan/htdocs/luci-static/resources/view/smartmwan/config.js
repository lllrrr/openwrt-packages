'use strict';
/*
 * smartmwan —— 配置视图（零 Lua）
 * 数据源：smartmwan.getConfig / validate / save / diff / apply / rollback / reload。
 *
 * save 与 apply 严格分离：save 只写盘并返回差异；apply 才走守护进程的一次完整事务。
 * 「应用前变更摘要」由后端 diff 给出，界面不自行拼装。
 */
'require smartmwan';
'require view';
'require rpc';
'require ui';

var ROOT = 'smw-config-root';

return view.extend({
	load: function() {
		return Promise.all([
			rpc.declare({ object: 'smartmwan', method: 'getConfig' })(),
			rpc.declare({ object: 'smartmwan', method: 'diff' })()
		]).then(function(rv) {
			return { config: rv[0], diff: rv[1] };
		}).catch(function(e) {
			return { __error: String(e && e.message || e) };
		});
	},

	render: function(data) {
		var smw = new smartmwan();
		if (data == null || data.__error != null)
			return E('div', { 'id': ROOT, 'class': 'smw-state smw-state-error alert-message warning' }, [
				E('strong', {}, [ 'RPC 失败：' ]),
				E('span', {}, [ (data && data.__error) || '无法读取配置' ])
			]);

		var cfg = smw.parse(data.config);
		if (cfg.state != 'ready')
			return E('div', { 'id': ROOT }, smw.states(cfg, { loadingText: '正在读取配置…' }));

		var diff = data.diff || {};
		var root = E('div', { 'id': ROOT, 'class': 'smw-panel' }, [ E('h2', {}, [ '配置' ]) ]);

		/* —— 当前配置概览（只读；编辑走 UCI 或后续表单） —— */
		var g = cfg.data.config.global;
		root.appendChild(E('h3', {}, [ '当前配置' ]));
		root.appendChild(smw.table(
			[ '项目', '值' ],
			[
				[ 'schema 版本', 'v' + cfg.data.schema_version ],
				[ '启用', g.enabled ? '是' : '否（首次安装不改变现有路由）' ],
				[ '模式', g.mode == 'failover' ? '主备' : '均衡' ],
				[ '算法', g.algorithm ],
				[ '桶数', String(g.buckets) ],
				[ '线路数', String(cfg.data.config.wans.length) ],
				[ '游戏规则数', String(cfg.data.config.games.length) ],
				[ '已应用快照', cfg.data.applied ? ('事务 ' + cfg.data.applied.transaction) : '从未应用' ]
			]
		));

		/* —— 待下发变更：后端 diff 原样展示 —— */
		root.appendChild(E('h3', {}, [ '待下发变更' ]));
		if (diff.ok && diff.data && diff.data.changes && diff.data.changes.length) {
			root.appendChild(E('ul', { 'class': 'smw-notes' },
				diff.data.changes.map(function(c) {
					return E('li', {}, [
						c.path + '：' + c.old + ' → ' + c.new +
						(c.risky ? '（高风险，需二次确认）' : '')
					]);
				})
			));
			root.appendChild(E('div', { 'class': 'smw-actions' }, [
				E('button', {
					'class': 'btn cbi-button cbi-button-apply important',
					'click': ui.createHandlerFn(this, 'handleApply')
				}, [ '应用变更（一次完整事务）' ])
			]));
		} else {
			root.appendChild(E('p', { 'class': 'smw-muted' },
				[ (diff.data && diff.data.note) || '当前保存的配置与上次成功应用一致' ]));
		}

		/* —— 操作区 —— */
		root.appendChild(E('h3', {}, [ '操作' ]));
		root.appendChild(E('div', { 'class': 'smw-actions' }, [
			E('button', {
				'class': 'btn cbi-button',
				'click': ui.createHandlerFn(this, 'handleReload')
			}, [ '重新读取配置' ]),
			E('button', {
				'class': 'btn cbi-button cbi-button-reset',
				'click': ui.createHandlerFn(this, 'handleRollback')
			}, [ '回滚到 last-good 并重新下发' ])
		]));
		root.appendChild(E('p', { 'class': 'smw-muted' },
			[ '「保存」与「应用」分离：修改 UCI 文件后先重新读取，确认变更摘要无误再应用。' +
			  '回滚会写回 last-good 快照并重新下发。' ]));

		/* —— 最近一次应用的结果 —— */
		if (cfg.data.applied) {
			root.appendChild(E('h3', {}, [ '最近一次应用' ]));
			root.appendChild(E('p', {}, [
				'事务 ', E('code', {}, [ cfg.data.applied.transaction ]),
				'，应用于 ', new smartmwan().time(cfg.data.applied.applied_at_ms)
			]));
		}

		return root;
	},

	handleApply: function() {
		var self = this;
		if (!confirm('将执行一次完整事务（策略路由 + nft 提交）。确认应用？'))
			return;
		rpc.declare({ object: 'smartmwan', method: 'apply' })().then(function(env) {
			if (env && env.ok) {
				var r = env.data || {};
				ui.addNotification(null, E('p', [
					'事务 ' + r.id + '：' + (r.ok ? (r.changed ? '已提交' : '无变更（幂等复核通过）') : '未提交')
				]), 'info');
			} else {
				ui.addNotification(null, E('p', [
					'应用失败：' + ((env && env.error && env.error.message) || '未知错误')
				]), 'error');
			}
			self.render(self.load());
		}).catch(function(e) {
			ui.addNotification(null, E('p', [ 'RPC 失败：' + e ]), 'error');
		});
	},

	handleRollback: function() {
		var self = this;
		if (!confirm('将回滚到上一次成功应用的快照并重新下发。确认？'))
			return;
		rpc.declare({ object: 'smartmwan', method: 'rollback' })().then(function(env) {
			if (env && env.ok) {
				ui.addNotification(null, E('p', [ '已回滚到 last-good 并重新下发' ]), 'info');
			} else {
				ui.addNotification(null, E('p', [
					'回滚失败：' + ((env && env.error && env.error.message) || '未知错误')
				]), 'error');
			}
			self.render(self.load());
		}).catch(function(e) {
			ui.addNotification(null, E('p', [ 'RPC 失败：' + e ]), 'error');
		});
	},

	handleReload: function() {
		var self = this;
		rpc.declare({ object: 'smartmwan', method: 'reload' })().then(function(env) {
			if (env && env.ok) {
				ui.addNotification(null, E('p', [ (env.data && env.data.note) || '已重新读取' ]), 'info');
			} else {
				ui.addNotification(null, E('p', [
					'重载失败：' + ((env && env.error && env.error.message) || '未知错误')
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
