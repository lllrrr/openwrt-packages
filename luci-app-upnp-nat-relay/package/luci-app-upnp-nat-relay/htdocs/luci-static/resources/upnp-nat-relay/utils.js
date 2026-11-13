'use strict';
'require uci';
'require baseclass';

var FOOTER_VERSION = '@PKG_VERSION@';

var FOOTER_OPTIONS = {
	project: _('UPnP NAT Relay'),
	repoUrl: 'https://github.com/hello-yunshu/luci-app-upnp-nat-relay'
};

function safeApply() {
	return uci.apply().catch(function(e) {
		var message = e && e.message ? e.message : String(e);
		if (e === 5 || /\bubus code 5\b/.test(message) || /No data|未收到数据/.test(message))
			return;
		throw e;
	});
}

function setBusy(button, label) {
	if (!button)
		return;
	button.disabled = true;
	button.setAttribute('data-original-title', button.textContent);
	button.textContent = label;
}

function resetBusy(button) {
	if (!button)
		return;
	button.disabled = false;
	button.textContent = button.getAttribute('data-original-title') || button.textContent;
	button.removeAttribute('data-original-title');
}

function reloadSoon(delay) {
	window.setTimeout(function() {
		window.location.reload();
	}, delay || 1200);
}

function waitForServiceReady(callStatus, options) {
	options = options || {};
	var interval = options.interval || 3000;
	var timeout = options.timeout || 120000;
	var startedAt = Date.now();

	function wait(delay) {
		return new Promise(function(resolve) {
			window.setTimeout(resolve, delay);
		});
	}

	function poll() {
		if (options.isActive && !options.isActive())
			return Promise.resolve({});

		return callStatus().then(function(status) {
			status = status || {};
			if (status.running && status.last_result !== 'starting')
				return status;
			if (!status.running && status.last_result === 'stopped')
				return status;
			if (Date.now() - startedAt >= timeout)
				return status;
			return wait(interval).then(poll);
		});
	}

	return poll();
}

function requireSuccess(result) {
	if (!result || result.success !== true)
		throw new Error(result.error || _('service action failed'));
	return result || {};
}

function isTransientXhrError(e) {
	var msg = e && e.message ? e.message : String(e);
	/* LuCI throws these when iOS WebKit / mobile Edge aborts an in-flight
	 * XHR (background throttling, network hiccup, page visibility changes).
	 * They are not real server-side failures and usually succeed on retry.
	 */
	return /aborted by browser|XHR request timed out|NetworkError|Failed to fetch/i.test(msg);
}

function rpcWithRetry(fn, options) {
	options = options || {};
	var retries = options.retries != null ? options.retries : 2;
	var delay = options.delay != null ? options.delay : 800;

	function attempt(remaining) {
		return Promise.resolve()
			.then(fn)
			.catch(function(e) {
				if (remaining > 0 && isTransientXhrError(e)) {
					return new Promise(function(resolve) {
						window.setTimeout(resolve, delay);
					}).then(function() {
						return attempt(remaining - 1);
					});
				}
				throw e;
			});
	}

	return attempt(retries);
}

function getErrorMessage(error) {
	if (!error)
		return '';
	if (error.message)
		return String(error.message);
	if (typeof error === 'string')
		return error;
	if (typeof error.toString === 'function')
		return error.toString();
	return '';
}

/* RPC / 配置读取失败时的页内错误面板：标题 + 可读说明 + 折叠技术详情。
 * 原始异常同时由调用方的 console.error 留在控制台。 */
function errorPanel(title, message, error) {
	var text = getErrorMessage(error);
	var children = [
		E('p', {}, title),
		message ? E('p', {}, message) : ''
	];

	if (text)
		children.push(E('details', {}, [
			E('summary', {}, _('Technical details')),
			E('pre', {}, text)
		]));

	return E('div', { 'class': 'alert-message danger', 'role': 'alert' }, children);
}

/* view.load() 的 catch 处理器：把异常转成可渲染的 _loadError 标记。 */
function loadFailed(label) {
	return function(error) {
		console.error('upnp-nat-relay: ' + label + ' load failed', error);
		return { _loadError: error };
	};
}

function loadSharedCSS() {
	if (!document.getElementById('upnp-shared-css')) {
		var link = E('link', {
			'id': 'upnp-shared-css',
			'rel': 'stylesheet',
			'href': L.resource('upnp-nat-relay/upnp-nat-relay.css') + '?v=@PKG_FULL_VERSION@'
		});
		document.head.appendChild(link);
	}

	/* 主题没有在 body 上留标记，唯一可靠的信号是主题样式表本身。
	 * 只在 bootstrap 下加类，供 CSS 做兼容覆盖，避免污染 aurora。 */
	var body = document.body;
	if (body && document.querySelector('link[rel="stylesheet"][href*="/bootstrap/"]'))
		body.classList.add('ubr-theme-bootstrap');

	/* 离开插件页时移除，防止兼容样式泄漏到其他视图 */
	if (!loadSharedCSS.unwatch) {
		loadSharedCSS.unwatch = true;
		window.addEventListener('hashchange', function() {
			if (document.body)
				document.body.classList.remove('ubr-theme-bootstrap');
		});
	}
}

function footerSeparator(extraClass) {
	var className = 'ys-tool-footer-separator';
	if (extraClass)
		className += ' ' + extraClass;
	return E('span', { 'class': className }, '\u00a0·\u00a0');
}

