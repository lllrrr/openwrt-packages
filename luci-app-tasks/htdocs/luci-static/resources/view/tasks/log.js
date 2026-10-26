'use strict';
'require view';
'require fs';
'require ui';

var LOG = '/etc/tasks/tasks.log';

/* Keep in sync with TASKS_LOG_LIMIT in /usr/lib/tasks/common.sh. */
var MAX_LINES = 500;

/* Load the shared stylesheet once. It only uses theme CSS variables, so it
 * follows the light / dark variant of Bootstrap and Argon by itself. */
function addStylesheet()
{
	if (document.querySelector('link[data-tasks-style]'))
		return;

	document.head.appendChild(E('link', {
		'rel': 'stylesheet',
		'type': 'text/css',
		'href': L.resource('view/tasks.css'),
		'data-tasks-style': '1'
	}));
}

function splitLines(text)
{
	text = (text || '').replace(/\s+$/, '');

	if (text === '')
		return [];

	return text.split('\n').slice(-MAX_LINES);
}

return view.extend({
	load: function() {
		return L.resolveDefault(fs.read(LOG), '');
	},

	render: function(data) {
		addStylesheet();

		var newestFirst = true;
		var raw = data || '';

		var logBox = E('pre', { 'class': 'tasks-log' });

		var counter = E('em', {}, '');

		function paint() {
			var lines = splitLines(raw);

			if (newestFirst)
				lines.reverse();

			if (!lines.length) {
				logBox.textContent = _('The log is empty. Scheduled and manually started tasks are recorded here.');
			}
			else {
				logBox.textContent = lines.join('\n');
			}

			counter.textContent = _('%d line(s)').format(splitLines(raw).length);
		}

		function refresh() {
			return L.resolveDefault(fs.read(LOG), '').then(function(text) {
				raw = text || '';
				paint();
			});
		}

		function clearLog() {
			ui.showModal(_('Confirm'), [
				E('p', {}, _('Delete all log entries? This cannot be undone.')),
				E('div', { 'class': 'right' }, [
					E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Cancel')),
					' ',
					E('button', {
						'class': 'cbi-button cbi-button-negative',
						'click': function() {
							ui.hideModal();

							/* Not wrapped in L.resolveDefault(): a failed write must
							 * surface as an error instead of a success message. */
							return fs.write(LOG, '').then(function() {
								ui.addNotification(null, E('p', {}, _('Log cleared.')), 'success');
								return refresh();
							}).catch(function(err) {
								ui.addNotification(null, E('p', {},
									_('Could not clear the log: %s').format(err.message || _('unknown error'))), 'danger');
							});
						}
					}, _('Clear log'))
				])
			]);
		}

		function downloadLog() {
			return L.resolveDefault(fs.read(LOG), '').then(function(text) {
				var blob = new Blob([ text || '' ], { type: 'text/plain' });
				var url = URL.createObjectURL(blob);
				var a = E('a', { 'href': url, 'download': 'tasks.log' });

				document.body.appendChild(a);
				a.click();
				document.body.removeChild(a);

				window.setTimeout(function() { URL.revokeObjectURL(url); }, 1000);
			});
		}

		paint();

		L.Poll.add(refresh, 5);

		return E('div', {}, [
			E('div', { 'class': 'cbi-section tasks-log-section' }, [
				E('div', { 'class': 'tasks-toolbar' }, [
					E('button', {
						'class': 'cbi-button cbi-button-neutral',
						'click': function() { refresh(); }
					}, _('Refresh')),
					E('button', {
						'class': 'cbi-button cbi-button-neutral',
						'click': function() { downloadLog(); }
					}, _('Download')),
					E('button', {
						'class': 'cbi-button cbi-button-negative',
						'click': function() { clearLog(); }
					}, _('Clear log')),
					E('label', {}, [
						E('input', {
							'type': 'checkbox',
							'checked': newestFirst ? '' : null,
							'change': function(ev) {
								newestFirst = ev.target.checked;
								paint();
							}
						}),
						E('span', {}, _('Newest first'))
					])
				]),
				E('p', {}, [
					_('Updates automatically every 5 seconds.'), ' ', counter
				]),
				logBox
			])
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
