'use strict';
/*
 * smartmwan —— 游戏路由视图（零 Lua）
 * 数据源：smartmwan.getGames（命中/冲突/DNS）/ getGameQuality（评分）/ getConfig（规则基线）。
 *
 * 规则管理走「草稿 → save → apply」链路（与主备页一致）：
 *   * 列表展示的是草稿规则（可编辑的真相），命中数按名称从 getGames 对齐；
 *   * 新增/编辑用 Drawer 表单，确认后写入草稿；删除走确认弹窗；
 *   * 保存时守护进程做全量校验，issues 不通过就不落盘；
 *   * 预置目录（/usr/share/smartmwan/presets）为空时全部为自定义规则，
 *     带 preset 来源标识的规则照常可编辑，守护进程校验兜底。
 * 诚实性两条：pending 规则显示「等待质量判定」；命中数读不到显示「—」而不是 0。
 */
'require smartmwan';
'require view';
'require rpc';
'require ui';

var ROOT = 'smw-games-root';
var Form = smartmwan.ui.Form;

function call(method, params) {
	/* params 必须作为模板声明：本机 LuCI 的 rpc.declare 只把模板里
	 * 出现的键装进请求，缺了模板实参会被整个丢弃（真机实测）。 */
	return rpc.declare({ object: 'smartmwan', method: method, params: params, reject: true });
}

var errText = smartmwan.errText || function(e) { return String(e && e.message || e); };

var SELECTIONS = [
	{ value: 'best', label: '择优（健康线路中按评分选择）' },
	{ value: 'pin', label: '固定线路' },
	{ value: 'follow', label: '跟随普通策略（仅识别统计，不干预）' }
];

var PROTOS = [
	{ value: 'both', label: 'TCP + UDP' },
	{ value: 'tcp', label: '仅 TCP' },
	{ value: 'udp', label: '仅 UDP' }
];

function linesToText(arr) {
	return (arr || []).join('\n');
}

function textToLines(text) {
	return String(text || '').split(/\n+/).map(function(s) { return s.trim(); })
		.filter(function(s) { return s !== ''; });
}

function selectionLabel(sel, pinWan) {
	if (sel === 'pin')
		return '固定线路（' + (pinWan || '未指定') + '）';
	if (sel === 'follow')
		return '跟随普通策略';
	return '择优';
}

function emptyRule() {
	return {
		name: '', enabled: true, priority: 50, preset: '',
		targets: [], ports: [], proto: 'both',
		client_ips: [], client_macs: [], domains: [],
		selection: 'best', pin_wan: '', comment: ''
	};
}

