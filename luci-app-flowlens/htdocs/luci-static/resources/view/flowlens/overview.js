'use strict';
'require view';
'require rpc';
'require dom';

var callDevices = rpc.declare({
	object: 'luci.flowlens',
	method: 'devices',
	expect: { '': {} }
});

var assetVersion = '0.1.27';
var languageStorageKey = 'flowlens.language';
var languageMessages = {
	zh: {
		boot: 'FlowLens 正在加载...',
		error: 'FlowLens 前端加载失败：'
	},
	en: {
		boot: 'Loading FlowLens...',
		error: 'FlowLens frontend failed to load: '
	}
};

function matchingLanguage(value) {
	var normalized = String(value || '').trim().replace(/_/g, '-').toLowerCase();

	if (!normalized)
		return '';

	if (normalized === 'zh' || normalized.indexOf('zh-') === 0)
		return 'zh';

	if (normalized === 'en' || normalized.indexOf('en-') === 0)
		return 'en';

	return '';
}

function safeGetAttribute(node, name) {
	if (!node || typeof node.getAttribute !== 'function')
		return '';

	try {
		return node.getAttribute(name) || '';
	} catch (error) {
		return '';
	}
}

function storedLanguage() {
	try {
		if (window.localStorage)
			return matchingLanguage(window.localStorage.getItem(languageStorageKey));
	} catch (error) {
		return '';
	}

	return '';
}

function resolvedLanguage() {
	var stored = storedLanguage();

	if (stored)
		return stored;

	var html = document.documentElement;
	var body = document.body;
	var candidates = [
		html && html.lang,
		safeGetAttribute(html, 'lang'),
		safeGetAttribute(html, 'xml:lang'),
		safeGetAttribute(html, 'data-language'),
		safeGetAttribute(html, 'data-lang'),
		body && body.lang,
		safeGetAttribute(body, 'lang'),
		safeGetAttribute(body, 'data-language'),
		safeGetAttribute(body, 'data-lang')
	];

	if (navigator.languages) {
		for (var i = 0; i < navigator.languages.length; i++)
			candidates.push(navigator.languages[i]);
	}

	candidates.push(navigator.language, navigator.userLanguage);

	for (var j = 0; j < candidates.length; j++) {
		var language = matchingLanguage(candidates[j]);

		if (language)
			return language;
	}

	return 'zh';
}

function languageText(key) {
	var language = resolvedLanguage();
	return (languageMessages[language] && languageMessages[language][key]) ||
		languageMessages.zh[key] ||
		key;
}

function parseRgb(color) {
	var match = String(color || '').match(/rgba?\((\d+),\s*(\d+),\s*(\d+)(?:,\s*([\d.]+))?\)/i);

	if (!match || match[4] === '0')
		return null;

	return [
		Number(match[1]),
		Number(match[2]),
		Number(match[3])
	];
}

function isDarkColor(color) {
	var rgb = parseRgb(color);

	if (!rgb)
		return false;

	return (rgb[0] * 0.2126 + rgb[1] * 0.7152 + rgb[2] * 0.0722) < 128;
}

function colorTheme(color) {
	var rgb = parseRgb(color);

	if (!rgb)
		return '';

	return isDarkColor(color) ? 'dark' : 'light';
}

function hostSurfaceTheme() {
	var nodes = [
		document.querySelector('.main-right'),
		document.querySelector('#maincontent'),
		document.querySelector('.main'),
		document.body,
		document.documentElement
	];

	for (var i = 0; i < nodes.length; i++) {
		if (!nodes[i])
			continue;

		var theme = colorTheme(window.getComputedStyle(nodes[i]).backgroundColor);

		if (theme)
			return theme;
	}

	return '';
}

function isDarkTheme() {
	var surfaceTheme = hostSurfaceTheme();

	if (surfaceTheme)
		return surfaceTheme === 'dark';

	if (document.documentElement.getAttribute('data-darkmode') === 'true' ||
		document.body.getAttribute('data-darkmode') === 'true')
		return true;

	return false;
}

function applyTheme(root) {
	if (isDarkTheme())
		root.setAttribute('data-darkmode', 'true');
	else
		root.removeAttribute('data-darkmode');
}

function loadStyle() {
	var id = 'flowlens-react-style';

	if (document.getElementById(id))
		return;

	document.head.appendChild(E('link', {
		id: id,
		rel: 'stylesheet',
		type: 'text/css',
		href: L.resource('flowlens/dist/flowlens-app.css') + '?v=' + assetVersion
	}));
}

function hasCurrentApp() {
	return window.FlowLensApp &&
		window.FlowLensApp.version === assetVersion &&
		typeof window.FlowLensApp.mount === 'function';
}

function loadScript() {
	var id = 'flowlens-react-script';

	if (hasCurrentApp())
		return Promise.resolve(window.FlowLensApp);

	return new Promise(function(resolve, reject) {
		var existing = document.getElementById(id);

		if (existing) {
			if (existing.dataset.version === assetVersion && existing.dataset.loaded !== '1') {
				existing.addEventListener('load', function() {
					if (hasCurrentApp()) {
						resolve(window.FlowLensApp);
						return;
					}

					reject(new Error('FlowLensApp.mount is unavailable'));
				});
				existing.addEventListener('error', reject);
				return;
			}

			if (existing.dataset.version === assetVersion && existing.dataset.loaded === '1') {
				if (hasCurrentApp()) {
					resolve(window.FlowLensApp);
					return;
				}
			}

			existing.parentNode.removeChild(existing);
		}

		window.FlowLensApp = null;

		var script = E('script', {
			id: id,
			src: L.resource('flowlens/dist/flowlens-app.js') + '?v=' + assetVersion
		});

		script.onload = function() {
			script.dataset.loaded = '1';
			if (hasCurrentApp()) {
				resolve(window.FlowLensApp);
				return;
			}

			reject(new Error('FlowLensApp.mount is unavailable'));
		};
		script.onerror = reject;
		script.dataset.version = assetVersion;
		document.head.appendChild(script);
	});
}

return view.extend({
	handleSaveApply: null,
	handleSave: null,
	handleReset: null,

	load: function() {
		return callDevices();
	},

	render: function(data) {
		var root = E('div', { 'class': 'flowlens-react-root' });

		applyTheme(root);
		loadStyle();
		dom.content(root, [
			E('div', { 'class': 'flowlens-boot' }, [
				E('div', { 'class': 'flowlens-boot-mark' }, [ 'F' ]),
				E('div', [ languageText('boot') ])
			])
		]);

		loadScript().then(function(app) {
			if (!app || typeof app.mount !== 'function')
				throw new Error('FlowLensApp.mount is unavailable');

			applyTheme(root);
			app.mount(root, {
				initialData: data || {},
				fetchDevices: callDevices,
				pollInterval: 2000
			});
		}).catch(function(error) {
			dom.content(root, E('div', { 'class': 'flowlens-load-error' }, [
				languageText('error') + error
			]));
		});

		return root;
	}
});
