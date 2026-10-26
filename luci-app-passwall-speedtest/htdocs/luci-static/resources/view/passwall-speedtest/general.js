'use strict';
'require view';
'require form';
'require poll';
'require rpc';
'require ui';
'require uci';

const callStatus = rpc.declare({
	object: 'passwall-speedtest',
	method: 'status',
	expect: {}
});

const callStart = rpc.declare({
	object: 'passwall-speedtest',
	method: 'start',
	expect: {}
});

const callRetest = rpc.declare({
	object: 'passwall-speedtest',
	method: 'start_retest',
	expect: {}
});

const callStop = rpc.declare({
	object: 'passwall-speedtest',
	method: 'stop',
	expect: {}
});

const callHistory = rpc.declare({
	object: 'passwall-speedtest',
	method: 'get_history',
	expect: { history: [] }
});

const callBestResult = rpc.declare({
	object: 'passwall-speedtest',
	method: 'get_best_result',
	expect: { content: '' }
});

const callListNodes = rpc.declare({
	object: 'passwall-speedtest',
	method: 'list_nodes',
	expect: {}
});

function script(src) {
	return new Promise(function(resolve, reject) {
		const existing = document.querySelector('script[src="%s"]'.format(src));

		if (existing && existing.dataset.loaded == 'true') {
			resolve();
			return;
		}

		const el = existing || E('script', { src: src });
		el.addEventListener('load', resolve, { once: true });
		el.addEventListener('error', reject, { once: true });
		el.onload = function() {
			el.dataset.loaded = 'true';
		};
		el.onerror = reject;

		if (!existing)
			document.head.appendChild(el);
	});
}

function chartCss() {
	return E('style', {}, `
.passwall-speedtest-chart-container {
	--card-bg: #f8f8f8;
	--text-color: #222;
	--card-shadow: 0 2px 6px rgba(0,0,0,0.1);
	width: 100%;
	margin: 20px auto;
	background: var(--card-bg);
	padding: 20px;
	border-radius: 8px;
	box-shadow: var(--card-shadow);
	color: var(--text-color);
	box-sizing: border-box;
}

@media (prefers-color-scheme: dark) {
	.passwall-speedtest-chart-container {
		--card-bg: #282828;
		--text-color: #e6eef6;
		--card-shadow: 0 2px 6px rgba(0,0,0,0.6);
	}
}

.passwall-speedtest-chart-container canvas {
	display: block;
	width: 100%;
	height: 300px;
}
`);
}

function tableCss() {
	return E('style', {}, `
/* CM IP lists / per-node IP list 两张 TableSection 表：单元格居中、控件字体匹配表格 */
.cbi-section table.table th,
.cbi-section table.table td {
	text-align: center;
	vertical-align: middle;
}
.cbi-section table.table td select,
.cbi-section table.table td input,
.cbi-section table.table td .cbi-input-multi,
.cbi-section table.table td .cbi-multi,
.cbi-section table.table td .cbi-value-field {
	font-size: 0.85em;
	margin: 0 auto;
	text-align: center;
}
`);
}

// passwall 节点下拉的标签：socks 型（本地负载均衡入口等）列出来但标注不能被测——
// 脚本要把候选 IP 写进节点 address，而 socks 节点的 address 就是 SOCKS 服务器本身，
// 改写即失效。此前是直接从下拉里滤掉，用户会误以为"节点显示不全"。
function markSocks(n) {
	const socks = String(n.type || '').toLowerCase() === 'socks';
	return socks ? '%s (%s)'.format(n.label, _('Socks — cannot be tested through')) : n.label;
}

