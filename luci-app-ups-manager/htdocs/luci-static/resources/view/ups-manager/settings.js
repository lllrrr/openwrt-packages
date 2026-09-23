'use strict';
'require view';
'require form';
'require rpc';
'require ui';

var callScanDevices = rpc.declare({
	object: 'luci.ups-manager',
	method: 'scan_devices',
	expect: { '': {} }
});

var callTestConnection = rpc.declare({
	object: 'luci.ups-manager',
	method: 'test_connection',
	expect: { '': {} }
});

// Brand Presets Database
var BRAND_PRESETS = [
	{ id: 'cyberpower_usb', name: 'CyberPower (硕天) - USB-HID (推荐)', driver: 'usbhid-ups', port: 'auto', desc: 'CyberPower USB-HID UPS', baud: '' },
	{ id: 'apc_usb', name: 'APC / 施耐德 - USB-HID (Back-UPS等)', driver: 'usbhid-ups', port: 'auto', desc: 'APC USB-HID UPS', baud: '' },
	{ id: 'apc_serial', name: 'APC - Smart-UPS 串口 (940-0024C等)', driver: 'apcsmart', port: '/dev/ttyS0', desc: 'APC Smart Serial', baud: '2400' },
	{ id: 'santak_usb', name: 'Santak (山特) - TG/MT/城堡 USB (Megatec)', driver: 'blazer_usb', port: 'auto', desc: 'Santak Megatec USB', baud: '' },
	{ id: 'santak_serial', name: 'Santak (山特) / 科华 - RS232 串口', driver: 'blazer_ser', port: '/dev/ttyUSB0', desc: 'Megatec RS232 Serial', baud: '2400' },
	{ id: 'eaton_usb', name: 'Eaton (伊顿) - USB-HID (Ellipse等)', driver: 'usbhid-ups', port: 'auto', desc: 'Eaton USB-HID', baud: '' },
	{ id: 'powercom_usb', name: 'Powercom (保利金) - USB-HID', driver: 'usbhid-ups', port: 'auto', desc: 'Powercom USB', baud: '' },
	{ id: 'ladis_usb', name: 'Ladis (雷迪司) - USB 版 (Megatec)', driver: 'blazer_usb', port: 'auto', desc: 'Ladis Megatec USB', baud: '' },
	{ id: 'tripplite_usb', name: 'Tripp Lite - USB-HID', driver: 'usbhid-ups', port: 'auto', desc: 'Tripp Lite USB', baud: '' },
	{ id: 'snmp_net', name: '机房专业级 SNMP 网络监控卡 (IP直连)', driver: 'snmp-ups', port: '192.168.1.200', desc: 'Network SNMP Card', baud: '' }
];

