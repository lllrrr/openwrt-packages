'use strict';
'require form';
'require fs';
'require ui';
'require view';

function injectCSS(){
	if(document.getElementById('pi-config-css')) return;
	var el = document.createElement('style');
	el.id = 'pi-config-css';
	el.textContent = [
		'#pi-config-textarea{',
		'  white-space:pre-wrap;word-wrap:break-word;overflow-wrap:break-word;',
		'  tab-size:2;',
		'}',
	].join('');
	document.head.appendChild(el);
}

return view.extend({
	render(){
		injectCSS();
		var m, s, o;

		m = new form.Map('pi', 'YAML 配置',
			'编辑 Mihomo YAML 配置文件。保存后自动热重载。');

		s = m.section(form.TypedSection);
		s.anonymous = true;

		s = m.section(form.NamedSection, 'global', 'pi');

		o = s.option(form.TextValue, '_configuration');
		o.rows = 30;
		o.monospace = true;
		o.wrap = 'soft';

		o.cfgvalue = function(section_id){
			return fs.read_direct('/etc/pi/config.yaml', 'text')
				.then(function(content){
					var ta = document.getElementById('cbi-pi-_configuration');
					if(ta) ta.id = 'pi-config-textarea';
					return content ?? '';
				})
				.catch(function(e){
					if(e.toString().includes('NotFoundError'))
						return fs.read_direct('/etc/pi/config.yaml', 'text')
							.then(function(content){ return content ?? ''; })
							.catch(function(){ return ''; });
					ui.addNotification(null, E('p', e.message));
					return '';
				});
		};

		o.load = function(section_id){
			return fs.read_direct('/etc/pi/config.yaml', 'text')
				.then(function(content){ return content ?? ''; })
				.catch(function(e){
					if(e.toString().includes('NotFoundError'))
						return fs.read_direct('/etc/pi/config.yaml', 'text')
							.then(function(content){ return content ?? ''; })
							.catch(function(e){ return ''; });
					ui.addNotification(null, E('p', e.message));
					return '';
				});
		};

		o.write = function(section_id, value){
			return fs.write('/etc/pi/config.yaml', value, 384)
				.catch(function(e){
					ui.addNotification(null, E('p', e.message));
				});
		};

		o.remove = function(section_id, value){
			return fs.write('/etc/pi/config.yaml', '')
				.catch(function(e){
					ui.addNotification(null, E('p', e.message));
				});
		};

		return m.render();
	},

	handleSaveApply(ev, mode){
		return this.handleSave(ev)
			.then(function(){
				return L.resolveDefault(fs.exec_direct('/etc/init.d/pi', ['hot_reload']), null);
			});
	}
});
