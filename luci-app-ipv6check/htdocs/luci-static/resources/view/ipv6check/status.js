'use strict';
'require view';
'require rpc';
'require poll';
'require dom';

/* IPv6 Connectivity Check - Status page */

var callGetStatus = rpc.declare({
	object: 'ipv6check',
	method: 'get_status',
	expect: {}
});

var callGetLog = rpc.declare({
	object: 'ipv6check',
	method: 'get_log',
	params: ['lines'],
	expect: {}
});

var callGetRestartHistory = rpc.declare({
	object: 'ipv6check',
	method: 'get_restart_history',
	expect: {}
});

var callRunCheck = rpc.declare({
	object: 'ipv6check',
	method: 'run_check',
	expect: {}
});

var callRestartInterface = rpc.declare({
	object: 'ipv6check',
	method: 'restart_interface',
	params: ['interface'],
	expect: {}
});

function statusMap() {
	return {
		'ok':      { text: '✅ ' + _('All reachable'),   color: '#2ecc71', bg: 'rgba(46,204,113,0.1)' },
		'partial': { text: '⚠️ ' + _('Partial'),          color: '#f39c12', bg: 'rgba(243,156,18,0.1)' },
		'fail':    { text: '❌ ' + _('All unreachable'),  color: '#e74c3c', bg: 'rgba(231,76,60,0.1)' },
		'unknown': { text: '❓ ' + _('Unknown'),          color: '#95a5a6', bg: 'rgba(149,165,166,0.1)' }
	};
}

/* 构建样式表 */
function injectStyles() {
	if (document.getElementById('ipv6check-status-style'))
		return;

	var style = document.createElement('style');
	style.id = 'ipv6check-status-style';
	style.textContent = [
		/* base container */
		'.ipv6check-wrap { font-family: "Segoe UI", "PingFang SC", "Microsoft YaHei", sans-serif; }',
		'.ipv6check-card { background: #fff; border-radius: 8px; box-shadow: 0 2px 12px rgba(0,0,0,0.08); padding: 20px; margin-bottom: 16px; border: 1px solid #e8e8e8; }',
		'.ipv6check-card h3 { margin: 0 0 16px 0; font-size: 16px; color: #333; border-bottom: 2px solid #4a90d9; padding-bottom: 8px; }',
		/* overview stats */
		'.ipv6check-overview { display: flex; gap: 16px; flex-wrap: wrap; margin-bottom: 16px; }',
		'.ipv6check-stat { flex: 1; min-width: 160px; padding: 16px; border-radius: 8px; text-align: center; }',
		'.ipv6check-stat .label { font-size: 12px; color: #888; margin-bottom: 4px; }',
		'.ipv6check-stat .value { font-size: 22px; font-weight: 700; }',
		/* target list */
		'.ipv6check-targets { display: grid; gap: 10px; }',
		'.ipv6check-target { display: flex; align-items: center; justify-content: space-between; padding: 12px 16px; border-radius: 6px; border: 1px solid #eee; background: #fafafa; transition: all 0.2s; }',
		'.ipv6check-target:hover { box-shadow: 0 2px 8px rgba(0,0,0,0.06); }',
		'.ipv6check-target .name { font-weight: 600; color: #333; }',
		'.ipv6check-target .host { font-family: "Consolas", "Courier New", monospace; font-size: 13px; color: #666; }',
		'.ipv6check-target > div:first-child { min-width: 0; }',
		'.ipv6check-target > div:last-child { flex-shrink: 0; text-align: right; }',
		'.ipv6check-target .status-badge { padding: 4px 12px; border-radius: 20px; font-size: 12px; font-weight: 600; }',
		'.status-ok { background: rgba(46,204,113,0.15); color: #27ae60; }',
		'.status-fail { background: rgba(231,76,60,0.15); color: #c0392b; }',
		/* action buttons */
		'.ipv6check-actions { display: flex; gap: 10px; margin-bottom: 16px; }',
		'.ipv6check-btn { padding: 8px 20px; border: none; border-radius: 6px; font-size: 14px; font-weight: 600; cursor: pointer; transition: all 0.2s; }',
		'.ipv6check-btn:hover { transform: translateY(-1px); box-shadow: 0 4px 12px rgba(0,0,0,0.15); }',
		'.ipv6check-btn:active { transform: translateY(0); }',
		'.ipv6check-btn:disabled { opacity: 0.5; cursor: not-allowed; transform: none; }',
		'.btn-primary { background: #4a90d9; color: #fff; }',
		'.btn-warning { background: #e67e22; color: #fff; }',
		/* log area */
		'.ipv6check-log { background: #1e1e2e; color: #cdd6f4; padding: 16px; border-radius: 8px; font-family: "Consolas", "Courier New", monospace; font-size: 12px; line-height: 1.6; max-height: 400px; overflow-y: auto; white-space: pre-wrap; word-break: break-all; }',
		/* info rows */
		'.ipv6check-info-row { display: flex; justify-content: space-between; padding: 8px 0; border-bottom: 1px solid #f0f0f0; }',
		'.ipv6check-info-row:last-child { border-bottom: none; }',
		'.ipv6check-info-row .key { color: #888; font-size: 13px; }',
		'.ipv6check-info-row .val { color: #333; font-size: 13px; font-weight: 500; }',
		/* spinner */
		'.ipv6check-spinner { display: inline-block; width: 16px; height: 16px; border: 2px solid rgba(255,255,255,0.3); border-top-color: #fff; border-radius: 50%; animation: ipv6spin 0.6s linear infinite; margin-right: 6px; vertical-align: middle; }',
		'@keyframes ipv6spin { to { transform: rotate(360deg); } }',
		'@media (max-width: 640px) { .ipv6check-actions { flex-direction: column; } .ipv6check-target { align-items: flex-start; flex-direction: column; gap: 8px; } .ipv6check-target > div:last-child { text-align: left; } .ipv6check-info-row { align-items: flex-start; flex-direction: column; gap: 4px; } }'
	].join('\n');
	document.head.appendChild(style);
}

