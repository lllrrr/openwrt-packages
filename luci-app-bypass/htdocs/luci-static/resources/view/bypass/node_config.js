'use strict';
'require view';
'require form';
'require uci';
'require fs';

// Read the editing section id from the URL query (?section=<id>). Reached via
// the Node List row extedit link; if opened without a section, show a hint.
function currentSection() {
	var m = (window.location.search || '').match(/(?:^|&|;)section=([^&;]*)/);
	return m ? decodeURIComponent(m[1]) : null;
}

return view.extend({
	load: function () {
		return Promise.all([
			uci.load('bypass'),
			fs.exec('/usr/share/bypass/api.sh', ['interfaces']).then(function (res) {
				try { return JSON.parse(res.stdout || '{}').interfaces || []; }
				catch (e) { return []; }
			}).catch(function () { return []; })
		]);
	},

	render: function (data) {
		var ifaces = data[1] || [];
		var sid = currentSection();

		if (!sid || !uci.get('bypass', sid)) {
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

		o = s.option(form.ListValue, 'type', _('Type'));
		o.value('NaiveProxy', 'NaiveProxy');
		o.description = _('Only NaiveProxy (https) is supported in this build.');

		o = s.option(form.Value, 'address', _('Address (server)'));
		o.description = _('Domain or IP of the NaiveProxy server.');
		o.datatype = 'host';

		o = s.option(form.Value, 'port', _('Port'));
		o.datatype = 'port';
		o.placeholder = '443';

		o = s.option(form.Value, 'username', _('Username'));

		o = s.option(form.Value, 'password', _('Password'));
		o.password = true;

		o = s.option(form.ListValue, 'egress_interface', _('Egress Interface'));
		o.description = _('Steer the naive -> server connection out of this interface. Empty = use the global default egress interface.');
		o.value('', _('(use global default)'));
		ifaces.forEach(function (i) { o.value(i, i); });

		return m.render();
	}
});
