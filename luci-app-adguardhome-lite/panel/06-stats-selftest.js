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
			// level 优先：warn 是「提示」，不影响整体结论，不能显示成异常
			var lv = c.level || (c.ok ? 'ok' : 'fail');
			var mark = lv === 'ok' ? '正常' : (lv === 'warn' ? '提示' : '异常');
			var color = lv === 'ok' ? '' : (lv === 'warn' ? '#b8860b' : '#c0392b');
			var cls = color ? ' style="color:' + color + '"' : '';
			return '<li><b' + cls + '>' + mark + ' · ' + esc(c.label) + '</b><br>'
				+ '<span class="agh-hint">' + esc(c.detail || '') + '</span></li>';
		}).join('');
	}

	function openSelftestModal() {
		var modal = $('agh-selftest-modal');
		if (modal) modal.hidden = false;
	}

	function closeSelftestModal() {
		var modal = $('agh-selftest-modal');
		if (modal) modal.hidden = true;
	}

	function selftestSummary(checks) {
		var fail = 0;
		var warn = 0;
		checks.forEach(function (c) {
			var lv = c.level || (c.ok ? 'ok' : 'fail');
			if (lv === 'fail') fail++;
			else if (lv === 'warn') warn++;
		});
		if (!fail && !warn) return '全部检查正常。';
		var parts = [];
		if (fail) parts.push(fail + ' 项异常');
		if (warn) parts.push(warn + ' 项提示');
		return '发现 ' + parts.join('、') + '。';
	}

	async function runSelftest() {
		var btn = $('agh-selftest-btn');
		var retry = $('agh-selftest-retry');
		var summary = $('agh-selftest-summary');
		var list = $('agh-selftest-list');
		openSelftestModal();
		if (list) list.innerHTML = '<li class="agh-hint">检测中...</li>';
		if (summary) summary.textContent = '';
		if (btn) {
			btn.disabled = true;
			btn.textContent = '检测中...';
		}
		if (retry) retry.disabled = true;
		try {
			var d = await apiGet(U.selftest);
			renderSelftest(d);
			if (summary) summary.textContent = selftestSummary((d && d.checks) || []);
		} catch (err) {
			if (summary) summary.textContent = '检测失败。';
			handleApiError(err, list);
		} finally {
			if (btn) {
				btn.disabled = false;
				btn.textContent = '开始检测';
			}
			if (retry) retry.disabled = false;
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
