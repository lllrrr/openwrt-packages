'use strict';
'require view';
'require form';
'require uci';

// Shunt-rule editor — reached from Rule Manage's table (extedit). Mirrors
// passwall2's client/shunt_rules.lua: a NamedSection editor for one rule with
// protocol / inbound / source / port / domain / IP / network match fields.
// If opened without a valid ?rule=
// section, redirect to the list.

function validatePortMatch(_sid, value) {
	if (!value) return true;
	if (!/^\d+(?:-\d+)?(?:,\d+(?:-\d+)?)*$/.test(value))
		return _('Use comma-separated ports or ranges, for example 80,443,1000-2000.');
	var entries = value.split(',');
	for (var i = 0; i < entries.length; i++) {
		var range = entries[i].split('-');
		var first = +range[0], last = +(range[1] || range[0]);
		if (first < 1 || last > 65535 || first > last)
			return _('Ports must be between 1 and 65535 and ranges must be ascending.');
	}
	return true;
}

function validateSourceMatch(_sid, value) {
	var values = Array.isArray(value) ? value : [value];
	for (var i = 0; i < values.length; i++) {
		var item = String(values[i] || '').trim();
		if (!item) continue;
		if (/^geoip:[A-Za-z0-9_-]+$/.test(item)) continue;
		var cidr = item.split('/');
		if (cidr.length > 2) return _('Enter an IPv4/IPv6 address, CIDR, or geoip: rule.');
		if (cidr.length === 2 && !/^\d+$/.test(cidr[1]))
			return _('Enter an IPv4/IPv6 address, CIDR, or geoip: rule.');
		if (cidr[0].indexOf(':') >= 0) {
			if (!/^[0-9A-Fa-f:.]+$/.test(cidr[0]) || (cidr[1] && (+cidr[1] < 0 || +cidr[1] > 128)))
				return _('Enter an IPv4/IPv6 address, CIDR, or geoip: rule.');
			continue;
		}
		var octets = cidr[0].split('.');
		if (octets.length !== 4 || octets.some(function (v) { return !/^\d+$/.test(v) || +v > 255; }) ||
			(cidr[1] && (+cidr[1] < 0 || +cidr[1] > 32)))
			return _('Enter an IPv4/IPv6 address, CIDR, or geoip: rule.');
	}
	return true;
}

