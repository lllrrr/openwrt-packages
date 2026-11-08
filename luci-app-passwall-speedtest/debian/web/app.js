/* cfpick web UI — vanilla JS, no build step. */
(function () {
	'use strict';

	const $ = (selector, root) => (root || document).querySelector(selector);
	const $$ = (selector, root) => Array.from((root || document).querySelectorAll(selector));

	const state = {
		token: localStorage.getItem('cfpick_token') || '',
		config: null,
		status: null,
		core: null,
		best: null,
		history: [],
		nodeInfo: [],
		coreTags: {},
		appInfo: null,
		appTimer: 0,
		tab: 'overview',
		logPos: 0,
		resultFilter: '',
		lastRunning: false,
		pollTimer: 0,
		logTimer: 0,
		coreTimer: 0,
		elapsedTimer: 0,
		chart: null,
		// 日志读取串行化，避免切页/定时器/手动刷新并发读到同一段而重复追加。
		logChain: Promise.resolve(),
	};

	const PHASES = {
		idle: '空闲',
		starting: '启动中',
		latency: '一轮延迟测试',
		running: '一轮延迟测试',
		download: '下载实测',
		commit: '写入结果',
		stopping: '正在停止',
		done: '已完成',
		failed: '失败',
	};

	const PALETTE = [
		['#2fbf71', 'rgba(47,191,113,0.18)'],
		['#ff6b5e', 'rgba(255,107,94,0.18)'],
		['#4da3ff', 'rgba(77,163,255,0.18)'],
		['#e0a340', 'rgba(224,163,64,0.18)'],
		['#9b7bff', 'rgba(155,123,255,0.18)'],
		['#ff9f43', 'rgba(255,159,67,0.18)'],
		['#20c4cb', 'rgba(32,196,203,0.18)'],
		['#f368a8', 'rgba(243,104,168,0.18)'],
	];

	// ── api ─────────────────────────────────────────────────────────────
	function withToken(url) {
		if (!state.token)
			return url;
		return url + (url.indexOf('?') >= 0 ? '&' : '?') + 'token=' + encodeURIComponent(state.token);
	}

	async function api(path, options) {
		const opts = Object.assign({}, options || {});
		opts.headers = Object.assign({}, opts.headers || {});
		if (state.token)
			opts.headers['X-CFPICK-Token'] = state.token;
		if (opts.body && typeof opts.body !== 'string') {
			opts.body = JSON.stringify(opts.body);
			opts.headers['Content-Type'] = 'application/json';
		}
		const response = await fetch(path, opts);
		const text = await response.text();
		let data = {};
		try { data = text ? JSON.parse(text) : {}; } catch (e) { data = { error: text }; }
		if (response.status === 401) {
			showAuth();
			throw new Error('需要访问令牌');
		}
		if (!response.ok)
			throw new Error(data.error || ('HTTP ' + response.status));
		return data;
	}

	// ── toast / dialogs ─────────────────────────────────────────────────
	let toastTimer = 0;
	function toast(message, isError) {
		const node = $('#toast');
		node.textContent = message;
		node.classList.toggle('error', !!isError);
		node.classList.remove('hidden');
		clearTimeout(toastTimer);
		toastTimer = setTimeout(() => node.classList.add('hidden'), isError ? 6500 : 3800);
	}

	function showAuth() {
		$('#auth-overlay').classList.remove('hidden');
		$('#auth-error').textContent = '';
		const input = $('#auth-token');
		if (input) { input.value = state.token || ''; input.focus(); }
	}

	function hideAuth() {
		$('#auth-overlay').classList.add('hidden');
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

	function phaseLabel(phase) {
		return PHASES[phase] || phase || '空闲';
	}

	function setText(id, text) {
		const node = document.getElementById(id);
		if (node) node.textContent = text;
	}

	// ── tabs ────────────────────────────────────────────────────────────
	const TABS = ['overview', 'nodes', 'iplists', 'settings', 'logs', 'core'];

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
			reloadLog(true);
		} else if (name === 'core') {
			refreshCore();
			refreshAppInfo();
		} else if (name === 'nodes') {
			refreshNodeInfo();
		} else if (name === 'settings' || name === 'overview') {
			refreshCronTasks();
		}
	}

	// ── status ───────────────────────────────────────────────────────────
	function renderStatus(status) {
		state.status = status;
		const running = !!status.running;
		const dot = $('#status-dot');
		dot.classList.toggle('running', running);
		dot.classList.toggle('idle', !running && status.phase !== 'failed');
		dot.classList.toggle('error', !running && status.phase === 'failed');

		let text;
		if (running) {
			text = phaseLabel(status.phase) + ' · 已运行 ' + fmtDuration(status.elapsed) +
				' · ' + (status.node_count || 0) + ' 个节点' +
				(status.stop_requested ? ' · 正在停止（收尾中）' : '');
		} else {
			text = phaseLabel(status.phase);
			if (status.last && status.last.last_time)
				text += ' · 上次 ' + status.last.last_time;
			if (status.last && status.last.best_ip)
				text += ' · 最优 ' + status.last.best_ip;
			if (status.last && status.last.error)
				text += ' · ' + status.last.error;
		}
		setText('status-text', text);
		setText('ov-phase', running ? phaseLabel(status.phase) : phaseLabel(status.phase));
		setText('ov-elapsed', running
			? '已运行 ' + fmtDuration(status.elapsed) + (status.stop_requested ? ' · 正在停止' : '')
			: (status.last && status.last.finished_at ? '上次完成于 ' + new Date(status.last.finished_at * 1000).toLocaleString() : '—'));

		// 已请求停止时按钮也要失效并显示「停止中…」，避免重复点。
		const stopping = running && !!status.stop_requested;
		const stopButton = $('#btn-stop');
		$('#btn-start').disabled = running;
		stopButton.disabled = !running || stopping;
		stopButton.textContent = stopping ? '停止中…' : '停止';
		$('#btn-retest').disabled = running;

		if (status.core) renderActiveCore(status.core);
		setText('ov-cron', status.cron ? '已启用' : '未启用');
		setText('ov-cron-line', status.cron_line || '—');
		renderDdnsStatus(status.ddns);
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
		let head = '—';
		if (enabled) {
			if (info.ok === false) head = '写入失败';
			else if (info.at) head = '已写入';
			else head = '等待写入';
		}
		setText('ov-ddns', head);
		setText('ov-ddns-meta', ddnsText(info));
		setText('ddns-status', enabled
			? ('DDNS：' + ddnsText(info))
			: 'DDNS 未启用；启用后，只有填写了 DDNS 域名的节点会写 DNS。');
	}

	function renderActiveCore(info) {
		const type = info.type || (state.config && state.config.core && state.config.core.type) || '';
		setText('ov-core', info.installed
			? (type ? type + ' · ' : '') + (info.version || '已安装')
			: (type ? type + ' · ' : '') + '未安装');
		setText('ov-core-path', info.path || '—');
	}

	async function pollStatus() {
		try {
			const status = await api('/api/status');
			const wasRunning = state.lastRunning;
			state.lastRunning = !!status.running;
			renderStatus(status);
			if (wasRunning && !status.running) {
				await refreshResults();
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
		setText('ov-elapsed', '已运行 ' + fmtDuration(elapsed) +
			(status.stop_requested ? ' · 正在停止' : ''));
	}

	// ── best / table / chart ─────────────────────────────────────────────
	function renderBest() {
		const best = state.best || {};
		const payload = best.payload || {};
		$('#best-text').textContent = best.content || '尚无结果。';
		const top = payload.best;
		setText('ov-best-ip', top && top.ip ? top.ip : '—');
		setText('ov-best-meta', top
			? (fmtNumber(top.latency) + ' ms · ' +
			   (top.speed > 0 ? fmtNumber(top.speed) + ' MB/s' : '未做下载实测') +
			   (top.node ? ' · ' + top.node : ''))
			: '—');
		setText('result-time', payload.generated_at ? '生成时间：' + payload.generated_at : '');

		const csv = $('#dl-csv');
		const json = $('#dl-json');
		csv.href = withToken('/api/export/result.csv');
		json.href = withToken('/api/export/result.json');
		const exports = (state.config && state.config.export) || {};
		csv.classList.toggle('hidden', exports.csv === false);
		json.classList.toggle('hidden', exports.json === false);

		renderResultTable();
	}

	function renderResultTable() {
		const rows = ((state.best && state.best.payload && state.best.payload.rows) || []);
		const filter = $('#result-filter');
		const nodes = [];
		rows.forEach((row) => {
			if (row.node && nodes.indexOf(row.node) < 0) nodes.push(row.node);
		});
		const selected = state.resultFilter;
		filter.replaceChildren();
		const all = document.createElement('option');
		all.value = '';
		all.textContent = '全部节点';
		filter.appendChild(all);
		nodes.forEach((name) => {
			const option = document.createElement('option');
			option.value = name;
			option.textContent = name;
			filter.appendChild(option);
		});
		filter.value = nodes.indexOf(selected) >= 0 ? selected : '';

		const body = $('#result-table tbody');
		body.replaceChildren();
		const visible = rows.filter((row) => !state.resultFilter || row.node === state.resultFilter);
		if (!visible.length) {
			const tr = document.createElement('tr');
			const td = document.createElement('td');
			td.colSpan = 6;
			td.className = 'empty';
			td.textContent = '尚无结果';
			tr.appendChild(td);
			body.appendChild(tr);
			return;
		}
		const bestIp = rows[0] && rows[0].ip;
		visible.forEach((row) => {
			const tr = document.createElement('tr');
			if (row.ip === bestIp) tr.className = 'best';
			const cells = [
				[row.ip, 'ip'],
				[fmtNumber(row.latency), ''],
				[fmtNumber(row.loss), ''],
				[row.speed > 0 ? fmtNumber(row.speed) : '—', ''],
				[row.region || '—', ''],
				[row.node || '—', ''],
			];
			cells.forEach((cell) => {
				const td = document.createElement('td');
				if (cell[1]) td.className = cell[1];
				td.textContent = cell[0];
				tr.appendChild(td);
			});
			body.appendChild(tr);
		});
	}

	function chartTheme() {
		const style = getComputedStyle(document.documentElement);
		return {
			text: style.getPropertyValue('--muted').trim() || '#667085',
			border: style.getPropertyValue('--border').trim() || '#dbe2ea',
			background: style.getPropertyValue('--bg-elev').trim() || '#ffffff',
		};
	}

	function renderChart() {
		if (!window.Chart) return;
		const canvas = $('#history-chart');
		if (!canvas) return;
		if (state.chart) {
			state.chart.destroy();
			state.chart = null;
		}
		const runs = (state.history || []).slice().sort((a, b) => a.time > b.time ? 1 : (a.time < b.time ? -1 : 0));
		if (!runs.length) {
			setText('chart-hint', '暂无历史数据；完成一次测速后会出现趋势线。');
			return;
		}
		setText('chart-hint', '每个点 = 某次运行中该节点的最优 IP');

		const toTimestamp = (text) => {
			const parsed = Date.parse(String(text || '').replace(' ', 'T'));
			return Number.isFinite(parsed) ? parsed : NaN;
		};
		const series = {};
		const order = [];
		runs.forEach((run) => {
			const points = (run.nodes && run.nodes.length)
				? run.nodes
				: [{ node: '', ip: run.ip, latency: run.latency, speed: run.speed, region: run.region }];
			const timestamp = toTimestamp(run.time);
			if (!Number.isFinite(timestamp)) return;
			points.forEach((point) => {
				const key = point.node || '(全局)';
				if (!series[key]) { series[key] = []; order.push(key); }
				series[key].push({
					x: timestamp,
					y: point.latency,
					node: point.node || '',
					ip: point.ip,
					speed: point.speed,
					region: point.region,
				});
			});
		});

		const theme = chartTheme();
		const datasets = order.map((key, index) => ({
			label: key,
			data: series[key],
			borderColor: PALETTE[index % PALETTE.length][0],
			backgroundColor: PALETTE[index % PALETTE.length][1],
			tension: 0.3,
			fill: false,
			pointRadius: 4,
			pointHoverRadius: 6,
			borderWidth: 2,
		}));

		state.chart = new Chart(canvas, {
			type: 'line',
			data: { datasets: datasets },
			options: {
				responsive: true,
				maintainAspectRatio: false,
				interaction: { mode: 'nearest', intersect: true },
				onClick: function (event, elements, chart) {
					const hits = chart.getElementsAtEventForMode(event, 'nearest', { intersect: true }, false);
					if (!hits || !hits.length) return;
					showPoint(chart.data.datasets[hits[0].datasetIndex].data[hits[0].index]);
				},
				plugins: {
					legend: {
						position: 'top',
						labels: { color: theme.text, usePointStyle: true, boxWidth: 8 },
					},
					tooltip: {
						mode: 'nearest',
						intersect: true,
						callbacks: {
							title: (items) => '时间：' + formatChartTime(items[0].raw.x),
							label: (item) => {
								const raw = item.raw;
								return (raw.node || '全局') + '：最优 ' + raw.ip + ' / ' +
									fmtNumber(raw.y) + 'ms' +
									(raw.speed > 0 ? ' / ' + fmtNumber(raw.speed) + ' MB/s' : '');
							},
						},
					},
				},
				scales: {
					x: {
						type: 'time',
						time: {
							unit: 'hour',
							displayFormats: { hour: 'MM-dd HH:mm' },
						},
						offset: true,
						ticks: { color: theme.text, autoSkip: true, maxTicksLimit: 6, maxRotation: 45 },
						grid: { color: theme.border },
					},
					y: {
						type: 'linear',
						title: { display: true, text: '延迟 (ms)', color: theme.text },
						ticks: { color: theme.text },
						grid: { color: theme.border },
					},
				},
			},
		});
	}

	function formatChartTime(value) {
		if (value instanceof Date) return value.toLocaleString();
		const number = Number(value);
		return Number.isFinite(number) ? new Date(number).toLocaleString() : String(value || '');
	}

	function showPoint(point) {
		setText('point-title', point.node || '全局最优');
		const body = $('#point-body');
		body.replaceChildren();
		const lines = [
			'最优 IP：' + point.ip,
			'延迟：' + fmtNumber(point.y) + ' ms',
			'时间：' + formatChartTime(point.x),
		];
		if (point.speed > 0) lines.push('下载速度：' + fmtNumber(point.speed) + ' MB/s');
		if (point.region) lines.push('地区：' + point.region);
		lines.forEach((line) => {
			const p = document.createElement('p');
			p.textContent = line;
			body.appendChild(p);
		});
		$('#point-overlay').classList.remove('hidden');
	}

	async function refreshResults() {
		try {
			const results = await Promise.all([api('/api/best'), api('/api/history')]);
			state.best = results[0];
			state.history = (results[1] && results[1].history) || [];
			renderBest();
			renderChart();
		} catch (e) {
			/* handled by api() */
		}
	}

	// ── nodes ───────────────────────────────────────────────────────────
	function ipListSelect(selected) {
		const select = document.createElement('select');
		const fallback = document.createElement('option');
		fallback.value = '';
		fallback.textContent = '默认列表';
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
		select.value = selected || '';
		return select;
	}

	function renderNodes() {
		const body = $('#nodes-body');
		if (!body) return;
		body.replaceChildren();
		const nodes = (state.config && state.config.nodes) || [];
		nodes.forEach((node, index) => {
			const tr = document.createElement('tr');
			tr.dataset.index = String(index);
			tr.dataset.node = node.name || '';

			const enabledCell = document.createElement('td');
			const enabled = document.createElement('input');
			enabled.type = 'checkbox';
			enabled.checked = node.enabled !== false;
			enabled.addEventListener('change', () => {
				node.enabled = enabled.checked;
				tr.classList.toggle('disabled', !enabled.checked);
				syncNodeActions();
			});
			enabledCell.appendChild(enabled);
			tr.appendChild(enabledCell);

			const nameCell = document.createElement('td');
			const name = document.createElement('input');
			name.type = 'text';
			name.value = node.name || '';
			name.placeholder = '节点名称';
			name.addEventListener('input', () => {
				node.name = name.value;
				tr.dataset.node = name.value;
			});
			nameCell.appendChild(name);
			tr.appendChild(nameCell);

			const linkCell = document.createElement('td');
			const link = document.createElement('input');
			link.type = 'text';
			link.className = 'link-input';
			link.value = node.link || '';
			link.placeholder = 'vless://… / vmess://… / trojan://… / ss://… / hysteria2://…';
			link.spellcheck = false;
			link.addEventListener('input', () => { node.link = link.value; });
			linkCell.appendChild(link);
			tr.appendChild(linkCell);

			const listCell = document.createElement('td');
			const listSelect = ipListSelect(node.ip_list);
			listSelect.addEventListener('change', () => { node.ip_list = listSelect.value; });
			listCell.appendChild(listSelect);
			tr.appendChild(listCell);

			const ddnsCell = document.createElement('td');
			const ddnsDomain = document.createElement('input');
			ddnsDomain.type = 'text';
			ddnsDomain.className = 'ddns-input';
			ddnsDomain.value = node.ddns_domain || '';
			ddnsDomain.placeholder = 'jp 或 jp.example.com；留空 = 只测速';
			ddnsDomain.spellcheck = false;
			ddnsDomain.addEventListener('input', () => { node.ddns_domain = ddnsDomain.value; });
			ddnsCell.appendChild(ddnsDomain);
			tr.appendChild(ddnsCell);

			const statusCell = document.createElement('td');
			const info = state.nodeInfo[index];
			const badge = document.createElement('span');
			if (info && info.valid) {
				badge.className = 'badge ok';
				badge.textContent = info.type + ' · ' + info.server + ':' + info.port;
			} else if (info) {
				badge.className = 'badge bad';
				badge.textContent = '无效';
				badge.title = info.error || '';
			} else {
				badge.className = 'badge info';
				badge.textContent = '未保存';
			}
			statusCell.appendChild(badge);
			tr.appendChild(statusCell);

			const actionCell = document.createElement('td');
			const actions = document.createElement('div');
			actions.className = 'row-actions';

			// 每行三个 worker 按钮：测速 / 复测 / 停止。禁用状态由 syncNodeActions()
			// 按 /api/status 的 workers + download_active 实时同步。
			[['测速', 'start', 'primary'], ['复测', 'retest', ''], ['停止', 'stop', 'danger']]
				.forEach(([label, action, cls]) => {
					const button = document.createElement('button');
					button.type = 'button';
					button.className = 'btn small' + (cls ? ' ' + cls : '');
					button.dataset.nodeAction = action;
					button.textContent = label;
					button.addEventListener('click', () => {
						if (action === 'stop')
							stopNode(node.name);
						else
							startNode(node.name, action === 'retest' ? 'retest' : 'start');
					});
					actions.appendChild(button);
				});

			const remove = document.createElement('button');
			remove.type = 'button';
			remove.className = 'btn small danger';
			remove.textContent = '删除';
			remove.addEventListener('click', () => {
				if (!confirm('删除节点 ' + (node.name || ('#' + (index + 1))) + '？')) return;
				nodes.splice(index, 1);
				renderNodes();
			});
			actions.appendChild(remove);
			actionCell.appendChild(actions);
			tr.appendChild(actionCell);

			if (node.enabled === false) tr.classList.add('disabled');
			body.appendChild(tr);
		});
		$('#nodes-empty').classList.toggle('hidden', nodes.length > 0);
		syncNodeActions();
	}

	async function refreshNodeInfo() {
		try {
			const data = await api('/api/nodes');
			state.nodeInfo = data.nodes || [];
			renderNodes();
		} catch (e) { /* ignore */ }
	}

	function nameFromLink(link) {
		const hash = link.indexOf('#');
		if (hash >= 0) {
			try { return decodeURIComponent(link.slice(hash + 1)).trim(); }
			catch (e) { return link.slice(hash + 1).trim(); }
		}
		return '';
	}

	function importBulk() {
		const text = $('#bulk-links').value || '';
		const nodes = state.config.nodes || (state.config.nodes = []);
		const existing = new Set(nodes.map((node) => (node.link || '').trim()));
		let added = 0;
		text.split(/\r?\n/).forEach((line) => {
			const link = line.trim();
			if (!link || link.startsWith('#') || existing.has(link)) return;
			existing.add(link);
			nodes.push({
				name: nameFromLink(link),
				link: link,
				ip_list: '',
				ddns_domain: '',
				enabled: true,
			});
			added += 1;
		});
		$('#bulk-links').value = '';
		$('#bulk-overlay').classList.add('hidden');
		renderNodes();
		toast(added ? ('已导入 ' + added + ' 个节点，记得点击「保存节点」') : '没有可导入的新链接');
	}

	// 折叠多选展开时默认会撑高所在行（表格行、grid 行），长节点列表能把整行
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
			// 先把列表移出文档流再测量：展开的瞬间列表还参与表格自动布局，
			// summary 会被撑宽/挤偏，等列表变成 fixed 后表格又重排回原样。
			// 先测再改就会用到重排前的坐标（首次打开偏一截，滚动一下才正常）。
			if (!list.classList.contains('floating')) {
				list.classList.add('floating');
				list.style.position = 'fixed';
				list.style.marginTop = '0';
				void list.offsetHeight;
			}
			// 注意：details 展开后的 rect 包含列表本身的高度，拿它当锚点会把
			// 浮层再往下推一整个列表的高度（看起来像脱离输入框的弹窗）。
			// 锚点必须是 summary。
			const anchor = details.querySelector('summary') || details;
			const rect = anchor.getBoundingClientRect();
			const margin = 8;
			const gap = 6;
			const vw = document.documentElement.clientWidth;
			const vh = document.documentElement.clientHeight;
			// 不要从 list 自己的 computedStyle 读宽度：悬浮层一旦设过宽度，
			// 下一次定位会把上次的值再读回来，越放越宽。国家码多选需要两列，
			// 至少 240px；节点多选至少 170px。
			const cssMin = details.classList.contains('country-picker') ? 240 : 170;
			const width = Math.min(Math.max(cssMin, Math.round(rect.width)),
				vw - margin * 2);
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
				// 表格/字体的重排可能延续到下一帧，再校准一次，避免首帧偏差。
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

	// ── IP lists ────────────────────────────────────────────────────────
	// 与 LuCI 设置页「国家过滤」保持一致；源列表里出现列表外的两位码时，
	// buildCountryPicker 会把它们补进选项，避免保存时被悄悄清掉。
	const COUNTRY_CODES = [
		['JP', '日本'], ['SG', '新加坡'], ['KR', '韩国'], ['HK', '香港'],
		['TW', '台湾'], ['TH', '泰国'], ['VN', '越南'], ['ID', '印尼'],
		['PH', '菲律宾'], ['MY', '马来西亚'], ['IN', '印度'], ['KH', '柬埔寨'],
		['DE', '德国'], ['NL', '荷兰'], ['FR', '法国'], ['GB', '英国'],
		['FI', '芬兰'], ['SE', '瑞典'], ['CH', '瑞士'], ['RU', '俄罗斯'],
		['TR', '土耳其'], ['UA', '乌克兰'], ['US', '美国'], ['CA', '加拿大'],
		['BR', '巴西'], ['AU', '澳大利亚'], ['AE', '阿联酋'], ['ZA', '南非'],
	];

	// 折叠式国家码多选（复用 node-picker 的样式与交互）。
	function buildCountryPicker(selected) {
		const details = document.createElement('details');
		details.className = 'node-picker country-picker';
		const summary = document.createElement('summary');
		const list = document.createElement('div');
		list.className = 'node-picker-list';

		const known = new Set(COUNTRY_CODES.map((entry) => entry[0]));
		const chosen = [];
		(selected || []).forEach((code) => {
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
			.match(/^(.*?\bcfpick(?:\.sh)?)\s+run\s+(start|retest|test|replace)\b(.*)$/);
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

	function configuredNodes() {
		const list = [];
		const seen = new Set();
		((state.config && state.config.nodes) || []).forEach((node, index) => {
			const name = (node.name || '').trim() || ('node' + (index + 1));
			if (seen.has(name)) return;
			seen.add(name);
			list.push({ name: name, enabled: node.enabled !== false, stale: false });
		});
		return list;
	}

	// A collapsible checkbox list.  No selection means "every enabled node",
	// matching the CLI's --node semantics.
	function buildNodePicker(selected, disabled) {
		const details = document.createElement('details');
		details.className = 'node-picker';
		const summary = document.createElement('summary');
		const list = document.createElement('div');
		list.className = 'node-picker-list';

		const nodes = configuredNodes();
		const known = new Set(nodes.map((node) => node.name));
		(selected || []).forEach((name) => {
			if (name && !known.has(name)) {
				known.add(name);
				nodes.push({ name: name, enabled: false, stale: true });
			}
		});
		const chosen = new Set(selected || []);
		nodes.forEach((node) => {
			const label = document.createElement('label');
			label.className = 'check';
			const box = document.createElement('input');
			box.type = 'checkbox';
			box.value = node.name;
			box.checked = chosen.has(node.name);
			box.disabled = !!disabled;
			const text = document.createElement('span');
			text.textContent = node.name + (node.stale
				? '（已删除）' : (node.enabled ? '' : '（未启用）'));
			label.appendChild(box);
			label.appendChild(text);
			list.appendChild(label);
		});
		if (!nodes.length) {
			const empty = document.createElement('span');
			empty.className = 'muted';
			empty.textContent = '还没有配置节点';
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
			summary.textContent = values.length ? values.join('、') : '全部节点';
			summary.title = values.length ? values.join('、') : '全部已启用节点';
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
		const body = { line: entry.line, schedule: schedule, enabled: enabled, mode: mode || '' };
		// null/undefined keeps the command's existing --node flags untouched;
		// an empty array explicitly clears them (= all nodes).
		if (nodes != null) body.nodes = nodes;
		try {
			const data = await api('/api/cron/task/save', {
				method: 'POST',
				body: body,
			});
			renderCronTasks(data);
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
			const data = await api('/api/cron/task/delete', {
				method: 'POST',
				body: { line: entry.line },
			});
			renderCronTasks(data);
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
			const data = await api('/api/cron/task/add', {
				method: 'POST',
				body: {
					schedule: schedule,
					mode: modeNode ? modeNode.value : 'retest',
					nodes: nodes,
				},
			});
			renderCronTasks(data);
			toast('定时任务已添加');
		} catch (e) {
			toast(e.message, true);
		}
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
						? entry.nodes.join('、') : '全部节点';
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
		renderOverviewCronTasks(tasks);
	}

	// The overview copy is read-only apart from enable/disable, matching the
	// LuCI console: every other edit lives on the Settings tab.
	function renderOverviewCronTasks(tasks) {
		const body = $('#ov-cron-body');
		if (!body) return;
		body.replaceChildren();

		if (!tasks.length) {
			const tr = document.createElement('tr');
			const td = document.createElement('td');
			td.colSpan = 5;
			td.className = 'empty';
			td.textContent = '暂无其他定时任务';
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
				? entry.nodes.join('、') : '全部节点';
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
			renderCronTasks(await api('/api/cron'));
		} catch (e) {
			setText('cron-note', '读取失败：' + e.message);
		}
	}

	// ── settings form ───────────────────────────────────────────────────
	function normalizeCronText(value) {
		// Chinese IMEs in full-width mode turn "12" into "１２", which looks
		// like "1 2" and would fail cron validation.  Convert to half-width.
		return String(value || '')
			.replace(/[！-～]/g,
				(ch) => String.fromCharCode(ch.charCodeAt(0) - 0xFEE0))
			.replace(/　/g, ' ');
	}

	function fillSettings(cfg) {
		const set = (id, value) => { const node = $('#' + id); if (node) node.value = value == null ? '' : value; };
		const check = (id, value) => { const node = $('#' + id); if (node) node.checked = !!value; };

		set('ip_source', cfg.ip_source);
		set('ip_online_url', cfg.ip_online_url);
		set('custom_ip_file', cfg.custom_ip_file);
		check('custom_allip', cfg.custom_allip);
		set('latency_max', cfg.latency_max);
		set('latency_min', cfg.latency_min);
		set('loss_max', cfg.loss_max);
		set('test_count', cfg.test_count);
		set('probe_timeout', cfg.probe_timeout);
		set('probes', cfg.probes);
		set('max_workers', cfg.max_workers);
		set('probe_url', cfg.probe_url);
		check('download_enabled', cfg.download_enabled);
		set('download_count', cfg.download_count);
		set('download_url', cfg.download_url);
		set('download_time', cfg.download_time);
		check('iterate_enabled', cfg.iterate_enabled);
		set('iterate_minutes', cfg.iterate_minutes);
		set('iterate_converge_count', cfg.iterate_converge_count);
		const ddns = cfg.ddns || {};
		const cloudflare = ddns.cloudflare || {};
		check('ddns_enabled', ddns.enabled);
		set('ddns_token', cloudflare.api_token || '');
		set('ddns_zone_id', cloudflare.zone_id);
		set('ddns_zone_name', cloudflare.zone_name);
		set('ddns_ip_count', ddns.ip_count);
		set('ddns_ttl', ddns.ttl);
		check('ddns_proxied', cloudflare.proxied);
		// The add form starts with no selection (= all nodes) after a reload.
		mountNodePicker('cron-add-nodes', []);
		if ($('#core-type')) $('#core-type').value = cfg.core.type;
		set('core_dns', cfg.core.dns_nameserver);
		set('web_listen', cfg.web.listen);
		set('web_port', cfg.web.port);
		set('web_token', cfg.web.token);
		updateFieldVisibility();
	}

	function collectSettings() {
		const cfg = JSON.parse(JSON.stringify(state.config || {}));
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

		cfg.ip_source = text('ip_source') || 'builtin_ipv4';
		cfg.ip_online_url = text('ip_online_url');
		cfg.custom_ip_file = text('custom_ip_file');
		cfg.custom_allip = check('custom_allip');
		cfg.latency_max = integer('latency_max', 0, 0, 60000);
		cfg.latency_min = integer('latency_min', 40, 0, 60000);
		cfg.loss_max = number('loss_max', 0.2, 0, 1);
		cfg.test_count = integer('test_count', 30, 1, 100000);
		cfg.probe_timeout = integer('probe_timeout', 5, 1, 120);
		cfg.probes = integer('probes', 3, 1, 5);
		cfg.max_workers = integer('max_workers', 5, 0, 128);
		cfg.probe_url = text('probe_url');
		cfg.download_enabled = check('download_enabled');
		cfg.download_count = integer('download_count', 5, 1, 10);
		cfg.download_url = text('download_url');
		cfg.download_time = integer('download_time', 10, 1, 60);
		cfg.iterate_enabled = check('iterate_enabled');
		cfg.iterate_minutes = integer('iterate_minutes', 30, 1, 10080);
		cfg.iterate_converge_count = integer('iterate_converge_count', 5, 1, 100);
		const oldDdns = cfg.ddns || {};
		cfg.ddns = Object.assign({}, oldDdns, {
			enabled: check('ddns_enabled'),
			provider: 'cloudflare',
			ip_count: integer('ddns_ip_count', 1, 1, 10),
			ttl: integer('ddns_ttl', 300, 1, 86400),
			cloudflare: Object.assign({}, oldDdns.cloudflare || {}, {
				api_token: text('ddns_token'),
				zone_id: text('ddns_zone_id'),
				zone_name: text('ddns_zone_name'),
				proxied: check('ddns_proxied'),
			}),
		});
		const corePaths = Object.assign({}, (cfg.core && cfg.core.paths) || {});
		$$('#core-cards input[data-core-path]').forEach((input) => {
			corePaths[input.dataset.corePath] = input.value.trim();
		});
		cfg.core = Object.assign({}, cfg.core, {
			type: text('core-type') || (cfg.core && cfg.core.type) || 'mihomo',
			paths: corePaths,
			dns_nameserver: text('core_dns'),
		});
		cfg.web = Object.assign({}, cfg.web, {
			listen: text('web_listen') || '127.0.0.1',
			port: integer('web_port', 8787, 1, 65535),
			token: text('web_token'),
		});
		return cfg;
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
			const payload = collectSettings();
			const response = await api('/api/config', { method: 'POST', body: { config: payload } });
			const oldToken = state.token;
			state.config = response.config;
			state.token = (response.config.web && response.config.web.token) || '';
			if (state.token) localStorage.setItem('cfpick_token', state.token);
			else localStorage.removeItem('cfpick_token');
			$('#dl-log').href = withToken('/api/export/log');
			state.nodeInfo = (await api('/api/nodes')).nodes || [];
			renderNodes();
			renderIpLists();
			fillSettings(state.config);
			renderBest();
			refreshCore();
			refreshCronTasks();
			if (hint) hint.textContent = '已保存 ' + new Date().toLocaleTimeString();
			if (response.warnings && response.warnings.length)
				toast(response.warnings.join('；'), true);
			else
				toast(response.cron_error ? (successMessage + '；定时任务: ' + response.cron_error)
					: (successMessage || '配置已保存'), !!response.cron_error);
			if (oldToken !== state.token) pollStatus();
		} catch (e) {
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
		if (state.tab !== 'logs') return;
		if (!$('#log-autorefresh') || !$('#log-autorefresh').checked) return;
		reloadLog(false);
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
		if (state.config && state.config.core) {
			if (!state.config.core.paths) state.config.core.paths = {};
			$$('#core-cards input[data-core-path]').forEach((input) => {
				state.config.core.paths[input.dataset.corePath] = input.value.trim();
			});
		}
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
				['来源', info.managed ? '托管（可自动升级）' : (info.installed ? '自定义路径' : '—'), ''],
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

			const pathLabel = document.createElement('label');
			pathLabel.className = 'core-path-label';
			pathLabel.appendChild(document.createTextNode('自定义二进制路径（留空使用托管内核）'));
			const pathInput = document.createElement('input');
			pathInput.type = 'text';
			pathInput.spellcheck = false;
			pathInput.dataset.corePath = type;
			pathInput.placeholder = '/var/lib/cfpick/core/' + type;
			pathInput.value = ((state.config && state.config.core && state.config.core.paths) || {})[type] || '';
			pathInput.addEventListener('input', () => {
				if (!state.config.core.paths) state.config.core.paths = {};
				state.config.core.paths[type] = pathInput.value.trim();
			});
			pathLabel.appendChild(pathInput);
			card.appendChild(pathLabel);

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
		renderCoreCards(payload);
		let message = payload.message || '';
		if (payload.error) message += (message ? '：' : '') + payload.error;
		setText('core-message', message);
		const active = payload.active || ((state.config && state.config.core && state.config.core.type) || '');
		const info = (payload.cores || {})[active] || {};
		renderActiveCore(Object.assign({}, info, { type: active }));
	}

	async function refreshCore() {
		try {
			renderCore(await api('/api/core'));
			scheduleCorePoll();
		} catch (e) { /* ignore */ }
	}

	// ── application self-update ──────────────────────────────────────────
	function renderAppInfo(app) {
		if (!app) return;
		state.appInfo = app;
		setText('app-current-version', app.version || '—');
		setText('app-commit', app.commit || '—');
		setText('app-branch', app.branch || '—');
		setText('app-source', app.source_dir || '—');
		const update = app.update || {};
		let text = '—';
		if (update.updating) {
			text = update.message || '更新中…';
		} else if (update.message) {
			text = update.message
				+ (update.error ? '：' + update.error : '')
				+ (update.commit ? '（' + update.commit + '）' : '');
		} else if (!app.manageable) {
			text = '源码目录不可用，无法在线更新';
		} else if (!app.systemd_run) {
			text = '未找到 systemd-run，无法在线更新';
		}
		setText('app-update-state', text);
		const running = !!(state.status && state.status.running);
		const busy = !!update.updating;
		const button = $('#btn-app-update');
		if (button) {
			button.disabled = !app.manageable || !app.systemd_run || busy || running;
			button.textContent = busy ? '更新中…' : '更新程序';
		}

		const uninstall = $('#btn-app-uninstall');
		if (uninstall)
			uninstall.disabled = running || busy;
	}

	async function refreshAppInfo() {
		try {
			renderAppInfo(await api('/api/app'));
		} catch (e) { /* ignore */ }
	}

	async function uninstallApp() {
		if (!confirm('卸载程序会停止 Web 服务；配置、结果与日志默认保留。继续？'))
			return;

		const button = $('#btn-app-uninstall');
		if (button) button.disabled = true;

		try {
			const response = await api('/api/uninstall-app', { method: 'POST', body: {} });
			toast(response.message || '已开始卸载，Web 服务即将停止');
		} catch (e) {
			// The service stops while the uninstall script runs, so a dropped
			// connection usually means the uninstall started successfully.
			if (e instanceof TypeError) {
				toast('卸载已开始，Web 服务可能已停止');
			} else {
				toast(e.message, true);
				if (button) button.disabled = false;
			}
		}
	}

	async function updateApp() {
		if (!confirm('更新程序会拉取代码并重启 Web 服务，页面会短暂断连。继续？'))
			return;
		try {
			const response = await api('/api/update-app', { method: 'POST', body: {} });
			toast(response.message || '已开始更新程序');
			if (response.app) renderAppInfo(response.app);
			waitForAppUpdate();
		} catch (e) {
			// fetch 本身失败（TypeError）通常说明服务已经开始重启、连接被断开；
			// 更新可能正在进行，继续轮询状态，而不是直接报 "Failed to fetch"。
			if (e instanceof TypeError) {
				toast('更新请求已断开（Web 服务可能正在重启），等待更新结果…');
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
				/* the web service is restarting */
			}
			if (attempts >= 60) {
				clearInterval(state.appTimer);
				state.appTimer = 0;
				toast('更新状态超时，请手动刷新页面', true);
			}
		}, 2000);
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
			toast(response.message || ('已开始更新 ' + type));
			await refreshCore();
		} catch (e) {
			toast(e.message, true);
		}
	}

	// ── actions ─────────────────────────────────────────────────────────
	// 节点页每行的独立测速：只测一个 worker，允许与其他 worker 并行探测。
	async function startNode(name, mode) {
		if (!name) {
			toast('请先给节点填写名称', true);
			return;
		}
		try {
			await api('/api/start', {
				method: 'POST',
				body: { mode: mode, nodes: [name] },
			});
			toast((mode === 'retest' ? '已开始复测：' : '已开始测速：') + name);
			activateTab('logs');
			await pollStatus();
		}
		catch (e) {
			toast(e.message, true);
		}
	}

	// 只停这一个 worker：它跑完当前 IP 后进入下载实测并写回，其他 worker 继续。
	async function stopNode(name) {
		if (!name) return;
		try {
			const response = await api('/api/stop', {
				method: 'POST',
				body: { nodes: [name] },
			});
			toast(response.message || ('已请求停止：' + name));
			await pollStatus();
		}
		catch (e) {
			toast(e.message, true);
		}
	}

	// 按钮状态跟 /api/status 同步：
	//   * 该 worker 正在测速 → 测速/复测禁用，停止可用；
	//   * 整个下载/写回阶段（download_active）→ 本页所有按钮禁用；
	//   * 空闲且未禁用 → 测速/复测可用，停止禁用。
	function syncNodeActions() {
		const status = state.status || {};
		const workers = status.workers || {};
		const busy = !!status.download_active;

		$$('#nodes-body tr').forEach((row) => {
			const name = row.dataset.node || '';
			const info = name ? workers[name] : null;
			const running = !!info;
			const stopping = !!(info && info.stopping);
			const off = row.classList.contains('disabled');
			row.classList.toggle('running', running);

			row.querySelectorAll('[data-node-action]').forEach((button) => {
				const action = button.dataset.nodeAction;
				if (action === 'stop') {
					button.disabled = !running || stopping || busy;
					button.textContent = stopping ? '停止中…' : '停止';
				}
				else {
					button.disabled = running || busy || off;
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
			toast(response.message || '已请求停止');
			await pollStatus();
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
		]);
		state.config = results[0].config;
		state.status = results[1];
		state.lastRunning = !!results[1].running;
		state.best = results[2];
		state.history = (results[3] && results[3].history) || [];
		state.nodeInfo = (results[4] && results[4].nodes) || [];
		state.core = results[5];
		state.appInfo = results[6];
		if (results[1] && results[1].state_dir)
			setText('state-dir', results[1].state_dir);
		$('#dl-log').href = withToken('/api/export/log');

		renderStatus(state.status);
		fillSettings(state.config);
		renderNodes();
		renderIpLists();
		renderBest();
		renderChart();
		renderCore(state.core);
		renderAppInfo(state.appInfo);
		activateTab(initialTab());
	}

	function startPolling() {
		clearInterval(state.pollTimer);
		clearInterval(state.logTimer);
		clearInterval(state.elapsedTimer);
		state.pollTimer = setInterval(pollStatus, 3000);
		state.logTimer = setInterval(tickLogs, 2000);
		state.elapsedTimer = setInterval(tickElapsed, 1000);
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

		$('#btn-add-node').addEventListener('click', () => {
			(state.config.nodes || (state.config.nodes = [])).push({
				name: '', link: '', ip_list: '', ddns_domain: '', enabled: true,
			});
			renderNodes();
		});
		$('#btn-save-nodes').addEventListener('click', () => saveConfig('节点已保存'));
		$('#btn-save-iplists').addEventListener('click', () => saveConfig('IP 列表已保存'));

		$('#btn-bulk').addEventListener('click', () => {
			$('#bulk-overlay').classList.remove('hidden');
			$('#bulk-links').focus();
		});
		$('#bulk-cancel').addEventListener('click', () => $('#bulk-overlay').classList.add('hidden'));
		$('#bulk-apply').addEventListener('click', importBulk);

		$('#settings-form').addEventListener('submit', (event) => {
			event.preventDefault();
			saveConfig('设置已保存');
		});
		$('#ip_source').addEventListener('change', updateFieldVisibility);
		$('#btn-cron-refresh').addEventListener('click', refreshCronTasks);
		mountScheduleEditor('cron-add-schedule', '0 3 * * *');
		mountNodePicker('cron-add-nodes', []);
		$('#btn-cron-add').addEventListener('click', addCronTask);
		$('#btn-ddns-preview').addEventListener('click', previewDdns);
		$('#btn-ddns-apply').addEventListener('click', applyDdns);

		$('#result-filter').addEventListener('change', (event) => {
			state.resultFilter = event.target.value;
			renderResultTable();
		});

		$('#btn-log-reload').addEventListener('click', () => reloadLog(true));
		$('#dl-log').href = withToken('/api/export/log');

		$('#btn-core-refresh').addEventListener('click', refreshCore);
		$('#btn-app-update').addEventListener('click', updateApp);
		$('#btn-app-uninstall').addEventListener('click', uninstallApp);
		$('#btn-save-core').addEventListener('click', async () => {
			state.config.core.type = $('#core-type').value;
			await saveConfig('内核选择已保存');
			await refreshCore();
		});

		$('#point-close').addEventListener('click', () => $('#point-overlay').classList.add('hidden'));
		$$('.overlay').forEach((overlay) => {
			overlay.addEventListener('click', (event) => {
				if (event.target === overlay && overlay.id !== 'auth-overlay')
					overlay.classList.add('hidden');
			});
		});
		document.addEventListener('keydown', (event) => {
			if (event.key === 'Escape') closeOverlays();
		});

		$('#auth-form').addEventListener('submit', async (event) => {
			event.preventDefault();
			const token = $('#auth-token').value.trim();
			if (!token) {
				$('#auth-error').textContent = '请输入令牌';
				return;
			}
			state.token = token;
			localStorage.setItem('cfpick_token', token);
			try {
				await loadAll();
				hideAuth();
				startPolling();
			} catch (e) {
				$('#auth-error').textContent = e.message === '需要访问令牌' ? '令牌无效' : e.message;
			}
		});

		if (window.matchMedia) {
			const query = window.matchMedia('(prefers-color-scheme: dark)');
			const redraw = () => { if (state.history.length) renderChart(); };
			if (query.addEventListener) query.addEventListener('change', redraw);
			else if (query.addListener) query.addListener(redraw);
		}
	}

	async function init() {
		bindEvents();
		try {
			const pingResponse = await fetch('/api/ping');
			const ping = await pingResponse.json();
			setText('app-version', ping.version || '');
			$('#dl-log').href = withToken('/api/export/log');
			if (ping.auth_required && !state.token) {
				showAuth();
				return;
			}
			await loadAll();
			startPolling();
		} catch (e) {
			toast('初始化失败：' + e.message, true);
		}
	}

	init();
})();
