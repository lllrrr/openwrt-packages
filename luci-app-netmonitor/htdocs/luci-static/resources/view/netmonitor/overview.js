/*
 * 总览页面：总体健康状态、关键指标、目标卡片
 *
 * 采用局部刷新（LuCI poll），不整页重载，不触发额外 Ping。
 * 界面由本项目自有样式承载（.nm-tcard / .nm-alert / .nm-btn），
 * 动态 SVG 徽章与实时声波柱用于表达实时状态。
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

		var hero = common.tcard('nm-hero-showcase');
		var bannerBox = common.el('div', 'nm-banner-box');
		var kpi = common.el('div', 'nm-grid');
		var live = common.el('div', 'nm-grid');
		var cards = common.el('div', 'nm-grid-wide');
		var foot = common.tcard('nm-footer-panel');

		page.appendChild(hero);
		page.appendChild(bannerBox);
		page.appendChild(kpi);
		page.appendChild(live);
		page.appendChild(cards);
		page.appendChild(foot);

		/* 阈值等级判定工具函数 */
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

		/* 动态 SVG 徽章生成器：多层雷达扩散 + 旋转光环 + 状态核心 */
		function buildHeroSvg(state) {
			var color = (state === 'good') ? 'var(--nm-ok, #10b981)' :
				(state === 'warning' ? 'var(--nm-warn, #f59e0b)' :
				(state === 'critical' ? 'var(--nm-bad, #ef4444)' : 'var(--nm-idle, #94a3b8)'));

			var iconPath = (state === 'good')
				? '<path d="M48 61.4l-8-8 2.8-2.8L48 55.8l13.2-13.2L64 45.4z" fill="white"/>'
				: ((state === 'warning')
					? '<path d="M52 41h-4v14h4V41zm0 18h-4v4h4v-4z" fill="white"/>'
					: '<path d="M58 48l-4-4-6 6-6-6-4 4 6 6-6 6 4 4 6-6 6 6 4-4-6-6 6-6z" fill="white"/>');

			var svgStr = `
			<svg width="104" height="104" viewBox="0 0 104 104" fill="none" xmlns="http://www.w3.org/2000/svg">
				<defs>
					<radialGradient id="nm-orb-glow" cx="50%" cy="50%" r="50%">
						<stop offset="0%" stop-color="${color}" stop-opacity="0.3" />
						<stop offset="100%" stop-color="${color}" stop-opacity="0" />
					</radialGradient>
					<linearGradient id="nm-orb-ring" x1="0%" y1="0%" x2="100%" y2="100%">
						<stop offset="0%" stop-color="${color}" stop-opacity="0.95" />
						<stop offset="55%" stop-color="${color}" stop-opacity="0.35" />
						<stop offset="100%" stop-color="${color}" stop-opacity="0.05" />
					</linearGradient>
					<linearGradient id="nm-orb-core" x1="0%" y1="0%" x2="100%" y2="100%">
						<stop offset="0%" stop-color="#34d399" />
						<stop offset="100%" stop-color="#059669" />
					</linearGradient>
				</defs>
				<circle cx="52" cy="52" r="48" fill="url(#nm-orb-glow)" />
				<circle class="nm-svg-radar-1" cx="52" cy="52" r="46" stroke="${color}" stroke-opacity="0.3" stroke-width="1.6" />
				<circle class="nm-svg-radar-2" cx="52" cy="52" r="39" stroke="${color}" stroke-opacity="0.55" stroke-width="1.8" />
				<circle class="nm-svg-rotate-dash" cx="52" cy="52" r="30" stroke="url(#nm-orb-ring)" stroke-width="2.4" stroke-dasharray="10 9" stroke-linecap="round" />
				<circle class="nm-svg-rotate-dash-rev" cx="52" cy="52" r="23" stroke="${color}" stroke-opacity="0.4" stroke-width="1.4" stroke-dasharray="3 11" stroke-linecap="round" />
				<circle cx="52" cy="52" r="19" fill="url(#nm-orb-core)" style="filter: drop-shadow(0 3px 8px ${color}55);" />
				${iconPath}
			</svg>`;

			var div = document.createElement('div');
			div.className = 'nm-hero-orb-wrap';
			div.innerHTML = svgStr;
			return div;
		}

		/* 动态 SVG 实时采样声波柱 */
		function buildLiveBarsSvg(bars) {
			var b1 = Math.min(22, Math.max(5, (bars[0] || 15) / 5));
			var b2 = Math.min(22, Math.max(5, (bars[1] || 35) / 5));
			var b3 = Math.min(22, Math.max(5, (bars[2] || 25) / 5));
			var b4 = Math.min(22, Math.max(5, (bars[3] || 45) / 5));
			var b5 = Math.min(22, Math.max(5, (bars[4] || 18) / 5));

			return `
			<svg width="44" height="28" viewBox="0 0 44 28" fill="none" xmlns="http://www.w3.org/2000/svg">
				<defs>
					<linearGradient id="nm-bar-grad" x1="0%" y1="100%" x2="0%" y2="0%">
						<stop offset="0%" stop-color="#2563eb" stop-opacity="0.5" />
						<stop offset="100%" stop-color="#60a5fa" />
					</linearGradient>
				</defs>
				<rect class="nm-bar-dyn-1" x="2" y="${28 - b1}" width="4.5" height="${b1}" rx="2.2" fill="url(#nm-bar-grad)" />
				<rect class="nm-bar-dyn-2" x="11" y="${28 - b2}" width="4.5" height="${b2}" rx="2.2" fill="url(#nm-bar-grad)" />
				<rect class="nm-bar-dyn-3" x="20" y="${28 - b3}" width="4.5" height="${b3}" rx="2.2" fill="url(#nm-bar-grad)" />
				<rect class="nm-bar-dyn-4" x="29" y="${28 - b4}" width="4.5" height="${b4}" rx="2.2" fill="url(#nm-bar-grad)" />
				<rect class="nm-bar-dyn-5" x="38" y="${28 - b5}" width="4.5" height="${b5}" rx="2.2" fill="url(#nm-bar-grad)" />
			</svg>`;
		}

		function renderHero(d) {
			common.clear(hero);

			var state = 'unknown';
			if (d.health === 'good') state = 'good';
			else if (d.health === 'warning') state = 'warning';
			else if (d.health === 'critical') state = 'critical';

			hero.appendChild(buildHeroSvg(state));

			var main = common.el('div', 'nm-hero-main');
			var title = _('No monitoring data');
			var desc = _('Add and enable monitoring targets to start collecting data.');

			if (state === 'good') {
				title = _('Network is healthy');
				desc = _('All monitored targets respond normally.');
			} else if (state === 'warning') {
				title = _('Network problems detected');
				desc = _('Some targets are unreachable or unstable. Check detailed target cards below.');
			} else if (state === 'critical') {
				title = _('Serious network failure');
				desc = _('One or more targets failed consecutively beyond the threshold limit.');
			}

			main.appendChild(common.el('h3', 'nm-hero-title', title));
			main.appendChild(common.el('div', 'nm-hero-desc', desc));

			var o = d.overall || {};
			var stats = common.el('div', 'nm-hero-stats-row');
			function stat(v, label) {
				var s = common.el('div', 'nm-stat-badge');
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
			function alertMsg(msg, kind) {
				bannerBox.appendChild(common.ui.alert({ text: msg, kind: kind }));
			}
			if (!d.running) {
				alertMsg(_('Background service is not running. Monitoring is stopped.'), 'warning');
			} else if (d.stale) {
				alertMsg(_('Background service did not update data recently. Check the service status.'), 'warning');
			}
			if (d.overall && d.overall.total === 0) {
				alertMsg(_('No enabled targets. Go to Targets to add one.'), 'info');
			}
		}

		/* TDesign 卡片封装：外层 .nm-tcard，内容沿用 .nm-card-inner 排版 */
		function makeGlassCard(title, val, subText, svgIcon) {
			var card = common.tcard();
			var inner = common.el('div', 'nm-card-inner');

			var head = common.el('div', 'nm-card-header');
			head.appendChild(common.el('span', 'nm-card-label', title));

			if (svgIcon) {
				var iconWrap = common.el('div', 'nm-card-icon-box');
				if (typeof svgIcon === 'string') iconWrap.innerHTML = svgIcon;
				else iconWrap.appendChild(svgIcon);
				head.appendChild(iconWrap);
			}

			inner.appendChild(head);
			inner.appendChild(common.el('div', 'nm-card-number', val));
			if (subText) inner.appendChild(common.el('div', 'nm-card-description', subText));

			card.appendChild(inner);
			return card;
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
				var subHtml = _('Weighted loss') + ' · ' + _('Samples') + ': ' + (x.loss_samples || 0) + '<br>' +
					_('Online') + ' ' + (x.online || 0) + ' / ' + (x.total || 0) + ' · ' +
					_('Avg') + ' ' + common.fmt.latency(x.avg) + ' ms · ' +
					_('P95') + ' ' + common.fmt.latency(x.p95) + ' ms';
				if (x.loss_lost > 0)
					subHtml += '<br>' + _('Lost packets') + ': ' + x.loss_lost;

				var c = makeGlassCard(title, common.fmt.percent(x.loss, 1), '', svg);
				var subDesc = common.el('div', 'nm-card-description');
				subDesc.innerHTML = subHtml;
				c.querySelector('.nm-card-inner').appendChild(subDesc);
				return c;
			}

			var curGrade = gradeOf(o.current, th);

			kpi.appendChild(makeGlassCard(_('Average latency'), common.fmt.latency(o.avg) + ' ms',
				_('Across enabled targets'), icons.trend(44)));
			kpi.appendChild(makeGlassCard(_('Current latency'), common.fmt.latency(o.current) + ' ms',
				_('Latest probe round'), icons.latencyDial(o.current, curGrade, 44)));

			var lossSub = _('Weighted by samples') + ': ' + (o.loss_samples || 0) + ' · ' +
				_('Unweighted') + ' ' + common.fmt.percent(o.loss_avg, 1);
			if (o.loss_lost > 0)
				lossSub += ' · ' + _('Lost packets') + ': ' + o.loss_lost;

			kpi.appendChild(makeGlassCard(_('Packet loss'), common.fmt.percent(o.loss, 1), lossSub, icons.packetLoss(o.loss, 44)));
			kpi.appendChild(regionCard(_('China network'), cn, icons.regionCN(44, cn, cn.avg)));
			kpi.appendChild(regionCard(_('Overseas network'), ov, icons.regionGlobal(44, ov, ov.avg)));
			kpi.appendChild(makeGlassCard(_('Online targets'), String(o.online || 0),
				_('Abnormal') + ': ' + (o.offline || 0), icons.multiTarget(list, 44)));
		}

		function renderLive(d) {
			common.clear(live);
			var o = d.overall || {};
			var list = d.targets || [];
			var cfgv = cfg || {};

			var acc = 0, samples = 0;
			for (var i = 0; i < list.length; i++) {
				if (!list[i].enabled) continue;
				var s = list[i].samples || 0;
				acc += (list[i].success_rate || 0) * s;
				samples += s;
			}
			var rate = (samples > 0) ? (acc / samples) : null;

			live.appendChild(makeGlassCard(_('Success rate'), common.fmt.percent(rate, 1),
				_('Samples') + ': ' + samples, icons.successRing(rate, 44)));

			live.appendChild(makeGlassCard(_('Abnormal'), String(o.offline || 0) + ' / ' + String(o.total || 0),
				_('Online') + ': ' + (o.online || 0), icons.bell(o.offline, 44)));

			live.appendChild(makeGlassCard(_('Last check'), common.fmt.ago(d.tick),
				common.fmt.clock(d.tick), icons.clock(d.tick, 44)));

			live.appendChild(makeGlassCard(_('Probe settings'),
				(cfgv.interval || 10) + 's / ' + (cfgv.timeout || 3) + 's',
				_('Interval') + ' / ' + _('Timeout'), icons.gear(44)));

			live.appendChild(makeGlassCard(_('Data source'),
				(cfgv.persistence === '1') ? _('Persistent history') : _('In-memory ring buffer'),
				_('Retention') + ': ' + (cfgv.history || '24h'), icons.database(44)));

			var fam = cfgv.address_family || 'auto';
			var v6 = false;
			for (var j = 0; j < list.length; j++) {
				var h = String(list[j].host || '');
				if (list[j].family === 'ipv6' || h.indexOf(':') >= 0) v6 = true;
			}
			var v4 = (fam !== 'ipv6');
			if (fam === 'ipv6') v6 = true;
			live.appendChild(makeGlassCard(_('Dual stack'),
				(v4 && v6) ? 'IPv4 + IPv6' : (v6 ? 'IPv6' : 'IPv4'),
				_('Address family') + ': ' + fam, icons.dualStack(fam, v4, v6, 44)));
		}

		function renderCards(d) {
			common.clear(cards);
			var list = d.targets || [];
			if (!list.length) {
				var e = common.el('div', 'nm-empty', _('No targets configured'));
				e.style.padding = '36px';
				e.style.textAlign = 'center';
				cards.appendChild(e);
				return;
			}
			for (var i = 0; i < list.length; i++) {
				var tc = common.targetCard(list[i]);
				cards.appendChild(tc);
			}
		}

		function renderFoot(d) {
			common.clear(foot);
			var row = common.el('div', 'nm-row');
			row.style.display = 'flex';
			row.style.alignItems = 'center';
			row.style.gap = '14px';
			row.style.flex = '1';

			row.appendChild(common.inlineIcon(icons.service(d.running, 30)));
			row.appendChild(common.el('div', '',
				(d.running ? _('Service running') : _('Service stopped')) +
				' · ' + _('Last update') + ': ' + common.fmt.ago(d.tick)));

			/* 动态 SVG 均衡柱图 */
			var bars = [];
			var tl = d.targets || [];
			for (var i = 0; i < tl.length && i < 5; i++)
				bars.push(tl[i].latency);

			var lb = common.el('div', 'nm-row');
			lb.style.display = 'flex';
			lb.style.alignItems = 'center';
			lb.style.gap = '10px';
			lb.style.marginLeft = '20px';

			var liveBarsHolder = common.el('div', '');
			liveBarsHolder.innerHTML = buildLiveBarsSvg(bars);
			lb.appendChild(liveBarsHolder);
			lb.appendChild(common.el('span', 'nm-card-description', _('Live sampling')));
			row.appendChild(lb);

			foot.appendChild(row);

			var actRow = common.el('div', 'nm-row');
			actRow.style.display = 'flex';
			actRow.style.gap = '10px';

			/* 服务控制按钮：按当前运行态禁用无意义的操作 ——
			 * 服务已在运行时「启动」无事可做，已停止时「停止」同理。
			 * 保留 Restart 始终可用（两种状态下都有意义）。
			 * 每次 renderFoot 重绘时重新计算，因此状态变化后按钮态
			 * 会自动跟上，不需要额外的状态同步代码。 */
			function btn(label, fn, isPrimary, disabled) {
				return common.ui.button({
					label: label,
					theme: isPrimary ? 'primary' : 'default',
					disabled: disabled,
					onClick: function () {
						return fn().then(function () {
							common.notify(_('Operation completed'));
							update();
						});
					}
				});
			}

			actRow.appendChild(btn(_('Start'), common.api.startService, true, d.running));
			actRow.appendChild(btn(_('Stop'), common.api.stopService, false, !d.running));
			actRow.appendChild(btn(_('Restart'), common.api.restartService, false, false));
			foot.appendChild(actRow);
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
				var err = common.el('div', 'nm-empty', String(e.message || e));
				err.style.padding = '24px';
				cards.appendChild(err);
			});
		}

		if (first) apply(first);
		poll.add(update, refresh);

		return root;
	}
});
