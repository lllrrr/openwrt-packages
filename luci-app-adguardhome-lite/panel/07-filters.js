	function toList(value) {
		if (!value) return [];
		if (Array.isArray(value)) return value;
		var out = [];
		if (typeof value === 'object') {
			for (var k in value) {
				if (Object.prototype.hasOwnProperty.call(value, k)) out.push(value[k]);
			}
		}
		return out;
	}

	// 总开关关闭时，其余功能开关置灰且不可点，避免误以为单项仍在生效
	function applyFilterMasterLock() {
		var master = $('agh-filter-enabled');
		var on = !master || master.checked;
		['agh-filter-adult', 'agh-filter-parental', 'agh-filter-safesearch', 'agh-filter-safebrowsing']
			.forEach(function (id) {
				var el = $(id);
				if (!el) return;
				el.disabled = !on;
				var field = el.closest ? el.closest('.agh-field') : null;
				if (field) field.classList.toggle('is-locked', !on);
			});
	}

	function setFilterFlags(d) {
		var map = {
			filtering_enabled: 'agh-filter-enabled',
			parental: 'agh-filter-parental',
			safesearch: 'agh-filter-safesearch',
			safebrowsing: 'agh-filter-safebrowsing'
		};
		for (var k in map) {
			if (!Object.prototype.hasOwnProperty.call(map, k)) continue;
			var el = $(map[k]);
			if (el) el.checked = !!d[k];
		}
		var rules = $('agh-filter-rules');
		// 用户正在编辑自定义规则时，刷新订阅列表不要覆盖文本域
		if (rules && !state.rulesDirty) rules.value = toList(d.user_rules).join('\n');

		// 成人内容拦截开关以 NSFW 订阅（含旧地址）是否存在且启用为准
		var adultEl = $('agh-filter-adult');
		if (adultEl) {
			var nsfw = findAdultFilter(d.filters);
			adultEl.checked = !!(nsfw && nsfw.enabled);
			// 已启用的旧地址在本页首次检测到时迁移一次到 CDN，其余情况交给用户开关
			if (nsfw && nsfw.enabled && nsfw.url !== ADULT_FILTER_URL && !state.adultMigrated) {
				state.adultMigrated = true;
				toggleAdultFilter(true);
			}
		}

		// DoH 开关以 user_rules 里是否已含全部 9 条规则为准
		var dohEl = $('agh-filter-doh');
		if (dohEl) {
			var userRules = toList(d.user_rules).map(function (x) { return String(x).trim(); });
			var hit = 0;
			for (var j = 0; j < DOH_RULES.length; j++) {
				if (userRules.indexOf(DOH_RULES[j]) >= 0) hit++;
			}
			dohEl.checked = hit === DOH_RULES.length;
		}
		applyFilterMasterLock();
		updateSwitchStates();
	}

	// 成人内容拦截：启用时写入 CDN 订阅，旧地址（raw / 上游 HaGeZi）自动迁移，避免重复列表
	async function toggleAdultFilter(on) {
		var found = findAdultFilter(state.filters);
		if (!on) {
			if (!found) return true;
			return filtersAction({ action: 'remove', url: found.url, whitelist: '0' });
		}
		if (found && found.url === ADULT_FILTER_URL) {
			if (found.enabled) return;
			return filtersAction({
				action: 'toggle',
				url: ADULT_FILTER_URL,
				name: found.name || ADULT_FILTER_NAME,
				whitelist: '0',
				enabled: '1'
			});
		}
		// 旧地址先移除，再按 CDN 地址重新添加；分两步是因为 AGH 的 set_url 不支持改地址
		if (found) {
			var ok = await filtersAction({ action: 'remove', url: found.url, whitelist: '0' });
			if (!ok) return;
		}
		return filtersAction({
			action: 'add',
			name: ADULT_FILTER_NAME,
			url: ADULT_FILTER_URL,
			whitelist: '0'
		});
	}

	// 开关 DoH 拦截：在自定义规则里增删 9 条，复用现有的规则保存接口
	function toggleDohBlock(on) {
		var ta = $('agh-filter-rules');
		var lines = ta ? ta.value.split('\n') : [];
		var out = [];
		var seen = {};
		for (var i = 0; i < lines.length; i++) {
			var s = lines[i].trim();
			if (!s) continue;
			// 裸域名与 ||domain^ 等价，统一清理后按开关状态重建
			if (DOH_RULES.indexOf(s) >= 0 || DOH_DOMAINS.indexOf(s) >= 0) continue;
			if (!seen[s]) {
				seen[s] = 1;
				out.push(s);
			}
		}
		if (on) {
			for (var k = 0; k < DOH_RULES.length; k++) out.push(DOH_RULES[k]);
		}
		if (ta) ta.value = out.join('\n');
		state.rulesDirty = false;
		return filtersAction({ action: 'rules', rules: out.join('\n') });
	}

	// 订阅来源标签：先解析出域名再比较，避免用 substring 判断时被伪造地址绕过
	function filterSource(url) {
		var u = String(url || '');
		var m = u.match(/^[a-z][a-z0-9+.-]*:\/\/([^\/?#]*)/i);
		var host = (m ? m[1] : '').toLowerCase();
		host = host.replace(/^[^@]*@/, '').replace(/:\d+$/, '');
		if (!host) return '';
		var isHost = function (name) {
			return host === name || host.slice(-(name.length + 1)) === '.' + name;
		};
		if (isHost('cdn.jsdelivr.net')) return 'jsDelivr';
		if (isHost('agh.ozero.top')) return '作者自建';
		if (/(^|\.)gh-?proxy(\.|$)/.test(host) || /(^|\.)ghfast(\.|$)/.test(host)) return 'GitHub 反代';
		if (isHost('github.com') || isHost('githubusercontent.com')) return 'GitHub 直连';
		return host;
	}

	function renderFilters(d) {
		var list = $('agh-filter-list');
		if (!list) return;
		var filters = toList(d && d.filters);
		if (!filters.length) {
			list.innerHTML = '<div class="agh-empty">还没有订阅规则</div>';
			return;
		}

		var html = '';
		for (var i = 0; i < filters.length; i++) {
			var f = filters[i];
			var wl = f.whitelist ? '1' : '0';
			var tag = f.whitelist ? ' <span class="agh-rule-tag">白名单</span>' : '';
			var src = filterSource(f.url);
			html += '<div class="agh-rule" data-url="' + esc(f.url) + '" data-name="' + esc(f.name || f.url) + '" data-whitelist="' + wl + '" title="' + esc(f.url) + '">' +
				'<input type="checkbox" class="agh-filter-toggle" ' + (f.enabled ? 'checked' : '') + '>' +
				'<span class="agh-rule-name">' + esc(f.name || f.url) + tag + '</span>' +
				(src ? '<span class="agh-rule-source">' + esc(src) + '</span>' : '') +
				'<span class="agh-rule-meta agh-rule-count">' + (f.rules_count || 0) + ' 条</span>' +
				'<button type="button" class="agh-ghost-btn agh-small-btn agh-filter-remove">删除</button>' +
				'</div>';
		}
		list.innerHTML = html;

		Array.prototype.slice.call(list.querySelectorAll('.agh-filter-toggle')).forEach(function (el) {
			el.onchange = function () {
				var row = el.closest('.agh-rule');
				filtersAction({
					action: 'toggle',
					url: row.getAttribute('data-url'),
					name: row.getAttribute('data-name'),
					whitelist: row.getAttribute('data-whitelist'),
					enabled: el.checked ? '1' : '0'
				});
			};
		});
		Array.prototype.slice.call(list.querySelectorAll('.agh-filter-remove')).forEach(function (el) {
			el.onclick = async function () {
				var row = el.closest('.agh-rule');
				if (!(await aghConfirm('删除规则列表「' + row.getAttribute('data-name') + '」？'))) return;
				filtersAction({
					action: 'remove',
					url: row.getAttribute('data-url'),
					whitelist: row.getAttribute('data-whitelist')
				});
			};
		});
	}

	async function loadFilters(silent) {
		var msg = $('agh-filters-msg');
		var list = $('agh-filter-list');
		if (!silent && list && !list.querySelector('.agh-rule')) list.innerHTML = '<div class="agh-empty">读取中...</div>';
		try {
			var d = await apiGet(U.filters);
			if (!d.ok) throw new Error(d.error || '读取失败');
			state.filters = toList(d.filters);
			setFilterFlags(d);
			renderFilters(d);
			state.presetSource = d.preset_source || 'jsdelivr';
			var srcSel = $('agh-preset-source');
			if (srcSel) srcSel.value = state.presetSource;
			setMsg(msg, '', '');
		} catch (err) {
			if (silent) return;
			handleApiError(err, msg);
			if (list) list.innerHTML = '<div class="agh-empty">读取失败</div>';
		}
	}

	async function filtersAction(data) {
		var msg = $('agh-filters-msg');
		try {
			await apiPost(U.filtersSave, data);
			showToast('已生效', 'ok');
			await loadFilters();
			return true;
		} catch (err) {
			handleApiError(err, msg);
			// 操作失败时按服务端真实状态复位开关与列表，避免滑块显示与实际不一致
			await loadFilters(true);
			return false;
		}
	}

	function bindFilterSwitch(id, feature) {
		var el = $(id);
		if (!el) return;
		el.onchange = function () {
			if (id === 'agh-filter-enabled') applyFilterMasterLock();
			filtersAction({ action: 'feature', feature: feature, value: el.checked ? '1' : '0' });
		};
	}

	// 成人内容拦截与家长控制功能重叠，开启其中一个时自动关闭另一个
	function bindParentalSwitch() {
		var el = $('agh-filter-parental');
		if (!el) return;
		el.onchange = async function () {
			var adult = $('agh-filter-adult');
			var adultWasOn = !!(adult && adult.checked);
			if (el.checked && adultWasOn) {
				if (adult) adult.checked = false;
				var ok = await toggleAdultFilter(false);
				if (!ok) {
					el.checked = false;
					return;
				}
			}
			filtersAction({ action: 'feature', feature: 'parental', value: el.checked ? '1' : '0' });
		};
	}

	// 档位切换与订阅更新都会改动 AGH 的过滤列表，必须互斥，
	// 否则 AGH 可能返回「filters are being updated」之类的冲突错误。
	function setFilterBusy(value) {
		state.filterBusy = value;
		var trim = $('agh-memory-trim');
		if (trim) {
			Array.prototype.slice.call(trim.querySelectorAll('button')).forEach(function (b) {
				b.disabled = value;
			});
		}
		var srcSel = $('agh-preset-source');
		if (srcSel) srcSel.disabled = value;
	}

	// 按设备内存切换预置规则档位
	function bindMemoryTrim() {
		var wrap = $('agh-memory-trim');
		if (!wrap) return;
		var msg = $('agh-memory-trim-msg');
		Array.prototype.slice.call(wrap.querySelectorAll('button')).forEach(function (btn) {
			btn.onclick = async function () {
				if (state.filterBusy) return;
				var tier = btn.getAttribute('data-tier');
				var label = tier === '512' ? '512MB' : (tier === '1024' ? '1GB' : '2GB 及以上');
				if (!(await aghConfirm('切换到 ' + label + ' 规则档位？会移除其它档位的预置列表。'))) return;
				Array.prototype.slice.call(wrap.querySelectorAll('button')).forEach(function (b) {
					b.classList.toggle('is-active', b === btn);
				});
				setFilterBusy(true);
				if (msg) msg.textContent = '正在切换...';
				try {
					var d = await apiPost(U.filtersSave, { action: 'trim', tier: tier });
					if (msg) msg.textContent = label + '：已订阅 ' + (d.kept || 0) + ' 个列表，变更 ' + (d.changed || 0) + ' 项';
					showToast('已切换档位', 'ok');
					await loadFilters();
				} catch (err) {
					if (msg) msg.textContent = '';
					handleApiError(err, msg);
					await loadFilters(true);
				} finally {
					setFilterBusy(false);
				}
			};
		});
	}

	// 切换预置订阅下载源：保存后把已有内置列表改到新源
	function bindPresetSource() {
		var sel = $('agh-preset-source');
		if (!sel) return;
		sel.onchange = async function () {
			if (state.filterBusy) {
				sel.value = state.presetSource || 'jsdelivr';
				return;
			}
			var msg = $('agh-filters-msg');
			var prev = state.presetSource || 'jsdelivr';
			var val = sel.value;
			setFilterBusy(true);
			if (msg) msg.textContent = '正在切换下载源...';
			try {
				var d = await apiPost(U.filtersSave, { action: 'preset_source', source: val });
				state.presetSource = val;
				var failedCount = Array.isArray(d.failed)
					? d.failed.length
					: (d.failed ? Object.keys(d.failed).length : 0);
				var text = '下载源已切换，迁移 ' + (d.migrated || 0) + ' 个列表';
				if (failedCount) text += '，失败 ' + failedCount + ' 个';
				if (msg) msg.textContent = text;
				showToast(text, 'ok');
				await loadFilters(true);
			} catch (err) {
				sel.value = prev;
				if (msg) msg.textContent = '';
				handleApiError(err, msg);
				await loadFilters(true);
			} finally {
				setFilterBusy(false);
			}
		};
	}

