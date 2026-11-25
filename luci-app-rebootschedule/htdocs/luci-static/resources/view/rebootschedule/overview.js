'use strict';
'require view';
'require form';
'require fs';

return view.extend({
	handleReboot: function() {
		if (!confirm(_('确定现在重启？所有连接都会断开。')))
			return;

		return fs.exec('/sbin/reboot').then(function() {
			ui.addNotification(null, E('p', _('重启命令已下发。')), 'info');
		}).catch(function(err) {
			ui.addNotification(null, E('p', _('重启失败：%s').format(err.message)), 'danger');
		});
	},

	render: function() {
		var m, s, o;

		m = new form.Map('rebootschedule', _('定时重启'),
			_('按计划自动重启本设备。服务每 20 秒重读一次配置，改完即时生效，无需重启服务。'));

		s = m.section(form.NamedSection, 'settings', 'reboot', _('触发规则'));
		s.addremove = false;
		s.anonymous = true;

		o = s.option(form.Flag, 'enabled', _('启用'));
		o.default = '0';
		o.rmempty = false;

		o = s.option(form.ListValue, 'mode', _('触发方式'));
		o.value('daily', _('每天定时'));
		o.value('weekly', _('指定星期几'));
		o.value('interval', _('按开机时长'));
		o.default = 'daily';
		o.depends('enabled', '1');

		o = s.option(form.Value, 'time', _('重启时间'),
			_('24 小时制，例如 03:30'));
		o.default = '03:30';
		o.placeholder = '03:30';
		o.depends('mode', 'daily');
		o.depends('mode', 'weekly');
		o.validate = function(section_id, value) {
			if (value == null || value === '')
				return _('必须填写重启时间');
			return /^([01][0-9]|2[0-3]):[0-5][0-9]$/.test(value)
				? true : _('时间格式不对，应为 HH:MM');
		};

		o = s.option(form.MultiValue, 'weekdays', _('星期'));
		o.value('1', _('周一'));
		o.value('2', _('周二'));
		o.value('3', _('周三'));
		o.value('4', _('周四'));
		o.value('5', _('周五'));
		o.value('6', _('周六'));
		o.value('0', _('周日'));
		o.default = '0 1 2 3 4 5 6';
		o.depends('mode', 'weekly');

		o = s.option(form.Value, 'hours', _('开机满多少小时'),
			_('连续运行达到这个小时数后重启一次'));
		o.datatype = 'range(1,8760)';
		o.default = '24';
		o.depends('mode', 'interval');

		s = m.section(form.NamedSection, 'settings', 'reboot', _('操作'));
		s.addremove = false;
		s.anonymous = true;

		o = s.option(form.Button, '_rebootnow', _('立即重启'));
		o.inputtitle = _('重启');
		o.inputstyle = 'negative';
		o.onclick = this.handleReboot.bind(this);

		return m.render();
	}
});
