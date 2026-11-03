'use strict';
'require view';
'require uci';

return view.extend({
	load: function() {
		return uci.load('shellinabox');
	},
	render: function() {
		if (uci.get('shellinabox', 'main', 'enable') === '0')
			return E('div', { class: 'alert-message warning' },
					_('ShellInABox is disabled. Enable it in Config and try again.'));
		var iframe = E('iframe', {
			src: L.url('admin/system/shellinabox/launch'),
			style: 'display: block; width: 100%; flex: 1; min-height: 0; border: none;'
		});
		var handle = E('div', {
			role: 'separator', tabindex: '0',
			'aria-label': _('Terminal height'),
			'aria-orientation': 'horizontal',
			'aria-valuemin': '500', 'aria-valuenow': '500',
			style: 'flex: 0 0 12px; cursor: ns-resize; touch-action: none; user-select: none; background: linear-gradient(#888, #888) center / 32px 2px no-repeat;'
		});
		var container = E('div', {
			style: 'display: flex; flex-direction: column; gap: 0; height: 500px; min-height: 500px; overflow: hidden; border-radius: 3px;'
		}, [iframe, handle]);
		var drag = null;
		function setHeight(height) {
			height = Math.max(500, Math.round(height));
			container.style.height = height + 'px';
			handle.setAttribute('aria-valuenow', height);
		}
		function stop() {
			if (!drag)
				return;
			var id = drag.id;
			drag = null;
			iframe.style.pointerEvents = '';
			window.removeEventListener('blur', stop);
			if (handle.hasPointerCapture(id))
				handle.releasePointerCapture(id);
		}
		// Capture the pointer and keep the cross-origin terminal from taking
		// mouse events until release. A plain click never sets the height.
		handle.addEventListener('pointerdown', function(ev) {
			if (ev.button !== 0 || !ev.isPrimary || drag)
				return;
			handle.setPointerCapture(ev.pointerId);
			drag = { id: ev.pointerId, y: ev.clientY, height: container.offsetHeight };
			iframe.style.pointerEvents = 'none';
			window.addEventListener('blur', stop);
			ev.preventDefault();
		});
		handle.addEventListener('pointermove', function(ev) {
			if (!drag || drag.id !== ev.pointerId)
				return;
			if (!ev.buttons) {
				stop();
				return;
			}
			setHeight(drag.height + ev.clientY - drag.y);
		});
		['pointerup', 'pointercancel', 'lostpointercapture'].forEach(function(type) {
			handle.addEventListener(type, stop);
		});
		handle.addEventListener('keydown', function(ev) {
			if (ev.key === 'ArrowUp' || ev.key === 'ArrowDown') {
				setHeight(container.offsetHeight + (ev.key === 'ArrowUp' ? -20 : 20));
				ev.preventDefault();
			}
		});
		return container;
	},
	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
