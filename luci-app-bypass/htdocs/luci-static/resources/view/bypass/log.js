'use strict';
'require view';
'require fs';
'require ui';

// Runtime Logs — mirrors passwall2's log/log.htm: a readonly textarea polled
// every 5 seconds via api.sh log_tail, a Clear button, and auto-scroll-to-
// bottom when the user is already at the bottom.

function api(/* action, ...args */) {
	return fs.exec('/usr/share/bypass/api.sh', Array.prototype.slice.call(arguments)).then(function (res) {
		try { return JSON.parse(res.stdout || '{}'); }
		catch (e) { return { code: -1, error: 'bad JSON' }; }
	}).catch(function (e) { return { code: -1, error: String(e) }; });
}

return view.extend({
	render: function () {
		var ta = E('textarea', {
			class: 'cbi-input-textarea',
			id: 'bypass_log_textarea',
			style: 'width:100%;margin-top:10px;font-family:monospace;font-size:12px',
			rows: 40,
			wrap: 'off',
			readonly: 'readonly'
		});

		var firstLoad = true;
		function isAtBottom() {
			return (ta.scrollTop + ta.clientHeight + 4) >= ta.scrollHeight;
		}

		function refreshLog() {
			var wasBottom = isAtBottom();
			api('log_tail', '500').then(function (r) {
				ta.value = r.log || '';
				// Auto-scroll on first load, or if the user was already at the bottom.
				if (firstLoad || wasBottom) {
					ta.scrollTop = ta.scrollHeight;
					firstLoad = false;
				}
			});
		}

		var clearBtn = E('button', {
			class: 'cbi-button cbi-button-remove',
			click: function () {
				api('clear_log').then(function () {
					ta.value = '';
					ta.scrollTop = ta.scrollHeight;
				});
			}
		}, _('Clear logs'));

		// Start polling every 5 seconds (matches passwall2).
		refreshLog();
		var pollHandle = setInterval(refreshLog, 5000);
		// Stop polling when leaving the page.
		window.addEventListener('popsstate', function () { clearInterval(pollHandle); });

		return E('div', { class: 'cbi-map' }, [
			E('h2', { name: 'content' }, _('Runtime Logs')),
			E('div', { style: 'margin-bottom:8px' }, [clearBtn]),
			ta
		]);
	},

	handleReset: null,
	handleSaveApply: null,
	handleSave: null
});
