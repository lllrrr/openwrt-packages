'use strict';
/*
 * smartmwan —— 主备切换视图（零 Lua）
 * 数据源：smartmwan.getFailover / getConfig；
 * 写操作：setPrimary / setBackupOrder / failback / save（+ apply）。
 *
 * 强制切换有二次确认（confirm），与后端 require_confirm 语义一致。
 * 「手动回切」是即时动作：主线路此刻不够格就如实不切，
 * 与「强制切换」（持久意志，目标恢复后自动生效）不是一回事。
 */
'require smartmwan';
'require view';
'require rpc';
'require ui';

var ROOT = 'smw-failover-root';

var FAILBACKS = [
	{ value: 'auto', label: '自动回切（满足延迟与连续成功条件后切回主线路）' },
	{ value: 'manual', label: '手动回切（主线路恢复后仍保持备用，需人工确认）' }
];

function call(method) {
	return rpc.declare({ object: 'smartmwan', method: method });
}

return view.extend({
	draft: null,

	load: function() {
		return Promise.all([
			call('getFailover')(),
			call('getConfig')()
		]).then(function(rv) {
			return { failover: rv[0], config: rv[1] };
		}).catch(function(e) {
			return { __error: String(e && e.message || e) };
		});
	},

	render: function(data) {
		var smw = smartmwan;
		if (data == null || data.__error != null)
			return 'failover', this.errorBox(data && data.__error);

		var parsed = smw.parse(data.failover);
		if (parsed.state == 'error')
			return 'failover', E('div', { 'id': ROOT }, smw.states(parsed, {
				loadingText: '正在读取主备状态…'
			}));
		if (parsed.state != 'ready')
			return E('div', { 'id': ROOT }, smw.states(parsed, { emptyText: '暂无主备数据' }));

		var f = parsed.data;
		var cfgParsed = smw.parse(data.config);
		this.base = cfgParsed.state == 'ready' ? cfgParsed.data.config : null;
		var self = this;
		var root = E('div', { 'id': ROOT, 'class': 'smw-panel' }, [
			E('h2', {}, [ '主备切换' ])
		]);

		/* —— 现状（只读） —— */
		root.appendChild(smw.section('当前状态', [
			smw.kv([
				[ '活动线路', f.active || '—' ],
				[ '主线路', f.primary || '—' ],
				[ '强制指定', f.forced || '—' ],
				[ '待命线路', f.standby && f.standby.length ? f.standby.join('、') : '—' ],
				[ '等待回切', f.waiting ? (f.waiting.wan + '：' + f.waiting.reason) : '—' ],
				[ '上次切换', f.last_switch_ms ? smartmwan.ago(f.last_switch_ms) : '从未切换' ]
			]),
			E('h4', {}, [ '切换顺序' ]),
			E('ol', { 'class': 'smw-order' },
				(f.order || []).map(function(n) {
					return E('li', {}, [ n + (n === f.active ? '（当前活动）' : '') ]);
				}))
		]));

		/* —— 编辑区 —— */
		if (this.base) {
			var g = this.base.global;
			var wans = this.base.wans || [];

			/* 主线路：走专门的 RPC（改一个字段就写盘并跑一轮事务，
			 * 不必先取整份配置再保存）。 */
			root.appendChild(smw.section('主线路', [
				E('div', { 'class': 'smw-form' }, [
					smw.field('主线路',
						smw.select(
							wans.map(function(w) {
								return {
									value: w.name,
									label: w.name + (w.enabled ? '' : '（已停用）')
								};
							}),
							g.primary,
							function(v) { self.setPrimary(v); }
						),
						'改动立即写盘并触发一轮事务；已排进备用列表的线路不能当主线路。')
				])
			]));

			/* 备用顺序：给每条线路一个序号，按序号升序排列。
			 * 拖拽排序好看但难用键盘操作，序号对所有人都一样的清楚。 */
			var orderFields = wans.filter(function(w) {
				return w.name !== g.primary;
			}).map(function(w) {
				var idx = g.backup_order.indexOf(w.name);
				return smw.field(w.name,
					smw.number(idx < 0 ? '' : idx + 1, { min: 1, max: wans.length }, function(v) {
						self.reorder(w.name, parseInt(v, 10));
					}),
					idx < 0 ? '留空 = 不参与备用' : '当前第 ' + (idx + 1) + ' 顺位');
			});
			root.appendChild(smw.section('备用顺序', [
				E('div', { 'class': 'smw-form' }, orderFields),
				E('p', { 'class': 'smw-muted' }, [
					'数字越小越优先接管。主线路故障时按此顺序挑第一条可用线路。'
				])
			]));

			/* 回切策略：多字段，走草稿 + save。 */
			var fbFields = [
				smw.field('回切方式',
					smw.select(FAILBACKS, g.failback, function(v) {
						self.stage(function(d) { d.global.failback = v; });
					}),
					'手动方式下主线路恢复也不会自动切回。'),
				smw.field('回切延迟（毫秒）',
					smw.number(g.failback_delay_ms, { min: 0, step: 1000 }, function(v) {
						self.stage(function(d) { d.global.failback_delay_ms = parseInt(v, 10); });
					}),
					'主线路健康后至少稳定这么久才回切；建议 ≥30000，避免抖动来回切。'),
				smw.field('连续成功次数',
					smw.number(g.failback_success_threshold, { min: 1, max: 100 }, function(v) {
						self.stage(function(d) { d.global.failback_success_threshold = parseInt(v, 10); });
					}),
					'回切前要求主线路连续探测成功的最少次数。'),
				smw.field('最小切换间隔（毫秒）',
					smw.number(g.min_switch_interval_ms, { min: 0, step: 1000 }, function(v) {
						self.stage(function(d) { d.global.min_switch_interval_ms = parseInt(v, 10); });
					}),
					'两次出口变更之间的兜底闸门，防止频繁切换。')
			];
			root.appendChild(smw.section('回切策略', [
				E('div', { 'class': 'smw-form' }, fbFields)
			]));
		}

		/* —— 操作区 —— */
		var actions = [];
		if (f.forced) {
			actions.push(E('button', {
				'class': 'btn cbi-button cbi-button-reset',
				'click': ui.createHandlerFn(this, 'handleRelease')
			}, [ '取消强制，回到自动决策' ]));
		} else {
			/* 手动回切：即时动作，不需要二次确认 —— 它恢复的是配置里的常态，
			 * 不是把流量强制到一条用户临时指定的线路。 */
			actions.push(E('button', {
				'class': 'btn cbi-button cbi-button-apply important',
				'click': ui.createHandlerFn(this, 'handleFailback')
			}, [ '立即回切到主线路' ]));
			(f.order || []).filter(function(n) { return n !== f.active; })
				.forEach(function(n) {
					actions.push(E('button', {
						'class': 'btn cbi-button',
						'click': ui.createHandlerFn(self, 'handleForce', n)
					}, [ '强制切换到 ' + n ]));
				});
		}
		root.appendChild(smw.section('操作', [
			E('div', { 'class': 'smw-actions' }, actions),
			E('p', { 'class': 'smw-muted' }, [
				'强制切换会把全部普通流量切到指定线路，需要二次确认；目标暂不可用时指令保留，恢复后生效。',
				'「立即回切」不同：主线路此刻不够格就如实不切，也不会留下一条将来悄悄生效的指令。'
			])
		]));

		/* 草稿保存栏 */
		this.slot = E('div', {});
		root.appendChild(this.slot);
		this.renderActions();

		return root;
	},

	/* ---------- 编辑辅助 ---------- */

	stage: function(fn) {
		if (this.draft == null)
			this.draft = JSON.parse(JSON.stringify(this.base));
		fn(this.draft);
		this.renderActions();
	},

	renderActions: function() {
		var self = this;
		if (this.slot == null)
			return;
		while (this.slot.firstChild)
			this.slot.removeChild(this.slot.firstChild);
		if (this.draft == null)
			return;
		this.slot.appendChild(smartmwan.dirty('回切策略有未保存的修改', [
			E('button', {
				'class': 'btn cbi-button',
				'click': ui.createHandlerFn(self, 'saveConfig', false)
			}, [ '保存' ]),
			E('button', {
				'class': 'btn cbi-button cbi-button-apply important',
				'click': ui.createHandlerFn(self, 'saveConfig', true)
			}, [ '保存并应用' ]),
			E('button', {
				'class': 'btn cbi-button cbi-button-reset',
				'click': function() { self.draft = null; self.renderActions(); }
			}, [ '放弃修改' ])
		]));
	},

	/** 改主线路：单个字段，走专门的 RPC。 */
	setPrimary: function(wan) {
		var self = this;
		call('setPrimary')({ wan: wan }).then(function(env) {
			if (env && env.ok && env.data && env.data.saved) {
				ui.addNotification(null, E('p', [ '主线路已设为 ' + wan ]), 'info');
			} else {
				ui.addNotification(null, E('p', [
					'设置失败：' + ((env && env.error && env.error.message) || '未变更')
				]), 'error');
			}
			smartmwan.refresh(self, ROOT);
		}).catch(function(e) {
			ui.addNotification(null, E('p', [ 'RPC 失败：' + e ]), 'error');
		});
	},

	/** 备用顺序：把某条线路放到第 n 位，其余按现有相对顺序重排。 */
	reorder: function(wan, pos) {
		var self = this;
		var cur = (this.base.global.backup_order || []).slice();
		var without = cur.filter(function(n) { return n !== wan; });
		if (!pos || isNaN(pos))
			return;                     /* 留空 = 移出备用列表 */
		without.splice(Math.max(0, Math.min(pos - 1, without.length)), 0, wan);
		call('setBackupOrder')({ order: without }).then(function(env) {
			if (env && env.ok && env.data && env.data.saved)
				ui.addNotification(null, E('p', [ '备用顺序已更新：' + without.join(' → ') ]), 'info');
			else
				ui.addNotification(null, E('p', [
					'设置失败：' + ((env && env.error && env.error.message) || '未变更')
				]), 'error');
			smartmwan.refresh(self, ROOT);
		}).catch(function(e) {
			ui.addNotification(null, E('p', [ 'RPC 失败：' + e ]), 'error');
		});
	},

	/* ---------- 写操作 ---------- */

	handleFailback: function() {
		var self = this;
		call('failback')({}).then(function(env) {
			if (!env || !env.ok) {
				ui.addNotification(null, E('p', [
					'回切失败：' + ((env && env.error && env.error.message) || '未知错误')
				]), 'error');
				return;
			}
			var d = env.data || {};
			if (d.switched)
				ui.addNotification(null, E('p', [ '已回切到主线路 ' + d.primary ]), 'info');
			else
				/* 没切也要说清楚为什么 —— 否则用户只看到按钮没反应。 */
				ui.addNotification(null, E('p', [
					'未回切：' + (d.reason || '主线路当前不可用作活动线路')
				]), 'warning');
			smartmwan.refresh(self, ROOT);
		}).catch(function(e) {
			ui.addNotification(null, E('p', [ 'RPC 失败：' + e ]), 'error');
		});
	},

	handleForce: function(wan) {
		var self = this;
		if (!confirm('确认把全部普通流量强制切换到 ' + wan + ' ？'))
			return;
		call('forceWan')({ wan: wan, confirm: true }).then(function(env) {
			if (env && env.ok)
				ui.addNotification(null, E('p', [
					'已提交强制切换（事务 ' + (env.data && env.data.id) + '）'
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

	handleRelease: function() {
		var self = this;
		call('releaseForced')({}).then(function(env) {
			if (env && env.ok)
				ui.addNotification(null, E('p', [ '已取消强制，回到自动决策' ]), 'info');
			else
				ui.addNotification(null, E('p', [
					'操作失败：' + ((env && env.error && env.error.message) || '未知错误')
				]), 'error');
			smartmwan.refresh(self, ROOT);
		}).catch(function(e) {
			ui.addNotification(null, E('p', [ 'RPC 失败：' + e ]), 'error');
		});
	},

	saveConfig: function(applyAfter) {
		var self = this;
		var cfg = this.draft || this.base;
		call('save')({ config: cfg }).then(function(env) {
			if (!env || !env.ok) {
				ui.addNotification(null, E('p', [
					'保存失败：' + ((env && env.error && env.error.message) || '未知错误')
				]), 'error');
				return null;
			}
			ui.addNotification(null, E('p', [
				'已写盘（' + ((env.data && env.data.changes) || []).length + ' 项变更）'
			]), 'info');
			self.draft = null;
			self.base = cfg;
			self.renderActions();
			return applyAfter ? call('apply')() : null;
		}).then(function(env) {
			if (env == null)
				return;
			var r = env.data || {};
			ui.addNotification(null, E('p', [
				'事务 ' + r.id + '：' + (r.ok ? (r.changed ? '已提交' : '无变更（幂等复核通过）') : '未提交')
			]), env.ok ? 'info' : 'error');
			smartmwan.refresh(self, ROOT);
		}).catch(function(e) {
			ui.addNotification(null, E('p', [ 'RPC 失败：' + e ]), 'error');
		});
	},

	errorBox: function(msg) {
		return 'failover', E('div', { 'id': ROOT, 'class': 'smw-state smw-state-error alert-message warning' }, [
			E('strong', {}, [ 'RPC 失败：' ]),
			E('span', {}, [ msg || '无法读取主备状态' ])
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
