'use strict';
/*
 * smartmwan —— 负载均衡视图（零 Lua）
 * 数据源：smartmwan.getBalance / getConfig；写操作：save（+ apply）。
 *
 * 编辑区走「先保存、再应用」两步：save 只写盘并返回差异，apply 才让守护进程
 * 跑一次完整事务。界面绝不直接把一份配置塞给内核。
 */
'require smartmwan';
'require view';
'require rpc';
'require ui';

var ROOT = 'smw-balance-root';

var Form = smartmwan.ui.Form;

/* 与 src/config/schema.rs::Algorithm 的 UCI 取值一一对应；
 * 顺序按「静态哈希 → 动态 → 加权」排列，便于用户按意图挑选。 */
var ALGORITHMS = [
	{ value: 'src_ip', label: '源地址哈希（同一客户端稳定走同一出口）' },
	{ value: 'src_ip_src_port', label: '源地址 + 源端口哈希' },
	{ value: 'src_ip_dst_ip', label: '源 + 目的地址哈希' },
	{ value: 'src_ip_dst_ip_dst_port', label: '源 + 目的地址 + 端口哈希' },
	{ value: 'full_five_tuple', label: '完整五元组哈希' },
	{ value: 'weighted_hash', label: '加权哈希（按权重分配桶）' },
	{ value: 'weighted_ecmp', label: '内核加权 ECMP（需内核多路径与 ip-full）' },
	{ value: 'least_new_connections', label: '新建连接数最少优先（动态重排）' },
	{ value: 'least_traffic', label: '实时流量最少优先（动态重排）' }
];

function call(method) {
	return rpc.declare({ object: 'smartmwan', method: method });
}

