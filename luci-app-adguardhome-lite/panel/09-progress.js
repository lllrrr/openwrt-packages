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