return view.extend({
	render: function() {
		var m, s, o;

		m = new form.Map('ups_manager', _('UPS 电源管理 硬件与服务配置'),
			_('支持多厂商 UPS（硕天、APC、山特、伊顿、科华、雷迪司等）及 USB-HID、Megatec 串口协议。支持全自动智能识别与一键填入。'));

		// 1. Hardware scan & preset tools
		s = m.section(form.NamedSection, 'ups', 'ups', _('快速识别与多厂商预设'));
		s.anonymous = true;

		// Brand Presets Dropdown
		o = s.option(form.ListValue, '_preset_selector', _('常见 UPS 厂商配置预设'),
			_('选择预设后将自动填入对应的 NUT 驱动、端口与默认配置模板。'));
		o.value('', _('-- 选择知名品牌配置模板 --'));
		for (var i = 0; i < BRAND_PRESETS.length; i++) {
			o.value(BRAND_PRESETS[i].id, BRAND_PRESETS[i].name);
		}
		o.onchange = function(ev) {
			var val = ev.target.value;
			if (!val) return;
			var preset = BRAND_PRESETS.find(function(p) { return p.id === val; });
			if (!preset) return;

			var driverInput = document.querySelector('[name="cbid.ups_manager.ups.driver"]');
			var portInput = document.querySelector('[name="cbid.ups_manager.ups.port"]');
			var descInput = document.querySelector('[name="cbid.ups_manager.ups.desc"]');

			if (driverInput) driverInput.value = preset.driver;
			if (portInput) portInput.value = preset.port;
			if (descInput) descInput.value = preset.desc;

			ui.addNotification(null, E('p', {}, _('已为您应用 [') + preset.name + _('] 驱动预设，请保存并应用。')), 'info');
		};

		// Scan Button
		o = s.option(form.Button, '_scan', _('硬件智能扫描'));
		o.inputtitle = _('🔍 扫描物理硬件 (USB / 串口)');
		o.inputstyle = 'cbi-button-action';
		o.onclick = function() {
			ui.showModal(_('正在全总线扫描物理设备...'), [
				E('p', { 'class': 'spinning' }, _('正在枚举 /sys/bus/usb 与 /dev/tty* 串口设备，比对品牌签名库，请稍候...'))
			]);

			return callScanDevices().then(function(res) {
				ui.hideModal();
				var devices = (res && res.devices) ? res.devices : [];
				if (devices.length === 0) {
					ui.addNotification(null, E('p', {}, _('未检测到任何已连接的 USB 或串口设备。请检查物理接线，或确认虚拟机已添加 USB 直通。')), 'warning');
					return;
				}

				var listNodes = [];
				for (var i = 0; i < devices.length; i++) {
					var d = devices[i];
					var isMatch = d.is_ups === 1;
					listNodes.push(E('div', {
						'style': 'padding:0.85rem;border:1px solid ' + (isMatch ? '#10b981' : '#cbd5e1') + ';background:' + (isMatch ? 'rgba(16,185,129,0.05)' : '#ffffff') + ';border-radius:0.5rem;margin-bottom:0.75rem;display:flex;justify-content:space-between;align-items:center;gap:1rem;'
					}, [
						E('div', {}, [
							E('div', { 'style': 'font-weight:700;font-size:0.95rem;' }, [
								(d.manufacturer ? d.manufacturer + ' — ' : '') + (d.product || _('未知总线设备')),
								isMatch ? E('span', { 'style': 'background:#dcfce7;color:#15803d;padding:2px 8px;border-radius:4px;font-size:0.75rem;margin-left:8px;' }, '✓ ' + _('已匹配 UPS 签名')) : ''
							]),
							E('div', { 'style': 'color:#64748b;font-size:0.8rem;font-family:monospace;margin-top:0.25rem;' }, [
								'VID: ' + (d.vid || 'N/A') + ' | PID: ' + (d.pid || 'N/A') + (d.serial ? ' | S/N: ' + d.serial : '') + ' | 推荐驱动: ' + d.recommended_driver
							])
						]),
						E('button', {
							'class': 'cbi-button ' + (isMatch ? 'cbi-button-apply' : 'cbi-button-neutral'),
							'data-vid': d.vid,
							'data-pid': d.pid,
							'data-serial': d.serial,
							'data-driver': d.recommended_driver,
							'click': function(e) {
								var btn = e.target;
								var vid = btn.getAttribute('data-vid');
								var pid = btn.getAttribute('data-pid');
								var serial = btn.getAttribute('data-serial');
								var driver = btn.getAttribute('data-driver');

								if (vid) document.querySelector('[name="cbid.ups_manager.ups.vendorid"]').value = vid;
								if (pid) document.querySelector('[name="cbid.ups_manager.ups.productid"]').value = pid;
								if (serial) document.querySelector('[name="cbid.ups_manager.ups.serial"]').value = serial;
								if (driver) document.querySelector('[name="cbid.ups_manager.ups.driver"]').value = driver;

								ui.hideModal();
								ui.addNotification(null, E('p', {}, _('已成功填入扫描到的硬件参数与驱动，请点击底部【保存并应用】生效。')), 'info');
							}
						}, _('选用此设备'))
					]));
				}

				ui.showModal(_('扫描到的物理总线设备列表'), [
					E('div', { 'style': 'max-height:400px;overflow-y:auto;' }, listNodes),
					E('div', { 'class': 'right', 'style': 'margin-top:1rem;' }, [
						E('button', {
							'class': 'cbi-button cbi-button-neutral',
							'click': function() { ui.hideModal(); }
						}, _('关闭'))
					])
				]);
			}).catch(function(err) {
				ui.hideModal();
				ui.addNotification(null, E('p', {}, _('扫描异常: ') + (err.message || err)), 'danger');
			});
		};

		// Test connection button
		o = s.option(form.Button, '_test', _('通信连通性即时探测'));
		o.inputtitle = _('🔌 立即测试与 UPS 的通信');
		o.inputstyle = 'cbi-button-neutral';
		o.onclick = function() {
			ui.showModal(_('正在探测 UPS 实时通信...'), [
				E('p', { 'class': 'spinning' }, _('正在执行 upsc 通信链路探测，请稍候...'))
			]);

			return callTestConnection().then(function(res) {
				ui.hideModal();
				if (res && res.success) {
					ui.addNotification(null, E('p', {}, _('通信测试成功！检测到设备: ') + (res.model || _('就绪')) + ' (' + _('响应耗时') + ' ' + res.latency_sec + 's)'), 'info');
				} else {
					ui.addNotification(null, E('p', {}, _('通信测试失败: ') + (res ? res.error : _('未响应')) + _('。如果提示冲突，请在维护页面执行一键清理残留驱动。')), 'danger');
				}
			});
		};

		// 2. Hardware parameters
		s = m.section(form.NamedSection, 'ups', 'ups', _('底层驱动与通信参数'));
		s.anonymous = true;

		o = s.option(form.ListValue, 'driver', _('NUT 驱动程序'));
		o.value('usbhid-ups', _('usbhid-ups (通用 USB-HID: 硕天 CyberPower, APC, 山特USB等)'));
		o.value('blazer_usb', _('blazer_usb (USB Megatec 协议: 国产山特, 科华, 雷迪司等)'));
		o.value('blazer_ser', _('blazer_ser (RS-232 串口 Megatec 协议: 山特串口, 科华串口)'));
		o.value('apcsmart', _('apcsmart (APC Smart 串口协议)'));
		o.value('snmp-ups', _('snmp-ups (机房网络 SNMP 卡)'));
		o.value('riello_usb', _('riello_usb (理路 Riello USB)'));
		o.value('dummy-ups', _('dummy-ups (开发者调试仿真驱动)'));
		o.default = 'usbhid-ups';

		o = s.option(form.Value, 'port', _('通信端口 / 设备节点'));
		o.default = 'auto';
		o.placeholder = 'auto 或 /dev/ttyUSB0 或 192.168.1.x';

		o = s.option(form.Value, 'vendorid', _('USB VendorID (选填)'), _('如硕天为 0764，APC 为 051d，山特为 06da'));
		o.placeholder = '0764';

		o = s.option(form.Value, 'productid', _('USB ProductID (选填)'));
		o.placeholder = '0501';

		o = s.option(form.Value, 'nominal_power', _('额定有功功率 (W)'),
			_('当硬件未报告 realpower 时，系统使用 (额定功率 × 负载率) 计算。硕天 UT650EGC 建议填写 360，TG500 建议 300，1000VA 建议 600。'));
		o.datatype = 'uinteger';
		o.default = '360';

		o = s.option(form.Value, 'power_scale', _('功率校准系数 (微调倍率)'),
			_('用于修正 UPS 内部 ADC 粗粒度阶梯跳变造成的偏差。若实际功率低于估算值，可微调为 0.8 或 0.9。默认 1.0。'));
		o.datatype = 'ufloat';
		o.default = '1.0';

		// 3. Security
		s = m.section(form.NamedSection, 'nut_service', 'nut_service', _('NUT 服务与网络监听安全'));
		s.anonymous = true;

		o = s.option(form.Value, 'listen_address', _('监听网络 IP 地址'),
			_('🔒 严格安全防护：默认仅监听 127.0.0.1 回环地址。严禁配置 0.0.0.0 以免将控制端口暴露在 WAN 或公网。'));
		o.datatype = 'ip4addr';
		o.default = '127.0.0.1';

		o = s.option(form.Value, 'listen_port', _('服务监听端口'));
		o.datatype = 'port';
		o.default = '3493';

		return m.render();
	}
});