return view.extend({
	load: function () {
		return uci.load('bypass');
	},

	render: function () {
		var sid = new URLSearchParams(window.location.search).get('rule');

		if (!sid || uci.get('bypass', sid, '.type') !== 'shunt_rules') {
			// No valid section — bounce back to the list.
			window.location.assign(L.url('admin/services/bypass/rule_manage'));
			return E('div', { class: 'cbi-map' }, [
				E('p', {}, _('Redirecting to Rule Manage…'))
			]);
		}

		var m = new form.Map('bypass', _('Edit Shunt Rule: %s').format(sid));

		var s = m.section(form.NamedSection, sid, 'shunt_rules', '');
		s.addremove = false;

		var o;

		o = s.option(form.Value, 'remarks', _('Name'));
		o.rmempty = false;

		o = s.option(form.MultiValue, 'protocol', _('Protocol'));
		o.value('http', 'HTTP');
		o.value('tls', 'TLS');
		o.description = _('BypassCore currently identifies HTTP and TLS traffic through transparent-inbound sniffing.');

		o = s.option(form.MultiValue, 'inbound', _('Inbound Tag'));
		o.value('tproxy', _('Transparent proxy'));
		o.description = _('Restrict this rule to traffic entering through the BypassCore transparent inbound.');

		o = s.option(form.ListValue, 'network', _('Network'));
		o.value('tcp', 'TCP');
		o.value('udp', 'UDP');
		o.value('tcp,udp', 'TCP + UDP');
		o.default = 'tcp,udp';

		o = s.option(form.DynamicList, 'source', _('Source'));
		o.placeholder = '192.168.1.100';
		o.validate = validateSourceMatch;
		o.description = _('Source IPv4/IPv6 address, CIDR, or geoip: rule, for example 192.168.1.0/24 or geoip:private.');

		o = s.option(form.Value, 'port', _('Port'));
		o.placeholder = '80,443,1000-2000';
		o.validate = validatePortMatch;

		o = s.option(form.ListValue, 'rule_type', _('Rule Type'));
		o.value('domain', _('Domain list'));
		o.value('ip', _('IP / CIDR list'));
		o.default = 'domain';
		o.description = _('A rule matches either domains or IPs, not both. Saving keeps only the selected list and discards the other one.');
		// UI-only selector derived from whichever list is populated; it is never
		// persisted to UCI. forcewrite normalizes legacy dual-list rules on every
		// save, so a stale hidden list cannot keep matching in the generated
		// BypassCore config.
		o.forcewrite = true;
		o.cfgvalue = function (section_id) {
			var dom = uci.get('bypass', section_id, 'domain_list');
			var ips = uci.get('bypass', section_id, 'ip_list');
			return (ips && !dom) ? 'ip' : 'domain';
		};
		o.write = function (section_id, formvalue) {
			if (formvalue === 'ip')
				uci.unset('bypass', section_id, 'domain_list');
			else
				uci.unset('bypass', section_id, 'ip_list');
		};

		o = s.option(form.TextValue, 'domain_list', _('Domain list'));
		o.rows = 8;
		o.wrap = 'off';
		o.placeholder = 'geosite:cn\ngeosite:category-ads-all\ndomain:example.com';
		o.description = _('One rule per line. v2ray prefixes: geosite:, domain:, full:, regexp:, ext:, or a bare domain.');
		o.depends('rule_type', 'domain');
		// Refuse to save an empty selected list: normalization discards the other
		// list, so an empty selection would leave the rule with no match condition
		// at all. The generator skips such rules loudly, but rejecting the save
		// here surfaces the mistake immediately.
		o.rmempty = false;
		o.validate = function (section_id, value) {
			if (!value || !value.trim())
				return _('The selected list must not be empty; a rule without match conditions would be skipped entirely.');
			return true;
		};

		o = s.option(form.TextValue, 'ip_list', _('IP / CIDR list'));
		o.rows = 8;
		o.wrap = 'off';
		o.placeholder = 'geoip:cn\ngeoip:private\n10.0.0.0/8';
		o.description = _('One rule per line. geoip:, ext:, or a bare CIDR / IP.');
		o.depends('rule_type', 'ip');
		o.rmempty = false;
		o.validate = function (section_id, value) {
			if (!value || !value.trim())
				return _('The selected list must not be empty; a rule without match conditions would be skipped entirely.');
			return true;
		};

		var node = m.render();
		var legacyDomain = uci.get('bypass', sid, 'domain_list');
		var legacyIp = uci.get('bypass', sid, 'ip_list');
		if (legacyDomain && legacyIp) {
			// Legacy dual-list rule: the selector defaults to "domain", so the
			// next save discards the IP list. Surface its content now so the
			// user can move it into a separate rule before saving.
			return node.then(function (rendered) {
				return E('div', {}, [
					E('div', { class: 'alert-message warning' }, [
						E('p', {}, _('This rule still contains both a domain list and an IP list. Saving keeps only the list of the selected Rule Type; the other list shown below will be discarded. Copy it into a separate rule first if you still need it.')),
						E('pre', { style: 'white-space:pre-wrap;margin:0' }, legacyIp)
					]),
					rendered
				]);
			});
		}
		return node;
	},

	addFooter: function () {
		var footer = this.super('addFooter', []);
		var actions = footer.querySelector('.cbi-page-actions');
		if (actions) {
			actions.insertBefore(E('button', {
				type: 'button',
				class: 'cbi-button cbi-button-neutral',
				click: function () { window.location.assign(L.url('admin/services/bypass/rule_manage')); }
			}, _('Back')), actions.firstChild);
			actions.insertBefore(document.createTextNode(' '), actions.childNodes[1] || null);
		}
		return footer;
	}
});
