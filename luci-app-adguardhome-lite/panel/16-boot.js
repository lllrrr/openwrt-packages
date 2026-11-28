	function init() {
		initTheme();
		initThemeSync();
		initEvents();
		updateSwitchStates();
		var hash = (window.location.hash || '').replace('#', '');
		// 外层 LuCI 刷新会用固定地址重建 iframe，#hash 丢失时沿用上次页签
		if (!hash) {
			try { hash = window.sessionStorage.getItem('agh-tab') || ''; } catch (e) {}
		}
		if (!hash) hash = 'overview';
		switchTab(hash, false);
		refreshStatus();
		resumePluginUpdate();
		loadLegacyScan();
		setInterval(function () {
			if (document.hidden || state.busy) return;
			refreshStatus(true);
		}, 10000);
	}

	if (document.readyState === 'loading') {
		document.addEventListener('DOMContentLoaded', init);
	} else {
		init();
	}
})();
