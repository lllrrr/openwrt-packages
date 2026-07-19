'use strict';
'require baseclass';

var AURORA_CLASS = 'qddns-theme-aurora';
var ARGON_CLASS = 'qddns-theme-argon';
var ROOT_CLASS = 'qddns-root';
var boundDocument = null;
var refreshQueued = false;

function docOrGlobal(doc) {
	if (doc)
		return doc;
	if (typeof document !== 'undefined')
		return document;
	return null;
}

function hasSelector(doc, selector) {
	try {
		return !!(doc && doc.querySelector && doc.querySelector(selector));
	} catch (err) {
		return false;
	}
}

function hasAuroraAsset(doc) {
	return hasSelector(doc, 'link[href*="/luci-static/aurora/main.css"]') ||
		hasSelector(doc, 'link[href*="/luci-static/aurora/login.css"]');
}

function hasArgonAsset(doc) {
	return hasSelector(doc, 'link[href*="/luci-static/argon/css/cascade.css"]') ||
		hasSelector(doc, 'script[src*="menu-argon.js"]');
}

function hasAuroraShell(doc) {
	var body = doc && doc.body;
	var html = doc && doc.documentElement;

	return !!(
		html && html.hasAttribute('data-darkmode') &&
		body && body.hasAttribute('data-nav-type') &&
		(hasSelector(doc, '#mobile-menu-overlay') ||
		 hasSelector(doc, '.desktop-menu-container') ||
		 hasSelector(doc, '.sidebar-panel'))
	);
}

function hasArgonShell(doc) {
	return !!(
		hasSelector(doc, '.main > .main-left') &&
		hasSelector(doc, '.main > .main-right') &&
		hasSelector(doc, '.darkMask')
	);
}

function detectTheme(doc) {
	doc = docOrGlobal(doc);

	if (!doc)
		return '';
	if (hasAuroraAsset(doc) || hasAuroraShell(doc))
		return 'aurora';
	if (hasArgonAsset(doc) || hasArgonShell(doc))
		return 'argon';
	return '';
}

function colorIsDark(value) {
	var channels = String(value || '').match(/[\d.]+/g);

	if (!channels || channels.length < 3)
		return false;

	var red = Number(channels[0]);
	var green = Number(channels[1]);
	var blue = Number(channels[2]);
	var luminance = (0.2126 * red + 0.7152 * green + 0.0722 * blue) / 255;

	return luminance < 0.5;
}

function isDarkTheme(doc, theme) {
	doc = docOrGlobal(doc);

	if (!doc)
		return false;

	if (theme === 'aurora')
		return doc.documentElement?.getAttribute('data-darkmode') === 'true';

	if (theme === 'argon' && doc.body && doc.defaultView?.getComputedStyle)
		return colorIsDark(doc.defaultView.getComputedStyle(doc.body).backgroundColor);

	return false;
}

function decorateRoot(root, doc, theme) {
	if (!root)
		return root;

	root.classList.add(ROOT_CLASS);
	root.classList.remove(AURORA_CLASS, ARGON_CLASS);

	if (theme === 'aurora')
		root.classList.add(AURORA_CLASS);
	else if (theme === 'argon')
		root.classList.add(ARGON_CLASS);

	root.setAttribute('data-qddns-theme', theme || 'default');
	root.setAttribute('data-qddns-dark', String(isDarkTheme(doc, theme)));
	return root;
}

function syncDocument(doc) {
	doc = docOrGlobal(doc);

	if (!doc || !doc.documentElement)
		return '';

	var theme = detectTheme(doc);
	var html = doc.documentElement;

	if (theme) {
		html.setAttribute('data-qddns-theme', theme);
		html.setAttribute('data-qddns-dark', String(isDarkTheme(doc, theme)));
	} else {
		html.removeAttribute('data-qddns-theme');
		html.removeAttribute('data-qddns-dark');
	}

	var roots = doc.querySelectorAll?.('.' + ROOT_CLASS) || [];
	for (var index = 0; index < roots.length; index++)
		decorateRoot(roots[index], doc, theme);

	return theme;
}

function queueRefresh(doc) {
	if (refreshQueued)
		return;

	refreshQueued = true;
	var win = doc && doc.defaultView;
	var schedule = win?.requestAnimationFrame || function(callback) { return win?.setTimeout(callback, 0); };

	schedule(function() {
		refreshQueued = false;
		syncDocument(doc);
	});
}

function bindThemeSignals(doc) {
	doc = docOrGlobal(doc);

	if (!doc || boundDocument === doc)
		return;

	boundDocument = doc;
	var win = doc.defaultView;
	var media = win?.matchMedia?.('(prefers-color-scheme: dark)');
	var listener = function() { queueRefresh(doc); };

	if (media?.addEventListener)
		media.addEventListener('change', listener);
	else if (media?.addListener)
		media.addListener(listener);

	if (win?.MutationObserver && doc.documentElement) {
		new win.MutationObserver(listener).observe(doc.documentElement, {
			attributes: true,
			attributeFilter: ['data-darkmode']
		});
	}

	if (win?.MutationObserver && doc.body) {
		new win.MutationObserver(function(records) {
			var theme = detectTheme(doc);

			for (var recordIndex = 0; recordIndex < records.length; recordIndex++) {
				var target = records[recordIndex].target;
				var targetModal = target?.matches?.('#modal_overlay > .modal')
					? target
					: target?.closest?.('#modal_overlay > .modal');

				if (targetModal)
					decorateRoot(targetModal, doc, theme);

				var nodes = records[recordIndex].addedNodes || [];

				for (var nodeIndex = 0; nodeIndex < nodes.length; nodeIndex++) {
					var node = nodes[nodeIndex];
					if (!node || node.nodeType !== 1)
						continue;

					if (node.matches?.('#modal_overlay > .modal'))
						decorateRoot(node, doc, theme);

					var modals = node.querySelectorAll?.('#modal_overlay > .modal') || [];
					for (var modalIndex = 0; modalIndex < modals.length; modalIndex++)
						decorateRoot(modals[modalIndex], doc, theme);
				}
			}
		}).observe(doc.body, { childList: true, subtree: true });
	}
}

return baseclass.extend({
	detect: detectTheme,
	colorIsDark: colorIsDark,
	isDark: function(doc) {
		doc = docOrGlobal(doc);
		return isDarkTheme(doc, detectTheme(doc));
	},
	sync: function(doc) {
		doc = docOrGlobal(doc);
		var theme = syncDocument(doc);
		bindThemeSignals(doc);
		return theme;
	},
	applyRoot: function(root, doc) {
		doc = docOrGlobal(doc);
		var theme = this.sync(doc);
		return decorateRoot(root, doc, theme);
	}
});
