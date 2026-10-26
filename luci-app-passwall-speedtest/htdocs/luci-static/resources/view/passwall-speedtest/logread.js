'use strict';
'require view';
'require rpc';

const callGetLog = rpc.declare({
	object: 'passwall-speedtest',
	method: 'get_log',
	params: [ 'pos' ],
	expect: {}
});

return view.extend({
	logPos: 0,

	getLog: function(textarea) {
		return callGetLog(this.logPos).then(L.bind(function(data) {
			const content = (data && data.content) || '';

			if (content.length > 0) {
				// 长时尾随时 textarea 无限增长会拖死页面：超过 512KB 只保留末尾
				textarea.value = (textarea.value + content).slice(-524288);
				textarea.scrollTop = textarea.scrollHeight;
			}

			if (data && data.pos != null)
				this.logPos = parseInt(data.pos, 10) || this.logPos;
		}, this));
	},

	render: function() {
		const checkbox = E('input', {
			type: 'checkbox',
			id: 'passwall-speedtest-log-refresh',
			checked: true
		});

		const textarea = E('textarea', {
			id: 'passwall-speedtest-logview',
			'class': 'cbi-input-textarea',
			style: 'width: 100%',
			rows: 30,
			readonly: 'readonly'
		});

		window.setInterval(L.bind(function() {
			if (checkbox.checked)
				this.getLog(textarea);
		}, this), 5000);

		this.getLog(textarea);

		return E([], [
			E('h2', {}, _('Logs')),
			E('div', { 'class': 'cbi-section' }, [
				E('label', {}, [ checkbox, ' ', _('Auto refresh') ]),
				E('br'),
				textarea
			])
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
