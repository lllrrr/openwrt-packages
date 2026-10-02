/*
 * 目标管理页面：新增 / 编辑 / 删除 / 启用 / 禁用 / 上下移动 / 复制 / 批量操作
 * 白色毛玻璃质感 + 高级动态 SVG 动效重构版本
 * 针对管理工具条、目标列表表格与编辑弹窗进行一体化视觉重构。
 */

'use strict';
'require view';
'require netmonitor.common as common';
'require netmonitor.icons as icons';

return view.extend({
	load: function() {
		common.css();
		return Promise.all([
			common.loadI18n(),
			common.api.getTargets(),
			common.api.getConfig()
		]);
	},

	render: function(res) {
		common.css();

		var targets = ((res && res[1]) || {}).targets || [];
		var cfg = (res && res[2]) || {};
		var checked = {};

		// 注入系统级白色毛玻璃、排版体系与动态 SVG 微动效
		(function injectTargetsStyles() {
			if (document.getElementById('nm-targets-glass-theme')) return;
			var style = document.createElement('style');
			style.id = 'nm-targets-glass-theme';
			style.textContent = `
				:root {
					--nm-bg-canvas: radial-gradient(120% 120% at 50% 0%, #f1f5f9 0%, #f8fafc 50%, #edf2f7 100%);
					--nm-glass-bg: linear-gradient(135deg, rgba(255, 255, 255, 0.85) 0%, rgba(255, 255, 255, 0.65) 100%);
					--nm-glass-card-bg: linear-gradient(145deg, rgba(255, 255, 255, 0.82) 0%, rgba(255, 255, 255, 0.65) 100%);
					--nm-glass-border: rgba(255, 255, 255, 0.95);
					--nm-glass-shadow: 0 10px 30px -5px rgba(15, 23, 42, 0.05), 0 2px 8px -2px rgba(15, 23, 42, 0.03);
					--nm-glass-shadow-hover: 0 20px 38px -8px rgba(15, 23, 42, 0.09), 0 6px 14px -3px rgba(15, 23, 42, 0.05);
					--nm-blur: blur(20px) saturate(190%);
					
					--nm-c-ok: #10b981;
					--nm-c-warn: #f59e0b;
					--nm-c-bad: #ef4444;
					--nm-c-primary: #3b82f6;
					
					--nm-txt-title: #0f172a;
					--nm-txt-body: #334155;
					--nm-txt-sub: #64748b;
					--nm-txt-light: #94a3b8;
				}

				.nm-root {
					background: var(--nm-bg-canvas);
					min-height: 100%;
					padding: 24px 20px 48px;
					font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "PingFang SC", "Hiragino Sans GB", "Microsoft YaHei", sans-serif;
					color: var(--nm-txt-body);
					-webkit-font-smoothing: antialiased;
				}

				.nm-page {
					max-width: 1440px;
					margin: 0 auto;
					display: flex;
					flex-direction: column;
					gap: 20px;
				}

				/* 毛玻璃卡片通用基类 */
				.nm-glass-card {
					background: var(--nm-glass-card-bg);
					backdrop-filter: var(--nm-blur);
					-webkit-backdrop-filter: var(--nm-blur);
					border: 1px solid var(--nm-glass-border);
					border-radius: 20px;
					box-shadow: var(--nm-glass-shadow);
					transition: transform 0.25s ease, box-shadow 0.25s ease;
					position: relative;
				}

				/* 顶部管理工具栏 */
				.nm-toolbar-glass {
					padding: 16px 24px;
					display: flex;
					align-items: center;
					flex-wrap: wrap;
					gap: 16px;
				}

				.nm-btn-glass {
					background: rgba(255, 255, 255, 0.88);
					border: 1px solid rgba(255, 255, 255, 0.95);
					border-radius: 12px;
					padding: 8px 16px;
					font-size: 0.86rem;
					font-weight: 650;
					color: var(--nm-txt-body);
					box-shadow: 0 2px 6px rgba(15, 23, 42, 0.04);
					cursor: pointer;
					display: inline-flex;
					align-items: center;
					gap: 7px;
					transition: all 0.2s cubic-bezier(0.4, 0, 0.2, 1);
				}

				.nm-btn-glass:hover:not(:disabled) {
					background: #ffffff;
					transform: translateY(-1.5px);
					box-shadow: 0 6px 16px rgba(15, 23, 42, 0.08);
					color: var(--nm-txt-title);
				}

				.nm-btn-glass:disabled {
					opacity: 0.55;
					cursor: not-allowed;
				}

				.nm-btn-primary-glass {
					background: linear-gradient(135deg, #3b82f6 0%, #1d4ed8 100%) !important;
					color: #ffffff !important;
					border: 1px solid rgba(255, 255, 255, 0.25) !important;
					box-shadow: 0 4px 14px rgba(37, 99, 235, 0.28) !important;
				}

				.nm-btn-primary-glass:hover:not(:disabled) {
					background: linear-gradient(135deg, #60a5fa 0%, #2563eb 100%) !important;
					box-shadow: 0 6px 20px rgba(37, 99, 235, 0.38) !important;
				}

				/* 工具栏右侧状态胶囊 */
				.nm-summary-pill {
					display: inline-flex;
					align-items: center;
					gap: 12px;
					background: rgba(255, 255, 255, 0.65);
					border: 1px solid rgba(255, 255, 255, 0.9);
					border-radius: 14px;
					padding: 6px 14px;
					font-size: 0.82rem;
					color: var(--nm-txt-sub);
				}

				/* 目标表格毛玻璃容器 */
				.nm-table-glass-wrap {
					background: var(--nm-glass-card-bg);
					backdrop-filter: var(--nm-blur);
					-webkit-backdrop-filter: var(--nm-blur);
					border: 1px solid var(--nm-glass-border);
					border-radius: 20px;
					box-shadow: var(--nm-glass-shadow);
					overflow-x: auto;
					-webkit-overflow-scrolling: touch;
				}

				.nm-table-glass {
					width: 100%;
					border-collapse: separate;
					border-spacing: 0;
					text-align: left;
					font-size: 0.88rem;
				}

				.nm-table-glass thead th {
					background: rgba(248, 250, 252, 0.9);
					backdrop-filter: blur(12px);
					-webkit-backdrop-filter: blur(12px);
					padding: 15px 16px;
					font-weight: 700;
					font-size: 0.8rem;
					color: var(--nm-txt-sub);
					text-transform: uppercase;
					letter-spacing: 0.05em;
					border-bottom: 1px solid rgba(226, 232, 240, 0.85);
					position: sticky;
					top: 0;
					z-index: 2;
					white-space: nowrap;
				}

				.nm-table-glass tbody tr {
					transition: background 0.18s ease;
				}

				.nm-table-glass tbody tr:hover {
					background: rgba(241, 245, 249, 0.7);
				}

				.nm-table-glass tbody td {
					padding: 13px 16px;
					border-bottom: 1px solid rgba(241, 245, 249, 0.85);
					color: var(--nm-txt-body);
					vertical-align: middle;
					white-space: nowrap;
				}

				.nm-table-glass tbody tr:last-child td {
					border-bottom: none;
				}

				.nm-target-name {
					font-weight: 700;
					color: var(--nm-txt-title);
				}

				.nm-target-host {
					font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
					font-size: 0.82rem;
					color: var(--nm-txt-sub);
				}

				.nm-num {
					font-variant-numeric: tabular-nums;
					font-weight: 650;
					color: var(--nm-txt-title);
				}

				/* 协议胶囊 */
				.nm-proto-badge-glass {
					display: inline-flex;
					align-items: center;
					padding: 3px 9px;
					border-radius: 8px;
					font-size: 0.75rem;
					font-weight: 700;
					letter-spacing: 0.02em;
				}

				.nm-proto-badge-glass.icmp {
					background: rgba(236, 253, 245, 0.95);
					border: 1px solid rgba(167, 243, 208, 0.9);
					color: #047857;
				}

				.nm-proto-badge-glass.tcp {
					background: rgba(239, 246, 255, 0.95);
					border: 1px solid rgba(191, 219, 254, 0.9);
					color: #1d4ed8;
				}

				/* 区域胶囊 */
				.nm-tag-pill {
					display: inline-flex;
					align-items: center;
					padding: 3px 9px;
					border-radius: 8px;
					font-size: 0.76rem;
					font-weight: 650;
					background: rgba(241, 245, 249, 0.9);
					border: 1px solid rgba(226, 232, 240, 0.9);
					color: #475569;
				}

				.nm-tag-pill.cn {
					background: rgba(239, 246, 255, 0.9);
					border-color: rgba(191, 219, 254, 0.9);
					color: #1d4ed8;
				}

				.nm-tag-pill.overseas {
					background: rgba(245, 243, 255, 0.9);
					border-color: rgba(221, 214, 254, 0.9);
					color: #6d28d9;
				}

				/* 操作微按钮 */
				.nm-btn-mini {
					background: rgba(255, 255, 255, 0.85);
					border: 1px solid rgba(226, 232, 240, 0.9);
					border-radius: 8px;
					padding: 4px 10px;
					font-size: 0.78rem;
					font-weight: 600;
					color: var(--nm-txt-body);
					cursor: pointer;
					transition: all 0.15s ease;
					margin-right: 4px;
				}

				.nm-btn-mini:hover:not(:disabled) {
					background: #ffffff;
					border-color: var(--nm-c-primary);
					color: var(--nm-c-primary);
					box-shadow: 0 2px 6px rgba(0, 0, 0, 0.05);
				}

				.nm-btn-mini.danger:hover:not(:disabled) {
					border-color: var(--nm-c-bad);
					color: var(--nm-c-bad);
				}

				/* 开关切换器优化 */
				.nm-switch {
					position: relative;
					display: inline-block;
					width: 36px;
					height: 20px;
					vertical-align: middle;
					margin-left: 6px;
				}

				.nm-switch input {
					opacity: 0;
					width: 0;
					height: 0;
				}

				.nm-switch i {
					position: absolute;
					cursor: pointer;
					top: 0; left: 0; right: 0; bottom: 0;
					background-color: #cbd5e1;
					transition: .24s;
					border-radius: 20px;
				}

				.nm-switch i:before {
					position: absolute;
					content: "";
					height: 16px;
					width: 16px;
					left: 2px;
					bottom: 2px;
					background-color: white;
					transition: .24s;
					border-radius: 50%;
					box-shadow: 0 1px 3px rgba(0, 0, 0, 0.15);
				}

				.nm-switch input:checked + i {
					background: linear-gradient(135deg, #10b981 0%, #059669 100%);
				}

				.nm-switch input:checked + i:before {
					transform: translateX(16px);
				}

				/* 底部提示胶囊卡片 */
				.nm-tip-glass-bar {
					padding: 14px 22px;
					display: flex;
					align-items: center;
					gap: 12px;
					font-size: 0.82rem;
					color: var(--nm-txt-sub);
				}

				/* 毛玻璃编辑模态弹窗 */
				.nm-modal {
					position: fixed;
					top: 0; left: 0; right: 0; bottom: 0;
					background: rgba(15, 23, 42, 0.38);
					backdrop-filter: blur(12px);
					-webkit-backdrop-filter: blur(12px);
					display: flex;
					align-items: center;
					justify-content: center;
					z-index: 1000;
					padding: 20px;
				}

				.nm-modal-box {
					background: linear-gradient(145deg, rgba(255, 255, 255, 0.95) 0%, rgba(255, 255, 255, 0.88) 100%);
					backdrop-filter: blur(24px);
					-webkit-backdrop-filter: blur(24px);
					border: 1px solid rgba(255, 255, 255, 0.98);
					border-radius: 24px;
					box-shadow: 0 25px 50px -12px rgba(15, 23, 42, 0.25);
					max-width: 640px;
					width: 100%;
					max-height: 90vh;
					overflow-y: auto;
					padding: 28px 32px;
					display: flex;
					flex-direction: column;
					gap: 16px;
				}

				.nm-modal-title {
					margin: 0 0 6px 0;
					font-size: 1.35rem;
					font-weight: 800;
					color: var(--nm-txt-title);
					letter-spacing: -0.02em;
				}

				.nm-field {
					display: flex;
					flex-direction: column;
					gap: 6px;
				}

				.nm-field label {
					font-size: 0.84rem;
					font-weight: 700;
					color: var(--nm-txt-sub);
				}

				.nm-input, .nm-select {
					background: rgba(255, 255, 255, 0.85);
					border: 1px solid rgba(203, 213, 225, 0.85);
					border-radius: 12px;
					padding: 8px 14px;
					font-size: 0.88rem;
					color: var(--nm-txt-title);
					outline: none;
					transition: all 0.2s ease;
				}

				.nm-input:focus, .nm-select:focus {
					background: #ffffff;
					border-color: var(--nm-c-primary);
					box-shadow: 0 0 0 3px rgba(59, 130, 246, 0.16);
				}

				.nm-modal-error {
					color: var(--nm-c-bad);
					font-size: 0.84rem;
					font-weight: 600;
					min-height: 20px;
				}

				.nm-modal-actions {
					display: flex;
					justify-content: flex-end;
					gap: 12px;
					margin-top: 10px;
				}
			`;
			document.head.appendChild(style);

			/* 统一增强：卡片高光 / 弹性上浮 / 键盘可达 / 减弱动效偏好 */
			if (!document.getElementById('nm-glass-enhance')) {
				var enh = document.createElement('style');
				enh.id = 'nm-glass-enhance';
				enh.textContent = `
					.nm-page { max-width: 1360px; gap: 22px; }

					.nm-glass-card::before {
						content: '';
						position: absolute;
						top: 0; left: 0; right: 0; height: 1px;
						background: linear-gradient(90deg, transparent 0%, rgba(255, 255, 255, 0.95) 25%, rgba(255, 255, 255, 0.95) 75%, transparent 100%);
						pointer-events: none;
						z-index: 1;
					}

					.nm-glass-card:hover {
						transform: translateY(-3px);
						border-color: #ffffff;
					}

					.nm-btn-glass:focus-visible,
					.nm-btn-mini:focus-visible,
					.nm-select-glass:focus-visible,
					.nm-input-glass:focus-visible,
					.nm-input:focus-visible,
					.nm-select:focus-visible {
						outline: 2px solid rgba(59, 130, 246, 0.5);
						outline-offset: 2px;
					}

					input[type="checkbox"] { accent-color: var(--nm-c-primary); }

					.nm-switch:focus-within i { box-shadow: 0 0 0 3px rgba(59, 130, 246, 0.3); }

					@media (max-width: 640px) {
						.nm-root { padding: 16px 12px 40px; }
						.nm-page { gap: 16px; }
					}

					@media (prefers-reduced-motion: reduce) {
						.nm-glass-card,
						.nm-btn-glass,
						.nm-stat-badge,
						.nm-sum-card,
						.nm-chip-btn,
						.nm-led-ping-ring,
						.nm-svg-radar-1,
						.nm-svg-radar-2,
						.nm-svg-rotate-dash,
						.nm-svg-rotate-dash-rev,
						.nm-svg-dial-glow,
						.nm-bar-dyn-1, .nm-bar-dyn-2, .nm-bar-dyn-3, .nm-bar-dyn-4, .nm-bar-dyn-5,
						.nm-wave-b1, .nm-wave-b2, .nm-wave-b3, .nm-wave-b4, .nm-wave-b5,
						.nm-svg-soft-pulse,
						.nm-led-ping {
							animation: none !important;
							transition: none !important;
						}
					}
				`;
				document.head.appendChild(enh);
			}
		})();

		var root = common.el('div', 'nm-root');
		var page = common.el('div', 'nm-page');
		root.appendChild(page);

		/* 工具栏 */
		var bar = common.el('div', 'nm-glass-card nm-toolbar-glass');
		var row = common.el('div', 'nm-row');
		row.style.display = 'flex';
		row.style.alignItems = 'center';
		row.style.flexWrap = 'wrap';
		row.style.gap = '12px';
		row.style.width = '100%';

		function toolBtn(label, fn, isPrimary, svgIcon) {
			var b = common.el('button', 'nm-btn-glass' + (isPrimary ? ' nm-btn-primary-glass' : ''));
			if (svgIcon) {
				var icBox = common.el('span', '');
				icBox.innerHTML = svgIcon;
				b.appendChild(icBox);
			}
			b.appendChild(document.createTextNode(label));
			b.addEventListener('click', function() {
				b.disabled = true;
				Promise.resolve(fn()).then(function() {
					reload();
				}).catch(function(e) {
					common.notify(String(e.message || e), 'error');
				}).then(function() { b.disabled = false; });
			});
			return b;
		}

		var addSvg = `<svg width="15" height="15" viewBox="0 0 16 16" fill="currentColor"><path d="M8 2a1 1 0 0 1 1 1v4h4a1 1 0 1 1 0 2H9v4a1 1 0 1 1-2 0V9H3a1 1 0 0 1 0-2h4V3a1 1 0 0 1 1-1z"/></svg>`;
		var okSvg = `<svg width="15" height="15" viewBox="0 0 16 16" fill="currentColor"><path d="M13.485 1.929a1 1 0 0 1 1.414 1.414L6.343 11.899 1.1 6.657a1 1 0 0 1 1.414-1.414l3.829 3.829 7.142-7.143z"/></svg>`;
		var disSvg = `<svg width="15" height="15" viewBox="0 0 16 16" fill="currentColor"><circle cx="8" cy="8" r="6" stroke="currentColor" stroke-width="2" fill="none"/><line x1="3.5" y1="3.5" x2="12.5" y2="12.5" stroke="currentColor" stroke-width="2"/></svg>`;
		var refSvg = `<svg width="15" height="15" viewBox="0 0 16 16" fill="currentColor"><path d="M11.534 7h3.932a.25.25 0 0 1 .192.41l-1.966 2.36a.25.25 0 0 1-.384 0l-1.966-2.36a.25.25 0 0 1 .192-.41zm-11 2h3.932a.25.25 0 0 0 .192-.41L2.692 6.23a.25.25 0 0 0-.384 0L.342 8.59A.25.25 0 0 0 .534 9z"/><path fill-rule="evenodd" d="M8 3c-1.552 0-2.94.707-3.857 1.818a.5.5 0 1 1-.771-.636A6.002 6.002 0 0 1 13.917 7H12.9A5.002 5.002 0 0 0 8 3zM3.1 9a5.002 5.002 0 0 0 8.9 4.182.5.5 0 1 1 .771.636A6.002 6.002 0 0 1 2.083 9H3.1z"/></svg>`;

		row.appendChild(toolBtn(_('Add target'), function() { return openEditor(null); }, true, addSvg));
		row.appendChild(toolBtn(_('Enable selected'), function() {
			return common.api.batchTargets(selectedIds(), true);
		}, false, okSvg));
		row.appendChild(toolBtn(_('Disable selected'), function() {
			return common.api.batchTargets(selectedIds(), false);
		}, false, disSvg));
		row.appendChild(toolBtn(_('Refresh'), function() { return Promise.resolve(); }, false, refSvg));

		var spacer = common.el('div', 'nm-spacer');
		spacer.style.flex = '1';
		row.appendChild(spacer);

		var summary = common.el('div', 'nm-summary-pill');
		var sumIconBox = common.el('span', 'nm-inline-icon');
		sumIconBox.innerHTML = icons.multiTarget(targets, 30);
		summary.appendChild(sumIconBox);
		summary.appendChild(common.inlineIcon(icons.gear(26)));
		var sumProto = (cfg.default_proto === 'tcp')
			? ('TCP:' + (cfg.default_tcp_port || 80)) : 'ICMP';
		summary.appendChild(common.el('span', '',
			_('Default probe method') + ': ' + sumProto + ' · ' +
			_('Global interval') + ': ' + (cfg.interval || 10) + 's · ' +
			_('Timeout') + ': ' + (cfg.timeout || 3) + 's'));
		row.appendChild(summary);
		bar.appendChild(row);
		page.appendChild(bar);

		var wrap = common.el('div', 'nm-table-glass-wrap');
		var table = common.el('table', 'nm-table-glass');
		var thead = common.el('thead', '');
		var tbody = common.el('tbody', '');
		var htr = common.el('tr', '');
		htr.appendChild(common.el('th', '', ''));
		[_('Name'), _('Address'), _('Probe method'), _('Region'), _('Custom label'), _('Family'),
		 _('Interval'), _('Timeout'), _('Interface'), _('Enabled'), _('Actions')]
			.forEach(function(h) { htr.appendChild(common.el('th', '', h)); });
		thead.appendChild(htr);
		table.appendChild(thead);
		table.appendChild(tbody);
		wrap.appendChild(table);
		page.appendChild(wrap);

		var tipRow = common.el('div', 'nm-glass-card nm-tip-glass-bar');
		tipRow.appendChild(common.inlineIcon(icons.responsive(28)));
		var tipText = common.el('div', '');
		tipText.innerHTML = _('Interval and timeout set to 0 inherit the global settings.') +
			' · ' + _('The table scrolls horizontally on small screens.');
		tipRow.appendChild(tipText);
		page.appendChild(tipRow);

		function selectedIds() {
			var ids = [];
			for (var k in checked)
				if (checked[k]) ids.push(k);
			return ids;
		}

		function renderList(list) {
			common.clear(tbody);
			targets = list;
			sumIconBox.innerHTML = icons.multiTarget(list, 30);
			if (!list.length) {
				var tr0 = common.el('tr', '');
				var td0 = common.el('td', 'nm-empty', _('No targets'));
				td0.colSpan = 12;
				td0.style.padding = '36px';
				td0.style.textAlign = 'center';
				td0.style.color = 'var(--nm-txt-sub)';
				tr0.appendChild(td0);
				tbody.appendChild(tr0);
				return;
			}

			for (var i = 0; i < list.length; i++) {
				(function(t, idx) {
					var tr = common.el('tr', '');
					tr.setAttribute('data-id', t.id);

					var tdChk = common.el('td', '');
					tdChk.style.textAlign = 'center';
					var cb = common.el('input', '');
					cb.type = 'checkbox';
					cb.checked = !!checked[t.id];
					cb.addEventListener('change', function() { checked[t.id] = cb.checked; });
					tdChk.appendChild(cb);
					tr.appendChild(tdChk);

					tr.appendChild(common.el('td', 'nm-target-name', t.name || t.id));
					tr.appendChild(common.el('td', 'nm-target-host', t.host || ''));

					// 探测协议胶囊
					var tdMethod = common.el('td', '');
					var badge, badgeTitle, isTcp = (t.proto === 'tcp');
					if (isTcp) {
						var tport = (t.tcp_port || 0) > 0
							? t.tcp_port : (cfg.default_tcp_port || 80);
						badge = 'TCP:' + tport;
						badgeTitle = _('TCP connect') +
							(((t.tcp_port || 0) > 0) ? '' : ' · ' + _('global default port'));
					} else {
						badge = 'ICMP';
						badgeTitle = _('ICMP (ping)');
					}
					var bspan = common.el('span',
						'nm-proto-badge-glass ' + (isTcp ? 'tcp' : 'icmp'), badge);
					bspan.title = badgeTitle;
					tdMethod.appendChild(bspan);
					tr.appendChild(tdMethod);

					var tdR = common.el('td', '');
					var regCls = (t.region === 'cn') ? 'cn' : ((t.region === 'overseas') ? 'overseas' : '');
					tdR.appendChild(common.el('span', 'nm-tag-pill ' + regCls, common.regionText(t.region)));
					tr.appendChild(tdR);

					tr.appendChild(common.el('td', '', t.label || '—'));

					var fam = { auto: _('Auto'), ipv4: _('IPv4'), ipv6: _('IPv6'), both: _('IPv4 + IPv6') };
					var tdFam = common.el('td', '');
					tdFam.style.whiteSpace = 'nowrap';
					tdFam.appendChild(common.inlineIcon(icons.dualStack(t.family, true, true, 20)));
					tdFam.appendChild(document.createTextNode(' ' + (fam[t.family] || t.family)));
					tr.appendChild(tdFam);

					tr.appendChild(common.el('td', 'nm-num', (t.interval || 0) === 0 ? _('Global') : (t.interval + 's')));
					tr.appendChild(common.el('td', 'nm-num', (t.timeout || 0) === 0 ? _('Global') : (t.timeout + 's')));
					tr.appendChild(common.el('td', '', t.interface || '—'));

					// 启用状态切换开关
					var tdEn = common.el('td', '');
					tdEn.style.whiteSpace = 'nowrap';
					tdEn.appendChild(common.inlineIcon(icons.online(18, !!t.enabled)));
					var lab = common.el('label', 'nm-switch');
					var inp = common.el('input', '');
					inp.type = 'checkbox';
					inp.checked = !!t.enabled;
					inp.addEventListener('change', function() {
						common.api.updateTarget({ id: t.id, enabled: inp.checked }).then(reload).catch(function(e) {
							common.notify(String(e.message || e), 'error');
							inp.checked = !inp.checked;
						});
					});
					lab.appendChild(inp);
					lab.appendChild(common.el('i', ''));
					tdEn.appendChild(lab);
					tr.appendChild(tdEn);

					// 操作按钮组
					var tdAct = common.el('td', '');
					tdAct.style.whiteSpace = 'nowrap';

					function mini(label, fn, isDanger) {
						var b = common.el('button', 'nm-btn-mini' + (isDanger ? ' danger' : ''), label);
						b.addEventListener('click', function() {
							b.disabled = true;
							Promise.resolve(fn()).then(reload).catch(function(e) {
								common.notify(String(e.message || e), 'error');
							}).then(function() { b.disabled = false; });
						});
						return b;
					}

					tdAct.appendChild(mini(_('Edit'), function() { return openEditor(t); }));
					tdAct.appendChild(mini('↑', function() { return common.api.moveTarget(t.id, -1); }));
					tdAct.appendChild(mini('↓', function() { return common.api.moveTarget(t.id, 1); }));
					tdAct.appendChild(mini(_('Copy'), function() { return common.api.copyTarget(t.id); }));
					tdAct.appendChild(mini(_('Delete'), function() {
						if (!window.confirm(_('Delete this target?') + ' (' + (t.name || t.id) + ')'))
							return Promise.resolve();
						return common.api.deleteTarget(t.id);
					}, true));

					tr.appendChild(tdAct);
					tbody.appendChild(tr);
				})(list[i], i);
			}
		}

		/* 编辑模态弹窗 */
		function openEditor(t) {
			var modal = common.el('div', 'nm-modal');
			var box = common.el('div', 'nm-modal-box');

			box.appendChild(common.el('h3', 'nm-modal-title', t ? _('Edit target') : _('Add target')));

			var fields = {};

			function field(label, key, control) {
				var f = common.el('div', 'nm-field');
				control.setAttribute('data-nm-key', key);
				f.appendChild(common.el('label', '', label));
				f.appendChild(control);
				fields[key] = control;
				box.appendChild(f);
			}

			function input(cls, value) {
				var i = common.el('input', cls || 'nm-input');
				i.value = (value == null ? '' : value);
				i.type = 'text';
				return i;
			}

			function select(options, value) {
				var s = common.el('select', 'nm-select');
				options.forEach(function(o) {
					var op = common.el('option', '', o[1]);
					op.value = o[0];
					s.appendChild(op);
				});
				s.value = value;
				return s;
			}

			var protoSel = select([
				['icmp', _('ICMP (ping)')], ['tcp', _('TCP connect')]
			], t ? (t.proto || 'icmp') : (cfg.default_proto || 'icmp'));

			var portInp = input('', (t && t.tcp_port) ? t.tcp_port : '');
			portInp.type = 'number';
			portInp.min = '0';
			portInp.max = '65535';

			function syncProto() {
				var isTcp = (protoSel.value === 'tcp');
				portInp.disabled = !isTcp;
				portInp.placeholder = isTcp
					? String(cfg.default_tcp_port || 80)
					: _('Not used by ICMP');
				portInp.style.opacity = isTcp ? '1' : '0.5';
			}
			protoSel.addEventListener('change', syncProto);

			field(_('Name'), 'name', input('', t ? t.name : ''));
			field(_('Address'), 'host', input('', t ? t.host : ''));
			field(_('Probe method'), 'proto', protoSel);
			field(_('TCP port (0 = global default)'), 'tcp_port', portInp);
			field(_('Region'), 'region', select([
				['cn', _('China')], ['overseas', _('Overseas')], ['other', _('Other')]
			], t ? t.region : 'cn'));
			field(_('Custom label'), 'label', input('', t ? t.label : ''));
			field(_('Address family'), 'family', select([
				['auto', _('Auto')], ['ipv4', _('IPv4 only')], ['ipv6', _('IPv6 only')], ['both', _('IPv4 + IPv6')]
			], t ? t.family : 'auto'));
			field(_('Check interval (s, 0 = global)'), 'interval', input('', t ? t.interval : 0));
			field(_('Timeout (s, 0 = global)'), 'timeout', input('', t ? t.timeout : 0));
			field(_('Interface (optional)'), 'interface', input('', t ? t.interface : ''));
			field(_('Source address (optional)'), 'source', input('', t ? t.source : ''));
			field(_('Remark'), 'remark', input('', t ? t.remark : ''));
			syncProto();

			var enRow = common.el('div', 'nm-row');
			enRow.style.display = 'flex';
			enRow.style.alignItems = 'center';
			enRow.style.gap = '10px';
			enRow.style.margin = '8px 0';
			var lab = common.el('label', 'nm-switch');
			var enInp = common.el('input', '');
			enInp.type = 'checkbox';
			enInp.checked = t ? !!t.enabled : true;
			lab.appendChild(enInp);
			lab.appendChild(common.el('i', ''));
			enRow.appendChild(lab);
			enRow.appendChild(common.el('span', '', _('Enabled')));
			box.appendChild(enRow);

			var errBox = common.el('div', 'nm-modal-error');
			box.appendChild(errBox);

			var actions = common.el('div', 'nm-modal-actions');
			var btnCancel = common.el('button', 'nm-btn-glass', _('Cancel'));
			var btnSave = common.el('button', 'nm-btn-glass nm-btn-primary-glass', _('Save & Apply'));

			function close() {
				if (modal.parentNode) modal.parentNode.removeChild(modal);
			}
			btnCancel.addEventListener('click', close);

			btnSave.addEventListener('click', function() {
				var proto = fields.proto.value;
				var port = parseInt(fields.tcp_port.value, 10);
				if (isNaN(port) || port < 0) port = 0;
				if (port > 65535) port = 65535;
				if (proto !== 'tcp') port = 0;

				var data = {
					name: fields.name.value.trim(),
					host: fields.host.value.trim(),
					proto: proto,
					tcp_port: port,
					region: fields.region.value,
					label: fields.label.value.trim(),
					family: fields.family.value,
					interval: parseInt(fields.interval.value, 10) || 0,
					timeout: parseInt(fields.timeout.value, 10) || 0,
					interface: fields.interface.value.trim(),
					source: fields.source.value.trim(),
					remark: fields.remark.value.trim(),
					enabled: enInp.checked ? '1' : '0'
				};
				if (!data.name || !data.host) {
					errBox.textContent = _('Name and address are required');
					return;
				}
				if (proto === 'tcp' && port === 0 && !(cfg.default_tcp_port > 0)) {
					errBox.textContent = _('TCP targets need a port or a global default port');
					return;
				}
				btnSave.disabled = true;
				btnCancel.disabled = true;

				var p;
				if (t) {
					var ops = [];
					for (var k in data)
						ops.push({ sid: t.id, opt: k, val: data[k] });
					p = common.saveConfig(ops);
				} else {
					p = common.addSection('netmonitor', 'target', data);
				}
				p.then(function(changed) {
					if (changed === 0) {
						close();
						common.notify(_('No changes to save'));
						return;
					}
					close();
					return common.applyChanges();
				}).catch(function(e) {
					if (!modal.parentNode) return;
					errBox.textContent = String(e.message || e);
					btnSave.disabled = false;
					btnCancel.disabled = false;
				});
			});

			actions.appendChild(btnCancel);
			actions.appendChild(btnSave);
			box.appendChild(actions);

			modal.appendChild(box);
			modal.addEventListener('click', function(ev) {
				if (ev.target === modal) close();
			});
			document.body.appendChild(modal);
			return Promise.resolve();
		}

		function reload() {
			return common.api.getTargets().then(function(d) {
				renderList(d.targets || []);
			});
		}

		renderList(targets);
		return root;
	}
});
