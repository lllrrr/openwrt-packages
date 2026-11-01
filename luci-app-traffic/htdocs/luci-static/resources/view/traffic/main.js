'use strict';
'require view';

return view.extend({
	load: function() {
		return Promise.resolve();
	},

	render: function() {
		// 加时间戳强制绕过浏览器缓存，否则更新前端后仍会加载旧页面
		var frame = E('iframe', {
			'src': '/traffic/?v=' + Date.now(),
			'style': 'width:100%;height:calc(100vh - 150px);min-height:600px;border:0;border-radius:8px;display:block'
		});
		return frame;
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
