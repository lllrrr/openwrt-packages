	function switchSettingsTab(name) {
		var valid = ['svc', 'upstream'];
		if (valid.indexOf(name) < 0) name = 'svc';
		var tabs = document.querySelectorAll('#agh-settings-tabs .agh-subtab');
		for (var i = 0; i < tabs.length; i++) {
			tabs[i].classList.toggle('is-active', tabs[i].getAttribute('data-subtab') === name);
		}
		var cards = document.querySelectorAll('#agh-tab-settings .agh-card[data-subpanel]');
		for (var j = 0; j < cards.length; j++) {
			cards[j].classList.toggle('is-active', cards[j].getAttribute('data-subpanel') === name);
		}
		state.settingsSubtab = name;
	}

	function switchLogTab(name) {
		var valid = ['sys', 'query'];
		if (valid.indexOf(name) < 0) name = 'sys';
		var tabs = document.querySelectorAll('#agh-logs-tabs .agh-subtab');
		for (var i = 0; i < tabs.length; i++) {
			tabs[i].classList.toggle('is-active', tabs[i].getAttribute('data-logtab') === name);
		}
		var cards = document.querySelectorAll('#agh-tab-logs .agh-card[data-logpanel]');
		for (var j = 0; j < cards.length; j++) {
			cards[j].classList.toggle('is-active', cards[j].getAttribute('data-logpanel') === name);
		}
		state.logSubtab = name;
		if (name === 'query') resetQueryLog();
		else loadLogs();
	}

	function switchTab(name, updateHash) {
		var valid = ['overview', 'settings', 'filters', 'advanced', 'logs', 'guide'];
		if (valid.indexOf(name) < 0) name = 'overview';

		var tabs = document.querySelectorAll('.agh-tab');
		for (var i = 0; i < tabs.length; i++) {
			tabs[i].classList.toggle('is-active', tabs[i].getAttribute('data-tab') === name);
		}
		var panels = document.querySelectorAll('.agh-tab-panel');
		for (var j = 0; j < panels.length; j++) {
			panels[j].classList.toggle('is-active', panels[j].id === 'agh-tab-' + name);
		}

		if (name === 'settings' && !state.settings) loadSettings();
		if (name === 'settings') switchSettingsTab(state.settingsSubtab || 'svc');
		if (name === 'filters') loadFilters(true);
		if (name === 'advanced' && !state.yamlLoaded) loadYaml();
		if (name === 'logs') switchLogTab(state.logSubtab || 'sys');

		if (updateHash !== false && window.history && window.history.replaceState) {
			window.history.replaceState(null, '', '#' + name);
		}
		// 面板在内层 iframe 中，#hash 会随外层刷新丢失，用 sessionStorage 兜底
		if (updateHash !== false) {
			try { window.sessionStorage.setItem('agh-tab', name); } catch (e) {}
		}
	}

