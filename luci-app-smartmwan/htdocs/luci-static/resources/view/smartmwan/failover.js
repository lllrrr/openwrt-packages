'use strict';
/*
 * smartmwan —— 主备切换视图（零 Lua）
 * 数据源：smartmwan.getFailover / getConfig；
 * 写操作：setPrimary / setBackupOrder / failback / save（+ apply）。
 *
 * 强制切换有二次确认（Modal Bottom Sheet，与后端 require_confirm 语义一致）。
 * 「手动回切」是即时动作：主线路此刻不够格就如实不切，
 * 与「强制切换」（持久意志，目标恢复后自动生效）不是一回事。
 */
'require smartmwan';
'require view';
'require rpc';
'require ui';
'require fs';

var ROOT = 'smw-failover-root';

var Form = smartmwan.ui.Form;

var FAILBACKS = [
	{ value: 'auto', label: '自动回切（满足延迟与连续成功条件后切回主线路）' },
	{ value: 'manual', label: '手动回切（主线路恢复后仍保持备用，需人工确认）' }
];

function call(method, params) {
	/* params 必须作为模板声明：本机 LuCI 的 rpc.declare 只把模板里
	 * 出现的键装进请求，缺了模板实参会被整个丢弃（真机实测）。 */
	return rpc.declare({ object: 'smartmwan', method: method, params: params, reject: true });
}

