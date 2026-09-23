'use strict';
'require view';
'require rpc';
'require ui';
'require dom';

var callGetHistory = rpc.declare({
	object: 'luci.ups-manager',
	method: 'get_history',
	expect: { '': {} }
});

var callGetStatus = rpc.declare({
	object: 'luci.ups-manager',
	method: 'get_status',
	expect: { '': {} }
});

function formatTime(ts) {
	var d = new Date(ts * 1000);
	var h = ('0' + d.getHours()).slice(-2);
	var m = ('0' + d.getMinutes()).slice(-2);
	var s = ('0' + d.getSeconds()).slice(-2);
	return h + ':' + m + ':' + s;
}

return view.extend({
	timeRangeHours: 1,
	historyData: [],
	currentStatus: null,

	load: function() {
		return Promise.all([
			callGetHistory(),
			callGetStatus()
		]);
	},

	render: function(res) {
		var self = this;
		var histRes = res[0] || {};
		self.currentStatus = res[1] || {};
		self.historyData = (histRes && histRes.points) ? histRes.points : [];

		var container = E('div', { 'class': 'cbi-map', 'style': 'max-width:1200px;margin:0 auto;' }, [
			E('h2', { 'class': 'cbi-map-title', 'style': 'font-size:1.25rem;font-weight:700;' }, _('电源历史监控曲线')),
			E('div', { 'class': 'cbi-map-descr', 'style': 'color:#64748b;margin-bottom:1.25rem;' }, _('实时记录电网输入电压、输出逆变电压、电池电量与负载率。数据点保存在内存环形缓冲区中，零闪存磨损。'))
		]);

		// Toolbar
		var toolbar = E('div', {
			'style': 'background:#ffffff;border:1px solid #e2e8f0;border-radius:10px;padding:0.75rem 1.25rem;margin-bottom:1.25rem;display:flex;justify-content:space-between;align-items:center;flex-wrap:wrap;gap:0.75rem;'
		}, [
			E('div', { 'style': 'display:flex;gap:0.5rem;align-items:center;' }, [
				E('span', { 'style': 'font-weight:600;font-size:0.85rem;color:#334155;' }, _('时间范围:')),
				E('button', {
					'class': 'cbi-button ' + (self.timeRangeHours === 1 ? 'cbi-button-apply' : 'cbi-button-neutral'),
					'click': function() { self.changeRange(1, this); }
				}, _('1 小时')),
				E('button', {
					'class': 'cbi-button ' + (self.timeRangeHours === 6 ? 'cbi-button-apply' : 'cbi-button-neutral'),
					'click': function() { self.changeRange(6, this); }
				}, _('6 小时')),
				E('button', {
					'class': 'cbi-button ' + (self.timeRangeHours === 24 ? 'cbi-button-apply' : 'cbi-button-neutral'),
					'click': function() { self.changeRange(24, this); }
				}, _('24 小时'))
			]),
			E('div', { 'style': 'display:flex;gap:0.5rem;' }, [
				E('button', {
					'class': 'cbi-button cbi-button-neutral',
					'click': function() { self.exportCSV(); }
				}, _('导出 CSV')),
				E('button', {
					'class': 'cbi-button cbi-button-action',
					'click': function() { self.refreshData(); }
				}, _('刷新曲线'))
			])
		]);

		// Voltage Chart Card
		var chartCard1 = E('div', { 'class': 'cbi-section', 'style': 'background:#ffffff;border:1px solid #e2e8f0;border-radius:12px;padding:1.25rem;margin-bottom:1.25rem;box-shadow:0 2px 8px rgba(0,0,0,0.04);' }, [
			E('div', { 'style': 'display:flex;justify-content:space-between;align-items:center;margin-bottom:1rem;' }, [
				E('span', { 'style': 'font-weight:700;font-size:0.95rem;color:#1e293b;' }, ['🔌 ', _('输入与输出电压曲线 (V)')]),
				E('span', { 'style': 'font-size:0.8rem;' }, [
					E('span', { 'style': 'color:#2563eb;font-weight:bold;' }, '— ' + _('市电输入') + '  '),
					E('span', { 'style': 'color:#10b981;font-weight:bold;' }, '— ' + _('逆变输出'))
				])
			]),
			E('div', { 'id': 'chart-voltage-container', 'style': 'width:100%;height:220px;' })
		]);

		// Load & Battery Chart Card
		var chartCard2 = E('div', { 'class': 'cbi-section', 'style': 'background:#ffffff;border:1px solid #e2e8f0;border-radius:12px;padding:1.25rem;margin-bottom:1.25rem;box-shadow:0 2px 8px rgba(0,0,0,0.04);' }, [
			E('div', { 'style': 'display:flex;justify-content:space-between;align-items:center;margin-bottom:1rem;' }, [
				E('span', { 'style': 'font-weight:700;font-size:0.95rem;color:#1e293b;' }, ['🔋 ', _('电池电量与输出负载率曲线 (%)')]),
				E('span', { 'style': 'font-size:0.8rem;' }, [
					E('span', { 'style': 'color:#10b981;font-weight:bold;' }, '— ' + _('电池电量(%)') + '  '),
					E('span', { 'style': 'color:#f59e0b;font-weight:bold;' }, '— ' + _('负载率(%)'))
				])
			]),
			E('div', { 'id': 'chart-load-container', 'style': 'width:100%;height:220px;' })
		]);

		dom.append(container, [toolbar, chartCard1, chartCard2]);

		// Render charts
		window.setTimeout(function() {
			self.drawCharts();
		}, 80);

		return container;
	},

	changeRange: function(hours, btn) {
		this.timeRangeHours = hours;
		var parent = btn.parentElement;
		var btns = parent.querySelectorAll('button');
		btns.forEach(function(b) { b.className = 'cbi-button cbi-button-neutral'; });
		btn.className = 'cbi-button cbi-button-apply';
		this.drawCharts();
	},

	refreshData: function() {
		var self = this;
		return Promise.all([callGetHistory(), callGetStatus()]).then(function(res) {
			self.historyData = (res[0] && res[0].points) ? res[0].points : [];
			self.currentStatus = res[1] || {};
			self.drawCharts();
			ui.addNotification(null, E('p', {}, _('历史曲线已更新')), 'info');
		});
	},

	getPreparedPoints: function() {
		var pts = this.historyData || [];
		var now = Math.floor(Date.now() / 1000);

		// If zero or 1 point, synthesize baseline from current status so chart never gets stuck!
		if (pts.length < 2) {
			var st = this.currentStatus || {};
			var curV = st.input_voltage || 220;
			var curVo = st.output_voltage || 220;
			var curC = st.battery_charge || 100;
			var curL = st.load_percent || 10;
			var curP = st.power || 50;

			return [
				{ t: now - 300, v: curV, vo: curVo, c: curC, l: curL, p: curP, ob: 0 },
				{ t: now - 150, v: curV, vo: curVo, c: curC, l: curL, p: curP, ob: 0 },
				{ t: now, v: curV, vo: curVo, c: curC, l: curL, p: curP, ob: 0 }
			];
		}

		var cutoff = now - (this.timeRangeHours * 3600);
		var filtered = pts.filter(function(p) { return p.t >= cutoff; });
		if (filtered.length < 2) return pts.slice(-50);
		return filtered;
	},

	renderSvgLineChart: function(points, keys, colors, yMin, yMax) {
		var width = 800;
		var height = 200;
		var padding = { top: 15, right: 25, bottom: 25, left: 45 };
		var chartW = width - padding.left - padding.right;
		var chartH = height - padding.top - padding.bottom;

		var tMin = points[0].t;
		var tMax = points[points.length - 1].t;
		if (tMax <= tMin) tMax = tMin + 10;

		var getX = function(t) {
			return padding.left + ((t - tMin) / (tMax - tMin)) * chartW;
		};
		var getY = function(val) {
			var clamped = Math.max(yMin, Math.min(yMax, val));
			return padding.top + chartH - ((clamped - yMin) / (yMax - yMin)) * chartH;
		};

		var svg = ['<svg viewBox="0 0 ' + width + ' ' + height + '" style="width:100%;height:100%;font-family:inherit;">'];

		// Subtle Grid lines
		svg.push('<line x1="' + padding.left + '" y1="' + padding.top + '" x2="' + (padding.left + chartW) + '" y2="' + padding.top + '" stroke="#f1f5f9" stroke-width="1" />');
		svg.push('<line x1="' + padding.left + '" y1="' + (padding.top + chartH/2) + '" x2="' + (padding.left + chartW) + '" y2="' + (padding.top + chartH/2) + '" stroke="#f1f5f9" stroke-width="1" />');
		svg.push('<line x1="' + padding.left + '" y1="' + (padding.top + chartH) + '" x2="' + (padding.left + chartW) + '" y2="' + (padding.top + chartH) + '" stroke="#e2e8f0" stroke-width="1" />');

		// Clean Y labels
		svg.push('<text x="' + (padding.left - 8) + '" y="' + (padding.top + 4) + '" font-size="11" text-anchor="end" fill="#94a3b8">' + yMax + '</text>');
		svg.push('<text x="' + (padding.left - 8) + '" y="' + (padding.top + chartH/2 + 4) + '" font-size="11" text-anchor="end" fill="#94a3b8">' + Math.round((yMax+yMin)/2) + '</text>');
		svg.push('<text x="' + (padding.left - 8) + '" y="' + (padding.top + chartH + 4) + '" font-size="11" text-anchor="end" fill="#94a3b8">' + yMin + '</text>');

		// Clean Time labels
		svg.push('<text x="' + padding.left + '" y="' + (height - 6) + '" font-size="11" fill="#94a3b8">' + formatTime(tMin) + '</text>');
		svg.push('<text x="' + (padding.left + chartW) + '" y="' + (height - 6) + '" font-size="11" text-anchor="end" fill="#94a3b8">' + formatTime(tMax) + '</text>');

		// Outage markers
		for (var i = 0; i < points.length; i++) {
			if (points[i].ob === 1) {
				var x = getX(points[i].t);
				svg.push('<line x1="' + x + '" y1="' + padding.top + '" x2="' + x + '" y2="' + (padding.top + chartH) + '" stroke="#ef4444" stroke-width="1.5" stroke-dasharray="3,2" />');
			}
		}

		// Line Series
		for (var k = 0; k < keys.length; k++) {
			var key = keys[k];
			var color = colors[k];
			var pathD = [];
			for (var p = 0; p < points.length; p++) {
				var val = points[p][key] !== undefined ? points[p][key] : 0;
				var ptX = getX(points[p].t).toFixed(1);
				var ptY = getY(val).toFixed(1);
				pathD.push((p === 0 ? 'M' : 'L') + ptX + ',' + ptY);
			}
			svg.push('<path d="' + pathD.join(' ') + '" fill="none" stroke="' + color + '" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round" />');
		}

		svg.push('</svg>');
		return svg.join('');
	},

	drawCharts: function() {
		var points = this.getPreparedPoints();

		var c1 = document.getElementById('chart-voltage-container');
		if (c1) {
			c1.innerHTML = this.renderSvgLineChart(points, ['v', 'vo'], ['#2563eb', '#10b981'], 180, 260);
		}

		var c2 = document.getElementById('chart-load-container');
		if (c2) {
			c2.innerHTML = this.renderSvgLineChart(points, ['c', 'l'], ['#10b981', '#f59e0b'], 0, 100);
		}
	},

	exportCSV: function() {
		var points = this.getPreparedPoints();
		var lines = ['Timestamp,DateTime,InputVoltage_V,OutputVoltage_V,BatteryCharge_Pct,Load_Pct,Power_W,OnBattery'];
		for (var i = 0; i < points.length; i++) {
			var p = points[i];
			var dt = new Date(p.t * 1000).toISOString();
			lines.push([p.t, dt, p.v || 0, p.vo || 0, p.c || 0, p.l || 0, p.p || 0, p.ob || 0].join(','));
		}

		var blob = new Blob([lines.join('\n')], { type: 'text/csv;charset=utf-8;' });
		var url = URL.createObjectURL(blob);
		var a = document.createElement('a');
		a.href = url;
		a.download = 'ups_manager_history_' + Math.floor(Date.now() / 1000) + '.csv';
		a.click();
		URL.revokeObjectURL(url);
	}
});
