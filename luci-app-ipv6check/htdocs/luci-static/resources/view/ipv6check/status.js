'use strict';
'require view';
'require rpc';
'require poll';
'require dom';

/* IPv6 连通性检测 - 运行状态页面 */

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

/* 状态文本与颜色映射 */
var statusMap = {
	'ok':      { text: '✅ 全部可达',   color: '#2ecc71', bg: 'rgba(46,204,113,0.1)' },
	'partial': { text: '⚠️ 部分可达',   color: '#f39c12', bg: 'rgba(243,156,18,0.1)' },
	'fail':    { text: '❌ 全部不可达', color: '#e74c3c', bg: 'rgba(231,76,60,0.1)' },
	'unknown': { text: '❓ 未知',       color: '#95a5a6', bg: 'rgba(149,165,166,0.1)' }
};

/* 构建样式表 */
function injectStyles() {
	if (document.getElementById('ipv6check-status-style'))
		return;

	var style = document.createElement('style');
	style.id = 'ipv6check-status-style';
	style.textContent = [
		/* 基础容器 */
		'.ipv6check-wrap { font-family: "Segoe UI", "PingFang SC", "Microsoft YaHei", sans-serif; }',
		'.ipv6check-card { background: #fff; border-radius: 8px; box-shadow: 0 2px 12px rgba(0,0,0,0.08); padding: 20px; margin-bottom: 16px; border: 1px solid #e8e8e8; }',
		'.ipv6check-card h3 { margin: 0 0 16px 0; font-size: 16px; color: #333; border-bottom: 2px solid #4a90d9; padding-bottom: 8px; }',
		/* 总览状态 */
		'.ipv6check-overview { display: flex; gap: 16px; flex-wrap: wrap; margin-bottom: 16px; }',
		'.ipv6check-stat { flex: 1; min-width: 160px; padding: 16px; border-radius: 8px; text-align: center; }',
		'.ipv6check-stat .label { font-size: 12px; color: #888; margin-bottom: 4px; }',
		'.ipv6check-stat .value { font-size: 22px; font-weight: 700; }',
		/* 目标列表 */
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
		/* 操作按钮 */
		'.ipv6check-actions { display: flex; gap: 10px; margin-bottom: 16px; }',
		'.ipv6check-btn { padding: 8px 20px; border: none; border-radius: 6px; font-size: 14px; font-weight: 600; cursor: pointer; transition: all 0.2s; }',
		'.ipv6check-btn:hover { transform: translateY(-1px); box-shadow: 0 4px 12px rgba(0,0,0,0.15); }',
		'.ipv6check-btn:active { transform: translateY(0); }',
		'.ipv6check-btn:disabled { opacity: 0.5; cursor: not-allowed; transform: none; }',
		'.btn-primary { background: #4a90d9; color: #fff; }',
		'.btn-warning { background: #e67e22; color: #fff; }',
		/* 日志区域 */
		'.ipv6check-log { background: #1e1e2e; color: #cdd6f4; padding: 16px; border-radius: 8px; font-family: "Consolas", "Courier New", monospace; font-size: 12px; line-height: 1.6; max-height: 400px; overflow-y: auto; white-space: pre-wrap; word-break: break-all; }',
		/* 信息行 */
		'.ipv6check-info-row { display: flex; justify-content: space-between; padding: 8px 0; border-bottom: 1px solid #f0f0f0; }',
		'.ipv6check-info-row:last-child { border-bottom: none; }',
		'.ipv6check-info-row .key { color: #888; font-size: 13px; }',
		'.ipv6check-info-row .val { color: #333; font-size: 13px; font-weight: 500; }',
		/* 加载动画 */
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
			E('h3', {}, '📋 检测日志'),
			logContentEl
		]);
		var historyCard = E('div', { 'class': 'ipv6check-card' }, [
			E('h3', {}, '🔄 接口重启历史'),
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
			logContentEl.textContent = logData.log || '暂无日志';
			historyContentEl.textContent = historyData.history || '暂无重启记录';

			var overallInfo = statusMap[status.overall] || statusMap['unknown'];
			var targets = status.targets || [];

			var content = document.createDocumentFragment();

			/* ===== 操作按钮 ===== */
			var actionsDiv = E('div', { 'class': 'ipv6check-actions' });

			var checkBtn = E('button', {
				'class': 'ipv6check-btn btn-primary',
				'onclick': function() {
					checkBtn.disabled = true;
					checkBtn.innerHTML = '<span class="ipv6check-spinner"></span>检测中...';
					callRunCheck().then(function() {
						return reloadData();
					}).then(function(newData) {
						updateView(newData);
					}).catch(function() {
						checkBtn.disabled = false;
						checkBtn.textContent = '🔍 立即检测';
					});
				}
			}, '🔍 立即检测');

			var restartBtn = E('button', {
				'class': 'ipv6check-btn btn-warning',
				'onclick': function() {
					var iface = status.restart_interface || 'wan6';
					if (!confirm('确定要重启接口 ' + iface + ' 吗？')) return;
					restartBtn.disabled = true;
					restartBtn.innerHTML = '<span class="ipv6check-spinner"></span>重启中...';
					callRestartInterface(iface).then(function() {
						setTimeout(function() {
							reloadData()
								.then(updateView)
								.catch(function() {
									restartBtn.disabled = false;
									restartBtn.textContent = '🔄 重启接口 (' + iface + ')';
								});
						}, 5000);
					}).catch(function() {
						restartBtn.disabled = false;
						restartBtn.textContent = '🔄 重启接口 (' + iface + ')';
					});
				}
			}, '🔄 重启接口 (' + (status.restart_interface || 'wan6') + ')');

			actionsDiv.appendChild(checkBtn);
			actionsDiv.appendChild(restartBtn);
			content.appendChild(actionsDiv);

			/* ===== 总览卡片 ===== */
			var overviewCard = E('div', { 'class': 'ipv6check-card' });
			overviewCard.appendChild(E('h3', {}, '📊 连通性总览'));

			var overviewGrid = E('div', { 'class': 'ipv6check-overview' });

			/* 整体状态 */
			overviewGrid.appendChild(E('div', {
				'class': 'ipv6check-stat',
				'style': { background: overallInfo.bg, border: '1px solid ' + overallInfo.color + '33' }
			}, [
				E('div', { 'class': 'label' }, '整体状态'),
				E('div', { 'class': 'value', 'style': { color: overallInfo.color } }, overallInfo.text)
			]));

			/* 检测时间 */
			overviewGrid.appendChild(E('div', {
				'class': 'ipv6check-stat',
				'style': { background: '#f0f4ff', border: '1px solid #d0dcf0' }
			}, [
				E('div', { 'class': 'label' }, '最近检测'),
				E('div', { 'class': 'value', 'style': { fontSize: '14px', color: '#4a90d9' } },
					status.check_time || '从未')
			]));

			/* 检测统计 */
			overviewGrid.appendChild(E('div', {
				'class': 'ipv6check-stat',
				'style': { background: '#f0fff4', border: '1px solid #d0f0dc' }
			}, [
				E('div', { 'class': 'label' }, '目标通过率'),
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
				E('div', { 'class': 'label' }, '连续失败'),
				E('div', { 'class': 'value', 'style': { color: failColor } },
					(status.consecutive_failures || 0) + '/' + (status.failure_threshold || 3))
			]));

			overviewCard.appendChild(overviewGrid);
			content.appendChild(overviewCard);

			/* ===== 目标详情卡片 ===== */
			var targetsCard = E('div', { 'class': 'ipv6check-card' });
			targetsCard.appendChild(E('h3', {}, '🎯 检测目标'));

			var targetsGrid = E('div', { 'class': 'ipv6check-targets' });

			if (targets.length === 0) {
				targetsGrid.appendChild(E('div', {
					'style': { padding: '20px', textAlign: 'center', color: '#999' }
				}, '暂无检测目标，请前往「参数配置」添加'));
			} else {
				targets.forEach(function(t) {
					var isOk = t.status === 'ok';
					targetsGrid.appendChild(E('div', { 'class': 'ipv6check-target' }, [
						E('div', {}, [
							E('div', { 'class': 'name' }, t.name || '未命名'),
							E('div', { 'class': 'host' }, t.host || '')
						]),
						E('div', {}, [
							E('span', { 'class': 'status-badge ' + (isOk ? 'status-ok' : 'status-fail') },
								isOk ? '可达' : '不可达'),
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
			infoCard.appendChild(E('h3', {}, 'ℹ️ 运行信息'));

			var infoRows = [
				['检测间隔', (status.interval || 300) + ' 秒'],
				['自动重启', status.auto_restart ? '已启用' : '已禁用'],
				['重启接口', status.restart_interface || 'wan6'],
				['失败阈值', (status.failure_threshold || 3) + ' 次连续失败后重启'],
				['上次重启', status.last_restart || '从未']
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
