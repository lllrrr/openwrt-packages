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

/* 表单控件统一走组件系统（label 关联、失焦校验、错误行都在 Form 里）。 */
var Form = smartmwan.ui.Form;
var smw = smartmwan;

/* 浮层里的菜单项：role=menuitem + 键盘可达（button 天然可聚焦）。 */
function menuItem(label, onClick, danger) {
	return E('button', {
		'type': 'button',
		'class': 'smw-menu-item' + (danger ? ' smw-menu-item-danger' : ''),
		'role': 'menuitem',
		'click': onClick
	}, [ label ]);
}

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
				smartmwan.button(
					g.enabled ? '停用服务（清空内核对象并交还路由）' : '启用服务（开始接管流量）',
					{
						variant: g.enabled ? 'danger' : 'filled',
						click: ui.createHandlerFn(this, 'toggleService')
					})
			])
		]));

		/* —— 健康检测 —— */
		/* 每个字段都带「取值范围」校验：后端仍会校验，这里只是让填错当场可见，
		 * 不必等一次保存往返才知道。 */
		var healthFields = [
			Form.field({
				label: '探测周期（毫秒）',
				required: true,
				control: Form.number({
					value: h.interval_ms, min: 100, max: 600000, step: 100,
					onchange: function(v) {
						self.stage(function(d) { d.global.health.interval_ms = parseInt(v, 10); });
					}
				}),
				help: '太短会给线路与 CPU 增加负担，太长则故障发现不及时。',
				validate: Form.validators.intBetween(100, 600000)
			}),
			Form.field({
				label: '单次超时（毫秒）',
				required: true,
				control: Form.number({
					value: h.timeout_ms, min: 10, max: 60000, step: 10,
					onchange: function(v) {
						self.stage(function(d) { d.global.health.timeout_ms = parseInt(v, 10); });
					}
				}),
				help: '必须小于探测周期，否则每轮都会被上一轮拖住。',
				validate: Form.validators.intBetween(10, 60000)
			}),
			Form.field({
				label: '连续失败阈值',
				required: true,
				control: Form.number({
					value: h.failure_threshold, min: 1, max: 100,
					onchange: function(v) {
						self.stage(function(d) { d.global.health.failure_threshold = parseInt(v, 10); });
					}
				}),
				help: '连续失败这么多次才判定线路故障。',
				validate: Form.validators.intBetween(1, 100)
			}),
			Form.field({
				label: '恢复预热（毫秒）',
				required: true,
				control: Form.number({
					value: h.warmup_ms, min: 0, max: 600000, step: 1000,
					onchange: function(v) {
						self.stage(function(d) { d.global.health.warmup_ms = parseInt(v, 10); });
					}
				}),
				help: '恢复后先观察这么久再承载流量，避免刚恢复的线路被立刻压垮。',
				validate: Form.validators.intBetween(0, 600000)
			}),
			Form.field({
				label: '日志等级',
				control: Form.select({
					options: LOG_LEVELS, value: g.log_level,
					onchange: function(v) {
						self.stage(function(d) { d.global.log_level = v; });
					}
				}),
				help: 'debug/trace 会显著增加日志量，排障结束后请调回 info。'
			})
		];
		this.fields = healthFields;
		root.appendChild(smw.section('健康检测', [
			E('div', { 'class': 'smw-form' }, healthFields.map(function(f) { return f.el; }))
		]));

		/* —— 待下发变更（后端 diff 原样展示） —— */
		var changes = (diff.ok && diff.data && diff.data.changes) || [];
		function changeNode(c) {
			return E('li', {}, [
				E('code', {}, [ c.path ]), '：' + c.old + ' → ' + c.new,
				c.risky ? E('span', { 'class': 'smw-warn' }, [ '（高风险）' ]) : ''
			]);
		}
		root.appendChild(smw.section('待下发变更', changes.length ? [
			E('ul', { 'class': 'smw-notes' }, changes.slice(0, 5).map(changeNode)),
			changes.length > 5
				? E('p', { 'class': 'smw-muted' }, [ '另有 ' + (changes.length - 5) + ' 项未列出。' ])
				: '',
			E('div', { 'class': 'smw-actions' }, [
				smartmwan.button('应用变更（一次完整事务）', {
					variant: 'filled',
					click: ui.createHandlerFn(this, 'handleApply')
				}),
				changes.length > 5
					? smartmwan.button('查看全部 ' + changes.length + ' 项', {
						variant: 'text',
						click: function() { self.showChanges(changes, changeNode); }
					})
					: ''
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
					? E('div', { 'class': 'smw-notice smw-notice-bad' }, [
						E('strong', {}, [ '配置问题：' ]),
						E('ul', { 'class': 'smw-notes' }, d.errors.map(function(i) {
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
		/* 放在 Drawer 里而不是内联 textarea：整份 JSON 有几十行，挤在页面里
		 * 会把下面的操作区推走；抽屉有固定底部栏与「未保存」保护，更适合长文编辑。 */
		root.appendChild(smw.section('配置备份', [
			E('p', { 'class': 'smw-muted' }, [
				'在右侧抽屉里查看或编辑整份配置（JSON）。导入会先交给后端校验，',
				'校验不通过不会写入任何内容。'
			]),
			E('div', { 'class': 'smw-actions' }, [
				smartmwan.button('打开配置编辑器', {
					variant: 'tonal',
					click: ui.createHandlerFn(this, 'handleConfigEditor')
				})
			])
		]));

		/* —— 操作区 —— */
		/* 低频与危险操作收进「更多操作」浮层：主界面只留一个入口，
		 * 避免「回滚」和「保存」并排摆着被误点。 */
		var moreBtn = smartmwan.button('更多操作', { variant: 'outlined' });
		moreBtn.addEventListener('click', function(ev) {
			ev.preventDefault();
			if (self._morePop != null) { self._morePop.close('toggle'); self._morePop = null; return; }
			self._morePop = smw.ui.Popover.open(moreBtn, {
				placement: 'bottom-end',
				content: E('div', { 'role': 'menu', 'class': 'smw-menu' }, [
					menuItem('重新读取配置（不改内核）', function() {
						self._morePop.close('action');
						self.handleReload();
					}),
					menuItem('立即探测一轮', function() {
						self._morePop.close('action');
						self.handleProbe();
					}),
					menuItem('回滚到 last-good 并重新下发', function() {
						self._morePop.close('action');
						self.handleRollback();
					}, true)
				]),
				onClose: function() { self._morePop = null; }
			});
		});

		root.appendChild(smw.section('操作', [
			E('div', { 'class': 'smw-actions' }, [
				smartmwan.button('重新读取配置', {
					variant: 'text',
					click: ui.createHandlerFn(this, 'handleReload')
				}),
				moreBtn
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
			smartmwan.button('保存', {
				variant: 'text',
				click: ui.createHandlerFn(self, 'saveConfig', false)
			}),
			smartmwan.button('保存并应用', {
				variant: 'filled',
				click: ui.createHandlerFn(self, 'saveConfig', true)
			}),
			smartmwan.button('放弃修改', {
				variant: 'outlined',
				click: function() { self.draft = null; self.renderActions(); }
			})
		]));
	},

	/* ---------- 写操作 ---------- */

	/** 启停服务：单独走一次保存 + 应用，并如实说明后果。 */
	toggleService: function() {
		var self = this;
		var on = !this.base.global.enabled;
		var p;
		if (on) {
			p = smartmwan.confirm({
				title: '启用服务',
				message: '启用后本插件将接管分流（写入策略路由与 nft 规则）。确认启用？',
				details: [
					'会写入本插件自己的策略路由规则与 nft 链，不影响其他规则。',
					'「待下发变更」里有未应用的改动时，会一并提交。'
				],
				confirmText: '确认启用'
			});
		} else {
			p = smartmwan.confirm({
				title: '停用服务',
				message: '停用后本插件会清空自己的内核对象，流量交还系统原路由。确认停用？',
				details: [
					'本插件创建的路由表、nft 链与标记会被清空。',
					'已建立的连接按 conntrack 继续走，新连接走系统原路由。'
				],
				confirmText: '确认停用',
				danger: true
			});
		}
		p.then(function(ok) {
			if (!ok)
				return null;
			var cfg = JSON.parse(JSON.stringify(self.base));
			cfg.global.enabled = on;
			return call('save')({ config: cfg }).then(function(env) {
				if (!env || !env.ok)
					throw new Error((env && env.error && env.error.message) || '未知错误');
				return call('apply')();
			});
		}).then(function(env) {
			if (env == null)
				return;
			var r = env.data || {};
			smartmwan.notify(E('p', [
				(on ? '已启用' : '已停用') + '：事务 ' + r.id + '（' +
				(r.ok ? (r.changed ? '已提交' : '无变更') : '未提交') + '）'
			]), env.ok && r.ok ? 'info' : 'error');
			smartmwan.refresh(self, ROOT);
		}).catch(function(e) {
			smartmwan.notify(E('p', [ 'RPC 失败：' + e ]), 'error');
		});
	},

	saveConfig: function(applyAfter) {
		var self = this;
		/* 表单级校验：有非法字段就不发 RPC —— 让用户先修字段，
		 * 而不是拿一份注定被后端拒绝的配置往返一次。 */
		var check = Form.validate(this.fields);
		if (!check.ok) {
			smartmwan.notify(E('p', [ '有字段填写不合法，请先修正标红的输入框。' ]), 'warning');
			return;
		}
		var cfg = this.draft || this.base;
		call('save')({ config: cfg }).then(function(env) {
			if (!env || !env.ok) {
				smartmwan.notify(E('p', [
					'保存失败：' + ((env && env.error && env.error.message) || '未知错误')
				]), 'error');
				return null;
			}
			smartmwan.notify(E('p', [
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
			smartmwan.notify(E('p', [
				'事务 ' + r.id + '：' + (r.ok ? (r.changed ? '已提交' : '无变更（幂等复核通过）') : '未提交')
			]), env.ok ? 'info' : 'error');
			smartmwan.refresh(self, ROOT);
		}).catch(function(e) {
			smartmwan.notify(E('p', [ 'RPC 失败：' + e ]), 'error');
		});
	},

	/** 完整变更列表：宽屏 Dialog。diff 原样展示，界面不重排、不改写。 */
	showChanges: function(changes, changeNode) {
		smw.ui.Dialog.open({
			title: '待下发变更（' + changes.length + ' 项）',
			description: '后端 diff 的原样输出。高风险项在应用时需要二次确认。',
			size: 'lg',
			body: E('ul', { 'class': 'smw-notes' }, changes.map(changeNode)),
			actions: [ { label: '关闭', variant: 'text', value: null } ]
		});
	},

	/**
	 * 配置编辑器（Drawer）：整份 JSON 的查看与编辑。
	 * 关闭时若有未保存改动会先确认；保存走 validate → save 两步，
	 * 后端校验不通过就不写盘（界面不自己判断配置好不好）。
	 */
	handleConfigEditor: function() {
		var self = this;
		var original = JSON.stringify(this.base, null, 2);
		var dirty = false;

		var ta = E('textarea', {
			'class': 'smw-textarea',
			'rows': '22',
			'spellcheck': 'false',
			'aria-label': '完整配置 JSON'
		}, [ original ]);
		ta.addEventListener('input', function() {
			dirty = ta.value !== original;
		});

		smw.ui.Drawer.open({
			title: '配置编辑器',
			description: '整份配置（JSON）。导出＝复制；导入＝修改后点「校验并保存」。',
			width: 560,
			body: [
				E('p', { 'class': 'smw-muted' }, [
					'导入会整份替换当前配置，建议先复制一份留底。',
					'保存只写盘，仍需回到页面点「应用变更」才会下发到内核。'
				]),
				ta
			],
			/* 未保存检测：有改动时关闭会先弹确认，避免手一滑丢掉整份 JSON。 */
			beforeClose: function() {
				return dirty ? '编辑器里有未保存的改动，关闭后会丢失。' : true;
			},
			actions: [
				{
					label: '关闭',
					variant: 'text',
					onClick: function(ctl) {
						ctl.requestClose(null, 'button');
						return false;   /* 关闭由 requestClose 走守卫，这里不重复关 */
					}
				},
				{
					label: '校验并保存',
					variant: 'filled',
					loadingText: '校验中…',
					onClick: function() {
						return self.importJson(ta.value);
					}
				}
			]
		});
	},

	/** 导入：先交给后端校验，通过才写盘。失败抛错，由 Drawer 就地显示并允许重试。 */
	importJson: function(text) {
		var self = this;
		var parsed;
		try {
			parsed = JSON.parse(text);
		} catch (e) {
			throw new Error('不是合法 JSON：' + (e && e.message ? e.message : e));
		}

		return call('validate')({ config: parsed }).then(function(env) {
			if (!env || !env.ok)
				throw new Error('校验请求失败：' + ((env && env.error && env.error.message) || '未知错误'));
			var rep = env.data || {};
			if (!rep.valid) {
				var issues = rep.issues || [];
				var first = issues.length ? (issues[0].path + '：' + issues[0].message) : '未知问题';
				throw new Error('配置校验不通过（' + issues.length + ' 项），未写入。首个问题：' + first);
			}
			return call('save')({ config: parsed });
		}).then(function(env) {
			if (!env || !env.ok)
				throw new Error('保存失败：' + ((env && env.error && env.error.message) || '未知错误'));
			var n = ((env.data && env.data.changes) || []).length;
			smartmwan.notify(E('p', [
				'导入已写盘（' + n + ' 项变更）。确认无误后到「待下发变更」点应用。'
			]), 'success');
			smartmwan.refresh(self, ROOT);
		});
	},

	handleApply: function() {
		var self = this;
		smartmwan.confirm({
			title: '应用变更',
			message: '将执行一次完整事务（策略路由 + nft 提交）。确认应用？',
			details: [
				'事务分八阶段推进，任一阶段失败会回滚已写入的内核对象。',
				'无实际差异时后端会走幂等复核，不下发任何规则。'
			],
			confirmText: '确认应用'
		}).then(function(ok) {
			if (!ok)
				return;
			/* 事务要跑多个阶段，用「进行中 → 完成/失败」的持续反馈，
			 * 而不是一个不知道进行到哪的静默等待。 */
			var task = smw.ui.Toast.progress({ message: '正在提交事务…', key: 'txn-apply' });
			call('apply')({}).then(function(env) {
				if (env && env.ok) {
					var r = env.data || {};
					task.done('事务 ' + r.id + '：' +
						(r.ok ? (r.changed ? '已提交' : '无变更（幂等复核通过）') : '未提交'));
				} else {
					task.fail('应用失败：' +
						((env && env.error && env.error.message) || '未知错误'));
				}
				smartmwan.refresh(self, ROOT);
			}).catch(function(e) {
				task.fail('RPC 失败：' + e);
			});
		});
	},

	handleRollback: function() {
		var self = this;
		smartmwan.confirm({
			title: '回滚到 last-good',
			message: '将回滚到上一次成功应用的快照并重新下发。确认？',
			details: [
				'当前已保存但未应用的改动会被丢弃。',
				'回滚同样走一次完整事务，失败时会自行回退。'
			],
			confirmText: '确认回滚',
			danger: true
		}).then(function(ok) {
			if (!ok)
				return;
			var task = smw.ui.Toast.progress({ message: '正在回滚并重新下发…', key: 'txn-rollback' });
			call('rollback')({}).then(function(env) {
				if (env && env.ok)
					task.done('已回滚到 last-good 并重新下发');
				else
					task.fail('回滚失败：' + ((env && env.error && env.error.message) || '未知错误'));
				smartmwan.refresh(self, ROOT);
			}).catch(function(e) {
				task.fail('RPC 失败：' + e);
			});
		});
	},

	handleReload: function() {
		var self = this;
		call('reload')({}).then(function(env) {
			if (env && env.ok)
				smartmwan.notify(E('p', [ (env.data && env.data.note) || '已重新读取' ]), 'info');
			else
				smartmwan.notify(E('p', [
					'重载失败：' + ((env && env.error && env.error.message) || '未知错误')
				]), 'error');
			smartmwan.refresh(self, ROOT);
		}).catch(function(e) {
			smartmwan.notify(E('p', [ 'RPC 失败：' + e ]), 'error');
		});
	},

	/** 立即探测一轮。这是唯一会真的发探测包的入口，因此单独成按钮。 */
	handleProbe: function() {
		var self = this;
		call('probeNow')({}).then(function(env) {
			if (env && env.ok) {
				var d = env.data || {};
				smartmwan.notify(E('p', [
					'探测完成：计划 ' + d.planned + '，完成 ' + d.completed +
					'，无效 ' + d.ignored + '，状态迁移 ' + d.transitions
				]), 'info');
			} else {
				smartmwan.notify(E('p', [
					'探测失败：' + ((env && env.error && env.error.message) || '未知错误')
				]), 'error');
			}
			smartmwan.refresh(self, ROOT);
		}).catch(function(e) {
			smartmwan.notify(E('p', [ 'RPC 失败：' + e ]), 'error');
		});
	},

	errorBox: function(msg) {
		return 'config', E('div', { 'id': ROOT, 'class': 'smw-state smw-state-error' }, [
			E('strong', {}, [ 'RPC 失败：' ]),
			E('span', {}, [ msg || '无法读取配置' ])
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
