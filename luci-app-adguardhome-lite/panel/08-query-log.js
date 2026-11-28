	function queryTimeParts(t) {
		var s = String(t || '').replace('T', ' ').trim();
		var parts = s.split(' ');
		if (parts.length > 1) {
			return { date: parts[0].slice(5), clock: parts[1].slice(0, 8) };
		}
		return { date: '', clock: (parts[0] || '').slice(0, 8) };
	}

	function queryClient(item) {
		if (item.client_name) return item.client_name + ' (' + item.client + ')';
		return item.client || '';
	}

	function renderQueryLog(items, append) {
		var el = $('agh-querylog-list');
		if (!el) return;

		var list = items || [];
		if (!list.length && !append) {
			el.innerHTML = '<tr><td colspan="6"><div class="agh-empty">没有符合条件的查询记录</div></td></tr>';
			return;
		}

		var html = list.map(function (it) {
			var blocked = it.blocked !== undefined
				? !!it.blocked
				: (String(it.reason || '').indexOf('Filtered') >= 0);
			var rule = it.rule || '';
			if (it.filter_name) rule += (rule ? ' · ' : '') + it.filter_name;
			var elapsed = it.elapsed_ms ? (Number(it.elapsed_ms).toFixed(0) + 'ms') : '';
			var tp = queryTimeParts(it.time);
			return '<tr>' +
				'<td class="agh-query-time"><span class="agh-query-date">' + esc(tp.date) + '</span>' + esc(tp.clock) + '</td>' +
				'<td class="agh-query-client" title="' + esc(queryClient(it)) + '">' + esc(queryClient(it)) + '</td>' +
				'<td class="agh-query-domain" title="' + esc(it.domain) + '">' + esc(it.domain) + '</td>' +
				'<td class="agh-query-rule" title="' + esc(rule) + '">' + esc(rule || '-') + '</td>' +
				'<td class="agh-query-elapsed">' + esc(elapsed) + '</td>' +
				'<td class="' + (blocked ? 'agh-log-block' : 'agh-log-ok') + '">' +
				(blocked ? '已拦截' : '已放行') + '</td>' +
				'</tr>';
		}).join('');

		if (append) el.insertAdjacentHTML('beforeend', html);
		else el.innerHTML = html;
	}

	async function loadQueryPage(index) {
		var list = $('agh-querylog-list');
		var info = $('agh-querylog-pageinfo');
		var prev = $('agh-querylog-prev');
		var next = $('agh-querylog-next');

		if (index < 0) index = 0;
		state.queryPage = index;
		if (info) info.textContent = '第 ' + (index + 1) + ' 页';
		if (prev) prev.disabled = index === 0;
		if (next) next.disabled = true;

		if (!state.queryPages[index]) {
			// 已有内容时保留旧行，避免刷新瞬间表格塌缩
			if (list && list.querySelectorAll('tr').length <= 1) {
				list.innerHTML = '<tr><td colspan="6"><div class="agh-empty">读取中...</div></td></tr>';
			}
			var params = new URLSearchParams();
			params.set('limit', '20');
			if (state.queryStatus) params.set('status', state.queryStatus);
			if (state.querySearch) params.set('search', state.querySearch);
			var cursor = state.queryCursors[index] || '';
			if (cursor) params.set('older_than', cursor);
			try {
				var d = await apiGet(U.querylog + '?' + params.toString());
				if (!d.ok) throw new Error(d.error || '读取失败');
				var items = Array.isArray(d.data) ? d.data : [];
				state.queryPages[index] = items;
				state.queryMore[index] = !!d.more;
				if (items.length) {
					state.queryCursors[index + 1] = d.cursor || items[items.length - 1].time;
				}
			} catch (err) {
				if (list) list.innerHTML = '<tr><td colspan="6"><div class="agh-empty">' + esc(err.message || '读取失败') + '</div></td></tr>';
				return;
			}
		}

		renderQueryLog(state.queryPages[index] || [], false);
		if (next) next.disabled = !state.queryMore[index];
	}

	function resetQueryLog() {
		state.queryPages = [];
		state.queryCursors = [''];
		state.queryMore = [];
		loadQueryPage(0);
	}

	function reloadQueryPage() {
		delete state.queryPages[state.queryPage];
		loadQueryPage(state.queryPage);
	}

