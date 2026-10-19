'use strict';
'require view';
'require form';
'require uci';

return view.extend({
	render: function() {
		var m, s, o;

		m = new form.Map('shellcrash', _('ShellCrash 插件设置'),
			_('在此配置 ShellCrash 的目录位置、端口检测规则、Web 控制面板及延迟测试参数。'));

		s = m.section(form.NamedSection, 'main', 'shellcrash', _('基础设置'));
		s.anonymous = false;
		s.addremove = false;

		o = s.option(form.Value, 'crashdir', _('ShellCrash 安装目录'),
			_('留空表示自动识别 /etc/ShellCrash、/data/ShellCrash 或 /tmp/ShellCrash。'));
		o.placeholder = '/etc/ShellCrash';

		o = s.option(form.Value, 'api_port', _('Clash API 端口'),
			_('Clash/Mihomo RESTful API 监听端口，留空自动从 ShellCrash.cfg 或内核配置读取 (默认 9999)。'));
		o.datatype = 'port';
		o.placeholder = '9999';

		o = s.option(form.Value, 'mixed_port', _('HTTP/SOCKS 混合端口'),
			_('本地代理混合端口，留空自动读取 (默认 7890)。'));
		o.datatype = 'port';
		o.placeholder = '7890';

		o = s.option(form.Value, 'secret', _('API 密钥 (Secret)'),
			_('访问 Clash API 的鉴权 Secret，留空自动读取。'));
		o.password = true;

		o = s.option(form.ListValue, 'panel_type', _('默认 Web 控制面板类型'));
		o.value('zashboard', _('Zashboard (现代化响应式面板，推荐)'));
		o.value('metacubexd', _('Metacubexd (Clash Meta 官方面板)'));
		o.value('yacd', _('Yacd (经典轻量面板)'));
		o.default = 'zashboard';

		o = s.option(form.ListValue, 'panel_mode', _('面板访问模式'));
		o.value('auto', _('自动判断 (优先本地部署，无则远程 CDN)'));
		o.value('core', _('内核内置 external-ui (/ui/)'));
		o.value('local', _('LuCI 本地站点 (/zashboard/ 等)'));
		o.value('remote', _('在线 CDN 站点'));
		o.value('custom', _('自定义 URL'));
		o.default = 'auto';

		o = s.option(form.Value, 'remote_url', _('在线 CDN 站点 URL'),
			_('用于在线远程面板访问的基地址。'));
		o.default = 'https://board.zash.run.place/';
		o.depends('panel_mode', 'remote');
		o.depends('panel_mode', 'auto');

		o = s.option(form.Value, 'panel_url', _('自定义面板 URL'));
		o.depends('panel_mode', 'custom');

		o = s.option(form.Flag, 'panel_query', _('免登录自动填充参数'),
			_('跳转面板时自动在 URL 中追加 hostname、port 与 secret 参数，实现一键免登录直连。'));
		o.default = '1';

		o = s.option(form.Value, 'ping_targets', _('延迟测试目标列表'),
			_('格式为：名称|URL，多个以空格分隔。经内核混合端口测试分流后真延迟。'));
		o.default = '百度|https://www.baidu.com/ 谷歌|https://www.google.com/generate_204 GitHub|https://github.com/ YouTube|https://www.youtube.com/';

		o = s.option(form.Value, 'poll_interval', _('看板状态刷新频率 (秒)'));
		o.datatype = 'uinteger';
		o.default = '3';

		o = s.option(form.Value, 'log_lines', _('日志默认显示行数'));
		o.datatype = 'uinteger';
		o.default = '200';

		return m.render();
	}
});
