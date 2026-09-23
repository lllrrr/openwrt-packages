'use strict';
'require view';
'require rpc';
'require ui';
'require dom';

var callGetRawData = rpc.declare({
	object: 'luci.ups-manager',
	method: 'get_raw_data',
	expect: { '': {} }
});

// NUT Field dictionary for human-friendly explanation and units
var NUT_DICT = {
	'battery.charge': { label: '电池剩余电量', unit: '%', type: 'measured', desc: '蓄电池组当前电量百分比' },
	'battery.charge.low': { label: '低电量告警阈值', unit: '%', type: 'reported', desc: '触发 LB 状态的设备设定阈值' },
	'battery.charge.warning': { label: '电量预警阈值', unit: '%', type: 'reported', desc: '触发预警通知的电量阈值' },
	'battery.runtime': { label: '预计持续续航', unit: '秒', type: 'measured', desc: '当前负载下的预估可用放电时间' },
	'battery.runtime.low': { label: '低续航告警阈值', unit: '秒', type: 'reported', desc: '触发低续航告警的时间阈值' },
	'battery.voltage': { label: '电池端电压', unit: 'V', type: 'measured', desc: '蓄电池组总工作电压' },
	'battery.voltage.nominal': { label: '电池标称电压', unit: 'V', type: 'reported', desc: '蓄电池组标准标称额定电压' },
	'battery.type': { label: '电池技术类型', unit: '', type: 'reported', desc: '电池材料化学类型 (如 PbAc, Li-ion)' },
	'device.mfr': { label: '设备厂商', unit: '', type: 'reported', desc: 'UPS 硬件生产制造商' },
	'device.model': { label: '设备型号', unit: '', type: 'reported', desc: 'UPS 硬件型号' },
	'device.serial': { label: '设备序列号', unit: '', type: 'reported', desc: '设备出厂唯一硬件编号' },
	'device.type': { label: '设备类别', unit: '', type: 'reported', desc: '硬件大类 (ups)' },
	'driver.name': { label: 'NUT 驱动程序', unit: '', type: 'system', desc: '用于和该硬件通信的 NUT 驱动' },
	'driver.version': { label: 'NUT 驱动版本', unit: '', type: 'system', desc: 'NUT 驱动内部版本号' },
	'driver.version.internal': { label: '驱动内部构建', unit: '', type: 'system', desc: '驱动编译版次' },
	'input.voltage': { label: '市电输入电压', unit: 'V', type: 'measured', desc: '电网交流输入实际电压' },
	'input.voltage.nominal': { label: '市电标称电压', unit: 'V', type: 'reported', desc: '电网标准设定电压 (如 220V)' },
	'input.frequency': { label: '市电输入频率', unit: 'Hz', type: 'measured', desc: '电网交流输入实时工频' },
	'input.frequency.nominal': { label: '市电标称频率', unit: 'Hz', type: 'reported', desc: '电网标准工频 (50Hz / 60Hz)' },
	'output.voltage': { label: '逆变输出电压', unit: 'V', type: 'measured', desc: '输出给后端设备的交流电压' },
	'output.voltage.nominal': { label: '输出标称电压', unit: 'V', type: 'reported', desc: '标准逆变输出目标电压' },
	'output.frequency': { label: '逆变输出频率', unit: 'Hz', type: 'measured', desc: '输出端交流电工频' },
	'output.current': { label: '输出实际电流', unit: 'A', type: 'measured', desc: '输出端实测负载电流' },
	'ups.load': { label: '实时负载率', unit: '%', type: 'measured', desc: '相对于额定功率的负载比例' },
	'ups.realpower': { label: '输出有功功率', unit: 'W', type: 'measured', desc: '设备实测有功功率' },
	'ups.realpower.nominal': { label: '额定有功功率', unit: 'W', type: 'reported', desc: '硬件设计最大有功功率容量' },
	'ups.power.nominal': { label: '额定视在功率', unit: 'VA', type: 'reported', desc: '硬件设计最大视在功率容量' },
	'ups.status': { label: '运行状态代码', unit: '', type: 'measured', desc: 'OL (市电在线), OB (电池供电), LB (低电量) 等' },
	'ups.temperature': { label: '设备内部温度', unit: '°C', type: 'measured', desc: '逆变器或机箱内部测温传感值' },
	'ups.mfr': { label: 'UPS 厂商名称', unit: '', type: 'reported', desc: 'UPS 协议返回的制造商字符串' },
	'ups.model': { label: 'UPS 型号名称', unit: '', type: 'reported', desc: 'UPS 协议返回的型号字符串' },
	'ups.serial': { label: 'UPS 硬件序号', unit: '', type: 'reported', desc: 'UPS 固件返回的序列号' },
	'ups.beeper.status': { label: '蜂鸣器状态', unit: '', type: 'reported', desc: 'enabled (启用) / disabled (静音)' },
	'ups.test.result': { label: '最近自检结果', unit: '', type: 'reported', desc: '自检执行状态 (Done and passed, etc)' }
};

