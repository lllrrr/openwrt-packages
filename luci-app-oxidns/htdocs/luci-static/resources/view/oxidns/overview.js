'require view';
'require view.oxidns.tabs as tabs';
'require view.oxidns.parts.overview as overviewPanel';
'require view.oxidns.parts.hijack as hijackPanel';

/*
 * Consolidated landing page. The former standalone DNS Hijack view is now a
 * second in-page tab; the RPCs, UCI options and ACLs are unchanged.
 */
return view.extend({
	load: function() {
		return Promise.all([
			overviewPanel.load(),
			hijackPanel.load()
		]);
	},
	render: function(results) {
		return tabs.build([
			{ id: 'overview', title: _('Overview'), render: function() { return overviewPanel.render(results[0]); } },
			{ id: 'hijack', title: _('DNS Hijack'), render: function() { return hijackPanel.render(results[1]); } }
		]);
	},
	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