/* 创建 DOM 元素的辅助函数 */
function E(tag, attrs, children) {
	var el = document.createElement(tag);
	if (attrs) {
		Object.keys(attrs).forEach(function(k) {
			if (k === 'style' && typeof attrs[k] === 'object') {
				Object.assign(el.style, attrs[k]);
			} else if (k.substring(0, 2) === 'on') {
				el.addEventListener(k.substring(2), attrs[k]);
			} else {
				el.setAttribute(k, attrs[k]);
			}
		});
	}
	if (children) {
		(Array.isArray(children) ? children : [children]).forEach(function(c) {
			if (typeof c === 'string') el.appendChild(document.createTextNode(c));
			else if (c) el.appendChild(c);
		});
	}
	return el;
}

return view.extend({
	handleSaveApply: null,
	handleSave: null,
	handleReset: null,

	load: function() {
		return Promise.all([
			callGetStatus(),
			callGetLog(80),
			callGetRestartHistory()
		]);
	},

	render: function(data) {
		injectStyles();

		var wrap = E('div', { 'class': 'ipv6check-wrap' });

		/*
		 * 日志区域使用持久化 DOM 节点：
		 * 轮询时只更新 textContent，不重建节点，避免滚动位置被重置
		 */
		var logContentEl = E('div', { 'class': 'ipv6check-log' });
		var historyContentEl = E('div', { 'class': 'ipv6check-log', 'style': { maxHeight: '200px' } });

		var logCard = E('div', { 'class': 'ipv6check-card' }, [
			E('h3', {}, '📋 ' + _('Detection Log')),
			logContentEl
		]);
		var historyCard = E('div', { 'class': 'ipv6check-card' }, [
			E('h3', {}, '🔄 ' + _('Interface Restart History')),
			historyContentEl
		]);

		var reloadData = function() {
			return Promise.all([
				callGetStatus(),
				callGetLog(80),
				callGetRestartHistory()
			]);
		};

		var updateView = function(data) {
			var status = data[0] || {};
			var logData = data[1] || {};
			var historyData = data[2] || {};

			/* 仅更新日志文本，不重建节点，保留用户滚动位置 */
			logContentEl.textContent = logData.log || _('No log entries.');
			historyContentEl.textContent = historyData.history || _('No restart records.');

			var map = statusMap();
			var overallInfo = map[status.overall] || map['unknown'];
			var targets = status.targets || [];

			var content = document.createDocumentFragment();

			/* ===== 操作按钮 ===== */
			var actionsDiv = E('div', { 'class': 'ipv6check-actions' });

			var checkBtn = E('button', {
				'class': 'ipv6check-btn btn-primary',
				'onclick': function() {
					checkBtn.disabled = true;
					checkBtn.innerHTML = '<span class="ipv6check-spinner"></span>' + _('Checking...');
					callRunCheck().then(function() {
						return reloadData();
					}).then(function(newData) {
						updateView(newData);
					}).catch(function() {
						checkBtn.disabled = false;
						checkBtn.textContent = '🔍 ' + _('Check Now');
					});
				}
			}, '🔍 ' + _('Check Now'));

			var restartBtn = E('button', {
				'class': 'ipv6check-btn btn-warning',
				'onclick': function() {
					var iface = status.restart_interface || 'wan6';
					if (!confirm(_('Restart interface ') + iface + '?')) return;
					restartBtn.disabled = true;
					restartBtn.innerHTML = '<span class="ipv6check-spinner"></span>' + _('Restarting...');
					callRestartInterface(iface).then(function() {
						setTimeout(function() {
							reloadData()
								.then(updateView)
								.catch(function() {
									restartBtn.disabled = false;
									restartBtn.textContent = _('Restart Interface') + ' (' + iface + ')';
								});
						}, 5000);
					}).catch(function() {
						restartBtn.disabled = false;
						restartBtn.textContent = _('Restart Interface') + ' (' + iface + ')';
					});
				}
			}, _('Restart Interface') + ' (' + (status.restart_interface || 'wan6') + ')');

			actionsDiv.appendChild(checkBtn);
			actionsDiv.appendChild(restartBtn);
			content.appendChild(actionsDiv);

			/* ===== 总览卡片 ===== */
			var overviewCard = E('div', { 'class': 'ipv6check-card' });
			overviewCard.appendChild(E('h3', {}, '\ud83d\udcca ' + _('Connectivity Overview')));

			var overviewGrid = E('div', { 'class': 'ipv6check-overview' });

			/* 整体状态 */
			overviewGrid.appendChild(E('div', {
				'class': 'ipv6check-stat',
				'style': { background: overallInfo.bg, border: '1px solid ' + overallInfo.color + '33' }
			}, [
				E('div', { 'class': 'label' }, _('Overall Status')),
				E('div', { 'class': 'value', 'style': { color: overallInfo.color } }, overallInfo.text)
			]));

			/* 检测时间 */
			overviewGrid.appendChild(E('div', {
				'class': 'ipv6check-stat',
				'style': { background: '#f0f4ff', border: '1px solid #d0dcf0' }
			}, [
				E('div', { 'class': 'label' }, _('Last Check')),
				E('div', { 'class': 'value', 'style': { fontSize: '14px', color: '#4a90d9' } },
					status.check_time || _('Never'))
			]));

			/* 检测统计 */
			overviewGrid.appendChild(E('div', {
				'class': 'ipv6check-stat',
				'style': { background: '#f0fff4', border: '1px solid #d0f0dc' }
			}, [
				E('div', { 'class': 'label' }, _('Target Pass Rate')),
				E('div', { 'class': 'value', 'style': { color: '#27ae60' } },
					(status.total_targets || 0) - (status.failed_targets || 0) + '/' + (status.total_targets || 0))
			]));

			/* 连续失败 */
			var failColor = (status.consecutive_failures || 0) > 0 ? '#e74c3c' : '#27ae60';
			overviewGrid.appendChild(E('div', {
				'class': 'ipv6check-stat',
				'style': { background: (status.consecutive_failures || 0) > 0 ? 'rgba(231,76,60,0.05)' : '#f0fff4',
				           border: '1px solid ' + failColor + '33' }
			}, [
				E('div', { 'class': 'label' }, _('Consecutive Failures')),
				E('div', { 'class': 'value', 'style': { color: failColor } },
					(status.consecutive_failures || 0) + '/' + (status.failure_threshold || 3))
			]));

			overviewCard.appendChild(overviewGrid);
			content.appendChild(overviewCard);

			/* ===== 目标详情卡片 ===== */
			var targetsCard = E('div', { 'class': 'ipv6check-card' });
			targetsCard.appendChild(E('h3', {}, _('Detection Targets')));

			var targetsGrid = E('div', { 'class': 'ipv6check-targets' });

			if (targets.length === 0) {
				targetsGrid.appendChild(E('div', {
					'style': { padding: '20px', textAlign: 'center', color: '#999' }
				}, _('No targets configured. Please go to Configuration to add targets.')));
			} else {
				targets.forEach(function(t) {
					var isOk = t.status === 'ok';
					targetsGrid.appendChild(E('div', { 'class': 'ipv6check-target' }, [
						E('div', {}, [
							E('div', { 'class': 'name' }, t.name || _('Unnamed')),
							E('div', { 'class': 'host' }, t.host || '')
						]),
						E('div', {}, [
							E('span', { 'class': 'status-badge ' + (isOk ? 'status-ok' : 'status-fail') },
								isOk ? _('Reachable') : _('Unreachable')),
							E('span', { 'style': { marginLeft: '10px', fontSize: '12px', color: '#999' } },
								t.last_check || '')
						])
					]));
				});
			}

			targetsCard.appendChild(targetsGrid);
			content.appendChild(targetsCard);

			/* ===== 运行信息卡片 ===== */
			var infoCard = E('div', { 'class': 'ipv6check-card' });
			infoCard.appendChild(E('h3', {}, 'ℹ️ ' + _('Runtime Info')));

			var infoRows = [
				[_('Check Interval'), (status.interval || 300) + ' ' + _('seconds')],
				[_('Auto Restart'), status.auto_restart ? _('Enabled') : _('Disabled')],
				[_('Restart Interface'), status.restart_interface || 'wan6'],
				[_('Failure Threshold'), (status.failure_threshold || 3) + ' ' + _('consecutive failures before restart')],
				[_('Last Restart'), status.last_restart || _('Never')]
			];

			infoRows.forEach(function(row) {
				infoCard.appendChild(E('div', { 'class': 'ipv6check-info-row' }, [
					E('span', { 'class': 'key' }, row[0]),
					E('span', { 'class': 'val' }, row[1])
				]));
			});

			content.appendChild(infoCard);

			/*
			 * 日志卡片和历史卡片复用持久化节点，追加到 fragment 末尾。
			 * dom.content 会将旧子节点替换为 fragment 内容，
			 * 但 logCard / historyCard 节点对象本身不变，内部滚动位置得以保留。
			 */
			content.appendChild(logCard);
			content.appendChild(historyCard);

			dom.content(wrap, content);
		};

		updateView(data);

		/*
		 * 轮询间隔与后端检测间隔对齐：
		 * 取 status.interval（后端配置值）的一半，最小 30s，最大 120s。
		 * 避免前端以 30s 固定间隔轮询，而后端 300s 才跑一次检测的浪费。
		 */
		var backendInterval = (data[0] || {}).interval || 300;
		var pollInterval = Math.max(30, Math.min(Math.floor(backendInterval / 2), 120));

		poll.add(function() {
			return reloadData().then(function(newData) {
				updateView(newData);
			}).catch(function() {
				return null;
			});
		}, pollInterval);

		return wrap;
	}
});