return view.extend({
	rawResult: null,

	load: function() {
		return callGetRawData();
	},

	render: function(res) {
		var self = this;
		self.rawResult = res;

		var container = E('div', { 'class': 'cbi-map' }, [
			E('h2', { 'class': 'cbi-map-title' }, _('UPS 设备能力识别与原始映射')),
			E('div', { 'class': 'cbi-map-descr' }, _('通过 NUT upsc 协议读取底层设备所有暴露字段，建立规范的能力映射字典。只读审计模式，绝不向 UPS 发送任何危险控制指令。'))
		]);

		var actionBar = E('div', { 'style': 'margin-bottom:1rem;display:flex;gap:0.75rem;justify-content:flex-end;' }, [
			E('button', {
				'class': 'cbi-button cbi-button-action',
				'click': function() {
					self.exportJson();
				}
			}, _('导出能力报告 (JSON)')),
			E('button', {
				'class': 'cbi-button cbi-button-neutral',
				'click': function() {
					self.exportRawText();
				}
			}, _('导出 NUT 原始文本 (Raw)'))
		]);

		var table = E('table', { 'class': 'table cbi-section-table', 'style': 'width:100%;' }, [
			E('thead', {}, [
				E('tr', { 'class': 'tr cbi-section-table-titles' }, [
					E('th', { 'class': 'th', 'style': 'width:25%;' }, _('NUT 原始字段')),
					E('th', { 'class': 'th', 'style': 'width:18%;' }, _('原始值')),
					E('th', { 'class': 'th', 'style': 'width:20%;' }, _('中文释义与单位')),
					E('th', { 'class': 'th', 'style': 'width:15%;' }, _('数据属性分类')),
					E('th', { 'class': 'th', 'style': 'width:22%;' }, _('说明'))
				])
			]),
			E('tbody', { 'id': 'capability-table-body' }, self.renderRows(res))
		]);

		dom.append(container, [actionBar, table]);
		return container;
	},

	renderRows: function(res) {
		if (!res || !res.success || !res.fields) {
			return [
				E('tr', {}, [
					E('td', { 'colspan': '5', 'style': 'text-align:center;color:#ef4444;padding:2rem;' },
						_('未能成功读取 UPS 原始字段，原因: ') + (res ? res.error : _('通信未就绪'))
					)
				])
			];
		}

		var keys = Object.keys(res.fields).sort();
		if (keys.length === 0) {
			return [
				E('tr', {}, [
					E('td', { 'colspan': '5', 'style': 'text-align:center;padding:2rem;' }, _('未检测到任何字段数据'))
				])
			];
		}

		var rows = [];
		for (var i = 0; i < keys.length; i++) {
			var k = keys[i];
			var v = res.fields[k];
			var meta = NUT_DICT[k] || { label: k, unit: '', type: 'custom', desc: _('扩展/未收录自定义字段') };

			var tagClass = 'cbi-button-neutral';
			var tagLabel = _('设备报告');
			if (meta.type === 'measured') {
				tagClass = 'cbi-button-apply';
				tagLabel = _('传感器实测');
			} else if (meta.type === 'system') {
				tagClass = 'cbi-button-action';
				tagLabel = _('系统/驱动');
			}

			rows.push(E('tr', { 'class': 'tr cbi-section-table-row' }, [
				E('td', { 'class': 'td', 'style': 'font-family:monospace;font-weight:600;' }, k),
				E('td', { 'class': 'td', 'style': 'font-family:monospace;color:#2563eb;' }, v),
				E('td', { 'class': 'td' }, [
					meta.label,
					meta.unit ? E('span', { 'style': 'color:#64748b;margin-left:4px;' }, '(' + meta.unit + ')') : ''
				]),
				E('td', { 'class': 'td' }, [
					E('span', { 'class': 'cbi-button ' + tagClass, 'style': 'padding:2px 8px;font-size:0.75rem;cursor:default;' }, tagLabel)
				]),
				E('td', { 'class': 'td', 'style': 'color:#64748b;font-size:0.85rem;' }, meta.desc)
			]));
		}

		return rows;
	},

	exportJson: function() {
		var content = JSON.stringify(this.rawResult, null, 2);
		var blob = new Blob([content], { type: 'application/json' });
		var url = URL.createObjectURL(blob);
		var a = document.createElement('a');
		a.href = url;
		a.download = 'ups_capability_report_' + Math.floor(Date.now() / 1000) + '.json';
		a.click();
		URL.revokeObjectURL(url);
	},

	exportRawText: function() {
		if (!this.rawResult || !this.rawResult.fields) return;
		var lines = [];
		var keys = Object.keys(this.rawResult.fields).sort();
		for (var i = 0; i < keys.length; i++) {
			lines.push(keys[i] + ': ' + this.rawResult.fields[keys[i]]);
		}
		var content = lines.join('\n');
		var blob = new Blob([content], { type: 'text/plain' });
		var url = URL.createObjectURL(blob);
		var a = document.createElement('a');
		a.href = url;
		a.download = 'nut_raw_fields_' + Math.floor(Date.now() / 1000) + '.txt';
		a.click();
		URL.revokeObjectURL(url);
	}
});
