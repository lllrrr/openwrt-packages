'use strict';
'require view';
'require rpc';
'require ui';
'require dom';

var callGetEnergy = rpc.declare({
	object: 'luci.ups-manager',
	method: 'get_energy',
	expect: { '': {} }
});

var callGetStatus = rpc.declare({
	object: 'luci.ups-manager',
	method: 'get_status',
	expect: { '': {} }
});

return view.extend({
	load: function() {
		return Promise.all([
			callGetEnergy(),
			callGetStatus()
		]);
	},

	render: function(data) {
		var energy = data[0] || {};
		var status = data[1] || {};

		var container = E('div', { 'class': 'cbi-map' }, [
			E('h2', { 'class': 'cbi-map-title' }, _('用电量统计与能耗报表')),
			E('div', { 'class': 'cbi-map-descr' }, _('实时功率监控、日用电量与月度用电量统计分析。支持实测功率与额定估算功率分级标识。'))
		]);

		// Metric cards
		var cards = E('div', { 'class': 'ups-manager-grid', 'style': 'display:grid;grid-template-columns:repeat(auto-fit, minmax(220px, 1fr));gap:1rem;margin-bottom:1.5rem;' }, [
			// Today kWh
			E('div', { 'class': 'cbi-section', 'style': 'background:#ffffff;border:1px solid #e2e8f0;border-radius:0.75rem;padding:1.25rem;' }, [
				E('div', { 'style': 'color:#64748b;font-size:0.875rem;' }, _('今日累计用电量')),
				E('div', { 'style': 'font-size:1.8rem;font-weight:700;color:#0f172a;margin:0.5rem 0;' },
					(energy.today_kwh !== undefined ? energy.today_kwh : '0.00') + ' kWh'
				),
				E('div', { 'style': 'font-size:0.8rem;color:#94a3b8;' }, _('从当日 00:00 起开始积分'))
			]),

			// Month kWh
			E('div', { 'class': 'cbi-section', 'style': 'background:#ffffff;border:1px solid #e2e8f0;border-radius:0.75rem;padding:1.25rem;' }, [
				E('div', { 'style': 'color:#64748b;font-size:0.875rem;' }, _('当月累计用电量')),
				E('div', { 'style': 'font-size:1.8rem;font-weight:700;color:#0f172a;margin:0.5rem 0;' },
					(energy.month_kwh !== undefined ? energy.month_kwh : '0.00') + ' kWh'
				),
				E('div', { 'style': 'font-size:0.8rem;color:#94a3b8;' }, _('自然月累加总计'))
			]),

			// Current Power
			E('div', { 'class': 'cbi-section', 'style': 'background:#ffffff;border:1px solid #e2e8f0;border-radius:0.75rem;padding:1.25rem;' }, [
				E('div', { 'style': 'color:#64748b;font-size:0.875rem;' }, _('当前实时输出功率')),
				E('div', { 'style': 'font-size:1.8rem;font-weight:700;color:#2563eb;margin:0.5rem 0;' }, [
					(status.power !== null && status.power !== undefined) ? (status.power + ' W') : _('未知'),
					status.power_is_estimated ?
						E('span', { 'style': 'font-size:0.75rem;background:#fef3c7;color:#b45309;padding:2px 6px;border-radius:4px;margin-left:6px;' }, _('估算')) :
						E('span', { 'style': 'font-size:0.75rem;background:#dcfce7;color:#15803d;padding:2px 6px;border-radius:4px;margin-left:6px;' }, _('实测'))
				]),
				E('div', { 'style': 'font-size:0.8rem;color:#94a3b8;' }, _('峰值: ') + (energy.peak_power || status.power || 0) + ' W')
			]),

			// Average Power
			E('div', { 'class': 'cbi-section', 'style': 'background:#ffffff;border:1px solid #e2e8f0;border-radius:0.75rem;padding:1.25rem;' }, [
				E('div', { 'style': 'color:#64748b;font-size:0.875rem;' }, _('24小时平均功率')),
				E('div', { 'style': 'font-size:1.8rem;font-weight:700;color:#0f172a;margin:0.5rem 0;' },
					(energy.avg_power || status.power || 0) + ' W'
				),
				E('div', { 'style': 'font-size:0.8rem;color:#94a3b8;' }, _('根据近期功率采样均值计算'))
			])
		]);

		// Disclaimer & Calculation Principles (Strict requirement of Section VII)
		var noteSection = E('div', { 'class': 'cbi-section', 'style': 'background:#f8fafc;border:1px solid #e2e8f0;border-radius:0.75rem;padding:1rem;margin-bottom:1.5rem;' }, [
			E('h4', { 'style': 'margin-top:0;color:#334155;' }, 'ℹ ' + _('用电量算法与计量透明度说明')),
			E('ul', { 'style': 'margin:0;padding-left:1.25rem;color:#475569;font-size:0.85rem;line-height:1.6;' }, [
				E('li', {}, _('当设备支持 ups.realpower 字段时，系统直接读取硬件高精度实测有功功率。')),
				E('li', {}, _('当设备不支持 ups.realpower 时，系统依据：实时估算功率 = 额定有功功率 (W) × (负载率 ups.load ÷ 100)。此时在界面显式标注为【估算】，因存在功率因数波动及非线性负载，典型误差约为 5%~15%。')),
				E('li', {}, _('UPS 输出端用电量不等同于市电输入电网总能耗，实际市电输入还包含 UPS 内置逆变器自耗电、充电损耗及整流转换效率 (典型效率约为 85%~95%)。'))
			])
		]);

		dom.append(container, [cards, noteSection]);
		return container;
	}
});
