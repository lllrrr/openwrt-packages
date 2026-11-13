/* cfpick 操作台 — vanilla JS, no build step.
 *
 * 与 Debian 版（debian/web/app.js）同一套界面与交互；区别只有节点来源：
 * 这里的节点是 PassWall 的 worker，配置与结果通过本包的 ucode CGI 读写，
 * 登录用操作台自己的账号密码（Debian 版用 Web 令牌）。
 */
(function () {
	'use strict';

	const $ = (selector, root) => (root || document).querySelector(selector);
	const $$ = (selector, root) => Array.from((root || document).querySelectorAll(selector));

	const state = {
		config: null,
		// 在线源列表：[{ url, enabled }]，enabled=false 的仍保留在配置里但不用。
		onlineSources: [],
		providers: {},
		status: null,
		core: null,
		best: null,
		history: [],
		downloads: [],
		ovSelectedNode: '',
		histSelectedNode: '',
		histMetric: 'speed',
		histPoints: [],
		openDropdown: '',
		dropdownOutsideBound: false,
		tasks: null,
		tasklog: [],
		appInfo: null,
		appTimer: 0,
		coreTimer: 0,
		tab: 'overview',
		logPos: 0,
		logSubtab: 'runlog',
		lastRunning: false,
		pollTimer: 0,
		logTimer: 0,
		taskTimer: 0,
		elapsedTimer: 0,
		coreTags: {},
		authMode: 'login',
		csrf: '',
		loggedIn: false,
		toastTimer: 0,
		// 日志读取串行化，避免切页/定时器/手动刷新并发读到同一段而重复追加。
		logChain: Promise.resolve(),
	};

	const PHASES = {
		idle: '空闲',
		starting: '启动中',
		testing: '一轮延迟测试',
		latency: '一轮延迟测试',
		running: '一轮延迟测试',
		download: '下载实测',
		committing: '写入结果',
		commit: '写入结果',
		stopping: '正在停止',
		done: '已完成',
		failed: '失败',
	};

	// ── api ─────────────────────────────────────────────────────────────
	// The console can be served at the root (direct :17544) or behind a
	// reverse-proxy path prefix; resolve assets and the CGI relative to the
	// page's directory so both work.
	function apiBase() {
		let path = window.location.pathname || '/';
		if (path.charAt(path.length - 1) !== '/')
			path = path.substring(0, path.lastIndexOf('/') + 1);
		return path || '/';
	}

	const ROUTES = {
		'/api/status': 'status',
		'/api/config': 'config',
		'/api/nodes': 'nodes',
		'/api/best': 'best',
		'/api/history': 'history',
		'/api/downloads': 'downloads',
		'/api/tasklog': 'tasklog',
		'/api/log': 'log',
		'/api/cron': 'tasks',
		'/api/ddns': 'ddns_preview',
		'/api/core': 'standalone',
		'/api/core/save': 'standalone_save',
		'/api/core/update': 'standalone_update_core',
		'/api/app': 'app_status',
		'/api/stop': 'stop',
		'/api/cron/task/save': 'task_save',
		'/api/cron/task/delete': 'task_delete',
		'/api/cron/task/add': 'task_add',
		'/api/ddns/apply': 'ddns_apply',
		'/api/update-app': 'app_update',
	};

	function splitPath(path) {
		const at = path.indexOf('?');
		const route = at < 0 ? path : path.slice(0, at);
		const query = new URLSearchParams(at < 0 ? '' : path.slice(at + 1));
		return { route: route, query: query };
	}

	async function request(action, options) {
		options = options || {};
		const method = options.method || 'GET';
		const params = new URLSearchParams({ action: action });
		Object.keys(options.query || {}).forEach((key) => {
			params.set(key, options.query[key]);
		});
		if (method === 'POST' && state.csrf)
			params.set('csrf', state.csrf);

		const headers = {};
		let body;
		if (options.body !== undefined && options.body !== null) {
			headers['Content-Type'] = 'application/json';
			body = (typeof options.body === 'string') ? options.body : JSON.stringify(options.body);
		}

		const response = await fetch(apiBase() + 'cgi-bin/api?' + params.toString(), {
			method: method,
			headers: headers,
			body: body,
			credentials: 'same-origin',
			cache: 'no-store',
		});

		let payload;
		try { payload = await response.json(); }
		catch (e) { payload = null; }

		if (response.status === 401 && action !== 'hello' && action !== 'login' && action !== 'setup')
			showAuth('login');

		// rpcd 拒绝未声明参数/未重载插件时会返回 JSON null；给出可操作的提示，
		// 而不是让浏览器抛 "Cannot read properties of null"。
		if (payload == null || typeof payload !== 'object')
			throw new Error('操作台 API 返回空响应（rpcd 插件可能未重载或参数不匹配），请执行 /etc/init.d/rpcd restart 后重试');

		if (!response.ok || payload.ok !== true)
			throw new Error(payload.error || ('HTTP ' + response.status));

		return translate(action, payload.data);
	}

	function translate(action, data) {
		switch (action) {
		case 'status': return translateStatus(data);
		case 'config': return { config: data || {} };
		case 'tasks': return {
			tasks: (data && data.entries) || [],
			writable: (data && data.writable) || '',
			run_script: (data && data.run_script) || '',
			errors: [],
		};
		case 'standalone': return translateCore(data);
		case 'app_status': return translateApp(data);
		default: return data;
		}
	}

	async function api(path, options) {
		options = options || {};
		const parsed = splitPath(path);
		let action = ROUTES[parsed.route];
		let body = options.body;

		if (parsed.route === '/api/start')
			action = (body && body.mode === 'retest') ? 'retest' : 'start';

		// 定时任务按 crontab 行保存，新增任务需要拼出完整命令。
		if (parsed.route === '/api/cron/task/add') {
			const script = (state.tasks && state.tasks.run_script) || '/usr/lib/cfpick/bin/cfpick.sh';
			body = {
				source: (state.tasks && state.tasks.writable) || '/etc/crontabs/root',
				schedule: body.schedule,
				command: script + ' ' + (body.mode || 'retest'),
				nodes: body.nodes || [],
			};
		}

		if (!action)
			throw new Error('未知接口：' + parsed.route);

		return request(action, {
			method: options.method || 'GET',
			body: body,
			query: Object.assign({}, options.query || {}, Object.fromEntries(parsed.query)),
		});
	}

	function translateStatus(status) {
		status = status || {};
		const core = state.core || {};
		const active = core.active || '';
		const info = (core.cores && core.cores[active]) || {};
		return {
			running: !!status.running,
			phase: status.phase || 'idle',
			elapsed: status.elapsed || 0,
			started_at: status.started_at || 0,
			node_count: status.node_count || 0,
			result_rows: status.result_rows || 0,
			cron: !!status.cron,
			cron_line: '',
			stop_requested: !!status.stop_requested,
			workers: status.workers || {},
			download_active: !!status.download_active,
			last: {
				last_time: status.last_time || '',
				best_ip: (status.best && status.best.ip) || '',
				best_latency: (status.best && status.best.latency) || 0,
				best_speed: (status.best && status.best.speed) || 0,
				finished_at: 0,
				error: '',
			},
			core: active ? Object.assign({ type: active }, info) : null,
			ddns: ddnsInfo(),
			version: (state.appInfo && state.appInfo.version) || '',
			state_dir: '/tmp/cfpick',
		};
	}

	function translateCore(data) {
		const raw = (data && data.cores && data.cores.cores) || {};
		const cores = {};
		Object.keys(raw).forEach((key) => { cores[key] = raw[key] || {}; });
		return {
			enabled: !!(data && data.enabled),
			active: (data && data.core) || '',
			cores: cores,
			updating: !!(data && data.updating),
			updating_type: (data && data.updating_type) || '',
			message: (data && data.updating) ? '内核更新中…' : '',
			error: '',
			update_log: (data && data.update_log) || '',
		};
	}

	function translateApp(data) {
		data = data || {};
		return {
			version: data.current_version || '',
			manageable: true,
			systemd_run: true,
			update: {
				updating: !!data.updating,
				ok: data.ok !== false,
				message: data.message || '',
				error: data.error || '',
				version: data.version || '',
			},
		};
	}

	// ── auth ────────────────────────────────────────────────────────────
	function storageGet(key) {
		try { return localStorage.getItem(key); }
		catch (e) { return null; }
	}

	function storageSet(key, value) {
		try { localStorage.setItem(key, value); }
		catch (e) { /* private mode */ }
	}

	function showAuth(mode) {
		state.authMode = mode || 'login';
		state.loggedIn = false;
		state.csrf = '';
		stopPolling();
		$('#auth-overlay').classList.remove('hidden');

		setText('auth-title', state.authMode === 'setup' ? '创建管理员账号' : '登录操作台');
		setText('auth-desc', state.authMode === 'setup'
			? '首次使用，请设置操作台管理员账号和密码。'
			: '输入管理员账号进入操作台。');
		$('#auth-confirm-row').classList.toggle('hidden', state.authMode !== 'setup');
		$('#auth-submit').textContent = state.authMode === 'setup' ? '创建并登录' : '登录';
		$('#auth-error').textContent = '';
		$('#auth-password').value = '';
		$('#auth-confirm').value = '';
		$('#auth-user').value = storageGet('cfpick_web_user') || 'admin';
		$('#auth-password').focus();
	}

	function hideAuth() {
		$('#auth-overlay').classList.add('hidden');
	}

	async function onAuthSubmit(event) {
		event.preventDefault();

		const user = $('#auth-user').value.trim();
		const password = $('#auth-password').value;
		const confirm = $('#auth-confirm').value;
		const error = $('#auth-error');
		const button = $('#auth-submit');

		error.textContent = '';

		if (!user) { error.textContent = '请输入用户名'; return; }
		if (!password) { error.textContent = '请输入密码'; return; }

		if (state.authMode === 'setup') {
			if (password.length < 6) { error.textContent = '密码至少 6 位'; return; }
			if (password !== confirm) { error.textContent = '两次输入的密码不一致'; return; }
		}

		button.disabled = true;

		try {
			const data = await request(state.authMode, {
				method: 'POST',
				body: { user: user, password: password },
			});
			state.csrf = (data && data.csrf) || '';
			state.loggedIn = true;
			storageSet('cfpick_web_user', user);
			hideAuth();
			await bootApp();
		}
		catch (e) {
			error.textContent = e.message;
		}
		finally {
			button.disabled = false;
		}
	}

	async function logout() {
		try { await request('logout', { method: 'POST', body: {} }); }
		catch (e) { /* ignore */ }
		stopPolling();
		state.status = null;
		state.lastRunning = false;
		showAuth('login');
	}

	// ── toast / dialogs ─────────────────────────────────────────────────
	function toast(message, isError) {
		const node = $('#toast');
		node.textContent = message;
		node.classList.toggle('error', !!isError);
		node.classList.remove('hidden');
		clearTimeout(state.toastTimer);
		state.toastTimer = setTimeout(() => node.classList.add('hidden'), isError ? 6500 : 3800);
	}

	function closeOverlays() {
		$$('.overlay').forEach((node) => {
			if (node.id !== 'auth-overlay')
				node.classList.add('hidden');
		});
	}

	// ── formatting ──────────────────────────────────────────────────────
	function fmtDuration(seconds) {
		seconds = Math.max(0, Math.floor(seconds || 0));
		const h = Math.floor(seconds / 3600);
		const m = Math.floor((seconds % 3600) / 60);
		const s = seconds % 60;
		if (h) return h + ' 小时 ' + m + ' 分';
		if (m) return m + ' 分 ' + s + ' 秒';
		return s + ' 秒';
	}

	function fmtNumber(value, digits) {
		const number = Number(value);
		return Number.isFinite(number) ? number.toFixed(digits == null ? 2 : digits) : '—';
	}

	function escHtml(value) {
		return String(value == null ? '' : value).replace(/[&<>"']/g, (ch) => ({
			'&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
		}[ch]));
	}

	function shortDate(ts) {
		return ts ? String(ts).slice(5, 19) : '';
	}

	function shortClock(ts) {
		return ts ? String(ts).slice(11, 19) : '';
	}

	function dlStatusPill(status) {
		if (status === 'best') return '<span class="pill ok">最优</span>';
		if (status === 'ok') return '<span class="pill soft">保留</span>';
		if (status === 'slow') return '<span class="pill warn">偏慢</span>';
		return '<span class="pill none">失败</span>';
	}

	function dlAsnCell(row) {
		if (!row || !row.asn)
			return '<span class="muted">—</span>';

		return '<span class="asn">' + escHtml(row.asn) + '</span>' +
			'<span class="cell-sub">' + escHtml(row.asn_name || '') +
			(row.asn_cc ? ' · ' + escHtml(row.asn_cc) : '') + '</span>';
	}

	function phaseLabel(phase) {
		return PHASES[phase] || phase || '空闲';
	}

	function setText(id, text) {
		const node = document.getElementById(id);
		if (node) node.textContent = text;
	}

	// ── tabs ────────────────────────────────────────────────────────────
	const TABS = ['overview', 'nodes', 'iplists', 'settings', 'logs', 'core', 'thirdparty'];

	function initialTab() {
		const name = (window.location.hash || '').replace(/^#/, '');
		return TABS.indexOf(name) >= 0 ? name : 'overview';
	}

	function activateTab(name) {
		state.tab = name;
		$$('.tab').forEach((tab) => tab.classList.toggle('active', tab.dataset.tab === name));
		$$('.panel').forEach((panel) => panel.classList.toggle('active', panel.dataset.panel === name));
		if (window.location.hash !== '#' + name)
			history.replaceState(null, '', '#' + name);
		if (name === 'logs') {
			if (state.logSubtab === 'tasklog') refreshTaskLog();
			else reloadLog(true);
		} else if (name === 'core') {
			refreshCore();
			refreshAppInfo();
		} else if (name === 'nodes') {
			refreshNodeInfo();
		} else if (name === 'settings' || name === 'overview') {
			refreshCronTasks();
			if (name === 'overview')
				refreshNodeInfo();
		}
	}

	// ── status ───────────────────────────────────────────────────────────
	function ddnsInfo() {
		const g = (state.config && state.config.global) || {};
		const workers = (state.config && state.config.workers) || [];
		const configured = workers.filter((item) =>
			String(item.ddns_domain || '').trim() !== '').length;
		return {
			enabled: g.ddns_enabled === '1',
			configured: configured > 0,
			at: '',
			ok: null,
			error: '',
		};
	}

	function renderStatus(status) {
		state.status = status;
		const running = !!status.running;
		const last = status.last || {};
		const dot = $('#status-dot');
		dot.classList.toggle('running', running);
		dot.classList.toggle('idle', !running && status.phase !== 'failed');
		dot.classList.toggle('error', !running && status.phase === 'failed');

		const text = running
			? phaseLabel(status.phase) + ' · 已运行 ' + fmtDuration(status.elapsed)
			: '空闲 · ' + (last.last_time || '尚未测速');
		setText('status-text', text);

		setText('st-state', running ? phaseLabel(status.phase) : '空闲');
		setText('st-elapsed', running
			? '已运行 ' + fmtDuration(status.elapsed) + (status.stop_requested ? ' · 正在停止' : '')
			: (last.last_time ? '上次 ' + last.last_time : '—'));
		setText('st-cron', status.cron ? '已启用' : '未启用');
		setText('st-last', last.last_time ? '上次 ' + last.last_time : '—');
		setText('st-workers', (status.node_count || 0) + ' / ' +
			(status.result_rows || 0) + ' 条');

		// 已请求停止时按钮也要失效并显示「停止中…」，避免重复点。
		const stopping = running && !!status.stop_requested;
		['#btn-stop', '#ov-btn-stop'].forEach((id) => {
			const button = $(id);
			if (!button) return;
			button.disabled = !running || stopping;
			button.textContent = stopping ? '停止中…' : '停止';
		});
		['#btn-start', '#ov-btn-start', '#btn-retest', '#ov-btn-retest'].forEach((id) => {
			const button = $(id);
			if (button) button.disabled = running;
		});
		['#btn-start', '#btn-retest'].forEach((id) => {
			const button = $(id);
			if (button) button.title = running ? '已有测速在运行，请先停止' : '';
		});

		syncNodeActions();
	}

	function ddnsText(info) {
		if (!info || !info.enabled) return '未启用';
		if (!info.configured) return '已启用，但没有节点填写 DDNS 域名';
		if (info.error) return info.error;
		if (!info.at) return '等待下次测速写入';
		return (info.ok === false ? '上次写入失败 · ' : '') + info.at +
			' · ' + (info.updated || 0) + ' 条更新 / ' + (info.unchanged || 0) + ' 条无变化' +
			(info.failed ? ' / ' + info.failed + ' 个节点失败' : '');
	}

	function renderDdnsStatus(info) {
		const enabled = !!(info && info.enabled);
		setText('ddns-status', enabled
			? ('DDNS：' + ddnsText(info))
			: 'DDNS 未启用；启用后，只有填写了 DDNS 域名的节点会写 DNS。');
	}

	async function pollStatus() {
		try {
			const status = await api('/api/status');
			const wasRunning = state.lastRunning;
			state.lastRunning = !!status.running;
			renderStatus(status);
			if (wasRunning && !status.running) {
				await refreshResults();
				refreshCronTasks().catch(() => {});
				refreshTaskLog().catch(() => {});
				toast('测速已结束，结果已刷新');
			}
		} catch (e) {
			/* auth overlay is already shown on 401 */
		}
	}

	function tickElapsed() {
		const status = state.status;
		if (!status || !status.running || !status.started_at)
			return;
		const elapsed = Math.floor(Date.now() / 1000) - status.started_at;
		setText('st-elapsed', '已运行 ' + fmtDuration(elapsed) +
			(status.stop_requested ? ' · 正在停止' : ''));
	}

	// ── best / result table / history ───────────────────────────────────
	function bestRows() {
		return ((state.best && state.best.payload && state.best.payload.rows) || []);
	}

	function renderBest() {
		const payload = (state.best && state.best.payload) || {};
		const top = payload.best;
		setText('st-best', top && top.ip ? top.ip : '—');
		setText('st-best-meta', top
			? (fmtNumber(top.latency) + ' ms · ' +
			   (top.speed > 0 ? fmtNumber(top.speed) + ' MB/s' : '未做下载实测') +
			   (top.node ? ' · ' + top.node : ''))
			: '—');
		renderOverview();
	}

	function overviewNodes() {
		const list = [];
		const map = {};

		function add(key, name, best) {
			if (!key) return null;
			if (!map[key]) {
				map[key] = { key, name: name || key, best: best || null, count: 0 };
				list.push(map[key]);
			}
			else if (best && !map[key].best) {
				map[key].best = best;
			}
			if (name && (!map[key].name || map[key].name === key))
				map[key].name = name;
			return map[key];
		}

		configuredWorkers().forEach((worker) => add(worker.node, nodeRemark(worker.node), null));
		bestRows().forEach((row) => {
			add(row.node_id || row.node, String(row.node || '').trim() || row.node_id, row);
		});
		(state.downloads || []).forEach((row) => {
			add(row.node_id || row.node, String(row.node || '').trim(), null);
		});

		// 下拉里的次数 = 该节点成功产生下载明细的任务轮数。
		const groups = {};
		(state.downloads || []).forEach((row) => {
			const key = row.node_id || row.node;
			if (!key || row.status === 'fail') return;
			if (!groups[key]) groups[key] = {};
			groups[key][(row.run_ts || '') + '|' + (row.done_ts || '')] = true;
		});
		list.forEach((node) => {
			node.count = Object.keys(groups[node.key] || {}).length;
		});

		return list;
	}

	function renderNodeDropdown(prefix, nodes, selectedKey, onSelect) {
		const wrap = $('#' + prefix + '-node-select');
		const button = $('#' + prefix + '-node-select-btn');
		const menu = $('#' + prefix + '-node-select-menu');
		if (!wrap || !button || !menu) return;

		const open = state.openDropdown === prefix;

		if (!nodes.length) {
			button.className = 'node-select-btn';
			button.title = '';
			button.setAttribute('aria-expanded', 'false');
			button.innerHTML = '<span class="state empty" aria-hidden="true"></span>' +
				'<span class="name">暂无节点</span><span class="count">0</span>' +
				'<span class="chevron" aria-hidden="true"></span>';
			menu.replaceChildren();
			wrap.classList.remove('open');
			return;
		}

		const current = nodes.find((node) => node.key === selectedKey) || nodes[0];
		button.className = 'node-select-btn' + (open ? ' open' : '');
		button.title = current.name;
		button.setAttribute('aria-expanded', open ? 'true' : 'false');
		button.innerHTML =
			'<span class="state' + (current.empty ? ' empty' : '') + '" aria-hidden="true"></span>' +
			'<span class="name">' + escHtml(current.name) + '</span>' +
			'<span class="count">' + (current.count || 0) + '</span>' +
			'<span class="chevron" aria-hidden="true"></span>';

		menu.replaceChildren();
		nodes.forEach((node) => {
			const item = document.createElement('button');
			item.type = 'button';
			item.className = 'node-select-item' + (node.key === current.key ? ' active' : '');
			item.setAttribute('role', 'option');
			item.setAttribute('aria-selected', node.key === current.key ? 'true' : 'false');
			item.dataset.key = node.key;
			item.title = node.name;
			item.innerHTML =
				'<span class="state' + (node.empty ? ' empty' : '') + '" aria-hidden="true"></span>' +
				'<span class="name">' + escHtml(node.name) + '</span>' +
				'<span class="count">' + (node.count || 0) + '</span>' +
				'<span class="check">' + (node.key === current.key ? '✓' : '') + '</span>';
			item.addEventListener('click', (event) => {
				event.stopPropagation();
				state.openDropdown = '';
				onSelect(node.key);
			});
			menu.appendChild(item);
		});

		wrap.classList.toggle('open', open);
		if (open) {
			const active = menu.querySelector('.node-select-item.active');
			if (active) {
				menu.scrollTop = Math.max(0, active.offsetTop -
					menu.clientHeight / 2 + active.offsetHeight / 2);
			}
		}

		button.onclick = (event) => {
			event.stopPropagation();
			const previous = state.openDropdown;
			state.openDropdown = open ? '' : prefix;
			if (previous && previous !== prefix) {
				if (previous === 'ov') renderOverview();
				else if (previous === 'hist') renderHistory();
			}
			renderNodeDropdown(prefix, nodes, selectedKey, onSelect);
		};
		menu.onclick = (event) => {
			event.stopPropagation();
		};
	}

	function renderOverview() {
		const nodes = overviewNodes();

		if (!state.ovSelectedNode || !nodes.some((node) => node.key === state.ovSelectedNode)) {
			const first = nodes.find((node) => node.best) || nodes[0];
			state.ovSelectedNode = first ? first.key : '';
		}

		renderNodeDropdown('ov', nodes.map((node) => ({
			key: node.key,
			name: node.name,
			count: node.count || 0,
			empty: !node.best,
		})), state.ovSelectedNode, (key) => {
			state.ovSelectedNode = key;
			renderOverview();
		});

		renderOverviewDetail(nodes);
	}

	function renderOverviewDetail(nodes) {
		const latest = $('#ov-node-latest');
		const host = $('#ov-node-tasks');
		if (!latest || !host) return;

		const node = nodes.find((item) => item.key === state.ovSelectedNode) || nodes[0];
		if (!node) {
			latest.className = 'node-latest muted';
			latest.textContent = '暂无节点';
			host.innerHTML = '<div class="empty-state">暂无数据</div>';
			return;
		}

		const best = node.best || bestRows().find((row) => (row.node_id || row.node) === node.key);
		const rows = (state.downloads || []).filter((row) => (row.node_id || row.node) === node.key);
		const groupsMap = {};

		rows.forEach((row) => {
			const key = (row.run_ts || '') + '|' + (row.done_ts || '');
			if (!groupsMap[key])
				groupsMap[key] = { run_ts: row.run_ts, done_ts: row.done_ts, rows: [] };
			groupsMap[key].rows.push(row);
		});

		const groups = Object.keys(groupsMap).map((key) => {
			const group = groupsMap[key];
			const okRows = group.rows.filter((row) => row.status !== 'fail');
			const bestRow = group.rows.find((row) => row.status === 'best') ||
				group.rows.slice().sort((a, b) => (b.speed || 0) - (a.speed || 0))[0];
			return { run_ts: group.run_ts, done_ts: group.done_ts, rows: group.rows, okRows, bestRow };
		}).filter((group) => group.okRows.length > 0);

		groups.sort((a, b) => (a.done_ts || a.run_ts) < (b.done_ts || b.run_ts) ? 1 : -1);

		if (best) {
			const asnRow = rows.find((row) => row.ip === best.ip);
			const asn = best.asn || (asnRow && asnRow.asn) || '';
			const asnName = best.asn_name || (asnRow && asnRow.asn_name) || '';
			const asnCc = best.asn_cc || (asnRow && asnRow.asn_cc) || '';
			const done = groups.length ? groups[0].done_ts :
				((state.best && state.best.payload && state.best.payload.generated_at) || '');

			latest.className = 'node-latest';
			latest.innerHTML =
				'<span class="label">最新</span>' +
				'<span class="ip">' + escHtml(best.ip) + '</span>' +
				'<span class="metric">' +
					(best.speed > 0 ? fmtNumber(best.speed) + ' MB/s' : '未做下载实测') +
					' · ' + fmtNumber(best.latency) + ' ms</span>' +
				(asn ? '<span class="asnline"><span class="asn-chip">' + escHtml(asn) + '</span>' +
					'<span class="name">' + escHtml(asnName) +
					(asnCc ? ' · ' + escHtml(asnCc) : '') + '</span></span>' : '') +
				(done ? '<span class="time">完成 ' + escHtml(shortClock(done)) + '</span>' : '');
		}
		else {
			latest.className = 'node-latest muted';
			latest.innerHTML = '<span class="label">最新</span><span class="ip">暂无有效结果</span>' +
				'<span class="muted">最近的任务没有产生可用 IP</span>';
		}

		if (!groups.length) {
			host.innerHTML = '<div class="empty-state"><strong>暂无下载明细</strong>新的任务会记录每一轮下载结果。</div>';
			return;
		}

		host.innerHTML = groups.map((group) => {
			const sorted = group.rows.slice().sort((a, b) => (b.speed || 0) - (a.speed || 0));
			const body = sorted.map((row, index) => {
				const winner = row.status === 'best' ? ' class="winner"' : '';
				return '<tr' + winner + '>' +
					'<td class="mono">' + (index + 1) + '</td>' +
					'<td class="ip">' + escHtml(row.ip) + '</td>' +
					'<td class="mono">' + (row.latency > 0 ? fmtNumber(row.latency) + ' ms' : '—') + '</td>' +
					'<td class="mono">' + (row.speed > 0 ? fmtNumber(row.speed) + ' MB/s' : '—') + '</td>' +
					'<td>' + dlAsnCell(row) + '</td>' +
					'<td>' + dlStatusPill(row.status) + '</td>' +
				'</tr>';
			}).join('');
			const bestRow = group.bestRow || {};

			return '<details class="task">' +
				'<summary>' +
					'<span class="task-time">' + escHtml(shortDate(group.run_ts)) + '</span>' +
					'<span class="pill ok">成功</span>' +
					'<span class="task-meta">完成 ' + escHtml(shortClock(group.done_ts)) +
						' · 下载 ' + group.okRows.length + '/' + group.rows.length + '</span>' +
					'<span class="task-best"><span class="mono">' + escHtml(bestRow.ip || '') + '</span>' +
						(bestRow.speed > 0 ? ' · ' + fmtNumber(bestRow.speed) + ' MB/s' : '') + '</span>' +
					'<span class="chevron" aria-hidden="true"></span>' +
				'</summary>' +
				'<div class="task-body"><div class="table-wrap"><table class="data">' +
					'<thead><tr><th>#</th><th>IP</th><th>延迟</th><th>下载</th><th>ASN / 机房</th><th>结果</th></tr></thead>' +
					'<tbody>' + body + '</tbody>' +
				'</table></div></div>' +
			'</details>';
		}).join('');
	}

	async function refreshResults() {
		try {
			const results = await Promise.all([
				api('/api/best'),
				api('/api/history'),
				api('/api/downloads').catch(() => null),
			]);
			state.best = results[0];
			state.history = (results[1] && results[1].history) || [];
			state.downloads = (results[2] && results[2].rows) || [];
			renderBest();
			renderHistory();
		} catch (e) {
			/* handled by api() */
		}
	}

	// ── 概览历史：节点 tab + 折线图 + 机房分布 ─────────────────────────
	function historyNodes() {
		const list = [];
		const map = {};

		function add(key, name) {
			if (!key) return null;
			if (!map[key]) {
				map[key] = { key: key, name: name || key, runs: [] };
				list.push(map[key]);
			}
			if (name && (!map[key].name || map[key].name === key))
				map[key].name = name;
			return map[key];
		}

		const remarkKey = {};
		configuredWorkers().forEach((worker) => {
			const remark = nodeRemark(worker.node);
			remarkKey[remark] = worker.node;
			add(worker.node, remark);
		});
		(state.history || []).forEach((run) => {
			(run.nodes || []).forEach((entry) => {
				const entryName = String(entry.node || '').trim();
				// 老历史文件没有 node_id，按备注名对回已配置的 worker。
				const key = entry.node_id ||
					remarkKey[entryName] || entryName;
				const node = add(key, entryName || key);
				if (!node) return;
				node.runs.push({
					time: run.time || '',
					ip: entry.ip || '',
					latency: +entry.latency || 0,
					speed: +entry.speed || 0,
					asn: entry.asn || '',
					asnName: entry.asn_name || '',
					cc: entry.asn_cc || '',
					region: entry.region || '',
				});
			});
		});

		// runs 保留全部历史：折线图与机房表都基于完整历史。
		list.forEach((node) => {
			node.runs.sort((a, b) => a.time > b.time ? 1 : (a.time < b.time ? -1 : 0));
		});

		return list;
	}

	function renderHistory() {
		const nodes = historyNodes();

		if (!state.histSelectedNode || !nodes.some((node) => node.key === state.histSelectedNode)) {
			const first = nodes.find((node) => node.runs.length) || nodes[0];
			state.histSelectedNode = first ? first.key : '';
		}

		renderNodeDropdown('hist', nodes.map((node) => ({
			key: node.key,
			name: node.name,
			count: node.runs.length,
			empty: !node.runs.length,
		})), state.histSelectedNode, (key) => {
			state.histSelectedNode = key;
			renderHistory();
		});

		renderHistoryDetail(nodes.find((node) => node.key === state.histSelectedNode) || nodes[0]);
	}

	function renderHistoryDetail(node) {
		const latest = $('#hist-node-latest');
		const block = $('#hist-chart-block');
		const empty = $('#hist-chart-empty');
		const head = $('#hist-dc-head');
		const wrap = $('#hist-dc-wrap');
		const tip = $('#hist-chart-tip');
		if (!latest || !block || !empty || !head || !wrap) return;

		state.histPoints = [];
		if (tip) tip.classList.add('hidden');

		if (!node) {
			latest.className = 'node-latest muted';
			latest.textContent = '暂无节点';
			block.classList.add('hidden');
			empty.classList.remove('hidden');
			head.classList.add('hidden');
			wrap.classList.add('hidden');
			const body = $('#hist-dc-body');
			if (body) body.replaceChildren();
			return;
		}

		const runs = node.runs || [];
		const last = runs[runs.length - 1];

		if (last) {
			latest.className = 'node-latest';
			latest.innerHTML =
				'<span class="label">最新</span>' +
				'<span class="ip">' + escHtml(last.ip) + '</span>' +
				'<span class="metric">' +
					(last.speed > 0 ? fmtNumber(last.speed) + ' MB/s' : '未做下载实测') +
					' · ' + fmtNumber(last.latency) + ' ms</span>' +
				(last.asn ? '<span class="asnline"><span class="asn-chip">' + escHtml(last.asn) + '</span>' +
					'<span class="name">' + escHtml(last.asnName) +
					(last.cc ? ' · ' + escHtml(last.cc) : '') + '</span></span>' : '') +
				'<span class="time">' + escHtml((last.time || '').slice(5, 16)) +
					' · 共 ' + runs.length + ' 次记录</span>';
		}
		else {
			latest.className = 'node-latest muted';
			latest.innerHTML = '<span class="label">历史</span><span class="ip">暂无有效记录</span>' +
				'<span class="muted">该节点还没有产生过历史最优 IP</span>';
		}

		if (!runs.length) {
			block.classList.add('hidden');
			empty.classList.remove('hidden');
			head.classList.add('hidden');
			wrap.classList.add('hidden');
			const body = $('#hist-dc-body');
			if (body) body.replaceChildren();
			return;
		}

		block.classList.remove('hidden');
		empty.classList.add('hidden');
		head.classList.remove('hidden');
		wrap.classList.remove('hidden');

		renderHistoryChart(runs);
		renderHistoryDatacenters(runs);
	}

	function niceMax(value) {
		if (!(value > 0)) return 1;
		const exp = Math.pow(10, Math.floor(Math.log(value) / Math.LN10));
		const base = value / exp;
		const step = base <= 1 ? 1 : base <= 2 ? 2 : base <= 2.5 ? 2.5 : base <= 5 ? 5 : 10;
		return step * exp;
	}

	function renderHistoryChart(runs) {
		const svg = $('#hist-chart');
		if (!svg) return;
		const W = 960;
		const H = 250;
		const padL = 50;
		const padR = 18;
		const padT = 22;
		const padB = 34;
		const metric = state.histMetric === 'latency' ? 'latency' : 'speed';
		const unit = metric === 'speed' ? 'MB/s' : 'ms';
		const values = runs.map((run) => metric === 'speed' ? run.speed : run.latency);
		const yMax = niceMax(Math.max.apply(null, values) * 1.12);
		const innerW = W - padL - padR;
		const innerH = H - padT - padB;
		const stepX = runs.length > 1 ? innerW / (runs.length - 1) : 0;
		const points = runs.map((run, index) => {
			const value = metric === 'speed' ? run.speed : run.latency;
			return {
				index: index,
				x: padL + (runs.length > 1 ? stepX * index : innerW / 2),
				y: padT + innerH - (value / yMax) * innerH,
				value: value,
				run: run,
			};
		});
		const parts = [];

		parts.push('<defs><linearGradient id="hist-area" x1="0" y1="0" x2="0" y2="1">' +
			'<stop offset="0%" stop-color="var(--accent)" stop-opacity="0.20"/>' +
			'<stop offset="100%" stop-color="var(--accent)" stop-opacity="0.015"/>' +
			'</linearGradient></defs>');

		for (let tick = 0; tick <= 4; tick++) {
			const value = yMax / 4 * tick;
			const y = padT + innerH - (value / yMax) * innerH;
			parts.push('<line class="grid-line" x1="' + padL + '" y1="' + y.toFixed(1) +
				'" x2="' + (W - padR) + '" y2="' + y.toFixed(1) + '"/>');
			parts.push('<text class="axis-text" x="' + (padL - 8) + '" y="' + (y + 3.5).toFixed(1) +
				'" text-anchor="end">' + (Number.isInteger(value) ? value : value.toFixed(1)) + '</text>');
		}
		parts.push('<text class="axis-text unit" x="' + (padL - 8) + '" y="' + (padT - 8) +
			'" text-anchor="end">' + unit + '</text>');

		const average = values.reduce((sum, value) => sum + value, 0) / values.length;
		const averageY = padT + innerH - (average / yMax) * innerH;
		parts.push('<line class="avg-line" x1="' + padL + '" y1="' + averageY.toFixed(1) +
			'" x2="' + (W - padR) + '" y2="' + averageY.toFixed(1) + '"/>');
		parts.push('<text class="avg-text" x="' + (padL + 8) + '" y="' + (averageY - 6).toFixed(1) +
			'" text-anchor="start">均值 ' +
			(metric === 'speed' ? fmtNumber(average) + ' MB/s' : fmtNumber(average, 0) + ' ms') + '</text>');

		const line = points.map((point, index) =>
			(index ? 'L' : 'M') + point.x.toFixed(1) + ' ' + point.y.toFixed(1)).join(' ');
		parts.push('<path d="' + line + ' L' + points[points.length - 1].x.toFixed(1) + ' ' + (padT + innerH) +
			' L' + points[0].x.toFixed(1) + ' ' + (padT + innerH) + ' Z" fill="url(#hist-area)"/>');
		parts.push('<path class="series-line" d="' + line + '"/>');

		// 只画线，不画点；透明命中区用于悬停提示
		points.forEach((point) => {
			parts.push('<circle class="pt-hit" data-i="' + point.index + '" cx="' + point.x.toFixed(1) +
				'" cy="' + point.y.toFixed(1) + '" r="13"/>');
		});

		const maxLabels = 6;
		const labelStep = Math.max(1, Math.ceil(runs.length / maxLabels));
		points.forEach((point) => {
			const show = runs.length <= 4 || point.index === 0 ||
				point.index === points.length - 1 || point.index % labelStep === 0;
			if (!show) return;
			const anchor = point.index === 0 ? 'start' :
				(point.index === points.length - 1 ? 'end' : 'middle');
			parts.push('<text class="axis-text" x="' + point.x.toFixed(1) + '" y="' + (H - 10) +
				'" text-anchor="' + anchor + '">' + escHtml((point.run.time || '').slice(5, 16)) + '</text>');
		});

		svg.innerHTML = parts.join('');
		state.histPoints = points;
	}

	function placeHistTip(tip, x, y) {
		const W = 960;
		const H = 250;
		const sideLeft = x > W * 0.78;
		const sideRight = x < W * 0.06;
		tip.classList.toggle('side-left', sideLeft);
		tip.classList.toggle('side-right', sideRight);
		tip.classList.toggle('to-right', !sideLeft && !sideRight && x > W * 0.68);
		tip.classList.toggle('to-left', !sideLeft && !sideRight && x < W * 0.18);
		tip.classList.toggle('below', !sideLeft && !sideRight && y < H * 0.60);
		tip.style.left = (x / W * 100) + '%';
		tip.style.top = (y / H * 100) + '%';
	}

	function showHistTip(point) {
		const tip = $('#hist-chart-tip');
		if (!tip || !point) return;
		const run = point.run;
		tip.classList.remove('hidden');
		tip.innerHTML =
			'<div class="tip-time">' + escHtml(run.time) + '</div>' +
			'<div class="tip-ip">' + escHtml(run.ip) + '</div>' +
			(run.asn ? '<div class="tip-asn">' + escHtml(run.asn) + ' · ' + escHtml(run.asnName) +
				(run.cc ? ' · ' + escHtml(run.cc) : '') + '</div>' : '') +
			'<div class="tip-metrics"><span>下载 <b>' + fmtNumber(run.speed) + ' MB/s</b></span>' +
				'<span>延迟 <b>' + fmtNumber(run.latency) + ' ms</b></span></div>';
		placeHistTip(tip, point.x, point.y);
	}

	function aggregate(values) {
		let min = Infinity;
		let max = -Infinity;
		let sum = 0;
		values.forEach((value) => {
			if (value < min) min = value;
			if (value > max) max = value;
			sum += value;
		});
		return { min: min, avg: values.length ? sum / values.length : 0, max: max };
	}

	function statValue(stat, key) {
		return stat ? fmtNumber(stat[key]) : '—';
	}

	// 节点每次任务的最优 IP 按机房归并：出现一次 +1，速度/延迟累积统计
	function renderHistoryDatacenters(runs) {
		const body = $('#hist-dc-body');
		if (!body) return;
		const map = {};
		const list = [];

		runs.forEach((run) => {
			const key = run.asn || ('ip:' + run.ip);
			if (!map[key]) {
				map[key] = { asn: run.asn || '未知机房', name: run.asnName, cc: run.cc,
					count: 0, speeds: [], lats: [] };
				list.push(map[key]);
			}
			const item = map[key];
			item.count += 1;
			// 0 表示这次没有下载实测/没有延迟数据，不参与最快最慢平均。
			if (run.speed > 0) item.speeds.push(run.speed);
			if (run.latency > 0) item.lats.push(run.latency);
		});

		list.forEach((item) => {
			item.speed = item.speeds.length ? aggregate(item.speeds) : null;
			item.latency = item.lats.length ? aggregate(item.lats) : null;
		});
		list.sort((a, b) => {
			const countDiff = b.count - a.count;
			if (countDiff) return countDiff;
			const avgA = a.speed ? a.speed.avg : -1;
			const avgB = b.speed ? b.speed.avg : -1;
			return avgB - avgA;
		});

		const total = runs.length || 1;
		body.innerHTML = list.map((item, index) => {
			const share = Math.round(item.count / total * 100);
			return '<tr' + (index === 0 ? ' class="lead"' : '') + '>' +
				'<td><span class="asn">' + escHtml(item.asn) + '</span>' +
					'<span class="cell-sub">' + escHtml(item.name) +
					(item.cc ? ' · ' + escHtml(item.cc) : '') + '</span></td>' +
				'<td class="count-cell"><span class="num">' + item.count + ' 次</span>' +
					'<span class="count-bar"><i style="width:' + share + '%"></i></span></td>' +
				'<td class="num">' + statValue(item.speed, 'max') + '</td>' +
				'<td class="num strong">' + statValue(item.speed, 'avg') + '</td>' +
				'<td class="num">' + statValue(item.speed, 'min') + '</td>' +
				'<td class="num">' + statValue(item.latency, 'min') + '</td>' +
				'<td class="num strong">' + statValue(item.latency, 'avg') + '</td>' +
				'<td class="num">' + statValue(item.latency, 'max') + '</td>' +
			'</tr>';
		}).join('');
	}

	function bindHistoryEvents() {
		const seg = $('#hist-metric');
		if (seg && !seg.dataset.bound) {
			seg.dataset.bound = '1';
			seg.addEventListener('click', (event) => {
				const button = event.target.closest('button[data-metric]');
				if (!button) return;
				state.histMetric = button.dataset.metric === 'latency' ? 'latency' : 'speed';
				$$('#hist-metric button').forEach((btn) => {
					const active = btn.dataset.metric === state.histMetric;
					btn.classList.toggle('active', active);
					btn.setAttribute('aria-pressed', active ? 'true' : 'false');
				});
				const title = $('#hist-chart-title');
				if (title)
					title.innerHTML = (state.histMetric === 'speed' ? '下载速度趋势' : '延迟趋势') +
						'<span class="muted">每次任务的最优 IP</span>';
				renderHistory();
			});
		}

		const wrap = $('#hist-chart-wrap');
		if (wrap && !wrap.dataset.bound) {
			wrap.dataset.bound = '1';
			wrap.addEventListener('mousemove', (event) => {
				const points = state.histPoints || [];
				if (!points.length) return;
				const rect = wrap.getBoundingClientRect();
				if (!rect.width) return;
				const ratio = (event.clientX - rect.left) / rect.width;
				let best = 0;
				let distance = Infinity;
				points.forEach((point, index) => {
					const current = Math.abs(point.x / 960 - ratio);
					if (current < distance) {
						distance = current;
						best = index;
					}
				});
				showHistTip(points[best]);
			});
			wrap.addEventListener('mouseleave', () => {
				const tip = $('#hist-chart-tip');
				if (tip) tip.classList.add('hidden');
			});
		}

		if (!state.dropdownOutsideBound) {
			state.dropdownOutsideBound = true;
			document.addEventListener('click', () => {
				const which = state.openDropdown;
				if (!which) return;
				state.openDropdown = '';
				if (which === 'ov') renderOverview();
				else if (which === 'hist') renderHistory();
			});
		}
	}

	// ── downloads ───────────────────────────────────────────────────────
	function downloadFile(name, text, type) {
		const blob = new Blob([text], { type: type || 'text/plain;charset=utf-8' });
		const url = URL.createObjectURL(blob);
		const link = document.createElement('a');
		link.href = url;
		link.download = name;
		document.body.appendChild(link);
		link.click();
		document.body.removeChild(link);
		setTimeout(() => URL.revokeObjectURL(url), 1000);
	}

	// ── nodes（PassWall worker） ────────────────────────────────────────
	function providerNodes(name) {
		const provider = (state.providers && state.providers[name]) || {};
		return provider.nodes || [];
	}

	function providerExists(name) {
		const provider = (state.providers && state.providers[name]) || {};
		return !!provider.exists;
	}

	function passwallNode(id) {
		const nodes = providerNodes('passwall');
		for (let i = 0; i < nodes.length; i++)
			if (nodes[i].value === id)
				return nodes[i];
		return null;
	}

	function nodeLabel(id) {
		const worker = (state.config && state.config.workers || []).find((item) => item.node === id);
		const node = passwallNode(id);
		let label = node ? (node.label || id) : id;
		if (worker && worker.ip_list) label += ' · ' + worker.ip_list;
		if (worker && worker.ddns_domain) label += ' · DDNS';
		if (node && String(node.type || '').toLowerCase() === 'socks')
			label += '（socks，不能测速）';
		return label;
	}

	// 定时任务只显示 PassWall 备注名（去掉 list_nodes 的 "[VMESS]:" 前缀）。
	function nodeRemark(id) {
		const node = passwallNode(id);
		const label = node ? (node.label || id) : id;
		const remark = label.replace(/^\[[^\]]*\]:/, '').trim();
		return remark || id;
	}

	function configuredWorkers() {
		const list = [];
		const seen = {};
		((state.config && state.config.workers) || []).forEach((worker) => {
			const id = String(worker.node || '').trim();
			if (!id || seen[id]) return;
			seen[id] = true;
			list.push({
				node: id,
				ip_list: worker.ip_list || '',
				ddns_domain: worker.ddns_domain || '',
			});
		});
		return list;
	}

	function ipListSelect(selected) {
		const select = document.createElement('select');
		const fallback = document.createElement('option');
		fallback.value = '';
		fallback.textContent = '默认（第一个启用）';
		select.appendChild(fallback);
		const lists = (state.config && state.config.ip_lists) || [];
		lists.forEach((list, index) => {
			const option = document.createElement('option');
			option.value = 'list' + (index + 1);
			option.textContent = 'list' + (index + 1) +
				(list.name ? ' · ' + list.name : '') +
				(list.enabled ? '' : '（未启用）');
			select.appendChild(option);
		});
		if (selected && !/^list[1-5]$/.test(selected)) {
			const option = document.createElement('option');
			option.value = selected;
			option.textContent = selected;
			select.appendChild(option);
		}
		select.value = selected || '';
		return select;
	}

	function renderNodes() {
		const body = $('#cfg-workers-body');
		if (!body) return;
		body.replaceChildren();

		const workers = state.config
			? (state.config.workers || (state.config.workers = []))
			: [];
		$('#workers-empty').classList.toggle('hidden', workers.length > 0);

		if (!workers.length) {
			const tr = document.createElement('tr');
			const td = document.createElement('td');
			td.colSpan = 4;
			td.className = 'empty';
			td.textContent = '暂无 worker；测速将使用上面的「单节点测速」';
			tr.appendChild(td);
			body.appendChild(tr);
			syncNodeActions();
			return;
		}

		const nodes = providerNodes('passwall');

		workers.forEach((worker, index) => {
			const tr = document.createElement('tr');
			tr.dataset.node = worker.node;

			const nodeCell = document.createElement('td');
			const nodeSelect = document.createElement('select');
			const emptyOption = document.createElement('option');
			emptyOption.value = '';
			emptyOption.textContent = '-- 请选择 --';
			nodeSelect.appendChild(emptyOption);
			const seen = {};
			nodes.forEach((node) => {
				if (!node.value || seen[node.value]) return;
				seen[node.value] = true;
				const option = document.createElement('option');
				option.value = node.value;
				option.textContent = node.label +
					(String(node.type || '').toLowerCase() === 'socks' ? '（socks）' : '');
				nodeSelect.appendChild(option);
			});
			if (worker.node && !seen[worker.node]) {
				const option = document.createElement('option');
				option.value = worker.node;
				option.textContent = worker.node;
				nodeSelect.appendChild(option);
			}
			nodeSelect.value = worker.node;
			nodeSelect.addEventListener('change', () => {
				worker.node = nodeSelect.value;
				tr.dataset.node = worker.node;
				syncNodeActions();
			});
			nodeCell.appendChild(nodeSelect);
			// 成功后监测的实时延迟；由 syncNodeActions() 按 /api/status 的 monitor 更新。
			const monitorBadge = document.createElement('span');
			monitorBadge.className = 'badge monitor hidden';
			monitorBadge.dataset.nodeMonitor = '';
			nodeCell.appendChild(monitorBadge);
			tr.appendChild(nodeCell);

			const listCell = document.createElement('td');
			const listSelect = ipListSelect(worker.ip_list);
			listSelect.addEventListener('change', () => { worker.ip_list = listSelect.value; });
			listCell.appendChild(listSelect);
			tr.appendChild(listCell);

			const ddnsCell = document.createElement('td');
			const ddnsInput = document.createElement('input');
			ddnsInput.type = 'text';
			ddnsInput.className = 'ddns-input';
			ddnsInput.value = worker.ddns_domain || '';
			ddnsInput.placeholder = '留空 = 写回 PassWall';
			ddnsInput.spellcheck = false;
			ddnsInput.addEventListener('input', () => {
				worker.ddns_domain = ddnsInput.value.trim();
			});
			ddnsCell.appendChild(ddnsInput);
			tr.appendChild(ddnsCell);

			const actionCell = document.createElement('td');
			const actions = document.createElement('div');
			actions.className = 'row-actions';
			[['测速', 'start', 'primary'], ['复测', 'retest', ''], ['停止', 'stop', 'danger']]
				.forEach(([label, action, cls]) => {
					const button = document.createElement('button');
					button.type = 'button';
					button.className = 'btn small' + (cls ? ' ' + cls : '');
					button.dataset.nodeAction = action;
					button.textContent = label;
					button.addEventListener('click', () => {
						if (action === 'stop')
							stopNode(worker.node);
						else
							startNode(worker.node, action);
					});
					actions.appendChild(button);
				});
			const remove = document.createElement('button');
			remove.type = 'button';
			remove.className = 'btn small danger';
			remove.textContent = '删除';
			remove.addEventListener('click', () => {
				workers.splice(index, 1);
				renderNodes();
			});
			actions.appendChild(remove);
			actionCell.appendChild(actions);
			tr.appendChild(actionCell);

			body.appendChild(tr);
		});

		syncNodeActions();
	}

	function addWorker() {
		if (!state.config.workers) state.config.workers = [];
		state.config.workers.push({ node: '', ip_list: '', ddns_domain: '' });
		renderNodes();
	}

	function fillNodeSelects(testValue) {
		const nodes = providerNodes('passwall');
		[['cfg-test-node', testValue]].forEach(([id, value]) => {
			const select = $('#' + id);
			if (!select) return;
			select.replaceChildren();
			const empty = document.createElement('option');
			empty.value = '';
			empty.textContent = '-- 请选择 --';
			select.appendChild(empty);

			let found = false;
			nodes.forEach((node) => {
				if (!node.value) return;
				const option = document.createElement('option');
				option.value = node.value;
				option.textContent = node.label +
					(String(node.type || '').toLowerCase() === 'socks' ? '（socks，不能测速）' : '');
				select.appendChild(option);
				if (node.value === value) found = true;
			});
			if (value && !found) {
				const option = document.createElement('option');
				option.value = value;
				option.textContent = value;
				select.appendChild(option);
			}
			select.value = value || '';
		});
	}

	async function refreshNodeInfo() {
		try {
			state.providers = await api('/api/nodes');
		} catch (e) {
			/* keep the previous provider list */
		}
		applyNodeSources();
		// PassWall 改备注名后，概览里的节点名也要跟着变。
		renderOverview();
		renderHistory();
	}

	function applyNodeSources() {
		const g = (state.config && state.config.global) || {};
		fillNodeSelects(g.node_test_node || '');
		renderNodes();
		fillThirdParty();
		if (state.tasks) renderTasks();
		const host = $('#cron-add-nodes');
		const selected = (host && typeof host._nodeValues === 'function') ? host._nodeValues() : [];
		mountNodePicker('cron-add-nodes', selected);
	}

	// ── IP lists ────────────────────────────────────────────────────────
	const COUNTRY_CODES = [
		['JP', '日本'], ['SG', '新加坡'], ['KR', '韩国'], ['HK', '香港'],
		['TW', '台湾'], ['TH', '泰国'], ['VN', '越南'], ['ID', '印尼'],
		['PH', '菲律宾'], ['MY', '马来西亚'], ['IN', '印度'], ['KH', '柬埔寨'],
		['DE', '德国'], ['NL', '荷兰'], ['FR', '法国'], ['GB', '英国'],
		['FI', '芬兰'], ['SE', '瑞典'], ['CH', '瑞士'], ['RU', '俄罗斯'],
		['TR', '土耳其'], ['UA', '乌克兰'], ['US', '美国'], ['CA', '加拿大'],
		['BR', '巴西'], ['AU', '澳大利亚'], ['AE', '阿联酋'], ['ZA', '南非'],
	];

	// 折叠多选展开时默认会撑高所在行（表格行、grid 行），长列表能把整行
	// 拉到几百像素。这里把展开的列表改成 fixed 悬浮层：脱离文档流，不改变
	// 行高；页面滚动或窗口缩放时重新贴回 summary 下方，下方空间不足则向上翻。
	function floatPickerList(details, list) {
		let onScroll = null;
		let onResize = null;

		function detach() {
			if (onScroll) window.removeEventListener('scroll', onScroll, true);
			if (onResize) window.removeEventListener('resize', onResize);
			onScroll = null;
			onResize = null;
		}

		function reset() {
			list.classList.remove('floating');
			['position', 'top', 'bottom', 'left', 'width', 'minWidth', 'maxWidth',
				'maxHeight', 'marginTop'].forEach((prop) => { list.style[prop] = ''; });
		}

		function place() {
			if (!details.isConnected) {
				detach();
				return;
			}
			// 先把列表移出文档流再测量，避免表格重排前的坐标。
			if (!list.classList.contains('floating')) {
				list.classList.add('floating');
				list.style.position = 'fixed';
				list.style.marginTop = '0';
				void list.offsetHeight;
			}
			const anchor = details.querySelector('summary') || details;
			const rect = anchor.getBoundingClientRect();
			const margin = 8;
			const gap = 6;
			const vw = document.documentElement.clientWidth;
			const vh = document.documentElement.clientHeight;
			const cssMin = details.classList.contains('country-picker') ? 240 : 170;
			const width = Math.min(Math.max(cssMin, Math.round(rect.width)), vw - margin * 2);
			const natural = Math.min(list.scrollHeight + 2, 190);
			const below = vh - rect.bottom - gap - margin;
			const above = rect.top - gap - margin;

			list.style.width = width + 'px';
			list.style.minWidth = '0';
			list.style.maxWidth = 'none';
			list.style.left = Math.max(margin,
				Math.min(rect.left, vw - margin - width)) + 'px';

			if (natural > below && above > below) {
				list.style.top = 'auto';
				list.style.bottom = Math.round(vh - rect.top + gap) + 'px';
				list.style.maxHeight = Math.max(90, Math.min(190, above)) + 'px';
			}
			else {
				list.style.bottom = 'auto';
				list.style.top = Math.round(rect.bottom + gap) + 'px';
				list.style.maxHeight = Math.max(90, Math.min(190, below)) + 'px';
			}
		}

		details.addEventListener('toggle', () => {
			if (details.open) {
				place();
				requestAnimationFrame(() => {
					if (details.open)
						place();
				});
				if (!onScroll) {
					onScroll = () => place();
					onResize = () => place();
					window.addEventListener('scroll', onScroll, true);
					window.addEventListener('resize', onResize);
				}
			}
			else {
				detach();
				reset();
			}
		});
	}

	function buildCountryPicker(selected) {
		const details = document.createElement('details');
		details.className = 'node-picker country-picker';
		const summary = document.createElement('summary');
		const list = document.createElement('div');
		list.className = 'node-picker-list';

		const known = new Set(COUNTRY_CODES.map((entry) => entry[0]));
		const chosen = [];
		const source = Array.isArray(selected) ? selected : String(selected || '').split(/[\s,]+/);
		source.forEach((code) => {
			const value = String(code || '').trim().toUpperCase();
			if (value && chosen.indexOf(value) < 0) chosen.push(value);
		});
		const options = COUNTRY_CODES.concat(
			chosen.filter((code) => !known.has(code)).map((code) => [code, '自定义']));

		options.forEach((entry) => {
			const label = document.createElement('label');
			label.className = 'check';
			const box = document.createElement('input');
			box.type = 'checkbox';
			box.value = entry[0];
			box.checked = chosen.indexOf(entry[0]) >= 0;
			const text = document.createElement('span');
			text.textContent = entry[0] + ' ' + entry[1];
			label.appendChild(box);
			label.appendChild(text);
			list.appendChild(label);
		});

		details.appendChild(summary);
		details.appendChild(list);
		floatPickerList(details, list);
		details._values = () => Array.from(
			list.querySelectorAll('input[type="checkbox"]:checked'))
			.map((box) => box.value);
		function sync() {
			const values = details._values();
			summary.textContent = values.length ? values.join(' ') : '全部';
			summary.title = values.length
				? values.join(' ')
				: '不限制国家，保留该端口下的全部 IP';
		}
		details.addEventListener('change', sync);
		sync();
		return details;
	}

	function renderIpLists() {
		const body = $('#iplists-body');
		if (!body) return;
		body.replaceChildren();
		const lists = (state.config && state.config.ip_lists) || [];
		lists.forEach((list, index) => {
			const tr = document.createElement('tr');

			const enabledCell = document.createElement('td');
			const enabled = document.createElement('input');
			enabled.type = 'checkbox';
			enabled.checked = !!list.enabled;
			enabled.addEventListener('change', () => { list.enabled = enabled.checked; });
			enabledCell.appendChild(enabled);
			tr.appendChild(enabledCell);

			const nameCell = document.createElement('td');
			const name = document.createElement('input');
			name.type = 'text';
			name.value = list.name || '';
			name.placeholder = 'list' + (index + 1);
			name.addEventListener('input', () => { list.name = name.value; });
			nameCell.appendChild(name);
			tr.appendChild(nameCell);

			const regionCell = document.createElement('td');
			const regions = buildCountryPicker(list.regions || []);
			regions.addEventListener('change', () => { list.regions = regions._values(); });
			regionCell.appendChild(regions);
			tr.appendChild(regionCell);

			const portCell = document.createElement('td');
			const port = document.createElement('input');
			port.type = 'number';
			port.min = '1';
			port.max = '65535';
			port.value = list.port || 443;
			port.addEventListener('input', () => { list.port = parseInt(port.value, 10) || 443; });
			portCell.appendChild(port);
			tr.appendChild(portCell);

			// 该列表自己的延迟上限：不同地区（港日/美欧）标准不同；0 = 跟随全局。
			const latencyCell = document.createElement('td');
			const latency = document.createElement('input');
			latency.type = 'number';
			latency.min = '0';
			latency.step = '1';
			latency.placeholder = '跟随全局';
			latency.value = parseInt(list.latency_max, 10) || 0;
			latency.addEventListener('input', () => {
				list.latency_max = Math.max(0, parseInt(latency.value, 10) || 0);
			});
			latencyCell.appendChild(latency);
			tr.appendChild(latencyCell);

			body.appendChild(tr);
		});
	}

	// ── scheduled tasks ─────────────────────────────────────────────────
	const SCHEDULE_MODES = [
		['hourly', '每小时'],
		['half-hourly', '每 30 分钟'],
		['6h', '每 6 小时'],
		['12h', '每 12 小时'],
		['daily', '每天'],
		['weekly', '每周'],
		['monthly', '每月'],
		['custom', '自定义'],
	];
	const TASK_MODES = [
		['start', '完整测速并写回（start）'],
		['retest', '复测现有最优并写回（retest）'],
		['test', '仅测速，不写回（test）'],
		['replace', '仅写回现有结果（replace）'],
	];

	function pad2(value) {
		return String(value).padStart(2, '0');
	}

	function normalizeCronText(value) {
		// Chinese IMEs in full-width mode turn "12" into "１２", which looks
		// like "1 2" and would fail cron validation.  Convert to half-width.
		return String(value || '')
			.replace(/[！-～]/g,
				(ch) => String.fromCharCode(ch.charCodeAt(0) - 0xFEE0))
			.replace(/　/g, ' ');
	}

	function cronPartsOf(expression) {
		const parts = normalizeCronText(expression).trim().split(/\s+/).filter(Boolean);
		if (parts.length && parts[0].charAt(0) === '@')
			return { alias: parts[0], parts: [parts[0], '', '', '', ''] };
		while (parts.length < 5) parts.push('*');
		return { alias: '', parts: parts.slice(0, 5) };
	}

	function cronNumber(value) {
		return /^\d+$/.test(value) ? String(parseInt(value, 10)) : null;
	}

	function detectSchedule(expression) {
		const parsed = cronPartsOf(expression);
		const parts = parsed.parts;
		if (parsed.alias) return { mode: 'custom', raw: parsed.alias };

		const minute = cronNumber(parts[0]);
		const hour = cronNumber(parts[1]);
		const day = cronNumber(parts[2]);
		const weekday = cronNumber(parts[4]);
		const dailyTail = parts[2] === '*' && parts[3] === '*' && parts[4] === '*';

		if (parts[0] === '0' && parts[1] === '*' && dailyTail) return { mode: 'hourly' };
		if (parts[0] === '*/30' && parts[1] === '*' && dailyTail) return { mode: 'half-hourly' };
		if (parts[0] === '0' && parts[1] === '*/6' && dailyTail) return { mode: '6h' };
		if (parts[0] === '0' && parts[1] === '*/12' && dailyTail) return { mode: '12h' };
		if (minute != null && hour != null && dailyTail)
			return { mode: 'daily', minute: minute, hour: hour };
		if (minute != null && hour != null && parts[2] === '*' && parts[3] === '*' && weekday != null)
			return { mode: 'weekly', minute: minute, hour: hour,
				weekday: weekday === '7' ? '0' : weekday };
		if (minute != null && hour != null && day != null && parts[3] === '*' && parts[4] === '*')
			return { mode: 'monthly', minute: minute, hour: hour, day: day };
		return { mode: 'custom', raw: parts.join(' ') };
	}

	function describeSchedule(expression) {
		const detected = detectSchedule(expression);
		const clock = (hour, minute) =>
			pad2(parseInt(hour, 10)) + ':' + pad2(parseInt(minute, 10));

		switch (detected.mode) {
		case 'hourly': return '每小时';
		case 'half-hourly': return '每 30 分钟';
		case '6h': return '每 6 小时';
		case '12h': return '每 12 小时';
		case 'daily': return '每天 ' + clock(detected.hour, detected.minute);
		case 'weekly': {
			const week = ['日', '一', '二', '三', '四', '五', '六'];
			return '每周' + (week[parseInt(detected.weekday, 10)] || detected.weekday) +
				' ' + clock(detected.hour, detected.minute);
		}
		case 'monthly':
			return '每月 ' + parseInt(detected.day, 10) + ' 日 ' +
				clock(detected.hour, detected.minute);
		default:
			return detected.raw || normalizeCronText(expression).trim() || '—';
		}
	}

	function taskLabel(command) {
		const cmd = String(command || '').trim();
		if (!cmd) return '—';
		const match = cmd.match(/\b(?:cfpick|cfpick\.sh)\s+(?:run\s+)?(start|retest|test|replace)\b/);
		if (match) {
			return {
				start: '完整测速并写回',
				retest: '复测现有最优并写回',
				test: '仅测速，不写回',
				replace: '仅写回现有结果',
			}[match[1]];
		}
		if (/\baliddns\.sh\b/.test(cmd)) return '阿里云 DDNS';
		if (/\bastra-dns\.sh\b/.test(cmd)) return 'Astra DNS';
		if (/\bcfpick\s+ddns\b/.test(cmd)) return 'DDNS 写回';
		if (/\bcfpick\s+update-core\b/.test(cmd)) return '内核更新';
		return '自定义';
	}

	function taskMode(command) {
		const match = String(command || '').trim()
			.match(/^(.*?\bcfpick(?:\.sh)?)\s+(start|retest|test|replace)\b(.*)$/);
		return match ? { prefix: match[1], mode: match[2], suffix: match[3] } : null;
	}

	function buildScheduleEditor(expression) {
		const detected = detectSchedule(expression);
		const editor = document.createElement('span');
		editor.className = 'schedule-editor';

		const mode = document.createElement('select');
		mode.className = 'sched-mode';
		SCHEDULE_MODES.forEach(([value, label]) => {
			const option = document.createElement('option');
			option.value = value;
			option.textContent = label;
			mode.appendChild(option);
		});
		mode.value = detected.mode;

		const time = document.createElement('input');
		time.type = 'time';
		time.className = 'sched-time';
		time.value = detected.hour != null
			? pad2(parseInt(detected.hour, 10)) + ':' + pad2(parseInt(detected.minute, 10))
			: '03:00';

		const weekday = document.createElement('select');
		weekday.className = 'sched-weekday';
		[['1', '周一'], ['2', '周二'], ['3', '周三'], ['4', '周四'],
			['5', '周五'], ['6', '周六'], ['0', '周日']].forEach(([value, label]) => {
			const option = document.createElement('option');
			option.value = value;
			option.textContent = label;
			weekday.appendChild(option);
		});
		weekday.value = detected.weekday || '1';

		const day = document.createElement('input');
		day.type = 'number';
		day.className = 'sched-day';
		day.min = '1';
		day.max = '31';
		day.value = detected.day || '1';

		const custom = document.createElement('input');
		custom.type = 'text';
		custom.className = 'sched-custom';
		custom.spellcheck = false;
		custom.value = detected.raw || normalizeCronText(expression).trim() || '0 3 * * *';

		editor.appendChild(mode);
		editor.appendChild(time);
		editor.appendChild(weekday);
		editor.appendChild(day);
		editor.appendChild(custom);

		function sync() {
			const value = mode.value;
			time.classList.toggle('hidden', value !== 'daily' && value !== 'weekly' && value !== 'monthly');
			weekday.classList.toggle('hidden', value !== 'weekly');
			day.classList.toggle('hidden', value !== 'monthly');
			custom.classList.toggle('hidden', value !== 'custom');
		}
		mode.addEventListener('change', sync);
		sync();

		editor._scheduleValue = function () {
			const selected = mode.value;
			if (selected === 'hourly') return '0 * * * *';
			if (selected === 'half-hourly') return '*/30 * * * *';
			if (selected === '6h') return '0 */6 * * *';
			if (selected === '12h') return '0 */12 * * *';
			if (selected === 'custom')
				return normalizeCronText(custom.value).trim() || '0 3 * * *';

			const clock = String(time.value || '03:00').split(':');
			const hour = parseInt(clock[0], 10) || 0;
			const minute = parseInt(clock[1], 10) || 0;
			if (selected === 'weekly')
				return minute + ' ' + hour + ' * * ' + (weekday.value || '1');
			if (selected === 'monthly')
				return minute + ' ' + hour + ' ' + (parseInt(day.value, 10) || 1) + ' * *';
			return minute + ' ' + hour + ' * * *';
		};
		return editor;
	}

	function mountScheduleEditor(hostId, expression) {
		const host = $('#' + hostId);
		if (!host) return;
		const editor = buildScheduleEditor(expression || '0 3 * * *');
		host.replaceChildren(editor);
		host._scheduleValue = editor._scheduleValue;
	}

	// Scheduled runs are limited by worker; the workers configured on the 节点
	// page are the only units the shell tests.
	function configuredNodes() {
		const list = [];
		const seen = new Set();
		configuredWorkers().forEach((worker) => {
			if (seen.has(worker.node)) return;
			seen.add(worker.node);
			list.push({ id: worker.node, name: nodeRemark(worker.node), stale: false });
		});
		return list;
	}

	// A collapsible checkbox list.  No selection means "every configured
	// worker", matching the CLI's --node semantics.
	function buildNodePicker(selected, disabled) {
		const details = document.createElement('details');
		details.className = 'node-picker';
		const summary = document.createElement('summary');
		const list = document.createElement('div');
		list.className = 'node-picker-list';

		const nodes = configuredNodes();
		const known = new Set(nodes.map((node) => node.id));
		(selected || []).forEach((id) => {
			if (id && !known.has(id)) {
				known.add(id);
				nodes.push({ id: id, name: id, stale: true });
			}
		});
		const chosen = new Set(selected || []);
		nodes.forEach((node) => {
			const label = document.createElement('label');
			label.className = 'check';
			const box = document.createElement('input');
			box.type = 'checkbox';
			box.value = node.id;
			box.checked = chosen.has(node.id);
			box.disabled = !!disabled;
			const text = document.createElement('span');
			text.textContent = node.stale ? (node.id + '（已删除）') : node.name;
			label.appendChild(box);
			label.appendChild(text);
			list.appendChild(label);
		});
		if (!nodes.length) {
			const empty = document.createElement('span');
			empty.className = 'muted';
			empty.textContent = '还没有配置 worker；请先在「节点」页添加';
			list.appendChild(empty);
		}

		details.appendChild(summary);
		details.appendChild(list);
		floatPickerList(details, list);
		details._nodeValues = () => Array.from(
			list.querySelectorAll('input[type="checkbox"]:checked'))
			.map((box) => box.value);
		function sync() {
			const values = details._nodeValues();
			// 收起状态显示节点名称，而不是 passwall section ID。
			const labels = values.map((id) => {
				const node = nodes.find((item) => item.id === id);
				return node ? (node.stale ? (id + '（已删除）') : node.name) : nodeRemark(id);
			});
			summary.textContent = labels.length ? labels.join('、') : '全部节点';
			summary.title = labels.length ? labels.join('、') : '全部待测节点';
		}
		list.addEventListener('change', sync);
		sync();
		return details;
	}

	function mountNodePicker(hostId, selected) {
		const host = $('#' + hostId);
		if (!host) return;
		const picker = buildNodePicker(selected);
		host.replaceChildren(picker);
		host._nodeValues = picker._nodeValues;
	}

	async function saveCronTask(entry, schedule, enabled, mode, nodes) {
		const body = {
			source: entry.source,
			line: entry.line,
			schedule: schedule,
			enabled: enabled,
			mode: mode || '',
		};
		// null/undefined keeps the command's existing --node flags untouched;
		// an empty array explicitly clears them (= all nodes).
		if (nodes != null) body.nodes = nodes;
		try {
			// 写操作的 RPC 返回的是原始 ubus 信封（entries），不是翻译后的
			// {tasks} 结构；直接赋给 state.tasks 会把表格渲染成空。重新读取
			// /api/cron 保证两张任务表立即显示最新内容。
			await api('/api/cron/task/save', { method: 'POST', body: body });
			await refreshCronTasks();
			toast(enabled ? '定时任务已保存并启用' : '定时任务已保存并停用');
		} catch (e) {
			toast(e.message, true);
			refreshCronTasks().catch(() => {});
		}
	}

	async function deleteCronTask(entry) {
		if (!confirm('删除定时任务？\n\n' + (entry.schedule || '') + ' ' + (entry.command || '')))
			return;
		try {
			await api('/api/cron/task/delete', {
				method: 'POST',
				body: { source: entry.source, line: entry.line },
			});
			await refreshCronTasks();
			toast('定时任务已删除');
		} catch (e) {
			toast(e.message, true);
			refreshCronTasks().catch(() => {});
		}
	}

	async function addCronTask() {
		const host = $('#cron-add-schedule');
		const schedule = host && typeof host._scheduleValue === 'function' ? host._scheduleValue() : '';
		const modeNode = $('#cron-add-mode');
		const nodeHost = $('#cron-add-nodes');
		const nodes = nodeHost && typeof nodeHost._nodeValues === 'function'
			? nodeHost._nodeValues() : [];
		if (!schedule) {
			toast('请填写计划表达式', true);
			return;
		}
		try {
			await api('/api/cron/task/add', {
				method: 'POST',
				body: {
					schedule: schedule,
					mode: modeNode ? modeNode.value : 'retest',
					nodes: nodes,
				},
			});
			await refreshCronTasks();
			toast('定时任务已添加');
		} catch (e) {
			toast(e.message, true);
		}
	}

	function renderTasks() {
		renderCronTasks(state.tasks);
		renderTaskOverview(state.tasks);
	}

	function renderCronTasks(data) {
		const body = $('#cron-body');
		if (!body) return;
		body.replaceChildren();

		// Every task is an ordinary crontab line; there is no managed main
		// task to hide or special-case.
		const tasks = (data && data.tasks) || [];
		tasks.forEach((entry) => {
			const writable = !!entry.writable;
			const tr = document.createElement('tr');

			const enabledCell = document.createElement('td');
			const enabled = document.createElement('input');
			enabled.type = 'checkbox';
			enabled.checked = !entry.disabled;
			enabled.disabled = !writable;
			enabledCell.appendChild(enabled);
			tr.appendChild(enabledCell);

			const scheduleCell = document.createElement('td');
			const schedule = buildScheduleEditor(entry.schedule || '0 3 * * *');
			schedule.querySelectorAll('select, input').forEach((node) => {
				node.disabled = !writable;
			});
			scheduleCell.appendChild(schedule);
			tr.appendChild(scheduleCell);

			const taskCell = document.createElement('td');
			const detected = taskMode(entry.command);
			let taskSelect = null;
			if (detected) {
				taskSelect = document.createElement('select');
				taskSelect.className = 'task-mode';
				TASK_MODES.forEach(([value, label]) => {
					const option = document.createElement('option');
					option.value = value;
					option.textContent = label;
					taskSelect.appendChild(option);
				});
				taskSelect.value = detected.mode;
				taskSelect.disabled = !writable;
				taskCell.appendChild(taskSelect);
			} else {
				taskCell.textContent = taskLabel(entry.command);
			}
			tr.appendChild(taskCell);

			const nodeCell = document.createElement('td');
			let nodePicker = null;
			if (detected) {
				if (writable) {
					nodePicker = buildNodePicker(entry.nodes || []);
					nodeCell.appendChild(nodePicker);
				} else {
					nodeCell.className = 'muted';
					nodeCell.textContent = (entry.nodes && entry.nodes.length)
						? entry.nodes.map(nodeRemark).join('、') : '全部节点';
				}
			} else {
				nodeCell.className = 'muted';
				nodeCell.textContent = '—';
			}
			tr.appendChild(nodeCell);

			const commandCell = document.createElement('td');
			commandCell.className = 'mono cron-command';
			commandCell.textContent = entry.command || '';
			tr.appendChild(commandCell);

			const actionCell = document.createElement('td');
			if (writable) {
				const actions = document.createElement('div');
				actions.className = 'row-actions';
				const save = document.createElement('button');
				save.type = 'button';
				save.className = 'btn small primary';
				save.textContent = '保存';
				save.addEventListener('click', () => saveCronTask(
					entry, schedule._scheduleValue(), enabled.checked,
					taskSelect ? taskSelect.value : '',
					nodePicker ? nodePicker._nodeValues() : null));
				const remove = document.createElement('button');
				remove.type = 'button';
				remove.className = 'btn small danger';
				remove.textContent = '删除';
				remove.addEventListener('click', () => deleteCronTask(entry));
				actions.appendChild(save);
				actions.appendChild(remove);
				actionCell.appendChild(actions);
			} else {
				const badge = document.createElement('span');
				badge.className = 'badge';
				badge.textContent = '只读';
				actionCell.appendChild(badge);
			}
			tr.appendChild(actionCell);

			body.appendChild(tr);
		});

		if (!tasks.length) {
			const tr = document.createElement('tr');
			const td = document.createElement('td');
			td.colSpan = 6;
			td.className = 'empty';
			td.textContent = '暂无与本程序相关的定时任务';
			tr.appendChild(td);
			body.appendChild(tr);
		}

		setText('cron-note', tasks.length ? (tasks.length + ' 个任务') : '暂无任务');
		setText('cron-errors', ((data && data.errors) || []).join('；'));
	}

	// The overview copy is read-only apart from enable/disable; every other
	// edit lives on the Settings tab.
	function renderTaskOverview(data) {
		const body = $('#task-body');
		if (!body) return;
		body.replaceChildren();

		const tasks = (data && data.tasks) || [];
		if (!tasks.length) {
			const tr = document.createElement('tr');
			const td = document.createElement('td');
			td.colSpan = 5;
			td.className = 'empty';
			td.textContent = '暂无定时任务';
			tr.appendChild(td);
			body.appendChild(tr);
			return;
		}

		tasks.forEach((entry) => {
			const tr = document.createElement('tr');

			const stateCell = document.createElement('td');
			const toggle = document.createElement('button');
			toggle.type = 'button';
			toggle.className = 'btn small' + (entry.disabled ? '' : ' primary');
			toggle.textContent = entry.disabled ? '启用' : '停用';
			toggle.disabled = !entry.writable;
			toggle.addEventListener('click', () => {
				const detected = taskMode(entry.command);
				// entry.disabled === true means the next click enables it.
				saveCronTask(entry, entry.schedule, entry.disabled,
					detected ? detected.mode : '',
					detected ? (entry.nodes || []) : null);
			});
			stateCell.appendChild(toggle);
			tr.appendChild(stateCell);

			const scheduleCell = document.createElement('td');
			scheduleCell.className = 'mono';
			scheduleCell.textContent = entry.schedule || '—';
			tr.appendChild(scheduleCell);

			const taskCell = document.createElement('td');
			taskCell.textContent = taskLabel(entry.command);
			tr.appendChild(taskCell);

			const nodeCell = document.createElement('td');
			nodeCell.textContent = (entry.nodes && entry.nodes.length)
				? entry.nodes.map(nodeRemark).join('、') : '全部节点';
			tr.appendChild(nodeCell);

			const commandCell = document.createElement('td');
			commandCell.className = 'mono cron-command';
			commandCell.textContent = entry.command || '';
			tr.appendChild(commandCell);

			body.appendChild(tr);
		});
	}

	async function refreshCronTasks() {
		try {
			state.tasks = await api('/api/cron');
			renderTasks();
		} catch (e) {
			setText('cron-note', '读取失败：' + e.message);
		}
	}

	// ── settings form ───────────────────────────────────────────────────
	function fillSettings(cfg) {
		const g = (cfg && cfg.global) || {};
		const set = (id, value) => { const node = $('#' + id); if (node) node.value = value == null ? '' : value; };
		const check = (id, value) => { const node = $('#' + id); if (node) node.checked = (value === true || value === 1 || value === '1'); };

		set('ip_source', g.ip_source || 'builtin_ipv4');
		state.onlineSources = onlineSourcesFromConfig(g);
		renderOnlineSources();
		set('custom_ip_file', g.custom_ip_file);
		check('custom_allip', g.custom_allip);
		set('latency_max', g.tl);
		set('latency_min', g.tll);
		set('loss_max', g.tlr);
		set('test_count', g.node_test_count);
		set('probe_timeout', g.node_test_timeout);
		set('probes', g.node_test_probes);
		set('max_workers', g.node_test_threads);
		set('probe_url', g.node_test_url);
		check('download_enabled', g.download_test_enabled);
		set('download_count', g.download_test_count);
		set('download_size', g.download_test_size);
		set('download_time', g.download_test_time);
		check('iterate_enabled', g.iterate_enabled);
		set('iterate_minutes', g.iterate_minutes);
		set('iterate_converge_count', g.iterate_converge_count);
		check('monitor_enabled', g.monitor_enabled);
		set('monitor_interval', g.monitor_interval);
		set('monitor_failures', g.monitor_failures);
		check('ddns_enabled', g.ddns_enabled);
		set('ddns_token', g.ddns_api_token || '');
		set('ddns_zone_id', g.ddns_zone_id);
		set('ddns_zone_name', g.ddns_zone_name);
		set('ddns_ip_count', g.ddns_ip_count);
		set('ddns_ttl', g.ddns_ttl);
		check('ddns_proxied', g.ddns_proxied);
		set('web_listen', g.web_bind || '0.0.0.0');
		set('web_port', g.web_port || '17544');
		updateFieldVisibility();
		// The add form starts with no selection (= all workers) after a reload.
		mountNodePicker('cron-add-nodes', []);
	}

	function collectSettings() {
		if (!state.config)
			throw new Error('配置尚未加载完成');

		const g = state.config.global || {};
		const text = (id) => { const node = $('#' + id); return node ? node.value.trim() : ''; };
		const check = (id) => { const node = $('#' + id); return !!(node && node.checked); };
		const number = (id, fallback, min, max) => {
			let value = parseFloat(text(id));
			if (!Number.isFinite(value)) value = fallback;
			if (min != null && value < min) value = min;
			if (max != null && value > max) value = max;
			return value;
		};
		const integer = (id, fallback, min, max) => Math.round(number(id, fallback, min, max));

		// Scheduled tasks are ordinary crontab lines now.  The UCI cron fields
		// below are legacy (kept so old configs round-trip); they no longer
		// generate or own any task.
		const cron = normalizeCronText(g.custom_cron || '0 3 * * *');
		if (!/^([0-9A-Za-z*,/-]+\s+){4}[0-9A-Za-z*,/-]+$/.test(cron) &&
			!/^@(reboot|hourly|daily|weekly|monthly|yearly|annually|midnight)$/.test(cron))
			throw new Error('定时任务计划无效');

		// 还没回车提交的输入框内容也算一个源，避免用户直接点保存时丢掉。
		const pending = $('#ip_online_new');
		if (pending && pending.value.trim()) {
			addOnlineSources(pending.value);
			pending.value = '';
		}
		// 启用的源写进 ip_online_url；未启用的单独存，回显时还留在列表里。
		const sources = state.onlineSources.filter((item) => /^https?:\/\//.test(item.url || ''));
		const onlineUrl = sources.filter((item) => item.enabled !== false)
			.map((item) => item.url).join(' ');
		const onlineDisabled = sources.filter((item) => item.enabled === false)
			.map((item) => item.url).join(' ');

		return {
			global: {
				enabled: g.enabled === '1',
				ip_source: text('ip_source') || 'builtin_ipv4',
				ip_online_url: onlineUrl,
				ip_online_disabled: onlineDisabled,
				custom_ip_file: text('custom_ip_file'),
				custom_allip: check('custom_allip'),
				tl: integer('latency_max', 0, 0, 60000),
				tll: integer('latency_min', 40, 0, 60000),
				tlr: number('loss_max', 0.2, 0, 1),
				node_test_url: text('probe_url'),
				node_test_count: integer('test_count', 30, 1, 100000),
				node_test_timeout: integer('probe_timeout', 5, 1, 120),
				node_test_probes: integer('probes', 3, 1, 5),
				node_test_threads: integer('max_workers', 5, 0, 128),
				download_test_enabled: check('download_enabled'),
				download_test_count: integer('download_count', 5, 1, 10),
				download_test_size: integer('download_size', 999999, 16384, 999999),
				download_test_time: integer('download_time', 10, 1, 60),
				iterate_enabled: check('iterate_enabled'),
				iterate_minutes: integer('iterate_minutes', 30, 1, 10080),
				iterate_converge_count: integer('iterate_converge_count', 5, 1, 3000),
				monitor_enabled: check('monitor_enabled'),
				monitor_interval: integer('monitor_interval', 60, 10, 3600),
				monitor_failures: integer('monitor_failures', 3, 1, 10),
				ddns_enabled: check('ddns_enabled'),
				ddns_ip_count: integer('ddns_ip_count', 1, 1, 10),
				ddns_ttl: integer('ddns_ttl', 300, 1, 86400),
				ddns_api_token: text('ddns_token'),
				ddns_zone_id: text('ddns_zone_id'),
				ddns_zone_name: text('ddns_zone_name'),
				ddns_proxied: check('ddns_proxied'),
				custom_cron_enabled: g.custom_cron_enabled === '1',
				custom_cron: cron,
				hour: parseInt(g.hour, 10) || 24,
				node_test_node: text('cfg-test-node'),
				web_bind: text('web_listen') || '0.0.0.0',
				web_port: integer('web_port', 17544, 1, 65535),
			},
			ip_lists: ((state.config && state.config.ip_lists) || []).slice(0, 5).map((item) => ({
				enabled: !!item.enabled,
				name: item.name || '',
				regions: Array.isArray(item.regions) ? item.regions.join(' ') : (item.regions || ''),
				port: parseInt(item.port, 10) || 443,
				latency_max: Math.max(0, parseInt(item.latency_max, 10) || 0),
			})),
			workers: configuredWorkers()
				.filter((item) => !!String(item.node || '').trim())
				.map((item) => ({
					node: String(item.node).trim(),
					ip_list: item.ip_list || '',
					ddns_domain: String(item.ddns_domain || '').trim(),
				})),
			servers: collectServers(),
		};
	}

	function collectServers() {
		const text = (id) => { const node = $('#' + id); return node ? node.value.trim() : ''; };
		const check = (id) => { const node = $('#' + id); return !!(node && node.checked); };
		const int = (id, fallback) => {
			const value = parseInt(text(id), 10);
			return Number.isFinite(value) ? value : fallback;
		};
		const selected = (id) => {
			const select = $('#' + id);
			if (!select) return [];
			return Array.from(select.selectedOptions || []).map((option) => option.value)
				.filter((value) => !!value);
		};

		return {
			ssr_enabled: check('tp-ssr-enabled'),
			ssr_services: selected('tp-ssr-services'),
			passwall_enabled: check('tp-passwall-enabled'),
			passwall2_enabled: check('tp-passwall2-enabled'),
			passwall2_services: selected('tp-passwall2-services'),
			bypass_enabled: check('tp-bypass-enabled'),
			bypass_services: selected('tp-bypass-services'),
			vssr_enabled: check('tp-vssr-enabled'),
			vssr_services: selected('tp-vssr-services'),
			HOST_enabled: check('tp-host-enabled'),
			host_domain: text('tp-host-domain'),
			DNS_enabled: check('tp-dns-enabled'),
			DNS_type: text('tp-dns-type') || 'aliyun',
			app_key: text('tp-app-key'),
			app_secret: text('tp-app-secret'),
			main_domain: text('tp-main-domain'),
			sub_domain: text('tp-sub-domain'),
			line: text('tp-dns-line') || 'default',
			AliDNS_ip_count: int('tp-alidns-count', 1),
			MosDNS_enabled: check('tp-mosdns-enabled'),
			MosDNS_ip_count: int('tp-mosdns-count', 1),
			openclash_restart: check('tp-openclash'),
			AstraDNS_enabled: check('tp-astra-enabled'),
			AstraDNS_config: text('tp-astra-config'),
			AstraDNS_bin: text('tp-astra-bin'),
		};
	}

	function fillThirdParty() {
		const servers = (state.config && state.config.servers) || {};
		const setCheck = (id, value) => {
			const node = $('#' + id);
			if (node) node.checked = (value === true || value === 1 || value === '1');
		};
		const setValue = (id, value) => {
			const node = $('#' + id);
			if (node) node.value = value == null ? '' : value;
		};

		setCheck('tp-ssr-enabled', servers.ssr_enabled);
		fillMulti('tp-ssr-services', providerNodes('ssr'), servers.ssr_services);
		setCheck('tp-passwall-enabled', servers.passwall_enabled);
		setCheck('tp-passwall2-enabled', servers.passwall2_enabled);
		fillMulti('tp-passwall2-services', providerNodes('passwall2'), servers.passwall2_services);
		setCheck('tp-bypass-enabled', servers.bypass_enabled);
		fillMulti('tp-bypass-services', providerNodes('bypass'), servers.bypass_services);
		setCheck('tp-vssr-enabled', servers.vssr_enabled);
		fillMulti('tp-vssr-services', providerNodes('vssr'), servers.vssr_services);

		setCheck('tp-host-enabled', servers.HOST_enabled);
		setValue('tp-host-domain', servers.host_domain);

		setCheck('tp-dns-enabled', servers.DNS_enabled);
		setValue('tp-dns-type', servers.DNS_type || 'aliyun');
		setValue('tp-app-key', servers.app_key);
		setValue('tp-app-secret', servers.app_secret ? '***' : '');
		setValue('tp-main-domain', servers.main_domain);
		setValue('tp-sub-domain', Array.isArray(servers.sub_domain)
			? servers.sub_domain.join(' ') : (servers.sub_domain || ''));
		setValue('tp-dns-line', servers.line || 'default');
		setValue('tp-alidns-count', servers.AliDNS_ip_count || '1');

		setCheck('tp-mosdns-enabled', servers.MosDNS_enabled);
		setValue('tp-mosdns-count', servers.MosDNS_ip_count || '1');
		setCheck('tp-openclash', servers.openclash_restart);

		setCheck('tp-astra-enabled', servers.AstraDNS_enabled);
		setValue('tp-astra-config', servers.AstraDNS_config || '/etc/astra-dns/named.yaml');
		setValue('tp-astra-bin', servers.AstraDNS_bin || '/usr/bin/astra-dns');

		if (state.providers && Object.keys(state.providers).length) {
			['ssr', 'passwall2', 'bypass', 'vssr'].forEach((name) => {
				const card = $('#tp-' + name);
				if (card) card.classList.toggle('hidden', !providerExists(name));
			});
			const passwallCard = $('#tp-passwall');
			if (passwallCard) passwallCard.classList.toggle('hidden', !providerExists('passwall'));
		}
	}

	function fillMulti(id, nodes, values) {
		const select = $('#' + id);
		if (!select) return;

		const wanted = new Set((values || []).map((value) => String(value)));
		const seen = {};

		select.replaceChildren();
		nodes.forEach((node) => {
			if (!node.value || seen[node.value]) return;
			seen[node.value] = true;
			const option = document.createElement('option');
			option.value = node.value;
			option.textContent = node.label +
				(String(node.type || '').toLowerCase() === 'socks' ? '（socks）' : '');
			option.selected = wanted.has(String(node.value));
			select.appendChild(option);
		});
		wanted.forEach((value) => {
			if (!seen[value]) {
				const option = document.createElement('option');
				option.value = value;
				option.textContent = value;
				option.selected = true;
				select.appendChild(option);
			}
		});
	}

	function updateFieldVisibility() {
		const source = $('#ip_source') ? $('#ip_source').value : '';
		$$('[data-when]').forEach((node) => {
			const key = node.dataset.when;
			let visible = true;
			if (key === 'online') visible = source === 'online';
			else if (key === 'custom_file') visible = source === 'custom_file';
			node.classList.toggle('hidden', !visible);
		});
	}

	// ── 在线源列表 ──────────────────────────────────────────────────────
	// 一行一个源，勾选 = 启用；底部输入框回车添加。启用的源保存到
	// ip_online_url（空格分隔，引擎逐个下载合并），未启用的存到
	// ip_online_disabled，回显时不丢。
	function parseSourceUrls(value) {
		return String(value || '').split(/[\s,]+/)
			.filter((item) => /^https?:\/\//.test(item));
	}

	function onlineSourcesFromConfig(global) {
		const enabled = parseSourceUrls(global.ip_online_url);
		const disabled = parseSourceUrls(global.ip_online_disabled)
			.filter((url) => enabled.indexOf(url) < 0);
		return enabled.map((url) => ({ url, enabled: true }))
			.concat(disabled.map((url) => ({ url, enabled: false })));
	}

	function renderOnlineSources() {
		const box = $('#ip_online_list');
		if (!box) return;
		box.textContent = '';
		state.onlineSources.forEach((item, index) => {
			const row = document.createElement('div');
			row.className = 'source-row';

			const check = document.createElement('input');
			check.type = 'checkbox';
			check.checked = item.enabled !== false;
			check.title = '启用该源';
			check.addEventListener('change', () => { item.enabled = check.checked; });

			const input = document.createElement('input');
			input.type = 'text';
			input.spellcheck = false;
			input.value = item.url;
			input.addEventListener('input', () => { item.url = input.value.trim(); });

			const del = document.createElement('button');
			del.type = 'button';
			del.className = 'btn small danger';
			del.textContent = '删除';
			del.addEventListener('click', () => {
				state.onlineSources.splice(index, 1);
				renderOnlineSources();
			});

			row.appendChild(check);
			row.appendChild(input);
			row.appendChild(del);
			box.appendChild(row);
		});
	}

	function addOnlineSources(text) {
		let added = false;
		parseSourceUrls(text).forEach((url) => {
			if (state.onlineSources.some((item) => item.url === url)) return;
			state.onlineSources.push({ url, enabled: true });
			added = true;
		});
		if (added) renderOnlineSources();
		return added;
	}

	function bindOnlineSourceInput() {
		const input = $('#ip_online_new');
		if (!input) return;
		input.addEventListener('keydown', (event) => {
			if (event.key !== 'Enter' || event.isComposing) return;
			event.preventDefault();
			if (addOnlineSources(input.value)) input.value = '';
		});
	}

	async function previewDdns() {
		try {
			const data = await api('/api/ddns');
			const preview = data.preview || {};
			const nodes = preview.nodes || [];
			let text;
			if (!nodes.length) {
				text = preview.error || '没有节点配置 DDNS 域名（这些节点只测速）。';
			} else {
				text = nodes.map((item) => item.error
					? (item.node || '?') + ' → ' + item.domain + '：' + item.error
					: (item.node || '?') + ' → ' + item.domain + '：' + (item.ips || []).join(', ')
				).join('\n');
				if (!preview.enabled) text += '\n（DDNS 当前未启用，预览不会写入）';
			}
			setText('ddns-status', text);
		} catch (e) {
			toast(e.message, true);
		}
	}

	async function applyDdns() {
		const button = $('#btn-ddns-apply');
		if (button) button.disabled = true;
		try {
			const data = await api('/api/ddns/apply', { method: 'POST', body: {} });
			toast(data.message || 'DDNS 写入完成');
			if (data.report) {
				const failed = (data.report.nodes || []).filter((item) => item.error);
				const lines = (data.report.nodes || []).map((item) => item.error
					? (item.node || '?') + ' → ' + item.domain + '：' + item.error
					: (item.node || '?') + ' → ' + item.domain + '：' + (item.ips || []).join(', ') +
						'（新建 ' + (item.created || 0) + ' / 更新 ' + (item.updated || 0) +
						' / 无变化 ' + (item.unchanged || 0) + '）');
				setText('ddns-status', lines.join('\n') || data.message || '');
				if (failed.length) toast(failed.length + ' 个节点写入失败', true);
			}
			await pollStatus();
		} catch (e) {
			toast(e.message, true);
		} finally {
			if (button) button.disabled = false;
		}
	}

	async function saveConfig(successMessage) {
		const hint = $('#save-hint');
		if (hint) hint.textContent = '正在保存…';
		try {
			const response = await api('/api/config', { method: 'POST', body: collectSettings() });
			state.config = response.config;
			fillSettings(state.config);
			applyNodeSources();
			renderIpLists();
			renderBest();
			renderDdnsStatus(ddnsInfo());
			if (hint) hint.textContent = '已保存 ' + new Date().toLocaleTimeString();
			toast(successMessage || '配置已保存');
			await pollStatus();
		} catch (e) {
			// DDNS validation failed: clear the token field so the user must
			// re-enter a working Cloudflare token before saving again.
			if (String(e.message || '').indexOf('DDNS') >= 0) {
				const token = $('#ddns_token');
				if (token) token.value = '';
			}
			if (hint) hint.textContent = '';
			toast(e.message, true);
		}
	}

	// ── logs ────────────────────────────────────────────────────────────
	// 切页、2 秒定时器和手动刷新可能同时发起读取；若两个请求用同一个 pos
	// 各追加一次，日志就会出现重复行。这里把读取排成串行队列。
	function reloadLog(reset) {
		state.logChain = state.logChain.then(
			() => reloadLogNow(reset),
			() => reloadLogNow(reset)
		);
		return state.logChain;
	}

	async function reloadLogNow(reset) {
		const view = $('#log-view');
		if (!view) return;
		if (reset) {
			state.logPos = 0;
			view.textContent = '';
		}
		try {
			const chunk = await api('/api/log?pos=' + state.logPos);
			if (chunk.content) {
				view.textContent += chunk.content;
				state.logPos = chunk.pos || 0;
				if (view.textContent.length > 2 * 1024 * 1024)
					view.textContent = view.textContent.slice(-2 * 1024 * 1024);
				if ($('#log-follow').checked)
					view.scrollTop = view.scrollHeight;
			}
			setText('log-meta', '已读取 ' + state.logPos + ' 字节' +
				(state.status && state.status.running ? ' · 测速运行中' : ''));
		} catch (e) {
			/* ignore */
		}
	}

	function tickLogs() {
		if (state.tab !== 'logs' || state.logSubtab !== 'runlog') return;
		if (!$('#log-autorefresh') || !$('#log-autorefresh').checked) return;
		reloadLog(false);
	}

	// 「日志」页内的两个窗口：运行日志 / 任务日志。
	function setLogSubtab(name) {
		state.logSubtab = (name === 'tasklog') ? 'tasklog' : 'runlog';
		$$('#log-subtabs .subtab').forEach((tab) => {
			tab.classList.toggle('active', tab.dataset.subtab === state.logSubtab);
		});
		$$('.panel[data-panel="logs"] [data-subpanel]').forEach((panel) => {
			panel.classList.toggle('active', panel.dataset.subpanel === state.logSubtab);
		});
		if (state.logSubtab === 'tasklog') refreshTaskLog();
		else reloadLog(false);
	}

	async function downloadLog() {
		try {
			const chunk = await api('/api/log?pos=0');
			const text = (chunk && chunk.content) || '';
			if (!text) { toast('日志为空', true); return; }
			downloadFile('speedtest.log', text);
		} catch (e) {
			toast(e.message, true);
		}
	}

	// ── task log ────────────────────────────────────────────────────────
	// 「日志」页的两个窗口之一：每次测速的结果是一条描述，下面展开各节点
	// 本次更新用的 IP、写回方式以及该 IP 的延迟/速度。数据来自 tasklog.tsv。
	const TASK_METHOD_LABELS = { ddns: '写 DNS', writeback: '写回' };

	function taskCell(text, className) {
		const td = document.createElement('td');
		if (className) td.className = className;
		td.textContent = text;
		return td;
	}

	function taskDetailRow(entry) {
		const tr = document.createElement('tr');
		const status = entry.status || '';
		let ip = entry.ip || '—';
		let method = TASK_METHOD_LABELS[entry.method] || '—';
		if (status === 'fail') {
			tr.className = 'task-row-fail';
			ip = '未更新（无有效结果）';
			method = '—';
		} else if (status === 'abnormal') {
			tr.className = 'task-row-abnormal';
			ip = '未完成（沿用上次结果）';
			method = '—';
		}
		tr.appendChild(taskCell(entry.node || '—'));
		tr.appendChild(taskCell(ip, 'ip'));
		tr.appendChild(taskCell(method));
		tr.appendChild(taskCell(entry.latency > 0 ? fmtNumber(entry.latency) + ' ms' : '—'));
		tr.appendChild(taskCell(entry.speed > 0 ? fmtNumber(entry.speed) + ' MB/s' : '—'));
		return tr;
	}

	function taskDetailsTable(entries) {
		const wrap = document.createElement('div');
		wrap.className = 'table-wrap';
		const table = document.createElement('table');
		table.className = 'data';
		const thead = document.createElement('thead');
		const headRow = document.createElement('tr');
		['节点', '更新 IP', '方式', '延迟', '速度'].forEach((label) => {
			const th = document.createElement('th');
			th.textContent = label;
			headRow.appendChild(th);
		});
		thead.appendChild(headRow);
		table.appendChild(thead);
		const tbody = document.createElement('tbody');
		entries.forEach((entry) => tbody.appendChild(taskDetailRow(entry)));
		table.appendChild(tbody);
		wrap.appendChild(table);
		return wrap;
	}

	function renderTaskLog(tasks) {
		const list = $('#tasklog-list');
		if (!list) return;
		state.tasklog = tasks || [];
		list.replaceChildren();

		if (!state.tasklog.length) {
			const empty = document.createElement('p');
			empty.className = 'task-empty';
			empty.textContent = '暂无任务记录；下一次测速开始后会写入这里。';
			list.appendChild(empty);
			return;
		}

		let expanded = false;
		state.tasklog.forEach((task) => {
			const block = document.createElement('article');
			block.className = 'task-entry';

			const head = document.createElement('div');
			head.className = 'task-head';
			const time = document.createElement('span');
			time.className = 'task-time';
			time.textContent = task.time || '—';
			head.appendChild(time);

			const badge = document.createElement('span');
			if (task.kind === 'result') {
				const ok = task.status === 'ok';
				badge.className = 'badge ' + (ok ? 'ok' : (task.status === 'stopped' ? 'info' : 'bad'));
				badge.textContent = ok ? '成功' : (task.status === 'stopped' ? '已停止' : '失败');
			} else {
				badge.className = 'badge info';
				badge.textContent = task.kind === 'event' ? '事件' : '开始';
			}
			head.appendChild(badge);

			const message = document.createElement('span');
			message.className = 'task-message';
			message.textContent = task.message || '';
			head.appendChild(message);
			block.appendChild(head);

			if (task.kind === 'result' && task.details && task.details.length) {
				const details = document.createElement('details');
				details.className = 'task-details';
				// 最新一条结果默认展开，其余折叠。
				if (!expanded) {
					details.open = true;
					expanded = true;
				}
				const summary = document.createElement('summary');
				let okCount = 0;
				let failCount = 0;
				let abnormalCount = 0;
				task.details.forEach((entry) => {
					if (entry.status === 'ok') okCount += 1;
					else if (entry.status === 'fail') failCount += 1;
					else abnormalCount += 1;
				});
				summary.textContent = '各节点更新情况（成功 ' + okCount +
					' · 失败 ' + failCount + ' · 异常 ' + abnormalCount + '）';
				details.appendChild(summary);
				details.appendChild(taskDetailsTable(task.details));
				block.appendChild(details);
			}

			list.appendChild(block);
		});
	}

	async function refreshTaskLog() {
		try {
			const data = await api('/api/tasklog');
			renderTaskLog((data && data.tasks) || []);
		} catch (e) {
			/* handled by api() */
		}
	}

	function tickTaskLog() {
		if (state.tab !== 'logs' || state.logSubtab !== 'tasklog') return;
		refreshTaskLog();
	}

	// ── core modules ─────────────────────────────────────────────────────
	const CORE_LABELS = {
		mihomo: 'mihomo（Clash.Meta）',
		xray: 'Xray-core',
	};

	function renderCoreCards(payload) {
		const container = $('#core-cards');
		if (!container) return;
		$$('#core-cards input[data-core-tag]').forEach((input) => {
			state.coreTags[input.dataset.coreTag] = input.value;
		});
		container.replaceChildren();
		const cores = payload.cores || {};
		const active = payload.active || '';
		const updating = !!payload.updating;
		const updatingType = payload.updating_type || '';

		Object.keys(CORE_LABELS).forEach((type) => {
			const info = cores[type] || {};
			const card = document.createElement('div');
			card.className = 'card stat core-card';

			const head = document.createElement('div');
			head.className = 'core-card-head';
			const title = document.createElement('h2');
			title.textContent = CORE_LABELS[type];
			const badge = document.createElement('span');
			if (type === active) {
				badge.className = 'badge info';
				badge.textContent = info.installed ? '当前使用' : '当前使用 · 未安装';
			} else if (info.installed) {
				badge.className = 'badge ok';
				badge.textContent = '已安装';
			} else {
				badge.className = 'badge bad';
				badge.textContent = '未安装';
			}
			head.appendChild(title);
			head.appendChild(badge);
			card.appendChild(head);

			const list = document.createElement('dl');
			list.className = 'kv';
			const rows = [
				['版本', info.version || '—', 'mono'],
				['路径', info.path || '—', 'mono'],
				['来源', info.managed ? '托管（可自动升级）' : (info.installed ? '系统自带' : '—'), ''],
			];
			rows.forEach((row) => {
				const dt = document.createElement('dt');
				dt.textContent = row[0];
				const dd = document.createElement('dd');
				if (row[2]) dd.className = row[2];
				dd.textContent = row[1];
				list.appendChild(dt);
				list.appendChild(dd);
			});
			card.appendChild(list);

			const updateRow = document.createElement('div');
			updateRow.className = 'core-update-row';
			const tagInput = document.createElement('input');
			tagInput.type = 'text';
			tagInput.placeholder = '版本标签，留空 = 最新版';
			tagInput.dataset.coreTag = type;
			tagInput.value = state.coreTags[type] || '';
			tagInput.spellcheck = false;
			tagInput.addEventListener('input', () => {
				state.coreTags[type] = tagInput.value;
			});
			const button = document.createElement('button');
			button.type = 'button';
			button.className = 'btn small primary';
			button.textContent = (updating && updatingType === type) ? '更新中…' :
				(info.installed ? '升级' : '安装');
			button.disabled = updating;
			button.addEventListener('click', () => updateCore(type, tagInput.value.trim()));
			updateRow.appendChild(tagInput);
			updateRow.appendChild(button);
			card.appendChild(updateRow);

			container.appendChild(card);
		});
	}

	function renderCore(payload) {
		if (!payload) return;
		state.core = payload;
		const enable = $('#sa-enabled');
		// 独立内核是固定项：无论旧配置里 standalone_enabled 是什么，都显示为固定启用。
		if (enable) { enable.checked = true; enable.disabled = true; }
		const select = $('#core-type');
		if (select) select.value = payload.active === 'mihomo' ? 'mihomo' : 'xray';
		renderCoreCards(payload);
		setText('core-message', payload.message || '');
		setText('sa-update-log', payload.update_log || '');
		scheduleCorePoll();
	}

	async function refreshCore() {
		try {
			renderCore(await api('/api/core'));
		} catch (e) { /* ignore */ }
	}

	async function saveCore() {
		try {
			await api('/api/core/save', {
				method: 'POST',
				body: {
					enabled: true,
					core: ($('#core-type') && $('#core-type').value === 'mihomo') ? 'mihomo' : 'xray',
				},
			});
			toast('内核设置已保存');
			await refreshCore();
		} catch (e) {
			toast(e.message, true);
		}
	}

	function scheduleCorePoll() {
		clearTimeout(state.coreTimer);
		if (state.core && state.core.updating) {
			state.coreTimer = setTimeout(() => { refreshCore(); }, 2000);
		}
	}

	async function updateCore(type, tag) {
		try {
			const response = await api('/api/core/update', {
				method: 'POST',
				body: { type: type, tag: tag || '' },
			});
			toast((response && response.busy) ? '内核正在更新，请稍候' : ('已开始更新 ' + type));
			await refreshCore();
		} catch (e) {
			toast(e.message, true);
		}
	}

	// ── application self-update ──────────────────────────────────────────
	function renderAppInfo(app) {
		if (!app) return;
		state.appInfo = app;
		setText('app-current-version', app.version || '—');
		setText('app-version', app.version || '');
		const update = app.update || {};
		let text = '—';
		if (update.updating) {
			text = update.message || '更新中…';
		} else if (update.message || update.error) {
			text = (update.message || '') + (update.error ? '：' + update.error : '') +
				(update.version ? '（' + update.version + '）' : '');
		}
		setText('app-update-state', text);
		const running = !!(state.status && state.status.running);
		const busy = !!update.updating;
		const button = $('#btn-app-update');
		if (button) {
			button.disabled = busy || running;
			button.textContent = busy ? '更新中…' : '更新程序';
		}
	}

	async function refreshAppInfo() {
		try {
			renderAppInfo(await api('/api/app'));
		} catch (e) { /* ignore */ }
	}

	async function updateApp() {
		if (!confirm('更新程序会下载并覆盖安装本包，页面会短暂断连。继续？'))
			return;
		try {
			const response = await api('/api/update-app', { method: 'POST', body: {} });
			if (response && response.started === false) {
				toast(response.error || '无法开始更新', true);
				return;
			}
			toast('已开始更新程序');
			waitForAppUpdate();
		} catch (e) {
			// fetch 本身失败（TypeError）通常说明服务已经开始重启、连接被断开；
			// 更新可能正在进行，继续轮询状态，而不是直接报错。
			if (e instanceof TypeError) {
				toast('更新请求已断开（服务可能正在重启），等待更新结果…');
				waitForAppUpdate();
			} else {
				toast(e.message, true);
			}
		}
	}

	function waitForAppUpdate() {
		clearInterval(state.appTimer);
		let attempts = 0;
		state.appTimer = setInterval(async () => {
			attempts += 1;
			try {
				const app = await api('/api/app');
				renderAppInfo(app);
				if (!app.update || !app.update.updating) {
					clearInterval(state.appTimer);
					state.appTimer = 0;
					const ok = !!(app.update && app.update.ok);
					const detail = (app.update && (app.update.error || app.update.message)) || '请查看更新日志';
					toast(ok ? '程序更新完成，页面即将刷新' : ('更新失败：' + detail), !ok);
					setTimeout(() => window.location.reload(), 1200);
					return;
				}
			} catch (e) {
				/* the service is restarting */
			}
			if (attempts >= 60) {
				clearInterval(state.appTimer);
				state.appTimer = 0;
				toast('更新状态超时，请手动刷新页面', true);
			}
		}, 2000);
	}

	// ── actions ──────────────────────────────────────────────────────────
	async function startNode(node, mode) {
		if (!node) {
			toast('请先选择一个 PassWall 节点', true);
			return;
		}
		try {
			const result = await api('/api/start', {
				method: 'POST',
				body: { mode: mode, nodes: [node] },
			});
			if (result && result.started === false)
				toast('该 worker 已在测速，请先停止');
			else
				toast((mode === 'retest' ? '已开始复测：' : '已开始测速：') + nodeLabel(node));
			activateTab('logs');
			await pollStatus();
		} catch (e) {
			toast(e.message, true);
		}
	}

	async function stopNode(node) {
		if (!node) return;
		try {
			const response = await api('/api/stop', {
				method: 'POST',
				body: { nodes: [node] },
			});
			toast((response && response.message) || ('已请求停止：' + nodeLabel(node)));
			await pollStatus();
		} catch (e) {
			toast(e.message, true);
		}
	}

	// 按钮状态跟 /api/status 同步：
	//   * 该 worker 正在测速 → 测速/复测禁用，停止可用；
	//   * 整个下载/写回阶段（download_active）→ 本页所有按钮禁用；
	//   * 空闲 → 测速/复测可用，停止禁用。
	function syncNodeActions() {
		const status = state.status || {};
		const workers = status.workers || {};
		const monitors = status.monitor || {};
		const busy = !!status.download_active;

		$$('#cfg-workers-body tr').forEach((row) => {
			const id = row.dataset.node || '';
			const info = id ? workers[id] : null;
			const running = !!info;
			const stopping = !!(info && info.stopping);
			row.classList.toggle('running', running);

			const monitorBadge = row.querySelector('[data-node-monitor]');
			if (monitorBadge) {
				const mon = id ? monitors[id] : null;
				monitorBadge.classList.toggle('hidden', !mon);
				if (mon) {
					const failed = mon.ok === false || mon.ok === 0;
					monitorBadge.className = 'badge monitor ' + (failed ? 'bad' : 'ok');
					monitorBadge.textContent = failed
						? '监测失败 ' + (mon.failures || 0) + ' 次'
						: '监测 ' + fmtNumber(mon.latency || 0) + ' ms';
					monitorBadge.title = '成功结果监测：' + (mon.target || '') +
						(mon.ip && mon.ip !== mon.target ? '（' + mon.ip + '）' : '') +
						(mon.checked_at
							? ' · ' + new Date(mon.checked_at * 1000).toLocaleString()
							: ' · 等待首次复测');
				}
			}

			row.querySelectorAll('[data-node-action]').forEach((button) => {
				const action = button.dataset.nodeAction;
				if (action === 'stop') {
					button.disabled = !running || stopping || busy;
					button.textContent = stopping ? '停止中…' : '停止';
				}
				else {
					button.disabled = running || busy;
				}
			});
		});
	}

	async function startTest(mode) {
		try {
			await api('/api/start', { method: 'POST', body: { mode: mode } });
			toast(mode === 'retest' ? '已开始复测现有最优 IP' : '已开始测速');
			activateTab('logs');
			await pollStatus();
		} catch (e) {
			toast(e.message, true);
		}
	}

	async function stopTest() {
		try {
			const response = await api('/api/stop', { method: 'POST', body: {} });
			toast((response && response.message) || '已请求停止');
			await pollStatus();
		} catch (e) {
			toast(e.message, true);
		}
	}

	// ── password ────────────────────────────────────────────────────────
	async function changePassword() {
		const current = $('#auth-current').value;
		const next = $('#auth-new').value;
		const confirm = $('#auth-confirm-new').value;

		if (!current || !next) {
			toast('请填写当前密码和新密码', true);
			return;
		}
		if (next.length < 6) {
			toast('新密码至少 6 位', true);
			return;
		}
		if (next !== confirm) {
			toast('两次输入的新密码不一致', true);
			return;
		}

		try {
			await request('password', { method: 'POST', body: { current: current, next: next } });
			$('#auth-current').value = '';
			$('#auth-new').value = '';
			$('#auth-confirm-new').value = '';
			$('#auth-password').value = '';
			toast('密码已更新，请重新登录');
			showAuth('login');
		} catch (e) {
			toast(e.message, true);
		}
	}

	// ── init ────────────────────────────────────────────────────────────
	async function loadAll() {
		const results = await Promise.all([
			api('/api/config'),
			api('/api/status'),
			api('/api/best'),
			api('/api/history'),
			api('/api/nodes'),
			api('/api/core'),
			api('/api/app'),
			api('/api/downloads').catch(() => null),
		]);
		state.config = results[0].config;
		state.status = results[1];
		state.lastRunning = !!(results[1] && results[1].running);
		state.best = results[2];
		state.history = (results[3] && results[3].history) || [];
		state.providers = results[4] || {};
		state.core = results[5];
		state.appInfo = results[6];
		state.downloads = (results[7] && results[7].rows) || [];
		if (results[1] && results[1].state_dir)
			setText('state-dir', results[1].state_dir);

		fillSettings(state.config);
		applyNodeSources();
		renderIpLists();
		renderBest();
		renderHistory();
		renderDdnsStatus(ddnsInfo());
		renderStatus(state.status);
		renderCore(state.core);
		renderAppInfo(state.appInfo);
		activateTab(initialTab());
	}

	function startPolling() {
		stopPolling();
		state.pollTimer = setInterval(pollStatus, 3000);
		state.logTimer = setInterval(tickLogs, 2000);
		state.taskTimer = setInterval(tickTaskLog, 5000);
		state.elapsedTimer = setInterval(tickElapsed, 1000);
	}

	function stopPolling() {
		clearInterval(state.pollTimer);
		clearInterval(state.logTimer);
		clearInterval(state.taskTimer);
		clearInterval(state.elapsedTimer);
		clearInterval(state.appTimer);
		clearTimeout(state.coreTimer);
		state.pollTimer = 0;
		state.logTimer = 0;
		state.taskTimer = 0;
		state.elapsedTimer = 0;
		state.appTimer = 0;
		state.coreTimer = 0;
	}

	async function bootApp() {
		state.loggedIn = true;
		state.lastRunning = false;
		state.logPos = 0;
		const view = $('#log-view');
		if (view) view.textContent = '';
		await loadAll();
		startPolling();
	}

	function bindEvents() {
		$('#tabs').addEventListener('click', (event) => {
			const tab = event.target.closest('.tab');
			if (tab) activateTab(tab.dataset.tab);
		});
		window.addEventListener('hashchange', () => activateTab(initialTab()));

		$('#btn-start').addEventListener('click', () => startTest('start'));
		$('#btn-stop').addEventListener('click', stopTest);
		$('#btn-retest').addEventListener('click', () => startTest('retest'));
		$('#btn-logout').addEventListener('click', logout);
		$('#ov-btn-start').addEventListener('click', () => startTest('start'));
		$('#ov-btn-stop').addEventListener('click', stopTest);
		$('#ov-btn-retest').addEventListener('click', () => startTest('retest'));
		bindHistoryEvents();

		$('#btn-add-worker').addEventListener('click', addWorker);
		$('#btn-save-nodes').addEventListener('click', () => saveConfig('节点已保存'));
		$('#btn-save-iplists').addEventListener('click', () => saveConfig('IP 列表已保存'));

		$('#settings-form').addEventListener('submit', (event) => {
			event.preventDefault();
			saveConfig('设置已保存');
		});
		$('#ip_source').addEventListener('change', updateFieldVisibility);
		bindOnlineSourceInput();
		$('#btn-cron-refresh').addEventListener('click', refreshCronTasks);
		mountScheduleEditor('cron-add-schedule', '0 3 * * *');
		mountNodePicker('cron-add-nodes', []);
		$('#btn-cron-add').addEventListener('click', addCronTask);
		$('#btn-ddns-preview').addEventListener('click', previewDdns);
		$('#btn-ddns-apply').addEventListener('click', applyDdns);
		$('#btn-password').addEventListener('click', changePassword);
		$('#btn-save-thirdparty').addEventListener('click', () => saveConfig('第三方配置已保存'));

		$('#log-subtabs').addEventListener('click', (event) => {
			const tab = event.target.closest('.subtab');
			if (tab) setLogSubtab(tab.dataset.subtab);
		});
		$('#btn-log-reload').addEventListener('click', () => reloadLog(true));
		$('#btn-tasklog-reload').addEventListener('click', refreshTaskLog);
		$('#dl-log').addEventListener('click', (event) => {
			event.preventDefault();
			downloadLog();
		});

		$('#btn-core-refresh').addEventListener('click', refreshCore);
		$('#btn-save-core').addEventListener('click', saveCore);
		$('#btn-app-update').addEventListener('click', updateApp);

		$$('.overlay').forEach((overlay) => {
			overlay.addEventListener('click', (event) => {
				if (event.target === overlay && overlay.id !== 'auth-overlay')
					overlay.classList.add('hidden');
			});
		});
		document.addEventListener('keydown', (event) => {
			if (event.key === 'Escape') closeOverlays();
		});

		$('#auth-form').addEventListener('submit', onAuthSubmit);
	}

	async function init() {
		bindEvents();
		try {
			const hello = await request('hello');
			if (hello && hello.authenticated) {
				state.csrf = hello.csrf || '';
				hideAuth();
				await bootApp();
				toast('已登录操作台');
			}
			else {
				showAuth(hello && hello.setup ? 'setup' : 'login');
			}
		} catch (e) {
			showAuth('login');
			toast('初始化失败：' + e.message, true);
		}
	}

	init();
})();
