'use strict';
'require view';
'require form';

// Every user-visible string is an English msgid wrapped in _().  The Chinese
// text lives in po/zh_Hans/trusted.po and is compiled into
// /usr/lib/lua/luci/i18n/trusted.zh-cn.lmo, which is also what the shell side
// reads.  Do not put translated text back into this file: a hardcoded string
// can never follow the LuCI language setting.

// The ruleset generator, the CGI wrapper and the session back end all speak
// plain IPv4 only.  Validating here keeps a value the firewall would reject
// (IPv6, "10.3.2.0/255.255.255.0", 999.1.1.1) out of the configuration in the
// first place - it used to be accepted by the form and then took the whole
// firewall down.
function checkV4(section_id, value) {
	value = (value || '').trim();

	if (!value)
		return true;

	var m = value.match(/^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})(?:\/(\d{1,2}))?$/);

	if (!m)
		return _('Enter an IPv4 address or a subnet. Example: 10.3.2.5 or 10.3.2.0/24.');

	for (var i = 1; i <= 4; i++) {
		var o = m[i];

		if (o.length > 1 && o.charAt(0) === '0')
			return _('Remove the leading zero from each part. Example: type 10.3.2.8, not 10.3.2.08.');

		if (+o > 255)
			return _('Each part must be a number from 0 to 255.');
	}

	if (m[5] !== undefined && +m[5] > 32)
		return _('The subnet prefix must be a number from 0 to 32.');

	return true;
}

// Current whitelist entries as the form shows them.  Used by the deny switch:
// an empty whitelist plus "block non-whitelisted devices" locks the
// administrator out of the very page needed to undo it.
function wlEntries(opt, section_id) {
	var list = opt.formvalue(section_id);

	if (list == null)
		list = opt.cfgvalue(section_id);

	if (list == null)
		return [];

	if (!Array.isArray(list))
		list = [ list ];

	return list.filter(function (v) {
		return v != null && String(v).trim() !== '';
	});
}

return view.extend({
	render: function() {
		var m, s, o, oIp;

		m = new form.Map('trusted', _('Trusted Access'),
			_('Devices in the whitelist can open the LuCI web page, the web terminal, and SSH without a password.') + '<br />' +
			_('You can add one IP address (10.3.2.5) or one subnet (10.3.2.0/24). Only IPv4 is supported. The router always trusts 127.0.0.1.') + '<br />' +
			_('The whitelist must contain at least one address. The router does not accept an empty whitelist.'));

		s = m.section(form.TypedSection, 'trusted', _('Whitelist'));
		s.anonymous = true;

		o = s.option(form.Flag, 'enabled', _('Enable'));
		o.default = false;

		oIp = s.option(form.DynamicList, 'ipaddr', _('IP address'),
			_('Enter an IP address or a subnet that you trust. Example: 10.3.2.5 or 10.3.2.0/24.') + '<br />' +
			_('Add the address that your device uses now.'));
		oIp.datatype = 'string';
		oIp.placeholder = '10.3.2.5';
		// An empty whitelist makes the whole plugin useless and, together with
		// the deny switch, unrecoverable from the browser.  Require one entry.
		oIp.rmempty = false;
		oIp.validate = checkV4;
		oIp.depends('enabled', '1');

		o = s.option(form.Flag, 'term_enabled', _('Web terminal without a password'),
			_('If you enable this option, whitelisted devices can log in to the web terminal without a password.') + '<br />' +
			_('This option applies to whitelisted devices only. Devices outside the whitelist can still log in to the web terminal with a user name and a password.'));
		o.default = false;
		o.depends('enabled', '1');

		o = s.option(form.Flag, 'ssh_enabled', _('SSH without a password'),
			_('If you enable this option, a whitelisted device runs ssh trusted@router-address and reaches a root shell without a login.') + '<br />' +
			_('This option applies to whitelisted devices only. Devices outside the whitelist can still log in on port 22 with a password or a key.'));
		o.default = false;
		o.depends('enabled', '1');

		o = s.option(form.Flag, 'deny_others', _('Block devices that are not in the whitelist'),
			_('If you enable this option, the router blocks devices outside the whitelist from the LuCI web page and the web terminal.') + '<br />' +
			_('This option is independent of the two options above. It does not change how whitelisted devices get in without a password.') + '<br />' +
			_('Caution: the whitelist must contain your own address. If it does not, you cannot open this page after you save the configuration.') + '<br />' +
			_('Before you enable this option, make sure that you know the root password. Also make sure that you have a valid SSH key. If the router blocks you, log in with SSH and run trusted deny off. If SSH is not available, use the serial console.'));
		o.default = false;
		o.depends('enabled', '1');
		o.validate = function (section_id, value) {
			if (value !== '1')
				return true;

			if (wlEntries(oIp, section_id).length > 0)
				return true;

			return _('The whitelist is empty. Add your own address in "IP address" first. Then enable this option. If you save now, the firewall blocks your device and you cannot open this page.');
		};

		return m.render();
	}
});
