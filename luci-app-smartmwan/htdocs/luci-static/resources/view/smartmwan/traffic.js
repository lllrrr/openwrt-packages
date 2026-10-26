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

function call(method) {
	return rpc.declare({ object: 'smartmwan', method: method });
}

return view.extend({
	load: function() {
		return Promise.all([
			call('getConnections')(),
			call('getTraffic')()
		]).then(function(rv) {
			return { conns: rv[0], traffic: rv[1] };
		}).catch(function(e) {
			return { __error: String(e && e.message || e) };
		});
	},

	render: function(data) {
		var smw = smartmwan;
		if (data == null || data.__error != null)
			return 'traffic', this.errorBox(data && data.__error);

		var conns = smw.parse(data.conns);
		var traffic = smw.parse(data.traffic);
		var root = E('div', { 'id': ROOT, 'class': 'smw-panel' }, [
			E('h2', {}, [ '连接与流量' ])
		]);

		if (conns.state == 'ready') {
			var c = conns.data;
			root.appendChild(smw.section('并发连接（按槽位）', [
				smw.table(
					[ '槽位', '路由表', '连接数', '较上轮' ],
					c.per_slot.map(function(r) {
						return [
							String(r.slot),
							String(r.table),
							String(r.conns),
							(r.growth >= 0 ? '+' : '') + r.growth
						];
					})
				),
				smw.kv([
					[ '本插件标记', String(c.owned) ],
					[ '他人标记（不介入）', String(c.foreign) ],
					[ '未标记', String(c.unmarked) ],
					[ '跟踪总数', String(c.total) +
						(c.truncated ? '（扫描达到上限，计数偏小）' : '') ]
				]),
				c.limits ? E('p', { 'class': c.limits.tight ? 'smw-warn' : 'smw-muted' }, [
					'conntrack 跟踪表：' + c.limits.count + ' / ' + c.limits.max +
					'（' + (c.limits.used_permille / 10).toFixed(1) + '%）' +
					(c.limits.tight ? '，接近上限' : '')
				]) : '',
				E('p', { 'class': 'smw-muted' }, [ c.note || '' ])
			]));
		}

		if (traffic.state == 'ready') {
			root.appendChild(smw.section('接口吞吐（窗口 ' + traffic.data.window_ms + ' ms）', [
				smw.table(
					[ '设备', '下行', '上行', '累计接收', '累计发送' ],
					traffic.data.devices.map(function(d) {
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

		/* 刷新指示：只更新时间文字，不整页重绘（重绘会让滚动位置跳走）。 */
		var stamp = smw.tick('轮询已启动（每 3 秒）');
		smw.poll(ROOT, function() {
			this.load().then(function() {
				stamp.textContent = '更新于 ' + smartmwan.time(Date.now());
			}).catch(function() {});
		}.bind(this), 3);
		root.appendChild(stamp);

		return root;
	},

	errorBox: function(msg) {
		return 'traffic', E('div', { 'id': ROOT, 'class': 'smw-state smw-state-error alert-message warning' }, [
			E('strong', {}, [ 'RPC 失败：' ]),
			E('span', {}, [ msg || '无法读取连接与流量' ])
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
