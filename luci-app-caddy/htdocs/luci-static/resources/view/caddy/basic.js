'use strict';
'require form';
'require fs';
'require poll';
'require rpc';
'require uci';
'require ui';
'require view';

const callServiceList = rpc.declare({
	object: 'service',
	method: 'list',
	params: ['name'],
	expect: { '': {} }
});

const callCaddyStatus = rpc.declare({
	object: 'luci.caddy',
	method: 'get_status',
	expect: { '': {} }
});

const callValidateConfig = rpc.declare({
	object: 'luci.caddy',
	method: 'validate_config',
	expect: { '': {} }
});

function getServiceStatus() {
	return L.resolveDefault(callServiceList('caddy'), {}).then(res => {
		let isRunning = false;
		try {
			isRunning = res['caddy']['instances']['caddy']['running'];
		} catch (e) { }
		return isRunning;
	});
}

function renderStatus(isRunning, version, uptime, cpu, mem) {
	const spanTemp = '<em><span style="color:%s"><strong>%s %s</strong></span></em>';
	let renderHTML;
	if (isRunning) {
		renderHTML = spanTemp.format('green', _('Caddy'), _('RUNNING'));
		if (version) {
			renderHTML += '<br/>' + _('Version') + ': <span style="color:#CD853F;">' + version + '</span>';
		}
		if (uptime) {
			renderHTML += '<br/>' + _('Uptime') + ': <span style="color:#DA70D6;">' + uptime + '</span>';
		}
		if (cpu) {
			renderHTML += '&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;' + _('CPU') + ': <span style="color:#6A5ACD;">' + cpu + '</span>';
		}
		if (mem) {
			renderHTML += '&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;' + _('Memory') + ': <span style="color:#0000CD;">' + mem + '</span>';
		}
	} else {
		renderHTML = spanTemp.format('red', _('Caddy'), _('NOT RUNNING'));
	}
	return renderHTML;
}

