'use strict';
'require view';
'require form';
'require uci';
'require rpc';
'require ui';
'require dom';

// 引入样式表
// LuCI 中 JS 视图加载自定义 CSS 的官方做法是通过 L.resource() 拼接静态资源
// 路径后插入 link 元素。L.resource() 会自动加上 /luci-static/resources/ 前缀。
// 加 id 防止视图重复渲染时重复插入。
if (!document.getElementById('chfs-stylesheet')) {
	document.querySelector('head').appendChild(
		E('link', {
			'id': 'chfs-stylesheet',
			'rel': 'stylesheet',
			'href': L.resource('view/chfs/chfs.css')
		})
	);
}

// rpcd ucode 后端声明的接口
var callStatus = rpc.declare({
	object: 'luci.chfs',
	method: 'status',
	expect: {}
});

var callInitAction = rpc.declare({
	object: 'luci.chfs',
	method: 'init_action',
	params: [ 'action' ],
	expect: {}
});

var callProbeListen = rpc.declare({
	object: 'luci.chfs',
	method: 'probe_listen',
	expect: {}
});

var callProbeWebdav = rpc.declare({
	object: 'luci.chfs',
	method: 'probe_webdav',
	expect: {}
});

var callReadIni = rpc.declare({
	object: 'luci.chfs',
	method: 'read_ini',
	expect: {}
});