return view.extend({
	draft: null,

	load: function() {
		return Promise.all([
			call('getGames')(),
			call('getGameQuality')(),
			call('getConfig')()
		]).then(function(rv) {
			return { games: rv[0], quality: rv[1], config: rv[2] };
		}).catch(function(e) {
			return { __error: errText(e) };
		});
	},

	render: function(data) {
		var smw = smartmwan;
		if (data == null || data.__error != null)
			return this.errorBox(data && data.__error);

		var self = this;
		var games = smw.parse(data.games);
		if (games.state != 'ready')
			return E('div', { 'id': ROOT }, smw.states(games, {
				loadingText: '正在读取规则…',
				emptyText: '没有配置游戏规则'
			}));

		var quality = smw.parse(data.quality);
		var cfg = smw.parse(data.config);
		this.base = cfg.state == 'ready' ? cfg.data.config : null;
		/* 命中数按名称对齐（运行时状态，不进草稿）。 */
		var hitsByName = {};
		(games.data.rules || []).forEach(function(r) { hitsByName[r.name] = r; });

		var root = E('div', { 'id': ROOT, 'class': 'smw-panel' }, [
			E('h2', {}, [ '游戏路由' ])
		]);

		/* —— 规则管理（可编辑草稿） —— */
		if (this.base) {
			var rules = (this.draft || this.base).games || [];
			var listEl = E('div', { 'class': 'smw-form' }, []);

			rules.forEach(function(g) {
				
				var kv = [
					[ '选路', selectionLabel(g.selection, g.pin_wan) ],
					[ '目标', (g.targets || []).join('、') || '—' ],
					[ '端口', (g.ports || []).join('、') || '任意' ],
					[ '域名', (g.domains || []).join('、') || '—' ],
					[ '优先级', String(g.priority) ]
				];
				if (g.comment)
					kv.push([ '备注', g.comment ]);

				listEl.appendChild(E('div', { 'class': 'smw-line-card' }, [
					E('div', { 'class': 'smw-line-head' }, [
						E('strong', {}, [ g.name ]),
						g.enabled ? smw.stateBadge('healthy', '启用') : smw.stateBadge('unknown', '停用'),
						g.preset ? E('span', { 'class': 'smw-badge smw-badge-info' }, [ '预置' ])
							: E('span', { 'class': 'smw-badge smw-badge-muted' }, [ '自定义' ]),
						g.selection == 'pin' && g.pin_wan ? E('span', { 'class': 'smw-badge smw-badge-warn' }, [ '固定 ' + g.pin_wan ]) : '',
						E('span', { 'class': 'smw-badge smw-badge-muted' }, [ '命中 ' + (g.hits == null ? '—' : g.hits.packets + ' 包') ])
					]),
					smw.kv(kv),
					E('div', { 'class': 'smw-line-actions' }, [
						smartmwan.button('编辑', { variant: 'tonal', click: ui.createHandlerFn(self, 'handleEditRule', g.name) }),
						smartmwan.button('删除', { variant: 'text-danger', click: ui.createHandlerFn(self, 'handleDeleteRule', g.name) })
					])
				]));
			});

			root.appendChild(smw.section('规则管理', [
				rules.length ? listEl
					: E('p', { 'class': 'smw-muted' }, [ '还没有任何规则；点「新增规则」创建第一条自定义规则。' ]),
				E('div', { 'class': 'smw-actions' }, [
					smartmwan.button('新增规则', { variant: 'filled', click: ui.createHandlerFn(self, 'handleEditRule', null) })
				]),
				E('p', { 'class': 'smw-muted' }, [
					'改动先进入草稿，点「保存并应用」后写盘并下发；命中数在应用后按周期采样，读不到时显示「—」而不是 0。'
				])
			]));
		}
		else {
			root.appendChild(smw.section('规则管理', [
				E('p', { 'class': 'smw-muted' }, [ '配置读取失败，无法编辑规则。' ])
			]));
		}

		/* —— 冲突：后端算出什么就显示什么 —— */
		if (games.data.conflicts && games.data.conflicts.length) {
			root.appendChild(smw.section('冲突与提示', [
				E('ul', { 'class': 'smw-notes' },
					games.data.conflicts.map(function(c) {
						return E('li', {}, [
							'[' + c.severity + '] ' + c.path + '：' + c.message +
							(c.hint ? '（' + c.hint + '）' : '')
						]);
					}))
			]));
		}

		/* —— DNS 集合状态：如实展示失败计数 —— */
		root.appendChild(smw.section('域名集合', [
			smw.kv([
				[ '跟踪域名', String(games.data.domains_tracked) ],
				[ '集合元素', String(games.data.dns_elements) ],
				[ '陈旧域名', String(games.data.dns_stale_domains) ],
				[ '解析失败（NXDOMAIN / 超时 / 本机）',
					(function(f) {
						return f ? (f.notfound + ' / ' + f.timeout + ' / ' + f.local) : '—';
					})(games.data.dns_failures) ]
			]),
			E('p', { 'class': 'smw-muted' }, [
				'域名规则依赖 DNS 解析；解析失败不清空旧元素，也不计为线路故障。',
				'CDN/任播会让命中不足，DoH/DoT 流量无法从 53 端口识别。'
			])
		]));

		/* —— 线路评分：解释「为什么没选它」 —— */
		if (quality.state == 'ready') {
			root.appendChild(smw.section('线路评分（游戏流量候选）', [
				smw.table(
					[ '线路', '评分', 'RTT', '抖动', '丢包', '状态', '可信' ],
					(quality.data.ranking || []).map(function(r) {
						return [
							r.wan,
							r.score.toFixed(1),
							r.rtt_ms + ' ms',
							r.jitter_ms + ' ms',
							smw.pmm(r.loss_pmm),
							r.state,
							r.confident ? '是' : '否'
						];
					})
				)
			]));
			root.appendChild(smw.section('规则落点', [
				smw.table(
					[ '规则', '选路方式', '当前落点' ],
					(quality.data.rules || []).map(function(r) {
						return [
							r.rule,
							r.selection + (r.pin_wan ? '（固定 ' + r.pin_wan + '）' : ''),
							r.pick_wan || '等待质量判定'
						];
					})
				)
			]));
		}

		/* 草稿保存栏 */
		this.slot = E('div', {});
		root.appendChild(this.slot);
		this.renderActions();

		return root;
	},

	/* ---------- 草稿 ---------- */

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
		this.slot.appendChild(smartmwan.dirty('游戏规则有未保存的修改（保存后仍需「应用」才会下发到内核）', [
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

	/* ---------- 规则表单（Drawer） ---------- */

	handleEditRule: function(name) {
		var self = this;
		var base = this.draft || this.base;
		var isNew = (name == null);
		var rule = null;
		if (!isNew) {
			(base.games || []).forEach(function(r) {
				if (r.name === name)
					rule = JSON.parse(JSON.stringify(r));
			});
			if (rule == null)
				return;
		}
		else
			rule = emptyRule();

		var wans = (this.base.wans || []);

		var nameIn = Form.text({ value: rule.name, onchange: function(v) { rule.name = String(v || '').trim(); } });
		var prioIn = Form.number({ value: rule.priority, min: 0, max: 65535, onchange: function(v) { rule.priority = parseInt(v, 10) || 0; } });
		var selIn = Form.select({ options: SELECTIONS, value: rule.selection, onchange: function(v) { rule.selection = v; } });
		var pinIn = Form.select({
			options: [ { value: '', label: '— 请选择线路 —' } ].concat(wans.map(function(w) {
				return { value: w.name, label: w.name + (w.enabled ? '' : '（已停用）') };
			})),
			value: rule.pin_wan || '',
			onchange: function(v) { rule.pin_wan = v; }
		});
		var protoIn = Form.select({ options: PROTOS, value: rule.proto, onchange: function(v) { rule.proto = v; } });
		var tgtIn = Form.textarea({ value: linesToText(rule.targets), rows: 4, onchange: function(v) { rule.targets = textToLines(v); } });
		var portIn = Form.textarea({ value: linesToText(rule.ports), rows: 3, onchange: function(v) { rule.ports = textToLines(v); } });
		var domIn = Form.textarea({ value: linesToText(rule.domains), rows: 3, onchange: function(v) { rule.domains = textToLines(v); } });
		var cmtIn = Form.text({ value: rule.comment, onchange: function(v) { rule.comment = String(v || ''); } });
		var ciIn = Form.textarea({ value: linesToText(rule.client_ips), rows: 3, onchange: function(v) { rule.client_ips = textToLines(v); } });
		var cmIn = Form.textarea({ value: linesToText(rule.client_macs), rows: 3, onchange: function(v) { rule.client_macs = textToLines(v); } });
		var enIn = Form.switch({ checked: rule.enabled, onchange: function(v) { rule.enabled = v; } });

		/* Form.field 返回 {el, input, setError...} 对象 —— body 里必须传 .el
		 * 而不是对象本身（LuCI 的 E() 会丢弃非节点子项，真机实测）。 */
		var drawerFields = [
			Form.field({ label: '规则名称', required: true, control: nameIn,
				help: '字母/数字/下划线（≤32 字符）；保存后作为规则标识，不可与现有规则重名。' }),
			Form.field({ label: '启用', control: enIn.el }),
			Form.field({ label: '选路方式', control: selIn,
				help: '择优 = 健康线路按评分选；固定线路 = 始终走所选线路；跟随普通策略 = 只识别统计不干预。' }),
			Form.field({ label: '固定线路', control: pinIn, help: '仅「选路方式 = 固定线路」时生效。' }),
			Form.field({ label: '优先级', required: true, control: prioIn,
				help: '数值越小越先匹配（默认 50）。' }),
			Form.field({ label: '目标 IP / 网段（每行一个）', control: tgtIn,
				help: '如 1.2.3.4 或 10.0.0.0/24，IPv4/IPv6 可混写。' }),
			Form.field({ label: '目的端口（每行一个）', control: portIn,
				help: '如 443 或 8000-8010；留空匹配任意端口。' }),
			Form.field({ label: '协议', control: protoIn }),
			Form.field({ label: '域名（每行一个）', control: domIn,
				help: '依赖 DNS 动态集合；不支持通配符与 URL。' }),
			Form.field({ label: '备注', control: cmtIn }),
			Form.field({ label: '客户端 IP / CIDR（每行一个，可留空）', control: ciIn,
				help: '限定规则只对这些内网客户端生效；留空 = 所有客户端。' }),
			Form.field({ label: '客户端 MAC（每行一个，可留空）', control: cmIn })
		];

		smartmwan.ui.Drawer.open({
			title: isNew ? '新增游戏规则' : '编辑规则：' + name,
			description: '字段留空 = 不限制（如「端口」留空匹配任意端口）。加入草稿后点「保存并应用」，守护进程会做全量校验。',
			width: 560,
			body: drawerFields.map(function(f) { return f.el; }),
		actions: [
				{ label: '取消', variant: 'text', value: null },
				{
					label: isNew ? '加入草稿' : '更新到草稿',
					variant: 'filled',
					onClick: function() {
						var e = self.validateRule(rule);
						if (e != null)
							throw new Error(e);
						self.stage(function(d) {
							if (!d.games)
								d.games = [];
							var replaced = false;
							for (var i = 0; i < d.games.length; i++)
								if (d.games[i].name === rule.name) {
									d.games[i] = rule;
									replaced = true;
									break;
								}
							if (!replaced)
								d.games.push(rule);
						});
						smartmwan.refresh(self, ROOT);
					}
				}
			]
		});
	},

	/** 轻量前端校验（名称/选路依赖）；格式细节交给守护进程全量校验。 */
	validateRule: function(rule) {
		if (!rule.name)
			return '规则名称不能为空';
		if (!/^[A-Za-z0-9_]{1,32}$/.test(rule.name))
			return '规则名称只能用字母、数字、下划线（≤32 字符）';
		var base = this.draft || this.base;
		for (var i = 0; i < (base.games || []).length; i++)
			if (base.games[i].name === rule.name)
				return '已存在同名规则：' + rule.name;
		if (rule.selection === 'pin' && !rule.pin_wan)
			return '固定线路方式必须选择一条线路';
		if (rule.selection !== 'pin')
			rule.pin_wan = '';
		if (!(rule.priority >= 0 && rule.priority <= 65535))
			return '优先级取值 0-65535';
		return null;
	},

	handleDeleteRule: function(name) {
		var self = this;
		smartmwan.confirm({
			title: '删除游戏规则',
			message: '确认删除规则「' + name + '」？',
			details: [
				'删除先进入草稿，点「保存并应用」后才真正写盘并从内核移除。'
			],
			confirmText: '确认删除',
			danger: true
		}).then(function(ok) {
			if (!ok)
				return;
			self.stage(function(d) {
				d.games = (d.games || []).filter(function(r) { return r.name !== name; });
			});
			smartmwan.refresh(self, ROOT);
		});
	},

	/* ---------- 保存 / 应用 ---------- */

	saveConfig: function(applyAfter) {
		var self = this;
		var cfg = this.draft || this.base;
		if (cfg == null)
			return;
		call('save', { config: {} })({ config: cfg }).then(function(env) {
			if (!env || !env.ok) {
				smartmwan.notify(E('p', [
					'保存失败：' + ((env && env.error && env.error.message) || '未知错误')
				]), 'error');
				return null;
			}
			var issues = (env.data && env.data.report && env.data.report.issues) || [];
			if (issues.length) {
				smartmwan.notify(E('p', [
					'保存被拒绝，配置校验未通过（' + issues.length + ' 项）：',
					E('ul', {}, issues.slice(0, 5).map(function(i) {
						return E('li', {}, [ i.path + '：' + i.message ]);
					}))
				]), 'error');
				return null;
			}
			var changes = (env.data && env.data.changes) || [];
			smartmwan.notify(E('p', [
				'已写盘（' + changes.length + ' 项变更）',
				changes.length ? E('ul', {}, changes.slice(0, 5).map(function(c) {
					return E('li', {}, [ c.path + '：' + c.old + ' → ' + c.new ]);
				})) : ''
			]), 'success');
			self.draft = null;
			self.base = cfg;
			self.renderActions();
			return applyAfter ? call('apply')({}) : null;
		}).then(function(env) {
			if (env == null)
				return;
			if (env.ok) {
				var r = env.data || {};
				smartmwan.notify(E('p', [
					'事务 ' + (r.id || '—') + '：' +
					(r.ok ? (r.changed ? '已提交' : '无变更（幂等复核通过）') : '未提交')
				]), r.ok ? 'info' : 'warning');
			}
			else {
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
		return E('div', { 'id': ROOT, 'class': 'smw-state smw-state-error' }, [
			E('strong', {}, [ 'RPC 失败：' ]),
			E('span', {}, [ msg || '无法读取游戏路由状态' ])
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
