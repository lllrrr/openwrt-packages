'use strict';
'require view';
'require form';
'require rpc';
'require ui';

var callTestNotification = rpc.declare({
	object: 'luci.ups-manager',
	method: 'test_notification',
	expect: { '': {} }
});

return view.extend({
	render: function() {
		var m, s, o;

		m = new form.Map('ups_manager', _('事件告警与即时推送通知'),
			_('当市电停电、市电恢复、电池告警或通信中断时，通过微信、钉钉、飞书、Bark 等通道第一时间将告警推送到手机。'));

		s = m.section(form.NamedSection, 'notification', 'notification', _('通知渠道配置'));
		s.anonymous = true;

		o = s.option(form.Flag, 'enabled', _('启用消息通知推送'));
		o.default = '0';

		o = s.option(form.ListValue, 'channel', _('推送通道'));
		o.value('wechat', _('企业微信机器人 (WeChat Work Bot)'));
		o.value('dingtalk', _('钉钉自定义机器人 (DingTalk Bot)'));
		o.value('feishu', _('飞书自定义机器人 (Feishu Bot)'));
		o.value('bark', _('Bark (iOS 设备极简推送)'));
		o.value('serverchan', _('Server酱·Turbo (微信提醒)'));
		o.value('webhook', _('自定义 Webhook (通用 JSON POST)'));
		o.default = 'webhook';

		o = s.option(form.Value, 'webhook_url', _('Webhook 地址 / 推送 URL'));
		o.placeholder = 'https://oapi.dingtalk.com/robot/send?access_token=...';
		o.rmempty = false;

		o = s.option(form.Value, 'secret', _('加签密钥 / 访问 Token (选填)'));
		o.password = true; // Mask secret for security

		o = s.option(form.Value, 'repeat_interval', _('重复告警防抖间隔 (秒)'),
			_('相同类型的事件在此间隔内不会重复推送，避免消息轰炸。'));
		o.datatype = 'uinteger';
		o.default = '600';

		// Test push button
		o = s.option(form.Button, '_test_notify', _('推送测试'));
		o.inputtitle = _('发送测试告警消息');
		o.inputstyle = 'cbi-button-action';
		o.onclick = function() {
			ui.showModal(_('正在发送测试消息...'), [
				E('p', { 'class': 'spinning' }, _('正在调用后台通知通道，请稍候...'))
			]);

			return callTestNotification().then(function(res) {
				ui.hideModal();
				if (res && res.success) {
					ui.addNotification(null, E('p', {}, _('测试推送请求已发出，请检查您的手机或客户端是否收到通知。')), 'info');
				} else {
					ui.addNotification(null, E('p', {}, _('测试推送失败: ') + (res ? res.error : _('未响应'))), 'danger');
				}
			}).catch(function(err) {
				ui.hideModal();
				ui.addNotification(null, E('p', {}, _('调用异常: ') + (err.message || err)), 'danger');
			});
		};

		s = m.section(form.NamedSection, 'notification', 'notification', _('告警触发事件订阅'));
		s.anonymous = true;

		o = s.option(form.Flag, 'notify_on_battery', _('市电中断 (切换电池供电)'));
		o.default = '1';

		o = s.option(form.Flag, 'notify_on_online', _('市电恢复 (恢复正常电网供电)'));
		o.default = '1';

		o = s.option(form.Flag, 'notify_on_low_battery', _('蓄电池电量严重告急 (Low Battery)'));
		o.default = '1';

		o = s.option(form.Flag, 'notify_on_overload', _('UPS 负载过载告警'));
		o.default = '1';

		o = s.option(form.Flag, 'notify_on_comm_lost', _('UPS 通信丢失或恢复'));
		o.default = '1';

		return m.render();
	}
});
