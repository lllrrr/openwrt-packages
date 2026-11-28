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
		yamlHash: '',
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
		openclash: false,
		passwall: false,
		passwallEnabled: false,
		passwallDnsPort: '',
		updateTimer: null,
		actionTimer: null,
		logTimer: null,
		toastTimer: null
	};