function footerIcon(name) {
	if (typeof document === 'undefined' || !document.createElementNS)
		return null;
	var svgNS = 'http://www.w3.org/2000/svg';
	var svg = document.createElementNS(svgNS, 'svg');
	var path = document.createElementNS(svgNS, 'path');
	svg.setAttribute('class', 'ys-tool-footer-link-icon ' + name);
	svg.setAttribute('viewBox', '0 0 24 24');
	svg.setAttribute('width', '14');
	svg.setAttribute('height', '14');
	svg.setAttribute('aria-hidden', 'true');
	svg.setAttribute('focusable', 'false');
	svg.setAttribute('style', 'width:1em;height:1em;max-width:1em;max-height:1em;display:inline-block;flex:0 0 auto;vertical-align:-0.125em');
	if (name === 'github') {
		path.setAttribute('fill', 'currentColor');
		path.setAttribute('d', 'M12 2C6.48 2 2 6.58 2 12.26c0 4.53 2.87 8.37 6.84 9.73.5.09.68-.22.68-.49v-1.9c-2.78.62-3.37-1.22-3.37-1.22-.45-1.19-1.11-1.5-1.11-1.5-.91-.64.07-.63.07-.63 1 .07 1.53 1.06 1.53 1.06.9 1.57 2.35 1.12 2.92.86.09-.67.35-1.12.63-1.38-2.22-.26-4.56-1.14-4.56-5.07 0-1.12.39-2.03 1.03-2.75-.1-.26-.45-1.3.1-2.71 0 0 .84-.28 2.75 1.05A9.36 9.36 0 0 1 12 6.97c.85 0 1.71.12 2.51.34 1.91-1.33 2.75-1.05 2.75-1.05.55 1.41.2 2.45.1 2.71.64.72 1.03 1.63 1.03 2.75 0 3.94-2.34 4.8-4.57 5.06.36.32.68.94.68 1.9v2.82c0 .27.18.59.69.49A10.24 10.24 0 0 0 22 12.26C22 6.58 17.52 2 12 2z');
	} else if (name === 'x') {
		path.setAttribute('fill', 'currentColor');
		path.setAttribute('d', 'M18.244 2.25h3.308l-7.227 8.26 8.502 11.24H16.17l-5.214-6.817L4.99 21.75H1.68l7.73-8.835L1.254 2.25H8.08l4.713 6.231 5.451-6.231zm-1.161 17.52h1.833L7.084 4.126H5.117L17.083 19.77z');
	} else {
		return null;
	}
	svg.appendChild(path);
	return svg;
}

function footerLink(href, label, icon) {
	var children = [];
	var iconNode = icon ? footerIcon(icon) : null;
	if (iconNode)
		children.push(iconNode);
	children.push(E('span', { 'class': 'ys-tool-footer-link-label' }, label));
	return E('a', {
		'class': 'ys-tool-footer-link' + (icon ? ' ' + icon : ''),
		'href': href,
		'target': '_blank',
		'rel': 'noopener noreferrer'
	}, children);
}

function footerVersion(version) {
	var value = version && version !== '-' ? version : FOOTER_VERSION;
	if (!value || value === '-' || value.charAt(0) === '@')
		return '';
	return /^v/i.test(value) ? value : 'v' + value;
}

function renderFooter(options) {
	options = options || {};
	var project = options.project || FOOTER_OPTIONS.project;
	var version = footerVersion(options.version);
	var repoUrl = options.repoUrl || FOOTER_OPTIONS.repoUrl;
	return E('div', { 'class': 'ys-tool-footer' }, [
		E('div', { 'class': 'ys-tool-footer-brand' }, [
			E('span', { 'class': 'ys-tool-footer-mark' }, '云云舒'),
			footerSeparator('ys-tool-footer-title-separator'),
			E('span', { 'class': 'ys-tool-footer-title' }, project),
			version ? footerSeparator('ys-tool-footer-version-separator') : '',
			version ? E('span', { 'class': 'ys-tool-footer-version' }, version) : ''
		]),
		E('div', { 'class': 'ys-tool-footer-links' }, [
			E('span', { 'class': 'ys-tool-footer-project-link' }, footerLink(repoUrl, _('Project'))),
			footerSeparator('ys-tool-footer-project-separator'),
			footerLink('https://github.com/hello-yunshu', 'GitHub', 'github'),
			footerSeparator(),
			footerLink('https://x.com/yunyunyshu', '@云云舒', 'x')
		])
	]);
}

function appendFooter(node, options) {
	loadSharedCSS();
	if (node)
		node.appendChild(renderFooter(options));
	return node;
}

function renderWithFooter(rendered, options) {
	return Promise.resolve(rendered).then(function(node) {
		return appendFooter(node, options);
	});
}

return baseclass.extend({
	safeApply: safeApply,
	setBusy: setBusy,
	resetBusy: resetBusy,
	reloadSoon: reloadSoon,
	waitForServiceReady: waitForServiceReady,
	requireSuccess: requireSuccess,
	rpcWithRetry: rpcWithRetry,
	isTransientXhrError: isTransientXhrError,
	errorPanel: errorPanel,
	loadFailed: loadFailed,
	loadSharedCSS: loadSharedCSS,
	FOOTER_VERSION: FOOTER_VERSION,
	FOOTER_OPTIONS: FOOTER_OPTIONS,
	renderFooter: renderFooter,
	appendFooter: appendFooter,
	renderWithFooter: renderWithFooter
});
