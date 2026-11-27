'use strict';
'require baseclass';
'require rpc';
'require request';
'require ui';

var callPrewarmRead = rpc.declare({
	object: 'luci.oxidns',
	method: 'prewarm_read',
	expect: {}
});

var callPrewarmSave = rpc.declare({
	object: 'luci.oxidns',
	method: 'prewarm_save',
	params: [ 'enabled', 'protocol', 'server', 'port', 'interval', 'content' ],
	expect: {}
});

var PREWARM_RUN_RPC = { object: 'luci.oxidns', method: 'prewarm_run' };

var BACKEND_ERRORS = {
	invalid_prewarm_settings: _('The prewarm port or interval is invalid.'),
	prewarm_failed: _('The prewarm operation failed.'),
	rpc_unavailable: _('The LuCI backend is unavailable.')
};

function field(id) {
	var node = document.getElementById(id);
	return node ? node.value : '';
}

function checked(id) {
	var node = document.getElementById(id);
	return !!(node && node.checked);
}

function row(label, input) {
	return E('div', { 'class': 'tr' }, [
		E('div', { 'class': 'td left', 'style': 'width: 240px' }, label),
		E('div', { 'class': 'td left' }, input)
	]);
}

function option(value, label, selected) {
	return E('option', {
		'value': value,
		'selected': selected ? 'selected' : null
	}, label || value);
}

function select(id, options, value) {
	return E('select', { 'id': id, 'class': 'cbi-input-select' },
		options.map(function(item) {
			return option(item[0], item[1], value === item[0]);
		}));
}

function textInput(id, value, describedBy) {
	var attrs = {
		'id': id,
		'class': 'cbi-input-text',
		'type': 'text',
		'inputmode': 'numeric',
		'value': value || ''
	};
	if (describedBy)
		attrs['aria-describedby'] = describedBy;

	return E('input', attrs);
}

function listTextarea(content) {
	var value = content || '';
	var textarea = E('textarea', {
		'id': 'oxidns-prewarm-content',
		'class': 'cbi-input-textarea',
		'rows': 20,
		'style': 'width: 100%; box-sizing: border-box; font-family: monospace;',
		'spellcheck': 'false'
	});
	textarea.defaultValue = value;
	textarea.value = value;
	return textarea;
}

function description(id, text) {
	return E('div', {
		'id': id,
		'class': 'cbi-value-description'
	}, text);
}

function setStatus(message, danger) {
	var node = document.getElementById('oxidns-prewarm-status');
	if (!node)
		return;
	node.textContent = message || '';
	node.className = danger ? 'alert-message error' : 'alert-message info';
}

function backendMessage(err, fallback) {
	var code = err && err.code;
	if (code && BACKEND_ERRORS[code])
		return BACKEND_ERRORS[code];
	return fallback || _('Operation failed');
}

function focusModal() {
	window.setTimeout(function() {
		var modal = document.getElementById('modal') || document.querySelector('.modal');
		if (!modal)
			return;

		var target = modal.querySelector('[autofocus], button:not([disabled]), input:not([disabled]), select, textarea');
		if (target && typeof target.focus === 'function')
			target.focus();
	}, 0);
}

/* 每次调用自带 HTTP 超时，不修改 L.env.rpctimeout */
function callLongRpc(desc, seconds) {
	return new Promise(function(resolve, reject) {
		var msg = {
			jsonrpc: '2.0',
			id: 'oxidns-' + Date.now() + '-' + Math.floor(Math.random() * 1000000),
			method: 'call',
			params: [ rpc.getSessionID(), desc.object, desc.method, {} ]
		};
		var req = {
			object: desc.object,
			method: desc.method,
			expect: {},
			resolve: resolve,
			reject: reject
		};

		request.post(rpc.getBaseURL(), msg, {
			timeout: seconds * 1000,
			credentials: true
		}).then(function(res) {
			rpc.parseCallReply(req, res);
		}, function(err) {
			reject(err);
		});
	});
}

function numericField(id, fallback, min, max) {
	var raw = String(field(id) || '').trim();
	if (!/^[0-9]+$/.test(raw)) {
		setStatus(_('Enter a number between %d and %d.').format(min, max), true);
		return null;
	}

	var value = parseInt(raw, 10);
	if (isNaN(value) || value < min || value > max) {
		setStatus(_('Enter a number between %d and %d.').format(min, max), true);
		return null;
	}

	return value;
}

