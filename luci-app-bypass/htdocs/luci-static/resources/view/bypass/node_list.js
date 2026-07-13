'use strict';
'require view';
'require form';
'require uci';

return view.extend({
	load: function () {
		return uci.load('bypass');
	},

	render: function () {
		var m = new form.Map('bypass', _('Node List'), _('NaiveProxy nodes (https).'));

		var s = m.section(form.GridSection, 'nodes', _('Nodes'));
		s.addremove = true;
		s.nodesc = true;
		s.sortable = true;
		// Clicking a row opens the editor for that section.
		s.extedit = function (sid) {
			return 'node_config?section=' + encodeURIComponent(sid);
		};
		// Default values applied when the user adds a new node.
		s.addopts = { type: 'NaiveProxy' };

		s.option(form.Value, 'remarks', _('Remarks')).width = '20%';
		var t = s.option(form.ListValue, 'type', _('Type'));
		t.value('NaiveProxy', 'NaiveProxy');
		t.width = '15%';
		s.option(form.Value, 'address', _('Address')).width = '30%';
		var p = s.option(form.Value, 'port', _('Port'));
		p.datatype = 'port';
		p.width = '10%';
		s.option(form.DummyValue, 'egress_interface', _('Egress')).width = '15%';

		return m.render();
	}
});
