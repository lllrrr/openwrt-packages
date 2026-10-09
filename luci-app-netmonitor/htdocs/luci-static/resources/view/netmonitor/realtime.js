/*
 * 实时监控页面：以表格形式列出所有目标的实时状态
 *
 * UI 结构：暂停/恢复按钮用 ui.button()（原生 <button>），区域标记用 ui.chip()。
 * 不再依赖 TDesign Web Components —— 原 <t-dialog> 因随包样式表残缺
 * （无 dialog 定位规则）而停在 display:none 状态，详见 netmonitor/ui.js 文件头。
 *
 * 明细表格保留 .nm-table 平面结构，动态呼吸 LED 与实时指标条保留。
 * 筛选下拉沿用原生 <select>：TDesign 的 t-select 在受控模式下实测无法展开。
 * 手机端表格可横向平滑滚动，并支持自适应卡片流展示。
 */

'use strict';
'require view';
'require poll';
'require netmonitor.common as common';
'require netmonitor.icons as icons';

return view.extend({
	load: function() {
		common.css();
		return Promise.all([
			common.loadI18n(),
			common.api.getConfig()
		]);
	},

	render: function(res) {
		common.css();

		var cfg = (res && res[1]) || {};
		var refresh = Math.max(1, parseInt(cfg.ui_refresh, 10) || 2);

		var filterRegion = 'all';
		var filterStatus = 'all';
		var keyword = '';
		var paused = false;
		var latest = null;

		var root = common.el('div', 'nm-root');
		var page = common.el('div', 'nm-page');
		root.appendChild(page);

		/* 原生下拉：沿用 .nm-select 样式，交互由浏览器保证，
		 * 兼容 LuCI 全部目标浏览器。 */
		function makeSelect(options, value) {
			var sel = document.createElement('select');
			sel.className = 'nm-select';
			options.forEach(function(o) {
				var opt = document.createElement('option');
				opt.value = o.value;
				opt.textContent = o.label;
				sel.appendChild(opt);
			});
			sel.value = value;
			return sel;
		}

		/* 工具栏 */
		var bar = common.tcard();
		var barRow = common.el('div', 'nm-toolbar-row');

		/* 区域筛选 */
		var fRegion = common.el('div', 'nm-field-glass');
		var selRegion = makeSelect([
			{ label: _('全部区域'), value: 'all' },
			{ label: _('国内'), value: 'cn' },
			{ label: _('国外'), value: 'overseas' },
			{ label: _('其他'), value: 'other' }
		], 'all');
		selRegion.addEventListener('change', function() {
			filterRegion = selRegion.value;
			renderTable();
		});
		fRegion.appendChild(common.el('label', '', _('区域')));
		fRegion.appendChild(selRegion);
		barRow.appendChild(fRegion);

		/* 状态筛选 */
		var fStatus = common.el('div', 'nm-field-glass');
		var selStatus = makeSelect([
			{ label: _('全部状态'), value: 'all' },
			{ label: _('在线'), value: 'online' },
			{ label: _('失败'), value: 'failed' },
			{ label: _('停用'), value: 'disabled' }
		], 'all');
		selStatus.addEventListener('change', function() {
			filterStatus = selStatus.value;
			renderTable();
		});
		fStatus.appendChild(common.el('label', '', _('状态')));
		fStatus.appendChild(selStatus);
		barRow.appendChild(fStatus);

		/* 关键字搜索 */
		var fKw = common.el('div', 'nm-field-glass');
		var inKw = document.createElement('input');
		inKw.type = 'text';
		inKw.className = 'nm-input';
		inKw.setAttribute('placeholder', _('搜索名称或地址'));
		inKw.addEventListener('input', function() {
			keyword = String(inKw.value || '').toLowerCase();
			renderTable();
		});
		fKw.appendChild(common.el('label', '', _('搜索')));
		fKw.appendChild(inKw);
		barRow.appendChild(fKw);

		var spacer = common.el('div', 'nm-spacer');
		spacer.style.flex = '1';
		barRow.appendChild(spacer);

		/* 暂停 / 恢复按钮。图标与文案都随 paused 变化，而 ui.button 的
		 * label / icon 是创建时定死的，所以每次切换整个换成一个新按钮，
		 * 而不是去改已有节点的子节点。 */
		var icoPause = '<svg width="14" height="14" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M4 3h3v10H4V3zm5 0h3v10H9V3z"/></svg>';
		var icoResume = '<svg width="14" height="14" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M4 3l9 5-9 5V3z"/></svg>';

		function makePauseBtn() {
			return common.ui.button({
				label: paused ? _('Resume') : _('暂停'),
				icon: paused ? icoResume : icoPause,
				variant: 'outline',
				onClick: function() {
					paused = !paused;
					var next = makePauseBtn();
					barRow.replaceChild(next, btnPause);
					btnPause = next;
				}
			});
		}

		var btnPause = makePauseBtn();
		barRow.appendChild(btnPause);

		bar.appendChild(barRow);
		page.appendChild(bar);

		/* 顶部实时指标条 */
		var strip = common.el('div', 'nm-strip-grid');
		page.appendChild(strip);

		/* 明细表格（平面 .nm-table，桌面显示） */
		var wrap = common.el('div', 'nm-table-wrap nm-realtime-table-wrap');
		var table = common.el('table', 'nm-table');
		var thead = common.el('thead', '');
		var tbody = common.el('tbody', '');
		table.appendChild(thead);
		table.appendChild(tbody);
		wrap.appendChild(table);
		page.appendChild(wrap);

		var heads = [
			'', _('名称'), _('地址'), _('区域'), _('状态'),
			_('当前'), _('平均'), _('P95'), _('丢包'),
			_('在线率'), _('连续失败'), _('最后检测')
		];
		var tr = common.el('tr', '');
		heads.forEach(function(h, hi) {
			var th = common.el('th', '', h);
			/* 首列是状态指示列（原为空表头），补上列名；
			 * 其余列加 scope，读屏逐格导航时能正确播报列名。 */
			if (hi === 0)
				th.setAttribute('aria-label', _('Status'));
			else
				th.setAttribute('scope', 'col');
			tr.appendChild(th);
		});
		thead.appendChild(tr);

		/* 窄屏自适应卡片流容器 */
		var cards = common.el('div', 'nm-cards-mobile');
		page.appendChild(cards);

		/* 底部状态提示条 */
		var foot = common.tcard('nm-foot-sub');
		page.appendChild(foot);

		function match(t) {
			if (filterRegion !== 'all' && t.region !== filterRegion) return false;
			if (filterStatus !== 'all' && t.status !== filterStatus) return false;
			if (keyword) {
				var s = ((t.name || '') + ' ' + (t.host || '') + ' ' + (t.label || '')).toLowerCase();
				if (s.indexOf(keyword) < 0) return false;
			}
			return true;
		}

		/* 状态诊断图标（矢量） */
		function statusIcon(t) {
			if (!t.enabled) return icons.online(20, false);
			if (t.last_error === 'dns') return icons.dnsFail(20);
			if (t.last_error) return icons.packetLoss(100, 20);
			if (t.grade === 'poor' || t.grade === 'severe') return icons.highLatency(t.latency, t.grade, 20);
			return icons.online(20, true);
		}

		/* 动态呼吸 LED 节点 */
		function createLedIndicator(t) {
			var w = common.el('div', 'nm-led-box');
			var cls = 'nm-led-off';
			if (t.enabled) {
				if (t.status === 'online') {
					cls = (t.grade === 'poor' || t.grade === 'severe') ? 'nm-led-warn' : 'nm-led-good';
				} else {
					cls = 'nm-led-bad';
				}
			}
			w.classList.add(cls);
			w.appendChild(common.el('span', 'nm-led-ping-ring', ''));
			w.appendChild(common.el('span', 'nm-led-center', ''));
			return w;
		}

		function gradeFromCfg(ms) {
			if (ms == null || isNaN(ms)) return 'unknown';
			var ex = parseFloat(cfg.latency_excellent) || 50;
			var gd = parseFloat(cfg.latency_good) || 100;
			var fr = parseFloat(cfg.latency_fair) || 200;
			var pr = parseFloat(cfg.latency_poor) || 500;
			if (ms <= ex) return 'excellent';
			if (ms <= gd) return 'good';
			if (ms <= fr) return 'fair';
			if (ms <= pr) return 'poor';
			return 'severe';
		}

		/* 区域标记 */
		function regionTag(t) {
			var kind = (t.region === 'cn') ? 'info'
				: ((t.region === 'overseas') ? 'warn' : 'idle');
			return common.ui.chip({
				text: t.label ? t.label : common.regionText(t.region),
				kind: kind
			});
		}

		/* 指标速览小卡 */
		function makeStripCard(title, val, subText, svgIcon, valCls) {
			var card = common.tcard();
			var inner = common.el('div', 'nm-card-inner');

			var head = common.el('div', 'nm-card-header');
			head.appendChild(common.el('span', 'nm-card-label', title));

			if (svgIcon) {
				var icoBox = common.el('div', 'nm-card-icon-box');
				/* 图标来自 icons.js（内置常量字符串，不含用户输入），可安全走 innerHTML */
				if (typeof svgIcon === 'string') icoBox.innerHTML = svgIcon;
				else icoBox.appendChild(svgIcon);
				head.appendChild(icoBox);
			}

			inner.appendChild(head);
			inner.appendChild(common.el('div', 'nm-card-number ' + (valCls || ''), val));
			if (subText) inner.appendChild(common.el('div', 'nm-card-description', subText));

			card.appendChild(inner);
			return card;
		}

		function renderStrip(d) {
			common.clear(strip);
			var o = d.overall || {};
			var ok = (o.offline || 0) === 0;

			strip.appendChild(makeStripCard(
				_('在线目标'),
				String(o.online || 0) + ' / ' + String(o.total || 0),
				_('异常') + ': ' + (o.offline || 0),
				icons.online(46, ok),
				ok ? 'nm-c-ok' : 'nm-c-bad'
			));

			var curGrade = gradeFromCfg(o.current);
			strip.appendChild(makeStripCard(
				_('当前延迟'),
				common.fmt.latency(o.current) + ' ms',
				_('最近一次检测'),
				icons.latencyDial(o.current, curGrade, 46),
				common.gradeClass(curGrade)
			));

			strip.appendChild(makeStripCard(
				_('丢包率'),
				common.fmt.percent(o.loss),
				_('按样本加权'),
				icons.lossRing(o.loss, 46),
				(o.loss > 5) ? 'nm-c-bad' : (o.loss > 0 ? 'nm-c-warn' : 'nm-c-ok')
			));

			strip.appendChild(makeStripCard(
				_('最后检测'),
				common.fmt.ago(d.tick),
				common.fmt.clock(d.tick),
				icons.clock(d.tick, 46)
			));
		}

		function renderTable() {
			if (!latest) return;
			common.clear(tbody);
			common.clear(cards);
			renderStrip(latest);

			var list = (latest.targets || []).filter(match);
			if (!list.length) {
				var tr0 = common.el('tr', '');
				var td0 = common.el('td', 'nm-empty', _('No matching targets'));
				td0.colSpan = heads.length;
				td0.style.padding = '38px';
				td0.style.textAlign = 'center';
				tr0.appendChild(td0);
				tbody.appendChild(tr0);

				var emptyCard = common.tcard();
				emptyCard.appendChild(common.el('div', 'nm-empty', _('No matching targets')));
				cards.appendChild(emptyCard);
				return;
			}

			for (var i = 0; i < list.length; i++) {
				var t = list[i];
				var row = common.el('tr', '');

				// 1. 动态呼吸 LED 状态指示
				var tdDot = common.el('td', '');
				tdDot.style.textAlign = 'center';
				tdDot.appendChild(createLedIndicator(t));
				row.appendChild(tdDot);

				// 2. 名称
				row.appendChild(common.el('td', 'nm-target-name', t.name || t.id));

				// 3. 地址
				row.appendChild(common.el('td', 'nm-target-host', t.host || ''));

			// 4. 区域标记
			var tdRegion = common.el('td', '');
			tdRegion.appendChild(regionTag(t));
			row.appendChild(tdRegion);

			// 5. 状态与诊断图标
			/* 状态文案：停用优先，其次具体错误类型（DNS/超时/不可达），
			 * 最后才回落到笼统的「在线 / 失败」。原先先三元赋值再 if 覆写，
			 * 两个分支表达同一件事且顺序易错，这里合并为一条判定链。 */
			var stText;
			if (!t.enabled) stText = _('停用');
			else if (t.last_error) stText = common.errorText(t.last_error);
			else stText = (t.status === 'online') ? _('在线') : _('失败');

				var tdSt = common.el('td', '');
				tdSt.style.display = 'flex';
				tdSt.style.alignItems = 'center';
				tdSt.style.gap = '8px';
				tdSt.appendChild(common.inlineIcon(statusIcon(t)));
				tdSt.appendChild(common.el('span', common.gradeClass(t.grade), stText));
				row.appendChild(tdSt);

				// 6-11. 指标数值
				row.appendChild(common.el('td', 'nm-num', common.fmt.latency(t.latency)));
				row.appendChild(common.el('td', 'nm-num', common.fmt.latency(t.avg)));
				row.appendChild(common.el('td', 'nm-num', common.fmt.latency(t.p95)));
				row.appendChild(common.el('td', 'nm-num', common.fmt.percent(t.loss)));
				row.appendChild(common.el('td', 'nm-num', common.fmt.percent(t.success_rate, 0)));
				row.appendChild(common.el('td', 'nm-num', String(t.streak_fail || 0)));

				// 12. 最后检查时间
				row.appendChild(common.el('td', 'nm-txt-sub', common.fmt.ago(t.last_check)));

				tbody.appendChild(row);

				// 窄屏卡片构建
				cards.appendChild(common.targetCard(t));
			}

			foot.textContent = _('更新') + ': ' + common.fmt.clock(latest.updated) +
				' · ' + _('间隔') + ': ' + (cfg.interval || 10) + 's' +
				' · ' + _('界面刷新') + ': ' + refresh + 's';
		}

		/* 首次加载标记。
		 *
		 * update() 在 render() 末尾被同步调用一次，那时 LuCI 还没把 root
		 * 挂到文档上，root.isConnected 为 false。而 poll 触发的后续调用
		 * 是页面已挂载后才发生的。两者必须区分：
		 *   - 首次调用：此时 root 尚未入文档，不能据此判定「页面已卸载」；
		 *     若误判会立刻自注销并短路返回，latest 永远拿不到数据，
		 *     表格与卡片流全部空白（只剩工具栏的几十个字符）。
		 *   - 轮询调用：root.isConnected 为 false 才真正代表页面被 SPA
		 *     路由换掉，此时自注销，避免访问 N 次累积 N 路轮询打 rpcd。
		 */
		var firstRun = true;

		function update() {
			if (!firstRun && !root.isConnected) {
				poll.remove(update);
				return Promise.resolve();
			}
			firstRun = false;
			if (paused) return Promise.resolve();
			return common.api.getStatus(false).then(function(d) {
				latest = d;
				renderTable();
			}).catch(function(e) {
				common.clear(tbody);
				var tr0 = common.el('tr', '');
				var td0 = common.el('td', 'nm-empty', String(e.message || e));
				td0.colSpan = heads.length;
				td0.style.padding = '28px';
				tr0.appendChild(td0);
				tbody.appendChild(tr0);
			});
		}

		update();
		poll.add(update, refresh);

		return root;
	}
});
