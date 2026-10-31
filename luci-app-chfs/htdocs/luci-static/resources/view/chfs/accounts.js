'use strict';
'require view';
'require form';
'require uci';
'require ui';

// 引入样式表, 与 main.js 共用同一份 CSS, 通过 id 去重
if (!document.getElementById('chfs-stylesheet')) {
	document.querySelector('head').appendChild(
		E('link', {
			'id': 'chfs-stylesheet',
			'rel': 'stylesheet',
			'href': L.resource('view/chfs/chfs.css')
		})
	);
}

// 权限取值与 chfs 的 rule 语义一一对应
var RULE_CHOICES = [
	[ 'none', _('Deny access') ],
	[ 'r',    _('Read-only') ],
	[ 'w',    _('Read-write') ],
	[ 'd',    _('Full control (including delete)') ]
];

return view.extend({
	load: function() {
		return uci.load('chfs');
	},

	render: function() {
		var m, s, o;

		m = new form.Map('chfs', _('Accounts and permissions'),
			_('Each account corresponds to one [account-name] section in the chfs configuration file. guest is the visitor account used for anonymous access and cannot be removed. Permission rules apply per directory; separate multiple directories with a vertical bar |.'));

		s = m.section(form.GridSection, 'account', _('Account list'),
			_('The default permission applies to all directories. Per-directory rules may be set to override it.'));
		s.addremove = true;
		s.anonymous = false;
		s.sortable = true;
		s.nodescription = false;

		// 节点名称作为 section 标识, 界面中不直接编辑
		o = s.option(form.Value, 'name', _('Account name'));
		o.rmempty = false;
		o.validate = function(section_id, value) {
			var v = (value || '').trim();

			if (v === '')
				return _('Account name must not be empty');

			// chfs 3.1 起账户名允许大写字母, 但不得包含空格与方括号
			if (/[\s\[\]]/.test(v))
				return _('Account name must not contain spaces, brackets or similar characters');

			// 检查重名
			var dup = false;
			uci.sections('chfs', 'account', function(sec) {
				if (sec['.name'] !== section_id && (sec.name || '').trim() === v)
					dup = true;
			});

			if (dup)
				return _('Account name already exists');

			return true;
		};

		o = s.option(form.Value, 'password', _('Password'));
		o.password = true;
		o.placeholder = _('Leave empty for no password');
		o.modalonly = false;

		o = s.option(form.ListValue, 'rule_default', _('Default permission'));
		o.rmempty = false;
		for (var i = 0; i < RULE_CHOICES.length; i++)
			o.value(RULE_CHOICES[i][0], RULE_CHOICES[i][1]);
		o.default = 'r';

		o = s.option(form.Value, 'rule_none', _('Denied directories'));
		o.placeholder = '/private|/secret';
		o.modalonly = true;

		o = s.option(form.Value, 'rule_r', _('Read-only directories'));
		o.placeholder = '/docs|/public';
		o.modalonly = true;

		o = s.option(form.Value, 'rule_w', _('Read-write directories'));
		o.placeholder = '/upload';
		o.modalonly = true;

		o = s.option(form.Value, 'rule_d', _('Full control directories'));
		o.placeholder = '/admin';
		o.modalonly = true;

		// guest 账户保护: 禁止删除
		// GridSection 通过 handleRemove 触发删除, 在此拦截 guest 账户
		var origRemove = s.handleRemove;
		s.handleRemove = function(section_id, ev) {
			var name = uci.get('chfs', section_id, 'name');

			if (name === 'guest') {
				ui.addNotification(null,
					E('p', {}, _('guest is the visitor account used for anonymous access and cannot be removed.')), 'warning');
				return Promise.resolve();
			}

			return origRemove.apply(this, arguments);
		};

		return m.render();
	}
});
