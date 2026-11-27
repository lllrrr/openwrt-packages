'require view';
'require view.oxidns.parts.rules as panel';

// Compatibility shim: the panel logic lives in parts/rules.js so it can
// be embedded in a consolidated tab container. Keeping this path lets old
// bookmarks and direct URLs continue to work.
return view.extend({
	load: function() {
		return panel.load();
	},
	render: function(data) {
		return panel.render(data);
	},
	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
