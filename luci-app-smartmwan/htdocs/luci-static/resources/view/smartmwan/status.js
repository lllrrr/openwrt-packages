'use strict';
/*
 * smartmwan —— 运行总览视图（零 Lua）
 * 数据源：smartmwan.getStatus / getLines / getCapabilities / getLogs。
 * 四态（加载/空/失败/就绪）由共享模块判定；后端 notes 原样展示。
 */
'require smartmwan';
'require view';
'require rpc';

var ROOT = 'smw-status-root';

return view.extend({
	load: function() {
		return Promise.all([
			rpc.declare({ object: 'smartmwan', method: 'getStatus' })(),
			rpc.declare({ object: 'smartmwan', method: 'getLines' })(),
			rpc.declare({ object: 'smartmwan', method: 'getCapabilities' })()
		]).then(function(rv) {
			return {
				status: rv[0],
				lines: rv[1],
				caps: rv[2]
			};
		}).catch(function(e) {
			return { __error: String(e && e.message || e) };
		});
	},

	render: function(data) {
		if (data == null || data.__error != null)
			return this.errorBox(data && data.__error);

		var smw = new smartmwan();
		var st = smw.parse(data.status);
		var root = E('div', { 'id': ROOT, 'class': 'smw-panel' });

		if (st.state != 'ready')
			return E('div', { 'id': ROOT }, smw.states(st, {
				loadingText: '正在读取运行状态…',
				emptyText: '守护进程尚未产出状态'
			}));

		var s = st.data;
		var caps = smw.parse(data.caps);
		var lines = smw.parse(data.lines);

		root.appendChild(E('h2', {}, [ '运行总览' ]));

		/* —— 总览卡片 —— */
		root.appendChild(E('div', { 'class': 'smw-cards' }, [
			this.card('模式', s.enabled ? (s.mode == 'failover' ? '主备' : '均衡') : '已停用',
				s.enabled ? '' : 'enabled=0：不接管任何流量'),
			this.card('活动出口', s.active || (s.all_dead ? '无可用出口' : '—'),
				s.all_dead ? '全部线路不可用' : ''),
			this.card('承载流量', s.carries_traffic ? '是' : '否',
				s.measured ? '' : '尚未完成首轮探测'),
			this.card('nft 通道', s.firewall, '')
		]));

		/* —— 后端说明：原样透传，不挑好消息 —— */
		root.appendChild(E('div', { 'class': 'smw-block' }, [
			E('h3', {}, [ '决策说明' ]),
			E('p', {}, [ s.reason ]),
			E('h4', {}, [ '后端备注（notes）' ]),
			smw.notes(s.notes)
		]));

		/* —— 桶分布 —— */
		if (s.buckets && s.buckets.share_permille && s.buckets.share_permille.length) {
			root.appendChild(E('div', { 'class': 'smw-block' }, [
				E('h3', {}, [ '桶分布（共 ' + s.buckets.total + ' 桶）' ]),
				smw.table(
					[ '线路', '千分比' ],
					s.buckets.share_permille.map(function(r) {
						return [ r.wan, r.permille + ' ‰' ];
					})
				)
			]));
		}

		/* —— 线路摘要 —— */
		if (lines.state == 'ready') {
			root.appendChild(E('div', { 'class': 'smw-block' }, [
				E('h3', {}, [ '线路' ]),
				smw.table(
					[ '线路', '状态', 'RTT', '丢包', '连接数', '槽位/表' ],
					lines.data.lines.map(function(l) {
						var m = l.metrics || {};
						return [
							l.name,
							smw.stateBadge(l.state, l.state_label),
							m.rtt_ms != null ? m.rtt_ms + ' ms' : '—',
							m.loss_pmm != null ? smw.pmm(m.loss_pmm) : '—',
							String(l.conns),
							l.slot ? l.slot + ' / ' + l.table : '—'
						];
					})
				)
			]));
		}

		/* —— 能力降级：如实展示 —— */
		if (caps.state == 'ready' && caps.data.degraded && caps.data.degraded.length) {
			root.appendChild(E('div', { 'class': 'smw-block' }, [
				E('h3', {}, [ '本机语法降级' ]),
				E('p', { 'class': 'smw-muted' }, [ caps.data.note ]),
				E('ul', { 'class': 'smw-notes' },
					caps.data.degraded.map(function(d) { return E('li', {}, [ d ]) }))
			]));
		}

		/* —— 最近一笔回执 —— */
		if (s.last_receipt) {
			var r = s.last_receipt;
			root.appendChild(E('div', { 'class': 'smw-block' }, [
				E('h3', {}, [ '最近一次事务' ]),
				E('p', {}, [
					E('code', {}, [ r.id ]), ' —— ',
					r.ok ? (r.changed ? '已提交' : '无变更（幂等复核通过）')
					     : (r.rollback && r.rollback.length ? '失败并已回滚' : '未提交')
				]),
				r.error ? E('p', { 'class': 'smw-error' }, [ r.error ]) : '',
				(r.rollback && r.rollback.length)
					? E('div', { 'class': 'alert-message warning' }, [
						E('strong', {}, [ '内核状态需人工确认：' ]),
						E('ul', {}, r.rollback.map(function(x) { return E('li', {}, [ x ]) }))
					])
					: ''
			]));
		}

		/* —— 轮询：5 秒；离开页面自行停止 —— */
		var self = this;
		smw.poll(ROOT, function() {
			rpc.declare({ object: 'smartmwan', method: 'getStatus' })().then(function(env) {
				var box = document.getElementById('smw-status-body');
				if (box == null)
					return;
				var p = new smartmwan().parse(env);
				box.textContent = p.state == 'ready'
					? ('更新于 ' + new smartmwan().time(Date.now()) + '：' + p.data.reason)
					: ('刷新失败：' + (p.error && p.error.message));
			}).catch(function() {});
		}, 5);
		root.appendChild(E('div', { 'id': 'smw-status-body', 'class': 'smw-muted' },
			[ '轮询已启动（每 5 秒）' ]));

		return root;
	},

	card: function(title, value, note) {
		return E('div', { 'class': 'smw-card' }, [
			E('div', { 'class': 'smw-card-title' }, [ title ]),
			E('div', { 'class': 'smw-card-value' }, [ String(value) ]),
			note ? E('div', { 'class': 'smw-card-note' }, [ note ]) : ''
		]);
	},

	errorBox: function(msg) {
		return E('div', { 'id': ROOT, 'class': 'smw-state smw-state-error alert-message warning' }, [
			E('strong', {}, [ 'RPC 失败：' ]),
			E('span', {}, [ msg || '无法连接守护进程，请确认 smartmwand 已启动' ])
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
