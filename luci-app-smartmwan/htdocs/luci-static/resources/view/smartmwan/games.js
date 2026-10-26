'use strict';
/*
 * smartmwan —— 游戏路由视图（零 Lua）
 * 数据源：smartmwan.getGames / getGameQuality。
 *
 * 诚实性两条：pending 规则显示「等待质量判定」，不显示编造的落点；
 * 命中数读不到时显示「—」而不是 0 —— 0 会被读成「规则没命中过」，
 * 而真相可能是通道不是真 nft、根本没读到。
 */
'require smartmwan';
'require view';
'require rpc';

var ROOT = 'smw-games-root';

function call(method) {
	return rpc.declare({ object: 'smartmwan', method: method });
}

return view.extend({
	load: function() {
		return Promise.all([
			call('getGames')(),
			call('getGameQuality')()
		]).then(function(rv) {
			return { games: rv[0], quality: rv[1] };
		}).catch(function(e) {
			return { __error: String(e && e.message || e) };
		});
	},

	render: function(data) {
		var smw = smartmwan;
		if (data == null || data.__error != null)
			return 'games', this.errorBox(data && data.__error);

		var games = smw.parse(data.games);
		if (games.state != 'ready')
			return 'games', E('div', { 'id': ROOT }, smw.states(games, {
				loadingText: '正在读取规则…',
				emptyText: '没有配置游戏规则'
			}));

		var d = games.data;
		var quality = smw.parse(data.quality);
		var root = E('div', { 'id': ROOT, 'class': 'smw-panel' }, [
			E('h2', {}, [ '游戏路由' ])
		]);

		/* —— 规则列表（含命中数） —— */
		root.appendChild(smw.section('规则', [
			smw.table(
				[ '规则', '状态', '选路', '固定线路', '命中', '目的', '端口', '域名' ],
				(d.rules || []).map(function(g) {
					return [
						g.name,
						g.enabled ? '启用' : '停用',
						g.selection,
						g.pin_wan || '—',
						/* 命中数：null（读不到）与 0（读到了但没命中）必须区分开。 */
						g.hits == null ? '—' : (g.hits.packets + ' 包'),
						(g.targets || []).join(' ') || '—',
						(g.ports || []).join(',') || '—',
						(g.domains || []).join(' ') || '—'
					];
				})
			),
			E('p', { 'class': 'smw-muted' }, [
				d.hits_note || '命中数来自内核 counter，按规则求和；同一规则可能对应多条 nft 规则。'
			])
		]));

		/* —— 冲突：后端算出什么就显示什么 —— */
		if (d.conflicts && d.conflicts.length) {
			root.appendChild(smw.section('冲突与提示', [
				E('ul', { 'class': 'smw-notes' },
					d.conflicts.map(function(c) {
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
				[ '跟踪域名', String(d.domains_tracked) ],
				[ '集合元素', String(d.dns_elements) ],
				[ '陈旧域名', String(d.dns_stale_domains) ],
				[ '解析失败（NXDOMAIN / 超时 / 本机）',
					d.dns_failures.notfound + ' / ' + d.dns_failures.timeout + ' / ' + d.dns_failures.local ]
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
					quality.data.ranking.map(function(r) {
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
					quality.data.rules.map(function(r) {
						return [
							r.rule,
							r.selection + (r.pin_wan ? '（固定 ' + r.pin_wan + '）' : ''),
							r.pick_wan || '等待质量判定'
						];
					})
				)
			]));
		}

		return root;
	},

	errorBox: function(msg) {
		return 'games', E('div', { 'id': ROOT, 'class': 'smw-state smw-state-error alert-message warning' }, [
			E('strong', {}, [ 'RPC 失败：' ]),
			E('span', {}, [ msg || '无法读取游戏路由状态' ])
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
