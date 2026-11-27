'require baseclass';
'require ui';

/*
 * Shared tab container for the consolidated OxiDNS views.
 *
 * LuCI's ui.tabs only auto-initialises panes that are present in the DOM when
 * the `luci-loaded` event fires. A view's render() runs after that event, so
 * panes created here would otherwise never get a tab menu. Build the standard
 * cbi-tabmenu markup directly and let ui.tabs.switchTab handle activation.
 *
 * Panels are rendered lazily on their first cbi-tab-active event. This keeps
 * CodeMirror from measuring a zero-width hidden pane and avoids running every
 * panel's polling loop while the user is on a different tab. Data is still
 * prefetched by the container's load(), so switching tabs is immediate.
 */
return baseclass.extend({
	build: function(panels) {
		var menu = E('ul', { 'class': 'cbi-tabmenu' });
		var group = E('div', { 'class': 'oxidns-tab-group' });

		panels.forEach(function(panel, index) {
			menu.appendChild(E('li', {
				'class': index === 0 ? 'cbi-tab' : 'cbi-tab-disabled',
				'data-tab': panel.id
			}, E('a', {
				'href': '#',
				'click': ui.tabs.switchTab.bind(ui.tabs)
			}, panel.title)));

			var pane = E('div', {
				'data-tab': panel.id,
				'data-tab-title': panel.title,
				'data-tab-active': index === 0 ? 'true' : 'false'
			});
			var rendered = false;
			pane.addEventListener('cbi-tab-active', function() {
				if (rendered)
					return;
				rendered = true;
				DOM.content(pane, panel.render());
			});
			group.appendChild(pane);
		});

		window.requestAnimationFrame(function() {
			var active = group.querySelector('[data-tab-active="true"]');
			if (active)
				active.dispatchEvent(new CustomEvent('cbi-tab-active', {
					'detail': { 'tab': active.getAttribute('data-tab') }
				}));
		});

		return E('div', {}, [ menu, group ]);
	}
});