// 服务状态标签的颜色语义: 依据运行状态与启用状态共同判定
function statusBadge(st) {
	var label, cls;

	if (!st.binary_ok) {
		label = _('chfs binary not installed');
		cls = 'label-danger';
	}
	else if (st.running) {
		label = _('Running');
		cls = 'label-success';
	}
	else if (st.enabled) {
		label = _('Enabled but not running');
		cls = 'label-warning';
	}
	else {
		label = _('Stopped');
		cls = 'label-secondary';
	}

	return E('span', { 'class': 'cbi-label ' + cls }, label);
}

	return view.extend({
	load: function() {
		return Promise.all([
			uci.load('chfs'),
			callStatus().catch(function() { return { running: false, binary_ok: false }; })
		]);
	},

	render: function(data) {
		var st = data[1] || {};
		var m, s, o, self = this;

		// 服务运行中时「当前端口」一律取真实生效值, 而不是 UCI 配置值 ——
		// 改了端口但没重启时两者不同, 若各显示各的, 运行状态行与下面的 WebUI
		// 地址会互相矛盾 (一个显示新配置, 一个显示实际监听)。不一致本身由
		// 下方的告警条负责说明, 这里只保证"描述正在运行的服务"的字段取真实值。
		var effPort = (st.running && st.ini_port) ? st.ini_port : (st.port || '8080');

		m = new form.Map('chfs', _('chfs File Sharing'),
			_('CuteHttpFileServer is an HTTP-based file sharing server. Use this page to configure the service; changes take effect after a restart.'));

		// ------------------------------------------------------------------
		// 服务状态卡片
		// ------------------------------------------------------------------
		s = m.section(form.NamedSection, 'main', 'chfs');
		s.anonymous = true;
		s.addremove = false;

		o = s.option(form.DummyValue, '_status', _('Running status'));
		o.rawhtml = true;
		o.cfgvalue = function() {
			return E('div', { 'class': 'chfs-status-line' }, [
				statusBadge(st),
				st.pid ? E('span', { 'class': 'chfs-meta' }, _('PID') + ': ' + st.pid) : '',
				st.mem_mb ? E('span', { 'class': 'chfs-meta' }, _('Memory usage') + ': ' + st.mem_mb + ' MB') : '',
				st.port ? E('span', { 'class': 'chfs-meta' }, _('Port') + ': ' + effPort) : ''
			]);
		};

		if (st.port_mismatch) {
			o = s.option(form.DummyValue, '_mismatch', '');
			o.rawhtml = true;
			o.cfgvalue = function() {
				return E('div', { 'class': 'chfs-alert chfs-alert-warn' },
					_('The port setting has changed but the service has not been restarted; the old configuration is still active. Restart the service to apply it.'));
			};
		}

		o = s.option(form.DummyValue, '_control', _('Service control'));
		o.rawhtml = true;
		o.cfgvalue = function() {
			var wrap = E('div', { 'class': 'chfs-actions' });

			var mk = function(action, label, style) {
				var btn = E('button', {
					'type': 'button',
					'class': 'btn cbi-button ' + (style || 'cbi-button-action'),
					'click': function(ev) {
						ev.preventDefault();
						return self.handleServiceAction(action,
							_('Service action') + ': ' + label + ' ' + _('Success'));
					}
				}, label);

				if (!st.binary_ok)
					btn.disabled = true;

				return btn;
			};

			// 运行中才允许停止与重启, 未运行时才允许启动
			wrap.appendChild(mk('start', _('Start'), st.running ? 'cbi-button-neutral' : 'cbi-button-action'));
			wrap.appendChild(mk('stop', _('Stop'), 'cbi-button-reset'));
			wrap.appendChild(mk('restart', _('Restart'), 'cbi-button-action'));

			// 服务未启用时, 启动会被后端拒绝, 此处给出说明
			if (!st.enabled)
				wrap.appendChild(E('span', { 'class': 'chfs-hint' },
					_('Note: the service is currently disabled. Save the configuration and tick "Enable service" first.')));

			return wrap;
		};

		// ------------------------------------------------------------------
		// WebUI 一键跳转
		//
		// 地址必须反映「当前真实生效」的协议与端口, 而不是 UCI 里的配置值:
		// 改了 port 或证书但没重启服务时, 两者并不一致, 按配置值拼出来的地址
		// 会打开一个没人监听的端口。真实值取自 /var/etc/chfs.ini
		// (后端 service_status 解析出的 st.ini_port / st.ini_https);
		// 仅在服务未运行时才退回配置值 —— 此时按钮本就禁用, 只作预览。
		//
		// 主机名用当前访问 LuCI 的 hostname, 而不是另配一份"设备地址"选项,
		// 从根源上避免两处地址不一致。
		// ------------------------------------------------------------------
		o = s.option(form.DummyValue, '_webui', _('WebUI access'));
		o.rawhtml = true;
		o.cfgvalue = function() {
			var running = !!st.running;
			var cfg_cert = uci.get('chfs', 'main', 'ssl_cert') || '';
			var cfg_key = uci.get('chfs', 'main', 'ssl_key') || '';

			var scheme = running
				? (st.ini_https ? 'https' : 'http')
				: ((cfg_cert !== '' && cfg_key !== '') ? 'https' : 'http');

			var host = window.location.hostname || '';
			// IPv6 字面量需要方括号; 部分浏览器返回时已带括号, 避免重复添加
			if (host.indexOf(':') >= 0 && host.charAt(0) !== '[')
				host = '[' + host + ']';

			// 端口直接用渲染期算好的 effPort, 与上方"运行状态"行同一来源,
			// 避免两处各算一遍后取值不一致。
			var url = scheme + '://' + host + ':' + effPort + '/';
			var usable = running && !!st.binary_ok;
			var wrap = E('div', { 'class': 'chfs-actions' });

			// 与其他自建按钮同一约定: cbi-button-action + type=button。
			// cbi-button-apply 会被 mint 主题接管成「保存并应用」, 点击只剩刷新;
			// 不声明 type 时默认 submit, 会被外层 <form> 提交掉。
			var open_btn = E('button', {
				'type': 'button',
				'class': 'btn cbi-button ' + (usable ? 'cbi-button-action' : 'cbi-button-neutral'),
				'title': url,
				'click': function(ev) {
					ev.preventDefault();
					window.open(url, '_blank', 'noopener');
					return false;
				}
			}, _('Open WebUI'));

			if (!usable)
				open_btn.disabled = true;

			wrap.appendChild(open_btn);
			wrap.appendChild(E('span', { 'class': 'chfs-meta chfs-mono' }, url));

			if (!usable)
				wrap.appendChild(E('span', { 'class': 'chfs-hint' },
					_('The service is not running; starting it will make the WebUI reachable at this address.')));

			return wrap;
		};

		// ------------------------------------------------------------------
		// 基本设置
		// ------------------------------------------------------------------
		o = s.option(form.Flag, 'enabled', _('Enable service'),
			_('When disabled the service will not start at boot and cannot be started from this page.'));

		o = s.option(form.Value, 'port', _('Listening port'),
			_('HTTP listening port, range 1-65535. Ports below 1024 require root privileges.'));
		o.datatype = 'port';
		o.placeholder = '8080';
		o.rmempty = false;
		o.validate = function(section_id, value) {
			var n = parseInt(value, 10);

			if (isNaN(n) || n < 1 || n > 65535)
				return _('Port must be an integer between 1 and 65535');

			if (n < 1024)
				return true;

			return true;
		};

		o = s.option(form.Value, 'path', _('Shared root directory'),
			_('Directories to share. Separate multiple directories with a vertical bar |, e.g. /mnt/sda1|/tmp/share. Leaving this empty prevents the service from starting.'));
		o.rmempty = false;
		o.placeholder = '/mnt/sda1';
		o.validate = function(section_id, value) {
			if (!value || value.trim() === '')
				return _('Shared root directory must not be empty');

			return true;
		};

		o = s.option(form.ListValue, 'run_as', _('Run as user'),
			_('Running as a non-root user is recommended to reduce risk. Ensure that user has proper read/write permissions on the shared directories.'));
		o.value('root', _('root (full privileges)'));
		o.value('nobody', _('nobody (restricted privileges)'));
		o.default = 'root';

		// ------------------------------------------------------------------
		// 访问控制
		// ------------------------------------------------------------------
		o = s.option(form.Flag, 'anonymous', _('Allow anonymous access'),
			_('When enabled, unauthenticated users access as the guest account with the rules configured for guest.'));

		o = s.option(form.Value, 'allow', _('IP allowlist'),
			_('Only allow access from the listed addresses. Leave empty for no restriction. Single addresses such as 192.168.1.10 and subnets such as 192.168.1.0/24 are supported; separate multiple entries with a vertical bar |.'));
		o.placeholder = '192.168.1.0/24|10.0.0.5';
		o.validate = function(section_id, value) {
			if (!value || value.trim() === '')
				return true;

			var parts = value.split('|');
			var re = /^[0-9a-fA-F:.]+$/;

			for (var i = 0; i < parts.length; i++) {
				var p = parts[i].trim();
				if (p !== '' && !re.test(p))
					return _('Invalid IP rule format') + ': ' + p;
			}

			return true;
		};

		// ------------------------------------------------------------------
		// 功能选项
		// ------------------------------------------------------------------
		o = s.option(form.ListValue, 'folder_download', _('Directory download policy'),
			_('Controls whether whole directories may be downloaded as archives.'));
		o.value('enable', _('Allow (unrestricted)'));
		o.value('leaf', _('Leaf directories only'));
		o.value('disable', _('Disable directory download'));
		o.default = 'enable';

		o = s.option(form.ListValue, 'file_remove', _('File removal method'),
			_('Strategy applied when deleting files.'));
		o.value('1', _('Move to system trash'));
		o.value('2', _('Move to chfs trash bin (~/.chfs_trashbin)'));
		o.value('3', _('Delete permanently'));
		o.default = '1';

		o = s.option(form.Value, 'session_timeout', _('Session timeout'),
			_('Validity period of a login session in minutes, range 1-1440.'));
		o.datatype = 'range(1,1440)';
		o.placeholder = '30';
		o.default = '30';

		o = s.option(form.Flag, 'image_preview', _('Enable image thumbnails'),
			_('Show thumbnails for image files in the web UI. Enabling this increases server-side computation overhead.'));

		// ------------------------------------------------------------------
		// 日志
		// ------------------------------------------------------------------
		o = s.option(form.Value, 'log_path', _('Operation log directory'),
			_('Directory for user operation logs. Leave empty to disable logging.'));
		o.placeholder = '/var/log/chfs';
		o.depends('enabled', '1');

		o = s.option(form.Flag, 'syslog', _('Output to syslog'),
			_('Redirect service stdout to syslog, viewable via logread.'));

		// ------------------------------------------------------------------
		// 页面外观
		// ------------------------------------------------------------------
		o = s.option(form.Value, 'html_title', _('Page title'));
		o.placeholder = 'chfs 文件共享';

		o = s.option(form.TextValue, 'html_notice', _('Page notice'),
			_('Notice shown at the top of the page. Plain text, or an HTML fragment wrapped in backticks.'));
		o.rows = 3;
		o.placeholder = '内部资料, 请勿外传';

		// ------------------------------------------------------------------
		// HTTPS
		// ------------------------------------------------------------------
		o = s.option(form.Value, 'ssl_cert', _('HTTPS certificate path'),
			_('Path to the certificate file. Both certificate and private key must be set to enable HTTPS; the listening port is normally 443 then.'));
		o.placeholder = '/etc/chfs/server.crt';

		o = s.option(form.Value, 'ssl_key', _('HTTPS private key path'),
			_('Path to the private key file. Must be used together with the certificate.'));
		o.placeholder = '/etc/chfs/server.key';

		return m.render();
	},

	// LuCI 保存流程:
	//   mode '0' 表示仅保存到 UCI, 不重启服务
	//   mode '1' 表示保存并应用, 需要重启服务使配置生效
	// 不可覆盖为强制重启, 否则"仅保存"按钮会失去意义。
	handleSaveApply: function(ev, mode) {
		var self = this;

		return this.handleSave(ev).then(function() {
			if (mode === '1')
				return self.handleServiceAction('restart', _('Configuration saved, service restarted'));

			ui.addNotification(null,
				E('p', {}, _('Configuration saved. Changes take effect after restarting the service.')), 'info');

			return;
		});
	},

	handleServiceAction: function(action, successMsg) {
		ui.showModal(_('Please wait'), [
			E('p', { 'class': 'spinning' }, _('Executing %s ...').format(action))
		]);

		return callInitAction(action).then(function(res) {
			ui.hideModal();

			if (res && res.ok) {
				ui.addNotification(null, E('p', {}, successMsg || _('Operation succeeded')), 'info');
				window.setTimeout(function() { location.reload(); }, 1200);
			}
			else {
				ui.addNotification(null,
					E('p', {}, _('Operation failed') + ': ' + ((res && res.msg) || _('Unknown error'))),
					'danger');
			}
		}).catch(function(e) {
			ui.hideModal();
			ui.addNotification(null, E('p', {}, _('Request failed') + ': ' + e), 'danger');
		});
	}
});
