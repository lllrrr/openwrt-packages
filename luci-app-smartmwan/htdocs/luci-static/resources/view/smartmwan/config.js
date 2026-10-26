'use strict';
/*
 * smartmwan —— 系统设置视图（零 Lua）
 * 数据源：smartmwan.getConfig / diff / diagnostics / getLogs；
 * 写操作：save（+ apply）、reload、rollback、probeNow、validate。
 *
 * save 与 apply 严格分离：save 只写盘并返回差异；apply 才走守护进程的一次完整事务。
 * 「应用前变更摘要」由后端 diff 给出，界面不自行拼装。
 */
'require smartmwan';
'require view';
'require rpc';
'require ui';

var ROOT = 'smw-config-root';

var LOG_LEVELS = [
	{ value: 'error', label: 'error（仅错误）' },
	{ value: 'warn', label: 'warn（警告及以上）' },
	{ value: 'info', label: 'info（常规，默认）' },
	{ value: 'debug', label: 'debug（含探测细节）' },
	{ value: 'trace', label: 'trace（最细，短时排障用）' }
];

function call(method) {
	return rpc.declare({ object: 'smartmwan', method: method });
}

return view.extend({
	draft: null,

	load: function() {
		return Promise.all([
			call('getConfig')(),
			call('diff')(),
			call('diagnostics')()
		]).then(function(rv) {
			return { config: rv[0], diff: rv[1], diag: rv[2] };
		}).catch(function(e) {
			return { __error: String(e && e.message || e) };
		});
	},

	render: function(data) {
		var smw = smartmwan;
		if (data == null || data.__error != null)
			return 'config', this.errorBox(data && data.__error);

		var cfg = smw.parse(data.config);
		if (cfg.state != 'ready')
			return E('div', { 'id': ROOT }, smw.states(cfg, { loadingText: '正在读取配置…' }));

		this.base = cfg.data.config;
		var self = this;
		var g = this.base.global;
		var h = this.base.global.health || {};
		var diff = data.diff || {};
		var root = E('div', { 'id': ROOT, 'class': 'smw-panel' }, [
			E('h2', {}, [ '系统设置' ])
		]);

		/* —— 服务开关 —— */
		/* 启用意味着插件开始接管流量，这是本插件风险最高的一次变更，
		 * 因此单独成卡、单独按钮，并写清后果。 */
		root.appendChild(smw.section('服务状态', [
			smw.kv([
				[ '当前', g.enabled ? '已启用（接管流量）' : '已停用（不改变现有路由）' ],
				[ 'schema 版本', 'v' + cfg.data.schema_version ],
				[ '已应用快照', cfg.data.applied ? ('事务 ' + cfg.data.applied.transaction) : '从未应用' ],
				[ '线路数', String(this.base.wans.length) ],
				[ '游戏规则数', String(this.base.games.length) ]
			]),
			E('div', { 'class': 'smw-actions' }, [
				E('button', {
					'class': 'btn cbi-button ' + (g.enabled ? 'cbi-button-reset' : 'cbi-button-apply important'),
					'click': ui.createHandlerFn(this, 'toggleService')
				}, [ g.enabled ? '停用服务（清空内核对象并交还路由）' : '启用服务（开始接管流量）' ])
			])
		]));

		/* —— 健康检测 —— */
		root.appendChild(smw.section('健康检测', [
			E('div', { 'class': 'smw-form' }, [
				smw.field('探测周期（毫秒）',
					smw.number(h.interval_ms, { min: 100, max: 600000, step: 100 }, function(v) {
						self.stage(function(d) { d.global.health.interval_ms = parseInt(v, 10); });
					}),
					'太短会给线路与 CPU 增加负担，太长则故障发现不及时。'),
				smw.field('单次超时（毫秒）',
					smw.number(h.timeout_ms, { min: 10, max: 60000, step: 10 }, function(v) {
						self.stage(function(d) { d.global.health.timeout_ms = parseInt(v, 10); });
					}),
					'必须小于探测周期，否则每轮都会被上一轮拖住。'),
				smw.field('连续失败阈值',
					smw.number(h.failure_threshold, { min: 1, max: 100 }, function(v) {
						self.stage(function(d) { d.global.health.failure_threshold = parseInt(v, 10); });
					}),
					'连续失败这么多次才判定线路故障。'),
				smw.field('恢复预热（毫秒）',
					smw.number(h.warmup_ms, { min: 0, max: 600000, step: 1000 }, function(v) {
						self.stage(function(d) { d.global.health.warmup_ms = parseInt(v, 10); });
					}),
					'恢复后先观察这么久再承载流量，避免刚恢复的线路被立刻压垮。'),
				smw.field('日志等级',
					smw.select(LOG_LEVELS, g.log_level, function(v) {
						self.stage(function(d) { d.global.log_level = v; });
					}),
					'debug/trace 会显著增加日志量，排障结束后请调回 info。')
			])
		]));

		/* —— 待下发变更（后端 diff 原样展示） —— */
		var changes = (diff.ok && diff.data && diff.data.changes) || [];
		root.appendChild(smw.section('待下发变更', changes.length ? [
			E('ul', { 'class': 'smw-notes' },
				changes.map(function(c) {
					return E('li', {}, [
						c.path + '：' + c.old + ' → ' + c.new +
						(c.risky ? '（高风险，需二次确认）' : '')
					]);
				})),
			E('div', { 'class': 'smw-actions' }, [
				E('button', {
					'class': 'btn cbi-button cbi-button-apply important',
					'click': ui.createHandlerFn(this, 'handleApply')
				}, [ '应用变更（一次完整事务）' ])
			])
		] : [
			E('p', { 'class': 'smw-muted' }, [
				(diff.data && diff.data.note) || '当前保存的配置与上次成功应用一致'
			])
		]));

		/* —— 诊断：只读聚合，帮助排障时不必挨个页面点 —— */
		var diag = smw.parse(data.diag);
		if (diag.state == 'ready') {
			var d = diag.data;
			root.appendChild(smw.section('诊断', [
				smw.kv([
					[ '协议 / schema', 'v' + d.protocol + ' / v' + d.schema_version ],
					[ '运行时间', d.uptime_ms ? smartmwan.ms(d.uptime_ms) : '—' ],
					[ 'nft 通道', d.firewall_channel || '—' ],
					[ '配置校验', d.config_valid ? '通过' : '存在致命问题' ],
					[ 'conntrack', d.conntrack
						? (d.conntrack.count + ' / ' + d.conntrack.max +
							'（' + (d.conntrack.used_permille / 10).toFixed(1) + '%）' +
							(d.conntrack.tight ? '，接近上限' : ''))
						: '未取到'],
					[ '域名集合', d.dns
						? (d.dns.domains + ' 个域名 / ' + d.dns.elements + ' 个元素' +
							(d.dns.stale_domains ? '，' + d.dns.stale_domains + ' 个陈旧' : ''))
						: '—' ]
				]),
				(d.errors && d.errors.length)
					? E('div', { 'class': 'alert-message warning' }, [
						E('strong', {}, [ '配置问题：' ]),
						E('ul', {}, d.errors.map(function(i) {
							return E('li', {}, [ i.path + '：' + i.message ]);
						}))
					]) : '',
				(d.warnings && d.warnings.length)
					? E('div', { 'class': 'smw-block' }, [
						E('h4', {}, [ '告警' ]),
						E('ul', { 'class': 'smw-notes' }, d.warnings.map(function(i) {
							return E('li', {}, [ i.path + '：' + i.message ]);
						}))
					]) : '',
				(d.capabilities_degraded && d.capabilities_degraded.length)
					? E('div', { 'class': 'smw-block' }, [
						E('h4', {}, [ '本机语法降级' ]),
						E('ul', { 'class': 'smw-notes' }, d.capabilities_degraded.map(function(x) {
							return E('li', {}, [ x ]);
						}))
					]) : ''
			]));
		}

		/* —— 配置导入 / 导出 —— */
		var io = E('textarea', {
			'class': 'cbi-input-textarea',
			'style': 'width:100%;min-height:9em;font-family:monospace;font-size:0.85em',
			'readonly': 'readonly'
		}, [ JSON.stringify(this.base, null, 2) ]);
		root.appendChild(smw.section('导出 / 导入', [
			E('p', { 'class': 'smw-muted' }, [
				'下面是当前保存的完整配置（JSON）。可复制存档，或把修改后的内容粘回上面的框里再点「校验并保存」。',
				'导入会**整份替换**当前配置，请先导出留底。'
			]),
			io,
			E('div', { 'class': 'smw-actions' }, [
				E('button', {
					'class': 'btn cbi-button',
					'click': function() {
						io.removeAttribute('readonly');
						io.focus();
					}
				}, [ '解锁编辑' ]),
				E('button', {
					'class': 'btn cbi-button cbi-button-apply',
					'click': ui.createHandlerFn(this, 'handleImport', io)
				}, [ '校验并保存' ])
			])
		]));

		/* —— 操作区 —— */
		root.appendChild(smw.section('操作', [
			E('div', { 'class': 'smw-actions' }, [
				E('button', {
					'class': 'btn cbi-button',
					'click': ui.createHandlerFn(this, 'handleReload')
				}, [ '重新读取配置' ]),
				E('button', {
					'class': 'btn cbi-button',
					'click': ui.createHandlerFn(this, 'handleProbe')
				}, [ '立即探测一轮' ]),
				E('button', {
					'class': 'btn cbi-button cbi-button-reset',
					'click': ui.createHandlerFn(this, 'handleRollback')
				}, [ '回滚到 last-good 并重新下发' ])
			]),
			E('p', { 'class': 'smw-muted' }, [
				'「保存」与「应用」分离：确认变更摘要无误再应用。',
				'回滚会写回 last-good 快照并重新下发。'
			])
		]));

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
		this.slot.appendChild(smartmwan.dirty('有未保存的修改（保存后仍需「应用」才会下发到内核）', [
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

	/* ---------- 写操作 ---------- */

	/** 启停服务：单独走一次保存 + 应用，并如实说明后果。 */
	toggleService: function() {
		var self = this;
		var on = !this.base.global.enabled;
		if (on && !confirm('启用后本插件将接管分流（写入策略路由与 nft 规则）。确认启用？'))
			return;
		if (!on && !confirm('停用后本插件会清空自己的内核对象，流量交还系统原路由。确认停用？'))
			return;
		var cfg = JSON.parse(JSON.stringify(this.base));
		cfg.global.enabled = on;
		call('save')({ config: cfg }).then(function(env) {
			if (!env || !env.ok) {
				ui.addNotification(null, E('p', [
					'保存失败：' + ((env && env.error && env.error.message) || '未知错误')
				]), 'error');
				return null;
			}
			return call('apply')();
		}).then(function(env) {
			if (env == null)
				return;
			var r = env.data || {};
			ui.addNotification(null, E('p', [
				(on ? '已启用' : '已停用') + '：事务 ' + r.id + '（' +
				(r.ok ? (r.changed ? '已提交' : '无变更') : '未提交') + '）'
			]), env.ok && r.ok ? 'info' : 'error');
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

	/** 导入：先交给后端校验，通过才写盘。界面不自己判断配置好不好。 */
	handleImport: function(box) {
		var self = this;
		var text = box.value;
		var parsed;
		try {
			parsed = JSON.parse(text);
		} catch (e) {
			ui.addNotification(null, E('p', [ '不是合法 JSON：' + e ]), 'error');
			return;
		}
		call('validate')({ config: parsed }).then(function(env) {
			if (!env || !env.ok) {
				ui.addNotification(null, E('p', [
					'校验失败：' + ((env && env.error && env.error.message) || '未知错误')
				]), 'error');
				return null;
			}
			var rep = env.data || {};
			if (!rep.valid) {
				ui.addNotification(null, E('p', [
					'配置校验不通过，未写入：',
					E('ul', {}, (rep.issues || []).map(function(i) {
						return E('li', {}, [ i.path + '：' + i.message ]);
					}))
				]), 'error');
				return null;
			}
			return call('save')({ config: parsed });
		}).then(function(env) {
			if (env == null)
				return;
			ui.addNotification(null, E('p', [
				'导入已写盘（' + ((env.data && env.data.changes) || []).length + ' 项变更）。',
				'确认无误后回到「待下发变更」点应用。'
			]), 'info');
			smartmwan.refresh(self, ROOT);
		}).catch(function(e) {
			ui.addNotification(null, E('p', [ 'RPC 失败：' + e ]), 'error');
		});
	},

	handleApply: function() {
		var self = this;
		if (!confirm('将执行一次完整事务（策略路由 + nft 提交）。确认应用？'))
			return;
		call('apply')({}).then(function(env) {
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
			smartmwan.refresh(self, ROOT);
		}).catch(function(e) {
			ui.addNotification(null, E('p', [ 'RPC 失败：' + e ]), 'error');
		});
	},

	handleRollback: function() {
		var self = this;
		if (!confirm('将回滚到上一次成功应用的快照并重新下发。确认？'))
			return;
		call('rollback')({}).then(function(env) {
			if (env && env.ok)
				ui.addNotification(null, E('p', [ '已回滚到 last-good 并重新下发' ]), 'info');
			else
				ui.addNotification(null, E('p', [
					'回滚失败：' + ((env && env.error && env.error.message) || '未知错误')
				]), 'error');
			smartmwan.refresh(self, ROOT);
		}).catch(function(e) {
			ui.addNotification(null, E('p', [ 'RPC 失败：' + e ]), 'error');
		});
	},

	handleReload: function() {
		var self = this;
		call('reload')({}).then(function(env) {
			if (env && env.ok)
				ui.addNotification(null, E('p', [ (env.data && env.data.note) || '已重新读取' ]), 'info');
			else
				ui.addNotification(null, E('p', [
					'重载失败：' + ((env && env.error && env.error.message) || '未知错误')
				]), 'error');
			smartmwan.refresh(self, ROOT);
		}).catch(function(e) {
			ui.addNotification(null, E('p', [ 'RPC 失败：' + e ]), 'error');
		});
	},

	/** 立即探测一轮。这是唯一会真的发探测包的入口，因此单独成按钮。 */
	handleProbe: function() {
		var self = this;
		call('probeNow')({}).then(function(env) {
			if (env && env.ok) {
				var d = env.data || {};
				ui.addNotification(null, E('p', [
					'探测完成：计划 ' + d.planned + '，完成 ' + d.completed +
					'，无效 ' + d.ignored + '，状态迁移 ' + d.transitions
				]), 'info');
			} else {
				ui.addNotification(null, E('p', [
					'探测失败：' + ((env && env.error && env.error.message) || '未知错误')
				]), 'error');
			}
			smartmwan.refresh(self, ROOT);
		}).catch(function(e) {
			ui.addNotification(null, E('p', [ 'RPC 失败：' + e ]), 'error');
		});
	},

	errorBox: function(msg) {
		return 'config', E('div', { 'id': ROOT, 'class': 'smw-state smw-state-error alert-message warning' }, [
			E('strong', {}, [ 'RPC 失败：' ]),
			E('span', {}, [ msg || '无法读取配置' ])
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
