'use strict';
'require baseclass';
'require rpc';
'require ui';
'require poll';

/*
 * DNS 劫持独立页（2026-11 从 overview.js 拆出）。
 *
 * 把局域网发往 53 端口的 DNS 请求（TCP/UDP、IPv4/IPv6）重定向到本机
 * OxiDNS 监听端口。目标端口可自动读 config.yaml 或手工指定，实现为 fw4
 * firewall redirect，路由器自身的查询不受影响。
 */

var callHijackGet = rpc.declare({
	object: 'luci.oxidns',
	method: 'hijack_get',
	expect: {}
});

var callHijackSave = rpc.declare({
	object: 'luci.oxidns',
	method: 'hijack_save',
	params: [ 'enabled', 'port_mode', 'port' ],
	expect: {}
});

var callStatus = rpc.declare({
	object: 'luci.oxidns',
	method: 'status',
	expect: {}
});

var BACKEND_ERRORS = {
	invalid_port_mode: _('The port mode must be automatic or manual.'),
	invalid_hijack_port: _('The hijack port must be a number between 1 and 65535.'),
	no_dns_listen: _('No usable DNS listener port was found.'),
	hijack_save_failed: _('Failed to save the DNS hijack settings.'),
	hijack_write_failed: _('Failed to write the firewall redirect.'),
	uci_unavailable: _('The UCI command is not available.')
};

var hijackState = {};
var statusState = {};
var dirty = false;
var viewRoot = null;
var pollFn = null;
var viewObserver = null;
var cleanupTasks = [];
var retryTimer = null;
var retryCount = 0;

function isAttached(node) {
	return !!(node && document.body && typeof document.body.contains === 'function' && document.body.contains(node));
}

function addCleanup(fn) {
	if (typeof fn === 'function' && cleanupTasks.indexOf(fn) < 0)
		cleanupTasks.push(fn);
}

function runCleanup() {
	var tasks = cleanupTasks.slice();
	cleanupTasks = [];

	for (var i = 0; i < tasks.length; i++) {
		try { tasks[i](); } catch (e) {}
	}
}

function watchView(root) {
	viewRoot = root || null;

	if (viewObserver) {
		try { viewObserver.disconnect(); } catch (e) {}
		viewObserver = null;
	}

	var vp = document.getElementById('view');
	if (!vp || typeof MutationObserver !== 'function')
		return;

	viewObserver = new MutationObserver(function() {
		if (viewRoot && !isAttached(viewRoot)) {
			try { viewObserver.disconnect(); } catch (e) {}
			viewObserver = null;
			runCleanup();
		}
	});
	viewObserver.observe(vp, { childList: true, subtree: false });
}

function unregisterPoll() {
	if (pollFn && typeof poll.remove === 'function')
		poll.remove(pollFn);
	pollFn = null;
}

function cancelRetry() {
	if (retryTimer !== null) {
		window.clearTimeout(retryTimer);
		retryTimer = null;
	}
	retryCount = 0;
}

function backendMessage(err, fallback) {
	var code = err && err.code;
	if (code && BACKEND_ERRORS[code])
		return BACKEND_ERRORS[code];
	return fallback || _('Operation failed');
}

function showRefreshError(message) {
	var node = document.getElementById('oxidns-hijack-error');
	if (!node)
		return;
	node.textContent = message || '';
	node.style.display = message ? 'block' : 'none';
}

