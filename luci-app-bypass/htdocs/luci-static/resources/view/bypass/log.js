'use strict';
'require view';
'require fs';
'require ui';

return view.extend({
	load: function () {
		return fs.exec('/usr/share/bypass/api.sh', ['log_tail', '300']).then(function (res) {
			try { return JSON.parse(res.stdout || '{}').log || ''; }
			catch (e) { return ''; }
		}).catch(function () { return ''; });
	},

	render: function (log) {
		var pre = E('pre', { class: 'cbi-section', style: 'white-space:pre-wrap;max-height:600px;overflow:auto;font-size:11px' }, log || _('(no log yet)'));

		var container = E('div', { class: 'cbi-map' }, [
			E('h2', { name: 'content' }, _('Log')),
			E('div', { class: 'cbi-section' }, [
				E('div', { style: 'margin-bottom:8px' }, [
					E('button', {
						class: 'cbi-button cbi-button-neutral',
						click: function () {
							fs.exec('/usr/share/bypass/api.sh', ['log_tail', '300']).then(function (res) {
								var t = '';
								try { t = JSON.parse(res.stdout || '{}').log || ''; } catch (e) {}
								while (pre.firstChild) pre.removeChild(pre.firstChild);
								pre.appendChild(document.createTextNode(t || _('(no log yet)')));
							});
						}
					}, _('Refresh')),
					' ',
					E('button', {
						class: 'cbi-button cbi-button-reset',
						click: function () {
							fs.exec('/usr/share/bypass/api.sh', ['clear_log']).then(function () {
								while (pre.firstChild) pre.removeChild(pre.firstChild);
								pre.appendChild(document.createTextNode(_('(cleared)')));
							});
						}
					}, _('Clear'))
				])
			]),
			pre
		]);

		return container;
	}
});
