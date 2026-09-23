'use strict';
'require view';
'require form';
'require ui';

return view.extend({
	render: function() {
		var m, s, o;

		m = new form.Map('ups_manager', _('断电保护与多设备联动关机'),
			_('当市电停电或蓄电池电量耗尽前，按优先级先后顺序安全关闭局域网 NAS、服务器，最后安全卸载并关闭路由器系统。'));

		s = m.section(form.NamedSection, 'shutdown', 'shutdown_policy', _('停机保护触发条件'));
		s.anonymous = true;

		o = s.option(form.Flag, 'enabled', _('启用自动停机保护'));
		o.default = '1';

		o = s.option(form.Value, 'battery_low_percent', _('触发停机的剩余电量 (%)'),
			_('当电池电量百分比小于或等于此值时，立即启动联动关机。'));
		o.datatype = 'uinteger';
		o.default = '20';

		o = s.option(form.Value, 'runtime_low_seconds', _('触发停机的预估续航 (秒)'),
			_('当预估放电续航时间小于此值时启动停机 (如 300 秒 = 5 分钟)。'));
		o.datatype = 'uinteger';
		o.default = '300';

		o = s.option(form.Value, 'on_battery_delay', _('持续断电时间上限 (秒)'),
			_('断电进入电池供电持续超过此秒数后触发关机。设为 0 表示不限制断电时长，仅依据电量/续航判断。'));
		o.datatype = 'uinteger';
		o.default = '600';

		s = m.section(form.NamedSection, 'shutdown', 'shutdown_policy', _('设备下线优先级与时序'));
		s.anonymous = true;

		o = s.option(form.Value, 'router_delay', _('路由器关机缓冲等待时间 (秒)'),
			_('发出从机停机广播后，本路由器等待此秒数（预留给局域网 NAS、PVE、物理机刷盘关机），再执行路由器自身关闭。'));
		o.datatype = 'uinteger';
		o.default = '180';

		o = s.option(form.Flag, 'shutdown_router', _('关闭路由器系统'));
		o.default = '1';

		// High risk option with confirmation
		o = s.option(form.Flag, 'poweroff_ups', _('最终关闭 UPS 输出电源 (危险选项)'),
			_('⚠️ 警告：勾选此项将在路由器停机瞬间向 UPS 发出切断负载电源指令。如果市电在此时恰好恢复，部分 UPS 可能会保持断电状态直至手动开机。家用及无人值守环境建议保持关闭！'));
		o.default = '0';

		return m.render();
	}
});
