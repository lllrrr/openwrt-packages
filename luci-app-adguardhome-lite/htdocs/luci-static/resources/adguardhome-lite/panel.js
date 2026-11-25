/*
 * AdGuard Home 管理中心 - 独立管理页面
 * 不依赖 LuCI 主题、luci.js 或 XHR，全部使用原生 fetch。
 */
(function () {
	'use strict';

	var CFG = window.AGH || {};
	var U = CFG.urls || {};
	var TOKEN = CFG.token || '';

	// 本页在 LuCI 的 iframe 里打开：父页面的 L.env.token 是当前会话的实时令牌，
	// 比模板里渲染的 token 更可靠（重新登录、LuCI 版本差异时都不会过期）。
	function parentToken() {
		try {
			var p = window.parent;
			if (!p || p === window) return '';
			if (p.L) {
				if (typeof p.L.getToken === 'function') {
					var live = p.L.getToken();
					if (live) return String(live);
				}
				if (p.L.env && p.L.env.token) return String(p.L.env.token);
			}
		} catch (e) { /* 忽略跨域或父页面尚未初始化 */ }
		return '';
	}

	var tokenPending = null;
	function refreshToken() {
		var live = parentToken();
		if (live) {
			TOKEN = live;
			return Promise.resolve(TOKEN);
		}
		if (!U.session) return Promise.resolve(TOKEN);
		if (tokenPending) return tokenPending;
		tokenPending = fetchWithTimeout(U.session, {
			credentials: 'same-origin',
			cache: 'no-store',
			headers: { 'Accept': 'application/json', 'X-Requested-With': 'XMLHttpRequest' }
		}, 8000).then(function (r) {
			return r.json();
		}).then(function (d) {
			tokenPending = null;
			if (d && d.ok && d.token) TOKEN = String(d.token);
			return TOKEN;
		}, function () {
			tokenPending = null;
			return TOKEN;
		});
		return tokenPending;
	}

	var ADULT_FILTER_URL = 'https://cdn.jsdelivr.net/gh/Ozero-top/AdguardHome-Rrules@dist/manual/nsfw.txt';
	var ADULT_FILTER_NAME = 'HaGeZi NSFW（成人内容）';
	// 旧版本写入过的上游地址，以及手动添加过的同一条列表；识别后统一迁移到 CDN 地址
	var ADULT_FILTER_URLS = [
		ADULT_FILTER_URL,
		'https://raw.githubusercontent.com/Ozero-top/AdguardHome-Rrules/refs/heads/dist/manual/nsfw.txt',
		'https://raw.githubusercontent.com/Ozero-top/AdguardHome-Rrules/dist/manual/nsfw.txt',
		'https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/nsfw.txt'
	];

	function findAdultFilter(list) {
		list = list || [];
		for (var i = 0; i < list.length; i++) {
			if (!list[i].whitelist && ADULT_FILTER_URLS.indexOf(list[i].url) >= 0) return list[i];
		}
		return null;
	}

	// 拦截常见 DoH 提供商，防止设备绕过 AdGuard Home。
	// 开启时写入 user_rules，关闭时按域名移除，裸域名与 ||domain^ 两种写法都会被清理。
	var DOH_DOMAINS = [
		'dns.google', 'cloudflare-dns.com', 'dns.quad9.net',
		'doh.opendns.com', 'dns.mozilla.org', 'doh.cleanbrowsing.org',
		'dns.nextdns.io', 'doh.pub', 'doh.360.cn'
	];
	var DOH_RULES = DOH_DOMAINS.map(function (d) { return '||' + d + '^'; });

	var state = {
		status: null,
		settings: null,
		filters: [],
		yamlLoaded: false,
		settingsSubtab: 'svc',
		logSubtab: 'sys',
		logLevel: '',
		logText: '',
		queryStatus: '',
		querySearch: '',
		queryAuto: 5,
		queryPage: 0,
		queryPages: [],
		queryCursors: [''],
		queryMore: [],
		queryTimer: null,
		rulesDirty: false,
		filterBusy: false,
		presetSource: 'jsdelivr',
		adultMigrated: false,
		parentalNotified: false,
		pluginLatest: '',
		pluginUrl: '',
		pluginUpdating: false,
		pluginChecking: false,
		pluginTimer: null,
		pluginMiss: 0,
		busy: false,
		passShown: false,
		openclash: false,
		passwall: false,
		passwallEnabled: false,
		passwallDnsPort: '',
		updateTimer: null,
		actionTimer: null,
		logTimer: null,
		toastTimer: null
	};

	function $(id) {
		return document.getElementById(id);
	}

	// 旧版会把主题自动写进 agh-theme，导致外层主题变了面板也不再跟随，
	// 这里只把手动选择存到 agh-theme-pin，并清掉旧的自动值
	var THEME_PIN = 'agh-theme-pin';
	var CORE_KEY = 'agh-core-version';

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
			var input = $(el.getAttribute('data-for'));
			var on = !!(input && input.checked);
			el.textContent = on
				? (el.getAttribute('data-on') || '已开启')
				: (el.getAttribute('data-off') || '已关闭');
			el.classList.toggle('is-on', on);
		}
	}

	function esc(value) {
		return String(value == null ? '' : value)
			.replace(/&/g, '&amp;')
			.replace(/</g, '&lt;')
			.replace(/>/g, '&gt;')
			.replace(/"/g, '&quot;')
			.replace(/'/g, '&#39;');
	}

	function showToast(text, kind) {
		var el = document.querySelector('.agh-toast');
		if (!el) {
			el = document.createElement('div');
			el.className = 'agh-toast';
			document.body.appendChild(el);
		}
		el.textContent = text;
		el.className = 'agh-toast is-visible' + (kind ? ' is-' + kind : '');
		if (state.toastTimer) clearTimeout(state.toastTimer);
		state.toastTimer = setTimeout(function () {
			el.className = 'agh-toast';
		}, 4500);
	}

	// 统一确认弹窗，替代浏览器原生 confirm，外观与面板保持一致
	function aghConfirm(text) {
		var modal = $('agh-confirm-modal');
		var textEl = $('agh-confirm-text');
		var okBtn = $('agh-confirm-ok');
		var cancelBtn = $('agh-confirm-cancel');
		var mask = $('agh-confirm-mask');
		if (!modal || !textEl || !okBtn || !cancelBtn) {
			return Promise.resolve(window.confirm(text));
		}

		var resolveFn = null;
		textEl.textContent = text;
		modal.hidden = false;
		okBtn.focus();

		function onKey(e) {
			if (e.key === 'Escape') finish(false);
		}

		function finish(result) {
			modal.hidden = true;
			okBtn.onclick = null;
			cancelBtn.onclick = null;
			if (mask) mask.onclick = null;
			document.removeEventListener('keydown', onKey);
			var done = resolveFn;
			resolveFn = null;
			if (done) done(result);
		}

		okBtn.onclick = function () { finish(true); };
		cancelBtn.onclick = function () { finish(false); };
		if (mask) mask.onclick = function () { finish(false); };
		document.addEventListener('keydown', onKey);
		return new Promise(function (resolve) { resolveFn = resolve; });
	}

	function setMsg(el, text, kind) {
		if (!el) return;
		el.textContent = text || '';
		el.style.whiteSpace = 'pre-wrap';
		el.style.color = kind === 'bad'
			? 'var(--agh-danger)'
			: kind === 'ok'
				? 'var(--agh-success)'
				: 'var(--agh-muted)';
	}

	function isLoginError(err) {
		return err && err.login === true;
	}

	function handleApiError(err, target) {
		if (isLoginError(err)) {
			var text = '登录已过期，请重新登录 LuCI 后刷新本页面。';
			if (target) setMsg(target, text, 'bad');
			showToast(text, 'bad');
			return;
		}
		var msg = err && err.message ? err.message : String(err);
		if (target) setMsg(target, msg, 'bad');
		showToast(msg, 'bad');
	}

	// LuCI 在会话失效或令牌不匹配时返回 HTML（登录页 / csrftoken），
	// 不能一律当成“登录已过期”，否则用户会反复登录仍看到同样的提示。
	function htmlResponseError(r, text) {
		var raw = String(text || '');
		var snippet = raw
			// 闭合标签可能带属性（如 </script >），不能用固定的 </script> 匹配
			.replace(/<script[\s\S]*?<\/script[^>]*>/gi, ' ')
			.replace(/<style[\s\S]*?<\/style[^>]*>/gi, ' ')
			.replace(/<[^>]+>/g, ' ')
			.replace(/\s+/g, ' ')
			.trim();
		if (snippet.length > 140) snippet = snippet.slice(0, 140) + '…';

		var loginRequired = r.status === 401
			|| (r.headers.get('x-luci-login-required') || '').toLowerCase() === 'yes';
		if (!loginRequired && /invalid token|csrf|令牌|登录|login|session/i.test(snippet)) {
			loginRequired = true;
		}
		if (loginRequired) {
			throw Object.assign(new Error('登录已过期'), { login: true, status: r.status });
		}
		throw new Error(snippet || ('服务器返回了网页（HTTP ' + r.status + '），请刷新页面后重试。'));
	}

	async function parseJsonResponse(r) {
		var ct = r.headers.get('content-type') || '';
		var text = await r.text();
		// 部分动作没带 JSON Content-Type，但 body 是合法 JSON；先按内容判断，
		// 否则会把正常响应当成网页错误，把原始 JSON 显示到提示里。
		if (/^\s*[{[]/.test(text)) {
			try {
				return JSON.parse(text);
			} catch (e) { /* 不是合法 JSON，继续按错误处理 */ }
		}
		if (ct.indexOf('text/html') >= 0) {
			htmlResponseError(r, text);
		}
		if (!r.ok) {
			if (text.trim().indexOf('<') === 0) htmlResponseError(r, text);
			throw new Error(text || ('HTTP ' + r.status));
		}
		if (text.trim().indexOf('<') === 0) htmlResponseError(r, text);
		throw new Error('接口返回格式错误');
	}

	// 统一超时：接口卡住时快速失败，避免整个面板一直停在加载状态
	function fetchWithTimeout(url, options, ms) {
		var opts = options || {};
		var controller = window.AbortController ? new AbortController() : null;
		if (controller) opts.signal = controller.signal;
		var timer = setTimeout(function () {
			if (controller) controller.abort();
		}, ms || 20000);
		return fetch(url, opts).then(function (r) {
			clearTimeout(timer);
			return r;
		}, function (err) {
			clearTimeout(timer);
			if (err && err.name === 'AbortError') throw new Error('请求超时，请稍后重试。');
			throw err;
		});
	}

	async function apiGet(url) {
		var r = await fetchWithTimeout(url, {
			credentials: 'same-origin',
			cache: 'no-store',
			headers: { 'Accept': 'application/json', 'X-Requested-With': 'XMLHttpRequest' }
		}, 20000);
		return parseJsonResponse(r);
	}

	async function postForm(url, data, timeout) {
		var body = new URLSearchParams(data || {});
		body.set('token', TOKEN);
		var r = await fetchWithTimeout(url, {
			method: 'POST',
			credentials: 'same-origin',
			cache: 'no-store',
			headers: {
				'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8',
				'Accept': 'application/json',
				'X-Requested-With': 'XMLHttpRequest'
			},
			body: body.toString()
		}, timeout || 30000);
		var json = await parseJsonResponse(r);
		if (json && json.ok === false) {
			var err = new Error(json.error || '操作失败');
			if (json.reason === 'auth_required') err.login = true;
			throw err;
		}
		return json;
	}

	async function apiPost(url, data, timeout) {
		if (!TOKEN) await refreshToken();
		try {
			return await postForm(url, data, timeout);
		} catch (err) {
			if (!isLoginError(err)) throw err;
			// 重新登录后令牌会轮换，取一次当前令牌再重试；仍失败才提示重新登录
			await refreshToken();
			return await postForm(url, data, timeout);
		}
	}

	async function apiText(url) {
		var r = await fetchWithTimeout(url, {
			credentials: 'same-origin',
			cache: 'no-store',
			headers: { 'Accept': 'text/plain', 'X-Requested-With': 'XMLHttpRequest' }
		}, 20000);
		var ct = r.headers.get('content-type') || '';
		if (ct.indexOf('text/html') >= 0) {
			throw Object.assign(new Error('登录已过期'), { login: true });
		}
		if (!r.ok) throw new Error('HTTP ' + r.status);
		return await r.text();
	}

	function panelUrl(port) {
		var host = window.location.hostname;
		if (host.indexOf(':') >= 0 && host.charAt(0) !== '[') host = '[' + host + ']';
		return 'http://' + host + ':' + (port || 13800) + '/';
	}

	function modeLabel(mode, flavor) {
		if (mode === 'takeover') return '接管 53 端口';
		if (mode === 'passwall') return (flavor === '2' ? 'PassWall2' : 'PassWall') + ' 前置';
		if (mode === 'openclash') return 'Clash 串联（已下线）';
		if (mode === 'clashfirst') return 'Clash 前置（Clash → AGH → 真实 DNS）';
		if (mode === 'none') return '仅面板（不接管 DNS）';
		return 'DNSMasq 上游';
	}

	function modeChain(d) {
		var cdp = d.clash_dns_port || '7874';
		if (d.dns_mode === 'takeover') {
			return d.openclash_running
				? '客户端 → 53 AGH → 1745 DNSMasq → Clash / WAN DNS'
				: '客户端 → 53 AGH → 1745 DNSMasq → WAN DNS';
		}
		if (d.dns_mode === 'passwall') {
			return '客户端 → 53 AGH → ' + (d.passwall_dns_port || '11400') + ' PassWall DNS → 分流';
		}
		if (d.dns_mode === 'openclash') return '客户端 → 53 DNSMasq → 5333 AGH → ' + cdp + ' Clash DNS';
		if (d.dns_mode === 'clashfirst') return '客户端 → Clash 劫持 → ' + cdp + ' Clash DNS → 5335 AGH → 真实 DNS';
		if (d.dns_mode === 'none') return '不接管 DNS，仅保留管理面板';
		return '客户端 → 53 DNSMasq → 5333 AGH → 自动选择上游';
	}

	function channelLabel(channel) {
		if (channel === 'beta') return '预发布版';
		if (channel === 'legacy') return '旧版本';
		return '正式版';
	}

	// AdGuard Home 预发布版本号形如 v1.0.0-b.2
	function isBetaVersion(version) {
		return /(^|-)b\.?\d/i.test(String(version || ''));
	}

	// 安装通道优先用安装时记录的值；旧安装没有记录时按版本号兜底
	function isCoreBeta(d) {
		var ch = d && d.core_channel;
		if (ch === 'beta') return true;
		if (ch === 'stable' || ch === 'legacy') return false;
		return isBetaVersion(d && d.version);
	}

	function coreUpdateBadge(d) {
		var u = d && d.core_update;
		if (!u || !u.update || !u.latest) return '';
		return ' <a href="#" class="agh-update-tip agh-core-update" title="点击前往安装">可更新 v' +
			esc(u.latest) + (u.beta ? '（预发布版）' : '') + '</a>';
	}

	function renderCoreVersion(d) {
		if (!d.core) return '<span class="agh-bad">未安装</span>';
		var version = d.version || '已安装';
		var html = '<span class="agh-ok">' + esc(version) + '</span>';
		if (isCoreBeta(d)) {
			html += ' <span class="agh-beta-tag">预发布版</span>';
		}
		html += coreUpdateBadge(d);
		return html;
	}

	function updatePluginVersion(d) {
		var ver = $('agh-plugin-version');
		var tip = $('agh-plugin-update');
		var p = d && d.plugin;
		if (ver && !state.pluginChecking) ver.textContent = (p && p.current) ? 'v' + p.current : '未知';
		if (!tip) return;

		if (state.pluginUpdating) {
			tip.textContent = '更新中...';
			tip.hidden = false;
			tip.disabled = true;
			return;
		}
		tip.disabled = false;
		if (p && p.url) state.pluginUrl = p.url;
		if (p && p.update && p.latest) {
			state.pluginLatest = p.latest;
			tip.textContent = '发现 v' + p.latest + '，立即更新';
			tip.hidden = false;
		} else {
			tip.hidden = true;
		}
	}

	// 点击版本号手动检测更新：清缓存后触发后台检查，轮询状态等结果
	async function checkPluginUpdate() {
		if (state.pluginChecking || state.pluginUpdating) return;
		state.pluginChecking = true;

		var ver = $('agh-plugin-version');
		var original = ver ? ver.textContent : '';
		if (ver) {
			ver.classList.add('is-checking');
			ver.textContent = '检测中…';
		}

		try {
			await apiPost(U.pluginCheck, {});
			var found = null;
			// 后台最多串行尝试 3 个节点（每节点 6 秒），这里等 36 秒再判定超时
			for (var i = 0; i < 24; i++) {
				await new Promise(function (resolve) { setTimeout(resolve, 1500); });
				var d = await apiGet(U.status);
				if (d && d.plugin && d.plugin.latest) {
					found = d.plugin;
					break;
				}
			}

			state.pluginChecking = false;
			if (ver) {
				ver.classList.remove('is-checking');
				if (!found) ver.textContent = original;
			}

			if (!found) {
				showToast('检测超时，请检查网络或 GitHub 反代设置', 'bad');
				return;
			}

			refreshStatus(true);
			showToast(found.update ? ('发现新版本 v' + found.latest) : '已是最新版本', 'ok');
		} catch (err) {
			state.pluginChecking = false;
			if (ver) {
				ver.classList.remove('is-checking');
				ver.textContent = original;
			}
			handleApiError(err);
		}
	}

	function applyHeroCore(version, installed) {
		var el = $('agh-hero-core');
		if (!el) return;
		if (installed === false) {
			el.textContent = '未安装内核';
			el.title = '尚未安装 AdGuard Home 内核';
			return;
		}
		if (version) {
			el.textContent = version;
			el.title = '当前内核版本';
			return;
		}
		el.textContent = '读取中';
		el.title = '正在读取内核版本';
	}

	// 先用缓存渲染，避免刷新瞬间显示成占位文案
	function initHeroCore() {
		var saved = '';
		try { saved = localStorage.getItem(CORE_KEY) || ''; } catch (e) { /* 忽略 */ }
		applyHeroCore(saved, true);
	}

	function updateHeroCore(d) {
		if (!d) return;
		if (!d.core) {
			applyHeroCore('', false);
			try { localStorage.removeItem(CORE_KEY); } catch (e) { /* 忽略 */ }
			return;
		}
		applyHeroCore(d.version || '', true);
		if (d.version) {
			try { localStorage.setItem(CORE_KEY, d.version); } catch (e) { /* 忽略 */ }
		}
	}

	function updateHeaderStatus() {
		var el = $('agh-header-status');
		if (!el) return;
		var d = state.status;
		if (!d) {
			el.className = 'agh-pill';
			el.textContent = '读取中';
			return;
		}
		if (d.update_running) {
			el.className = 'agh-pill agh-pill-warn';
			el.textContent = '内核安装中';
			return;
		}
		if (d.running) {
			el.className = 'agh-pill agh-pill-ok';
			el.textContent = '运行中';
			return;
		}
		if (d.enabled) {
			el.className = 'agh-pill agh-pill-warn';
			el.textContent = '已启用 / 未运行';
			return;
		}
		el.className = 'agh-pill agh-pill-bad';
		el.textContent = '已停止';
	}

	function attachPasswordActions(pass) {
		var toggle = $('agh-pass-toggle');
		var copy = $('agh-pass-copy');
		if (toggle) {
			toggle.onclick = function () {
				state.passShown = !state.passShown;
				renderStatus();
			};
		}
		if (copy) {
			copy.onclick = function () {
				copyText(pass);
			};
		}
	}

	// 点击「可更新」跳转到初始化配置的内核安装按钮
	function attachCoreUpdateAction() {
		var links = document.querySelectorAll('.agh-core-update');
		for (var i = 0; i < links.length; i++) {
			links[i].onclick = function (e) {
				e.preventDefault();
				var btn = $('agh-install-btn');
				if (btn) btn.scrollIntoView({ behavior: 'smooth', block: 'center' });
			};
		}
	}

	function renderStatus() {
		var d = state.status;
		updateHeaderStatus();
		updatePluginVersion(d);
		updateHeroCore(d);
		if (!d) {
			var grid = $('agh-status-grid');
			if (grid) grid.innerHTML = '<div class="agh-empty">无法读取状态</div>';
			return;
		}

		var panel = panelUrl(d.web_port);
		var pass = d.admin_pass || '';
		var passHtml = pass
			? '<span class="agh-pass-wrap"><span id="agh-pass-text">' + (state.passShown ? esc(pass) : '••••••••') + '</span>' +
				'<button type="button" class="agh-mini-btn" id="agh-pass-toggle">' + (state.passShown ? '隐藏' : '显示') + '</button>' +
				'<button type="button" class="agh-mini-btn" id="agh-pass-copy">复制</button></span>'
			: '<span class="agh-warn">未设置</span>';

		var rows = [
			['服务状态', d.running ? '<span class="agh-ok">运行中</span>' : '<span class="agh-bad">已停止</span>'],
			['内核版本', renderCoreVersion(d)],
			['DNS 接管', esc(modeLabel(d.dns_mode, d.passwall_flavor)) + ((d.mode_applied && d.mode_applied !== d.dns_mode) ? ' <span class="agh-warn">（待应用）</span>' : '')],
			['当前链路', '<span class="agh-path">' + esc(modeChain(d)) + '</span>'],
			['更新通道', esc(channelLabel(d.channel))]
		];

		rows.push(
			['面板地址', '<a href="' + esc(panel) + '" target="_blank" rel="noopener">' + esc(panel.replace(/^http:\/\//, '')) + '</a>'],
			['管理员', esc(d.admin_user || 'admin')],
			['面板密码', passHtml],
			['配置文件', d.config_exists ? '<span class="agh-ok">已生成</span>' : '<span class="agh-warn">未生成</span>'],
			['工作目录', '<span class="agh-path">' + esc(d.workdir || '') + '</span>']
		);

		if (d.dns_mode === 'takeover' && d.openclash_hijack && !d.dns_redirect) {
			rows.push(['配置建议', '<span class="agh-warn">检测到 Clash DNS 劫持，但把查询收回 53 的规则没有生效，查询可能绕过 AdGuard Home。请在「基础设置」重新保存一次「接管 53 端口」，或检查防火墙状态。</span>']);
		}
		// DNSMasq 内置劫持被固件或其它插件重新打开时，过滤会静默失效
		if ((d.dns_mode === 'takeover' || d.dns_mode === 'passwall') && String(d.dnsmasq_redirect || '') === '1') {
			rows.push(['配置建议', '<span class="agh-warn">DNSMasq 内置的 DNS 劫持（dns_redirect=1）被重新开启了，它会抢在插件规则之前把查询送到 1745，导致过滤失效。请在「基础设置」重新保存一次当前接管方式。</span>']);
		}
		if (d.dns_mode === 'passwall') {
			if (!d.passwall_enabled) {
				rows.push(['配置建议', '<span class="agh-warn">未检测到启用中的 PassWall / PassWall2，查询会经 AdGuard Home 转给本机 DNSMasq（1745），不走 PassWall 分流。</span>']);
			} else if (!d.dns_redirect) {
				rows.push(['配置建议', '<span class="agh-warn">把查询收回 53 的规则没有生效，查询可能被 PassWall 的劫持抢走。请在「基础设置」重新保存一次「PassWall 前置」。</span>']);
			} else {
				// PassWall 自带的 dnsmasq 只接受局域网来源，上游可能是 127.0.0.1 或局域网 IP，
				// 这里只比较端口，避免误报。
				var pswPort = String(d.passwall_dns_port || '');
				var ups = String(d.upstream_current || '');
				var upsPort = (ups.match(/:(\d+)\s*$/) || [])[1] || '';
				if (pswPort && d.upstream_source !== 'custom' && upsPort !== pswPort) {
					rows.push(['配置建议', '<span class="agh-warn">AdGuard Home 上游未指向当前 PassWall DNS 端口（' + esc(pswPort) +
						'），插件会在 10 秒内自动跟随（会短暂重启一次 AdGuard Home）。</span>']);
				}
			}
		}
		if (d.dns_mode === 'openclash' && d.openclash_hijack_port &&
			d.openclash_hijack_port !== '53' && d.openclash_hijack_port !== String(d.dns_port)) {
			rows.push(['配置建议', '<span class="agh-warn">Clash 把 53 直接劫持到 ' + esc(d.openclash_hijack_port) +
				'，查询不经过 DNSMasq，AdGuard Home 被绕过。请改用「Clash 前置」。</span>']);
		}
		if (d.dns_mode === 'openclash' && !d.openclash_running) {
			rows.push(['配置建议', '<span class="agh-warn">Clash 内核未运行，AdGuard Home 的上游 ' + esc(d.clash_dns_port || '7874') + ' 不可用，DNS 会解析失败。</span>']);
		}
		if (d.dns_mode === 'clashfirst') {
			if (!d.openclash_running) {
				rows.push(['配置建议', '<span class="agh-warn">Clash 内核未运行，前置链路无法生效。</span>']);
			} else if (!d.openclash_redirect || d.openclash_redirect === '0') {
				rows.push(['配置建议', '<span class="agh-warn">Clash 的 DNS 劫持未开启，客户端查询会绕过 AdGuard Home。</span>']);
			} else if (!d.openclash_upstream_agh) {
				rows.push(['配置建议', '<span class="agh-warn">未检测到指向 127.0.0.1:' + String(d.dns_port) + ' 的 Clash 上游，可保存一次设置或重启 Clash 使其生效。</span>']);
			}
		}
		if (d.parental_auto_disabled) {
			rows.push(['配置建议', '<span class="agh-warn">连不上 AdGuard 家长控制服务（family.adguard-dns.com），家长控制已自动关闭，避免全屋断网；代理可用后再开启。</span>']);
			if (!state.parentalNotified) {
				state.parentalNotified = true;
				showToast('家长控制已自动关闭：连不上 AdGuard 服务端，继续开启会导致断网', 'bad');
			}
		} else {
			state.parentalNotified = false;
			if (d.parental_enabled && d.parental_service_ok === false) {
				rows.push(['配置建议', '<span class="agh-warn">家长控制已开启，但连不上 AdGuard 家长控制服务，正在尝试自动关闭；若网络异常请手动关闭家长控制。</span>']);
			}
		}

		var wide = { '当前链路': 1, '面板地址': 1 };
		var html = '';
		for (var i = 0; i < rows.length; i++) {
			var label = rows[i][0];
			var cls = 'agh-status-item';
			if (wide[label]) cls += ' agh-status-wide';
			if (label === '配置建议') cls += ' agh-status-full';
			if (label === 'DNS 接管') cls += ' agh-status-nowrap';
			html += '<div class="' + cls + '"><span class="agh-k">' + esc(label) + '</span><span class="agh-v">' + rows[i][1] + '</span></div>';
		}
		var grid = $('agh-status-grid');
		if (grid) grid.innerHTML = html;

		attachPasswordActions(pass);
		attachCoreUpdateAction();
		updateSteps(d);

		if (d.update_running && !state.updateTimer) {
			showProgress();
			startProgressPoll();
		}
	}

	function updateSteps(d) {
		if (!d) return;
		var busy = state.busy || d.action_running || d.update_running || state.pluginUpdating;

		var installBtn = $('agh-install-btn');
		var enableBtn = $('agh-enable-btn');
		var panelLink = $('agh-panel-link');
		var noLegacyTarget = d.channel === 'legacy' && !(d.core_update && d.core_update.latest);
		var legacyRisk = d.channel === 'legacy' && d.legacy_config_risk;

		if (installBtn) {
			installBtn.disabled = busy || noLegacyTarget;
			installBtn.textContent = d.core ? '重新安装/更新内核' : '安装内核';
		}
		var coreHint = $('agh-core-hint');
		if (coreHint) {
			var cu = d.core_update;
			var hintText = '';
			var hintWarn = false;
			if (d.core) {
				if (cu && cu.update && cu.latest) {
					hintText = '已安装 ' + (d.version || '未知') + '，发现新版本 v' + cu.latest +
						(cu.beta ? '（预发布版）' : '（正式版）') + '，点击「安装/更新内核」升级';
					hintWarn = true;
				} else {
					var installedChannel = d.core_channel || (isCoreBeta(d) ? 'beta' : 'stable');
					if (d.channel && d.channel !== installedChannel) {
						// 通道已切换但目标版本不高于当前版本时不会有更新提示，这里明确给出切换入口
						hintText = '已安装 ' + (d.version || '未知') + '（' + channelLabel(installedChannel) +
							'），当前为' + channelLabel(d.channel) + '通道' +
							(cu && cu.latest ? '（目标 v' + cu.latest + '）' : '') +
							'，点击「重新安装/更新内核」切换';
						hintWarn = true;
					} else {
						hintText = '已安装，当前版本：' + (d.version || '未知');
						if (isCoreBeta(d)) hintText += '（预发布版，升级大版本前会自动备份配置）';
					}
				}
			} else {
				hintText = d.update_running ? '正在安装...' : '尚未安装内核';
			}
			if (noLegacyTarget && !d.update_running) {
				hintText = '旧版本通道暂无可用目标版本（版本检查未完成或只有一条正式版本线），请稍后刷新';
				hintWarn = true;
			}
			if (legacyRisk && d.config_schema) {
				hintText += '；当前配置为 schema ' + d.config_schema + '，且没有更旧的备份，旧版本内核会拒绝安装';
				hintWarn = true;
			}
			coreHint.className = hintWarn ? 'agh-hint agh-warn' : 'agh-hint';
			coreHint.textContent = hintText;
		}

		if (enableBtn) {
			enableBtn.disabled = !d.core || busy;
			enableBtn.textContent = d.running ? '重新应用设置' : '一键启用';
		}
		var enableHint = $('agh-enable-hint');
		if (enableHint) {
			if (!d.core) enableHint.textContent = '请先完成第 1 步。';
			else if (d.running) enableHint.textContent = '服务正在运行。';
			else if (d.enabled) enableHint.textContent = '已启用但当前未运行，请点击启动或查看日志。';
			else enableHint.textContent = '内核已就绪，可以启用。';
		}

		if (panelLink) {
			if (d.running) {
				panelLink.href = panelUrl(d.web_port);
				panelLink.className = 'agh-btn agh-btn-secondary';
				panelLink.textContent = '打开 AGH 面板';
				panelLink.removeAttribute('aria-disabled');
			} else {
				panelLink.href = '#';
				panelLink.className = 'agh-btn agh-btn-secondary is-disabled';
				panelLink.textContent = '服务未运行';
				panelLink.setAttribute('aria-disabled', 'true');
			}
		}
		var consoleHint = $('agh-console-hint');
		if (consoleHint) {
			consoleHint.textContent = d.running
				? '面板地址：' + panelUrl(d.web_port)
				: '启用服务后即可打开面板。';
		}

		var headerConsole = $('agh-header-console');
		if (headerConsole) {
			if (d.running) {
				headerConsole.href = panelUrl(d.web_port);
				headerConsole.className = 'agh-badge agh-badge-link';
				headerConsole.removeAttribute('aria-disabled');
			} else {
				headerConsole.href = '#';
				headerConsole.className = 'agh-badge agh-badge-link is-disabled';
				headerConsole.setAttribute('aria-disabled', 'true');
			}
		}

		var startBtn = $('agh-start-btn');
		var stopBtn = $('agh-stop-btn');
		var restartBtn = $('agh-restart-btn');
		if (startBtn) startBtn.disabled = busy || d.running;
		if (stopBtn) stopBtn.disabled = busy || (!d.running && !d.enabled);
		if (restartBtn) restartBtn.disabled = busy || !d.core;
	}

	function fmtCount(value) {
		if (value === null || value === undefined || value === '' || isNaN(Number(value))) return '-';
		return Number(value).toLocaleString('zh-CN');
	}

	// 统计异常提示：正常时隐藏，不占卡片高度
	function setStatsAlert(text) {
		var el = $('agh-stats-alert');
		if (!el) return;
		if (text) {
			el.textContent = text;
			el.hidden = false;
		} else {
			el.textContent = '';
			el.hidden = true;
		}
	}

	// 统计随 /status 一起返回，这里只负责渲染，避免额外请求
	function renderStats(d, status) {
		var keys = {
			queries: 'agh-stat-queries',
			blocked: 'agh-stat-blocked',
			malware: 'agh-stat-malware',
			adult: 'agh-stat-adult'
		};
		if (!d || d.ok === false) {
			Object.keys(keys).forEach(function (k) {
				var el = $(keys[k]);
				if (el) el.textContent = '-';
			});
			setStatsAlert(status && status.running === false
				? '服务未运行，暂无统计数据。'
				: ((d && d.error) || '统计读取失败。'));
			return;
		}
		Object.keys(keys).forEach(function (k) {
			if (k === 'adult') return;
			var el = $(keys[k]);
			if (el) el.textContent = fmtCount(d[k]);
		});
		var adultEl = $('agh-stat-adult');
		if (adultEl) {
			adultEl.textContent = (d.adult_filter && !Number(d.adult)) ? '已启用' : fmtCount(d.adult);
		}
		var updated = $('agh-stats-updated');
		if (updated) {
			updated.textContent = '更新于 ' + new Date().toLocaleTimeString('zh-CN', { hour12: false });
		}
		// 只有影响统计的异常才提示：防护关闭时数字不会继续增长
		setStatsAlert(d.protection === false ? '防护已关闭，统计数据不会更新；开启防护后恢复。' : '');
	}

	async function refreshStatus(silent) {
		try {
			var d = await apiGet(U.status);
			state.status = d;
			renderStatus();
			if (d && d.stats) renderStats(d.stats, d);
			if (d.action_running && !state.busy) {
				state.busy = true;
				pollAction(null);
			}
		} catch (err) {
			if (!silent) handleApiError(err);
		}
	}

	async function clearStats() {
		if (!(await aghConfirm('将清空 AdGuard Home 的 DNS 查询与拦截统计，确定继续？'))) return;
		var btn = $('agh-stats-clear');
		if (btn) btn.disabled = true;
		try {
			await apiPost(U.statsClear, {});
			showToast('统计数据已清空', 'ok');
		} catch (err) {
			handleApiError(err);
		} finally {
			if (btn) btn.disabled = false;
			refreshStatus(true);
		}
	}

	function renderSelftest(d) {
		var list = $('agh-selftest-list');
		if (!list) return;
		var checks = (d && d.checks) || [];
		if (!checks.length) {
			list.innerHTML = '<li class="agh-hint">未获取到检测结果。</li>';
			return;
		}
		list.innerHTML = checks.map(function (c) {
			var mark = c.ok ? '正常' : '异常';
			var cls = c.ok ? '' : ' style="color:#c0392b"';
			return '<li><b' + cls + '>' + mark + ' · ' + esc(c.label) + '</b><br>'
				+ '<span class="agh-hint">' + esc(c.detail || '') + '</span></li>';
		}).join('');
	}

	async function runSelftest() {
		var btn = $('agh-selftest-btn');
		if (btn) {
			btn.disabled = true;
			btn.textContent = '检测中...';
		}
		try {
			var d = await apiGet(U.selftest);
			renderSelftest(d);
			showToast(d.ok ? '自检通过' : '自检发现问题，请查看下方结果', d.ok ? 'ok' : '');
		} catch (err) {
			handleApiError(err, $('agh-selftest-list'));
		} finally {
			if (btn) {
				btn.disabled = false;
				btn.textContent = '开始检测';
			}
		}
	}

	function renderLegacy(d) {
		var card = $('agh-legacy-card');
		if (!card) return;
		var items = (d && d.items) || [];
		if (!items.length || d.ok === false) {
			card.style.display = 'none';
			return;
		}
		card.style.display = '';
		$('agh-legacy-count').textContent = items.length + ' 项';
		$('agh-legacy-list').innerHTML = items.map(function (it) {
			return '<li><b>' + esc(it.name) + '</b>：<code>' + esc(it.path) + '</code><br><span class="agh-hint">' + esc(it.note) + '</span></li>';
		}).join('');
	}

	async function loadLegacyScan() {
		try {
			var d = await apiGet(U.legacyScan);
			renderLegacy(d);
		} catch (err) {
			/* 旧版扫描失败不打扰正常使用 */
		}
	}

	async function cleanLegacy() {
		if (!(await aghConfirm('将停止并禁用旧服务、删除旧版插件文件，删除前自动备份。确定继续？'))) return;
		var btn = $('agh-legacy-clean');
		if (btn) btn.disabled = true;
		try {
			var d = await apiPost(U.legacyClean, {});
			showToast('已清理 ' + (d.removed || 0) + ' 项，备份：' + (d.backup || '-'), 'ok');
			await loadLegacyScan();
		} catch (err) {
			handleApiError(err);
		} finally {
			if (btn) btn.disabled = false;
		}
	}

	// 服务端把空 Lua 表序列化成 {} 而不是 []，这里统一兼容数组与对象两种形态，
	// 否则 (d.user_rules || []) 拿到 {} 后调 .join 会抛 TypeError。
	function toList(value) {
		if (!value) return [];
		if (Array.isArray(value)) return value;
		var out = [];
		if (typeof value === 'object') {
			for (var k in value) {
				if (Object.prototype.hasOwnProperty.call(value, k)) out.push(value[k]);
			}
		}
		return out;
	}

	// 总开关关闭时，其余功能开关置灰且不可点，避免误以为单项仍在生效
	function applyFilterMasterLock() {
		var master = $('agh-filter-enabled');
		var on = !master || master.checked;
		['agh-filter-adult', 'agh-filter-parental', 'agh-filter-safesearch', 'agh-filter-safebrowsing']
			.forEach(function (id) {
				var el = $(id);
				if (!el) return;
				el.disabled = !on;
				var field = el.closest ? el.closest('.agh-field') : null;
				if (field) field.classList.toggle('is-locked', !on);
			});
	}

	function setFilterFlags(d) {
		var map = {
			filtering_enabled: 'agh-filter-enabled',
			parental: 'agh-filter-parental',
			safesearch: 'agh-filter-safesearch',
			safebrowsing: 'agh-filter-safebrowsing'
		};
		for (var k in map) {
			if (!Object.prototype.hasOwnProperty.call(map, k)) continue;
			var el = $(map[k]);
			if (el) el.checked = !!d[k];
		}
		var rules = $('agh-filter-rules');
		// 用户正在编辑自定义规则时，刷新订阅列表不要覆盖文本域
		if (rules && !state.rulesDirty) rules.value = toList(d.user_rules).join('\n');

		// 成人内容拦截开关以 NSFW 订阅（含旧地址）是否存在且启用为准
		var adultEl = $('agh-filter-adult');
		if (adultEl) {
			var nsfw = findAdultFilter(d.filters);
			adultEl.checked = !!(nsfw && nsfw.enabled);
			// 已启用的旧地址在本页首次检测到时迁移一次到 CDN，其余情况交给用户开关
			if (nsfw && nsfw.enabled && nsfw.url !== ADULT_FILTER_URL && !state.adultMigrated) {
				state.adultMigrated = true;
				toggleAdultFilter(true);
			}
		}

		// DoH 开关以 user_rules 里是否已含全部 9 条规则为准
		var dohEl = $('agh-filter-doh');
		if (dohEl) {
			var userRules = toList(d.user_rules).map(function (x) { return String(x).trim(); });
			var hit = 0;
			for (var j = 0; j < DOH_RULES.length; j++) {
				if (userRules.indexOf(DOH_RULES[j]) >= 0) hit++;
			}
			dohEl.checked = hit === DOH_RULES.length;
		}
		applyFilterMasterLock();
		updateSwitchStates();
	}

	// 成人内容拦截：启用时写入 CDN 订阅，旧地址（raw / 上游 HaGeZi）自动迁移，避免重复列表
	async function toggleAdultFilter(on) {
		var found = findAdultFilter(state.filters);
		if (!on) {
			if (!found) return true;
			return filtersAction({ action: 'remove', url: found.url, whitelist: '0' });
		}
		if (found && found.url === ADULT_FILTER_URL) {
			if (found.enabled) return;
			return filtersAction({
				action: 'toggle',
				url: ADULT_FILTER_URL,
				name: found.name || ADULT_FILTER_NAME,
				whitelist: '0',
				enabled: '1'
			});
		}
		// 旧地址先移除，再按 CDN 地址重新添加；分两步是因为 AGH 的 set_url 不支持改地址
		if (found) {
			var ok = await filtersAction({ action: 'remove', url: found.url, whitelist: '0' });
			if (!ok) return;
		}
		return filtersAction({
			action: 'add',
			name: ADULT_FILTER_NAME,
			url: ADULT_FILTER_URL,
			whitelist: '0'
		});
	}

	// 开关 DoH 拦截：在自定义规则里增删 9 条，复用现有的规则保存接口
	function toggleDohBlock(on) {
		var ta = $('agh-filter-rules');
		var lines = ta ? ta.value.split('\n') : [];
		var out = [];
		var seen = {};
		for (var i = 0; i < lines.length; i++) {
			var s = lines[i].trim();
			if (!s) continue;
			// 裸域名与 ||domain^ 等价，统一清理后按开关状态重建
			if (DOH_RULES.indexOf(s) >= 0 || DOH_DOMAINS.indexOf(s) >= 0) continue;
			if (!seen[s]) {
				seen[s] = 1;
				out.push(s);
			}
		}
		if (on) {
			for (var k = 0; k < DOH_RULES.length; k++) out.push(DOH_RULES[k]);
		}
		if (ta) ta.value = out.join('\n');
		state.rulesDirty = false;
		return filtersAction({ action: 'rules', rules: out.join('\n') });
	}

	// 订阅来源标签：先解析出域名再比较，避免用 substring 判断时被伪造地址绕过
	function filterSource(url) {
		var u = String(url || '');
		var m = u.match(/^[a-z][a-z0-9+.-]*:\/\/([^\/?#]*)/i);
		var host = (m ? m[1] : '').toLowerCase();
		host = host.replace(/^[^@]*@/, '').replace(/:\d+$/, '');
		if (!host) return '';
		var isHost = function (name) {
			return host === name || host.slice(-(name.length + 1)) === '.' + name;
		};
		if (isHost('cdn.jsdelivr.net')) return 'jsDelivr';
		if (isHost('agh.ozero.top')) return '作者自建';
		if (/(^|\.)gh-?proxy(\.|$)/.test(host) || /(^|\.)ghfast(\.|$)/.test(host)) return 'GitHub 反代';
		if (isHost('github.com') || isHost('githubusercontent.com')) return 'GitHub 直连';
		return host;
	}

	function renderFilters(d) {
		var list = $('agh-filter-list');
		if (!list) return;
		var filters = toList(d && d.filters);
		if (!filters.length) {
			list.innerHTML = '<div class="agh-empty">还没有订阅规则</div>';
			return;
		}

		var html = '';
		for (var i = 0; i < filters.length; i++) {
			var f = filters[i];
			var wl = f.whitelist ? '1' : '0';
			var tag = f.whitelist ? ' <span class="agh-rule-tag">白名单</span>' : '';
			var src = filterSource(f.url);
			html += '<div class="agh-rule" data-url="' + esc(f.url) + '" data-name="' + esc(f.name || f.url) + '" data-whitelist="' + wl + '" title="' + esc(f.url) + '">' +
				'<input type="checkbox" class="agh-filter-toggle" ' + (f.enabled ? 'checked' : '') + '>' +
				'<span class="agh-rule-name">' + esc(f.name || f.url) + tag + '</span>' +
				(src ? '<span class="agh-rule-source">' + esc(src) + '</span>' : '') +
				'<span class="agh-rule-meta agh-rule-count">' + (f.rules_count || 0) + ' 条</span>' +
				'<button type="button" class="agh-ghost-btn agh-small-btn agh-filter-remove">删除</button>' +
				'</div>';
		}
		list.innerHTML = html;

		Array.prototype.slice.call(list.querySelectorAll('.agh-filter-toggle')).forEach(function (el) {
			el.onchange = function () {
				var row = el.closest('.agh-rule');
				filtersAction({
					action: 'toggle',
					url: row.getAttribute('data-url'),
					name: row.getAttribute('data-name'),
					whitelist: row.getAttribute('data-whitelist'),
					enabled: el.checked ? '1' : '0'
				});
			};
		});
		Array.prototype.slice.call(list.querySelectorAll('.agh-filter-remove')).forEach(function (el) {
			el.onclick = async function () {
				var row = el.closest('.agh-rule');
				if (!(await aghConfirm('删除规则列表「' + row.getAttribute('data-name') + '」？'))) return;
				filtersAction({
					action: 'remove',
					url: row.getAttribute('data-url'),
					whitelist: row.getAttribute('data-whitelist')
				});
			};
		});
	}

	async function loadFilters(silent) {
		var msg = $('agh-filters-msg');
		var list = $('agh-filter-list');
		if (!silent && list && !list.querySelector('.agh-rule')) list.innerHTML = '<div class="agh-empty">读取中...</div>';
		try {
			var d = await apiGet(U.filters);
			if (!d.ok) throw new Error(d.error || '读取失败');
			state.filters = toList(d.filters);
			setFilterFlags(d);
			renderFilters(d);
			state.presetSource = d.preset_source || 'jsdelivr';
			var srcSel = $('agh-preset-source');
			if (srcSel) srcSel.value = state.presetSource;
			setMsg(msg, '', '');
		} catch (err) {
			if (silent) return;
			handleApiError(err, msg);
			if (list) list.innerHTML = '<div class="agh-empty">读取失败</div>';
		}
	}

	async function filtersAction(data) {
		var msg = $('agh-filters-msg');
		try {
			await apiPost(U.filtersSave, data);
			showToast('已生效', 'ok');
			await loadFilters();
			return true;
		} catch (err) {
			handleApiError(err, msg);
			// 操作失败时按服务端真实状态复位开关与列表，避免滑块显示与实际不一致
			await loadFilters(true);
			return false;
		}
	}

	function bindFilterSwitch(id, feature) {
		var el = $(id);
		if (!el) return;
		el.onchange = function () {
			if (id === 'agh-filter-enabled') applyFilterMasterLock();
			filtersAction({ action: 'feature', feature: feature, value: el.checked ? '1' : '0' });
		};
	}

	// 成人内容拦截与家长控制功能重叠，开启其中一个时自动关闭另一个
	function bindParentalSwitch() {
		var el = $('agh-filter-parental');
		if (!el) return;
		el.onchange = async function () {
			var adult = $('agh-filter-adult');
			var adultWasOn = !!(adult && adult.checked);
			if (el.checked && adultWasOn) {
				if (adult) adult.checked = false;
				var ok = await toggleAdultFilter(false);
				if (!ok) {
					el.checked = false;
					return;
				}
			}
			filtersAction({ action: 'feature', feature: 'parental', value: el.checked ? '1' : '0' });
		};
	}

	// 档位切换与订阅更新都会改动 AGH 的过滤列表，必须互斥，
	// 否则 AGH 可能返回「filters are being updated」之类的冲突错误。
	function setFilterBusy(value) {
		state.filterBusy = value;
		var trim = $('agh-memory-trim');
		if (trim) {
			Array.prototype.slice.call(trim.querySelectorAll('button')).forEach(function (b) {
				b.disabled = value;
			});
		}
		var srcSel = $('agh-preset-source');
		if (srcSel) srcSel.disabled = value;
	}

	// 按设备内存切换预置规则档位
	function bindMemoryTrim() {
		var wrap = $('agh-memory-trim');
		if (!wrap) return;
		var msg = $('agh-memory-trim-msg');
		Array.prototype.slice.call(wrap.querySelectorAll('button')).forEach(function (btn) {
			btn.onclick = async function () {
				if (state.filterBusy) return;
				var tier = btn.getAttribute('data-tier');
				var label = tier === '512' ? '512MB' : (tier === '1024' ? '1GB' : '2GB 及以上');
				if (!(await aghConfirm('切换到 ' + label + ' 规则档位？会移除其它档位的预置列表。'))) return;
				Array.prototype.slice.call(wrap.querySelectorAll('button')).forEach(function (b) {
					b.classList.toggle('is-active', b === btn);
				});
				setFilterBusy(true);
				if (msg) msg.textContent = '正在切换...';
				try {
					var d = await apiPost(U.filtersSave, { action: 'trim', tier: tier });
					if (msg) msg.textContent = label + '：已订阅 ' + (d.kept || 0) + ' 个列表，变更 ' + (d.changed || 0) + ' 项';
					showToast('已切换档位', 'ok');
					await loadFilters();
				} catch (err) {
					if (msg) msg.textContent = '';
					handleApiError(err, msg);
					await loadFilters(true);
				} finally {
					setFilterBusy(false);
				}
			};
		});
	}

	// 切换预置订阅下载源：保存后把已有内置列表改到新源
	function bindPresetSource() {
		var sel = $('agh-preset-source');
		if (!sel) return;
		sel.onchange = async function () {
			if (state.filterBusy) {
				sel.value = state.presetSource || 'jsdelivr';
				return;
			}
			var msg = $('agh-filters-msg');
			var prev = state.presetSource || 'jsdelivr';
			var val = sel.value;
			setFilterBusy(true);
			if (msg) msg.textContent = '正在切换下载源...';
			try {
				var d = await apiPost(U.filtersSave, { action: 'preset_source', source: val });
				state.presetSource = val;
				var failedCount = Array.isArray(d.failed)
					? d.failed.length
					: (d.failed ? Object.keys(d.failed).length : 0);
				var text = '下载源已切换，迁移 ' + (d.migrated || 0) + ' 个列表';
				if (failedCount) text += '，失败 ' + failedCount + ' 个';
				if (msg) msg.textContent = text;
				showToast(text, 'ok');
				await loadFilters(true);
			} catch (err) {
				sel.value = prev;
				if (msg) msg.textContent = '';
				handleApiError(err, msg);
				await loadFilters(true);
			} finally {
				setFilterBusy(false);
			}
		};
	}

	function queryTimeParts(t) {
		var s = String(t || '').replace('T', ' ').trim();
		var parts = s.split(' ');
		if (parts.length > 1) {
			return { date: parts[0].slice(5), clock: parts[1].slice(0, 8) };
		}
		return { date: '', clock: (parts[0] || '').slice(0, 8) };
	}

	function queryClient(item) {
		if (item.client_name) return item.client_name + ' (' + item.client + ')';
		return item.client || '';
	}

	function renderQueryLog(items, append) {
		var el = $('agh-querylog-list');
		if (!el) return;

		var list = items || [];
		if (!list.length && !append) {
			el.innerHTML = '<tr><td colspan="6"><div class="agh-empty">没有符合条件的查询记录</div></td></tr>';
			return;
		}

		var html = list.map(function (it) {
			var blocked = it.blocked !== undefined
				? !!it.blocked
				: (String(it.reason || '').indexOf('Filtered') >= 0);
			var rule = it.rule || '';
			if (it.filter_name) rule += (rule ? ' · ' : '') + it.filter_name;
			var elapsed = it.elapsed_ms ? (Number(it.elapsed_ms).toFixed(0) + 'ms') : '';
			var tp = queryTimeParts(it.time);
			return '<tr>' +
				'<td class="agh-query-time"><span class="agh-query-date">' + esc(tp.date) + '</span>' + esc(tp.clock) + '</td>' +
				'<td class="agh-query-client" title="' + esc(queryClient(it)) + '">' + esc(queryClient(it)) + '</td>' +
				'<td class="agh-query-domain" title="' + esc(it.domain) + '">' + esc(it.domain) + '</td>' +
				'<td class="agh-query-rule" title="' + esc(rule) + '">' + esc(rule || '-') + '</td>' +
				'<td class="agh-query-elapsed">' + esc(elapsed) + '</td>' +
				'<td class="' + (blocked ? 'agh-log-block' : 'agh-log-ok') + '">' +
				(blocked ? '已拦截' : '已放行') + '</td>' +
				'</tr>';
		}).join('');

		if (append) el.insertAdjacentHTML('beforeend', html);
		else el.innerHTML = html;
	}

	async function loadQueryPage(index) {
		var list = $('agh-querylog-list');
		var info = $('agh-querylog-pageinfo');
		var prev = $('agh-querylog-prev');
		var next = $('agh-querylog-next');

		if (index < 0) index = 0;
		state.queryPage = index;
		if (info) info.textContent = '第 ' + (index + 1) + ' 页';
		if (prev) prev.disabled = index === 0;
		if (next) next.disabled = true;

		if (!state.queryPages[index]) {
			// 已有内容时保留旧行，避免刷新瞬间表格塌缩
			if (list && list.querySelectorAll('tr').length <= 1) {
				list.innerHTML = '<tr><td colspan="6"><div class="agh-empty">读取中...</div></td></tr>';
			}
			var params = new URLSearchParams();
			params.set('limit', '20');
			if (state.queryStatus) params.set('status', state.queryStatus);
			if (state.querySearch) params.set('search', state.querySearch);
			var cursor = state.queryCursors[index] || '';
			if (cursor) params.set('older_than', cursor);
			try {
				var d = await apiGet(U.querylog + '?' + params.toString());
				if (!d.ok) throw new Error(d.error || '读取失败');
				var items = Array.isArray(d.data) ? d.data : [];
				state.queryPages[index] = items;
				state.queryMore[index] = !!d.more;
				if (items.length) {
					state.queryCursors[index + 1] = d.cursor || items[items.length - 1].time;
				}
			} catch (err) {
				if (list) list.innerHTML = '<tr><td colspan="6"><div class="agh-empty">' + esc(err.message || '读取失败') + '</div></td></tr>';
				return;
			}
		}

		renderQueryLog(state.queryPages[index] || [], false);
		if (next) next.disabled = !state.queryMore[index];
	}

	function resetQueryLog() {
		state.queryPages = [];
		state.queryCursors = [''];
		state.queryMore = [];
		loadQueryPage(0);
	}

	function reloadQueryPage() {
		delete state.queryPages[state.queryPage];
		loadQueryPage(state.queryPage);
	}

	function setSelectDays(id, days, fallback) {
		var sel = $(id);
		if (!sel) return;
		var value = String(days || fallback || 30);
		var has = Array.prototype.slice.call(sel.options).some(function (opt) {
			return opt.value === value;
		});
		if (!has) {
			var extra = document.createElement('option');
			extra.value = value;
			extra.textContent = value + ' 天（当前）';
			sel.appendChild(extra);
		}
		setSelectValue(id, value);
	}

	function pollAction(onDone) {
		if (state.actionTimer) clearTimeout(state.actionTimer);
		var ticks = 0;
		state.busy = true;
		updateSteps(state.status);

		async function tick() {
			ticks++;
			try {
				var d = await apiGet(U.status);
				state.status = d;
				renderStatus();
				if (d && !d.action_running) {
					state.busy = false;
					updateSteps(d);
					if (onDone) onDone(d);
					showToast('操作完成', 'ok');
					return;
				}
			} catch (err) {
				handleApiError(err);
			}
			if (ticks < 30) {
				state.actionTimer = setTimeout(tick, 1500);
			} else {
				state.busy = false;
				updateSteps(state.status);
				showToast('操作仍在后台执行，请稍后刷新页面', 'warn');
			}
		}
		tick();
	}

	async function postService(action, confirmText) {
		if (confirmText && !(await aghConfirm(confirmText))) return;
		state.busy = true;
		updateSteps(state.status);
		apiPost(U.service, { action: action }).then(function () {
			showToast('正在执行，请稍候...', 'ok');
			pollAction();
		}).catch(function (err) {
			state.busy = false;
			updateSteps(state.status);
			handleApiError(err);
		});
	}

	function updateProgressBar(logText, running, done) {
		var bar = $('agh-progress-bar');
		if (!bar) return;
		var fill = bar.querySelector('i');
		var matches = String(logText || '').match(/下载进度：\d+%/g);
		var pct = -1;
		if (matches && matches.length) {
			pct = parseInt(matches[matches.length - 1].replace(/[^0-9]/g, ''), 10);
		}

		if (done) {
			bar.classList.remove('is-indeterminate');
			if (fill) fill.style.width = '100%';
			return;
		}
		if (!running) {
			bar.classList.remove('is-indeterminate');
			if (fill) fill.style.width = '0';
			return;
		}
		if (pct < 0) {
			bar.classList.add('is-indeterminate');
			if (fill) fill.style.width = '';
			return;
		}
		bar.classList.remove('is-indeterminate');
		if (fill) fill.style.width = Math.max(2, Math.min(100, pct)) + '%';
	}

	function showProgress(text) {
		var wrap = $('agh-progress-wrap');
		if (wrap) wrap.hidden = false;
		var log = $('agh-progress-log');
		if (log && text) log.textContent = text;
		var stateEl = $('agh-progress-state');
		if (stateEl) stateEl.textContent = '';
		updateProgressBar('', true, false);
	}

	function hideProgress() {
		var wrap = $('agh-progress-wrap');
		if (wrap) wrap.hidden = true;
		updateProgressBar('', true, false);
	}

	function startProgressPoll() {
		if (state.updateTimer) return;
		var ticks = 0;
		state.updateTimer = true;
		state.busy = true;
		state.updateStart = Date.now();

		async function tick() {
			ticks++;
			try {
				var d = await apiGet(U.coreProgress);
				var log = $('agh-progress-log');
				if (log && d && d.log) {
					log.textContent = d.log;
					log.scrollTop = log.scrollHeight;
				}
				var stateEl = $('agh-progress-state');
				if (d && d.running) {
					var elapsed = Math.max(0, Math.round((Date.now() - state.updateStart) / 1000));
					if (stateEl) stateEl.textContent = '进行中 · ' + elapsed + ' 秒';
					updateProgressBar(log ? log.textContent : '', true, false);
					ticks = 0;
					state.updateTimer = setTimeout(tick, 2000);
					return;
				}
				if (d && typeof d.code === 'number') {
					state.updateTimer = null;
					state.busy = false;
					if (stateEl) stateEl.textContent = d.code === 0 ? '完成' : ('失败（错误码 ' + d.code + '）');
					updateProgressBar('', false, d.code === 0);
					refreshStatus(true);
					showToast(d.code === 0 ? '内核安装/更新完成' : '安装失败，请查看日志', d.code === 0 ? 'ok' : 'bad');
					if (d.code === 0) setTimeout(hideProgress, 3000);
					return;
				}
				if (ticks < 8) {
					if (stateEl) stateEl.textContent = '等待任务启动...';
					state.updateTimer = setTimeout(tick, 1500);
				} else {
					state.updateTimer = null;
					state.busy = false;
					if (stateEl) stateEl.textContent = '未检测到任务';
					showToast('未能启动安装任务，请查看运行日志', 'bad');
				}
			} catch (err) {
				state.updateTimer = null;
				state.busy = false;
				handleApiError(err);
			}
		}
		tick();
	}

	async function installCore() {
		if (state.pluginUpdating) return;
		var st = state.status || {};
		var cu = st.core_update || {};
		var target = cu.latest
			? ('v' + cu.latest + (cu.beta ? '（预发布版）' : '（正式版）'))
			: '当前通道的最新内核';
		var risk = (st.channel === 'legacy' && st.legacy_config_risk)
			? '当前配置可能不被旧版本内核支持，且没有更旧的配置备份，安装会被取消。'
			: '';
		if (!(await aghConfirm('将安装 ' + target + '，需要从下载源获取，可能需要几分钟。' + risk + '确定继续？'))) return;
		showProgress('正在启动安装任务...');
		state.busy = true;
		updateSteps(state.status);
		apiPost(U.coreInstall, {}).then(function () {
			startProgressPoll();
		}).catch(function (err) {
			state.busy = false;
			updateSteps(state.status);
			handleApiError(err);
		});
	}

	// ===== 插件在线更新 =====
	// 更新说明：展示最新版内容；强制指定其它版本时隐藏，避免把最新版说明误当成目标版本
	function syncPluginNotes() {
		var p = (state.status && state.status.plugin) || {};
		var latest = p.latest || state.pluginLatest || '';
		var notes = String(p.notes || '').trim();
		var forceEl = $('agh-plugin-force');
		var force = !!(forceEl && forceEl.checked);
		var input = $('agh-plugin-version-input');
		var target = force ? ((input && input.value) || '').replace(/\s+/g, '') : latest;
		var otherVersion = !!(target && latest && target !== latest);

		var link = $('agh-plugin-update-notes-link');
		if (link) {
			if (state.pluginUrl) link.href = state.pluginUrl;
			link.hidden = !state.pluginUrl;
			link.textContent = (latest && !otherVersion) ? ('查看 v' + latest + ' 完整更新日志') : '查看完整更新日志';
		}

		var notesBox = $('agh-plugin-update-notes');
		var notesBody = $('agh-plugin-update-notes-body');
		var notesTitle = $('agh-plugin-update-notes-title');
		if (!notesBox || !notesBody) return;

		if (otherVersion) {
			notesBox.hidden = true;
			return;
		}
		notesBox.hidden = false;
		notesBox.classList.toggle('is-empty', !notes);
		var multi = (notes.match(/【v/g) || []).length > 1;
		if (notesTitle) {
			notesTitle.textContent = multi
				? ('升级到 v' + latest + ' 的更新内容')
				: (latest ? ('v' + latest + ' 更新内容') : '新版更新内容');
		}
		notesBody.textContent = notes || '该版本未在 Release 中提供更新说明。';
	}

	function openPluginUpdateModal() {
		var p = (state.status && state.status.plugin) || {};
		if (!p.update || !p.latest) return;
		state.pluginLatest = p.latest;
		if (p.url) state.pluginUrl = p.url;
		var summary = $('agh-plugin-update-summary');
		if (summary) summary.textContent = '当前 v' + (p.current || '未知') + ' → 最新 v' + p.latest;
		var force = $('agh-plugin-force');
		if (force) force.checked = false;
		var row = $('agh-plugin-version-row');
		if (row) row.hidden = true;
		var hint = $('agh-plugin-force-hint');
		if (hint) hint.hidden = true;
		var input = $('agh-plugin-version-input');
		if (input) input.value = p.latest;
		var start = $('agh-plugin-update-start');
		if (start) start.textContent = '开始更新';
		syncPluginNotes();
		var modal = $('agh-plugin-update-modal');
		if (modal) modal.hidden = false;
	}

	function togglePluginForce() {
		var force = $('agh-plugin-force');
		var on = !!(force && force.checked);
		var row = $('agh-plugin-version-row');
		if (row) row.hidden = !on;
		var hint = $('agh-plugin-force-hint');
		if (hint) hint.hidden = !on;
		var input = $('agh-plugin-version-input');
		if (on && input && !input.value) input.value = state.pluginLatest;
		var start = $('agh-plugin-update-start');
		if (start) start.textContent = on ? '开始强制更新' : '开始更新';
		syncPluginNotes();
	}

	function closePluginUpdateModal() {
		var modal = $('agh-plugin-update-modal');
		if (modal) modal.hidden = true;
	}

	function showPluginDismiss(on) {
		var dismiss = $('agh-plugin-update-dismiss');
		if (dismiss) dismiss.hidden = !on;
	}

	function showPluginProgress() {
		var card = $('agh-plugin-update-progress');
		if (card) card.hidden = false;
		showPluginDismiss(false);
	}

	function hidePluginProgress() {
		var card = $('agh-plugin-update-progress');
		if (card) card.hidden = true;
	}

	function setPluginProgress(log, running, done) {
		var bar = $('agh-plugin-update-bar');
		if (bar) {
			var fill = bar.querySelector('i');
			var matches = String(log || '').match(/下载进度：\d+%/g);
			var pct = -1;
			if (matches && matches.length) {
				pct = parseInt(matches[matches.length - 1].replace(/[^0-9]/g, ''), 10);
			}
			if (done) {
				bar.classList.remove('is-indeterminate');
				if (fill) fill.style.width = '100%';
			} else if (running && pct >= 0) {
				bar.classList.remove('is-indeterminate');
				if (fill) fill.style.width = Math.max(2, Math.min(100, pct)) + '%';
			} else {
				bar.classList.add('is-indeterminate');
				if (fill) fill.style.width = '';
			}
		}

		var logEl = $('agh-plugin-update-log');
		if (logEl) {
			logEl.textContent = log || '';
			logEl.scrollTop = logEl.scrollHeight;
		}

		var phase = $('agh-plugin-update-phase');
		if (phase) {
			var lines = String(log || '').trim().split('\n');
			phase.textContent = done ? '完成' : (lines[lines.length - 1] || '准备中...');
		}
	}

	function pollPluginProgress() {
		state.pluginTimer = null;
		apiGet(U.pluginProgress).then(function (d) {
			showPluginProgress();
			setPluginProgress(d.log || '', !!d.running, typeof d.code === 'number' && d.code === 0);
			if (d.running) {
				state.pluginUpdating = true;
				if (state.status) updatePluginVersion(state.status);
				state.pluginTimer = setTimeout(pollPluginProgress, 1500);
				return;
			}
			if (typeof d.code === 'number') {
				state.pluginUpdating = false;
				if (state.status) updatePluginVersion(state.status);
				if (d.code === 0) {
					showToast('插件更新完成，页面即将刷新', 'ok');
					setTimeout(function () { window.location.reload(); }, 2500);
				} else {
					showPluginDismiss(true);
					showToast('插件更新失败，请查看更新日志', 'bad');
				}
			} else if (state.pluginUpdating && state.pluginMiss < 4) {
				// 任务刚启动，等 running 标记出现
				state.pluginMiss += 1;
				state.pluginTimer = setTimeout(pollPluginProgress, 800);
			} else if (state.pluginUpdating) {
				state.pluginUpdating = false;
				if (state.status) updatePluginVersion(state.status);
				showPluginDismiss(true);
				showToast('未能启动更新任务，请查看运行日志', 'bad');
			}
		}).catch(function (err) {
			state.pluginUpdating = false;
			if (state.status) updatePluginVersion(state.status);
			handleApiError(err);
		});
	}

	async function startPluginUpdate() {
		if (!state.pluginLatest) return;
		var forceEl = $('agh-plugin-force');
		var force = !!(forceEl && forceEl.checked);
		var versionInput = $('agh-plugin-version-input');
		var target = force ? ((versionInput && versionInput.value) || '').replace(/\s+/g, '') : state.pluginLatest;
		if (!target) {
			showToast('请输入目标版本号', 'bad');
			return;
		}
		if (force && !/^\d+\.\d+\.\d+[\w.-]*$/.test(target)) {
			showToast('版本号格式不正确，例如 1.3.5', 'bad');
			return;
		}
		if (force) {
			if (!(await aghConfirm('强制更新到 v' + target + '？\n\n同版本为重装，低版本为降级；会先备份配置，降级可能遇到配置结构变化。'))) {
				return;
			}
		} else if (!(await aghConfirm('更新到 v' + target + '？\n\n更新过程中 AdGuard Home 会重启，DNS 可能短暂中断。'))) {
			return;
		}
		var channelEl = document.querySelector('input[name="agh-plugin-channel"]:checked');
		var methodEl = document.querySelector('input[name="agh-plugin-method"]:checked');
		closePluginUpdateModal();
		state.pluginUpdating = true;
		state.pluginMiss = 0;
		showPluginProgress();
		setPluginProgress('正在启动更新任务...\n', true, false);
		if (state.status) updatePluginVersion(state.status);
		apiPost(U.pluginUpdate, {
			version: target,
			channel: channelEl ? channelEl.value : 'cn',
			method: methodEl ? methodEl.value : 'source',
			force: force ? 1 : 0
		}).then(function () {
			state.pluginTimer = setTimeout(pollPluginProgress, 800);
		}).catch(function (err) {
			state.pluginUpdating = false;
			if (state.status) updatePluginVersion(state.status);
			hidePluginProgress();
			handleApiError(err);
		});
	}

	// 页面重新打开时恢复未完成的更新进度
	function resumePluginUpdate() {
		apiGet(U.pluginProgress).then(function (d) {
			if (d && d.running) {
				state.pluginUpdating = true;
				showPluginProgress();
				setPluginProgress(d.log || '', true, false);
				if (state.status) updatePluginVersion(state.status);
				pollPluginProgress();
			} else if (d && typeof d.code === 'number' && d.code !== 0) {
				// 上次更新失败：保留日志，方便排查，并提供关闭入口
				showPluginProgress();
				setPluginProgress(d.log || '', false, false);
				showPluginDismiss(true);
			}
		}).catch(function () { /* 忽略 */ });
	}

	function setSelectValue(id, value) {
		var el = $(id);
		if (!el) return;
		var found = false;
		for (var i = 0; i < el.options.length; i++) {
			if (el.options[i].value === value) {
				el.value = value;
				found = true;
				break;
			}
		}
		if (!found && value) {
			var opt = document.createElement('option');
			opt.value = value;
			opt.textContent = value;
			el.appendChild(opt);
			el.value = value;
		}
	}

	function pickedBypassIfaces() {
		var menu = $('agh-bypass-iface-menu');
		if (!menu) return '';
		return Array.prototype.slice.call(menu.querySelectorAll('input:checked'))
			.map(function (el) { return el.value; })
			.join(' ');
	}

	function updateBypassIfaceLabel() {
		var label = $('agh-bypass-iface-label');
		if (!label) return;
		var picked = pickedBypassIfaces().split(/\s+/).filter(Boolean);
		label.textContent = picked.length ? ('已排除：' + picked.join('、')) : '全部接管';
		label.title = picked.join(' ');
	}

	function renderBypassIfaces(devices, configured) {
		var menu = $('agh-bypass-iface-menu');
		if (!menu) return;
		var picked = (configured || '').split(/\s+/);
		var list = toList(devices).slice();
		picked.forEach(function (name) {
			if (name && list.indexOf(name) < 0) list.push(name);
		});
		menu.innerHTML = '';
		if (!list.length) {
			menu.textContent = '未检测到可用接口';
			updateBypassIfaceLabel();
			return;
		}
		list.sort();
		list.forEach(function (name) {
			var item = document.createElement('label');
			item.className = 'agh-option';
			var input = document.createElement('input');
			input.type = 'checkbox';
			input.value = name;
			input.checked = picked.indexOf(name) >= 0;
			input.addEventListener('change', updateBypassIfaceLabel);
			var text = document.createElement('span');
			text.textContent = name;
			item.appendChild(input);
			item.appendChild(text);
			menu.appendChild(item);
		});
		updateBypassIfaceLabel();
	}

	function applyUpstreamLocks() {
		var src = $('agh-set-upstream-source');
		var custom = $('agh-set-upstream-custom');
		var on = !!(src && src.value === 'custom');
		if (custom) {
			custom.disabled = !on;
		}
		var field = $('agh-upstream-custom-field');
		if (field) {
			// 自动模式下这一栏没有作用，直接隐藏，避免空白大输入框占位
			field.hidden = !on;
		}

		// 接管 53 模式下 AGH 的上游就是本机 DNSMasq(1745)，
		// 换成公网上游会丢掉路由器/DHCP 主机名的本地解析，必须提示。
		var note = $('agh-upstream-lan-note');
		if (note) {
			var modeEl = $('agh-set-dns-mode');
			var modeVal = modeEl ? modeEl.value : '';
			var show = on && (modeVal === 'takeover' || modeVal === 'passwall');
			note.hidden = !show;
			if (!show) {
				note.textContent = '';
			} else if (modeVal === 'passwall') {
				note.textContent = '当前是「PassWall 前置」：自定义上游会绕过 PassWall 的 DNS，国内外分流将失效；需要分流时请把来源保持为「自动」。';
			} else {
				note.textContent = '当前是「接管 53 端口」：自定义上游会绕过本机 DNSMasq(1745)，路由器与 DHCP 主机名（如 xxx.lan）将无法解析。需要保留本地解析时，请在列表末尾加上 127.0.0.1:1745。';
			}
		}
	}

	function applyCacheLocks() {
		var enabled = $('agh-set-cache-enabled');
		var on = !!(enabled && enabled.checked);
		var fields = $('agh-cache-fields');
		if (fields) {
			fields.classList.toggle('is-locked', !on);
			Array.prototype.slice.call(fields.querySelectorAll('input, select')).forEach(function (el) {
				el.disabled = !on;
			});
		}
		var optimistic = $('agh-set-cache-optimistic');
		if (optimistic) optimistic.disabled = !on;
	}

	function applyCryptoLocks() {
		var sel = $('agh-set-dns-crypto');
		var value = sel ? sel.value : 'off';
		var customWrap = $('agh-crypto-custom-wrap');
		if (customWrap) customWrap.hidden = value !== 'custom';

		var modeEl = $('agh-set-dns-mode');
		var mode = modeEl ? modeEl.value : '';
		var on = mode === 'clashfirst';
		var fields = $('agh-crypto-fields');
		if (fields) {
			fields.classList.toggle('is-locked', !on);
			Array.prototype.slice.call(fields.querySelectorAll('input, select, button')).forEach(function (el) {
				el.disabled = !on;
			});
		}

		var note = $('agh-crypto-mode-note');
		if (!note) return;
		// 自定义上游时右列已经有输入框，再叠加提示会显得拥挤，直接不显示
		var text = '';
		if (value !== 'custom') {
			if (!on) {
				text = '需切换到「Clash 前置」后才能使用。';
			} else if (value !== 'off' && state.cryptoBlocked) {
				text = '检测到自定义上游 DNS，加密预设不会生效；请在「DNS 解析 → 上游 DNS」把来源改回「自动」。';
			}
		}
		note.textContent = text;
		note.style.display = text ? '' : 'none';

		// 锁定时保存按钮一并禁用，避免点了没有反应
		var saveBtn = $('agh-save-crypto-btn');
		if (saveBtn) {
			saveBtn.disabled = !on;
			saveBtn.title = on ? '' : '当前接管方式不是「Clash 前置」，无法保存加密上游';
		}
	}

	function applyModeLocks(mode) {
		var takeover = mode === 'takeover';
		var group = $('agh-bypass-group');
		if (group) {
			group.classList.toggle('is-locked', !takeover);
			Array.prototype.slice.call(group.querySelectorAll('input, button, select')).forEach(function (el) {
				el.disabled = !takeover;
			});
			if (!takeover) {
				var menu = $('agh-bypass-iface-menu');
				if (menu) menu.hidden = true;
			}
		}
		var note = $('agh-bypass-note');
		if (note) note.style.display = takeover ? 'none' : '';

		var clashOption = document.querySelector('#agh-set-dns-mode option[value="clashfirst"]');
		if (clashOption) {
			clashOption.disabled = !state.openclash;
			clashOption.textContent = state.openclash
				? 'Clash 前置（Clash 7874 → AGH 5335 → 真实 DNS）'
				: 'Clash 前置（未安装 Clash，不可用）';
		}

		var passwallOption = document.querySelector('#agh-set-dns-mode option[value="passwall"]');
		if (passwallOption) {
			passwallOption.disabled = !state.passwall;
			passwallOption.textContent = state.passwall
				? 'PassWall / PassWall2 前置（AGH 53 → PassWall DNS 分流，保留劫持）'
				: 'PassWall / PassWall2 前置（未安装 PassWall，不可用）';
		}

		var modeNote = $('agh-dns-mode-note');
		if (modeNote) {
			var text = '';
			if (state.openclash && mode === 'upstream') {
				text = '检测到 Clash：该模式会改写 DNSMasq 上游，重启 Clash 后可能被覆盖，建议改用「接管 53 端口」。';
			} else if (!state.openclash && mode === 'clashfirst') {
				text = 'Clash 未安装，「Clash 前置」模式不会生效，请改用「接管 53 端口」。';
			} else if (mode === 'passwall' && !state.passwallEnabled) {
				text = 'PassWall / PassWall2 当前未启用：AdGuard Home 会把查询转给本机 DNSMasq（1745）。启用后会在 10 秒内自动切回 PassWall 分流。';
			} else if (mode === 'passwall') {
				text = 'PassWall DNS 端口：' + (state.passwallDnsPort || '11400') + '，保存后自动写入 AdGuard Home 上游，端口变化会自动跟随。';
			}
			modeNote.textContent = text;
			modeNote.style.display = text ? '' : 'none';
		}
		applyUpstreamLocks();
		applyCryptoLocks();
	}

	async function loadSettings() {
		var msgEl = $('agh-settings-msg');
		try {
			var d = await apiGet(U.settingsGet);
			if (d && d.ok === false) throw new Error(d.error || '读取设置失败');
			state.settings = d;
			var enabled = $('agh-set-enabled');
			if (enabled) enabled.checked = !!d.enabled;
			setSelectValue('agh-set-dns-mode', d.dns_mode);
			var port = $('agh-set-webport');
			if (port) port.value = d.webport;
			setSelectValue('agh-set-binpath', d.binpath);
			setSelectValue('agh-set-workdir', d.workdir);
			setSelectValue('agh-set-channel', d.channel);
			setSelectValue('agh-set-github-proxy', d.github_proxy);
			var cacheEnabled = $('agh-set-cache-enabled');
			if (cacheEnabled) cacheEnabled.checked = !!d.cache_enabled;
			var cacheSize = $('agh-set-cache-size');
			if (cacheSize) {
				var sizeValue = String(d.cache_size_mb || 16);
				var hasSize = Array.prototype.slice.call(cacheSize.options).some(function (opt) {
					return opt.value === sizeValue;
				});
				if (!hasSize) {
					var extra = document.createElement('option');
					extra.value = sizeValue;
					extra.textContent = sizeValue + ' MB（当前）';
					cacheSize.appendChild(extra);
				}
				setSelectValue('agh-set-cache-size', sizeValue);
			}
			var cacheTtlMin = $('agh-set-cache-ttl-min');
			if (cacheTtlMin) cacheTtlMin.value = (d.cache_ttl_min != null ? d.cache_ttl_min : 0);
			var cacheTtlMax = $('agh-set-cache-ttl-max');
			if (cacheTtlMax) cacheTtlMax.value = (d.cache_ttl_max != null ? d.cache_ttl_max : 0);
			var cacheOptimistic = $('agh-set-cache-optimistic');
			if (cacheOptimistic) cacheOptimistic.checked = !!d.cache_optimistic;
			applyCacheLocks();
			var upSource = $('agh-set-upstream-source');
			if (upSource) setSelectValue('agh-set-upstream-source', d.upstream_source || 'auto');
			var upCustom = $('agh-set-upstream-custom');
			if (upCustom) upCustom.value = (d.upstream_custom || '').split(' ').filter(Boolean).join('\n');
			var upCurrent = $('agh-upstream-current');
			if (upCurrent) upCurrent.textContent = d.upstream_current || '—';
			applyUpstreamLocks();
			setSelectDays('agh-set-stats-days', d.stats_retention_days, 30);
			setSelectDays('agh-set-querylog-days', d.querylog_retention_days, 30);
			var cryptoSelect = $('agh-set-dns-crypto');
			if (cryptoSelect) setSelectValue('agh-set-dns-crypto', d.dns_crypto || 'off');
			var cryptoCustom = $('agh-set-dns-crypto-custom');
			if (cryptoCustom) cryptoCustom.value = d.dns_crypto_custom || '';
			state.cryptoBlocked = !!d.crypto_blocked;
			applyCryptoLocks();
			renderBypassIfaces(d.devices, d.bypass_ifaces);
			var bypassClients = $('agh-set-bypass-clients');
			if (bypassClients) bypassClients.value = d.bypass_clients || '';
			state.openclash = !!d.openclash_installed;
			state.passwall = !!d.passwall_installed;
			state.passwallEnabled = !!d.passwall_enabled;
			state.passwallDnsPort = d.passwall_dns_port || '';
			applyModeLocks(d.dns_mode);
			var path = $('agh-yaml-path');
			if (path && d.config_path) path.textContent = d.config_path;
			setMsg(msgEl, '', '');
			var cacheMsg = $('agh-cache-msg');
			if (cacheMsg) setMsg(cacheMsg, '', '');
			var cryptoMsg = $('agh-crypto-msg');
			if (cryptoMsg) setMsg(cryptoMsg, '', '');
			updateSwitchStates();
		} catch (err) {
			handleApiError(err, msgEl);
		}
	}

	async function saveSettings(event) {
		event.preventDefault();
		var fromCacheForm = event.target && event.target.id === 'agh-cache-form';
		var fromCryptoForm = event.target && event.target.id === 'agh-crypto-form';
		var fromUpstreamForm = event.target && event.target.id === 'agh-upstream-form';
		var msgEl = fromCacheForm ? $('agh-cache-msg')
			: (fromCryptoForm ? $('agh-crypto-msg')
				: (fromUpstreamForm ? $('agh-upstream-msg') : $('agh-settings-msg')));
		var btn = fromCacheForm ? $('agh-save-cache-btn')
			: (fromCryptoForm ? $('agh-save-crypto-btn')
				: (fromUpstreamForm ? $('agh-save-upstream-btn') : $('agh-save-settings-btn')));
		var port = $('agh-set-webport');
		var portValue = port ? port.value.trim() : '';
		var n = Number(portValue);

		if (!portValue || !Number.isInteger(n) || n < 1 || n > 65535) {
			setMsg(msgEl, '管理面板端口必须是 1-65535 之间的整数。', 'bad');
			return;
		}
		if (n === 53 || n === 1745 || n === 5333 || n === 5335) {
			setMsg(msgEl, '管理面板端口不能使用 53、1745、5333 或 5335。', 'bad');
			return;
		}

		var cacheEnabled = !$('agh-set-cache-enabled') || $('agh-set-cache-enabled').checked;
		var cacheSizeRaw = $('agh-set-cache-size') ? $('agh-set-cache-size').value : '16';
		var cacheSize = Number(cacheSizeRaw);
		if (!cacheSizeRaw || !Number.isInteger(cacheSize) || cacheSize < 1 || cacheSize > 256) {
			setMsg(msgEl, '缓存大小必须是 1-256MB 之间的整数。', 'bad');
			return;
		}
		var ttlMinRaw = $('agh-set-cache-ttl-min') ? $('agh-set-cache-ttl-min').value.trim() : '60';
		var ttlMaxRaw = $('agh-set-cache-ttl-max') ? $('agh-set-cache-ttl-max').value.trim() : '0';
		var ttlMin = Number(ttlMinRaw);
		var ttlMax = Number(ttlMaxRaw);
		if (ttlMinRaw === '' || !Number.isInteger(ttlMin) || ttlMin < 0 || ttlMin > 604800) {
			setMsg(msgEl, '最小 TTL 必须是 0-604800 秒之间的整数。', 'bad');
			return;
		}
		if (ttlMaxRaw === '' || !Number.isInteger(ttlMax) || ttlMax < 0 || ttlMax > 604800) {
			setMsg(msgEl, '最大 TTL 必须是 0-604800 秒之间的整数。', 'bad');
			return;
		}
		if (ttlMax > 0 && ttlMin > ttlMax) {
			setMsg(msgEl, '最小 TTL 不能大于最大 TTL；最大 TTL 为 0 表示不限制。', 'bad');
			return;
		}

		var dnsCrypto = $('agh-set-dns-crypto') ? $('agh-set-dns-crypto').value : 'off';
		var dnsCryptoCustom = $('agh-set-dns-crypto-custom') ? $('agh-set-dns-crypto-custom').value.trim() : '';
		if (['off', 'alidns', 'dnspod', 'cloudflare', 'custom'].indexOf(dnsCrypto) < 0) {
			setMsg(msgEl, '加密上游参数不正确。', 'bad');
			return;
		}
		if (dnsCrypto === 'custom') {
			if (!dnsCryptoCustom) {
				setMsg(msgEl, '请填写自定义加密上游地址。', 'bad');
				return;
			}
			if (!/^(https:\/\/|tls:\/\/|quic:\/\/|sdns:\/\/)\S+$/.test(dnsCryptoCustom)) {
				setMsg(msgEl, '自定义加密上游需以 https://、tls://、quic:// 或 sdns:// 开头，且不能包含空格。', 'bad');
				return;
			}
		}

		var upSource = $('agh-set-upstream-source') ? $('agh-set-upstream-source').value : 'auto';
		var upRaw = $('agh-set-upstream-custom') ? $('agh-set-upstream-custom').value : '';
		var upItems = upRaw.replace(/\s+/g, ' ').trim().split(' ').filter(Boolean);
		if (upSource === 'custom') {
			if (!upItems.length) {
				setMsg(msgEl, '请填写自定义上游 DNS，或把来源改回「自动」。', 'bad');
				return;
			}
			for (var ui = 0; ui < upItems.length; ui++) {
				var addr = upItems[ui].replace(/^\[[^\]]*\]/, '');
				var valid = /^(https:\/\/|tls:\/\/|quic:\/\/|sdns:\/\/)\S+$/.test(addr) || /^[A-Za-z0-9._:-]+$/.test(addr);
				if (!valid) {
					setMsg(msgEl, '上游 DNS 格式不正确：' + upItems[ui], 'bad');
					return;
				}
			}
		}

		var data = {
			enabled: $('agh-set-enabled').checked ? '1' : '0',
			dns_mode: $('agh-set-dns-mode').value,
			webport: String(n),
			binpath: $('agh-set-binpath').value,
			workdir: $('agh-set-workdir').value,
			channel: $('agh-set-channel').value,
			github_proxy: $('agh-set-github-proxy').value,
			cache_enabled: cacheEnabled ? '1' : '0',
			cache_size_mb: String(cacheSize),
			cache_ttl_min: String(ttlMin),
			cache_ttl_max: String(ttlMax),
			cache_optimistic: (cacheEnabled && $('agh-set-cache-optimistic') && $('agh-set-cache-optimistic').checked) ? '1' : '0',
			dns_crypto: dnsCrypto,
			dns_crypto_custom: dnsCryptoCustom,
			upstream_source: upSource,
			upstream_custom: upItems.join(' '),
			bypass_ifaces: pickedBypassIfaces(),
			bypass_clients: $('agh-set-bypass-clients') ? $('agh-set-bypass-clients').value.trim() : ''
		};

		if (btn) btn.disabled = true;
		setMsg(msgEl, '正在保存并应用设置...', '');
		try {
			await apiPost(U.settingsSave, data);
			setMsg(msgEl, '设置已保存，正在应用...', 'ok');
			showToast('设置已保存，正在重启服务...', 'ok');
			pollAction(function () {
				if (btn) btn.disabled = false;
				loadSettings();
				refreshStatus(true);
			});
		} catch (err) {
			if (btn) btn.disabled = false;
			applyCryptoLocks();
			handleApiError(err, msgEl);
		}
	}

	async function loadYaml() {
		var msgEl = $('agh-yaml-msg');
		var editor = $('agh-yaml-editor');
		if (!editor) return;
		try {
			var d = await apiGet(U.yamlGet);
			editor.value = d.yaml || '';
			updateYamlCount();
			var path = $('agh-yaml-path');
			if (path && d.path) path.textContent = d.path;
			state.yamlLoaded = true;
			setMsg(msgEl, d.yaml ? '' : '配置文件尚未生成，请先启用服务。', d.yaml ? '' : 'bad');
		} catch (err) {
			handleApiError(err, msgEl);
		}
	}

	function updateYamlCount() {
		var editor = $('agh-yaml-editor');
		var count = $('agh-yaml-count');
		if (editor && count) count.textContent = editor.value.length + ' 字符';
	}

	async function saveYaml() {
		var editor = $('agh-yaml-editor');
		var msgEl = $('agh-yaml-msg');
		var btn = $('agh-yaml-save');
		if (!editor) return;
		if (!(await aghConfirm('将校验并保存 AdGuardHome.yaml，随后重启服务。确定继续？'))) return;
		if (btn) btn.disabled = true;
		setMsg(msgEl, '正在校验配置...', '');
		try {
			await apiPost(U.yamlSave, { yaml: editor.value });
			setMsg(msgEl, '配置已保存，正在重启服务...', 'ok');
			showToast('配置已保存，正在重启服务...', 'ok');
			pollAction(function () {
				if (btn) btn.disabled = false;
				loadYaml();
				refreshStatus(true);
			});
		} catch (err) {
			if (btn) btn.disabled = false;
			handleApiError(err, msgEl);
		}
	}

	async function loadLogs() {
		var box = $('agh-log-box');
		if (!box) return;
		try {
			var url = U.logs + (state.logLevel ? ('?level=' + encodeURIComponent(state.logLevel)) : '');
			var text = await apiText(url);
			state.logText = text || '';
			renderLogSections(text);
		} catch (err) {
			box.innerHTML = '<div class="agh-empty">读取日志失败：' + esc(err && err.message ? err.message : err) + '</div>';
			handleApiError(err);
		}
	}

	// 把后端拼接的日志按 ***** 标题 ***** 拆成独立区块
	function renderLogSections(text) {
		var box = $('agh-log-box');
		if (!box) return;

		var raw = String(text || '').replace(/\r\n/g, '\n');
		var sections = [];
		var title = '系统日志';
		var lastIndex = 0;
		var re = /^\s*[=*]{5}\s*(.+?)\s*[=*]{5}\s*$/gm;
		var m;

		while ((m = re.exec(raw)) !== null) {
			var body = raw.slice(lastIndex, m.index).replace(/^\n+|\n+$/g, '');
			if (body || sections.length) {
				sections.push({ title: title, body: body });
			}
			title = m[1];
			lastIndex = re.lastIndex;
		}

		var tail = raw.slice(lastIndex).replace(/^\n+|\n+$/g, '');
		if (tail) sections.push({ title: title, body: tail });

		if (!sections.length) {
			box.innerHTML = '<div class="agh-empty">暂无相关日志。</div>';
			return;
		}

		function rankOf(title) {
			if (title.indexOf('持久化状态') === 0) return 0;
			if (title.indexOf('服务操作') >= 0) return 1;
			if (title.indexOf('订阅更新') === 0) return 2;
			if (title.indexOf('系统日志') === 0) return 3;
			if (title.indexOf('内核安装') === 0) return 4;
			return 99;
		}

		sections.sort(function (a, b) { return rankOf(a.title) - rankOf(b.title); });
		for (var si = 0; si < sections.length; si++) {
			if (sections[si].title.indexOf('服务操作') >= 0) {
				sections[si].title = '服务操作日志';
			}
		}

		box.innerHTML = sections.map(function (s) {
			var main = s.title.indexOf('系统日志') === 0 ? ' agh-log-section-main' : '';
			var tall = (s.title.indexOf('服务操作') >= 0 || s.title.indexOf('订阅更新') === 0)
				? ' agh-log-section-tall' : '';
			var body = s.body || '';
			// 系统日志按时间倒序，最新的记录排在最前
			if (main && body) {
				body = body.replace(/\n+$/, '').split('\n').reverse().join('\n');
			}
			return '<section class="agh-log-section' + main + tall + '">' +
				'<h4 class="agh-log-section-title">' + esc(s.title) + '</h4>' +
				'<pre class="agh-log agh-log-tall">' + esc(body || '（暂无记录）') + '</pre>' +
				'</section>';
		}).join('');
	}

	function downloadLogs() {
		var text = state.logText || '';
		if (!text) {
			showToast('没有可下载的日志', 'bad');
			return;
		}
		var blob = new Blob([text], { type: 'text/plain;charset=utf-8' });
		var a = document.createElement('a');
		var d = new Date();
		var stamp = d.getFullYear() + ('0' + (d.getMonth() + 1)).slice(-2) + ('0' + d.getDate()).slice(-2)
			+ '-' + ('0' + d.getHours()).slice(-2) + ('0' + d.getMinutes()).slice(-2);
		a.href = URL.createObjectURL(blob);
		a.download = 'adguardhome-lite-log-' + stamp + '.txt';
		a.click();
		URL.revokeObjectURL(a.href);
	}

	function copyText(text) {
		if (!text) return;
		if (navigator.clipboard && window.isSecureContext) {
			navigator.clipboard.writeText(text);
			showToast('密码已复制到剪贴板', 'ok');
			return;
		}
		var ta = document.createElement('textarea');
		ta.value = text;
		ta.style.position = 'fixed';
		ta.style.left = '-9999px';
		document.body.appendChild(ta);
		ta.select();
		try {
			document.execCommand('copy');
			showToast('密码已复制到剪贴板', 'ok');
		} catch (e) {
			showToast('浏览器不支持自动复制，请手动选择密码', 'bad');
		}
		document.body.removeChild(ta);
	}

	async function savePassword(event) {
		event.preventDefault();
		var msgEl = $('agh-pass-msg');
		var btn = $('agh-savepass-btn');
		var pwEl = $('agh-newpass');
		var pw2El = $('agh-newpass2');
		var pw = pwEl ? pwEl.value : '';
		var pw2 = pw2El ? pw2El.value : '';

		if (!pw || pw.length < 8) {
			setMsg(msgEl, '新密码至少需要 8 个字符。', 'bad');
			return;
		}
		if (pw !== pw2) {
			setMsg(msgEl, '两次输入的密码不一致。', 'bad');
			return;
		}
		if (typeof TwinBcrypt === 'undefined') {
			setMsg(msgEl, '密码组件加载失败，请刷新页面后重试。', 'bad');
			return;
		}

		var hash;
		try {
			hash = TwinBcrypt.hashSync(pw, 10);
		} catch (e) {
			setMsg(msgEl, '密码哈希计算失败：' + e, 'bad');
			return;
		}

		if (btn) btn.disabled = true;
		setMsg(msgEl, '正在保存新密码...', '');
		try {
			await apiPost(U.password, { hash: hash, password: pw });
			setMsg(msgEl, '密码已保存，正在重启服务...', 'ok');
			showToast('面板密码修改成功', 'ok');
			if (pwEl) pwEl.value = '';
			if (pw2El) pw2El.value = '';
			pollAction(function () {
				if (btn) btn.disabled = false;
				refreshStatus(true);
			});
		} catch (err) {
			if (btn) btn.disabled = false;
			handleApiError(err, msgEl);
		}
	}

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
	}

	function initEvents() {
		var tabs = document.querySelectorAll('.agh-tab');
		for (var i = 0; i < tabs.length; i++) {
			tabs[i].onclick = function () {
				switchTab(this.getAttribute('data-tab'));
			};
		}
		var gotoButtons = document.querySelectorAll('[data-goto]');
		for (var j = 0; j < gotoButtons.length; j++) {
			gotoButtons[j].onclick = function () {
				switchTab(this.getAttribute('data-goto'));
			};
		}
		var subTabs = document.querySelectorAll('#agh-settings-tabs .agh-subtab');
		for (var k = 0; k < subTabs.length; k++) {
			subTabs[k].onclick = function () {
				switchSettingsTab(this.getAttribute('data-subtab'));
			};
		}
		var logTabs = document.querySelectorAll('#agh-logs-tabs .agh-subtab');
		for (var m = 0; m < logTabs.length; m++) {
			logTabs[m].onclick = function () {
				switchLogTab(this.getAttribute('data-logtab'));
			};
		}

		if ($('agh-refresh-status')) $('agh-refresh-status').onclick = function () { refreshStatus(); };
		if ($('agh-stats-clear')) $('agh-stats-clear').onclick = clearStats;
		if ($('agh-theme-toggle')) $('agh-theme-toggle').onclick = toggleTheme;
		if ($('agh-legacy-clean')) $('agh-legacy-clean').onclick = cleanLegacy;
		if ($('agh-selftest-btn')) $('agh-selftest-btn').onclick = runSelftest;
		if ($('agh-install-btn')) $('agh-install-btn').onclick = installCore;
		if ($('agh-enable-btn')) $('agh-enable-btn').onclick = function () {
			postService('bootstrap', '将启动 AdGuard Home 并接管路由器 DNS。确定继续？');
		};
		if ($('agh-start-btn')) $('agh-start-btn').onclick = function () { postService('start'); };
		if ($('agh-stop-btn')) $('agh-stop-btn').onclick = function () {
			postService('stop', '将停止 AdGuard Home 并关闭面板，同时恢复 DNSMasq 原始设置。确定继续？');
		};
		if ($('agh-restart-btn')) $('agh-restart-btn').onclick = function () {
			postService('restart', '将重启 AdGuard Home 服务。确定继续？');
		};
		if ($('agh-settings-form')) $('agh-settings-form').onsubmit = saveSettings;
		if ($('agh-cache-form')) $('agh-cache-form').onsubmit = saveSettings;
		if ($('agh-upstream-form')) $('agh-upstream-form').onsubmit = saveSettings;
		if ($('agh-crypto-form')) $('agh-crypto-form').onsubmit = saveSettings;

		if ($('agh-plugin-update')) $('agh-plugin-update').onclick = openPluginUpdateModal;
		if ($('agh-plugin-version')) {
			$('agh-plugin-version').onclick = checkPluginUpdate;
			$('agh-plugin-version').onkeydown = function (e) {
				if (e.key === 'Enter' || e.key === ' ') {
					e.preventDefault();
					checkPluginUpdate();
				}
			};
		}
		if ($('agh-plugin-update-cancel')) $('agh-plugin-update-cancel').onclick = closePluginUpdateModal;
		if ($('agh-plugin-update-mask')) $('agh-plugin-update-mask').onclick = closePluginUpdateModal;
		if ($('agh-plugin-update-start')) $('agh-plugin-update-start').onclick = startPluginUpdate;
		if ($('agh-plugin-force')) $('agh-plugin-force').onchange = togglePluginForce;
		if ($('agh-plugin-version-input')) $('agh-plugin-version-input').oninput = syncPluginNotes;
		if ($('agh-plugin-update-dismiss')) $('agh-plugin-update-dismiss').onclick = hidePluginProgress;
		document.addEventListener('keydown', function (e) {
			if (e.key !== 'Escape') return;
			var modal = $('agh-plugin-update-modal');
			if (modal && !modal.hidden) closePluginUpdateModal();
		});

		bindFilterSwitch('agh-filter-enabled', 'filtering');
		bindParentalSwitch();
		bindFilterSwitch('agh-filter-safesearch', 'safesearch');
		bindFilterSwitch('agh-filter-safebrowsing', 'safebrowsing');
		bindMemoryTrim();
		bindPresetSource();

		// 成人内容拦截与家长控制功能重叠，开启其中一个时自动关闭另一个
		if ($('agh-filter-adult')) {
			$('agh-filter-adult').onchange = async function () {
				var el = this;
				var parental = $('agh-filter-parental');
				var parentalWasOn = !!(parental && parental.checked);
				if (el.checked && parentalWasOn) {
					if (parental) parental.checked = false;
					var ok = await filtersAction({ action: 'feature', feature: 'parental', value: '0' });
					if (!ok) {
						el.checked = false;
						return;
					}
				}
				toggleAdultFilter(el.checked);
			};
		}

		if ($('agh-filter-add-form')) {
			$('agh-filter-add-form').onsubmit = function (e) {
				e.preventDefault();
				var url = ($('agh-filter-url') ? $('agh-filter-url').value : '').trim();
				if (!url) {
					setMsg($('agh-filters-msg'), '请填写订阅地址。', 'bad');
					return;
				}
				filtersAction({
					action: 'add',
					name: ($('agh-filter-name') ? $('agh-filter-name').value : '').trim(),
					url: url,
					whitelist: ($('agh-filter-whitelist') && $('agh-filter-whitelist').value === '1') ? '1' : '0'
				});
			};
		}
		if ($('agh-filter-rules-form')) {
			$('agh-filter-rules-form').onsubmit = async function (e) {
				e.preventDefault();
				var ok = await filtersAction({ action: 'rules', rules: $('agh-filter-rules') ? $('agh-filter-rules').value : '' });
				if (ok) state.rulesDirty = false;
			};
		}
		if ($('agh-filter-rules')) {
			$('agh-filter-rules').oninput = function () {
				state.rulesDirty = true;
			};
		}
		if ($('agh-filter-doh')) {
			$('agh-filter-doh').onchange = function () {
				toggleDohBlock(this.checked).then(function () {
					updateSwitchStates();
				});
			};
		}
		if ($('agh-retention-form')) {
			$('agh-retention-form').onsubmit = async function (e) {
				e.preventDefault();
				var msg = $('agh-retention-msg');
				var btn = $('agh-save-retention-btn');
				if (btn) btn.disabled = true;
				try {
					await apiPost(U.retention, {
						days: $('agh-set-stats-days') ? $('agh-set-stats-days').value : '30',
						query_days: $('agh-set-querylog-days') ? $('agh-set-querylog-days').value : '30'
					});
					showToast('保留周期已保存，正在应用...', 'ok');
					pollAction(function () {
						if (btn) btn.disabled = false;
					});
				} catch (err) {
					if (btn) btn.disabled = false;
					handleApiError(err, msg);
				}
			};
		}
		if ($('agh-querylog-refresh')) {
			$('agh-querylog-refresh').onclick = function () { resetQueryLog(); };
		}
		if ($('agh-querylog-prev')) {
			$('agh-querylog-prev').onclick = function () { loadQueryPage(state.queryPage - 1); };
		}
		if ($('agh-querylog-next')) {
			$('agh-querylog-next').onclick = function () { loadQueryPage(state.queryPage + 1); };
		}
		var qfilter = document.querySelectorAll('#agh-querylog-filter button');
		for (var qi = 0; qi < qfilter.length; qi++) {
			qfilter[qi].onclick = function () {
				state.queryStatus = this.getAttribute('data-qstatus') || '';
				for (var k = 0; k < qfilter.length; k++) {
					qfilter[k].classList.toggle('is-active', qfilter[k] === this);
				}
				resetQueryLog();
			};
		}
		var qsearchTimer = null;
		if ($('agh-querylog-search')) {
			$('agh-querylog-search').oninput = function () {
				var value = this.value;
				if (qsearchTimer) clearTimeout(qsearchTimer);
				qsearchTimer = setTimeout(function () {
					state.querySearch = value.replace(/^\s+|\s+$/g, '');
					resetQueryLog();
				}, 400);
			};
		}
		if ($('agh-querylog-auto')) {
			var startQueryTimer = function () {
				if (state.queryTimer) {
					clearInterval(state.queryTimer);
					state.queryTimer = null;
				}
				if (state.queryAuto > 0) {
					state.queryTimer = setInterval(function () {
						if (document.hidden || state.logSubtab !== 'query') return;
						var panel = $('agh-tab-logs');
						if (!panel || !panel.classList.contains('is-active')) return;
						reloadQueryPage();
					}, state.queryAuto * 1000);
				}
			};
			$('agh-querylog-auto').onchange = function () {
				state.queryAuto = Number(this.value) || 0;
				startQueryTimer();
			};
			// 默认每 5 秒自动刷新
			state.queryAuto = Number($('agh-querylog-auto').value) || 0;
			startQueryTimer();
		}
		if ($('agh-set-cache-enabled')) $('agh-set-cache-enabled').onchange = applyCacheLocks;
		if ($('agh-set-upstream-source')) $('agh-set-upstream-source').onchange = applyUpstreamLocks;
		if ($('agh-set-dns-crypto')) $('agh-set-dns-crypto').onchange = applyCryptoLocks;
		if ($('agh-set-dns-mode')) {
			$('agh-set-dns-mode').onchange = function () {
				applyModeLocks(this.value);
			};
		}
		if ($('agh-bypass-iface-toggle')) {
			$('agh-bypass-iface-toggle').onclick = function (e) {
				e.stopPropagation();
				var menu = $('agh-bypass-iface-menu');
				if (menu) menu.hidden = !menu.hidden;
			};
			document.addEventListener('click', function (e) {
				var menu = $('agh-bypass-iface-menu');
				var dd = $('agh-bypass-iface-dd');
				if (menu && !menu.hidden && dd && !dd.contains(e.target)) menu.hidden = true;
			});
		}
		if ($('agh-password-form')) $('agh-password-form').onsubmit = savePassword;
		if ($('agh-yaml-load')) $('agh-yaml-load').onclick = async function () {
			if (state.yamlLoaded && !(await aghConfirm('重新加载会丢弃当前未保存的修改。确定继续？'))) return;
			loadYaml();
		};
		if ($('agh-yaml-save')) $('agh-yaml-save').onclick = saveYaml;
		if ($('agh-yaml-editor')) $('agh-yaml-editor').oninput = updateYamlCount;

		if ($('agh-log-refresh')) {
			$('agh-log-refresh').onclick = async function () {
				var btn = this;
				if (btn.disabled) return;
				var label = btn.textContent;
				btn.disabled = true;
				btn.textContent = '刷新中...';
				try {
					await loadLogs();
				} finally {
					btn.disabled = false;
					btn.textContent = label;
				}
			};
		}
		if ($('agh-log-level')) {
			$('agh-log-level').onchange = function () {
				state.logLevel = this.value || '';
				loadLogs();
			};
		}
		if ($('agh-log-download')) $('agh-log-download').onclick = downloadLogs;
		if ($('agh-log-auto')) {
			$('agh-log-auto').onchange = function () {
				if (state.logTimer) {
					clearInterval(state.logTimer);
					state.logTimer = null;
				}
				if (this.checked) {
					state.logTimer = setInterval(function () {
						if (document.hidden || state.logSubtab !== 'sys') return;
						var panel = $('agh-tab-logs');
						if (!panel || !panel.classList.contains('is-active')) return;
						loadLogs();
					}, 5000);
				}
			};
			// 默认开启 5 秒自动刷新
			if ($('agh-log-auto').checked) {
				state.logTimer = setInterval(function () {
					if (document.hidden || state.logSubtab !== 'sys') return;
					var panel = $('agh-tab-logs');
					if (!panel || !panel.classList.contains('is-active')) return;
					loadLogs();
				}, 5000);
			}
		}

		window.addEventListener('hashchange', function () {
			switchTab((window.location.hash || '#overview').replace('#', ''), false);
		});

		document.addEventListener('change', function (e) {
			if (e.target && e.target.type === 'checkbox') updateSwitchStates();
		});
	}

	function init() {
		initTheme();
		initThemeSync();
		initHeroCore();
		initEvents();
		updateSwitchStates();
		var hash = (window.location.hash || '#overview').replace('#', '');
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
