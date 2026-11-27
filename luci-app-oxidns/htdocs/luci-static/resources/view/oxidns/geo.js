'require view';
'require view.oxidns.parts.geo as panel';

// Compatibility shim: the panel logic lives in parts/geo.js so it can
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