return view.extend({
	load: function() {
		return Promise.all([
			uci.load('passwall-speedtest'),
			callStatus(),
			callBestResult(),
			callHistory(),
			callListNodes()
		]);
	},

	updateStatus: function(node, status) {
		if (!node)
			return;

		const running = status && status.running;
		const cron = status && status.cron;

		node.replaceChildren(
			E('em', {}, [
				E('b', { style: 'color:%s'.format(running ? 'green' : 'red') },
					_('PassWall Speed Test') + ' ' + (running ? _('RUNNING') : _('NOT RUNNING')))
			]),
			' ',
			E('em', {}, [
				E('b', { style: 'color:%s'.format(cron ? 'green' : 'red') },
					cron ? _('Crontab enabled') : _('Crontab disabled'))
			])
		);
	},

	pollStatus: function(node, button) {
		return callStatus().then(L.bind(function(status) {
			const wasRunning = this._wasRunning;
			this._wasRunning = !!(status && status.running);
			this.updateStatus(node, status);
			this.updateButton(button, status && status.running);
			// 运行→停止跳变（点停止/定时任务跑完）时，重拉结果与历史并就地刷新，免手动刷新页面
			if (wasRunning && !this._wasRunning)
				return this.refreshResults();
		}, this));
	},

	// 重拉 Best IP 文本与历史图表，点停止/跑完后无需手动刷新页面即可看到新结果
	refreshResults: function() {
		return Promise.all([callBestResult(), callHistory()]).then(L.bind(function(res) {
			const best = res[0];
			const history = res[1] || [];
			const ta = document.getElementById('cbid.passwall-speedtest.global._best_result');
			if (ta)
				ta.value = (typeof best == 'string' ? best : (best && best.content) || '');
			const canvas = document.getElementById('passwall-speedtest-latency-chart');
			if (canvas && window.Chart) {
				const ex = Chart.getChart(canvas);
				if (ex) ex.destroy();
				this.drawCharts(canvas.closest('.passwall-speedtest-chart-container') || canvas.parentElement, history);
			}
		}, this)).catch(function() {});
	},

	updateButton: function(button, running) {
		if (!button)
			return;

		if (button.classList) {
			button.value = running ? _('Stop') : _('Start');
			button.textContent = running ? _('Stop') : _('Start');
			button.classList.toggle('cbi-button-reset', !!running);
			button.classList.toggle('cbi-button-apply', !running);
		}
		else {
			button.inputtitle = running ? _('Stop') : _('Start');
			button.inputstyle = running ? 'reset' : 'apply';
		}
	},

	drawCharts: function(root, dataPoints) {
		if (!root || !window.Chart || !dataPoints || !dataPoints.length)
			return;

		const latencyCanvas = root.querySelector('#passwall-speedtest-latency-chart');

		if (!latencyCanvas)
			return;

		// 每个配置节点一条线：按 passwall 多节点配置的节点序号分组，同序号（同一配置行）
		// 的历次「该节点最优 IP」连成一条线，序号未在当次结果中出现的运行自然断开。
		// 悬停 tooltip 与点击弹窗均显示「节点名：最优 IP / 延迟ms」。
		// 旧数据（result.csv 无节点列）退化为单条全局最优线。
		const runs = dataPoints.slice().sort((a, b) => (a.time > b.time ? 1 : (a.time < b.time ? -1 : 0)));
		const series = {};
		const seriesOrder = [];

		for (let i = 0; i < runs.length; i++) {
			const run = runs[i];
			const pts = (run.nodes && run.nodes.length)
				? run.nodes
				: [{ node: '', idx: null, ip: run.ip, latency: run.latency, speed: run.speed, region: run.region }];

			for (let j = 0; j < pts.length; j++) {
				const n = pts[j];
				const key = (n.idx != null) ? 'idx:' + n.idx : 'name:' + (n.node || '');

				if (!series[key]) {
					series[key] = [];
					seriesOrder.push(key);
				}

				series[key].push({ x: run.time, y: n.latency, node: n.node, ip: n.ip, speed: n.speed, region: n.region });
			}
		}

		const palette = [
			['rgba(75, 192, 192, 1)', 'rgba(75, 192, 192, 0.2)'],
			['rgba(255, 99, 132, 1)', 'rgba(255, 99, 132, 0.2)'],
			['rgba(54, 162, 235, 1)', 'rgba(54, 162, 235, 0.2)'],
			['rgba(255, 206, 86, 1)', 'rgba(255, 206, 86, 0.2)'],
			['rgba(153, 102, 255, 1)', 'rgba(153, 102, 255, 0.2)'],
			['rgba(255, 159, 64, 1)', 'rgba(255, 159, 64, 0.2)'],
			['rgba(46, 204, 113, 1)', 'rgba(46, 204, 113, 0.2)'],
			['rgba(231, 76, 60, 1)', 'rgba(231, 76, 60, 0.2)']
		];

		const datasets = seriesOrder.map(function(key, i) {
			const pts = series[key];
			// 图例取该序号最近一次的节点备注名（节点改名后显示当前名，悬停仍显示各点当时名称）
			const last = pts[pts.length - 1];

			return {
				label: last.node || _('Latency'),
				data: pts,
				borderColor: palette[i % palette.length][0],
				backgroundColor: palette[i % palette.length][1],
				tension: 0.3,
				fill: false,
				pointRadius: 4,
				pointHoverRadius: 6
			};
		});

		const timeScale = {
			type: 'time',
			time: {
				parser: 'yyyy-MM-dd HH:mm:ss',
				tooltipFormat: 'yyyy-MM-dd HH:mm:ss',
				unit: 'hour',
				displayFormats: { hour: 'MM-dd HH:mm' }
			},
			title: { display: true, text: _('Time') },
			offset: true,
			ticks: {
				autoSkip: true,
				maxTicksLimit: 6,
				maxRotation: 45,
				minRotation: 0
			}
		};

		new Chart(latencyCanvas, {
			type: 'line',
			data: {
				datasets: datasets
			},
			options: {
				responsive: true,
				interaction: { mode: 'nearest', intersect: true },
				onClick: function(evt, elements, chart) {
					const els = chart.getElementsAtEventForMode(evt, 'nearest', { intersect: true }, false);

					if (!els || !els.length)
						return;

					const p = chart.data.datasets[els[0].datasetIndex].data[els[0].index];

					// ui.showModal 不自带关闭按钮，Escape 也只在内容含 .right > button 时生效；
					// 不加按钮弹窗无法退出（只能刷新页面）
					ui.showModal(p.node || _('Node'), [
						E('div', {}, pointDetail(p)),
						E('div', { 'class': 'right' }, [
							E('button', {
								'class': 'btn',
								'click': function() { ui.hideModal(); }
							}, _('Close'))
						])
					]);
				},
				plugins: {
					tooltip: {
						mode: 'nearest',
						intersect: true,
						callbacks: {
							title: ctx => _('Time') + ': ' + (ctx[0].raw.x || ''),
							label: ctx => pointLabel(ctx.raw)
						}
					},
					legend: { position: 'top' }
				},
				scales: {
					x: timeScale,
					y: {
						type: 'linear',
						title: { display: true, text: _('Latency') + ' (ms)' }
					}
				}
			}
		});

		function pointLabel(p) {
			return '%s：最优 %s / %sms'.format(p.node || '-', p.ip, p.y) +
				(p.speed > 0 ? ' / %s MB/s'.format(p.speed) : '');
		}

		function pointDetail(p) {
			return [
				E('p', {}, pointLabel(p)),
				E('p', {}, _('Time') + ': ' + (p.x || '')),
				(p.speed > 0 ? E('p', {}, _('Download speed') + ': ' + p.speed + ' MB/s') : E([])),
				(p.region ? E('p', {}, _('Region') + ': ' + p.region) : E([]))
			];
		}
	},

	render: function(data) {
		let m, s, o;
		let actionButton;
		const status = data[1] || {};
		const bestResult = data[2] || '';
		const history = data[3] || [];
		const nodes = data[4] || {};
		this._wasRunning = !!(status && status.running);
		const passwallNodes = (nodes.passwall && nodes.passwall.nodes) || [];

		m = new form.Map('passwall-speedtest', _('PassWall Speed Test'),
			_('Schedules and runs a PassWall node-based Cloudflare IP test: latency screening first, then a real download test on the fastest candidates; the best IP is written back to the selected passwall nodes and other integrations') +
			'<br><a href="https://github.com/urbanescavenger/luci-app-passwall-speedtest" target="_blank">⭐ ' + _('Star on GitHub') + '</a>');

		s = m.section(form.NamedSection, 'global', 'global');
		s.addremove = false;

		s.tab('basic', _('Basic Settings'));

		o = s.taboption('basic', form.Button, '_speedtest', _('Speed test'),
			_('Two-stage test through the selected passwall node(s): first probes every candidate Cloudflare IP via a local SOCKS and measures HTTP HEAD latency (<code>time_pretransfer</code>); then downloads a real file through up to 5 lowest-latency IPs of each worker to measure actual throughput. The best IP by download speed is written back to each passwall worker node (if every download test fails, the latency ranking is kept).'));
		this.updateButton(o, status.running);
		actionButton = o;
		o.onclick = L.bind(function(ev, sectionId) {
			const button = ev.currentTarget;
			const statusNode = document.getElementById('passwall-speedtest-status');
			const view = this;
			button.disabled = true;

			return callStatus().then(function(st) {
				if (!st.running) {
					// 未运行 → 启动，跳日志页
					return callStart().then(function() {
						window.setTimeout(function() {
							window.location = L.url('admin/services/passwall-speedtest/logread');
						}, 500);
					});
				}
				// 运行中 → 停止：协作式收尾。用户停止第一轮后，脚本仍会把已通过 IP 的下载
				// 实测做完（多 worker 串行，最多 5 个/worker × 单 IP 时限），再写回并重启
				// passwall，因此可能比原来的 ~timeout×probes 长很多。这里按 2s 轮询到真正
				// 退出（最多约 20 分钟，与 rpcd 的 1200s 收尾宽限一致）；s.running 仍为真时
				// 保持 Stop，不谎报已停止。
				return callStop().then(function() {
					const waitStopped = function(tries) {
						tries = tries || 0;
						return callStatus().then(function(s) {
							view.updateStatus(statusNode, s);
							if (s && s.running && tries < 610) {
								return new Promise(function(r) { window.setTimeout(r, 2000); })
									.then(function() { return waitStopped(tries + 1); });
							}
							view.updateButton(button, s && s.running);
							return view.refreshResults();
						});
					};
					return waitStopped();
				});
			}).catch(function(e) {
				ui.addNotification(null, E('p', {}, e.message));
			}).finally(function() {
				button.disabled = false;
			});
		}, this);

		o = s.taboption('basic', form.Button, '_retest', _('Retest current best IPs'),
			_('Runs ONE latency round + the download test only on the IPs already in the current best list (result.csv) and each node\'s current address. The online IP list is NOT re-downloaded. The best IP is written back as usual.'));
		o.onclick = function(ev) {
			const button = ev.currentTarget;
			button.disabled = true;

			return callStatus().then(function(st) {
				if (st.running) {
					ui.addNotification(null, E('p', {}, _('A test is already running')));
					return;
				}
				return callRetest().then(function() {
					window.setTimeout(function() {
						window.location = L.url('admin/services/passwall-speedtest/logread');
					}, 500);
				});
			}).catch(function(e) {
				ui.addNotification(null, E('p', {}, e.message));
			}).finally(function() {
				button.disabled = false;
			});
		};

		o = s.taboption('basic', form.ListValue, 'ip_source', _('IP list source'),
			_('Select the built-in Cloudflare IP list, an online CM source, or a custom file used as candidates'));
		o.value('builtin_ipv4', _('Built-in IPv4 list'));
		o.value('builtin_ipv6', _('Built-in IPv6 list'));
		o.value('online', _('Online CM source'));
		o.value('custom_file', _('Custom file'));
		o.default = 'builtin_ipv4';
		o.rmempty = false;

		o = s.taboption('basic', form.Value, 'ip_online_url', _('Online source URL'),
			_('Source list in <code>IP:PORT#country</code> format. Shared by all 5 CM IP lists below; each list keeps only its own port.'));
		o.depends('ip_source', 'online');
		o.default = 'https://zip.cm.edu.kg/all.txt';
		o.rmempty = false;

		o = s.taboption('basic', form.Value, 'custom_ip_file', _('Custom IP list file'),
			_('Enter a local file path, for example: /etc/passwall-speedtest/ip.txt'));
		o.depends('ip_source', 'custom_file');
		o.rmempty = true;
		o.validate = function(sectionId, value) {
			const ipSource = this.section.formvalue(sectionId, 'ip_source');

			if (ipSource == 'custom_file' && !value)
				return _('Custom IP list file is required when using Custom file');

			return true;
		};

		o = s.taboption('basic', form.Flag, 'custom_allip', _('Scan all IPs in each /24'),
			_('Only applies to custom IP lists. Disabled by default: one random IP per /24 is tested. Enable to test every IP in each /24 (slower).'));
		o.depends('ip_source', 'custom_file');
		o.default = o.disabled;
		o.rmempty = false;

		o = s.taboption('basic', form.Value, 'tl', _('Latency cap (ms)'),
			_('Discard candidate IPs whose average latency is above this threshold (measured via the node\'s local SOCKS).'));
		o.datatype = 'uinteger';
		o.default = '200';
		o.rmempty = false;

		o = s.taboption('basic', form.Value, 'tll', _('Latency lower bound (ms)'),
			_('Discard candidate IPs whose average latency is below this threshold.'));
		o.datatype = 'uinteger';
		o.default = '40';
		o.rmempty = false;

		o = s.taboption('basic', form.Value, 'tlr', _('Packet loss rate cap'),
			_('Discard candidate IPs whose packet loss ratio exceeds this value (0–1).'));
		o.datatype = 'ufloat';
		o.default = '0.2';
		o.rmempty = false;

		o = s.taboption('basic', form.ListValue, 'node_test_node', _('Passwall node to test through (single-node fallback)'),
			_('Used only when no passwall workers are selected in the Third-Party tab. Select a CF-CDN-fronted passwall node (VLESS/VMess/Trojan/SS…). Its <em>address</em> will be cycled through candidate IPs and finally set to the fastest one. SOCKS-type nodes (e.g. a local load-balance entry) are listed but cannot be tested through — their <em>address</em> is the SOCKS server itself.'));
		o.value('', _('-- Please choose --'));
		passwallNodes.forEach(function(n) { o.value(n.value, markSocks(n)); });
		o.rmempty = true;

		o = s.taboption('basic', form.ListValue, 'stable_node', _('Passwall stable node (required)'),
			_('During a speed test, passwall\'s global node is temporarily switched to this stable node and restored afterwards, so your live traffic is unaffected by the tested nodes\' <em>address</em> being rewritten. <strong>Required.</strong> Must NOT equal the tested node (single-node fallback) or any selected passwall worker node. If your current global node is a shunt (分流) node, its shunt rules are suspended for the duration of the test and all traffic goes through this stable node.'));
		o.value('', _('-- Please choose --'));
		passwallNodes.forEach(function(n) { o.value(n.value, n.label); });
		o.rmempty = false;
		o.validate = function(section_id, value) {
			if (!value || !value.length) return _('Please choose a stable node');
			return true;
		};

		o = s.taboption('basic', form.Value, 'node_test_url', _('Probe URL'),
			_('URL probed via the node\'s local SOCKS; only the HTTP HEAD latency is measured. generate_204 / connectivity-check endpoints are preferred.'));
		o.default = 'https://www.google.com/generate_204';
		o.value('https://www.google.com/generate_204', 'Google');
		o.value('https://www.gstatic.com/generate_204', 'Gstatic');
		o.value('https://speed.cloudflare.com/__down?bytes=1', 'Cloudflare');
		o.value('https://connect.rom.miui.com/generate_204', 'MIUI (CN)');
		o.value('https://connectivitycheck.platform.hicloud.com/generate_204', 'HiCloud (CN)');
		o.rmempty = false;

		o = s.taboption('basic', form.Value, 'node_test_count', _('Max IPs to test'),
			_('This mode tests IPs through the node (~3-7s each). Cap the count to avoid long runs. With the online CM source the cap is applied <strong>per CM IP list, per worker</strong>, so 5 lists × count × workers × probes can multiply quickly — keep count modest unless you need thoroughness.'));
		o.datatype = 'uinteger';
		o.default = '30';
		o.rmempty = false;

		o = s.taboption('basic', form.Value, 'node_test_timeout', _('Probe timeout (s)'),
			_('Per-IP curl <code>--max-time</code> in seconds.'));
		o.datatype = 'uinteger';
		o.default = '5';
		o.rmempty = false;

		o = s.taboption('basic', form.Value, 'node_test_probes', _('Probes per IP'),
			_('How many curl probes per candidate IP. Each probe is a full SOCKS+curl, so higher values are slower. If <strong>any</strong> single probe fails, that IP is discarded immediately and the remaining probes are skipped — only IPs that succeed on <em>all</em> probes are kept, so the best IP is a stable one.'));
		o.datatype = 'uinteger';
		o.default = '3';
		o.rmempty = false;

		o = s.taboption('basic', form.Value, 'node_test_threads', _('Max parallel workers'),
			_('Cap on concurrently running passwall workers (only relevant when passwall nodes are selected in the Third-Party tab). 0 means run all workers at once. Each worker runs its own SOCKS+curl chain, so high values need more RAM/CPU — keep ≤ node count and mind router limits.'));
		o.datatype = 'uinteger';
		o.default = '5';
		o.rmempty = false;

		o = s.taboption('basic', form.Flag, 'download_test_enabled', _('Real download speed test'),
			_('After latency screening, download a real file through up to 5 lowest-latency IPs of each worker to measure actual throughput (MB/s). The final best IP is chosen by download speed; IPs whose download test fails are dropped. If every download test fails (e.g. the URL is unreachable through that node), the latency ranking is kept. Each download runs through the node\'s local SOCKS exactly like the latency probe, and the generated SOCKS config is verified to point at the candidate IP before it is accepted.'));
		o.default = '1';
		o.rmempty = false;

		o = s.taboption('basic', form.Value, 'download_test_count', _('Download-test candidates per worker'),
			_('Only the N lowest-latency IPs of each worker are download-tested (default 5, max 5). Each candidate downloads the file below (10 MB by default), so keep it small to limit proxy traffic and runtime.'));
		o.datatype = 'uinteger';
		o.default = '5';
		o.depends('download_test_enabled', '1');
		o.rmempty = false;
		o.validate = function(sectionId, value) {
			if (value && parseInt(value, 10) > 5)
				return _('At most 5 IPs can be download-tested per worker');
			return true;
		};

		o = s.taboption('basic', form.Value, 'download_test_url', _('Download test URL'),
			_('A fixed-size file downloaded through the node\'s local SOCKS. Cloudflare\'s speed endpoint works best for CF-fronted nodes. The response must be HTTP 2xx with at least 16 KB.'));
		o.default = 'https://speed.cloudflare.com/__down?bytes=10000000';
		o.value('https://speed.cloudflare.com/__down?bytes=10000000', _('Cloudflare 10 MB'));
		o.value('https://speed.cloudflare.com/__down?bytes=20000000', _('Cloudflare 20 MB'));
		o.depends('download_test_enabled', '1');
		o.rmempty = false;

		o = s.taboption('basic', form.Value, 'download_test_time', _('Download test time limit (s)'),
			_('Per-IP curl <code>--max-time</code> for the download test. A partial transfer cut off by this limit still yields a valid average speed.'));
		o.datatype = 'uinteger';
		o.default = '10';
		o.depends('download_test_enabled', '1');
		o.rmempty = false;

		o = s.taboption('basic', form.Flag, 'iterate_enabled', _('Time-boxed iterative test'),
			_('Run the test in time-boxed mode: each tested node runs its own independent loop until the duration elapses. After its first pass, a node only re-tests the IPs that passed its previous pass, so its candidate pool shrinks toward the most stable, lowest-latency IPs. Nothing is written to result.csv or passwall during the run; when the timer ends, each node\'s best remaining IP is written back.'));
		o.default = o.disabled;
		o.rmempty = false;

		o = s.taboption('basic', form.Value, 'iterate_minutes', _('Iterative test duration (minutes)'),
			_('Total wall-clock budget for the iterative test. The run stops after the round that is in progress when the deadline passes.'));
		o.datatype = 'uinteger';
		o.depends('iterate_enabled', '1');
		o.default = '30';
		o.rmempty = false;
		o.validate = function(sectionId, value) {
			const enabled = this.section.formvalue(sectionId, 'iterate_enabled');

			if (enabled == '1' && (!value || parseInt(value, 10) < 1))
				return _('Duration must be at least 1 minute when the iterative test is enabled');

			return true;
		};

		s.tab('cron', _('Crontab Settings'));

		o = s.taboption('cron', form.Flag, 'enabled', _('Enabled'),
			_('Enable scheduled task to test the selected IP list'));
		o.default = o.disabled;
		o.rmempty = false;

		o = s.taboption('cron', form.Flag, 'custom_cron_enabled', _('Enable custom cron'));
		o.default = o.disabled;
		o.rmempty = false;

		o = s.taboption('cron', form.Value, 'custom_cron', _('Custom Cron'), _('Example: 0 */3 * * *'));
		o.depends('custom_cron_enabled', '1');

		o = s.taboption('cron', form.ListValue, 'hour', _('Interval'));
		o.depends('custom_cron_enabled', '0');
		[1, 2, 3, 4, 6, 8, 12, 24].forEach(function(hour) {
			o.value(hour, _('Every %d hour(s)').format(hour));
		});
		o.default = '24';

		// ── 五个 CM 备选 IP 列表（共享 ip_online_url，仅国家/端口筛选不同）──
		// 始终渲染，通过 data-depends 联动 ip_source 动态显隐（见 m.render().then 中的 cbi_d_add 注册）。
		s = m.section(form.TableSection, 'ip_list', _('CM IP lists (per-country)'),
			_('Define up to 5 CM-source IP lists. All share the online URL above; each filters by its own country set and port. Assign one list per passwall worker node in the Third-Party tab. Workers without an explicit list use the first enabled list. Only used when IP list source = Online CM source. Note: the port only picks the candidates — the port actually probed is the worker node\'s own port, so set the node to the same port.'));
		s.addremove = false;
		s.anonymous = false;
		s.nodescriptions = true;

		o = s.option(form.Flag, 'enabled', _('Enabled'));
		o.rmempty = false;

		o = s.option(form.Value, 'name', _('Name'),
			_('Display label for this list, shown in the per-node dropdown.'));
		o.rmempty = true;

		o = s.option(form.MultiValue, 'regions', _('Country filter'),
			_('Only keep IPs tagged with the selected countries. Leave none selected to keep every country on this port.'));
		o.value('JP', _('Japan'));
		o.value('SG', _('Singapore'));
		o.value('KR', _('South Korea'));
		o.value('HK', _('Hong Kong'));
		o.value('TW', _('Taiwan'));
		o.value('TH', _('Thailand'));
		o.value('VN', _('Vietnam'));
		o.value('ID', _('Indonesia'));
		o.value('PH', _('Philippines'));
		o.value('MY', _('Malaysia'));
		o.value('IN', _('India'));
		o.value('KH', _('Cambodia'));
		o.value('DE', _('Germany'));
		o.value('NL', _('Netherlands'));
		o.value('FR', _('France'));
		o.value('GB', _('United Kingdom'));
		o.value('FI', _('Finland'));
		o.value('SE', _('Sweden'));
		o.value('CH', _('Switzerland'));
		o.value('RU', _('Russia'));
		o.value('TR', _('Turkey'));
		o.value('UA', _('Ukraine'));
		o.value('US', _('United States'));
		o.value('CA', _('Canada'));
		o.value('BR', _('Brazil'));
		o.value('AU', _('Australia'));
		o.value('AE', _('United Arab Emirates'));
		o.value('ZA', _('South Africa'));

		o = s.option(form.Value, 'port', _('Port'),
			_('Keep only source entries on this port (Cloudflare serves 443 / 8443 / 2053 / 2083 / 2087 / 2096). Default 443.'));
		o.datatype = 'port';
		o.default = '443';
		o.rmempty = false;

		s = m.section(form.NamedSection, 'global', 'global', _('Best IP'));
		s.addremove = false;
		o = s.option(form.TextValue, '_best_result');
		o.rows = 8;
		o.readonly = true;
		o.wrap = 'off';
		o.cfgvalue = function() {
			return typeof bestResult == 'string' ? bestResult : (bestResult.content || '');
		};
		o.write = function() {};

		return m.render().then(L.bind(function(formNode) {
			const statusNode = E('p', { id: 'passwall-speedtest-status' }, _('Collecting data...'));
			this.updateStatus(statusNode, status);
			// 真实 DOM 按钮（option 对象改 inputtitle 不会更新已渲染 DOM，轮询必须拿 DOM 元素）
			const domButton = formNode.querySelector('[name="cbid.passwall-speedtest.global._speedtest"]');

			const chartNode = E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('History Charts')),
				chartCss(),
				E('div', { 'class': 'passwall-speedtest-chart-container' }, [
					E('canvas', { id: 'passwall-speedtest-latency-chart' })
				])
			]);

			const root = E([], [
				E('div', { 'class': 'cbi-section' }, [ statusNode ]),
				formNode
			]);

			const formActions = formNode.querySelector('.cbi-page-actions');

			if (formActions && formActions.parentNode)
				formActions.parentNode.insertBefore(chartNode, formActions);
			else
				formNode.appendChild(chartNode);

			// CM IP lists 表格格式：单元格居中、控件字体匹配表格紧凑尺寸
			formNode.insertBefore(tableCss(), formNode.firstChild);

			// 联动显隐：ip_source != online 时隐藏「CM IP lists」TableSection
			// 通过 LuCI CBI 的 data-depends 机制实现，无需页面刷新。
			// cbi_init() 在 DOMContentLoaded 时已执行，所以这里手动调用 cbi_d_add。
			// 注意：不能在这里调 cbi_d_update()——此时 formNode 尚未挂载到 document，
			// document.getElementById() 找不到 detached 元素，cbi_tag_last 会因
			// parent=null 而抛 TypeError。改为手动设置初始显隐；后续用户切换
			// ip_source 时 cbi_d_update() 正常触发，依赖系统接管。
			var ipListContainer = null;
			formNode.querySelectorAll('h2, h3, h4, h5, legend, .cbi-section-title').forEach(function(h) {
				if (/CM IP lists/.test(h.textContent)) {
					ipListContainer = h.closest('.cbi-section') || h.closest('fieldset') || h.closest('div');
				}
			});
			if (ipListContainer) {
				// cbi_d_update 通过 document.getElementById(entry.id) 查找元素，
				// 确保容器有 id（LuCI 通常已设置，此处兜底）。
				if (!ipListContainer.id)
					ipListContainer.id = 'cbi-passwall-speedtest-ip_list';
				var ipListIdx = Array.prototype.indexOf.call(ipListContainer.parentNode.children, ipListContainer);
				ipListContainer.setAttribute('data-depends',
					JSON.stringify([{'cbid.passwall-speedtest.global.ip_source': 'online'}]));
				ipListContainer.setAttribute('data-index', String(ipListIdx));
				if (typeof cbi_d_add === 'function') {
					cbi_d_add(ipListContainer,
						{ 'cbid.passwall-speedtest.global.ip_source': 'online' }, ipListIdx);
				}
				// 初始显隐：formNode 尚未挂载，手动设置；后续由 cbi_d_update 接管
				if (uci.get('passwall-speedtest', 'global', 'ip_source') !== 'online')
					ipListContainer.style.display = 'none';
			}

			poll.add(L.bind(this.pollStatus, this, statusNode, domButton), 3);

			script(L.resource('passwall-speedtest/chart.js')).then(function() {
				return script(L.resource('passwall-speedtest/chartjs-adapter-date-fns.js'));
			}).then(L.bind(function() {
				this.drawCharts(chartNode, history);
			}, this));

			return root;
		}, this));
	}
});