return view.extend({
	load() {
		return Promise.all([
			L.resolveDefault(callCaddyStatus(), {}),
			uci.load('caddy')
		]);
	},

	handleRestart(ev) {
		return fs.exec('/etc/init.d/caddy', ['restart']).then(res => {
			ui.addNotification(null, E('p', _('Service restarted successfully.')), 'info');
		}).catch(err => {
			ui.addNotification(null, E('p', _('Failed to restart service: ') + err.message), 'error');
		});
	},

	handleValidate(ev) {
		return callValidateConfig().then(res => {
			let tb = document.getElementById('validate-status');
			if (tb) {
				let validate = res.validate || '';
				validate = validate.replace(/{"level":/g, '<br>{"level":')
					.replace(/Error/g, '<br>Error')
					.replace(/Valid configuration/g, '<br><strong><font color="#008000">Current configuration is correct!</font></strong>')
					.replace(/warn/g, '<font color="#800080">Warning</font>')
					.replace(/level/g, '<font color="#1E90FF">Level</font>')
					.replace(/info/g, '<font color="#00BFFF">Info</font>')
					.replace(/msg/g, '<font color="#FFA500">Message</font>')
					.replace(/error/g, '<font color="#DB7093">Error</font>')
					.replace(/Error:/g, '<font color="red"><strong>Configuration error!</strong><br>Error location:</font>');
				tb.innerHTML = '<br><font color="#FF00FF">Status:</font>' + '<font color="#2F4F4F">' + validate + '</font>';
			}
		});
	},

	handleFlushCache() {
		return fs.exec('/etc/init.d/caddy', ['restart']).then(res => {
			ui.addNotification(null, E('p', _('DNS Cache flushed successfully.')), 'info');
		});
	},

	render(data) {
		let m, s, o;
		const statusData = data[0] || {};
		const port = uci.get_first('caddy', 'caddy', 'port') || '12311';

		m = new form.Map('caddy', _('Caddy'),
			_('Caddy is a scalable server platform with automatic HTTPS, a fast and extensible multi-platform HTTP/1-2-3 web server.') +
			'<br/>' + _('Project URL') + ': <a href="https://github.com/caddyserver/caddy" target="_blank">github.com/caddyserver/caddy</a>&nbsp;&nbsp;' +
			_('Documentation') + ': <a href="https://caddyserver.com/docs/" target="_blank">caddyserver.com/docs/</a>');

		s = m.section(form.TypedSection);
		s.anonymous = true;
		s.render = () => {
			return E('div', { class: 'cbi-section', id: 'status_bar' }, [
				E('p', { id: 'service_status' }, renderStatus(
					statusData.running || false,
					statusData.version || '',
					statusData.uptime || '',
					statusData.cpu || '',
					statusData.mem || ''
				))
			]);
		};

		s = m.section(form.TypedSection, 'caddy');
		s.anonymous = true;

		s.tab('basic', _('Basic Options'));
		s.tab('advanced', _('Advanced Options'));
		s.tab('webdav', _('WebDAV'));

		o = s.taboption('basic', form.Flag, 'enabled', _('Enabled'));
		o.rmempty = false;
		o.default = o.disabled;

		o = s.taboption('basic', form.Button, '_restart', _('Restart'));
		o.title = '&#160;';
		o.inputtitle = _('Restart');
		o.inputstyle = 'apply';
		o.description = _('Quickly restart the service without modifying parameters.');
		o.onclick = L.bind(this.handleRestart, this);

		o = s.taboption('basic', form.ListValue, 'cmd', _('Startup Mode'),
			_('Use custom configuration file. If you do not understand the parameters, do not choose custom.'));
		o.value('default', _('Default'));
		o.value('custom', _('Custom'));
		o.default = 'default';

		o = s.taboption('basic', form.Value, 'port', _('Port'));
		o.datatype = 'and(port,min(1))';
		o.default = '12311';
		o.depends('cmd', 'default');

		o = s.taboption('basic', form.Flag, 'file_pass', _('Enable Authentication'));
		o.default = o.disabled;
		o.depends('cmd', 'default');

		o = s.taboption('basic', form.Value, 'file_username', _('Username'));
		o.datatype = 'string';
		o.default = 'admin';
		o.depends('file_pass', '1');

		o = s.taboption('basic', form.Value, 'file_password', _('Password'));
		o.datatype = 'string';
		o.password = true;
		o.default = '123456';
		o.depends('file_pass', '1');

		o = s.taboption('basic', form.Flag, 'filezip', _('Enable Compression'));
		o.default = o.disabled;
		o.depends('cmd', 'default');

		o = s.taboption('basic', form.Flag, 'log', _('Enable Log'));
		o.default = o.enabled;
		o.depends('cmd', 'default');

		o = s.taboption('basic', form.Value, 'log_dir', _('Log Path'),
			_('Log storage path. Provide full path with log filename.<br>Recommended: /tmp/ directory, e.g., /tmp/caddy/requests.log'));
		o.datatype = 'string';
		o.default = '/tmp/caddy/requests.log';
		o.depends('log', '1');

		o = s.taboption('advanced', form.Value, 'bin_dir', _('Binary Path'),
			_('Caddy binary storage path. Provide full path with caddy name.<br>Example: /usr/bin/caddy<br>Compile your own architecture binary: <a href="https://www.right.com.cn/forum/forum.php?mod=viewthread&tid=6006472&highlight=caddy" target="_blank">Compile Guide</a>'));
		o.datatype = 'string';
		o.placeholder = '/usr/bin/caddy';

		o = s.taboption('advanced', form.Value, 'data_dir', _('Document Root'),
			_('Path for web file access. Default: /mnt'));
		o.datatype = 'string';
		o.default = '/mnt';
		o.depends('cmd', 'default');

		o = s.taboption('advanced', form.Flag, 'api', _('Enable API'));
		o.default = o.disabled;
		o.depends('cmd', 'default');

		o = s.taboption('advanced', form.Button, '_validate', _('Validate Config'),
			_('Verify Caddyfile configuration. It simulates starting caddy but does not actually start it.'));
		o.title = '&#160;';
		o.inputtitle = _('Validate');
		o.inputstyle = 'apply';
		o.onclick = L.bind(this.handleValidate, this);

		o = s.taboption('advanced', form.DummyValue, '_validate_status', _('Validation Result'));
		o.cfgvalue = function() { return ''; };
		o.render = function() {
			return E('div', {}, [
				E('span', { id: 'validate-status' }, '')
			]);
		};

		o = s.taboption('advanced', form.Flag, 'allow_wan', _('Allow WAN Access'));
		o.rmempty = false;
		o.default = o.disabled;

		o = s.taboption('webdav', form.Flag, 'webdav', _('Enable WebDAV'));
		o.default = o.disabled;
		o.depends('cmd', 'default');

		o = s.taboption('webdav', form.Flag, 'webdav_pass', _('Enable Authentication'));
		o.default = o.disabled;
		o.depends('webdav', '1');

		o = s.taboption('webdav', form.Value, 'webdav_username', _('Username'));
		o.datatype = 'string';
		o.default = 'admin';
		o.depends('webdav_pass', '1');

		o = s.taboption('webdav', form.Value, 'webdav_password', _('Password'));
		o.datatype = 'string';
		o.password = true;
		o.default = '123456';
		o.depends('webdav_pass', '1');

		o = s.taboption('webdav', form.Value, 'webdav_port', _('WebDAV Port'));
		o.datatype = 'and(port,min(1))';
		o.default = '12322';
		o.depends('webdav', '1');

		o = s.taboption('webdav', form.Flag, 'webzip', _('Enable Compression'));
		o.default = o.disabled;
		o.depends('webdav', '1');

		o = s.taboption('webdav', form.Value, 'webdav_data_dir', _('WebDAV Document Root'),
			_('Path for WebDAV file access. Default: /mnt<br>Connection URL must add /dav suffix, e.g., 192.168.1.1:12311/dav'));
		o.datatype = 'string';
		o.default = '/mnt';
		o.depends('webdav', '1');

		o = s.taboption('advanced', form.TextValue, '_caddyfile', _('Caddyfile Configuration'),
			_('This is the Caddy startup configuration file at /etc/caddy/Caddyfile.<br>Command used: caddy run --config /etc/caddy/Caddyfile --adapter caddyfile<br>To set password, cannot use plain text, need to convert.<br>Convert command: $(uci -q get caddy.@caddy[0].bin_dir) hash-password --plaintext newpassword'));
		o.rows = 25;
		o.depends('cmd', 'custom');
		o.cfgvalue = section_id => fs.trimmed('/etc/caddy/Caddyfile').catch(e => '');
		o.write = function(section_id, formvalue) {
			return this.cfgvalue(section_id).then(value => {
				if (value === formvalue) return;
				return fs.write('/etc/caddy/Caddyfile',
					formvalue.trim().replace(/\r\n/g, '\n') + '\n');
			});
		};

		o = s.taboption('basic', form.Button, '_open_web', _('Web Interface'));
		o.title = '&#160;';
		o.inputtitle = _('Open Web Interface');
		o.inputstyle = 'apply';
		o.onclick = function() {
			window.open('http://' + window.location.hostname + ':' + port + '/');
		};

		return m.render();
	}
});
