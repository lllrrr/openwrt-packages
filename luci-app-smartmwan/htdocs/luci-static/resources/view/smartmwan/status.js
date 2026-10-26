'use strict';
/*
 * smartmwan —— 运行总览视图（零 Lua）
 * 数据源：smartmwan.getStatus / getLines / getTraffic / getCapabilities / getLogs。
 * 四态（加载/空/失败/就绪）由共享模块判定；后端 notes 原样展示。
 *
 * 本页只读：所有「改配置」的入口都在各自的设置页。
 */
'require smartmwan';
'require view';
'require rpc';

var ROOT = 'smw-status-root';

function call(object, method) {
	return rpc.declare({ object: object, method: method });
}

return view.extend({
	load: function() {
		return Promise.all([
			call('smartmwan', 'getStatus')(),
			call('smartmwan', 'getLines')(),
			call('smartmwan', 'getTraffic')(),
			call('smartmwan', 'getCapabilities')()
		]).then(function(rv) {
			return {
				status: rv[0],
				lines: rv[1],
				traffic: rv[2],
				caps: rv[3]
			};
		}).catch(function(e) {
			return { __error: String(e && e.message || e) };
		});
	},

	render: function(data) {
		if (data == null || data.__error != null)
			return this.errorBox(data && data.__error);

		var smw = smartmwan;   /* LuCI require 返回单例实例，不可再 new */
		var st = smw.parse(data.status);

		if (st.state != 'ready')
			return 'status', E('div', { 'id': ROOT }, smw.states(st, {
				loadingText: '正在读取运行状态…',
				emptyText: '守护进程尚未产出状态'
			}));

		var s = st.data;
		var caps = smw.parse(data.caps);
		var lines = smw.parse(data.lines);
		var traffic = smw.parse(data.traffic);

		var root = E('div', { 'id': ROOT, 'class': 'smw-panel' }, [
			E('h2', {}, [ '运行总览' ])
		]);

		/* —— 总览卡片 —— */
		/* 停用不是「一种模式」而是「插件不接管流量」，必须单独成卡并说明后果。 */
		root.appendChild(E('div', { 'class': 'smw-cards' }, [
			s.enabled
				? smw.stat('模式', smartmwan.mode(s.mode), '', 'ok')
				: smw.stat('模式', '已停用', 'enabled=0：不接管任何流量', 'warn'),
			s.all_dead
				? smw.stat('活动出口', '无可用出口', '全部线路不可用', 'bad')
				: smw.stat('活动出口', s.active || '—', ''),
			smw.stat('承载流量', s.carries_traffic ? '是' : '否',
				s.measured ? '' : '尚未完成首轮探测', s.carries_traffic ? 'ok' : ''),
			smw.stat('nft 通道', s.firewall, '')
		]));

		/* —— 实时吞吐：总览页最常被问的就是「现在跑了多少」 —— */
		if (traffic.state == 'ready' && traffic.data.devices && traffic.data.devices.length) {
			var devs = traffic.data.devices;
			root.appendChild(smartmwan.section('接口吞吐（窗口 ' + traffic.data.window_ms + ' ms）', [
				smw.table(
					[ '设备', '下行', '上行', '累计接收', '累计发送' ],
					devs.map(function(d) {
						return [
							d.device,
							smw.kbps(d.rx_kbps),
							smw.kbps(d.tx_kbps),
							smw.bytes(d.rx_bytes),
							smw.bytes(d.tx_bytes)
						];
					})
				)
			]));
		}

		/* —— 后端说明：原样透传，不挑好消息 —— */
		root.appendChild(smartmwan.section('决策说明', [
			E('p', {}, [ s.reason ]),
			E('h4', {}, [ '后端备注（notes）' ]),
			smw.notes(s.notes)
		]));

		/* —— 桶分布 —— */
		if (s.buckets && s.buckets.share_permille && s.buckets.share_permille.length) {
			root.appendChild(smartmwan.section('桶分布（共 ' + s.buckets.total + ' 桶）', [
				E('div', { 'class': 'smw-bars' },
					s.buckets.share_permille.map(function(r) {
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

		/* —— 线路摘要：抖动与丢包决定体验，必须和 RTT 并列 —— */
		if (lines.state == 'ready') {
			root.appendChild(smartmwan.section('线路', [
				smw.table(
					[ '线路', '状态', 'RTT', '抖动', '丢包', '连接数', '槽位/表' ],
					lines.data.lines.map(function(l) {
						var m = l.metrics || {};
						return [
							l.name,
							smw.stateBadge(l.state, l.state_label),
							m.rtt_ms != null ? m.rtt_ms + ' ms' : '—',
							m.jitter_ms != null ? m.jitter_ms + ' ms' : '—',
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
			root.appendChild(smartmwan.section('本机语法降级', [
				E('p', { 'class': 'smw-muted' }, [ caps.data.note ]),
				E('ul', { 'class': 'smw-notes' },
					caps.data.degraded.map(function(d) { return E('li', {}, [ d ]); }))
			]));
		}

		/* —— 最近一笔回执 —— */
		if (s.last_receipt) {
			var r = s.last_receipt;
			/* 回执有四种结局，UI 必须分得清：已提交 / 无变更 / 失败已回滚 / 未提交。
			   压成「成功/失败」两种会丢掉「内核现在是什么状态」。 */
			var outcome = r.ok
				? (r.changed ? '已提交' : '无变更（幂等复核通过）')
				: (r.rollback && r.rollback.length ? '失败并已回滚' : '未提交');
			root.appendChild(smartmwan.section('最近一次事务', [
				E('p', {}, [ E('code', {}, [ r.id ]), ' —— ', outcome ]),
				r.error ? E('p', { 'class': 'smw-error' }, [ r.error ]) : '',
				(r.rollback && r.rollback.length)
					? E('div', { 'class': 'alert-message warning' }, [
						E('strong', {}, [ '内核状态需人工确认：' ]),
						E('ul', {}, r.rollback.map(function(x) { return E('li', {}, [ x ]); }))
					])
					: ''
			]));
		}

		/* —— 刷新指示：只在原地更新时间，不整页重绘（重绘会让滚动位置跳走） —— */
		var stamp = E('span', { 'class': 'smw-tick' }, [ '轮询已启动（每 5 秒）' ]);
		smw.poll(ROOT, function() {
			call('smartmwan', 'getStatus')().then(function(env) {
				var p = smartmwan.parse(env);
				if (p.state == 'ready')
					stamp.textContent = '更新于 ' + smartmwan.time(Date.now()) + '：' + p.data.reason;
				else
					stamp.textContent = '刷新失败：' + (p.error && p.error.message);
			}).catch(function() {});
		}, 5);
		root.appendChild(stamp);

		return root;
	},

	errorBox: function(msg) {
		return 'status', E('div', { 'id': ROOT, 'class': 'smw-state smw-state-error alert-message warning' }, [
			E('strong', {}, [ 'RPC 失败：' ]),
			E('span', {}, [ msg || '无法连接守护进程，请确认 smartmwand 已启动' ])
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
