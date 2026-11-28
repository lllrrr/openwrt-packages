	function esc(value) {
		return String(value == null ? '' : value)
			.replace(/&/g, '&amp;')
			.replace(/</g, '&lt;')
			.replace(/>/g, '&gt;')
			.replace(/"/g, '&quot;')
			.replace(/'/g, '&#39;');
	}

	function showToast(text, kind) {
		var el = document.querySelector('.agh-toast');
		if (!el) {
			el = document.createElement('div');
			el.className = 'agh-toast';
			document.body.appendChild(el);
		}
		el.textContent = text;
		el.className = 'agh-toast is-visible' + (kind ? ' is-' + kind : '');
		if (state.toastTimer) clearTimeout(state.toastTimer);
		state.toastTimer = setTimeout(function () {
			el.className = 'agh-toast';
		}, 4500);
	}

	// 统一确认弹窗，替代浏览器原生 confirm，外观与面板保持一致
	function aghConfirm(text) {
		var modal = $('agh-confirm-modal');
		var textEl = $('agh-confirm-text');
		var okBtn = $('agh-confirm-ok');
		var cancelBtn = $('agh-confirm-cancel');
		var mask = $('agh-confirm-mask');
		if (!modal || !textEl || !okBtn || !cancelBtn) {
			return Promise.resolve(window.confirm(text));
		}

		var resolveFn = null;
		textEl.textContent = text;
		modal.hidden = false;
		okBtn.focus();

		function onKey(e) {
			if (e.key === 'Escape') finish(false);
		}

		function finish(result) {
			modal.hidden = true;
			okBtn.onclick = null;
			cancelBtn.onclick = null;
			if (mask) mask.onclick = null;
			document.removeEventListener('keydown', onKey);
			var done = resolveFn;
			resolveFn = null;
			if (done) done(result);
		}

		okBtn.onclick = function () { finish(true); };
		cancelBtn.onclick = function () { finish(false); };
		if (mask) mask.onclick = function () { finish(false); };
		document.addEventListener('keydown', onKey);
		return new Promise(function (resolve) { resolveFn = resolve; });
	}

	function setMsg(el, text, kind) {
		if (!el) return;
		el.textContent = text || '';
		el.style.whiteSpace = 'pre-wrap';
		el.style.color = kind === 'bad'
			? 'var(--agh-danger)'
			: kind === 'ok'
				? 'var(--agh-success)'
				: 'var(--agh-muted)';
	}

	function isLoginError(err) {
		return err && err.login === true;
	}

	function handleApiError(err, target) {
		if (isLoginError(err)) {
			var text = '登录已过期，请重新登录 LuCI 后刷新本页面。';
			if (target) setMsg(target, text, 'bad');
			showToast(text, 'bad');
			return;
		}
		var msg = err && err.message ? err.message : String(err);
		if (target) setMsg(target, msg, 'bad');
		showToast(msg, 'bad');
	}

	// LuCI 在会话失效或令牌不匹配时返回 HTML（登录页 / csrftoken），
	// 不能一律当成“登录已过期”，否则用户会反复登录仍看到同样的提示。
	function htmlResponseError(r, text) {
		var raw = String(text || '');
		var snippet = raw
			// 闭合标签可能带属性（如 </script >），不能用固定的 </script> 匹配
			.replace(/<script[\s\S]*?<\/script[^>]*>/gi, ' ')
			.replace(/<style[\s\S]*?<\/style[^>]*>/gi, ' ')
			.replace(/<[^>]+>/g, ' ')
			.replace(/\s+/g, ' ')
			.trim();
		if (snippet.length > 140) snippet = snippet.slice(0, 140) + '…';

		var loginRequired = r.status === 401
			|| (r.headers.get('x-luci-login-required') || '').toLowerCase() === 'yes';
		if (!loginRequired && /invalid token|csrf|令牌|登录|login|session/i.test(snippet)) {
			loginRequired = true;
		}
		if (loginRequired) {
			throw Object.assign(new Error('登录已过期'), { login: true, status: r.status });
		}
		throw new Error(snippet || ('服务器返回了网页（HTTP ' + r.status + '），请刷新页面后重试。'));
	}

	async function parseJsonResponse(r) {
		var ct = r.headers.get('content-type') || '';
		var text = await r.text();
		// 部分动作没带 JSON Content-Type，但 body 是合法 JSON；先按内容判断，
		// 否则会把正常响应当成网页错误，把原始 JSON 显示到提示里。
		if (/^\s*[{[]/.test(text)) {
			try {
				return JSON.parse(text);
			} catch (e) { /* 不是合法 JSON，继续按错误处理 */ }
		}
		if (ct.indexOf('text/html') >= 0) {
			htmlResponseError(r, text);
		}
		if (!r.ok) {
			if (text.trim().indexOf('<') === 0) htmlResponseError(r, text);
			throw new Error(text || ('HTTP ' + r.status));
		}
		if (text.trim().indexOf('<') === 0) htmlResponseError(r, text);
		throw new Error('接口返回格式错误');
	}

	// 统一超时：接口卡住时快速失败，避免整个面板一直停在加载状态
	function fetchWithTimeout(url, options, ms) {
		var opts = options || {};
		var controller = window.AbortController ? new AbortController() : null;
		if (controller) opts.signal = controller.signal;
		var timer = setTimeout(function () {
			if (controller) controller.abort();
		}, ms || 20000);
		return fetch(url, opts).then(function (r) {
			clearTimeout(timer);
			return r;
		}, function (err) {
			clearTimeout(timer);
			if (err && err.name === 'AbortError') throw new Error('请求超时，请稍后重试。');
			throw err;
		});
	}

	async function apiGet(url) {
		var r = await fetchWithTimeout(url, {
			credentials: 'same-origin',
			cache: 'no-store',
			headers: { 'Accept': 'application/json', 'X-Requested-With': 'XMLHttpRequest' }
		}, 20000);
		return parseJsonResponse(r);
	}

	async function postForm(url, data, timeout) {
		var body = new URLSearchParams(data || {});
		body.set('token', TOKEN);
		var r = await fetchWithTimeout(url, {
			method: 'POST',
			credentials: 'same-origin',
			cache: 'no-store',
			headers: {
				'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8',
				'Accept': 'application/json',
				'X-Requested-With': 'XMLHttpRequest'
			},
			body: body.toString()
		}, timeout || 30000);
		var json = await parseJsonResponse(r);
		if (json && json.ok === false) {
			var err = new Error(json.error || '操作失败');
			if (json.reason === 'auth_required') err.login = true;
			err.reason = json.reason || '';
			throw err;
		}
		return json;
	}

	async function apiPost(url, data, timeout) {
		if (!TOKEN) await refreshToken();
		try {
			return await postForm(url, data, timeout);
		} catch (err) {
			if (!isLoginError(err)) throw err;
			// 重新登录后令牌会轮换，取一次当前令牌再重试；仍失败才提示重新登录
			await refreshToken();
			return await postForm(url, data, timeout);
		}
	}

	async function apiText(url) {
		var r = await fetchWithTimeout(url, {
			credentials: 'same-origin',
			cache: 'no-store',
			headers: { 'Accept': 'text/plain', 'X-Requested-With': 'XMLHttpRequest' }
		}, 20000);
		var ct = r.headers.get('content-type') || '';
		if (ct.indexOf('text/html') >= 0) {
			throw Object.assign(new Error('登录已过期'), { login: true });
		}
		if (!r.ok) throw new Error('HTTP ' + r.status);
		return await r.text();
	}

