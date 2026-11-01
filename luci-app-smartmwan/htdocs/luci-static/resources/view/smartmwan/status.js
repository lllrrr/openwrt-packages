'use strict';
/*
 * smartmwan —— 运行总览视图（零 Lua）
 * 数据源：smartmwan.getStatus / getLines / getTraffic / getCapabilities。
 * 四态（加载/空/失败/就绪）由共享模块判定；后端 notes 原样展示。
 *
 * 本页只读：所有「改配置」的入口都在各自的设置页。
 *
 * 轮询策略：页面结构分成「壳（标题 + live 容器 + 刷新指示）」与「live 内容」，
 * 每轮重取四项数据后只替换 live 容器（记录并恢复滚动位置，页面不跳），
 * 替换后再登记轮询 —— smw.poll 保证同一模块同时只有一条活跃轮询。
 */
'require smartmwan';
'require view';
'require rpc';

var ROOT = 'smw-status-root';

function call(object, method) {
	/* reject: true —— ubus 层错误（桥未加载/权限/连接失败）必须走 reject，
	 * 否则裸状态码会被当成功结果 resolve，四态判定只能猜出「未知错误」。 */
	return rpc.declare({ object: object, method: method, reject: true });
}

/* 用一份数据填充 live 容器。render 与轮询共用；数据四态不就绪时原样渲染。 */
function fill(container, data) {
	var smw = smartmwan;
	var st = smw.parse(data.status);

	if (st.state != 'ready') {
		container.appendChild(smw.states(st, {
			loadingText: '正在读取运行状态…',
			emptyText: '守护进程尚未产出状态'
		}));
		return;
	}

	var s = st.data;
	var caps = smw.parse(data.caps);
	var lines = smw.parse(data.lines);
	var traffic = smw.parse(data.traffic);

	/* —— 总览卡片 —— */
	/* 停用不是「一种模式」而是「插件不接管流量」，必须单独成卡并说明后果。 */
	container.appendChild(E('div', { 'class': 'smw-cards' }, [
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
		container.appendChild(smartmwan.section('接口吞吐（窗口 ' + traffic.data.window_ms + ' ms）', [
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
	container.appendChild(smartmwan.section('决策说明', [
		E('p', {}, [ s.reason ]),
		E('h4', {}, [ '后端备注（notes）' ]),
		smw.notes(s.notes)
	]));

	/* —— 桶分布 —— */
	if (s.buckets && s.buckets.share_permille && s.buckets.share_permille.length) {
		container.appendChild(smartmwan.section('桶分布（共 ' + s.buckets.total + ' 桶）', [
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
		container.appendChild(smartmwan.section('线路', [
			smw.table(
				[ '线路', '状态', 'RTT', '抖动', '丢包', '连接数', '槽位/表' ],
				(lines.data.lines || []).map(function(l) {
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
		container.appendChild(smartmwan.section('本机语法降级', [
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
		container.appendChild(smartmwan.section('最近一次事务', [
			E('p', {}, [ E('code', {}, [ r.id ]), ' —— ', outcome ]),
			r.error ? E('p', { 'class': 'smw-error' }, [ r.error ]) : '',
			(r.rollback && r.rollback.length)
				? E('div', { 'class': 'smw-notice' }, [
					E('strong', {}, [ '内核状态需人工确认：' ]),
					E('ul', { 'class': 'smw-notes' }, r.rollback.map(function(x) { return E('li', {}, [ x ]); }))
				])
				: ''
		]));
	}
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
			return { __error: smartmwan.errText(e) };
		});
	},

	render: function(data) {
		if (data == null || data.__error != null)
			return this.errorBox(data && data.__error);

		var self = this;
		var root = E('div', { 'id': ROOT, 'class': 'smw-panel' }, [
			E('h2', {}, [ '运行总览' ])
		]);
		var live = E('div', { 'class': 'smw-live' });
		root.appendChild(live);

		var stamp = E('span', { 'class': 'smw-tick' }, [ '轮询已启动（每 5 秒）' ]);
		root.appendChild(stamp);

		fill(live, data);

		smw.poll(ROOT, function() {
			self.load().then(function(fresh) {
				if (fresh == null || fresh.__error != null) {
					stamp.textContent = '刷新失败：' + ((fresh && fresh.__error) || '未知错误');
					return;
				}
				var y = window.scrollY;
				while (live.firstChild)
					live.removeChild(live.firstChild);
				fill(live, fresh);
				window.scrollTo(0, y);
				var p = smartmwan.parse(fresh.status);
				stamp.textContent = '更新于 ' + smartmwan.time(Date.now()) +
					(p.state == 'ready' && p.data.reason ? '：' + p.data.reason : '');
			}).catch(function(e) {
				stamp.textContent = '刷新失败：' + smartmwan.errText(e);
			});
		}, 5);

		return root;
	},

	errorBox: function(msg) {
		return E('div', { 'id': ROOT, 'class': 'smw-state smw-state-error' }, [
			E('strong', {}, [ 'RPC 失败：' ]),
			E('span', {}, [ msg || '无法连接守护进程，请确认 smartmwand 已启动' ])
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
