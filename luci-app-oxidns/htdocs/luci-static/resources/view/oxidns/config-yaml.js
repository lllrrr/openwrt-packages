'use strict';
'require baseclass';

return baseclass.extend({
	render: function(content, options) {
		var handlers = options || {};

		var textarea = E('textarea', {
			'id': 'oxidns-config-content',
			'class': 'cbi-input-textarea',
			'style': 'width: 100%; min-height: 420px; font-family: monospace;',
			'spellcheck': 'false',
			'input': function(ev) {
				if (typeof handlers.onInput === 'function')
					handlers.onInput(ev.target.value);
			}
		});

		textarea.value = content || '';
		textarea.defaultValue = content || '';

		return E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('YAML')),
			E('div', { 'class': 'cbi-section-descr' },
				_('Advanced mode saves the text exactly as written. Normal mode rewrites only the fields it manages.')),
			textarea
		]);
	},

	value: function(fallback) {
		var textarea = document.getElementById('oxidns-config-content');
		return textarea ? textarea.value : (fallback || '');
	}
});
