'use strict';
/*
 * smartmwan —— 连接与流量视图（零 Lua）
 * 数据源：smartmwan.getConnections / getTraffic。
 * 轮询 3 秒；离开页面自行停止（共享模块的 poll 生命周期）。
 *
 * 轮询策略：页面分「壳（标题 + live 容器 + 刷新指示）」与「live 内容」，
 * 每轮重取数据后整体替换 live 容器并恢复滚动位置 —— 连接数与吞吐是本页的
 * 主体，只更新时间戳不更新数字等于没有轮询。
 */
'require smartmwan';
'require view';
'require rpc';

var ROOT = 'smw-traffic-root';

function call(method) {
	return rpc.declare({ object: 'smartmwan', method: method, reject: true });
}

/* 用一份数据填充 live 容器。render 与轮询共用。 */
function fill(container, data) {
	var smw = smartmwan;
	var conns = smw.parse(data.conns);
	var traffic = smw.parse(data.traffic);

	if (conns.state == 'ready') {
		var c = conns.data;
		container.appendChild(smw.section('并发连接（按槽位）', [
			smw.table(
				[ '槽位', '路由表', '连接数', '较上轮' ],
				(c.per_slot || []).map(function(r) {
					return [
						String(r.slot),
						String(r.table),
						String(r.conns),
						r.growth == null ? '—' : (r.growth >= 0 ? '+' : '') + r.growth
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
		container.appendChild(smw.section('接口吞吐（窗口 ' + traffic.data.window_ms + ' ms）', [
			smw.table(
				[ '设备', '下行', '上行', '累计接收', '累计发送' ],
				(traffic.data.devices || []).map(function(d) {
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

	if (conns.state != 'ready' && traffic.state != 'ready')
		container.appendChild(smw.states(conns, { emptyText: '暂无连接与流量数据' }));
}

/* 兼容旧版共享模块缓存:errText 缺失时退化为原始消息,页面不因混缓存崩溃 */
var errText = smartmwan.errText || function(e) { return String(e && e.message || e); };
return view.extend({
	load: function() {
		return Promise.all([
			call('getConnections')(),
			call('getTraffic')()
		]).then(function(rv) {
			return { conns: rv[0], traffic: rv[1] };
		}).catch(function(e) {
			return { __error: errText(e) };
		});
	},

	render: function(data) {
		if (data == null || data.__error != null)
			return this.errorBox(data && data.__error);

		var smw = smartmwan;
		var self = this;
		var root = E('div', { 'id': ROOT, 'class': 'smw-panel' }, [
			E('h2', {}, [ '连接与流量' ])
		]);
		var live = E('div', { 'class': 'smw-live' });
		root.appendChild(live);

		var stamp = smw.tick('轮询已启动（每 3 秒）');
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
				stamp.textContent = '更新于 ' + smartmwan.time(Date.now());
			}).catch(function(e) {
				stamp.textContent = '刷新失败：' + errText(e);
			});
		}, 3);

		return root;
	},

	errorBox: function(msg) {
		return E('div', { 'id': ROOT, 'class': 'smw-state smw-state-error' }, [
			E('strong', {}, [ 'RPC 失败：' ]),
			E('span', {}, [ msg || '无法读取连接与流量' ])
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
