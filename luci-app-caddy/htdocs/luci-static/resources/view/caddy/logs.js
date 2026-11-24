'use strict';
'require dom';
'require fs';
'require poll';
'require rpc';
'require ui';
'require view';

const callGetLog = rpc.declare({
	object: 'luci.caddy',
	method: 'get_log',
	expect: { '': {} }
});

const callClearLog = rpc.declare({
	object: 'luci.caddy',
	method: 'clear_log',
	expect: { '': {} }
});

let scrollPosition = 0;
let userScrolled = false;
let logTextarea;

function pollLog() {
	return callGetLog().then(res => {
		if (logTextarea) {
			logTextarea.value = res.log || _('No log data.');
			if (!userScrolled) {
				logTextarea.scrollTop = logTextarea.scrollHeight;
			}
		}
	});
}

return view.extend({
	handleClearLog() {
		return callClearLog().then(res => {
			if (logTextarea) {
				logTextarea.value = '';
			}
		});
	},

	render() {
		logTextarea = E('textarea', {
			'class': 'cbi-input-textarea',
			'wrap': 'off',
			'readonly': 'readonly',
			'style': 'width: calc(100% - 20px);height: 535px;overflow-y: scroll;',
		});

		const log_textarea_wrapper = E('div', { 'id': 'log_textarea' }, logTextarea);

		poll.add(pollLog);

		return E([
			E('div', { 'class': 'cbi-map' }, [
				E('h2', {}, '%s - %s'.format(_('Caddy'), _('Log Data'))),
				E('div', { 'class': 'cbi-section' }, [
					E('div', { 'style': 'margin-bottom: 10px;' }, [
						E('button', {
							'class': 'cbi-button cbi-button-negative',
							'click': ui.createHandlerFn(this, 'handleClearLog')
						}, _('Clear Log'))
					]),
					log_textarea_wrapper,
				])
			])
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
