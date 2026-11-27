'require view';
'require view.oxidns.tabs as tabs';
'require view.oxidns.parts.config as configPanel';
'require view.oxidns.parts.settings as settingsPanel';
'require view.oxidns.parts.prewarm as prewarmPanel';

/*
 * Consolidated configuration page: runtime YAML, plugin meta settings and
 * prewarm task. These edit different layers and stay as separate in-page tabs
 * rather than being merged into one form.
 */
return view.extend({
	load: function() {
		return Promise.all([
			configPanel.load(),
			settingsPanel.load(),
			prewarmPanel.load()
		]);
	},
	render: function(results) {
		return tabs.build([
			{ id: 'config', title: _('Configuration'), render: function() { return configPanel.render(results[0]); } },
			{
				id: 'settings',
				title: _('Settings'),
				hashes: [ 'settings', 'api-credentials' ],
				anchor: 'api-credentials',
				render: function() { return settingsPanel.render(results[1]); }
			},
			{ id: 'prewarm', title: _('Prewarm'), render: function() { return prewarmPanel.render(results[2]); } }
		]);
	},
	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
