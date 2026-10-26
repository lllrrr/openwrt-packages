'use strict';
/*
 * smartmwan —— 负载均衡视图（零 Lua）
 * 数据源：smartmwan.getBalance。本页只读：均衡参数在「设置」页改。
 */
'require smartmwan';
'require view';
'require rpc';

var ROOT = 'smw-balance-root';

return view.extend({
	load: function() {
		return rpc.declare({ object: 'smartmwan', method: 'getBalance' })().catch(function(e) {
			return { __error: String(e && e.message || e) };
		});
	},

	render: function(data) {
		var smw = new smartmwan();
		var parsed = data && data.__error == null ? smw.parse(data) : null;

		if (parsed == null || parsed.state == 'error')
			return E('div', { 'id': ROOT }, smw.states(parsed || { state: 'error', error: { message: data && data.__error } }, {
				loadingText: '正在读取均衡状态…'
			}));

		if (parsed.state != 'ready')
			return E('div', { 'id': ROOT }, smw.states(parsed, { emptyText: '暂无均衡数据' }));

		var b = parsed.data;
		var root = E('div', { 'id': ROOT, 'class': 'smw-panel' }, [
			E('h2', {}, [ '负载均衡' ])
		]);

		root.appendChild(smw.table(
			[ '项目', '值' ],
			[
				[ '算法', b.algorithm + (b.algorithm != b.configured_algorithm ? '（配置为 ' + b.configured_algorithm + '）' : '') ],
				[ '算法限制', b.limitations || '—' ],
				[ '桶数', String(b.buckets_total) ],
				[ '上轮搬动', String(b.moved) + ' 桶' ],
				[ '重排间隔', b.rebalance_interval_ms + ' ms' ],
				[ '平滑系数', (b.smoothing_permille / 1000).toFixed(2) ],
				[ '哈希种子', '0x' + (b.hash_seed || 0).toString(16) ]
			]
		));

		if (b.share_permille && b.share_permille.length) {
			root.appendChild(E('h3', {}, [ '份额' ]));
			root.appendChild(E('div', { 'class': 'smw-bars' },
				b.share_permille.map(function(r) {
					return E('div', { 'class': 'smw-bar-row' }, [
						E('span', { 'class': 'smw-bar-label' }, [ r.wan ]),
						E('span', { 'class': 'smw-bar-track' },
							E('span', { 'class': 'smw-bar-fill', 'style': 'width:' + (r.permille / 10) + '%' })),
						E('span', { 'class': 'smw-bar-value' }, [ (r.permille / 10).toFixed(1) + '%' ])
					]);
				})
			));
		}

		if (b.buckets && b.buckets.length) {
			root.appendChild(E('h3', {}, [ '桶图（槽位）' ]));
			root.appendChild(E('div', { 'class': 'smw-bucketmap' },
				b.buckets.map(function(slot, i) {
					return E('span', { 'class': 'smw-bucket' + (slot ? '' : ' smw-bucket-zero') },
						[ String(i) + '→' + (slot || '—') ]);
				})
			));
			root.appendChild(E('p', { 'class': 'smw-muted' },
				[ '格式：桶号→槽位；— 表示该桶不分流。桶与槽位的对应关系在重启后可复现。' ]));
		}

		return root;
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