return view.extend({
	/* 编辑中的草稿：null 表示「还没改过」。只有非 null 才渲染保存栏。 */
	draft: null,

	load: function() {
		return Promise.all([
			call('getBalance')(),
			call('getConfig')()
		]).then(function(rv) {
			return { balance: rv[0], config: rv[1] };
		}).catch(function(e) {
			return { __error: String(e && e.message || e) };
		});
	},

	render: function(data) {
		var smw = smartmwan;
		var parsed = data && data.__error == null ? smw.parse(data.balance) : null;

		if (data == null || data.__error != null)
			return 'balance', this.errorBox(data && data.__error);

		if (parsed == null || parsed.state == 'error')
			return 'balance', E('div', { 'id': ROOT }, smw.states(
				parsed || { state: 'error', error: { message: data && data.__error } },
				{ loadingText: '正在读取均衡状态…' }));

		if (parsed.state != 'ready')
			return E('div', { 'id': ROOT }, smw.states(parsed, { emptyText: '暂无均衡数据' }));

		var b = parsed.data;
		var cfgParsed = smw.parse(data.config);
		/* 草稿的原料：getConfig 给的整份配置。改字段后原样回传 save —— 后端才是
		 * 唯一权威，界面不自己拼配置。 */
		this.base = cfgParsed.state == 'ready' ? cfgParsed.data.config : null;
		var self = this;

		var root = E('div', { 'id': ROOT, 'class': 'smw-panel' }, [
			E('h2', {}, [ '负载均衡' ])
		]);

		/* —— 编辑区 —— */
		if (this.base) {
			var g = this.base.global;
			var fields = [
				Form.field({
					label: '算法',
					control: Form.searchSelect({
						options: ALGORITHMS,
						value: g.algorithm,
						onchange: function(v) {
							self.stage(function(d) { d.global.algorithm = v; });
						}
					}).el,
					help: '动态算法（最少连接/最少流量）会按统计窗口重排桶；' +
						'加权 ECMP 依赖内核能力，不支持时会降级。'
				}),
				Form.field({
					label: '桶数',
					required: true,
					control: Form.number({
						value: g.buckets, min: 2, max: 256, step: 2,
						onchange: function(v) {
							self.stage(function(d) { d.global.buckets = parseInt(v, 10); });
						}
					}),
					help: '桶越多分配越细，但规则数也随之增长；改动会重排全部新建连接。',
					validate: Form.validators.intBetween(2, 256)
				}),
				Form.field({
					label: '会话保持（已建立连接不换出口）',
					control: Form.switch({
						checked: !!g.conn_sticky,
						onchange: function(v) {
							self.stage(function(d) { d.global.conn_sticky = v; });
						}
					}).el,
					help: '关闭后，桶重排会让已建立连接换出口（可能瞬断）。'
				}),
				Form.field({
					label: '最小重排间隔（毫秒）',
					required: true,
					control: Form.number({
						value: g.rebalance_interval_ms, min: 0, max: 600000, step: 100,
						onchange: function(v) {
							self.stage(function(d) { d.global.rebalance_interval_ms = parseInt(v, 10); });
						}
					}),
					help: '动态算法的重排节流：太小会让内核被反复重写。',
					validate: Form.validators.intBetween(0, 600000)
				})
			];

			/* 权重：按线路逐条给输入框。权重只在加权算法下参与桶分配，
			 * 这句话必须写出来，否则用户在纯哈希算法下调半天以为没生效。 */
			var weightFields = (this.base.wans || []).map(function(w) {
				return Form.field({
					label: w.name + ' 权重',
					required: true,
					control: Form.number({
						value: w.weight, min: 0, max: 1000, step: 1,
						onchange: function(v) {
							self.stage(function(d) {
								for (var i = 0; i < d.wans.length; i++)
									if (d.wans[i].name === w.name)
										d.wans[i].weight = parseInt(v, 10);
							});
						}
					}),
					help: '0 表示不参与分流',
					validate: Form.validators.intBetween(0, 1000)
				});
			});

			this.fields = fields.concat(weightFields);

			root.appendChild(smw.section('均衡参数', [
				E('div', { 'class': 'smw-form' }, fields.map(function(f) { return f.el; }))
			]));
			root.appendChild(smw.section('线路权重', [
				E('div', { 'class': 'smw-form' }, weightFields.map(function(f) { return f.el; })),
				E('p', { 'class': 'smw-muted' }, [
					'权重只在「加权哈希 / 加权 ECMP / 动态算法」下参与桶分配；',
					'纯哈希算法按哈希值均分，权重不生效。'
				])
			]));
		}

		/* —— 生效情况（只读）：编辑区写的是「意图」，这里显示的是「实际」 —— */
		root.appendChild(smw.section('当前生效', [
			smw.kv([
				[ '生效算法', smw.algorithm(b.algorithm) ],
				[ '配置算法', smw.algorithm(b.configured_algorithm) +
					(b.algorithm !== b.configured_algorithm ? '（已降级，见限制说明）' : '') ],
				[ '算法限制', b.limitations || '—' ],
				[ '桶数', String(b.buckets_total) ],
				[ '上轮搬动', String(b.moved) + ' 桶' ],
				[ '平滑系数', (b.smoothing_permille / 1000).toFixed(2) ],
				[ '哈希种子', '0x' + (b.hash_seed || 0).toString(16) ]
			])
		]));

		if (b.share_permille && b.share_permille.length) {
			root.appendChild(smw.section('份额', [
				E('div', { 'class': 'smw-bars' },
					b.share_permille.map(function(r) {
						return E('div', { 'class': 'smw-bar-row' }, [
							E('span', { 'class': 'smw-bar-label' }, [ r.wan ]),
							E('span', { 'class': 'smw-bar-track' },
								E('span', {
									'class': 'smw-bar-fill',
									'style': 'width:' + (r.permille / 10) + '%'
								})),
							E('span', { 'class': 'smw-bar-value' }, [ (r.permille / 10).toFixed(1) + '%' ])
						]);
					})
				)
			]));
		}

		if (b.buckets && b.buckets.length) {
			root.appendChild(smw.section('桶图（槽位）', [
				E('div', { 'class': 'smw-bucketmap' },
					b.buckets.map(function(slot, i) {
						return E('span', { 'class': 'smw-bucket' + (slot ? '' : ' smw-bucket-zero') },
							[ String(i) + '→' + (slot || '—') ]);
					})
				),
				E('p', { 'class': 'smw-muted' }, [
					'格式：桶号→槽位；— 表示该桶不分流。桶与槽位的对应关系在重启后可复现。'
				])
			]));
		}

		/* —— 保存栏：只在真的改过之后出现 —— */
		this.slot = E('div', {});
		root.appendChild(this.slot);
		this.renderActions();

		return root;
	},

	/** 把一次改动写进草稿（不改 this.base，避免「取消」无从恢复）。 */
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
		/* 清空后重建：LuCI 没有内建的重绘，局部替换要自己来。 */
		while (this.slot.firstChild)
			this.slot.removeChild(this.slot.firstChild);

		if (this.draft == null)
			return;

		this.slot.appendChild(smwDirty());

		function smwDirty() {
			return smartmwan.dirty('有未保存的修改（保存后仍需「应用」才会下发到内核）', [
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
			]);
		}
	},

	/** 保存（写盘）。applyAfter 为真时再触发一次完整事务。 */
	/* 不叫 handleSave：那是 LuCI 表单视图的保留钩子，占用它会凭空多出一个
	 * 全局「保存」按钮，语义与本页的「保存并应用」完全不同。 */
	saveConfig: function(applyAfter) {
		var self = this;
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
			var changes = (env.data && env.data.changes) || [];
			smartmwan.notify(E('p', [
				'已写盘（' + changes.length + ' 项变更）',
				E('ul', {}, changes.map(function(c) {
					return E('li', {}, [ c.path + '：' + c.old + ' → ' + c.new ]);
				}))
			]), 'success');
			self.draft = null;
			self.base = cfg;
			self.renderActions();
			if (applyAfter)
				return call('apply')();
			return null;
		}).then(function(env) {
			if (env == null)
				return;
			if (env.ok) {
				var r = env.data || {};
				smartmwan.notify(E('p', [
					'事务 ' + r.id + '：' +
					(r.ok ? (r.changed ? '已提交' : '无变更（幂等复核通过）') : '未提交')
				]), 'info');
			} else {
				smartmwan.notify(E('p', [
					'应用失败：' + ((env.error && env.error.message) || '未知错误')
				]), 'error');
			}
			smartmwan.refresh(self, ROOT);
		}).catch(function(e) {
			smartmwan.notify(E('p', [ 'RPC 失败：' + e ]), 'error');
		});
	},

	errorBox: function(msg) {
		return 'balance', E('div', { 'id': ROOT, 'class': 'smw-state smw-state-error' }, [
			E('strong', {}, [ 'RPC 失败：' ]),
			E('span', {}, [ msg || '无法读取均衡状态' ])
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
