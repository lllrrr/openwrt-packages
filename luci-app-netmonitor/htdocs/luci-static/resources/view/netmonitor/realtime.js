/*
 * 实时监控页面：以表格形式列出所有目标的实时状态
 * 手机端表格可横向滚动，不出现页面溢出。
 */

'use strict';
'require view';
'require poll';
'require netmonitor.common as common';
'require netmonitor.icons as icons';

return view.extend({
	load: function() {
		common.css();
		return Promise.all([common.loadI18n(), common.api.getConfig()]);
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

		/* 工具栏 */
		var bar = common.el('div', 'nm-card');
		var barRow = common.el('div', 'nm-row');

		var fRegion = common.el('div', 'nm-field');
		var selRegion = common.el('select', 'nm-select');
		[
			['all', _('All regions')],
			['cn', _('China')],
			['overseas', _('Overseas')],
			['other', _('Other')]
		].forEach(function(o) {
			var op = common.el('option', '', o[1]);
			op.value = o[0];
			selRegion.appendChild(op);
		});
		selRegion.addEventListener('change', function() { filterRegion = selRegion.value; renderTable(); });
		fRegion.appendChild(common.el('label', '', _('Region')));
		fRegion.appendChild(selRegion);
		barRow.appendChild(fRegion);

		var fStatus = common.el('div', 'nm-field');
		var selStatus = common.el('select', 'nm-select');
		[
			['all', _('All status')],
			['online', _('Online')],
			['failed', _('Failed')],
			['disabled', _('Disabled')]
		].forEach(function(o) {
			var op = common.el('option', '', o[1]);
			op.value = o[0];
			selStatus.appendChild(op);
		});
		selStatus.addEventListener('change', function() { filterStatus = selStatus.value; renderTable(); });
		fStatus.appendChild(common.el('label', '', _('Status')));
		fStatus.appendChild(selStatus);
		barRow.appendChild(fStatus);

		var fKw = common.el('div', 'nm-field');
		var inKw = common.el('input', 'nm-input');
		inKw.type = 'search';
		inKw.placeholder = _('Search name or address');
		inKw.addEventListener('input', function() { keyword = inKw.value.toLowerCase(); renderTable(); });
		fKw.appendChild(common.el('label', '', _('Search')));
		fKw.appendChild(inKw);
		barRow.appendChild(fKw);

		barRow.appendChild(common.el('div', 'nm-spacer'));

		var btnPause = common.el('button', 'nm-btn', _('Pause'));
		btnPause.addEventListener('click', function() {
			paused = !paused;
			btnPause.textContent = paused ? _('Resume') : _('Pause');
		});
		barRow.appendChild(btnPause);

		bar.appendChild(barRow);
		page.appendChild(bar);

		/* 实时指标条：与表格同源（同一次 getStatus），不会造成额外探测 */
		var strip = common.el('div', 'nm-grid');
		page.appendChild(strip);

		/* 表格 */
		var wrap = common.el('div', 'nm-table-wrap');
		var table = common.el('table', 'nm-table');
		var thead = common.el('thead', '');
		var tbody = common.el('tbody', '');
		table.appendChild(thead);
		table.appendChild(tbody);
		wrap.appendChild(table);
		page.appendChild(wrap);

		var heads = [
			'', _('Name'), _('Address'), _('Region'), _('Status'),
			_('Current'), _('Average'), _('P95'), _('Loss'),
			_('Availability'), _('Fails'), _('Last check')
		];
		var tr = common.el('tr', '');
		heads.forEach(function(h) {
			var th = common.el('th', '', h);
			tr.appendChild(th);
		});
		thead.appendChild(tr);

		/* 卡片视图（窄屏时更友好） */
		var cards = common.el('div', 'nm-grid-wide');
		page.appendChild(cards);

		var foot = common.el('div', 'nm-card nm-card-sub');
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

		/* 每一行的状态图标按真实的失败类型切换：
		 * DNS 失败显示地球+叉、超时显示丢包、高延迟显示波形，正常显示在线环。
		 * 也就是说图标是「诊断结果的可视化」，而不是同一个图标换个颜色。 */
		function statusIcon(t) {
			if (!t.enabled) return icons.online(22, false);
			if (t.last_error === 'dns') return icons.dnsFail(22);
			if (t.last_error) return icons.packetLoss(100, 22);
			if (t.grade === 'poor' || t.grade === 'severe') return icons.highLatency(t.latency, t.grade, 22);
			return icons.online(22, true);
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

		function renderStrip(d) {
			common.clear(strip);
			var o = d.overall || {};
			var ok = (o.offline || 0) === 0;

			strip.appendChild(common.iconCard(_('Online targets'),
				String(o.online || 0) + ' / ' + String(o.total || 0),
				_('Abnormal') + ': ' + (o.offline || 0), icons.online(60, ok),
				ok ? 'nm-c-ok' : 'nm-c-bad'));

			strip.appendChild(common.iconCard(_('Current latency'),
				common.fmt.latency(o.current) + ' ms',
				_('Latest probe round'), icons.latencyDial(o.current, gradeFromCfg(o.current), 60),
				common.gradeClass(gradeFromCfg(o.current))));

			strip.appendChild(common.iconCard(_('Packet loss'), common.fmt.percent(o.loss),
				_('Weighted by samples'), icons.lossRing(o.loss, 60),
				(o.loss > 5) ? 'nm-c-bad' : (o.loss > 0 ? 'nm-c-warn' : 'nm-c-ok')));

			strip.appendChild(common.iconCard(_('Last check'), common.fmt.ago(d.tick),
				common.fmt.clock(d.tick), icons.clock(d.tick, 60)));
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
				tr0.appendChild(td0);
				tbody.appendChild(tr0);
				return;
			}

			for (var i = 0; i < list.length; i++) {
				var t = list[i];
				var row = common.el('tr', '');

				var tdDot = common.el('td', '');
				tdDot.appendChild(common.el('span', common.dotClass(t.grade), ''));
				row.appendChild(tdDot);

				row.appendChild(common.el('td', '', t.name || t.id));
				row.appendChild(common.el('td', 'nm-target-host', t.host || ''));

				var tdRegion = common.el('td', '');
				tdRegion.appendChild(common.el('span', common.regionTagClass(t.region),
					t.label ? t.label : common.regionText(t.region)));
				row.appendChild(tdRegion);

				var stText = t.enabled ? (t.status === 'online' ? _('Online') : _('Failed')) : _('Disabled');
				if (!t.enabled) stText = _('Disabled');
				else if (t.last_error) stText = common.errorText(t.last_error);
				var tdSt = common.el('td', '');
				tdSt.style.display = 'flex';
				tdSt.style.alignItems = 'center';
				tdSt.style.gap = '6px';
				tdSt.appendChild(common.inlineIcon(statusIcon(t)));
				tdSt.appendChild(common.el('span', common.gradeClass(t.grade), stText));
				row.appendChild(tdSt);

				row.appendChild(common.el('td', 'nm-num', common.fmt.latency(t.latency)));
				row.appendChild(common.el('td', 'nm-num', common.fmt.latency(t.avg)));
				row.appendChild(common.el('td', 'nm-num', common.fmt.latency(t.p95)));
				row.appendChild(common.el('td', 'nm-num', common.fmt.percent(t.loss)));
				row.appendChild(common.el('td', 'nm-num', common.fmt.percent(t.success_rate, 0)));
				row.appendChild(common.el('td', 'nm-num', String(t.streak_fail || 0)));
				row.appendChild(common.el('td', '', common.fmt.ago(t.last_check)));

				tbody.appendChild(row);
				cards.appendChild(common.targetCard(t));
			}

			foot.textContent = _('Updated') + ': ' + common.fmt.clock(latest.updated) +
				' · ' + _('Interval') + ': ' + (cfg.interval || 10) + 's' +
				' · ' + _('UI refresh') + ': ' + refresh + 's';
		}

		function update() {
			if (paused) return Promise.resolve();
			return common.api.getStatus(false).then(function(d) {
				latest = d;
				renderTable();
			}).catch(function(e) {
				common.clear(tbody);
				var tr0 = common.el('tr', '');
				var td0 = common.el('td', 'nm-empty', String(e.message || e));
				td0.colSpan = heads.length;
				tr0.appendChild(td0);
				tbody.appendChild(tr0);
			});
		}

		update();
		poll.add(update, refresh);

		return root;
	}
});
