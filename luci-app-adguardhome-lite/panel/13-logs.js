	function updateYamlCount() {
		var editor = $('agh-yaml-editor');
		var count = $('agh-yaml-count');
		if (editor && count) count.textContent = editor.value.length + ' 字符';
	}

	async function saveYaml() {
		var editor = $('agh-yaml-editor');
		var msgEl = $('agh-yaml-msg');
		var btn = $('agh-yaml-save');
		if (!editor) return;
		if (!(await aghConfirm('将校验并保存 AdGuardHome.yaml，随后重启服务。确定继续？'))) return;
		if (btn) btn.disabled = true;
		setMsg(msgEl, '正在校验配置...', '');
		try {
			await apiPost(U.yamlSave, { yaml: editor.value, base_hash: state.yamlHash });
			setMsg(msgEl, '配置已保存，正在重启服务...', 'ok');
			showToast('配置已保存，正在重启服务...', 'ok');
			pollAction(function () {
				if (btn) btn.disabled = false;
				loadYaml();
				refreshStatus(true);
			});
		} catch (err) {
			if (btn) btn.disabled = false;
			// 409 冲突：磁盘配置已被其他页面或 AGH 面板改过，覆盖会丢对方修改。
			// 不自动重载，避免静默丢弃用户当前正在编辑的内容。
			if (err && err.reason === 'yaml_conflict') {
				handleApiError(err, msgEl);
				if (await aghConfirm('配置文件已被其他操作修改，继续保存会覆盖对方的改动。\n是否重新加载最新配置？（当前未保存的修改将丢失）')) {
					await loadYaml();
					setMsg(msgEl, '已加载最新配置，请确认后重新保存。', 'ok');
				}
				return;
			}
			handleApiError(err, msgEl);
		}
	}

	async function loadLogs() {
		var box = $('agh-log-box');
		if (!box) return;
		try {
			var url = U.logs + (state.logLevel ? ('?level=' + encodeURIComponent(state.logLevel)) : '');
			var text = await apiText(url);
			state.logText = text || '';
			renderLogSections(text);
		} catch (err) {
			box.innerHTML = '<div class="agh-empty">读取日志失败：' + esc(err && err.message ? err.message : err) + '</div>';
			handleApiError(err);
		}
	}

	// 把后端拼接的日志按 ***** 标题 ***** 拆成独立区块
	function renderLogSections(text) {
		var box = $('agh-log-box');
		if (!box) return;

		var raw = String(text || '').replace(/\r\n/g, '\n');
		var sections = [];
		var title = '系统日志';
		var lastIndex = 0;
		var re = /^\s*[=*]{5}\s*(.+?)\s*[=*]{5}\s*$/gm;
		var m;

		while ((m = re.exec(raw)) !== null) {
			var body = raw.slice(lastIndex, m.index).replace(/^\n+|\n+$/g, '');
			if (body || sections.length) {
				sections.push({ title: title, body: body });
			}
			title = m[1];
			lastIndex = re.lastIndex;
		}

		var tail = raw.slice(lastIndex).replace(/^\n+|\n+$/g, '');
		if (tail) sections.push({ title: title, body: tail });

		if (!sections.length) {
			box.innerHTML = '<div class="agh-empty">暂无相关日志。</div>';
			return;
		}

		function rankOf(title) {
			if (title.indexOf('持久化状态') === 0) return 0;
			if (title.indexOf('服务操作') >= 0) return 1;
			if (title.indexOf('订阅更新') === 0) return 2;
			if (title.indexOf('系统日志') === 0) return 3;
			if (title.indexOf('内核安装') === 0) return 4;
			return 99;
		}

		sections.sort(function (a, b) { return rankOf(a.title) - rankOf(b.title); });
		for (var si = 0; si < sections.length; si++) {
			if (sections[si].title.indexOf('服务操作') >= 0) {
				sections[si].title = '服务操作日志';
			}
		}

		box.innerHTML = sections.map(function (s) {
			var main = s.title.indexOf('系统日志') === 0 ? ' agh-log-section-main' : '';
			var tall = (s.title.indexOf('服务操作') >= 0 || s.title.indexOf('订阅更新') === 0)
				? ' agh-log-section-tall' : '';
			var body = s.body || '';
			// 系统日志按时间倒序，最新的记录排在最前
			if (main && body) {
				body = body.replace(/\n+$/, '').split('\n').reverse().join('\n');
			}
			return '<section class="agh-log-section' + main + tall + '">' +
				'<h4 class="agh-log-section-title">' + esc(s.title) + '</h4>' +
				'<pre class="agh-log agh-log-tall">' + esc(body || '（暂无记录）') + '</pre>' +
				'</section>';
		}).join('');
	}

	function downloadLogs() {
		var text = state.logText || '';
		if (!text) {
			showToast('没有可下载的日志', 'bad');
			return;
		}
		var blob = new Blob([text], { type: 'text/plain;charset=utf-8' });
		var a = document.createElement('a');
		var d = new Date();
		var stamp = d.getFullYear() + ('0' + (d.getMonth() + 1)).slice(-2) + ('0' + d.getDate()).slice(-2)
			+ '-' + ('0' + d.getHours()).slice(-2) + ('0' + d.getMinutes()).slice(-2);
		a.href = URL.createObjectURL(blob);
		a.download = 'adguardhome-lite-log-' + stamp + '.txt';
		a.click();
		URL.revokeObjectURL(a.href);
	}

	async function savePassword(event) {
		event.preventDefault();
		var msgEl = $('agh-pass-msg');
		var btn = $('agh-savepass-btn');
		var pwEl = $('agh-newpass');
		var pw2El = $('agh-newpass2');
		var pw = pwEl ? pwEl.value : '';
		var pw2 = pw2El ? pw2El.value : '';

		if (!pw || pw.length < 8) {
			setMsg(msgEl, '新密码至少需要 8 个字符。', 'bad');
			return;
		}
		if (pw !== pw2) {
			setMsg(msgEl, '两次输入的密码不一致。', 'bad');
			return;
		}
		if (typeof TwinBcrypt === 'undefined') {
			setMsg(msgEl, '密码组件加载失败，请刷新页面后重试。', 'bad');
			return;
		}

		var hash;
		try {
			hash = TwinBcrypt.hashSync(pw, 10);
		} catch (e) {
			setMsg(msgEl, '密码哈希计算失败：' + e, 'bad');
			return;
		}

		if (btn) btn.disabled = true;
		setMsg(msgEl, '正在保存新密码...', '');
		try {
			await apiPost(U.password, { hash: hash, password: pw });
			setMsg(msgEl, '密码已保存，正在重启服务...', 'ok');
			showToast('面板密码修改成功', 'ok');
			if (pwEl) pwEl.value = '';
			if (pw2El) pw2El.value = '';
			pollAction(function () {
				if (btn) btn.disabled = false;
				refreshStatus(true);
			});
		} catch (err) {
			if (btn) btn.disabled = false;
			handleApiError(err, msgEl);
		}
	}

