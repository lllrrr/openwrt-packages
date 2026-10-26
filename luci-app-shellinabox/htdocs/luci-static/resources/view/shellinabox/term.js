'use strict';
'require view';
'require uci';

return view.extend({
	load: function() {
		return uci.load('shellinabox');
	},
	render: function() {
		if (uci.get('shellinabox', 'main', 'enable') === '0')
			return E('div', { class: 'alert-message warning' },
					_('ShellInABox is disabled. Enable it in Config and try again.'));
		return E('iframe', {
			src: L.url('admin/system/shellinabox/launch'),
			style: 'width: 100%; min-height: 500px; border: none; border-radius: 3px; resize: vertical;'
		});
	},
	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
