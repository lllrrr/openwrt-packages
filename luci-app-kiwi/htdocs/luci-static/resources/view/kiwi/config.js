// SPDX-License-Identifier: Apache-2.0
// Kiwi — Pipeline 配置编辑器（TextValue JSON 编辑）

'use strict';
'require form';
'require fs';
'require ui';
'require view';

function injectCSS() {
	if (document.getElementById('kiwi-config-css')) return;
	var el = document.createElement('style');
	el.id = 'kiwi-config-css';
	el.textContent = [
		'#kiwi-config-textarea{',
		'  white-space:pre-wrap;word-wrap:break-word;overflow-wrap:break-word;',
		'  tab-size:2;',
		'}',
	].join('');
	document.head.appendChild(el);
}

return view.extend({
	render() {
		injectCSS();

		let m, s, o;

		m = new form.Map('kiwi', '配置',
			'在此编辑 Kiwi Pipeline JSON 配置，保存后自动热重载。');

		s = m.section(form.TypedSection);
		s.anonymous = true;

		s = m.section(form.NamedSection, 'config', 'kiwi');

		o = s.option(form.TextValue, '_configuration');
		o.rows = 30;
		o.monospace = true;
		o.wrap = 'soft';

		o.cfgvalue = function(section_id) {
			return fs.read_direct('/etc/kiwi/pipeline.json', 'text')
				.then(function(content) {
					var ta = document.getElementById('cbi-kiwi-config-_configuration');
					if (ta) ta.id = 'kiwi-config-textarea';
					return content ?? '';
				}).catch(function(e) {
					ui.addNotification(null, E('p', '读取配置文件失败：' + e.message));
					return '';
				});
		};

		o.load = function(section_id) {
			return fs.read_direct('/etc/kiwi/pipeline.json', 'text')
				.then(function(content) { return content ?? ''; })
				.catch(function(e) { return ''; });
		};

		o.write = function(section_id, value) {
			return fs.write('/etc/kiwi/pipeline.json', value, 384 /* 0600 */)
				.catch(function(e) {
					ui.addNotification(null, E('p', '写入配置失败：' + e.message));
				});
		};

		o.remove = function(section_id, value) {
			return fs.write('/etc/kiwi/pipeline.json', '')
				.catch(function(e) {
					ui.addNotification(null, E('p', '清空配置失败：' + e.message));
				});
		};

		return m.render();
	},

	handleSaveApply(ev, mode) {
		return this.handleSave(ev).then(function() {
			return L.resolveDefault(fs.exec_direct('/etc/init.d/kiwi', ['reload']), null);
		});
	}
});
