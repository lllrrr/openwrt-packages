'use strict';
'require view';
'require rpc';
'require dom';
'require ui';
'require uci';

var callServiceList = rpc.declare({
	object: 'service',
	method: 'list',
	params: ['name'],
	expect: { '': {} }
});

function getServiceStatus() {
	return callServiceList('mydomain').then(function(result) {
		return result || {};
	}).catch(function() {
		return {};
	});
}

return view.extend({
	load: function() {
		return Promise.all([
			uci.load('mydomain'),
			getServiceStatus()
		]);
	},

	render: function(data) {
		var mydomain = data[0];
		var service = data[1];

		var ddnsSection = E('fieldset', { 'class': 'cbi-section' }, [
			E('legend', {}, _('Dynamic DNS Status')),
			E('table', { 'class': 'table' }, [
				E('tr', { 'class': 'tr table-titles' }, [
					E('th', { 'class': 'th' }, _('Name')),
					E('th', { 'class': 'th' }, _('Domain')),
					E('th', { 'class': 'th' }, _('Status')),
					E('th', { 'class': 'th' }, _('Enabled'))
				])
			])
		]);

		var proxySection = E('fieldset', { 'class': 'cbi-section' }, [
			E('legend', {}, _('Reverse Proxy Status')),
			E('table', { 'class': 'table' }, [
				E('tr', { 'class': 'tr table-titles' }, [
					E('th', { 'class': 'th' }, _('Name')),
					E('th', { 'class': 'th' }, _('Frontend Port')),
					E('th', { 'class': 'th' }, _('Backend URL')),
					E('th', { 'class': 'th' }, _('Enabled'))
				])
			])
		]);

		var certSection = E('fieldset', { 'class': 'cbi-section' }, [
			E('legend', {}, _('Certificate Status')),
			E('table', { 'class': 'table' }, [
				E('tr', { 'class': 'tr table-titles' }, [
					E('th', { 'class': 'th' }, _('Name')),
					E('th', { 'class': 'th' }, _('Domain')),
					E('th', { 'class': 'th' }, _('Status'))
				])
			])
		]);

		// Add DDNS entries
		uci.sections('mydomain', 'ddns').forEach(function(s) {
			var row = E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td' }, s['.name']),
				E('td', { 'class': 'td' }, s.domain || '-'),
				E('td', { 'class': 'td' }, s.enabled === '1' ? _('Active') : _('Inactive')),
				E('td', { 'class': 'td' }, s.enabled === '1' ? _('Yes') : _('No'))
			]);
			ddnsSection.lastElementChild.appendChild(row);
		});

		// Add proxy entries
		uci.sections('mydomain', 'proxy').forEach(function(s) {
			var row = E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td' }, s['.name']),
				E('td', { 'class': 'td' }, s.frontend_port || '-'),
				E('td', { 'class': 'td' }, s.backend_url || '-'),
				E('td', { 'class': 'td' }, s.enabled === '1' ? _('Yes') : _('No'))
			]);
			proxySection.lastElementChild.appendChild(row);
		});

		// Add certificate entries
		uci.sections('mydomain', 'certificate').forEach(function(s) {
			var row = E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td' }, s['.name']),
				E('td', { 'class': 'td' }, s.domain || '-'),
				E('td', { 'class': 'td' }, s.enabled === '1' ? _('Valid') : _('Invalid'))
			]);
			certSection.lastElementChild.appendChild(row);
		});

		return E('div', {}, [
			E('h2', {}, _('MyDomain Status')),
			ddnsSection,
			proxySection,
			certSection
		]);
	}
});
