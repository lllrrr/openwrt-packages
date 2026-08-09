'use strict';
'require view';
'require fs';
'require ui';

// Geo View — query page mirroring passwall2's rule/geoview.htm.
// Two query modes:
//   • Domain/IP Query (lookup): enter a domain or IP → which geo rule lists it belongs to.
//   • GeoIP/Geosite Query (extract): enter geoip:cn / geosite:gfw → extract member domains/IPs.
// Both write into a shared readonly textarea. Calls api.sh geo_view which wraps
// the geoview binary with correct -type / -input / -value|-list flags.

function api(/* action, ...args */) {
	return fs.exec('/usr/share/bypass/api.sh', Array.prototype.slice.call(arguments)).then(function (res) {
		try { return JSON.parse(res.stdout || '{}'); }
		catch (e) { return { code: -1, error: 'bad JSON' }; }
	}).catch(function (e) { return { code: -1, error: String(e) }; });
}

return view.extend({
	render: function () {
		var result = E('textarea', {
			id: 'geoview_textarea',
			class: 'cbi-input-textarea',
			style: 'width:100%;margin-top:10px;font-family:monospace;font-size:12px',
			rows: 25,
			wrap: 'off',
			readonly: 'readonly',
			placeholder: _('Results appear here.')
		});

		function setButtonsDisabled(state) {
			lookupBtn.disabled = state;
			extractBtn.disabled = state;
			listBtn.disabled = state;
		}

		function renderResponse(r) {
			if (r.code !== 0)
				return Promise.resolve(_('Error: ') + (r.error || r.output || _('unknown')));

			if (!r.stream)
				return Promise.resolve(r.output || _('No results were found!'));

			var chunks = [];
			var offset = 0;

			function readNext() {
				return api('geo_view', 'read', r.stream, String(offset)).then(function (part) {
					if (part.code !== 0)
						throw new Error(part.error || part.output || _('unknown'));

					chunks.push(part.output || '');
					var next = Number(part.next_offset);
					if (part.done === 1 || part.done === true)
						return chunks.join('');
					if (!isFinite(next) || next <= offset)
						throw new Error(_('Invalid Geo View result stream'));

					offset = next;
					return readNext();
				});
			}

			return readNext();
		}

		function runQuery(btn, request, busyLabel) {
			setButtonsDisabled(true);
			var oldLabel = btn.textContent;
			btn.textContent = busyLabel || _('Querying…');
			result.value = '';
			request.then(renderResponse).then(function (text) {
				result.value = text;
			}, function (e) {
				result.value = _('Error: ') + String(e);
			}).then(function () {
				setButtonsDisabled(false);
				btn.textContent = oldLabel;
			});
		}

		function doQuery(btn, action, input) {
			var value = (input.value || '').trim();
			if (!value) {
				ui.addNotification(null, E('p', {}, _('Please enter query content!')));
				return;
			}
			runQuery(btn, api('geo_view', action, value));
		}

		function doList(btn) {
			runQuery(btn, api('geo_view', 'list'), _('Listing…'));
		}

		function bindEnter(input, btn, action) {
			input.addEventListener('keydown', function (ev) {
				if (ev.key === 'Enter') { ev.preventDefault(); doQuery(btn, action, input); }
			});
		}

		var lookupInput = E('input', {
			type: 'text',
			id: 'geoview.lookup',
			class: 'password-input cbi-input-text',
			placeholder: _('Enter a domain or IP')
		});
		var lookupBtn = E('button', {
			type: 'button',
			id: 'lookup-view_btn',
			class: 'cbi-button cbi-button-apply'
		}, _('Query'));
		lookupBtn.addEventListener('click', function () { doQuery(lookupBtn, 'lookup', lookupInput); });
		bindEnter(lookupInput, lookupBtn, 'lookup');

		var extractInput = E('input', {
			type: 'text',
			id: 'geoview.extract',
			class: 'password-input cbi-input-text',
			placeholder: 'geoip:cn / geosite:gfw'
		});
		var extractBtn = E('button', {
			type: 'button',
			id: 'extract-view_btn',
			class: 'cbi-button cbi-button-apply'
		}, _('Query'));
		extractBtn.addEventListener('click', function () { doQuery(extractBtn, 'extract', extractInput); });
		bindEnter(extractInput, extractBtn, 'extract');

		var listBtn = E('button', {
			type: 'button',
			id: 'list-view_btn',
			class: 'cbi-button cbi-button-action'
		}, _('List'));
		listBtn.addEventListener('click', function () { doList(listBtn); });

		return E('div', { class: 'cbi-map', style: 'margin-bottom:2rem' }, [
			E('div', { class: 'cbi-value' }, [
				E('ul', {}, [
					E('strong', { style: 'color:var(--primary);display:inline-block;margin-bottom:.5rem' }, _('Tips:')),
					E('li', {}, _('By entering a domain or IP, you can query the Geo rule list they belong to.')),
					E('li', {}, _('By entering a GeoIP or Geosite, you can extract the domains/IPs they contain.')),
					E('li', {}, _('Use the GeoIP/Geosite query function to verify if the entered Geo rules are correct.'))
				])
			]),

			E('div', { class: 'cbi-value' }, [
				E('label', { class: 'cbi-value-title', for: 'geoview.lookup' }, _('Domain/IP Query')),
				E('div', { class: 'cbi-value-field' }, [
					E('div', { style: 'display:flex;gap:2px;align-items:center;white-space:nowrap' }, [lookupInput, lookupBtn]),
					E('div', { class: 'cbi-value-description' }, _('Enter a domain or IP to query the Geo rule list they belong to.'))
				])
			]),

			E('div', { class: 'cbi-value' }, [
				E('label', { class: 'cbi-value-title', for: 'geoview.extract' }, _('GeoIP/Geosite Query')),
				E('div', { class: 'cbi-value-field' }, [
					E('div', { style: 'display:flex;gap:2px;align-items:center;white-space:nowrap' }, [extractInput, extractBtn, listBtn]),
					E('div', { class: 'cbi-value-description' }, _('Enter a GeoIP or Geosite to extract the domains/IPs they contain. Format: geoip:cn or geosite:gfw'))
				])
			]),
			E('div', { class: 'cbi-value' }, result)
		]);
	},

	handleReset: null,
	handleSaveApply: null,
	handleSave: null
});
