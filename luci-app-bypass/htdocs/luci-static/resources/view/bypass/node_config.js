'use strict';
'require view';
'require form';
'require uci';

// Read the editing section id from the URL query (?section=<id>). Reached via
// the Node List row extedit link; if opened without a section, show a hint.
function currentSection() {
	return new URLSearchParams(window.location.search).get('section');
}

return view.extend({
	load: function () {
		return uci.load('bypass');
	},

	render: function () {
		var sid = currentSection();

		if (!sid || uci.get('bypass', sid, '.type') !== 'nodes') {
			var hint = new form.Map('bypass', _('Node Config'));
			var hs = hint.section(form.NamedSection, '__dummy__', 'nodes', _('No node selected'));
			hs.option(form.DummyValue, '_hint', _('Pick a node from the Node List to edit, or add a new one there.')).optional = true;
			return hint.render();
		}

		var m = new form.Map('bypass', _('Node Config'),
			_('NaiveProxy node (https).'));
		var s = m.section(form.NamedSection, sid, 'nodes', _('Node') + ': ' + sid);

		var o;

		o = s.option(form.Value, 'remarks', _('Remarks'));
		o.rmempty = false;

		o = s.option(form.Value, 'address', _('Address (server)'));
		o.description = _('Domain or IP of the NaiveProxy server.');
		o.datatype = 'host';
		o.rmempty = false;

		o = s.option(form.Value, 'port', _('Port'));
		o.datatype = 'port';
		o.placeholder = '443';
		o.rmempty = false;

		o = s.option(form.Value, 'username', _('Username'));

		o = s.option(form.Value, 'password', _('Password'));
		o.password = true;

		return m.render();
	}
});
