'use strict';
/*
 * smartmwan —— 游戏路由视图（零 Lua）
 * 数据源：smartmwan.getGames / getGameQuality。
 * 诚实性：pending 规则显示「等待质量判定」，不显示编造的落点。
 */
'require smartmwan';
'require view';
'require rpc';

var ROOT = 'smw-games-root';

return view.extend({
	load: function() {
		return Promise.all([
			rpc.declare({ object: 'smartmwan', method: 'getGames' })(),
			rpc.declare({ object: 'smartmwan', method: 'getGameQuality' })()
		]).then(function(rv) {
			return { games: rv[0], quality: rv[1] };
		}).catch(function(e) {
			return { __error: String(e && e.message || e) };
		});
	},

	render: function(data) {
		var smw = new smartmwan();
		if (data == null || data.__error != null)
			return E('div', { 'id': ROOT, 'class': 'smw-state smw-state-error alert-message warning' }, [
				E('strong', {}, [ 'RPC 失败：' ]),
				E('span', {}, [ (data && data.__error) || '无法读取游戏路由状态' ])
			]);

		var games = smw.parse(data.games);
		var quality = smw.parse(data.quality);
		var root = E('div', { 'id': ROOT, 'class': 'smw-panel' }, [ E('h2', {}, [ '游戏路由' ]) ]);

		if (games.state != 'ready')
			return E('div', { 'id': ROOT }, smw.states(games, {
				loadingText: '正在读取规则…',
				emptyText: '没有配置游戏规则'
			}));

		/* —— 规则列表 —— */
		root.appendChild(smw.table(
			[ '规则', '状态', '选路', '固定线路', '目的', '端口', '域名' ],
			games.data.rules.map(function(g) {
				return [
					g.name,
					g.enabled ? '启用' : '停用',
					g.selection,
					g.pin_wan || '—',
					(g.targets || []).join(' ') || '—',
					(g.ports || []).join(',') || '—',
					(g.domains || []).join(' ') || '—'
				];
			})
		));

		/* —— 冲突：后端算出什么就显示什么 —— */
		if (games.data.conflicts && games.data.conflicts.length) {
			root.appendChild(E('h3', {}, [ '冲突与提示' ]));
			root.appendChild(E('ul', { 'class': 'smw-notes' },
				games.data.conflicts.map(function(c) {
					return E('li', {}, [ '[' + c.severity + '] ' + c.path + '：' + c.message +
						(c.hint ? '（' + c.hint + '）' : '') ]);
				})
			));
		}

		/* —— DNS 集合状态：如实展示失败计数 —— */
		var d = games.data;
		root.appendChild(E('h3', {}, [ '域名集合' ]));
		root.appendChild(smw.table(
			[ '项目', '值' ],
			[
				[ '跟踪域名', String(d.domains_tracked) ],
				[ '集合元素', String(d.dns_elements) ],
				[ '陈旧域名', String(d.dns_stale_domains) ],
				[ '解析失败（NXDOMAIN / 超时 / 本机）',
					d.dns_failures.notfound + ' / ' + d.dns_failures.timeout + ' / ' + d.dns_failures.local ]
			]
		));
		root.appendChild(E('p', { 'class': 'smw-muted' },
			[ '域名规则依赖 DNS 解析；解析失败不清空旧元素，也不计为线路故障。CDN/任播会让命中不足，' +
			  'DoH/DoT 流量无法从 53 端口识别。' ]));

		/* —— 线路评分：解释「为什么没选它」 —— */
		if (quality.state == 'ready') {
			root.appendChild(E('h3', {}, [ '线路评分（游戏流量候选）' ]));
			root.appendChild(smw.table(
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
			));
			root.appendChild(E('h3', {}, [ '规则落点' ]));
			root.appendChild(smw.table(
				[ '规则', '选路方式', '当前落点' ],
				quality.data.rules.map(function(r) {
					return [
						r.rule,
						r.selection + (r.pin_wan ? '（固定 ' + r.pin_wan + '）' : ''),
						r.pick_wan || '等待质量判定'
					];
				})
			));
		}

		return root;
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
