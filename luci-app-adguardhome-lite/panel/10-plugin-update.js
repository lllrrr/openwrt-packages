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

