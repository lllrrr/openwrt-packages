/*
 * 总览页面：总体健康状态、关键指标、目标卡片
 * 采用局部刷新（LuCI poll），不会整页重载，也不会触发额外的 Ping。
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
			common.api.getConfig(),
			common.api.getStatus(true)
		]);
	},

	render: function(res) {
		common.css();

		var cfg = (res && res[1]) || {};
		var first = (res && res[2]) || null;
		var refresh = Math.max(1, parseInt(cfg.ui_refresh, 10) || 2);

		var root = common.el('div', 'nm-root');
		var page = common.el('div', 'nm-page');
		root.appendChild(page);

		var hero = common.el('div', 'nm-hero');
		var bannerBox = common.el('div', '');
		var kpi = common.el('div', 'nm-grid');
		var live = common.el('div', 'nm-grid');
		var cards = common.el('div', 'nm-grid-wide');
		var foot = common.el('div', 'nm-card');

		page.appendChild(hero);
		page.appendChild(bannerBox);
		page.appendChild(kpi);
		page.appendChild(live);
		page.appendChild(cards);
		page.appendChild(foot);

		/* 阈值来自后端 thresholds（UCI 可配），因此图标等级与后端判定完全一致，
		 * 不会出现「前端显示良好、后端已判严重」的错位。 */
		function gradeOf(ms, th) {
			if (ms == null || isNaN(ms)) return 'unknown';
			th = th || {};
			var ex = parseFloat(th.latency_excellent) || 50;
			var gd = parseFloat(th.latency_good) || 100;
			var fr = parseFloat(th.latency_fair) || 200;
			var pr = parseFloat(th.latency_poor) || 500;
			if (ms <= ex) return 'excellent';
			if (ms <= gd) return 'good';
			if (ms <= fr) return 'fair';
			if (ms <= pr) return 'poor';
			return 'severe';
		}

		function renderHero(d) {
			common.clear(hero);

			var state = 'unknown';
			if (d.health === 'good') state = 'good';
			else if (d.health === 'warning') state = 'warning';
			else if (d.health === 'critical') state = 'critical';

			hero.style.setProperty('--nm-hero-glow',
				state === 'good' ? 'rgba(46,158,91,0.12)' :
				(state === 'unknown' ? 'transparent' : 'rgba(207,68,55,0.12)'));

			hero.appendChild(common.svgBox(icons.health(state, 72), 'nm-hero-icon'));

			var main = common.el('div', 'nm-hero-main');
			var title = _('No monitoring data');
			var desc = _('Add and enable monitoring targets to start collecting data.');

			if (state === 'good') {
				title = _('Network is healthy');
				desc = _('All monitored targets respond normally.');
			} else if (state === 'warning') {
				title = _('Network problems detected');
				desc = _('Some targets are unreachable or unstable.');
			} else if (state === 'critical') {
				title = _('Serious network failure');
				desc = _('One or more targets failed consecutively beyond the threshold.');
			}

			main.appendChild(common.el('h3', 'nm-hero-title', title));
			main.appendChild(common.el('div', 'nm-hero-desc', desc));

			var o = d.overall || {};
			var stats = common.el('div', 'nm-hero-stats');
			function stat(v, label) {
				var s = common.el('div', 'nm-hero-stat');
				s.appendChild(common.el('b', '', v));
				s.appendChild(common.el('span', '', label));
				return s;
			}
			stats.appendChild(stat(common.fmt.latency(o.current) + ' ms', _('Current latency')));
			stats.appendChild(stat(common.fmt.percent(o.loss), _('Packet loss')));
			stats.appendChild(stat(String(o.online || 0), _('Online')));
			stats.appendChild(stat(String(o.offline || 0), _('Abnormal')));
			stats.appendChild(stat(String(o.total || 0), _('Target count')));
			main.appendChild(stats);

			hero.appendChild(main);
		}

		function renderBanners(d) {
			common.clear(bannerBox);
			if (!d.running) {
				bannerBox.appendChild(common.banner(
					_('Background service is not running. Monitoring is stopped.'), 'warn'));
			} else if (d.stale) {
				bannerBox.appendChild(common.banner(
					_('Background service did not update data recently. Check the service status.'), 'warn'));
			}
			if (d.overall && d.overall.total === 0) {
				bannerBox.appendChild(common.banner(
					_('No enabled targets. Go to Targets to add one.'), 'info'));
			}
		}

		function renderKpi(d) {
			common.clear(kpi);
			var o = d.overall || {};
			var r = d.regions || {};
			var cn = r.cn || {};
			var ov = r.overseas || {};
			var list = d.targets || [];
			var th = d.thresholds || {};

			function regionCard(title, x, svg) {
				var c = common.el('div', 'nm-card');
				var head = common.el('div', 'nm-row');
				head.appendChild(common.el('span', 'nm-card-title', title));
				c.appendChild(head);

				/* 主值刻意取「该区域按包样本量加权的丢包率」，而不是在线目标数：
				 * 这一页要回答的是「国内 / 国外各自的丢包情况」，加权丢包率才是
				 * 两组之间可直接比较的量；在线数放在副行，仍然一眼可见。 */
				var lossCls = (x.loss > 5) ? 'nm-c-warn' : (x.loss > 0 ? '' : 'nm-c-ok');
				c.appendChild(common.el('div', 'nm-card-value ' + lossCls,
					common.fmt.percent(x.loss, 1)));

				var sub = common.el('div', 'nm-card-sub');
				sub.appendChild(common.el('div', '', _('Weighted loss') + ' · ' +
					_('Samples') + ': ' + (x.loss_samples || 0)));
				sub.appendChild(common.el('div', '',
					_('Online') + ' ' + (x.online || 0) + ' / ' + (x.total || 0) + ' · ' +
					_('Avg') + ' ' + common.fmt.latency(x.avg) + ' ms · ' +
					_('P95') + ' ' + common.fmt.latency(x.p95) + ' ms'));
				if (x.loss_lost > 0)
					sub.appendChild(common.el('div', '', _('Lost packets') + ': ' + x.loss_lost));
				c.appendChild(sub);
				common.cardIcon(c, svg);
				return c;
			}

			var curGrade = gradeOf(o.current, th);

			kpi.appendChild(common.kpiCard(_('Average latency'), common.fmt.latency(o.avg) + ' ms',
				_('Across enabled targets'), 'nm-c-ok', icons.trend(52)));
			kpi.appendChild(common.kpiCard(_('Current latency'), common.fmt.latency(o.current) + ' ms',
				_('Latest probe round'), common.gradeClass(curGrade),
				icons.latencyDial(o.current, curGrade, 52)));
			/* 整体丢包率：主值是**按包样本量加权**的口径 Σ(丢包) / Σ(发送)，
			 * 也就是把所有启用目标的探测包合并统计；副标题给出样本量与
			 * 每目标等权的对照值，两个口径都摆在明面上，不再出现
			 * 「标签写 Weighted by samples、实现却是等权平均」这种前后不一致。 */
			var lossSub = _('Weighted by samples') + ': ' + (o.loss_samples || 0) + ' · ' +
			_('Unweighted') + ' ' + common.fmt.percent(o.loss_avg, 1);
			if (o.loss_lost > 0)
				lossSub += ' · ' + _('Lost packets') + ': ' + o.loss_lost;
			kpi.appendChild(common.kpiCard(_('Packet loss'),
				common.fmt.percent(o.loss, 1), lossSub,
				(o.loss > 5 ? 'nm-c-warn' : 'nm-c-ok'),
				icons.packetLoss(o.loss, 52)));
			kpi.appendChild(regionCard(_('China network'), cn, icons.regionCN(52, cn, cn.avg)));
			kpi.appendChild(regionCard(_('Overseas network'), ov, icons.regionGlobal(52, ov, ov.avg)));
			kpi.appendChild(common.kpiCard(_('Online targets'), String(o.online || 0),
				_('Abnormal') + ': ' + (o.offline || 0), 'nm-c-ok', icons.multiTarget(list, 52)));
		}

		/* 实时指标区：每一格都是「图标 + 该图标所代表功能的真实读数」。
		 * 图标本身随数据变化：圆环弧长 = 百分比、指针 = 延迟等级、
		 * 表盘指针 / 时钟指针 = 真实时间与数值，不是固定装饰。 */
		function renderLive(d) {
			common.clear(live);
			var o = d.overall || {};
			var list = d.targets || [];
			var cfgv = cfg || {};

			/* 成功率为按样本数加权，样本为 0 时不伪造 100% */
			var acc = 0, samples = 0;
			for (var i = 0; i < list.length; i++) {
				if (!list[i].enabled) continue;
				var s = list[i].samples || 0;
				acc += (list[i].success_rate || 0) * s;
				samples += s;
			}
			var rate = (samples > 0) ? (acc / samples) : null;

			live.appendChild(common.iconCard(_('Success rate'), common.fmt.percent(rate, 1),
				_('Samples') + ': ' + samples, icons.successRing(rate, 64),
				rate == null ? '' : (rate >= 99 ? 'nm-c-ok' : (rate >= 95 ? 'nm-c-warn' : 'nm-c-bad'))));

			live.appendChild(common.iconCard(_('Abnormal'), String(o.offline || 0) + ' / ' + String(o.total || 0),
				_('Online') + ': ' + (o.online || 0), icons.bell(o.offline, 64),
				(o.offline > 0) ? 'nm-c-bad' : 'nm-c-ok'));

			live.appendChild(common.iconCard(_('Last check'), common.fmt.ago(d.tick),
				common.fmt.clock(d.tick), icons.clock(d.tick, 64)));

			live.appendChild(common.iconCard(_('Probe settings'),
				(cfgv.interval || 10) + 's / ' + (cfgv.timeout || 3) + 's',
				_('Interval') + ' / ' + _('Timeout'), icons.gear(64)));

			live.appendChild(common.iconCard(_('Data source'),
				(cfgv.persistence === '1') ? _('Persistent history') : _('In-memory ring buffer'),
				_('Retention') + ': ' + (cfgv.history || '24h'), icons.database(64)));

			var fam = cfgv.address_family || 'auto';
			var v6 = false;
			for (var j = 0; j < list.length; j++) {
				var h = String(list[j].host || '');
				if (list[j].family === 'ipv6' || h.indexOf(':') >= 0) v6 = true;
			}
			var v4 = (fam !== 'ipv6');
			if (fam === 'ipv6') v6 = true;
			live.appendChild(common.iconCard(_('Dual stack'),
				(v4 && v6) ? 'IPv4 + IPv6' : (v6 ? 'IPv6' : 'IPv4'),
				_('Address family') + ': ' + fam, icons.dualStack(fam, v4, v6, 64)));
		}

		function renderCards(d) {
			common.clear(cards);
			var list = d.targets || [];
			if (!list.length) {
				var e = common.el('div', 'nm-empty', _('No targets configured'));
				cards.appendChild(e);
				return;
			}
			for (var i = 0; i < list.length; i++)
				cards.appendChild(common.targetCard(list[i]));
		}

		function renderFoot(d) {
			common.clear(foot);
			var row = common.el('div', 'nm-row');
			row.appendChild(common.inlineIcon(icons.service(d.running, 30)));
			row.appendChild(common.el('div', '',
				(d.running ? _('Service running') : _('Service stopped')) +
				' · ' + _('Last update') + ': ' + common.fmt.ago(d.tick)));

			/* 柱状图高度取各目标当前延迟，是真实采样而非固定图像 */
			var bars = [];
			var tl = d.targets || [];
			for (var i = 0; i < tl.length && i < 4; i++)
				bars.push(tl[i].latency);
			var lb = common.el('div', 'nm-row');
			lb.appendChild(common.inlineIcon(icons.liveBars(bars, 34)));
			lb.appendChild(common.el('span', 'nm-card-sub', _('Live sampling')));
			row.appendChild(lb);

			row.appendChild(common.el('div', 'nm-spacer'));

			function btn(label, fn, cls) {
				var b = common.el('button', 'nm-btn nm-btn-sm ' + (cls || ''), label);
				b.addEventListener('click', function() {
					b.disabled = true;
					fn().then(function() {
						common.notify(_('Operation completed'));
						update();
					}).catch(function(e) {
						common.notify(String(e.message || e), 'error');
					}).then(function() { b.disabled = false; });
				});
				return b;
			}

			row.appendChild(btn(_('Start'), common.api.startService, 'nm-btn-primary'));
			row.appendChild(btn(_('Stop'), common.api.stopService));
			row.appendChild(btn(_('Restart'), common.api.restartService));
			foot.appendChild(row);
		}

		function apply(d) {
			renderHero(d);
			renderBanners(d);
			renderKpi(d);
			renderLive(d);
			renderCards(d);
			renderFoot(d);
		}

		function update() {
			return common.api.getStatus(true).then(apply).catch(function(e) {
				common.clear(cards);
				cards.appendChild(common.el('div', 'nm-empty', String(e.message || e)));
			});
		}

		if (first) apply(first);
		poll.add(update, refresh);

		return root;
	}
});
