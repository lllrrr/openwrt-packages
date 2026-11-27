'require view';
'require view.oxidns.tabs as tabs';
'require view.oxidns.parts.core as corePanel';
'require view.oxidns.parts.rules as rulesPanel';
'require view.oxidns.parts.geo as geoPanel';

/*
 * Consolidated data and update page. Core, rule baseline and Geo data all
 * follow the same download -> verify -> replace flow and used to duplicate
 * progress polling; keeping them as in-page tabs removes two top-level
 * entries without touching their RPCs.
 */
return view.extend({
	load: function() {
		return Promise.all([
			corePanel.load(),
			rulesPanel.load(),
			geoPanel.load()
		]);
	},
	render: function(results) {
		return tabs.build([
			{ id: 'core', title: _('Core'), render: function() { return corePanel.render(results[0]); } },
			{ id: 'rules', title: _('Rules'), render: function() { return rulesPanel.render(results[1]); } },
			{ id: 'geo', title: _('Geo Data'), render: function() { return geoPanel.render(results[2]); } }
		]);
	},
	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
