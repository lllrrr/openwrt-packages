	function $(id) {
		return document.getElementById(id);
	}

	// 旧版会把主题自动写进 agh-theme，导致外层主题变了面板也不再跟随，
	// 这里只把手动选择存到 agh-theme-pin，并清掉旧的自动值
	var THEME_PIN = 'agh-theme-pin';

	// 外层 LuCI / Argon 主题（wrapper 通过 agh_theme 参数与 postMessage 下发），
	// 手动切换后切回与外层一致时，自动恢复跟随
	var parentTheme = '';
	try {
		var qm = /[?&]agh_theme=(dark|light)/.exec(window.location.search || '');
		if (qm) parentTheme = qm[1];
	} catch (e) { /* 忽略 */ }

	function savedTheme() {
		try {
			localStorage.removeItem('agh-theme');
			var saved = localStorage.getItem(THEME_PIN) || '';
			return (saved === 'dark' || saved === 'light') ? saved : '';
		} catch (e) {
			return '';
		}
	}

	function setSavedTheme(theme) {
		try {
			if (theme) localStorage.setItem(THEME_PIN, theme);
			else localStorage.removeItem(THEME_PIN);
		} catch (e) { /* 隐私模式下忽略 */ }
	}

	function applyTheme(theme) {
		var dark = theme === 'dark';
		// 类挂在 html 上，页面首屏前就能生效，避免刷新时闪一下浅色
		document.documentElement.classList.toggle('agh-dark', dark);
		var btn = $('agh-theme-toggle');
		if (btn) btn.textContent = dark ? '切换为浅色' : '切换为暗色';
		reportSurface();
	}

	// 面板卡片有圆角，四角会露出 iframe 自身的画布（浏览器默认白色）。
	// 把卡片实际底色回传给外层，让 iframe 底色同色，四角就不会露白。
	function reportSurface() {
		var color = '';
		var app = document.querySelector('.agh-app');
		if (app) color = window.getComputedStyle(app).backgroundColor || '';
		if (!color || color === 'transparent' || color === 'rgba(0, 0, 0, 0)') color = '';
		try {
			if (window.parent && window.parent !== window) {
				window.parent.postMessage({ type: 'agh-surface', color: color }, window.location.origin);
			}
		} catch (e) { /* 忽略 */ }
	}

	function initTheme() {
		var theme = savedTheme() || parentTheme;
		if (theme !== 'dark' && theme !== 'light') {
			theme = (window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches) ? 'dark' : 'light';
		}
		applyTheme(theme);
	}

	function toggleTheme() {
		var next = document.documentElement.classList.contains('agh-dark') ? 'light' : 'dark';
		// 切回与外层主题一致时取消手动覆盖，继续跟随外层主题
		setSavedTheme(parentTheme && next === parentTheme ? '' : next);
		applyTheme(next);
	}

	// 跟随外层 LuCI（明暗）与 Argon 主题
	function initThemeSync() {
		window.addEventListener('message', function (e) {
			if (e.origin !== window.location.origin) return;
			var data = e.data || {};
			if (data.type !== 'agh-theme') return;
			if (data.mode !== 'dark' && data.mode !== 'light') return;
			parentTheme = data.mode;
			// 用户手动选过主题就不再被外层覆盖
			if (!savedTheme()) applyTheme(data.mode);
		});
	}

	// 开关旁边的状态文字，可按开关自定义开/关文案
	function updateSwitchStates() {
		var nodes = document.querySelectorAll('.agh-switch-state');
		for (var i = 0; i < nodes.length; i++) {
			var el = nodes[i];
			// 用 getElementById 而非本地 $()：避免 CodeQL 把 $ 当成 jQuery 的 HTML 解析入口（js/xss-through-dom）
			var target = el.getAttribute('data-for');
			var input = target ? document.getElementById(target) : null;
			var on = !!(input && input.checked);
			el.textContent = on
				? (el.getAttribute('data-on') || '已开启')
				: (el.getAttribute('data-off') || '已关闭');
			el.classList.toggle('is-on', on);
		}
	}

