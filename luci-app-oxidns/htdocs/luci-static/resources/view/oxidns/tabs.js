'require baseclass';
'require ui';

/*
 * Shared tab container for the consolidated OxiDNS views.
 *
 * LuCI's ui.tabs only auto-initialises panes that are present in the DOM when
 * the `luci-loaded` event fires. A view's render() runs after that event, so
 * panes created here would otherwise never get a tab menu. Build the standard
 * cbi-tabmenu markup directly and handle activation ourselves.
 *
 * Panels are rendered lazily on their first cbi-tab-active event. Switching
 * away dispatches cbi-tab-inactive so polling panels can stop their timers;
 * hidden panes stay in the DOM only to preserve form state.
 */

function isAttached(node) {
	return !!(node && document.body && typeof document.body.contains === 'function' && document.body.contains(node));
}

function paneFor(node) {
	var parent = node && node.parentNode;
	return parent && parent.hasAttribute && parent.hasAttribute('data-tab') ? parent : null;
}

/* A panel inside a hidden tab is attached to the document but must be treated
 * as inactive. Standalone compatibility views have no enclosing pane and stay
 * active whenever they are attached. */
function isActive(node) {
	if (!isAttached(node))
		return false;

	var pane = paneFor(node);
	return !pane || pane.getAttribute('data-tab-active') === 'true';
}

/* Panels call this from their post-mount setTimeout, when map.parentNode is
 * the tab pane. Returns an unregister function for the panel's cleanup list. */
function watchActivation(node, onActive, onInactive) {
	var pane = paneFor(node);
	if (!pane)
		return function() {};

	pane.addEventListener('cbi-tab-active', onActive);
	pane.addEventListener('cbi-tab-inactive', onInactive);

	return function() {
		pane.removeEventListener('cbi-tab-active', onActive);
		pane.removeEventListener('cbi-tab-inactive', onInactive);
	};
}

function dispatch(pane, type, detail) {
	if (!pane)
		return;

	pane.dispatchEvent(new CustomEvent(type, {
		'bubbles': true,
		'detail': detail || {}
	}));
}

/* LuCI's module loader requires every factory to return a Class subclass
 * constructor (Class.isSubclass check). Returning a plain object is rejected
 * as "factory yields invalid constructor" on newer LuCI builds. extend()
 * puts these helpers on the prototype; require() hands callers an instance,
 * so tabs.build()/isActive()/watchActivation() keep working unchanged. */
return baseclass.extend({
	isActive: isActive,
	watchActivation: watchActivation,

	build: function(panels) {
		var menu = E('ul', { 'class': 'cbi-tabmenu' });
		var group = E('div', { 'class': 'oxidns-tab-group' });
		var links = [];
		var panes = [];
		var activeIndex = 0;
		var initialHash = (window.location.hash || '').replace(/^#/, '');

		panels.forEach(function(panel, index) {
			var aliases = [panel.id].concat(panel.hashes || []);
			if (aliases.indexOf(initialHash) >= 0)
				activeIndex = index;
		});

		function activate(index, hash, updateLocation) {
			if (index < 0 || index >= panels.length)
				return;

			links.forEach(function(link, i) {
				link.classList.toggle('cbi-tab', i === index);
				link.classList.toggle('cbi-tab-disabled', i !== index);
			});

			panes.forEach(function(pane, i) {
				if (i === index || pane.getAttribute('data-tab-active') !== 'true')
					return;

				pane.setAttribute('data-tab-active', 'false');
				dispatch(pane, 'cbi-tab-inactive', { 'tab': panels[i].id });
			});

			var pane = panes[index];
			var panel = panels[index];
			pane.setAttribute('data-tab-active', 'true');

			if (!pane.firstChild)
				DOM.content(pane, panel.render());

			dispatch(pane, 'cbi-tab-active', { 'tab': panel.id });

			if (updateLocation && window.history && typeof window.history.replaceState === 'function')
				window.history.replaceState(null, '', window.location.pathname + window.location.search + '#' + panel.id);

			/* Deep links such as #api-credentials name an anchor inside a lazily
			 * rendered panel; wait one frame so the target exists before scrolling. */
			if (hash && hash !== panel.id && panel.anchor) {
				window.setTimeout(function() {
					var target = document.getElementById(panel.anchor);
					if (target && typeof target.scrollIntoView === 'function')
						target.scrollIntoView({ 'block': 'start' });
				}, 0);
			}
		}

		panels.forEach(function(panel, index) {
			var active = index === activeIndex;
			var link = E('li', {
				'class': active ? 'cbi-tab' : 'cbi-tab-disabled',
				'data-tab': panel.id
			}, E('a', { 'href': '#' + panel.id }, panel.title));

			link.firstChild.addEventListener('click', function(ev) {
				ev.preventDefault();
				activate(index, panel.id, true);
			});

			menu.appendChild(link);
			links.push(link);

			var pane = E('div', {
				'data-tab': panel.id,
				'data-tab-title': panel.title,
				'data-tab-active': active ? 'true' : 'false'
			});

			panes.push(pane);
			group.appendChild(pane);
		});

		window.requestAnimationFrame(function() {
			activate(activeIndex, initialHash, false);
		});

		/* 同页内改变 hash（例如点击指向 #api-credentials 的链接）时也要切换 */
		window.addEventListener('hashchange', function() {
			var hash = (window.location.hash || '').replace(/^#/, '');
			for (var i = 0; i < panels.length; i++) {
				var aliases = [ panels[i].id ].concat(panels[i].hashes || []);
				if (aliases.indexOf(hash) >= 0) {
					activate(i, hash, false);
					return;
				}
			}
		});

		return E('div', {}, [ menu, group ]);
	}
});