/* 兼容旧版共享模块缓存:errText 缺失时退化为原始消息,页面不因混缓存崩溃 */
var errText = smartmwan.errText || function(e) { return String(e && e.message || e); };
return view.extend({
	draft: null,

	load: function() {
		return Promise.all([
			call('getFailover')(),
			call('getConfig')(),
			/* 网口清单：fs.list 走 rpcd-mod-file（luci-base ACL 必授），
			 * 不走 network.getDevices —— 后者依赖的 network ubus 方法在本机
			 * ACL 未授，且 initNetworkState 会记忆化失败状态。 */
			fs.list('/sys/class/net')
		]).then(function(rv) {
			return {
				failover: rv[0],
				config: rv[1],
				/* 系统当前已知网口（去掉回环）：供线路手动绑定设备用。 */
				devices: (rv[2] || []).filter(function(e) { return e.type !== 'file'; })
					.map(function(e) { return e.name; })
					.filter(function(n) { return n && n !== 'lo'; })
			};
		}).catch(function(e) {
			return { __error: errText(e) };
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
					Form.field({
						label: '主线路',
						control: Form.select({
							options: wans.map(function(w) {
								return {
									value: w.name,
									label: w.name + (w.enabled ? '' : '（已停用）')
								};
							}),
							value: g.primary,
							onchange: function(v) { self.setPrimary(v); }
						}),
						help: '改动立即写盘并触发一轮事务；已排进备用列表的线路不能当主线路。'
					}).el
				])
			]));

			/* 备用顺序：顺位下拉预设（不参与备用 / 第 N 顺位），不让用户填数字。
			 * 改选即时写盘（setBackupOrder），其余线路自动顺延并重绘。 */
			/* 候选排除主线路：global.primary 未显式设置时，以线路 role=primary
			 * 为准 —— 否则主线路会混进备用顺位里。 */
			var backupCandidates = wans.filter(function(w) {
				return w.name !== g.primary && w.role !== 'primary';
			});
			var maxPos = backupCandidates.length;
			var orderFields = backupCandidates.map(function(w) {
				var idx = g.backup_order.indexOf(w.name);
				return Form.field({
					label: w.name + ' 备用顺位',
					control: Form.select({
						options: [ { value: '', label: '不参与备用' } ].concat(
							Array.apply(null, { length: maxPos }).map(function(_, i) {
								return { value: String(i + 1), label: '第 ' + (i + 1) + ' 顺位' };
							})
						),
						value: idx < 0 ? '' : String(idx + 1),
						onchange: function(v) {
							self.reorder(w.name, v === '' ? NaN : parseInt(v, 10));
						}
					}),
					help: idx < 0 ? '当前不参与备用' : '当前第 ' + (idx + 1) + ' 顺位，改选后即时生效'
				});
			});
			root.appendChild(smw.section('备用顺序', [
				E('div', { 'class': 'smw-form' }, orderFields.map(function(f) { return f.el; })),
				E('p', { 'class': 'smw-muted' }, [
					'顺位越靠前越优先接管。主线路故障时按此顺序挑第一条可用线路。'
				])
			]));

			/* 网口绑定：每条线路可手动指定网络设备；留空 = 跟随 netifd 自动识别。
			 * 模组重拨后设备名可能漂移，手动绑定保证该线路始终落在预期网口，
			 * 而不是被自动识别指到别的口上。 */
			var deviceFields = wans.map(function(w) {
				return Form.field({
					label: w.name + ' 网口',
					control: Form.select({
						options: [ { value: '', label: '自动（跟随 netifd）' } ].concat(
							(data.devices || []).map(function(d) {
								return { value: d, label: d + (d === (w.device || '') ? '（当前）' : '') };
							})
						),
						value: w.device || '',
						onchange: function(v) {
							self.stage(function(d) {
								for (var i = 0; i < d.wans.length; i++)
									if (d.wans[i].name === w.name)
										d.wans[i].device = v;
							});
						}
					}),
					help: '留空 = 跟随 netifd 自动识别；手动绑定后该线路固定使用所选网口，自动探测不再改写。'
				});
			});
			root.appendChild(smw.section('网口绑定', [
				E('div', { 'class': 'smw-form' }, deviceFields.map(function(f) { return f.el; })),
				E('p', { 'class': 'smw-muted' }, [
					'改动先进入草稿，点「保存并应用」后下发；应用后线路按新网口重新探测。'
				])
			]));

			/* 回切策略：多字段，走草稿 + save。 */
			var fbFields = [
				Form.field({
					label: '回切方式',
					control: Form.select({
						options: FAILBACKS,
						value: g.failback,
						onchange: function(v) {
							self.stage(function(d) { d.global.failback = v; });
						}
					}),
					help: '手动方式下主线路恢复也不会自动切回。'
				}),
				Form.field({
					label: '回切延迟（毫秒）',
					required: true,
					control: Form.number({
						value: g.failback_delay_ms, min: 0, max: 3600000, step: 1000,
						onchange: function(v) {
							self.stage(function(d) { d.global.failback_delay_ms = parseInt(v, 10); });
						}
					}),
					help: '主线路健康后至少稳定这么久才回切；建议 ≥30000，避免抖动来回切。',
					validate: Form.validators.intBetween(0, 3600000)
				}),
				Form.field({
					label: '连续成功次数',
					required: true,
					control: Form.number({
						value: g.failback_success_threshold, min: 1, max: 100,
						onchange: function(v) {
							self.stage(function(d) { d.global.failback_success_threshold = parseInt(v, 10); });
						}
					}),
					help: '回切前要求主线路连续探测成功的最少次数。',
					validate: Form.validators.intBetween(1, 100)
				}),
				Form.field({
					label: '最小切换间隔（毫秒）',
					required: true,
					control: Form.number({
						value: g.min_switch_interval_ms, min: 0, max: 3600000, step: 1000,
						onchange: function(v) {
							self.stage(function(d) { d.global.min_switch_interval_ms = parseInt(v, 10); });
						}
					}),
					help: '两次出口变更之间的兜底闸门，防止频繁切换。',
					validate: Form.validators.intBetween(0, 3600000)
				})
			];
			this.fields = fbFields;
			root.appendChild(smw.section('回切策略', [
				E('div', { 'class': 'smw-form' }, fbFields.map(function(f) { return f.el; }))
			]));
		}

		/* —— 操作区 —— */
		var actions = [];
		if (f.forced) {
			actions.push(smartmwan.button('取消强制，回到自动决策', {
				variant: 'outlined',
				click: ui.createHandlerFn(this, 'handleRelease')
			}));
		} else {
			/* 手动回切：即时动作，不需要二次确认 —— 它恢复的是配置里的常态，
			 * 不是把流量强制到一条用户临时指定的线路。 */
			actions.push(smartmwan.button('立即回切到主线路', {
				variant: 'filled',
				click: ui.createHandlerFn(this, 'handleFailback')
			}));
			(f.order || []).filter(function(n) { return n !== f.active; })
				.forEach(function(n) {
					actions.push(smartmwan.button('强制切换到 ' + n, {
						variant: 'tonal',
						click: ui.createHandlerFn(self, 'handleForce', n)
					}));
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

	/** 改主线路：单个字段，走专门的 RPC。 */
	setPrimary: function(wan) {
		var self = this;
		call('setPrimary', { wan: '' })({ wan: wan }).then(function(env) {
			/* 便捷设置回执形如 {change, changed, receipt}：changed 才是落盘标志。 */
			if (env && env.ok && env.data && (env.data.changed || env.data.saved)) {
				smartmwan.notify(E('p', [ '主线路已设为 ' + wan ]), 'info');
			} else {
				smartmwan.notify(E('p', [
					'设置失败：' + ((env && env.error && env.error.message) || (env && env.data && env.data.change) || '未变更')
				]), 'error');
			}
			smartmwan.refresh(self, ROOT);
		}).catch(function(e) {
			smartmwan.notify(E('p', [ 'RPC 失败：' + errText(e) ]), 'error');
		});
	},

	/** 备用顺序：把某条线路放到第 n 位；序号留空 = 移出备用列表。
	 * 两种意图都要真的下发，否则用户清空序号后列表纹丝不动。 */
	reorder: function(wan, pos) {
		var self = this;
		var cur = (this.base.global.backup_order || []).slice();
		var without = cur.filter(function(n) { return n !== wan; });
		if (pos != null && !isNaN(pos) && pos >= 1)
			without.splice(Math.max(0, Math.min(pos - 1, without.length)), 0, wan);
		if (!pos || isNaN(pos)) {
			/* 留空 = 移出备用。已经不在列表里时如实说明，不假装操作成功。 */
			if (cur.indexOf(wan) < 0) {
				smartmwan.notify(E('p', [ wan + ' 本就不在备用列表中' ]), 'info');
				return;
			}
		}
		call('setBackupOrder', { order: [] })({ order: without }).then(function(env) {
			/* 回执 {change, changed, receipt}：changed=true 表示已写盘。 */
			if (env && env.ok && env.data && (env.data.changed || env.data.saved)) {
				smartmwan.notify(E('p', [
					env.data.change || (without.length
						? '备用顺序已更新：' + without.join(' → ')
						: '备用列表已清空')
				]), 'info');
			}
			else if (env && env.ok && env.data) {
				/* ok 但 changed=false：顺序与现状一致，如实说明。 */
				smartmwan.notify(E('p', [ '顺序未变化（与当前一致）' ]), 'info');
			}
			else {
				smartmwan.notify(E('p', [
					'设置失败：' + errText(env && env.error)
				]), 'error');
			}
			smartmwan.refresh(self, ROOT);
		}).catch(function(e) {
			smartmwan.notify(E('p', [ 'RPC 失败：' + errText(e) ]), 'error');
		});
	},

	/* ---------- 写操作 ---------- */

	handleFailback: function() {
		var self = this;
		call('failback')({}).then(function(env) {
			if (!env || !env.ok) {
				smartmwan.notify(E('p', [
					'回切失败：' + ((env && env.error && env.error.message) || '未知错误')
				]), 'error');
				return;
			}
			var d = env.data || {};
			if (d.switched)
				smartmwan.notify(E('p', [ '已回切到主线路 ' + d.primary ]), 'info');
			else
				/* 没切也要说清楚为什么 —— 否则用户只看到按钮没反应。 */
				smartmwan.notify(E('p', [
					'未回切：' + (d.reason || '主线路当前不可用作活动线路')
				]), 'warning');
			smartmwan.refresh(self, ROOT);
		}).catch(function(e) {
			smartmwan.notify(E('p', [ 'RPC 失败：' + errText(e) ]), 'error');
		});
	},

	handleForce: function(wan) {
		var self = this;
		/* 强制切换会把全部普通流量挪到一条线路上，且目标暂不可用时指令会保留
		 * 并在恢复后自动生效 —— 后果必须写进确认面板，不能只问一句「确定吗」。 */
		smartmwan.confirm({
			title: '强制切换线路',
			message: '确认把全部普通流量强制切换到 ' + wan + ' ？',
			details: [
				'目标暂不可用时指令会保留，恢复后自动生效。',
				'想回到自动决策，请点「取消强制，回到自动决策」。'
			],
			confirmText: '确认切换'
		}).then(function(ok) {
			if (!ok)
				return;
			call('forceWan', { wan: '', confirm: true })({ wan: wan, confirm: true }).then(function(env) {
				if (env && env.ok)
					smartmwan.notify(E('p', [
						'已提交强制切换（事务 ' + (env.data && env.data.id) + '）'
					]), 'info');
				else
					smartmwan.notify(E('p', [
						'操作失败：' + ((env && env.error && env.error.message) || '未知错误')
					]), 'error');
				smartmwan.refresh(self, ROOT);
			}).catch(function(e) {
				smartmwan.notify(E('p', [ 'RPC 失败：' + errText(e) ]), 'error');
			});
		});
	},

	handleRelease: function() {
		var self = this;
		call('releaseForced')({}).then(function(env) {
			if (env && env.ok)
				smartmwan.notify(E('p', [ '已取消强制，回到自动决策' ]), 'info');
			else
				smartmwan.notify(E('p', [
					'操作失败：' + ((env && env.error && env.error.message) || '未知错误')
				]), 'error');
			smartmwan.refresh(self, ROOT);
		}).catch(function(e) {
			smartmwan.notify(E('p', [ 'RPC 失败：' + errText(e) ]), 'error');
		});
	},

	saveConfig: function(applyAfter) {
		var self = this;
		var check = Form.validate(this.fields);
		if (!check.ok) {
			smartmwan.notify(E('p', [ '有字段填写不合法，请先修正标红的输入框。' ]), 'warning');
			return;
		}
		var cfg = this.draft || this.base;
		call('save', { config: {} })({ config: cfg }).then(function(env) {
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
			if (env.ok) {
				var r = env.data || {};
				smartmwan.notify(E('p', [
					'事务 ' + (r.id || '—') + '：' +
					(r.ok ? (r.changed ? '已提交' : '无变更（幂等复核通过）') : '未提交')
				]), r.ok ? 'info' : 'warning');
			} else {
				smartmwan.notify(E('p', [
					'应用失败：' + errText(env.error)
				]), 'error');
			}
			smartmwan.refresh(self, ROOT);
		}).catch(function(e) {
			smartmwan.notify(E('p', [ 'RPC 失败：' + errText(e) ]), 'error');
		});
	},

	errorBox: function(msg) {
		return 'failover', E('div', { 'id': ROOT, 'class': 'smw-state smw-state-error' }, [
			E('strong', {}, [ 'RPC 失败：' ]),
			E('span', {}, [ msg || '无法读取主备状态' ])
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
