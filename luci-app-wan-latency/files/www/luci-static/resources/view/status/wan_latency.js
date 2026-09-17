'use strict';
// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 xiaokeikei
'require view';
'require fs';

var API = '/usr/libexec/wan-latency-api';

return view.extend({
	render: function () {
		/* Route all data access through LuCI's authenticated RPC bridge. */
		window.wanLatencyApi = function(query) {
			return fs.exec_direct(API, [ String(query || '') ], 'json');
		};

		var frame = E('iframe', {
			src: '/wan-latency/index.html?v=20260908-v120',
			style: 'width:100%;height:calc(100vh - 120px);border:0;border-radius:12px;background:transparent'
		});
		return E('div', { style: 'margin:-8px' }, [frame]);
	},
	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
