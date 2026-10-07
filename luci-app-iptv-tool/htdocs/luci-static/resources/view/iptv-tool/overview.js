'use strict';
'require view';

return view.extend({
	render: function() {
		var host = window.location.hostname;
		var src = 'http://' + host + ':8023/';

		var iframe = E('iframe', {
			src: src,
			width: '100%',
			height: '800px',
			style: 'border: 1px solid #ccc; border-radius: 4px; background: #fff;'
		});

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('IPTV-Tool')),
			E('div', { 'class': 'cbi-map-descr' },
				_('IPTV Toolbox: EPG, Live Source, and Logo Management.')),
			iframe
		]);
	}
});
