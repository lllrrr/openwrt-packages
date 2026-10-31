'use strict';
'require view';
'require rpc';
'require ui';
'require dom';
'require uci';

// 引入样式表, 与其它视图共用, 通过 id 去重
if (!document.getElementById('chfs-stylesheet')) {
	document.querySelector('head').appendChild(
		E('link', {
			'id': 'chfs-stylesheet',
			'rel': 'stylesheet',
			'href': L.resource('view/chfs/chfs.css')
		})
	);
}

var callStatus = rpc.declare({
	object: 'luci.chfs',
	method: 'status',
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

// 生成一行键值展示
function kv(label, value, mono) {
	return E('div', { 'class': 'chfs-kv' }, [
		E('span', { 'class': 'chfs-kv-key' }, label),
		E('span', { 'class': 'chfs-kv-val' + (mono ? ' chfs-mono' : '') }, value)
	]);
}

return view.extend({
	load: function() {
		return Promise.all([
			callStatus().catch(function() { return null; }),
			callProbeListen().catch(function() { return null; }),
			callProbeWebdav().catch(function() { return null; }),
			callReadIni().catch(function() { return null; })
		]);
	},

	render: function(data) {
		var st = data[0] || {};
		var listen = data[1] || {};
		var dav = data[2] || {};
		var ini = data[3] || {};
		var self = this;

		var container = E('div', { 'class': 'cbi-map chfs-status-page' }, [
			E('h2', {}, _('chfs Service Status')),
			E('div', { 'class': 'cbi-map-descr' },
				_('Data on this page is obtained by live probing and reflects the real running state of the service.'))
		]);

		// ------------------------------------------------------------------
		// 进程状态
		// ------------------------------------------------------------------
		var procCard = E('div', { 'class': 'chfs-card' }, [
			E('h3', {}, _('Process information')),
			kv(_('Running status'), st.running ? _('Running') : _('Stopped')),
			kv(_('Start on boot'), st.enabled ? _('Enabled') : _('Disabled')),
			st.pid ? kv(_('PID'), st.pid, true) : '',
			st.mem_mb ? kv(_('Memory usage'), st.mem_mb + ' MB') : '',
			kv(_('Program file'), st.binary_ok ? _('Present') : _('Missing (/usr/bin/chfs)')),
			kv(_('Configuration file'), st.ini_exists ? _('Generated (/var/etc/chfs.ini)') : _('Not generated'))
		]);

		if (st.port_mismatch)
			procCard.appendChild(E('div', { 'class': 'chfs-alert chfs-alert-warn' },
				_('The configured port differs from the running instance. Please restart the service.')));

		container.appendChild(procCard);

		// ------------------------------------------------------------------
		// 端口监听
		// ------------------------------------------------------------------
		var portValue = listen.port || st.port || '-';
		var listenText = listen.listening ? _('Listening') : _('Not listening');

		container.appendChild(E('div', { 'class': 'chfs-card' }, [
			E('h3', {}, _('Port listening')),
			kv(_('Configured port'), String(portValue), true),
			kv(_('Listen status'), listenText)
		]));

		// ------------------------------------------------------------------
		// WebDAV 探测结果
		// ------------------------------------------------------------------
		var davStatus;
		if (dav.available)
			davStatus = E('span', { 'class': 'cbi-label label-success' }, _('Available'));
		else if (!st.running)
			davStatus = E('span', { 'class': 'cbi-label label-secondary' }, _('Service is not running, cannot probe'));
		else
			davStatus = E('span', { 'class': 'cbi-label label-danger' }, _('Unavailable'));

		var davCard = E('div', { 'class': 'chfs-card' }, [
			E('h3', {}, _('WebDAV access')),
			E('div', { 'class': 'chfs-kv' }, [
				E('span', { 'class': 'chfs-kv-key' }, _('Probe result')),
				E('span', { 'class': 'chfs-kv-val' }, davStatus)
			]),
			dav.http_code ? kv(_('HTTP status code'), dav.http_code, true) : '',
			kv(_('Access protocol'), (dav.scheme || 'http').toUpperCase(), true),
			kv(_('Access address'), dav.url || '-', true),
			E('p', { 'class': 'chfs-note' },
				_('Since version 1.10 chfs supports WebDAV by default. It shares the same port, the same account rules and the same IP allowlist as HTTP, with no extra switch. Replace <host> in the address with the actual IP or domain of the router.')),
			dav.msg ? E('p', { 'class': 'chfs-note' }, dav.msg) : '',
			dav.tip ? E('p', { 'class': 'chfs-note chfs-note-warn' }, dav.tip) : ''
		]);

		// 复制地址按钮: 使用剪贴板 API, 不可用时降级为选中提示
		var copyBtn = E('button', {
			'type': 'button',
			'class': 'btn cbi-button',
			'click': function(ev) {
				ev.preventDefault();
				var full = (dav.scheme || 'http') + '://' + (window.location.hostname || '') +
					':' + (dav.port || '') + '/webdav';

				var done = function() {
					ui.addNotification(null, E('p', {}, _('Address copied') + ': ' + full), 'info');
				};

				if (navigator.clipboard && navigator.clipboard.writeText) {
					navigator.clipboard.writeText(full).then(done, function() {
						ui.addNotification(null, E('p', {}, full), 'info');
					});
				}
				else {
					ui.addNotification(null, E('p', {}, _('Please copy manually') + ': ' + full), 'info');
				}
			}
		}, _('Copy WebDAV address'));

		davCard.appendChild(E('div', { 'class': 'chfs-actions' }, [ copyBtn ]));
		container.appendChild(davCard);

		// ------------------------------------------------------------------
		// 生成的配置文件
		// ------------------------------------------------------------------
		var iniCard = E('div', { 'class': 'chfs-card' }, [
			E('h3', {}, _('Generated configuration file')),
			E('p', { 'class': 'chfs-note' },
				_('The following is the actual chfs.ini read by the service (located at /var/etc/chfs.ini), rendered automatically from the UCI configuration.'))
		]);

		if (ini.ok && ini.content)
			iniCard.appendChild(E('pre', { 'class': 'chfs-pre' }, ini.content));
		else
			iniCard.appendChild(E('p', { 'class': 'chfs-note' },
				ini.msg || _('The configuration file has not been generated yet. Start the service once first.')));

		container.appendChild(iniCard);

		// ------------------------------------------------------------------
		// 刷新按钮
		// ------------------------------------------------------------------
		container.appendChild(E('div', { 'class': 'chfs-actions' }, [
			E('button', {
				'type': 'button',
				'class': 'btn cbi-button cbi-button-action',
				'click': function(ev) {
					ev.preventDefault();
					location.reload();
				}
			}, _('Refresh status'))
		]));

		return container;
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
