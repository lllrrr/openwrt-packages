'use strict';
/*
 * smartmwan —— 连接与流量视图（零 Lua）
 * 数据源：smartmwan.getConnections / getTraffic。
 * 轮询 3 秒；离开页面自行停止（共享模块的 poll 生命周期）。
 */
'require smartmwan';
'require view';
'require rpc';

var ROOT = 'smw-traffic-root';

return view.extend({
	load: function() {
		return Promise.all([
			rpc.declare({ object: 'smartmwan', method: 'getConnections' })(),
			rpc.declare({ object: 'smartmwan', method: 'getTraffic' })()
		]).then(function(rv) {
			return { conns: rv[0], traffic: rv[1] };
		}).catch(function(e) {
			return { __error: String(e && e.message || e) };
		});
	},

	render: function(data) {
		var smw = new smartmwan();
		if (data == null || data.__error != null)
			return E('div', { 'id': ROOT, 'class': 'smw-state smw-state-error alert-message warning' }, [
				E('strong', {}, [ 'RPC 失败：' ]),
				E('span', {}, [ (data && data.__error) || '无法读取连接与流量' ])
			]);

		var conns = smw.parse(data.conns);
		var traffic = smw.parse(data.traffic);
		var root = E('div', { 'id': ROOT, 'class': 'smw-panel' }, [ E('h2', {}, [ '连接与流量' ]) ]);

		if (conns.state == 'ready') {
			var c = conns.data;
			root.appendChild(E('h3', {}, [ '并发连接（按槽位）' ]));
			root.appendChild(smw.table(
				[ '槽位', '路由表', '连接数', '较上轮' ],
				c.per_slot.map(function(r) {
					return [ String(r.slot), String(r.table), String(r.conns), (r.growth >= 0 ? '+' : '') + r.growth ];
				})
			));
			root.appendChild(smw.table(
				[ '项目', '值' ],
				[
					[ '本插件标记', String(c.owned) ],
					[ '他人标记（不介入）', String(c.foreign) ],
					[ '未标记', String(c.unmarked) ],
					[ '跟踪总数', String(c.total) + (c.truncated ? '（扫描达到上限，计数偏小）' : '') ]
				]
			));
			if (c.limits) {
				root.appendChild(E('p', { 'class': c.limits.tight ? 'smw-warn' : 'smw-muted' }, [
					'conntrack 跟踪表：' + c.limits.used + ' / ' + c.limits.max +
					'（' + (c.limits.used_permille / 10).toFixed(1) + '%）' +
					(c.limits.tight ? '，接近上限' : '')
				]));
			}
		}

		if (traffic.state == 'ready') {
			root.appendChild(E('h3', {}, [ '接口吞吐（窗口 ' + traffic.data.window_ms + ' ms）' ]));
			root.appendChild(smw.table(
				[ '设备', '接收', '发送', '累计接收', '累计发送' ],
				traffic.data.devices.map(function(d) {
					return [
						d.device,
						smw.kbps(d.rx_kbps),
						smw.kbps(d.tx_kbps),
						smw.bytes(d.rx_bytes),
						smw.bytes(d.tx_bytes)
					];
				})
			));
		}

		/* 轮询：3 秒 */
		var self = this;
		smw.poll(ROOT, function() {
			self.load().then(function(d) {
				var box = document.getElementById('smw-traffic-refresh');
				if (box == null)
					return;
				box.textContent = '更新于 ' + new smartmwan().time(Date.now());
			}).catch(function() {});
		}, 3);
		root.appendChild(E('div', { 'id': 'smw-traffic-refresh', 'class': 'smw-muted' },
			[ '轮询已启动（每 3 秒）' ]));

		return root;
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