function scheduleRetry() {
	cancelRetry();
	if (retryCount >= 4) {
		showRefreshError(_('Could not refresh DNS hijack status. Use Refresh to try again.'));
		return;
	}

	retryCount++;
	showRefreshError(_('Could not refresh DNS hijack status. Retrying...'));
	retryTimer = window.setTimeout(function() {
		retryTimer = null;
		if (isAttached(viewRoot))
			refreshAll();
	}, Math.min(30000, 1000 * Math.pow(2, retryCount)));
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

function valueOrDash(value) {
	if (value === null || value === undefined || value === '')
		return '-';
	return value;
}

function setNodeContent(node, value) {
	while (node.firstChild)
		node.removeChild(node.firstChild);

	if (value && value.nodeType)
		node.appendChild(value);
	else
		node.textContent = valueOrDash(value);
}

function renderRow(label, value, id) {
	var attrs = { 'class': 'td left' };
	if (id)
		attrs.id = id;

	return E('div', { 'class': 'tr' }, [
		E('div', { 'class': 'td left', 'style': 'width: 240px' }, label),
		E('div', attrs, valueOrDash(value))
	]);
}

function statusBadge(text, good) {
	return E('span', {
		'class': good ? 'label label-success' : 'label label-warning',
		'aria-live': 'polite'
	}, text);
}

function hijackStatusBadge(hijack) {
	return hijack && hijack.enabled ? statusBadge(_('Enabled'), true) : statusBadge(_('Disabled'), false);
}

function coreInstalled(status) {
	return !!(status && status.core && status.core.installed);
}

function hijackPortText(hijack) {
	var source = (hijack && hijack.port_mode === 'manual')
		? _('manual')
		: _('from config.yaml');

	if (!hijack || (hijack.udp_port == null && hijack.tcp_port == null))
		return _('No target port available (source: %s).').format(source);

	var ports;
	if (hijack.udp_port != null && hijack.udp_port === hijack.tcp_port)
		ports = _('port %s (TCP/UDP)').format(hijack.udp_port);
	else
		ports = _('UDP port %s, TCP port %s')
			.format(hijack.udp_port == null ? '-' : hijack.udp_port,
				hijack.tcp_port == null ? '-' : hijack.tcp_port);

	return _('%s, %s').format(source, ports);
}

function hijackSelectedMode() {
	var box = document.querySelector('input[name="oxidns-hijack-port-mode"]:checked');
	return (box && box.value === 'manual') ? 'manual' : 'auto';
}

function hijackPortInput() {
	return document.getElementById('oxidns-hijack-port');
}

// auto 时手填框禁用并置灰；manual 时才允许输入
function syncHijackPortInput() {
	var input = hijackPortInput();
	var description = document.getElementById('oxidns-hijack-port-description');

	if (input)
		input.disabled = (hijackSelectedMode() !== 'manual');

	if (description)
		description.textContent = (hijackSelectedMode() === 'manual')
			? _('Enter a port number between 1 and 65535.')
			: _('The port is read from config.yaml automatically.');

	markDirty();
}

function markDirty() {
	if (dirty)
		return;

	dirty = true;
	var hint = document.getElementById('oxidns-hijack-dirty');
	if (hint)
		hint.style.display = 'block';
}

function clearDirty() {
	dirty = false;

	var hint = document.getElementById('oxidns-hijack-dirty');
	if (hint)
		hint.style.display = 'none';
}

function setHijackStatus(message, danger) {
	var node = document.getElementById('oxidns-hijack-status');
	if (!node)
		return;
	node.textContent = message || '';
	node.className = danger ? 'alert-message error' : 'alert-message info';
}

/*
 * 轮询只更新只读的端口/规则段信息。用户一旦改动任何控件，enabled / 端口来源 /
 * radio / port 输入框都停止被远程结果覆盖，直到 Apply 或 Cancel。
 */
function applyHijackState(hijack, force) {
	hijack = hijack || {};

	if (!force && !dirty) {
		var box = document.getElementById('oxidns-hijack-enabled');
		if (box)
			box.checked = !!hijack.enabled;

		var mode = (hijack.port_mode === 'manual') ? 'manual' : 'auto';
		var autoBox = document.getElementById('oxidns-hijack-mode-auto');
		var manualBox = document.getElementById('oxidns-hijack-mode-manual');
		if (autoBox)
			autoBox.checked = (mode === 'auto');
		if (manualBox)
			manualBox.checked = (mode === 'manual');

		var input = hijackPortInput();
		if (input) {
			if (document.activeElement !== input) {
				var value = hijack.manual_port;
				if (value == null && hijack.udp_port != null)
					value = hijack.udp_port;
				input.value = (value == null) ? '' : String(value);
			}
			input.disabled = (mode !== 'manual');
		}

		var description = document.getElementById('oxidns-hijack-port-description');
		if (description)
			description.textContent = (mode === 'manual')
				? _('Enter a port number between 1 and 65535.')
				: _('The port is read from config.yaml automatically.');
	}

	setNodeContent(document.getElementById('oxidns-hijack-ports'), hijackPortText(hijack));
	setNodeContent(document.getElementById('oxidns-hijack-sections'), (hijack.sections || []).join(', '));
}

function refreshHijack() {
	return Promise.resolve(callHijackGet()).then(function(hijack) {
		if (!hijack || hijack.ok === false)
			throw hijack || { code: 'rpc_unavailable' };

		/* 保留最后一次成功状态，失败时不把表单清空 */
		hijackState = hijack;
		if (isAttached(viewRoot))
			applyHijackState(hijackState, false);
	}).catch(function(err) {
		showRefreshError(backendMessage(err, _('Could not refresh DNS hijack status.')));
		throw err;
	});
}

function refreshStatus() {
	return Promise.resolve(callStatus()).then(function(status) {
		if (!status || status.ok === false)
			throw status || { code: 'rpc_unavailable' };

		statusState = status;
		if (isAttached(viewRoot))
			updateHijackControls();
	}).catch(function(err) {
		showRefreshError(backendMessage(err, _('Could not refresh OxiDNS status.')));
		throw err;
	});
}

function refreshAll() {
	/* 不能在未挂载时自行 unregisterPoll：poll.add() 会立即 step 一次，
	 * 而那时 render 还没返回、map 不在 DOM 里，会把轮询自我删除。
	 * 卸载清理由 watchView → runCleanup → addCleanup 负责。 */
	if (!isAttached(viewRoot))
		return Promise.resolve();

	return Promise.all([ refreshStatus(), refreshHijack() ]).then(function() {
		cancelRetry();
		showRefreshError('');
	}).catch(function(err) {
		scheduleRetry();
		console.warn('oxidns hijack refresh:', err);
	});
}

function updateHijackControls() {
	var node = document.getElementById('oxidns-hijack-core-hint');
	if (!node)
		return;

	if (coreInstalled(statusState)) {
		node.style.display = 'none';
		return;
	}

	node.style.display = 'block';
	node.textContent = _('Install the OxiDNS core before DNS hijack can redirect to a local listener.');
}

function cancelChanges() {
	clearDirty();
	applyHijackState(hijackState, true);
	setHijackStatus(_('Unsaved DNS hijack changes discarded.'), false);
}

function saveHijack() {
	var box = document.getElementById('oxidns-hijack-enabled');
	var enabled = !!(box && box.checked);
	var mode = hijackSelectedMode();
	var input = hijackPortInput();
	var port = input ? String(input.value || '').trim() : '';
	var portNumber = 0;

	// 设置本身要合法：manual 下端口必须是 1-65535。后端同样会校验，这里先挡一次。
	if (mode === 'manual') {
		portNumber = parseInt(port, 10);
		if (!/^[0-9]+$/.test(port) || portNumber < 1 || portNumber > 65535) {
			setHijackStatus(_('Enter a port number between 1 and 65535.'), true);
			return Promise.resolve();
		}
	}

	showRefreshError('');
	ui.showModal(_('OxiDNS'), [
		E('p', {}, _('Applying DNS hijack...'))
	]);
	focusModal();

	/* RPC list 声明 port 为 number；auto 模式传 0，后端只在 manual 时使用它 */
	return Promise.resolve(callHijackSave(enabled, mode, portNumber)).then(function(result) {
		ui.hideModal();
		if (!result || result.ok === false) {
			setHijackStatus(backendMessage(result, _('Failed to apply DNS hijack')), true);
			return refreshHijack().catch(function() {});
		}

		hijackState = result;
		applyHijackState(result, true);
		clearDirty();

		if (result.warn === 'firewall_reload_failed') {
			setHijackStatus(_('Rules were written, but the firewall reload failed. The rules take effect on the next firewall reload or reboot.'), true);
			return;
		}
		setHijackStatus(result.enabled
			? _('DNS hijack enabled. LAN port 53 requests are redirected to OxiDNS.')
			: _('DNS hijack disabled.'), false);
	}).catch(function(err) {
		ui.hideModal();
		setHijackStatus(backendMessage(err, _('Failed to apply DNS hijack')), true);
		return refreshHijack().catch(function() {});
	});
}

return baseclass.extend({
	load: function() {
		return Promise.all([
			Promise.resolve(callHijackGet()).catch(function(err) {
				console.warn('oxidns hijack load:', err);
				return { ok: false, code: 'rpc_unavailable' };
			}),
			Promise.resolve(callStatus()).catch(function(err) {
				console.warn('oxidns status load:', err);
				return { ok: false, code: 'rpc_unavailable' };
			})
		]).then(function(results) {
			return {
				hijack: results[0] || {},
				status: results[1] || {}
			};
		});
	},

	render: function(data) {
		var hijack = (data && data.hijack) || {};
		var status = (data && data.status) || {};

		hijackState = hijack;
		statusState = status;
		dirty = false;

		addCleanup(unregisterPoll);
		addCleanup(cancelRetry);

		var map = E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('DNS Hijack')),
			E('div', { 'class': 'cbi-map-descr' },
				_('Redirect LAN DNS requests on port 53 (TCP and UDP, IPv4 and IPv6) to the local OxiDNS DNS listener.')),
			E('div', { 'class': 'cbi-section', 'id': 'oxidns-hijack-section' }, [
				E('div', {
					'id': 'oxidns-hijack-core-hint',
					'class': 'alert-message warning',
					'style': 'margin: 1em 0; display: none;'
				}),
				E('div', {
					'id': 'oxidns-hijack-error',
					'class': 'alert-message error',
					'aria-live': 'polite',
					'style': 'margin: 1em 0; display: none;'
				}),
				E('div', {
					'id': 'oxidns-hijack-dirty',
					'class': 'alert-message warning',
					'aria-live': 'polite',
					'style': 'margin: 1em 0; display: none;'
				}, _('You have unsaved changes. Remote updates are paused until you Apply or Cancel.')),
				E('div', { 'class': 'table cbi-section-table' }, [
					renderRow(_('Status'), hijackStatusBadge(hijack)),
					renderRow(_('Target ports'), '-', 'oxidns-hijack-ports'),
					renderRow(_('Active firewall sections'), '-', 'oxidns-hijack-sections')
				]),
				E('div', { 'style': 'margin: .75em 0;' }, [
					E('label', { 'style': 'display: block; margin-bottom: .35em;' }, [
						E('input', {
							'id': 'oxidns-hijack-mode-auto',
							'type': 'radio',
							'name': 'oxidns-hijack-port-mode',
							'value': 'auto',
							'checked': (hijack.port_mode === 'manual') ? null : 'checked',
							'style': 'margin-right: .5em;',
							'change': syncHijackPortInput
						}),
						_('Read the port from config.yaml automatically')
					]),
					E('label', { 'style': 'display: block;' }, [
						E('input', {
							'id': 'oxidns-hijack-mode-manual',
							'type': 'radio',
							'name': 'oxidns-hijack-port-mode',
							'value': 'manual',
							'checked': (hijack.port_mode === 'manual') ? 'checked' : null,
							'style': 'margin-right: .5em;',
							'change': syncHijackPortInput
						}),
						_('Use a manual port'),
						' ',
						E('input', {
							'id': 'oxidns-hijack-port',
							'type': 'text',
							'inputmode': 'numeric',
							'placeholder': _('5353'),
							'aria-describedby': 'oxidns-hijack-port-description',
							'value': (hijack.manual_port != null) ? String(hijack.manual_port) : '',
							'disabled': (hijack.port_mode === 'manual') ? null : 'disabled',
							'style': 'width: 6em; margin-left: .4em;',
							'input': markDirty
						})
					]),
					E('div', {
						'id': 'oxidns-hijack-port-description',
						'class': 'cbi-value-description',
						'style': 'margin-top: .35em;'
					}, (hijack.port_mode === 'manual')
						? _('Enter a port number between 1 and 65535.')
						: _('The port is read from config.yaml automatically.'))
				]),
				E('label', { 'style': 'display: block; margin: .5em 0;' }, [
					E('input', {
						'id': 'oxidns-hijack-enabled',
						'type': 'checkbox',
						'checked': hijack.enabled ? 'checked' : null,
						'style': 'margin-right: .5em;',
						'change': markDirty
					}),
					_('Enable DNS hijack')
				]),
				E('div', { 'class': 'cbi-button-row' }, [
					E('button', {
						'id': 'oxidns-hijack-apply',
						'type': 'button',
						'class': 'btn cbi-button cbi-button-positive',
						'click': function(ev) {
							ev.preventDefault();
							return saveHijack();
						}
					}, _('Apply')),
					' ',
					E('button', {
						'id': 'oxidns-hijack-cancel',
						'type': 'button',
						'class': 'btn cbi-button cbi-button-neutral',
						'click': function(ev) {
							ev.preventDefault();
							return cancelChanges();
						}
					}, _('Cancel'))
				]),
				E('div', {
					'id': 'oxidns-hijack-status',
					'aria-live': 'polite',
					'style': 'margin-top: 1em;'
				})
			])
		]);

		watchView(map);

		/* LuCI 在 render 返回后才插入 DOM，而 poll.add() 会立即 step 一次；
		 * 注册轮询和首帧回填都推迟到挂载之后。 */
		window.setTimeout(function() {
			if (!isAttached(viewRoot))
				return;
			pollFn = refreshAll;
			poll.add(pollFn, 5);
			updateHijackControls();
			applyHijackState(hijackState, false);
		}, 0);

		return map;
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
