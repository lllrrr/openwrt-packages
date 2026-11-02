'use strict';

(function() {
	const $ = (selector) => document.querySelector(selector);
	const $$ = (selector) => Array.prototype.slice.call(document.querySelectorAll(selector));

	const SCHEDULE_MODES = [
		['daily', '每天'],
		['weekly', '每周'],
		['monthly', '每月'],
		['hourly', '每小时（整点）'],
		['half-hourly', '每 30 分钟'],
		['6h', '每 6 小时'],
		['12h', '每 12 小时'],
		['custom', '自定义']
	];

	const state = {
		authMode: 'login',
		tab: 'overview',
		status: null,
		standalone: null,
		coreTags: {},
		results: null,
		history: null,
		tasks: null,
		nodes: null,
		config: null,
		ipLists: [],
		workers: [],
		servers: {},
		csrf: '',
		logPos: 0,
		lastRunning: false,
		loggedIn: false,
		pollCount: 0,
		pollTimer: null,
		logTimer: null,
		toastTimer: null
	};

	function el(tag, attrs, children) {
		const node = document.createElement(tag);

		Object.keys(attrs || {}).forEach((key) => {
			const value = attrs[key];

			if (value == null)
				return;

			if (key === 'checked')
				node.checked = !!value;
			else if (key === 'value')
				node.value = value;
			else if (key === 'text')
				node.textContent = value;
			else if (key === 'class')
				node.className = value;
			else
				node.setAttribute(key, value);
		});

		(Array.isArray(children) ? children : (children == null ? [] : [children])).forEach((child) => {
			if (child == null)
				return;

			node.appendChild(typeof child === 'string' ? document.createTextNode(child) : child);
		});

		return node;
	}

	function setText(id, value) {
		const node = $('#' + id);

		if (node)
			node.textContent = value == null ? '' : value;
	}

	function setValue(id, value) {
		const node = $('#' + id);

		if (node)
			node.value = value == null ? '' : value;
	}

	function setCheck(id, value) {
		const node = $('#' + id);

		if (node)
			node.checked = value === true || value === 1 || value === '1';
	}

	function toast(message, bad) {
		const node = $('#toast');

		if (!node)
			return;

		node.textContent = message;
		node.classList.toggle('bad', !!bad);
		node.classList.remove('hidden');
		clearTimeout(state.toastTimer);
		state.toastTimer = setTimeout(() => node.classList.add('hidden'), 4200);
	}

	function fmtNumber(value, digits) {
		const number = Number(value);

		if (!Number.isFinite(number))
			return '—';

		return number.toFixed(digits == null ? 2 : digits);
	}

	function pad2(value) {
		return value < 10 ? '0' + value : '' + value;
	}

	function fmtDuration(seconds) {
		const total = Math.max(0, Math.floor(Number(seconds) || 0));
		const hours = Math.floor(total / 3600);
		const minutes = Math.floor((total % 3600) / 60);
		const rest = total % 60;

		if (hours > 0)
			return hours + 'h ' + pad2(minutes) + 'm ' + pad2(rest) + 's';
		if (minutes > 0)
			return minutes + 'm ' + pad2(rest) + 's';
		return rest + 's';
	}

	function phaseLabel(phase) {
		switch (phase) {
		case 'starting': return '启动中';
		case 'testing': return '测速中';
		case 'stopping': return '正在停止';
		case 'committing': return '正在写入结果';
		default: return '空闲';
		}
	}

	// The console can be served at the root (direct :17544) or behind a
	// reverse-proxy path prefix (e.g. Caddy `handle_path /CF/*`).  Resolve
	// assets and the CGI relative to the page's directory so both work.
	function apiBase() {
		let path = window.location.pathname || '/';

		if (path.charAt(path.length - 1) != '/')
			path = path.substring(0, path.lastIndexOf('/') + 1);

		return path || '/';
	}

	async function api(action, options) {
		options = options || {};

		const params = new URLSearchParams({ action: action });

		Object.keys(options.query || {}).forEach((key) => {
			params.set(key, options.query[key]);
		});

		const isPost = options.method === 'POST';

		if (isPost && state.csrf)
			params.set('csrf', state.csrf);

		const headers = {};
		let body;

		if (options.body !== undefined) {
			headers['Content-Type'] = 'application/json';
			body = JSON.stringify(options.body);
		}

		const response = await fetch(apiBase() + 'cgi-bin/api?' + params.toString(), {
			method: options.method || 'GET',
			headers: headers,
			body: body,
			credentials: 'same-origin',
			cache: 'no-store'
		});

		let payload;

		try {
			payload = await response.json();
		}
		catch (e) {
			payload = { ok: false, error: '响应解析失败' };
		}

		if (response.status === 401 && action !== 'hello' && action !== 'login' && action !== 'setup')
			showAuth('login');

		if (!response.ok || payload.ok !== true)
			throw new Error(payload.error || ('HTTP ' + response.status));

		return payload.data;
	}

	function storageGet(key) {
		try { return localStorage.getItem(key); }
		catch (e) { return null; }
	}

	function storageSet(key, value) {
		try { localStorage.setItem(key, value); }
		catch (e) { /* private mode */ }
	}

	function clearTimers() {
		clearInterval(state.pollTimer);
		clearInterval(state.logTimer);
		state.pollTimer = null;
		state.logTimer = null;
	}

	function showAuth(mode) {
		state.authMode = mode;
		state.loggedIn = false;
		state.csrf = '';
		clearTimers();
		$('#app-view').classList.add('hidden');
		$('#auth-view').classList.remove('hidden');

		setText('auth-title', mode === 'setup' ? '创建管理员账号' : '登录操作台');
		setText('auth-desc', mode === 'setup'
			? '首次使用，请设置操作台管理员账号和密码。'
			: '输入管理员账号进入操作台。');
		$('#auth-confirm-row').classList.toggle('hidden', mode !== 'setup');
		$('#auth-submit').textContent = mode === 'setup' ? '创建并登录' : '登录';
		$('#auth-error').textContent = '';
		$('#auth-password').value = '';
		$('#auth-confirm').value = '';
		$('#auth-user').value = storageGet('cfpick_web_user') || 'admin';
		$('#auth-password').focus();
	}

	async function onAuthSubmit(event) {
		event.preventDefault();

		const user = $('#auth-user').value.trim();
		const password = $('#auth-password').value;
		const confirm = $('#auth-confirm').value;
		const error = $('#auth-error');
		const button = $('#auth-submit');

		error.textContent = '';

		if (!user) {
			error.textContent = '请输入用户名';
			return;
		}

		if (!password) {
			error.textContent = '请输入密码';
			return;
		}

		if (state.authMode === 'setup') {
			if (password.length < 6) {
				error.textContent = '密码至少 6 位';
				return;
			}

			if (password !== confirm) {
				error.textContent = '两次输入的密码不一致';
				return;
			}
		}

		button.disabled = true;

		try {
			const data = await api(state.authMode, { method: 'POST', body: { user: user, password: password } });
			state.csrf = data.csrf || '';
			storageSet('cfpick_web_user', user);
			await showApp();
		}
		catch (e) {
			error.textContent = e.message;
		}
		finally {
			button.disabled = false;
		}
	}

	async function showApp() {
		state.loggedIn = true;
		$('#auth-view').classList.add('hidden');
		$('#app-view').classList.remove('hidden');
		clearTimers();
		state.pollCount = 0;
		state.logPos = 0;
		$('#log-view').textContent = '';

		await refreshAll();

		if (!state.loggedIn)
			return;

		try { await fetchLog(false); }
		catch (e) { /* log is optional */ }

		activateTab('overview');

		state.pollTimer = setInterval(poll, 3000);
		state.logTimer = setInterval(() => {
			if (state.tab === 'logs' && $('#log-follow').checked)
				fetchLog(true).catch(() => {});
		}, 6000);
	}

	async function refreshAll() {
		const results = await Promise.allSettled([
			refreshStatus(),
			refreshResults(),
			refreshHistory(),
			refreshTasks(),
			refreshNodes(),
			refreshStandalone(),
			loadConfig()
		]);

		const errors = results
			.filter((result) => result.status === 'rejected')
			.map((result) => result.reason && result.reason.message)
			.filter((message) => !!message);

		if (errors.length)
			toast(errors[0], true);
	}

	async function refreshStatus() {
		state.status = await api('status');
		renderStatus();
	}

	function renderStatus() {
		const status = state.status || {};
		const running = !!status.running;
		const best = status.best;

		state.lastRunning = running;

		const dot = $('#status-dot');
		dot.classList.toggle('running', running);
		dot.classList.toggle('error', !running && status.phase === 'failed');

		setText('st-state', running ? phaseLabel(status.phase) : '空闲');
		setText('st-elapsed', running
			? '已运行 ' + fmtDuration(status.elapsed)
			: (status.last_time ? '上次 ' + status.last_time : '—'));
		setText('st-best', best && best.ip ? best.ip : '—');
		setText('st-best-meta', best
			? fmtNumber(best.latency) + ' ms · ' +
				(best.speed > 0 ? fmtNumber(best.speed) + ' MB/s' : '未做下载实测') +
				(best.node ? ' · ' + best.node : '')
			: '—');
		setText('st-cron', status.cron ? '已启用' : '未启用');
		setText('st-last', status.last_time ? '上次 ' + status.last_time : '—');
		setText('st-workers', (status.node_count || 0) + ' / ' + (status.result_rows || 0) + ' 条');

		setText('status-text', running
			? phaseLabel(status.phase) + ' · ' + fmtDuration(status.elapsed)
			: '空闲 · ' + (status.last_time || '尚未测速'));

		$('#btn-start').disabled = running;
		$('#btn-retest').disabled = running;
		$('#btn-stop').disabled = !running;
	}

	// ── 独立内核模式（统一测速使用 mihomo / Xray） ─────────────────
	async function refreshStandalone() {
		state.standalone = await api('standalone');
		renderStandalone();
	}

	const CORE_LABELS = {
		mihomo: 'mihomo（Clash.Meta）',
		xray: 'Xray-core'
	};

	function coreBadge(type, info, selected) {
		if (type === selected)
			return el('span', { class: 'badge info' },
				info.installed ? '当前使用' : '当前使用 · 未安装');

		if (info.installed)
			return el('span', { class: 'badge ok' }, '已安装');

		return el('span', { class: 'badge bad' }, '未安装');
	}

	function renderStandaloneCoreCards(data) {
		const container = $('#sa-core-cards');
		if (!container)
			return;

		// Keep the version tags the user is typing; the card list is rebuilt
		// after every refresh and while an update is polling.
		$$('#sa-core-cards input[data-core-tag]').forEach((input) => {
			state.coreTags[input.dataset.coreTag] = input.value;
		});

		container.replaceChildren();

		const cores = (data.cores && data.cores.cores) || {};
		const selected = data.core === 'mihomo' ? 'mihomo' : 'xray';
		const updating = !!data.updating;
		const updatingType = data.updating_type || '';

		['mihomo', 'xray'].forEach((type) => {
			const info = cores[type] || {};

			const tag = el('input', {
				type: 'text',
				placeholder: '版本标签，留空 = 最新版',
				spellcheck: 'false'
			});
			tag.dataset.coreTag = type;
			tag.value = state.coreTags[type] || '';
			tag.addEventListener('input', () => { state.coreTags[type] = tag.value; });

			const update = el('button', { type: 'button', class: 'btn small primary' },
				(updating && updatingType === type) ? '更新中…' : (info.installed ? '升级' : '安装'));
			update.disabled = updating;
			update.addEventListener('click', () => updateStandaloneCore(type, tag.value.trim()));

			const source = info.managed ? '托管（可自动升级）'
				: (info.installed ? '系统自带' : '—');

			container.appendChild(el('div', { class: 'card stat core-card' }, [
				el('div', { class: 'core-card-head' }, [
					el('h2', {}, CORE_LABELS[type]),
					coreBadge(type, info, selected)
				]),
				el('dl', { class: 'kv' }, [
					el('dt', {}, '版本'), el('dd', { class: 'mono' }, info.version || '—'),
					el('dt', {}, '路径'), el('dd', { class: 'mono' }, info.path || '—'),
					el('dt', {}, '来源'), el('dd', {}, source)
				]),
				el('div', { class: 'core-update-row' }, [tag, update])
			]));
		});
	}

	function renderStandalone() {
		const data = state.standalone || {};
		const enabled = !!data.enabled;
		const core = data.core === 'mihomo' ? 'mihomo' : 'xray';

		const enable = $('#sa-enabled');
		if (enable)
			enable.checked = enabled;

		const select = $('#sa-core-select');
		if (select)
			select.value = core;

		renderStandaloneCoreCards(data);

		const updating = !!data.updating;
		setText('sa-update-message', updating ? '内核更新中…' : '—');

		const log = $('#sa-update-log');
		if (log)
			log.textContent = data.update_log || '';
	}

	async function saveStandalone() {
		const enabled = $('#sa-enabled').checked;
		const core = $('#sa-core-select').value === 'mihomo' ? 'mihomo' : 'xray';

		try {
			await api('standalone_save', {
				method: 'POST',
				body: { enabled: enabled, core: core }
			});
			toast('独立测速设置已保存');
			await refreshStandalone();
		}
		catch (e) {
			toast(e.message || '保存失败', true);
		}
	}

	async function updateStandaloneCore(type, tag) {
		try {
			const result = await api('standalone_update_core', {
				method: 'POST',
				body: { type: type, tag: tag || '' }
			});

			if (result && result.busy)
				toast('内核正在更新，请稍候', true);
			else
				toast('已开始更新 ' + type);

			await refreshStandalone();
		}
		catch (e) {
			toast(e.message || '更新失败', true);
		}
	}

	async function refreshResults() {
		state.results = await api('results', { query: { limit: 500 } });
		renderResults();
	}

	function renderResults() {
		const body = $('#result-body');
		const payload = state.results || {};
		const rows = payload.rows || [];
		const total = payload.total || rows.length;
		const seen = {};

		body.replaceChildren();

		if (!rows.length) {
			body.appendChild(el('tr', {}, [el('td', { colspan: '6', class: 'empty' }, '暂无结果')]));
			return;
		}

		rows.forEach((row) => {
			const best = !seen[row.node];
			seen[row.node] = true;

			body.appendChild(el('tr', { class: best ? 'best' : '' }, [
				el('td', {}, row.node || ''),
				el('td', { class: 'mono' }, row.ip || ''),
				el('td', {}, fmtNumber(row.latency) + ' ms'),
				el('td', {}, fmtNumber((row.loss || 0) * 100) + '%'),
				el('td', {}, row.speed > 0 ? fmtNumber(row.speed) + ' MB/s' : '—'),
				el('td', {}, row.region || '')
			]));
		});

		if (total > rows.length) {
			body.appendChild(el('tr', {}, [
				el('td', { colspan: '6', class: 'empty' },
					'仅显示前 ' + rows.length + ' 条，共 ' + total + ' 条')
			]));
		}
	}

	async function refreshHistory() {
		state.history = await api('history');
		renderHistory();
	}

	function renderHistory() {
		const body = $('#history-body');
		const runs = ((state.history && state.history.history) || []).slice(0, 12);

		body.replaceChildren();

		if (!runs.length) {
			body.appendChild(el('tr', {}, [el('td', { colspan: '5', class: 'empty' }, '暂无历史')]));
			return;
		}

		runs.forEach((run) => {
			body.appendChild(el('tr', {}, [
				el('td', {}, run.time || ''),
				el('td', { class: 'mono' }, run.ip || ''),
				el('td', {}, fmtNumber(run.latency) + ' ms'),
				el('td', {}, run.speed > 0 ? fmtNumber(run.speed) + ' MB/s' : '—'),
				el('td', {}, run.region || '')
			]));
		});
	}

	async function refreshTasks() {
		state.tasks = await api('tasks');
		renderTasks();
	}

	// ── structured schedule editor ─────────────────────────────────────
	// The task UI edits a frequency + fixed time instead of a raw five-field
	// cron string; anything the presets cannot express is shown as 自定义.
	function cronPartsOf(expression) {
		const parts = normalizeCronText(expression).trim().split(/\s+/).filter(Boolean);

		if (parts.length && parts[0].charAt(0) === '@')
			return { alias: parts[0], parts: [parts[0], '', '', '', ''] };

		while (parts.length < 5)
			parts.push('*');

		return { alias: '', parts: parts.slice(0, 5) };
	}

	function cronNumber(value) {
		return /^\d+$/.test(value) ? String(parseInt(value, 10)) : null;
	}

	function detectSchedule(expression) {
		const parsed = cronPartsOf(expression);
		const parts = parsed.parts;

		if (parsed.alias)
			return { mode: 'custom', raw: parsed.alias };

		const minute = cronNumber(parts[0]);
		const hour = cronNumber(parts[1]);
		const day = cronNumber(parts[2]);
		const weekday = cronNumber(parts[4]);
		const dailyTail = parts[2] === '*' && parts[3] === '*' && parts[4] === '*';

		if (parts[0] === '0' && parts[1] === '*' && dailyTail)
			return { mode: 'hourly' };
		if (parts[0] === '*/30' && parts[1] === '*' && dailyTail)
			return { mode: 'half-hourly' };
		if (parts[0] === '0' && parts[1] === '*/6' && dailyTail)
			return { mode: '6h' };
		if (parts[0] === '0' && parts[1] === '*/12' && dailyTail)
			return { mode: '12h' };
		if (minute != null && hour != null && dailyTail)
			return { mode: 'daily', minute: minute, hour: hour };
		if (minute != null && hour != null && parts[2] === '*' && parts[3] === '*' && weekday != null)
			return { mode: 'weekly', minute: minute, hour: hour,
				weekday: weekday === '7' ? '0' : weekday };
		if (minute != null && hour != null && day != null && parts[3] === '*' && parts[4] === '*')
			return { mode: 'monthly', minute: minute, hour: hour, day: day };

		return { mode: 'custom', raw: parts.join(' ') };
	}

	function buildScheduleEditor(expression) {
		const detected = detectSchedule(expression);
		const editor = el('span', { class: 'schedule-editor' });

		const mode = el('select', { class: 'sched-mode' });
		SCHEDULE_MODES.forEach(([value, label]) => {
			mode.appendChild(el('option', { value: value }, label));
		});
		mode.value = detected.mode;

		const time = el('input', { type: 'time', class: 'sched-time' });
		time.value = (detected.hour != null)
			? pad2(parseInt(detected.hour, 10)) + ':' + pad2(parseInt(detected.minute, 10))
			: '03:00';

		const weekday = el('select', { class: 'sched-weekday' });
		[['1', '周一'], ['2', '周二'], ['3', '周三'], ['4', '周四'],
			['5', '周五'], ['6', '周六'], ['0', '周日']].forEach(([value, label]) => {
			weekday.appendChild(el('option', { value: value }, label));
		});
		weekday.value = detected.weekday || '1';

		const day = el('input', { type: 'number', class: 'sched-day', min: '1', max: '31' });
		day.value = detected.day || '1';

		const custom = el('input', { type: 'text', class: 'sched-custom mono', spellcheck: 'false' });
		custom.value = detected.raw || normalizeCronText(expression).trim() || '0 3 * * *';

		editor.appendChild(mode);
		editor.appendChild(time);
		editor.appendChild(weekday);
		editor.appendChild(day);
		editor.appendChild(custom);

		function sync() {
			const value = mode.value;
			const timed = value === 'daily' || value === 'weekly' || value === 'monthly';

			time.classList.toggle('hidden', !timed);
			weekday.classList.toggle('hidden', value !== 'weekly');
			day.classList.toggle('hidden', value !== 'monthly');
			custom.classList.toggle('hidden', value !== 'custom');
		}

		mode.addEventListener('change', sync);
		sync();

		function value() {
			const selected = mode.value;

			if (selected === 'hourly')
				return '0 * * * *';
			if (selected === 'half-hourly')
				return '*/30 * * * *';
			if (selected === '6h')
				return '0 */6 * * *';
			if (selected === '12h')
				return '0 */12 * * *';
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
		}

		editor._scheduleValue = value;

		return editor;
	}

	function mountScheduleEditor(id, expression) {
		const host = $('#' + id);
		if (!host)
			return;

		const editor = buildScheduleEditor(expression || '0 3 * * *');
		host.replaceChildren(editor);
		host._scheduleValue = editor._scheduleValue;
	}

	function scheduleExpression(id) {
		const host = $('#' + id);

		return (host && typeof host._scheduleValue === 'function')
			? host._scheduleValue() : '';
	}

	async function saveTask(entry, schedule, enabled) {
		try {
			state.tasks = await api('task_save', {
				method: 'POST',
				body: {
					source: entry.source,
					line: entry.line,
					schedule: schedule,
					enabled: enabled
				}
			});
			renderTasks();
			await refreshStatus();
			toast(enabled ? '定时任务已保存并启用' : '定时任务已保存并停用');
		}
		catch (e) {
			toast(e.message, true);
			await refreshTasks().catch(() => {});
		}
	}

	async function deleteTask(entry) {
		if (!confirm('删除定时任务？\n\n' + (entry.schedule || '') + ' ' + (entry.command || '')))
			return;

		try {
			state.tasks = await api('task_delete', {
				method: 'POST',
				body: { source: entry.source, line: entry.line }
			});
			renderTasks();
			await refreshStatus();
			toast('定时任务已删除');
		}
		catch (e) {
			toast(e.message, true);
			await refreshTasks().catch(() => {});
		}
	}

	async function addTask(scheduleId, modeId) {
		const schedule = scheduleExpression(scheduleId);
		const mode = textValue(modeId) || 'retest';
		const script = (state.tasks && state.tasks.run_script) ||
			'/usr/lib/cfpick/bin/cfpick.sh';

		if (!schedule) {
			toast('请填写计划表达式', true);
			return;
		}

		try {
			state.tasks = await api('task_add', {
				method: 'POST',
				body: {
					source: (state.tasks && state.tasks.writable) || '/etc/crontabs/root',
					schedule: schedule,
					command: script + ' ' + mode
				}
			});
			renderTasks();
			await refreshStatus();
			toast('定时任务已添加');
		}
		catch (e) {
			toast(e.message, true);
		}
	}

	// The same task list is shown on the Overview and Settings tabs; keep both
	// in sync after any save/delete/add.
	function renderTasks() {
		['#task-body', '#cfg-task-body'].forEach(renderTaskBody);
	}

	function renderTaskBody(selector) {
		const body = $(selector);
		if (!body)
			return;

		const entries = (state.tasks && state.tasks.entries) || [];

		body.replaceChildren();

		if (!entries.length) {
			body.appendChild(el('tr', {}, [el('td', { colspan: '5', class: 'empty' }, '暂无本插件相关的定时任务')]));
			return;
		}

		entries.forEach((entry) => {
			// The list only carries this plugin's lines; /etc/crontab entries
			// are still shown read-only because that file has a user column.
			const editable = !!entry.writable;

			const enabled = el('input', { type: 'checkbox', checked: !entry.disabled });
			enabled.disabled = !editable;

			const schedule = buildScheduleEditor(entry.schedule || '0 3 * * *');
			schedule.querySelectorAll('select, input').forEach((node) => {
				node.disabled = !editable;
			});

			const save = el('button', { type: 'button', class: 'btn small primary' }, '保存');
			save.disabled = !editable;
			save.addEventListener('click', () => saveTask(entry, schedule._scheduleValue(), enabled.checked));

			const remove = el('button', { type: 'button', class: 'btn small danger' }, '删除');
			remove.disabled = !editable;
			remove.addEventListener('click', () => deleteTask(entry));

			const badge = entry.managed ? '设置页维护' : '';

			body.appendChild(el('tr', { class: entry.managed ? 'best' : '' }, [
				el('td', {}, enabled),
				el('td', {}, schedule),
				el('td', { class: 'cmd' }, [
					entry.command || '',
					badge ? el('span', { class: 'task-badge' }, badge) : null
				]),
				el('td', {}, entry.source || ''),
				el('td', {}, [el('div', { class: 'task-actions' }, [save, remove])])
			]));
		});
	}

	async function fetchLog(append) {
		const data = await api('log', { query: { pos: state.logPos } });
		const view = $('#log-view');

		if (data.content) {
			view.textContent = ((append ? view.textContent : '') + data.content).slice(-524288);
			view.scrollTop = view.scrollHeight;
		}

		if (data.pos != null)
			state.logPos = parseInt(data.pos, 10) || state.logPos;
	}

	async function poll() {
		try {
			const wasRunning = state.lastRunning;

			await refreshStatus();

			if (wasRunning && !state.lastRunning) {
				await Promise.all([
					refreshResults().catch(() => {}),
					refreshHistory().catch(() => {}),
					refreshTasks().catch(() => {})
				]);
			}

			state.pollCount += 1;

			if (state.tab === 'logs' && $('#log-follow').checked && state.pollCount % 2 === 0)
				await fetchLog(true);

			// Only poll this tab while a core update is running; otherwise a
			// rebuild every few seconds would steal focus from the inputs.
			if (state.tab === 'standalone' && state.standalone && state.standalone.updating)
				await refreshStandalone().catch(() => {});
		}
		catch (e) {
			/* 401 handled by api(); transient errors are ignored until the next poll */
		}
	}

	async function runAction(action, message) {
		const buttons = ['#btn-start', '#btn-retest', '#btn-stop'].map((id) => $(id));

		buttons.forEach((button) => { button.disabled = true; });

		try {
			await api(action, { method: 'POST', body: {} });
			toast(message);
			await refreshStatus();
		}
		catch (e) {
			toast(e.message, true);
		}
		finally {
			renderStatus();
		}
	}

	function provider(name) {
		return (state.nodes && state.nodes[name]) || {};
	}

	function providerNodes(name) {
		return provider(name).nodes || [];
	}

	function providerExists(name) {
		return !!provider(name).exists;
	}

	async function refreshNodes() {
		state.nodes = await api('nodes');
		const g = (state.config && state.config.global) || {};
		fillNodeSelects(g.node_test_node || '', g.stable_node || '');
		renderWorkers();
		fillThirdParty();
	}

	function fillNodeSelects(testValue, stableValue) {
		const nodes = providerNodes('passwall');
		const selects = [
			['cfg-test-node', testValue],
			['cfg-stable-node', stableValue]
		];

		selects.forEach(([id, value]) => {
			const select = $('#' + id);
			if (!select)
				return;

			select.replaceChildren(el('option', { value: '' }, '-- 请选择 --'));

			let found = false;

			nodes.forEach((node) => {
				if (!node.value)
					return;

				const label = node.label + (String(node.type || '').toLowerCase() === 'socks'
					? '（socks，不能测速）' : '');
				select.appendChild(el('option', { value: node.value }, label));

				if (node.value === value)
					found = true;
			});

			if (value && !found)
				select.appendChild(el('option', { value: value }, value));

			select.value = value || '';
		});
	}

	function renderWorkers() {
		const body = $('#cfg-workers-body');
		if (!body)
			return;

		body.replaceChildren();

		if (!state.workers.length) {
			body.appendChild(el('tr', {}, [
				el('td', { colspan: '4', class: 'empty' },
					'暂无 worker；测速将使用上面的「单节点测速」')
			]));
			return;
		}

		const nodes = providerNodes('passwall');

		state.workers.forEach((worker, index) => {
			const nodeSelect = el('select');
			nodeSelect.appendChild(el('option', { value: '' }, '-- 请选择 --'));

			const seen = {};

			nodes.forEach((node) => {
				if (!node.value || seen[node.value])
					return;

				seen[node.value] = true;
				nodeSelect.appendChild(el('option', { value: node.value },
					node.label + (String(node.type || '').toLowerCase() === 'socks' ? '（socks）' : '')));
			});

			if (worker.node && !seen[worker.node])
				nodeSelect.appendChild(el('option', { value: worker.node }, worker.node));

			nodeSelect.value = worker.node || '';
			nodeSelect.addEventListener('change', () => { worker.node = nodeSelect.value; });

			const listSelect = el('select');
			listSelect.appendChild(el('option', { value: '' }, '默认（第一个启用）'));

			for (let i = 1; i <= 5; i++) {
				const name = (state.ipLists[i - 1] && state.ipLists[i - 1].name) || '';
				listSelect.appendChild(el('option', { value: 'list' + i },
					'list' + i + (name ? ': ' + name : '')));
			}

			if (worker.ip_list && !/^list[1-5]$/.test(worker.ip_list))
				listSelect.appendChild(el('option', { value: worker.ip_list }, worker.ip_list));

			listSelect.value = worker.ip_list || '';
			listSelect.addEventListener('change', () => { worker.ip_list = listSelect.value; });

			const ddnsInput = el('input', {
				type: 'text',
				placeholder: '留空 = 写回 passwall',
				spellcheck: 'false'
			});
			ddnsInput.value = worker.ddns_domain || '';
			ddnsInput.addEventListener('input', () => {
				worker.ddns_domain = ddnsInput.value.trim();
			});

			const remove = el('button', { type: 'button', 'class': 'btn small danger' }, '删除');
			remove.addEventListener('click', () => {
				state.workers.splice(index, 1);
				renderWorkers();
			});

			body.appendChild(el('tr', {}, [
				el('td', {}, nodeSelect),
				el('td', {}, listSelect),
				el('td', {}, ddnsInput),
				el('td', {}, remove)
			]));
		});
	}

	function addWorker() {
		state.workers.push({ node: '', ip_list: '', ddns_domain: '' });
		renderWorkers();
	}

	function fillMulti(id, nodes, values) {
		const select = $('#' + id);
		if (!select)
			return;

		const wanted = new Set((values || []).map((value) => String(value)));
		const seen = {};

		select.replaceChildren();

		nodes.forEach((node) => {
			if (!node.value || seen[node.value])
				return;

			seen[node.value] = true;

			const option = el('option', { value: node.value },
				node.label + (String(node.type || '').toLowerCase() === 'socks' ? '（socks）' : ''));
			option.selected = wanted.has(String(node.value));
			select.appendChild(option);
		});

		wanted.forEach((value) => {
			if (!seen[value]) {
				const option = el('option', { value: value }, value);
				option.selected = true;
				select.appendChild(option);
			}
		});
	}

	function fillThirdParty() {
		const servers = (state.config && state.config.servers) || {};

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

		if (state.nodes) {
			['ssr', 'passwall2', 'bypass', 'vssr'].forEach((name) => {
				const card = $('#tp-' + name);
				if (card)
					card.classList.toggle('hidden', !providerExists(name));
			});

			const passwallCard = $('#tp-passwall');
			if (passwallCard)
				passwallCard.classList.toggle('hidden', !providerExists('passwall'));
		}
	}

	async function loadConfig() {
		state.config = await api('config');
		state.ipLists = ((state.config && state.config.ip_lists) || []).map((item) => ({
			enabled: !!item.enabled,
			name: item.name || '',
			regions: item.regions || '',
			port: item.port || '443'
		}));

		while (state.ipLists.length < 5)
			state.ipLists.push({ enabled: false, name: '', regions: '', port: '443' });

		state.workers = ((state.config && state.config.workers) || []).map((item) => ({
			node: item.node || '',
			ip_list: item.ip_list || '',
			ddns_domain: item.ddns_domain || ''
		}));
		state.servers = (state.config && state.config.servers) || {};

		fillConfig();
	}

	function fillConfig() {
		const g = (state.config && state.config.global) || {};

		setValue('cfg-ip-source', g.ip_source || 'builtin_ipv4');
		setValue('cfg-ip-online-url', g.ip_online_url);
		setValue('cfg-custom-ip-file', g.custom_ip_file);
		setCheck('cfg-custom-allip', g.custom_allip);
		setValue('cfg-tl', g.tl);
		setValue('cfg-tll', g.tll);
		setValue('cfg-tlr', g.tlr);
		setValue('cfg-test-count', g.node_test_count);
		setValue('cfg-test-timeout', g.node_test_timeout);
		setValue('cfg-test-probes', g.node_test_probes);
		setValue('cfg-test-threads', g.node_test_threads);
		setValue('cfg-test-url', g.node_test_url);
		setCheck('cfg-dl-enabled', g.download_test_enabled);
		setValue('cfg-dl-count', g.download_test_count);
		setValue('cfg-dl-url', g.download_test_url);
		setValue('cfg-dl-time', g.download_test_time);
		setCheck('cfg-iter-enabled', g.iterate_enabled);
		setValue('cfg-iter-minutes', g.iterate_minutes);
		setCheck('cfg-ddns-enabled', g.ddns_enabled);
		setValue('cfg-ddns-count', g.ddns_ip_count);
		setValue('cfg-ddns-ttl', g.ddns_ttl);
		setValue('cfg-ddns-token', g.ddns_api_token);
		setValue('cfg-ddns-zone-id', g.ddns_zone_id);
		setValue('cfg-ddns-zone-name', g.ddns_zone_name);
		setCheck('cfg-ddns-proxied', g.ddns_proxied);
		renderIpLists();
		fillNodeSelects(g.node_test_node || '', g.stable_node || '');
		renderWorkers();
		fillThirdParty();
		updateSourceVisibility();
	}

	// Normalize full-width digits/spaces from Chinese IMEs before sending a
	// schedule to the API.
	function normalizeCronText(value) {
		return String(value || '')
			.replace(/[！-～]/g, (ch) => String.fromCharCode(ch.charCodeAt(0) - 0xFEE0))
			.replace(/　/g, ' ');
	}

	function renderIpLists() {
		const body = $('#cfg-iplists-body');
		if (!body)
			return;

		body.replaceChildren();

		state.ipLists.forEach((item) => {
			const enabled = el('input', { type: 'checkbox', checked: !!item.enabled });
			const name = el('input', { type: 'text', value: item.name || '', placeholder: '名称' });
			const regions = el('input', { type: 'text', class: 'regions', value: item.regions || '', placeholder: 'JP SG KR' });
			const port = el('input', { type: 'number', value: item.port || '443', min: '1', max: '65535' });

			enabled.addEventListener('change', () => { item.enabled = enabled.checked; });
			name.addEventListener('input', () => { item.name = name.value; });
			regions.addEventListener('input', () => { item.regions = regions.value; });
			port.addEventListener('input', () => { item.port = port.value; });

			body.appendChild(el('tr', {}, [
				el('td', {}, enabled),
				el('td', {}, name),
				el('td', {}, regions),
				el('td', {}, port)
			]));
		});
	}

	function textValue(id) {
		const node = $('#' + id);
		return node ? node.value.trim() : '';
	}

	function numberValue(id, fallback) {
		const value = parseFloat(textValue(id));
		return Number.isFinite(value) ? value : fallback;
	}

	function intValue(id, fallback) {
		return Math.round(numberValue(id, fallback));
	}

	function checkValue(id) {
		const node = $('#' + id);
		return !!(node && node.checked);
	}

	function selectedValues(id) {
		const select = $('#' + id);

		if (!select)
			return [];

		return Array.prototype.slice.call(select.selectedOptions || [])
			.map((option) => option.value)
			.filter((value) => !!value);
	}

	function collectConfig() {
		if (!state.config)
			throw new Error('配置尚未加载完成');

		const stableNode = textValue('cfg-stable-node');

		if (!stableNode)
			throw new Error('请选择稳定节点（测速期间用于承载实流量）');

		// The schedule is edited in the task list, which writes UCI for the
		// managed "start" line.  Reuse its current values so saving the rest
		// of the settings page does not restore a stale schedule.
		const globalCfg = (state.config && state.config.global) || {};
		const managed = (state.tasks && state.tasks.managed) || null;
		const cron = normalizeCronText((managed && managed.schedule) ||
			globalCfg.custom_cron || '0 3 * * *');

		if (!/^([0-9A-Za-z*,/-]+\s+){4}[0-9A-Za-z*,/-]+$/.test(cron) &&
			!/^@(reboot|hourly|daily|weekly|monthly|yearly|annually|midnight)$/.test(cron))
			throw new Error('主任务计划无效，请在定时任务列表中修正');

		return {
			global: {
				enabled: managed ? managed.enabled : (globalCfg.enabled === '1'),
				ip_source: textValue('cfg-ip-source') || 'builtin_ipv4',
				ip_online_url: textValue('cfg-ip-online-url'),
				custom_ip_file: textValue('cfg-custom-ip-file'),
				custom_allip: checkValue('cfg-custom-allip'),
				tl: intValue('cfg-tl', 0),
				tll: intValue('cfg-tll', 40),
				tlr: numberValue('cfg-tlr', 0.2),
				node_test_url: textValue('cfg-test-url'),
				node_test_count: intValue('cfg-test-count', 30),
				node_test_timeout: intValue('cfg-test-timeout', 5),
				node_test_probes: intValue('cfg-test-probes', 3),
				node_test_threads: intValue('cfg-test-threads', 5),
				download_test_enabled: checkValue('cfg-dl-enabled'),
				download_test_count: intValue('cfg-dl-count', 5),
				download_test_url: textValue('cfg-dl-url'),
				download_test_time: intValue('cfg-dl-time', 10),
				iterate_enabled: checkValue('cfg-iter-enabled'),
				iterate_minutes: intValue('cfg-iter-minutes', 30),
				ddns_enabled: checkValue('cfg-ddns-enabled'),
				ddns_ip_count: intValue('cfg-ddns-count', 1),
				ddns_ttl: intValue('cfg-ddns-ttl', 300),
				ddns_api_token: textValue('cfg-ddns-token'),
				ddns_zone_id: textValue('cfg-ddns-zone-id'),
				ddns_zone_name: textValue('cfg-ddns-zone-name'),
				ddns_proxied: checkValue('cfg-ddns-proxied'),
				custom_cron_enabled: true,
				custom_cron: cron,
				hour: 24,
				node_test_node: textValue('cfg-test-node'),
				stable_node: stableNode
			},
			ip_lists: state.ipLists.slice(0, 5).map((item) => ({
				enabled: !!item.enabled,
				name: item.name || '',
				regions: item.regions || '',
				port: parseInt(item.port, 10) || 443
			})),
			workers: state.workers
				.filter((item) => !!String(item.node || '').trim())
				.map((item) => ({
					node: String(item.node).trim(),
					ip_list: item.ip_list || '',
					ddns_domain: String(item.ddns_domain || '').trim()
				})),
			servers: {
				ssr_enabled: checkValue('tp-ssr-enabled'),
				ssr_services: selectedValues('tp-ssr-services'),
				passwall_enabled: checkValue('tp-passwall-enabled'),
				passwall2_enabled: checkValue('tp-passwall2-enabled'),
				passwall2_services: selectedValues('tp-passwall2-services'),
				bypass_enabled: checkValue('tp-bypass-enabled'),
				bypass_services: selectedValues('tp-bypass-services'),
				vssr_enabled: checkValue('tp-vssr-enabled'),
				vssr_services: selectedValues('tp-vssr-services'),
				HOST_enabled: checkValue('tp-host-enabled'),
				host_domain: textValue('tp-host-domain'),
				DNS_enabled: checkValue('tp-dns-enabled'),
				DNS_type: textValue('tp-dns-type') || 'aliyun',
				app_key: textValue('tp-app-key'),
				app_secret: textValue('tp-app-secret'),
				main_domain: textValue('tp-main-domain'),
				sub_domain: textValue('tp-sub-domain'),
				line: textValue('tp-dns-line') || 'default',
				AliDNS_ip_count: intValue('tp-alidns-count', 1),
				MosDNS_enabled: checkValue('tp-mosdns-enabled'),
				MosDNS_ip_count: intValue('tp-mosdns-count', 1),
				openclash_restart: checkValue('tp-openclash'),
				AstraDNS_enabled: checkValue('tp-astra-enabled'),
				AstraDNS_config: textValue('tp-astra-config'),
				AstraDNS_bin: textValue('tp-astra-bin')
			}
		};
	}

	async function saveConfig() {
		try {
			const body = collectConfig();
			await api('config', { method: 'POST', body: body });
			await loadConfig();
			await refreshNodes();
			await refreshStatus();
			await refreshTasks();
			toast('配置已保存');
		}
		catch (e) {
			toast(e.message, true);
		}
	}

	async function changePassword(event) {
		event.preventDefault();

		const current = $('#cfg-auth-current').value;
		const next = $('#cfg-auth-new').value;
		const confirm = $('#cfg-auth-confirm').value;

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
			await api('password', { method: 'POST', body: { current: current, next: next } });
			$('#auth-password').value = '';
			$('#cfg-auth-current').value = '';
			$('#cfg-auth-new').value = '';
			$('#cfg-auth-confirm').value = '';
			toast('密码已更新，请重新登录');
			showAuth('login');
		}
		catch (e) {
			toast(e.message, true);
		}
	}

	async function logout() {
		try {
			await api('logout', { method: 'POST', body: {} });
		}
		catch (e) {
			/* ignore */
		}

		clearTimers();
		state.status = null;
		state.lastRunning = false;
		state.csrf = '';
		showAuth('login');
	}

	function activateTab(name) {
		state.tab = name;
		$$('.tab').forEach((tab) => tab.classList.toggle('active', tab.dataset.tab === name));
		$$('.pane').forEach((pane) => pane.classList.toggle('active', pane.id === 'pane-' + name));

		if (name === 'logs')
			fetchLog(true).catch(() => {});

		if (name === 'standalone')
			refreshStandalone().catch(() => {});
	}

	function updateSourceVisibility() {
		const source = $('#cfg-ip-source').value;

		$('#row-ip-online').classList.toggle('hidden', source !== 'online');
		$('#row-custom-file').classList.toggle('hidden', source !== 'custom_file');
		$('#row-custom-allip').classList.toggle('hidden', source !== 'custom_file');
	}

	function bindEvents() {
		$('#auth-form').addEventListener('submit', onAuthSubmit);
		$('#password-form').addEventListener('submit', changePassword);
		$('#btn-logout').addEventListener('click', logout);

		$('#tabs').addEventListener('click', (event) => {
			const tab = event.target.closest('.tab');
			if (tab)
				activateTab(tab.dataset.tab);
		});

		$('#btn-start').addEventListener('click', () => runAction('start', '已开始测速'));
		$('#btn-retest').addEventListener('click', () => runAction('retest', '已开始复测'));
		$('#btn-stop').addEventListener('click', () => runAction('stop', '已请求停止'));

		$('#btn-sa-refresh').addEventListener('click', () => {
			refreshStandalone().catch((e) => toast(e.message || '刷新失败', true));
		});
		$('#btn-sa-save').addEventListener('click', saveStandalone);

		mountScheduleEditor('task-add-schedule', '0 3 * * *');
		mountScheduleEditor('cfg-task-add-schedule', '0 3 * * *');

		$('#btn-add-worker').addEventListener('click', addWorker);
		$('#btn-task-add').addEventListener('click',
			() => addTask('task-add-schedule', 'task-add-mode'));
		$('#btn-cfg-task-add').addEventListener('click',
			() => addTask('cfg-task-add-schedule', 'cfg-task-add-mode'));
		$('#btn-cfg-task-add-toggle').addEventListener('click',
			() => $('#cfg-task-add-form').classList.toggle('hidden'));
		$('#btn-log-clear').addEventListener('click', () => { $('#log-view').textContent = ''; });

		$$('.save-config').forEach((button) => {
			button.addEventListener('click', saveConfig);
		});

		$('#cfg-ip-source').addEventListener('change', updateSourceVisibility);
	}

	async function boot() {
		bindEvents();
		updateSourceVisibility();

		try {
			const hello = await api('hello');

			if (hello.authenticated) {
				state.csrf = hello.csrf || '';
				await showApp();
			}
			else {
				showAuth(hello.setup ? 'setup' : 'login');
			}
		}
		catch (e) {
			showAuth('login');
		}
	}

	boot();
})();