function savePrewarm() {
	/* RPC list 声明 enabled 为 boolean、port / interval 为 number，必须传对应类型 */
	var enabled = checked('oxidns-prewarm-enabled');
	var port = numericField('oxidns-prewarm-port', 5333, 1, 65535);
	if (port === null)
		return Promise.resolve();

	var interval = numericField('oxidns-prewarm-interval', 3000, 0, 86400);
	if (interval === null)
		return Promise.resolve();

	ui.showModal(_('OxiDNS'), [ E('p', {}, _('Saving prewarm settings...')) ]);
	focusModal();

	return Promise.resolve(callPrewarmSave(
		enabled,
		field('oxidns-prewarm-protocol') || 'udp',
		field('oxidns-prewarm-server') || '127.0.0.1',
		port,
		interval,
		field('oxidns-prewarm-content')
	)).then(function(result) {
		ui.hideModal();
		if (!result || result.ok === false) {
			setStatus(backendMessage(result, _('Failed to save prewarm settings')), true);
			return;
		}
		setStatus(_('Prewarm settings saved.'), false);
	}).catch(function(err) {
		ui.hideModal();
		setStatus(backendMessage(err, _('Failed to save prewarm settings')), true);
	});
}

function runPrewarm() {
	ui.showModal(_('OxiDNS'), [ E('p', {}, _('Warming up...')) ]);
	focusModal();

	return callLongRpc(PREWARM_RUN_RPC, 180).then(function(result) {
		ui.hideModal();
		if (!result || result.ok === false) {
			setStatus(backendMessage(result, _('Prewarm failed')), true);
			return;
		}
		setStatus(_('Prewarm completed.'), false);
	}).catch(function(err) {
		ui.hideModal();
		setStatus(backendMessage(err, _('Prewarm failed')), true);
	});
}

return baseclass.extend({
	load: function() {
		return Promise.resolve(callPrewarmRead()).catch(function(err) {
			console.warn('oxidns prewarm load:', err);
			return { ok: false, code: 'rpc_unavailable' };
		});
	},

	render: function(settings) {
		settings = settings || {};

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('Prewarm')),
			E('div', { 'class': 'cbi-map-descr' },
				_('Keep popular domains resolved so the first visit is fast. A and AAAA records are queried through the selected OxiDNS listener.')),
			E('div', { 'class': 'cbi-section' }, [
				E('div', { 'class': 'table cbi-section-table' }, [
					row(_('Enable prewarming'), E('div', {}, [
						E('input', {
							'id': 'oxidns-prewarm-enabled',
							'type': 'checkbox',
							'checked': settings.enabled !== false ? 'checked' : null
						})
					])),
					row(_('Prewarm list'), E('div', {}, [
						listTextarea(settings.content),
						description('oxidns-prewarm-content-description',
							_('One domain per line. Blank lines and lines starting with # are ignored. Changes apply on the next pass; use Run now to apply immediately.'))
					])),
					row(_('Protocol'), select('oxidns-prewarm-protocol', [
						[ 'udp', _('UDP') ],
						[ 'tcp', _('TCP') ]
					], settings.protocol || 'udp')),
					row(_('Server IP'), select('oxidns-prewarm-server', [
						[ '127.0.0.1', _('127.0.0.1 (local listener)') ],
						[ '192.168.1.1', _('192.168.1.1 (LAN address)') ]
					], settings.server || '127.0.0.1')),
					row(_('Port'), E('div', {}, [
						textInput('oxidns-prewarm-port', settings.port || '5333', 'oxidns-prewarm-port-description'),
						description('oxidns-prewarm-port-description',
							_('The selected server must be an OxiDNS listener with cache enabled.'))
					])),
					row(_('Interval (seconds)'), E('div', {}, [
						textInput('oxidns-prewarm-interval', settings.interval || '3000', 'oxidns-prewarm-interval-description'),
						description('oxidns-prewarm-interval-description',
							_('0 = run once at service start.'))
					]))
				]),
				E('div', { 'class': 'cbi-button-row' }, [
					E('button', {
						'type': 'button',
						'class': 'btn cbi-button cbi-button-positive',
						'click': function(ev) {
							ev.preventDefault();
							return savePrewarm();
						}
					}, _('Save Settings')),
					' ',
					E('button', {
						'type': 'button',
						'class': 'btn cbi-button cbi-button-neutral',
						'click': function(ev) {
							ev.preventDefault();
							return runPrewarm();
						}
					}, _('Run now'))
				]),
				E('div', {
					'id': 'oxidns-prewarm-status',
					'aria-live': 'polite',
					'style': 'margin-top: 1em;'
				})
			])
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
