'use strict';
'require baseclass';

return baseclass.extend({
	resolveUrl: function(uciData, statusData) {
		uciData = uciData || {};
		statusData = statusData || {};

		var panelType = uciData.panel_type || 'zashboard';
		var panelMode = uciData.panel_mode || 'auto';
		var panelUrl = uciData.panel_url || '';
		var remoteUrl = uciData.remote_url || 'https://board.zash.run.place/';
		var withQuery = (uciData.panel_query !== '0');
		var protocol = uciData.panel_protocol || 'auto';
		var extraQuery = uciData.panel_query_extra || '';

		var hostname = window.location.hostname || '127.0.0.1';
		var apiPort = statusData.api_port || uciData.api_port || 9999;
		var secret = statusData.secret || uciData.secret || '';

		if (protocol === 'auto') {
			protocol = (statusData.api_tls) ? 'https' : 'http';
		}

		var targetUrl = '';
		if (panelMode === 'custom' && panelUrl) {
			targetUrl = panelUrl;
		} else if (panelMode === 'core' || (panelMode === 'auto' && statusData.panel_core_installed)) {
			targetUrl = protocol + '://' + hostname + ':' + apiPort + '/ui/';
		} else if (panelMode === 'local' || (panelMode === 'auto' && statusData.panel_local_installed)) {
			targetUrl = '/zashboard/';
		} else if (panelMode === 'remote' || panelMode === 'auto') {
			if (panelType === 'metacubexd') {
				targetUrl = 'https://metacubex.github.io/metacubexd/';
			} else if (panelType === 'yacd') {
				targetUrl = 'http://yacd.haishan.me/';
			} else {
				targetUrl = remoteUrl || 'https://board.zash.run.place/';
			}
		}

		if (withQuery && targetUrl) {
			var joinChar = (targetUrl.indexOf('?') >= 0) ? '&' : '?';
			var q = 'hostname=' + encodeURIComponent(hostname) +
			        '&port=' + encodeURIComponent(apiPort) +
			        '&secret=' + encodeURIComponent(secret);
			if (extraQuery) {
				q += '&' + extraQuery.replace(/^[?&]+/, '');
			}
			targetUrl += joinChar + q;
		}

		return targetUrl;
	}
});
