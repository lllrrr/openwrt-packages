'use strict';
'require view';
'require rpc';
'require ui';
'require poll';

'require languard.common as common';

var STYLE = common.STYLE;
var fmtBytes = common.fmtBytes, fmtGeo = common.fmtGeo, fmtTime = common.fmtTime;
var appChip = common.appChip, appHue = common.appHue, catMeta = common.catMeta;
var typeLabel = common.typeLabel;

// 应用筛选状态。common.js 里也有一份同名变量供 appChip 使用,
// 严格模式下给未声明的标识符赋值会抛 ReferenceError。
var APP_FILTER = null;
var APP_CHIP_CLICK = null;

// RPC 声明全部来自 common.js
var callList = common.callList;
var callBlock = common.callBlock;
var callUnblock = common.callUnblock;
var callUnblockAll = common.callUnblockAll;
var callIpList = common.callIpList;
var callSync = common.callSync;
var callAppList = common.callAppList;
var callAppStats = common.callAppStats;
var callBlockAudit = common.callBlockAudit;
var callFix = common.callFix;
var callAppImport = common.callAppImport;
var callAppDel = common.callAppDel;
var callSigList = common.callSigList;
var callDomainHits = common.callDomainHits;
var callDomainLog = common.callDomainLog;
var callSigAdd = common.callSigAdd;
var callSigDel = common.callSigDel;
var callAppReset = common.callAppReset;
var callSampleStart = common.callSampleStart;
var callSampleStop = common.callSampleStop;
var callSampleResult = common.callSampleResult;
var callSampleSave = common.callSampleSave;
var callQosList = common.callQosList;
var callQosAdd = common.callQosAdd;
var callQosDel = common.callQosDel;
var callDevMerge = common.callDevMerge;
var callDevUnmerge = common.callDevUnmerge;
var callDomainList = common.callDomainList;
var callDomainAdd = common.callDomainAdd;
var callDomainDel = common.callDomainDel;
var callDomainToggle = common.callDomainToggle;
var callProxyList = common.callProxyList;
var callProxyAdd = common.callProxyAdd;
var callProxyDel = common.callProxyDel;
var callIpAdd = common.callIpAdd;
var callIpDel = common.callIpDel;
var callDashboard = common.callDashboard;
var callTrend = common.callTrend;
var callPanicState = common.callPanicState;
var callPanic = common.callPanic;
var callKnownAdd = common.callKnownAdd;
var callKnownList = common.callKnownList;
var callWlList = common.callWlList;
var callWlAdd = common.callWlAdd;
var callWlDel = common.callWlDel;
var callFeedList = common.callFeedList;
var callFeedAdd = common.callFeedAdd;
var callFeedSet = common.callFeedSet;
var callFeedDel = common.callFeedDel;
var callFeedRefresh = common.callFeedRefresh;
var callPortPresets = common.callPortPresets;
var callPortTemplate = common.callPortTemplate;
var callExport = common.callExport;
var callExportFile = common.callExportFile;
var callImportFile = common.callImportFile;
var callImport = common.callImport;
var callGroupList = common.callGroupList;
var callGroupAdd = common.callGroupAdd;
var callGroupDel = common.callGroupDel;
var callGroupSet = common.callGroupSet;
var callCurfew = common.callCurfew;
var callPortList = common.callPortList;
var callPortAdd = common.callPortAdd;
var callPortDel = common.callPortDel;
var callNotifyGet = common.callNotifyGet;
var callNotifyAdd = common.callNotifyAdd;
var callNotifyDel = common.callNotifyDel;
var callNotifyToggle = common.callNotifyToggle;
var callNotifyEvents = common.callNotifyEvents;
var callNotifyTest = common.callNotifyTest;
var callSchedList = common.callSchedList;
var callSchedAdd = common.callSchedAdd;
var callSchedDel = common.callSchedDel;
var callSchedToggle = common.callSchedToggle;
var callSelfCheck = common.callSelfCheck;
var callLogList = common.callLogList;
var callLogClear = common.callLogClear;
var callAutoGet = common.callAutoGet;
var callAutoSet = common.callAutoSet;
var callScan = common.callScan;
var callIpFlush = common.callIpFlush;
var callRename = common.callRename;

return view.extend({
	load: function () {
		// Nothing is fetched here. The shell paints immediately and each
		// section fills itself as its own call returns, so a slow iplist
		// (100 KB+ once a subscription is loaded) no longer blocks the page.
		return Promise.resolve({});
	},

	handleBlock: function (dev, ev) {
		var btn = ev.currentTarget;
		btn.disabled = true;
		btn.textContent = _('Blocking…');
		return callBlock(dev.mac, dev.host || '', dev.ip || '').then(function (res) {
			if (!res || res.success === false)
				throw new Error((res && res.error) || _('Failed'));
			ui.addNotification(null, E('p', {}, _('Blocked') + ' ' + (dev.host || dev.mac)), 'info');
			return this.refresh();
		}.bind(this)).catch(function (e) {
			ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error');
			return this.refresh();
		}.bind(this));
	},

	handleUnblock: function (dev, ev) {
		var btn = ev.currentTarget;
		btn.disabled = true;
		btn.textContent = _('Unblocking…');
		return callUnblock(dev.mac).then(function (res) {
			if (!res || res.success === false)
				throw new Error((res && res.error) || _('Failed'));
			ui.addNotification(null, E('p', {}, _('Unblocked') + ' ' + (dev.host || dev.mac)), 'info');
			return this.refresh();
		}.bind(this)).catch(function (e) {
			ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error');
			return this.refresh();
		}.bind(this));
	},

	handleUnblockAll: function (ev) {
		if (!confirm(_('Unblock all devices?')))
			return;
		var btn = ev.currentTarget;
		btn.disabled = true;
		return callUnblockAll('yes').then(function () {
			ui.addNotification(null, E('p', {}, _('All devices unblocked')), 'info');
			return this.refresh();
		}.bind(this)).catch(function (e) {
			ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error');
			return this.refresh();
		}.bind(this));
	},

	handleRename: function (dev) {
		var self = this;
		var name = prompt(_('Device name'), dev.host || '');
		if (name === null) return;
		return callRename(dev.mac, name).then(function (res) {
			if (res && res.success === false)
				throw new Error(res.error || _('Failed'));
			return self.refresh();
		}).catch(function (e) {
			ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error');
			return self.refresh();
		});
	},

	handleProbe: function (ev) {
		var btn = ev.currentTarget;
		btn.disabled = true;
		btn.textContent = _('Scanning…');
		return callList('1').then(function (res) {
			this.devices = (res && res.devices) || [];
			this.blockedCount = (res && res.blocked_count) || 0;
			this.renderTable();
		}.bind(this)).catch(function (e) {
			ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error');
		}).finally(function () {
			btn.disabled = false;
			btn.textContent = _('Rescan devices');
		});
	},

	refresh: function () {
		var self = this;
		return callList('1').then(function (res) {
			self.devices = (res && res.devices) || [];
			self.blockedCount = (res && res.blocked_count) || 0;
			self.renderTable();
		}).catch(common.fail).then(function () {
			self.renderTable();
		});
	},

	filterRows: function () {
		var q = (this.query || '').toLowerCase().trim();
		if (!q) return this.devices;
		return this.devices.filter(function (d) {
			return (d.host || '').toLowerCase().indexOf(q) !== -1 ||
				(d.ip || '').indexOf(q) !== -1 ||
				(d.mac || '').toLowerCase().indexOf(q) !== -1;
		});
	},

	refreshNotify: function () {
		var self = this;
		return callNotifyGet().then(function (res) {
			self.notify = res || {};
			self.renderNotify();
		}).catch(function () { self.renderNotify(); });
	},

	handleNotifyAdd: function (ev) {
		var self = this;
		var g = function (id) { var e = document.getElementById(id); return e ? e.value : ''; };
		var type = g('cb-nt-type');
		var btn = ev.currentTarget;
		btn.disabled = true;
		return callNotifyAdd(type, g('cb-nt-name'), g('cb-nt-url'), g('cb-nt-token'), g('cb-nt-chat'))
			.then(function (res) {
				if (res && res.success === false) throw new Error(res.error || _('Failed'));
				return self.refreshNotify();
			}).catch(function (e) {
				ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error');
			}).finally(function () { btn.disabled = false; });
	},

	handleNotifyDel: function (id, ev) {
		var self = this;
		ev.currentTarget.disabled = true;
		return callNotifyDel(id).then(function () { return self.refreshNotify(); })
			.catch(function (e) { ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error'); });
	},

	handleNotifyToggle: function (ch, ev) {
		var self = this;
		return callNotifyToggle(ch.id, ch.enabled ? '0' : '1')
			.then(function () { return self.refreshNotify(); });
	},

	handleNotifyTest: function (ch, ev) {
		var self = this;
		var btn = ev.currentTarget;
		btn.disabled = true;
		return callNotifyTest(ch.id).then(function (res) {
			if (res && res.success === false) throw new Error(res.error || _('Send failed'));
			ui.addNotification(null, E('p', {}, _('Test message sent')), 'info');
		}).catch(function (e) {
			ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error');
		}).finally(function () { btn.disabled = false; });
	},

	handleNotifyEvents: function (ev) {
		var self = this;
		var picked = [];
		document.querySelectorAll('#cb-nt-events .cb-dchip.on').forEach(function (d) {
			picked.push(d.getAttribute('data-event'));
		});
		return callNotifyEvents(picked.join(',')).then(function () {
			ui.addNotification(null, E('p', {}, _('Saved')), 'info');
			return self.refreshNotify();
		}).catch(function (e) {
			ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error');
		});
	},

	renderNotify: function () {
		var tbody = document.getElementById('cb-nt-tbody');
		if (!tbody) return;
		while (tbody.firstChild) tbody.removeChild(tbody.firstChild);

		var self = this;
		var n = this.notify || {};
		var list = n.channels || [];

		if (!list.length) {
			tbody.appendChild(E('tr', {}, E('td', { 'colspan': 4, 'class': 'cb-empty' },
				_('No notification channels yet'))));
		}

		list.forEach(function (c) {
			var target = c.type === 'telegram'
				? ('chat ' + (c.chat || '?'))
				: (c.url || '');
			tbody.appendChild(E('tr', {}, [
				E('td', {}, E('span', { 'class': 'cb-res ' + (c.enabled ? 'cb-health-ok' : 'cb-sched-idle') },
					c.type)),
				E('td', { 'class': 'cb-u' }, c.name || ''),
				E('td', { 'class': 'cb-val', 'style': 'font-size:.78rem;color:var(--text-muted)' },
					String(target).slice(0, 48)),
				E('td', { 'style': 'text-align:right;white-space:nowrap' }, [
					E('button', { 'class': 'cb-btn', 'style': 'margin-right:.3rem',
						'click': function (ev) { self.handleNotifyTest(c, ev); } }, _('Test')),
					E('button', { 'class': 'cb-btn', 'style': 'margin-right:.3rem',
						'click': function (ev) { self.handleNotifyToggle(c, ev); } },
						c.enabled ? _('Pause') : _('Resume')),
					E('button', { 'class': 'cb-btn cb-btn-danger',
						'click': function (ev) { self.handleNotifyDel(c.id, ev); } }, _('Delete'))
				])
			]));
		});

		// event chips
		var evBox = document.getElementById('cb-nt-events');
		if (evBox) {
			while (evBox.firstChild) evBox.removeChild(evBox.firstChild);
			var labels = { auto_block: _('Auto block'), new_device: _('New device'), expire: _('Block expired') };
			(n.event_names || []).forEach(function (e) {
				var on = n.events && n.events[e];
				evBox.appendChild(E('div', { 'class': 'cb-dchip' + (on ? ' on' : ''), 'data-event': e,
					'style': 'width:auto;padding:0 .6rem',
					'click': function (ev) { ev.currentTarget.classList.toggle('on'); } }, labels[e] || e));
			});
		}
	},

	refreshDash: function () {
		var self = this;
		return Promise.all([ callDashboard(), callTrend() ]).then(function (r) {
			self.dash = r[0] || {};
			self.trend = r[1] || {};
			self.renderDash();
		}).catch(function () { self.renderDash(); });
	},

	renderDash: function () {
		var box = document.getElementById('cb-dash-body');
		if (!box) return;
		while (box.firstChild) box.removeChild(box.firstChild);

		if (!this.dash) {
			// still loading: keep the layout stable instead of flashing dashes
			box.appendChild(E('div', { 'class': 'cb-stats' },
				[ 0, 1, 2, 3, 4, 5 ].map(function () {
					return E('div', { 'class': 'cb-stat cb-skel' }, [
						E('div', { 'class': 'cb-skel-line', 'style': 'width:45%;height:1.3rem' }),
						E('div', { 'class': 'cb-skel-line', 'style': 'width:70%;margin-top:.35rem' })
					]);
				})));
			return;
		}

		var d = this.dash || {};
		var self = this;
		function card(n, label, cls) {
			return E('div', { 'class': 'cb-stat' + (cls ? ' ' + cls : '') }, [
				E('div', { 'class': 'cb-n' }, String(n == null ? '-' : n)),
				E('div', { 'class': 'cb-l' }, label)
			]);
		}
		function row(k, v) {
			return E('div', { 'class': 'cb-dash-row' }, [
				E('span', { 'class': 'cb-k' }, k),
				E('span', { 'class': 'cb-v' }, String(v))
			]);
		}

		box.appendChild(E('div', { 'class': 'cb-stats' }, [
			card(d.devices_online, _('Devices online'), 'ok'),
			card(d.devices_blocked, _('Devices blocked'), d.devices_blocked ? 'warn' : ''),
			card(d.ips_blocked, _('Blocked IPs'), d.ips_blocked ? 'accent' : ''),
			card(d.logins_fail_today, _('Login failures today'), d.logins_fail_today ? 'warn' : '')
		]));

		if (d.arp_recent && d.arp_recent.length) {
			box.appendChild(E('div', { 'class': 'cb-card' }, [
				E('div', { 'class': 'cb-card-head' }, [
					E('span', { 'class': 'cb-dot', 'style': 'background:var(--danger)' }),
					E('span', {}, _('MAC conflicts'))
				]),
				E('div', { 'class': 'cb-card-body' }, E('div', { 'class': 'cb-dash-rows' },
					d.arp_recent.slice(-6).reverse().map(function (ev) {
						return E('div', { 'class': 'cb-dash-row' }, [
							E('span', { 'class': 'cb-k' }, (ev.severity === 'gateway'
								? _('gateway') : _('conflict')) + ' · ' + fmtTime(ev.ts)),
							E('span', { 'class': 'cb-v', 'style': 'color:var(--danger)' },
								ev.ip + '  ' + ev.was + ' → ' + ev.now)
						]);
					})))
			]));
		}

		box.appendChild(E('div', { 'class': 'cb-card' }, [
			E('div', { 'class': 'cb-card-head' }, [
				E('span', { 'class': 'cb-dot' }), E('span', {}, _('Login failures, last 24 hours'))
			]),
			E('div', { 'class': 'cb-card-body' }, [
				E('div', { 'class': 'cb-trend', 'id': 'cb-trend' }),
				E('div', { 'class': 'cb-trend-legend' }, [
					E('span', {}, '-24h'),
					E('span', {}, _('now'))
				])
			])
		]));

		box.appendChild(E('div', { 'class': 'cb-card' }, [
			E('div', { 'class': 'cb-card-head' }, [
				E('span', { 'class': 'cb-dot', 'style': d.panic_on ? 'background:var(--danger)' : null }),
				E('span', {}, _('Protection')),
				d.panic_on
					? E('span', { 'class': 'cb-src cb-src-panic', 'style': 'margin-left:auto' },
						_('blocking new devices only'))
					: ''
			]),
			E('div', { 'class': 'cb-card-body' }, E('div', { 'class': 'cb-dash-rows' }, [
				row(_('Automatic protection'), d.auto_enabled
					? (_('on') + ' · ' + (d.threshold || '-') + ' / ' + (d.window || '-') + 's')
					: _('off')),
				row(_('Blocked addresses from auto-block'), (d.ips_auto || 0)),
				row(_('Schedule rules'), (d.schedules || 0) + ' (' + (d.schedules_active || 0) + ' ' + _('active now') + ')'),
				row(_('Trusted devices'), d.trusted || 0),
				row(_('New devices awaiting review'), d.pending || 0),
				row(_('MAC changes, last 24 hours'),
					(d.arp_24h || 0) + (d.arp_24h ? '' : '')),
				row(_('Groups'), d.groups || 0),
				row(_('Port restrictions'), d.ports || 0),
				row(_('Notification channels'), d.channels || 0),
				row(_('Logins today'), (d.logins_ok_today || 0) + ' ' + _('ok') + ' · ' + (d.logins_fail_today || 0) + ' ' + _('failed')),
				row(_('Failures in last 24h'), d.logins_fail_24h || 0),
				E('div', { 'class': 'cb-dash-row' }, [
					E('span', { 'class': 'cb-k' }, _('Current mode')),
					E('span', {
						'class': 'cb-v',
						'style': d.panic_on ? 'color:var(--danger)' : 'color:var(--success)'
					}, d.panic_on
						? _('blocking new devices only') +
						  (d.panic_since ? ' · ' + _('since') + ' ' + fmtTime(d.panic_since) : '')
						: _('normal'))
				]),
				E('div', { 'class': 'cb-actions', 'style': 'margin-top:.8rem' }, [
					d.panic_on
						? E('button', { 'class': 'cb-btn cb-btn-primary',
							'click': function (ev) { self.handlePanic(false, ev); } }, _('Back to normal'))
						: E('button', { 'class': 'cb-btn cb-btn-danger',
							'click': function (ev) { self.handlePanic(true, ev); } }, _('Block new devices only'))
				])
			]))
		]));

		var healthCard = E('div', { 'class': 'cb-card cb-card-hero' }, [
			E('div', { 'class': 'cb-card-head' }, [
				E('span', { 'class': 'cb-dot' }), E('span', {}, _('Health'))
			]),
			E('div', { 'class': 'cb-card-body' }, (function () {
				var wrap = E('div', {});
				// tab 红点跟着健康状态走,不用点进设置页才知道有问题
				(self._alertTabs || []).forEach(function (pair) {
					if (!d.health_ok) pair[1].setAttribute('data-alert', '1');
					else pair[1].removeAttribute('data-alert');
				});
				wrap.appendChild(E('span', { 'class': 'cb-res ' + (d.health_ok ? 'cb-health-ok' : 'cb-health-bad') },
					d.health_ok ? _('all checks passed') : _('attention needed')));
				if (!d.health_ok && (d.health_failing || []).length) {
					var list = E('div', { 'class': 'cb-fail-list' });
					// 每一项失败都给一个能直接点的恢复动作,不必再切到健康页
					var FIXABLE = { nftset: 1, rulesfile: 1, nfthook: 1,
					                watcher: 1, appstats: 1, logread: 1, luci_realip: 1 };
					d.health_failing.forEach(function (c) {
						list.appendChild(E('div', { 'class': 'cb-fail-item' }, [
							E('span', {}, '✕ ' + (c.detail || c.id)),
							FIXABLE[c.id]
								? E('button', {
									'class': 'cb-btn cb-btn-primary',
									'style': 'font-size:.72rem;padding:.05rem .5rem;margin-left:.5rem;white-space:nowrap',
									'click': function (ev) { self.handleFix(ev, c.id); }
								}, _('Fix'))
								: ''
						]));
					});
					wrap.appendChild(list);
				}
				wrap.appendChild(E('div', { 'class': 'cb-actions', 'style': 'margin-top:.7rem' }, [
					E('button', { 'class': 'cb-btn cb-btn-primary',
						'click': function (ev) { self.refreshDash(); } }, _('Refresh')),
					!d.health_ok ? E('button', { 'class': 'cb-btn',
						'click': function (ev) { self.handleSync(ev); } }, _('Sync to kernel')) : ''
				]));
				return wrap;
			})())
		]);
		box.appendChild(healthCard);

		if ((d.recent || []).length) {
			var rl = E('div', { 'class': 'cb-dash-rows' });
			d.recent.forEach(function (e) {
				var label = e.result === 'success' ? _('login ok')
					: (e.result === 'failure' ? _('login failed') : _('session closed'));
				rl.appendChild(E('div', { 'class': 'cb-dash-row' }, [
					E('span', { 'class': 'cb-k' }, fmtTime(e.ts)),
					E('span', { 'class': 'cb-v' }, (e.kind || '') + ' · ' + label)
				]));
			});
			box.appendChild(E('div', { 'class': 'cb-card' }, [
				E('div', { 'class': 'cb-card-head' }, [
					E('span', { 'class': 'cb-dot' }), E('span', {}, _('Recent activity'))
				]),
				E('div', { 'class': 'cb-card-body' }, rl)
			]));
		}

		// the chart markup is rebuilt above, so paint it now
		self.renderTrend();
	},

	refreshFeeds: function () {
		var self = this;
		return callFeedList().then(function (res) {
			self.feeds = (res && res.feeds) || [];
			self.renderFeeds();
		}).catch(function () { self.renderFeeds(); });
	},

	// The browser sends the file straight to a small CGI, which writes it to
	// /tmp; the feed then points at that path with file://, so nothing has to
	// be served over the network or typed by hand.
	handleFeedUpload: function (ev) {
		var self = this;
		var input = document.getElementById('cb-feed-file');
		var f = input && input.files && input.files[0];
		if (!f) { ui.addNotification(null, E('p', {}, _('Pick a file first')), 'warning'); return; }
		var kind = (document.getElementById('cb-feed-kind') || {}).value || 'ip';
		var name = (document.getElementById('cb-feed-name') || {}).value || f.name;
		var btn = ev.currentTarget;
		btn.disabled = true;
		return fetch('/cgi-bin/lg-upload?name=' + encodeURIComponent(f.name), {
			method: 'POST', body: f, credentials: 'same-origin'
		}).then(function (r) { return r.json(); }).then(function (res) {
			if (!res || !res.path) throw new Error(_('Upload failed'));
			return callFeedAdd(name, 'file://' + res.path, '', kind, '');
		}).then(function (res) {
			if (res && res.success === false) throw new Error(res.error || _('Failed'));
			input.value = '';
			return self.refreshFeeds();
		}).catch(function (e) {
			ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error');
		}).finally(function () { btn.disabled = false; });
	},

	handleFeedAdd: function (ev) {
		var self = this;
		var n = (document.getElementById('cb-feed-name') || {}).value || '';
		var u = (document.getElementById('cb-feed-url') || {}).value || '';
		var k = (document.getElementById('cb-feed-kind') || {}).value || 'ip';
		if (!u) { ui.addNotification(null, E('p', {}, _('List URL is required')), 'warning'); return; }
		var btn = ev.currentTarget; btn.disabled = true;
		return callFeedAdd(n, u, '', k, '').then(function (res) {
			if (res && res.success === false) throw new Error(res.error || _('Failed'));
			document.getElementById('cb-feed-url').value = '';
			return self.refreshFeeds();
		}).catch(function (e) {
			ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error');
		}).finally(function () { btn.disabled = false; });
	},

	handleFeedRefresh: function (f, ev) {
		var self = this;
		var btn = ev.currentTarget;
		btn.disabled = true; btn.textContent = _('Fetching…');
		return callFeedRefresh(f.id).then(function (res) {
			if (res && res.success === false) throw new Error(res.error || _('Failed'));
			ui.addNotification(null, E('p', {}, _('Imported') + ' ' + (res.added || 0) + ', ' + _('removed') + ' ' + (res.removed || 0)), 'info');
			return Promise.all([ self.refreshFeeds(), self.refreshIps() ]);
		}).catch(function (e) {
			ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error');
		}).finally(function () { btn.disabled = false; btn.textContent = _('Fetch'); });
	},

	handleFeedDel: function (f, ev) {
		var self = this;
		ev.currentTarget.disabled = true;
		return callFeedDel(f.id).then(function () { return Promise.all([ self.refreshFeeds(), self.refreshIps() ]); })
			.catch(function (e) { ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error'); });
	},

	renderFeeds: function () {
		var tbody = document.getElementById('cb-feed-tbody');
		if (!tbody) return;
		while (tbody.firstChild) tbody.removeChild(tbody.firstChild);
		var self = this;
		var list = this.feeds || [];
		if (!list.length) {
			tbody.appendChild(E('tr', {}, E('td', { 'colspan': 7, 'class': 'cb-empty' },
				_('No subscriptions yet'))));
			return;
		}
		var INTERVALS = [
			{ v: 0,      l: _('manual') },
			{ v: 3600,   l: _('hourly') },
			{ v: 21600,  l: _('every 6 hours') },
			{ v: 86400,  l: _('daily') },
			{ v: 604800, l: _('weekly') }
		];

		list.forEach(function (f) {
			var cur = Number(f.interval) || 0;
			var sel = E('select', {
				'class': 'cb-sel',
				'change': function (ev) {
					var v = ev.target.value;
					callFeedSet(f.id, v).then(function () { self.renderFeeds(); })
						.catch(function (e) {
							ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error');
						});
				}
			}, INTERVALS.map(function (o) {
				return E('option', { 'value': o.v, 'selected': cur === o.v ? 'selected' : null }, o.l);
			}));

			tbody.appendChild(E('tr', {}, [
				E('td', { 'class': 'cb-u' }, [
					f.name || '',
					f.last_error
						? E('div', { 'class': 'cb-drop', 'title': f.last_error, 'style': 'color:var(--danger)' },
							_('last fetch failed'))
						: '',
					f.truncated
						? E('div', { 'class': 'cb-drop', 'style': 'color:var(--warning)',
							'title': _('only the first entries of a large list are imported') },
							_('truncated to') + ' ' + (f.imported || 0) + ' / ' + (f.total || 0))
						: ''
				]),
				E('td', { 'class': 'cb-hide-sm' }, f.kind || 'ip'),
				E('td', { 'class': 'cb-hide-sm' }, (f.kind === 'domain') ? _('domain blocking')
					: (f.kind === 'app') ? _('app recognition') : _('address blocking')),
				E('td', { 'class': 'cb-t' }, String(f.imported || 0)),
				E('td', {}, sel),
				E('td', { 'style': 'font-size:.78rem;color:var(--text-muted)' },
					f.last ? fmtTime(f.last) : _('never')),
				E('td', { 'style': 'text-align:right;white-space:nowrap' }, [
					E('button', { 'class': 'cb-btn', 'style': 'margin-right:.3rem',
						'click': function (ev) { self.handleFeedRefresh(f, ev); } }, _('Fetch')),
					E('button', { 'class': 'cb-btn cb-btn-danger',
						'click': function (ev) { self.handleFeedDel(f, ev); } }, _('Delete'))
				])
			]));
		});
	},

	refreshDomains: function () {
		var self = this;
		return callDomainList().then(function (res) {
			self.domains = (res && res.domains) || [];
			self.domainCount = (res && res.count) || 0;
			self.domainsEnabled = !!(res && res.enabled);
			self.renderDomains();
		}).catch(common.fail);
	},

	renderDomains: function () {
		var box = document.getElementById('cb-domain-list');
		if (!box) return;
		var self = this;
		while (box.firstChild) box.removeChild(box.firstChild);

		var en = document.getElementById('cb-domain-enabled');
		if (en) en.checked = this.domainsEnabled !== false;

		var cnt = document.getElementById('cb-domain-count');
		if (cnt) cnt.textContent = (this.domainCount || 0) + ' ' + _('domains');

		var list = this.domains || [];
		if (!list.length) {
			box.appendChild(E('span', { 'class': 'cb-note' }, _('None configured')));
			return;
		}
		list.slice(0, 200).forEach(function (d) {
			box.appendChild(E('span', { 'class': 'cb-proxychip' }, [
				E('span', { 'class': 'cb-mono' }, d.domain),
				E('button', {
					'class': 'cb-proxyx', 'title': _('Remove'),
					'click': function () {
						return callDomainDel(d.domain).then(function () { return self.refreshDomains(); });
					}
				}, '\u00d7')
			]));
		});
		if (list.length > 200)
			box.appendChild(E('span', { 'class': 'cb-note' }, '+ ' + (this.domainCount - 200)));
	},

	handleDomainAdd: function (ev) {
		var self = this;
		var el = document.getElementById('cb-domain-input');
		if (!el) return;
		var name = (el.value || '').trim();
		if (!name) { el.focus(); return; }
		var btn = ev.currentTarget;
		btn.disabled = true;
		return callDomainAdd(name).then(function (res) {
			if (res && res.success === false) throw new Error(res.error || _('Failed'));
			el.value = '';
			return self.refreshDomains();
		}).catch(function (e) {
			ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error');
		}).finally(function () { btn.disabled = false; });
	},

	handleDomainToggle: function (on) {
		var self = this;
		return callDomainToggle(on ? '1' : '0').then(function () {
			return self.refreshDomains();
		}).catch(function (e) {
			ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error');
		});
	},

	refreshApps: function () {
		var self = this;
		return callAppList().then(function (res) {
			self.apps = (res && res.apps) || [];
			var cnt = document.getElementById('cb-app-count');
			if (cnt) cnt.textContent = self.apps.length + ' ' + _('apps');
			var sel = document.getElementById('cb-sig-app');
			if (sel) delete sel.dataset.filled;
		}).catch(common.fail);
	},

	refreshAppStats: function (range) {
		var self = this;
		if (typeof range !== 'string') range = self.appRange || 'today';
		self.appStatsAt = Date.now();
		self.appRange = range;
		return Promise.all([ callAppList(), callAppStats(range) ]).then(function (r) {
			self.apps = (r[0] && r[0].apps) || [];
			self.appStats = r[1] || {};
			self.renderAppStats();
			var cnt = document.getElementById('cb-app-count');
			if (cnt) cnt.textContent = self.apps.length + ' ' + _('apps');
			var sel = document.getElementById('cb-sig-app');
			if (sel) delete sel.dataset.filled;
			var day = document.getElementById('cb-app-day');
			if (day) day.textContent = self.appStats.day || '';
		}).catch(function (e) { console.error('languard: app stats refresh failed', e); });
	},

	renderAppStats: function () {
		var selfC = this;
		APP_FILTER = this.appFilter || null;
		APP_CHIP_CLICK = function (name) {
			selfC.appFilter = (selfC.appFilter === name) ? null : name;
			selfC.renderAppStats();
		};
		// appChip 在 common.js 里,状态要同步过去
		common.setAppFilter(APP_FILTER, APP_CHIP_CLICK);
		var plist = (this.appStats && this.appStats.proxy) || [];
		var ptot = (this.appStats && this.appStats.proxy_total) || 0;
		var hlist = (this.appStats && this.appStats.hosts) || [];
		var ptb = document.getElementById('cb-proxy-tbody');
		if (ptb) {
			while (ptb.firstChild) ptb.removeChild(ptb.firstChild);
			var phead = document.getElementById('cb-proxy-total');
			if (phead) phead.textContent = ptot ? fmtBytes(ptot) : '';
			var q = (this.proxyFilter || '').trim().toLowerCase();
			if (q) {
				hlist = hlist.filter(function (x) {
					var hay = [ x.host || '' ];
					(x.nodes || []).forEach(function (n) { hay.push(n.node); });
					(x.groups || []).forEach(function (g) { hay.push(g.group); });
					return hay.join(' ').toLowerCase().indexOf(q) !== -1;
				});
			}
			if (!hlist.length) {
				ptb.appendChild(E('tr', {}, E('td', { 'colspan': 3, 'class': 'cb-empty' },
					q ? _('Nothing matches this filter') : _('Nothing went through the proxy in this window'))));
			}
			var lim = (this.proxyTop === undefined) ? 10 : this.proxyTop;
			var shown = lim ? hlist.slice(0, lim) : hlist;
			var top = shown.length ? shown[0].bytes : 0;
			shown.forEach(function (x) {
				var tags = [];
				(x.groups || []).forEach(function (g, i) {
					if (i < 4) tags.push(E('span', { 'class': 'cb-tag', 'title': fmtBytes(g.bytes) }, g.group));
				});
				(x.nodes || []).forEach(function (n, i) {
					if (i < 4) tags.push(E('span', { 'class': 'cb-tag cb-tag-node', 'title': fmtBytes(n.bytes) }, n.node));
				});
				ptb.appendChild(E('tr', {}, [
					E('td', { 'class': 'cb-mono', 'style': 'font-size:.78rem' }, x.host || '(ip)'),
					E('td', { 'class': 'cb-hide-sm' }, tags),
					E('td', { 'style': 'text-align:right;white-space:nowrap' }, [
						E('span', { 'style': 'display:inline-block;height:.5rem;border-radius:2px;background:var(--accent);opacity:.55;vertical-align:middle;margin-right:.5rem;width:' +
							(top ? Math.max(2, Math.round(56 * x.bytes / top)) : 0) + 'px' }),
						E('span', {}, fmtBytes(x.bytes))
					])
				]));
			});
		}

		var tbody = document.getElementById('cb-app-tbody');
		if (!tbody) return;
		while (tbody.firstChild) tbody.removeChild(tbody.firstChild);

		// 首次请求还没回来:先放骨架行,空表不会像坏了
		if (this.appStatsAt === undefined) {
			for (var si = 0; si < 3; si++) {
				tbody.appendChild(E('tr', {}, [
					E('td', {}, E('span', { 'class': 'cb-skel', 'style': 'width:' + (60 + si * 12) + '%' })),
					E('td', { 'class': 'cb-hide-sm' }, E('span', { 'class': 'cb-skel', 'style': 'width:3rem' })),
					E('td', { 'class': 'cb-hide-sm' }),
					E('td', {}, E('span', { 'class': 'cb-skel', 'style': 'width:4rem;display:inline-block' }))
				]));
			}
			return;
		}

		var self = this;
		var list = (this.appStats && this.appStats.apps) || [];
		if (!list.length) {
			tbody.appendChild(E('tr', {}, E('td', { 'colspan': 4, 'class': 'cb-empty' },
				_('No traffic attributed yet'))));
			this.renderAppDevices();
			return;
		}
		list.slice(0, 50).forEach(function (a) {
			var meta = null;
			(self.apps || []).forEach(function (x) { if (x.name === a.name) meta = x; });
			var active = self.appFilter === a.name;
			tbody.appendChild(E('tr', {
				'style': 'cursor:pointer' +
					(active ? ';background:var(--brand-subtle)' : '') +
					((self.appFilter && !active) ? ';opacity:.32' : ''),
				'click': function () {
					self.appFilter = active ? null : a.name;
					self.renderAppStats();
				}
			}, [
				E('td', { 'class': 'cb-u' }, [
					E('span', {
						'style': 'display:inline-block;width:.55rem;height:.55rem;border-radius:50%;' +
							'margin-right:.45rem;background:hsl(' + appHue(a.name) + ',62%,52%)'
					}),
					a.name,
					(meta && meta.generic)
						? E('span', { 'class': 'cb-src cb-src-manual', 'style': 'margin-left:.35rem',
							'title': _('a broad vendor category, not a single app') }, _('broad'))
						: '',
					a.low > 0
						? E('span', { 'class': 'cb-src cb-src-panic', 'style': 'margin-left:.35rem',
							'title': _('part of this was matched by port only, without checking the packet') },
							_('port match'))
						: ''
				]),
				E('td', { 'class': 'cb-hide-sm' }, meta ? (meta.class || '') : ''),
				E('td', { 'class': 'cb-hide-sm cb-t' }, meta ? String(meta.sigs) : ''),
				E('td', { 'style': 'text-align:right;font-family:var(--font-mono)' }, fmtBytes(a.bytes))
			]));
		});
		this.renderAppDevices();
	},

	renderAppDevices: function () {
		var box = document.getElementById('cb-app-dev');
		if (!box) return;
		var self = this;
		while (box.firstChild) box.removeChild(box.firstChild);

		var devs = (this.appStats && this.appStats.dev) || [];
		var filter = this.appFilter;

		if (!devs.length) {
			box.appendChild(E('span', { 'class': 'cb-note' }, _('None')));
			return;
		}
		devs.slice(0, 20).forEach(function (d) {
			box.appendChild(E('div', { 'class': 'cb-dash-row' }, [
				E('span', { 'class': 'cb-k' }, [
					(d.name || d.ip),
					E('span', { 'class': 'cb-drop' }, '  ' + d.ip)
				]),
				E('span', { 'class': 'cb-v' }, d.apps.slice(0, 4).map(function (x) {
					return appChip(x.name, x.name + ' ' + fmtBytes(x.bytes));
				}))
			]));
		});
	},

	refreshSample: function () {
		var self = this;
		return callSampleResult().then(function (res) {
			self.sample = res || {};
			self.renderSample();
			if (res && res.running) {
				if (!self.sampleTimer) {
					self.sampleTimer = window.setInterval(function () { self.refreshSample(); }, 3000);
				}
			} else if (self.sampleTimer) {
				window.clearInterval(self.sampleTimer);
				self.sampleTimer = null;
			}
		}).catch(common.fail);
	},

	renderSample: function () {
		var tbody = document.getElementById('cb-sample-tbody');
		if (!tbody) return;
		var self = this;
		while (tbody.firstChild) tbody.removeChild(tbody.firstChild);

		var running = !!(this.sample && this.sample.running);
		var pkts = (this.sample && this.sample.packets) || 0;
		var started = (this.sample && this.sample.started) || 0;
		var dur = (this.sample && this.sample.duration) || 0;
		var left = running && started && dur ? Math.max(0, dur - (Math.floor(Date.now() / 1000) - started)) : 0;

		var st = document.getElementById('cb-sample-state');
		if (st) st.textContent = running ? _('capturing') : (pkts ? _('stopped') : '');

		// the state has to be unmistakable: a dot, the remaining time, and the
		// button that would do nothing is disabled
		var live = document.getElementById('cb-sample-live');
		if (live) {
			while (live.firstChild) live.removeChild(live.firstChild);
			if (running) {
				live.appendChild(E('span', {
					'class': 'cb-res cb-health-ok', 'style': 'margin-right:.35rem' },
					'● ' + _('capturing') + ' · ' + pkts + ' ' + _('packets') +
					(left ? ' · ' + left + 's' : '')));
			} else if (pkts) {
				live.appendChild(E('span', { 'class': 'cb-drop' },
					'○ ' + _('stopped') + ' · ' + pkts + ' ' + _('packets')));
			} else {
				live.appendChild(E('span', { 'class': 'cb-drop' }, '○ ' + _('not sampling')));
			}
		}
		var sb = document.getElementById('cb-sample-start');
		if (sb) sb.disabled = running;
		var tb = document.getElementById('cb-sample-stop');
		if (tb) tb.disabled = !running;

		var groups = (this.sample && this.sample.groups) || [];
		if (!groups.length) {
			tbody.appendChild(E('tr', {}, E('td', { 'colspan': 7, 'class': 'cb-empty' },
				_('No capture yet'))));
			return;
		}
		groups.forEach(function (g) {
			tbody.appendChild(E('tr', {}, [
				E('td', { 'class': 'cb-mono' }, g.proto),
				E('td', { 'class': 'cb-mono' }, String(g.dport)),
				E('td', { 'class': 'cb-mono', 'style': 'font-size:.75rem' }, g.prefix),
				E('td', { 'class': 'cb-hide-sm cb-t' }, String(g.count)),
				E('td', { 'class': 'cb-hide-sm', 'style': 'font-size:.75rem' }, (g.dsts || []).slice(0, 2).join(' ')),
				E('td', { 'style': 'text-align:right' },
					E('button', { 'class': 'cb-btn',
						'click': function () {
							var name = prompt(_('Name this app'), '');
							if (!name) return;
							callSampleSave(name, g.proto, String(g.dport), g.prefix, 'game')
								.then(function () { return self.refreshAppStats(); })
								.catch(function (e) {
									ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error');
								});
						} }, _('Save as signature')))
			]));
		});
	},

	handleSampleStart: function (ev) {
		var self = this;
		var dur = (document.getElementById('cb-sample-dur') || {}).value || '60';
		return callSampleStart(dur).then(function () {
			return self.refreshSample();
		}).catch(function (e) {
			ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error');
		});
	},

	handleSampleStop: function (ev) {
		var self = this;
		return callSampleStop().then(function () { return self.refreshSample(); })
			.catch(common.fail);
	},

	refreshQos: function () {
		var self = this;
		return callQosList().then(function (res) {
			self.qos = (res && res.rules) || [];
			self.renderQos();
		}).catch(common.fail);
	},

	renderQos: function () {
		var self = this;
		var tbody = document.getElementById('cb-qos-tbody');
		if (!tbody) return;
		while (tbody.firstChild) tbody.removeChild(tbody.firstChild);

		// device picker
		var dev = document.getElementById('cb-qos-dev');
		if (dev && !dev.dataset.filled) {
			dev.appendChild(E('option', { 'value': '' }, _('All devices')));
			(this.devices || []).forEach(function (d) {
				if (!d.ip) return;
				dev.appendChild(E('option', { 'value': d.ip },
					(d.host || d.mac) + ' · ' + d.ip));
			});
			dev.dataset.filled = '1';
		}
		var appSel = document.getElementById('cb-qos-app');
		if (appSel && !appSel.dataset.filled) {
			appSel.appendChild(E('option', { 'value': '' }, _('All apps')));
			(this.apps || []).forEach(function (a) {
				appSel.appendChild(E('option', { 'value': a.name }, a.name));
			});
			appSel.dataset.filled = '1';
		}

		var list = this.qos || [];
		if (!list.length) {
			tbody.appendChild(E('tr', {}, E('td', { 'colspan': 7, 'class': 'cb-empty' },
				_('No rate rules yet'))));
			return;
		}
		list.forEach(function (r) {
			tbody.appendChild(E('tr', {}, [
				E('td', {}, r.ip || _('All devices')),
				E('td', { 'class': 'cb-u' }, r.app || _('All apps')),
				E('td', { 'class': 'cb-mono' },
					r.action === 'block'
						? E('span', { 'class': 'cb-src cb-src-panic' }, _('blocked'))
						: r.dscp),
				E('td', { 'class': 'cb-hide-sm cb-t' }, String(r.ips || 0)),
				E('td', { 'style': 'text-align:right' },
					E('button', { 'class': 'cb-btn cb-btn-danger',
						'click': function () {
							callQosDel(r.id).then(function () { return self.refreshQos(); });
						} }, _('Delete')))
			]));
		});
	},

	handleQosAdd: function (ev) {
		var self = this;
		var ip = (document.getElementById('cb-qos-dev') || {}).value || '';
		var app = (document.getElementById('cb-qos-app') || {}).value || '';
		var dscp = (document.getElementById('cb-qos-dscp') || {}).value || 'cs1';
		if (!ip && !app) {
			ui.addNotification(null, E('p', {}, _('Pick a device, an app, or both')), 'warning');
			return;
		}
		var btn = ev.currentTarget;
		btn.disabled = true;
		return callQosAdd(ip, app, dscp).then(function () {
			return self.refreshQos();
		}).catch(function (e) {
			ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error');
		}).finally(function () { btn.disabled = false; });
	},

	refreshDomainHits: function () {
		var self = this;
		return callDomainHits(40).then(function (res) {
			self.dh = res || {};
			var st = document.getElementById('cb-dh-state');
			if (st) st.textContent = self.dh.enabled
				? (self.dh.count || 0) + ' ' + _('hits')
				: _('logging off');
			var tb = document.getElementById('cb-dh-tbody');
			if (!tb) return;
			while (tb.firstChild) tb.removeChild(tb.firstChild);
			var hits = (self.dh.hits || []);
			if (!hits.length) {
				tb.appendChild(E('tr', {}, E('td', { 'colspan': 2, 'class': 'cb-empty' },
					self.dh.enabled ? _('No blocked domain was queried yet') : _('Enable DNS logging to see hits'))));
				return;
			}
			hits.forEach(function (h) {
				tb.appendChild(E('tr', {}, [
					E('td', { 'class': 'cb-mono' }, h.domain),
					E('td', { 'class': 'cb-mono' }, h.ip)
				]));
			});
		}).catch(common.fail);
	},

	handleDomainLog: function (ev) {
		var self = this;
		var on = !(this.dh && this.dh.enabled);
		return callDomainLog(on ? '1' : '0').then(function () {
			return self.refreshDomainHits();
		}).catch(function (e) {
			ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error');
		});
	},

	handleAppUrlImport: function (ev) {
		var self = this;
		var url = (document.getElementById('cb-app-url') || {}).value || '';
		var name = (document.getElementById('cb-app-urlname') || {}).value || '';
		if (!url.trim()) return;
		if (!name.trim()) {
			ui.addNotification(null, E('p', {}, _('Give the app a name first')), 'warning');
			return;
		}
		var btn = ev.currentTarget;
		btn.disabled = true;
		return callFeedAdd(name.trim(), url.trim(), '', 'app', 'other').then(function (res) {
			if (res && res.success === false) throw new Error(res.error || _('Failed'));
			document.getElementById('cb-app-url').value = '';
			document.getElementById('cb-app-urlname').value = '';
			return self.refreshAppStats();
		}).catch(function (e) {
			ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error');
		}).finally(function () { btn.disabled = false; });
	},

	loadSigs: function (name) {
		var self = this;
		var sel = document.getElementById('cb-sig-app');
		if (sel && !sel.dataset.filled) {
			sel.appendChild(E('option', { 'value': '' }, _('Pick an app')));
			(this.apps || []).forEach(function (a) {
				sel.appendChild(E('option', { 'value': a.name }, a.name));
			});
			sel.dataset.filled = '1';
			if (name) sel.value = name;
		}
		if (!name) return;
		return callSigList(name).then(function (res) {
			self.sigs = (res && res.sigs) || [];
			self.sigApp = name;
			self.renderSigs();
		}).catch(common.fail);
	},

	renderSigs: function () {
		var tbody = document.getElementById('cb-sig-tbody');
		if (!tbody) return;
		var self = this;
		while (tbody.firstChild) tbody.removeChild(tbody.firstChild);
		var cnt = document.getElementById('cb-sig-count');
		if (cnt) cnt.textContent = (this.sigs || []).length + ' ' + _('signatures');
		if (!(this.sigs || []).length) {
			tbody.appendChild(E('tr', {}, E('td', { 'colspan': 5, 'class': 'cb-empty' }, _('None'))));
			return;
		}
		this.sigs.forEach(function (sg) {
			tbody.appendChild(E('tr', {}, [
				E('td', { 'class': 'cb-mono' }, sg.proto || '-'),
				E('td', { 'class': 'cb-mono' }, sg.dport || '-'),
				E('td', { 'class': 'cb-mono' }, sg.host || '-'),
				E('td', { 'class': 'cb-mono', 'style': 'font-size:.72rem' }, sg.dict || '-'),
				E('td', { 'style': 'text-align:right' },
					E('button', { 'class': 'cb-btn cb-btn-danger', 'style': 'padding:.05rem .5rem',
						'click': function () {
							callSigDel(self.sigApp, sg.idx).then(function () {
								return self.loadSigs(self.sigApp);
							});
						} }, _('Delete')))
			]));
		});
	},

	handleAppImport: function (ev) {
		var self = this;
		var ta = document.getElementById('cb-app-import');
		if (!ta || !ta.value.trim()) { if (ta) ta.focus(); return; }
		var btn = ev.currentTarget;
		btn.disabled = true;
		return callAppImport(ta.value).then(function (res) {
			if (res && res.success === false) throw new Error(res.error || _('Failed'));
			ta.value = '';
			ui.addNotification(null, E('p', {},
				_('Imported') + ' ' + (res.added || 0) + ' · ' + _('total') + ' ' + (res.total || 0)), 'info');
			return self.refreshAppStats();
		}).catch(function (e) {
			ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error');
		}).finally(function () { btn.disabled = false; });
	},

	handleAppReset: function (ev) {
		var self = this;
		if (!confirm(_('Reset the traffic counters?'))) return;
		var btn = ev.currentTarget;
		btn.disabled = true;
		return callAppReset('yes').then(function () { return self.refreshAppStats(); })
			.catch(common.fail)
			.finally(function () { btn.disabled = false; });
	},

	refreshTrend: function () {
		var self = this;
		return callTrend().then(function (res) {
			self.trend = res || {};
			self.renderTrend();
		}).catch(common.fail);
	},

	renderTrend: function () {
		var box = document.getElementById('cb-trend');
		if (!box) return;
		while (box.firstChild) box.removeChild(box.firstChild);
		var h = (this.trend && this.trend.hourly) || [];
		if (!h.length) return;
		var max = 1;
		h.forEach(function (p) { if (p.fail > max) max = p.fail; });
		h.forEach(function (p) {
			var pct = Math.max(2, Math.round((p.fail / max) * 100));
			box.appendChild(E('div', {
				'class': 'cb-bar' + (p.fail ? ' has' : ''),
				'style': 'height:' + pct + '%',
				'title': (24 - p.ago) + 'h ago · ' + p.fail + ' ' + _('failures') + ' / ' + p.ok + ' ' + _('ok')
			}));
		});
	},

	handlePanic: function (on, ev) {
		var self = this;
		var btn = ev.currentTarget;
		btn.disabled = true;
		return callPanic(on ? '1' : '0').then(function (res) {
			if (res && res.success === false) throw new Error(res.error || _('Failed'));
			ui.addNotification(null, E('p', {}, on
				? _('Locked down') + ' · ' + (res.blocked || 0) + ' ' + _('devices')
				: _('Lockdown released')), 'info');
			return Promise.all([ self.refreshDash(), self.refresh() ]);
		}).catch(function (e) {
			ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error');
		}).finally(function () { btn.disabled = false; });
	},

	handleAccept: function (dev, ev) {
		var self = this;
		var btn = ev.currentTarget;
		btn.disabled = true;
		return callKnownAdd(dev.mac).then(function (res) {
			if (res && res.success === false) throw new Error(res.error || _('Failed'));
			ui.addNotification(null, E('p', {}, _('Device accepted')), 'info');
			return self.refresh();
		}).catch(function (e) {
			ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error');
		}).finally(function () { btn.disabled = false; });
	},

	handleTrust: function (dev, ev) {
		var self = this;
		var btn = ev.currentTarget;
		btn.disabled = true;
		var call = dev.trusted ? callWlDel : callWlAdd;
		return call(dev.mac).then(function (res) {
			if (res && res.success === false) throw new Error(res.error || _('Failed'));
			return self.refresh();
		}).catch(function (e) {
			ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error');
		}).finally(function () { btn.disabled = false; });
	},

	handleExport: function (ev) {
		var btn = ev.currentTarget; btn.disabled = true;
		return callExportFile().then(function (res) {
			// 应用库有 2MB,ubus 一次传不完:后端写到 /www 下,这里交给浏览器
			if (!res || res.success === false) throw new Error((res && res.error) || _('Failed'));
			var d = new Date();
			var p = function (n) { return (n < 10 ? '0' : '') + n; };
			var name = 'languard-backup-' + d.getFullYear() + p(d.getMonth() + 1) + p(d.getDate())
				+ '-' + p(d.getHours()) + p(d.getMinutes()) + '.json';
			var a = document.createElement('a');
			a.href = (res.url || '/languard-backup.json') + '?t=' + Date.now();
			a.download = name;
			document.body.appendChild(a); a.click();
			document.body.removeChild(a);
			ui.addNotification(null, E('p', {},
				_('Saved') + ' ' + name + ' (' + Math.round((res.size || 0) / 1024) + ' KB, '
				+ (res.sections || 0) + ' ' + _('sections') + ')'), 'info');
		}).catch(function (e) {
			ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error');
		}).finally(function () { btn.disabled = false; });
	},

	handleImportFile: function (ev) {
		var self = this;
		var f = ev.target.files && ev.target.files[0];
		if (!f) return;
		if (!confirm(_('Replace all lists and rules with this backup?'))) return;
		fetch('/cgi-bin/lg-upload?name=languard-backup.json', { method: 'POST', body: f })
			.then(function (r) { if (!r.ok) throw new Error('upload failed'); return callImportFile('languard-backup.json'); })
			.then(function (res) {
				if (res && res.success === false) throw new Error(res.error || _('Failed'));
				ui.addNotification(null, E('p', {},
					_('Restored') + ' ' + (res.imported || 0) + ' ' + _('sections')), 'info');
				return Promise.all([ self.refresh(), self.refreshIps(), self.refreshDash() ]);
			})
			.catch(function (e) {
				ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error');
			});
	},

	handleImport: function (ev) {
		var self = this;
		var ta = document.getElementById('cb-backup-text');
		var payload = ta ? ta.value.trim() : '';
		if (!payload) { ui.addNotification(null, E('p', {}, _('Paste a backup first')), 'warning'); return; }
		if (!confirm(_('Replace all lists and rules with this backup?'))) return;
		var btn = ev.currentTarget; btn.disabled = true;
		return callImport(payload).then(function (res) {
			if (res && res.success === false) throw new Error(res.error || _('Failed'));
			ui.addNotification(null, E('p', {}, _('Restored') + ' ' + (res.imported || 0) + ' ' + _('sections')), 'info');
			return Promise.all([ self.refresh(), self.refreshIps(), self.refreshDash() ]);
		}).catch(function (e) {
			ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error');
		}).finally(function () { btn.disabled = false; });
	},

	handlePortPreset: function (ev) {
		var self = this;
		var mac = (document.getElementById('cb-port-mac') || {}).value || '';
		var preset = (document.getElementById('cb-port-preset') || {}).value || 'iot';
		if (!mac) { ui.addNotification(null, E('p', {}, _('Pick a device')), 'warning'); return; }
		var btn = ev.currentTarget; btn.disabled = true;
		return callPortTemplate(mac, preset).then(function (res) {
			if (res && res.success === false) throw new Error(res.error || _('Failed'));
			ui.addNotification(null, E('p', {}, _('Added') + ' ' + (res.added || 0) + ' ' + _('rules')), 'info');
			return self.refreshPorts();
		}).catch(function (e) {
			ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error');
		}).finally(function () { btn.disabled = false; });
	},

	refreshPorts: function () {
		var self = this;
		return callPortList().then(function (res) {
			self.ports = (res && res.rules) || [];
			self.renderPorts();
		}).catch(function () { self.renderPorts(); });
	},

	refreshGroups: function () {
		var self = this;
		return callGroupList().then(function (res) {
			self.groups = (res && res.groups) || [];
			self.renderGroups();
		}).catch(function () { self.renderGroups(); });
	},

	handlePortAdd: function (ev) {
		var self = this;
		var mac = (document.getElementById('cb-port-mac') || {}).value || '';
		var proto = (document.getElementById('cb-port-proto') || {}).value || 'tcp';
		var port = (document.getElementById('cb-port-num') || {}).value || '';
		var note = (document.getElementById('cb-port-note') || {}).value || '';
		if (!mac) { ui.addNotification(null, E('p', {}, _('Pick a device')), 'warning'); return; }
		var btn = ev.currentTarget; btn.disabled = true;
		return callPortAdd(mac, proto, port, note).then(function (res) {
			if (res && res.success === false) throw new Error(res.error || _('Failed'));
			return self.refreshPorts();
		}).catch(function (e) {
			ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error');
		}).finally(function () { btn.disabled = false; });
	},

	handlePortDel: function (id, ev) {
		var self = this;
		ev.currentTarget.disabled = true;
		return callPortDel(id).then(function () { return self.refreshPorts(); })
			.catch(function (e) { ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error'); });
	},

	renderPorts: function () {
		var tbody = document.getElementById('cb-port-tbody');
		if (!tbody) return;
		while (tbody.firstChild) tbody.removeChild(tbody.firstChild);
		var self = this;

		var sel = document.getElementById('cb-port-mac');
		if (sel) {
			var keep = sel.value;
			while (sel.firstChild) sel.removeChild(sel.firstChild);
			(this.devices || []).forEach(function (d) {
				sel.appendChild(E('option', { 'value': d.mac }, (d.host || d.mac) + (d.ip ? '  ' + d.ip : '')));
			});
			if (keep) sel.value = keep;
		}

		var list = this.ports || [];
		if (!list.length) {
			tbody.appendChild(E('tr', {}, E('td', { 'colspan': 4, 'class': 'cb-empty' },
				_('No port restrictions yet'))));
			return;
		}
		list.forEach(function (r) {
			tbody.appendChild(E('tr', {}, [
				E('td', { 'class': 'cb-u' }, r.host || r.mac),
				E('td', { 'class': 'cb-t' }, r.proto + '/' + r.port),
				E('td', { 'style': 'font-size:.78rem;color:var(--text-muted)' }, r.note || ''),
				E('td', { 'style': 'text-align:right' },
					E('button', { 'class': 'cb-btn cb-btn-danger',
						'click': function (ev) { self.handlePortDel(r.id, ev); } }, _('Delete')))
			]));
		});
	},

	handleGroupAdd: function (ev) {
		var self = this;
		var el = document.getElementById('cb-group-name');
		var name = el ? el.value : '';
		if (!name) return;
		var btn = ev.currentTarget; btn.disabled = true;
		return callGroupAdd(name, '').then(function (res) {
			if (res && res.success === false) throw new Error(res.error || _('Failed'));
			if (el) el.value = '';
			return self.refreshGroups();
		}).catch(function (e) {
			ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error');
		}).finally(function () { btn.disabled = false; });
	},

	handleGroupDel: function (id, ev) {
		var self = this;
		ev.currentTarget.disabled = true;
		return callGroupDel(id).then(function () { return self.refreshGroups(); })
			.catch(function (e) { ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error'); });
	},

	handleCurfew: function (g, ev) {
		var self = this;
		var btn = ev.currentTarget; btn.disabled = true;
		return callCurfew(g.id, '0').then(function (res) {
			if (res && res.success === false) throw new Error(res.error || _('Failed'));
			ui.addNotification(null, E('p', {} , _('Curfew applied to') + ' ' + (res.blocked || 0) + ' ' + _('devices')), 'info');
			return self.refresh();
		}).catch(function (e) {
			ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error');
		}).finally(function () { btn.disabled = false; });
	},

	renderGroups: function () {
		var box = document.getElementById('cb-sched-groups');
		if (!box) return;
		while (box.firstChild) box.removeChild(box.firstChild);
		var self = this;
		var list = this.groups || [];
		if (!list.length) {
			box.appendChild(E('div', { 'class': 'cb-empty' }, _('No groups yet')));
			return;
		}
		list.forEach(function (g) {
			var pick = E('select', { 'multiple': 'multiple', 'size': '3',
				'style': 'min-width:16rem;font-size:.78rem;padding:.2rem;border-radius:.3rem;border:1px solid var(--hairline);background:var(--surface-sunken);color:inherit' });
			(self.devices || []).forEach(function (d) {
				var sel = (g.macs || []).indexOf(d.mac) !== -1;
				pick.appendChild(E('option', { 'value': d.mac, 'selected': sel ? 'selected' : null },
					(d.host || d.mac)));
			});
			box.appendChild(E('div', { 'style': 'display:flex;gap:.6rem;align-items:flex-start;flex-wrap:wrap;padding:.5rem 0;border-bottom:1px solid var(--hairline)' }, [
				E('div', { 'style': 'min-width:9rem' }, [
					E('div', { 'class': 'cb-u' }, g.name),
					E('div', { 'class': 'cb-drop' }, (g.count || 0) + ' ' + _('devices'))
				]),
				pick,
				E('div', { 'style': 'display:flex;gap:.35rem' }, [
					E('button', { 'class': 'cb-btn', 'click': function () {
						var macs = [];
						Array.prototype.forEach.call(pick.options, function (o) { if (o.selected) macs.push(o.value); });
						callGroupSet(g.id, macs.join(',')).then(function () { return self.refreshGroups(); })
							.catch(function (e) { ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error'); });
					} }, _('Save')),
					E('button', { 'class': 'cb-btn cb-btn-primary',
						'click': function (ev) { self.handleCurfew(g, ev); } }, _('Curfew')),
					E('button', { 'class': 'cb-btn cb-btn-danger',
						'click': function (ev) { self.handleGroupDel(g.id, ev); } }, _('Delete'))
				])
			]));
		});
	},

	refreshSched: function () {
		var self = this;
		return callSchedList().then(function (res) {
			self.sched = (res && res.rules) || [];
			self.renderSched();
		}).catch(function () { self.renderSched(); });
	},

	handleSchedAdd: function (ev) {
		var self = this;
		var sel = document.getElementById('cb-sched-mac');
		var st = document.getElementById('cb-sched-start');
		var sp = document.getElementById('cb-sched-stop');
		if (!sel || !sel.value) { ui.addNotification(null, E('p', {}, _('Pick a device')), 'warning'); return; }
		var days = [];
		document.querySelectorAll('#cb-sched-days .cb-dchip.on').forEach(function (d) {
			days.push(parseInt(d.getAttribute('data-day'), 10));
		});
		if (!days.length) { ui.addNotification(null, E('p', {}, _('Pick at least one day')), 'warning'); return; }
		if (!st.value || !sp.value) { ui.addNotification(null, E('p', {}, _('Set both times')), 'warning'); return; }
		if (st.value === sp.value) { ui.addNotification(null, E('p', {}, _('Start and end must differ')), 'warning'); return; }

		var btn = ev.currentTarget;
		btn.disabled = true;
		return callSchedAdd(sel.value, days.join(','), st.value, sp.value, sel.options[sel.selectedIndex].text)
			.then(function (res) {
				if (res && res.success === false) throw new Error(res.error || _('Failed'));
				self.sched = (res && res.rules) || [];
				self.renderSched();
				return self.refresh();
			}).catch(function (e) {
				ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error');
			}).finally(function () { btn.disabled = false; });
	},

	handleSchedDel: function (id, ev) {
		var self = this;
		var btn = ev.currentTarget;
		btn.disabled = true;
		return callSchedDel(id).then(function (res) {
			self.sched = (res && res.rules) || [];
			self.renderSched();
			return self.refresh();
		}).catch(function (e) {
			ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error');
		});
	},

	handleSchedToggle: function (rule, ev) {
		var self = this;
		return callSchedToggle(rule.id, rule.enabled ? '0' : '1').then(function (res) {
			self.sched = (res && res.rules) || [];
			self.renderSched();
			return self.refresh();
		}).catch(function (e) {
			ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error');
		});
	},

	renderSched: function () {
		var tbody = document.getElementById('cb-sched-tbody');
		if (!tbody) return;
		while (tbody.firstChild) tbody.removeChild(tbody.firstChild);

		var self = this;
		var names = [_('Sun'), _('Mon'), _('Tue'), _('Wed'), _('Thu'), _('Fri'), _('Sat')];
		var list = this.sched || [];

		// device picker options
		var sel = document.getElementById('cb-sched-mac');
		if (sel) {
			var keep = sel.value;
			while (sel.firstChild) sel.removeChild(sel.firstChild);
			(this.devices || []).slice().sort(function (a, b) {
				return String(a.host || a.ip || '').localeCompare(String(b.host || b.ip || ''));
			}).forEach(function (d) {
				sel.appendChild(E('option', { 'value': d.mac },
					(d.host || d.mac) + (d.ip ? '  ' + d.ip : '')));
			});
			if (keep) sel.value = keep;
		}

		if (!list.length) {
			tbody.appendChild(E('tr', {}, E('td', { 'colspan': 7, 'class': 'cb-empty' },
				_('No schedule rules yet'))));
			return;
		}

		list.forEach(function (r) {
			var dayTxt = (r.days || []).map(function (d) { return names[d] || d; }).join(' ');
			tbody.appendChild(E('tr', {}, [
				E('td', { 'class': 'cb-u' }, r.name || r.mac),
				E('td', { 'style': 'font-size:.8rem' }, dayTxt),
				E('td', { 'class': 'cb-t' }, (r.start || '') + ' - ' + (r.stop || '')),
				E('td', {}, E('span', { 'class': 'cb-res ' + (r.active ? 'cb-sched-on' : 'cb-sched-idle') },
					r.active ? _('blocking now') : (r.enabled ? _('scheduled') : _('disabled')))),
				E('td', { 'style': 'text-align:right;white-space:nowrap' }, [
					E('button', { 'class': 'cb-btn', 'style': 'margin-right:.35rem',
						'click': function (ev) { self.handleSchedToggle(r, ev); } },
						r.enabled ? _('Pause') : _('Resume')),
					E('button', { 'class': 'cb-btn cb-btn-danger',
						'click': function (ev) { self.handleSchedDel(r.id, ev); } }, _('Delete'))
				])
			]));
		});
	},

	// Rebuild the two kernel sets from saved state. This only touches set
	// elements, so it is safe to run while the LAN is busy.
	handleSync: function (ev) {
		var self = this;
		var btn = ev && ev.currentTarget;
		if (btn) btn.disabled = true;
		return callSync().then(function () {
			ui.addNotification(null, E('p', {}, _('Kernel set rebuilt from saved state')), 'info');
			return Promise.all([ self.refreshHealth(), self.refreshDash() ]);
		}).catch(function (e) {
			ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error');
		}).finally(function () { if (btn) btn.disabled = false; });
	},

	refreshHealth: function () {
		var self = this;
		return callSelfCheck().then(function (res) {
			self.health = res || {};
			self.renderHealth();
		}).catch(function (e) {
			self.health = { ok: false, checks: [], error: e && e.message };
			self.renderHealth();
		});
	},

	renderHealth: function () {
		var box = document.getElementById('cb-health-body');
		if (!box) return;
		while (box.firstChild) box.removeChild(box.firstChild);

		var h = this.health || {};
		var names = {
			watcher: _('Service process'),
			logread: _('Log stream'),
			rulesfile: _('Generated rules'),
			nftset: _('Kernel IP set'),
			nfthook: _('Firewall rules'),
			geodb: _('Region database'),
			state: _('State storage'),
			autoprot: _('Automatic protection'),
			appstats: _('Traffic counters'),
			luci_realip: _('LuCI client address')
		};

		var head = document.getElementById('cb-health-head');
		if (head) {
			while (head.firstChild) head.removeChild(head.firstChild);
			head.appendChild(E('span', {
				'class': 'cb-res ' + (h.ok ? 'cb-health-ok' : 'cb-health-bad')
			}, h.ok ? _('all checks passed') : _('attention needed')));
			if (h.error) head.appendChild(E('span', { 'class': 'cb-drop' }, h.error));
		}

		var list = h.checks || [];
		if (!list.length) {
			box.appendChild(E('div', { 'class': 'cb-empty' }, _('No results yet')));
			return;
		}

		var self = this;
		// 每一项都对应后端 methods.fix 里的一条恢复动作
		var FIXABLE = { nftset: 1, rulesfile: 1, nfthook: 1,
		                watcher: 1, appstats: 1, logread: 1, luci_realip: 1 };

		list.forEach(function (c) {
			var bad = !c.ok;
			var extra = [];
			if (bad && c.hint) extra.push(E('span', { 'class': 'cb-hint' }, c.hint));
			if (bad && FIXABLE[c.id]) {
				extra.push(E('span', { 'class': 'cb-hint' },
					E('button', {
						'class': 'cb-btn cb-btn-primary',
						'style': 'font-size:.75rem;padding:.1rem .55rem',
						'click': function (ev) { self.handleFix(ev, c.id); }
					}, _('Fix now'))));
			}
			box.appendChild(E('div', { 'class': 'cb-check' + (bad ? ' bad' : '') }, [
				E('span', { 'class': 'cb-mark ' + (bad ? 'bad' : 'ok') }, bad ? '\u2715' : '\u2713'),
				E('span', { 'class': 'cb-name' }, names[c.id] || c.id),
				E('span', { 'class': 'cb-val' }, c.detail || '')
			].concat(extra)));
		});
	},

	refreshLogs: function () {
		var self = this;
		// 封禁记录和登录记录合成一条时间线:它们回答的是同一类问题
		var audit = callBlockAudit('100').then(function (r) {
			return ((r && r.events) || []).map(function (e) {
				var ts = Math.round(new Date(String(e.ts).replace(' ', 'T')).getTime() / 1000) || 0;
				var t = ts ? fmtTime(ts) : String(e.ts || '');
				return { ts: ts, kind: e.kind === 'panic' ? 'panic' : e.kind,
				         result: e.kind === 'unblock' ? 'closed' : 'failure',
				         ip: e.ip && e.ip !== '-' ? e.ip : '',
				         user: e.mac && e.mac !== '-' ? e.mac : '',
				         detail: (e.note || '') };
			});
		}).catch(function () { return []; });
		return Promise.all([ callLogList('500'), audit ]).then(function (both) {
			var res = both[0];
			var merged = ((res && res.entries) || []).concat(both[1]);
			merged.sort(function (a, b) { return (b.ts || 0) - (a.ts || 0); });
			res = { entries: merged };
			var next = (res && res.entries) || [];
			var prev = self.logs || [];
			// Only touch the DOM when the head changed, so the flash animation
			// on new rows is not restarted by every poll.
			var head = function (a) {
				return a.length ? [ a[0].ts, a[0].ip, a[0].kind, a[0].result ].join('|') : '';
			};
			if (head(prev) === head(next) && prev.length === next.length) {
				return;
			}
			// remember which entries are new so they can be highlighted
			var prevKeys = {};
			prev.forEach(function (e) { prevKeys[e.ts + '|' + e.ip + '|' + e.kind + '|' + e.result] = 1; });
			self.newKeys = {};
			next.forEach(function (e) {
				var k = e.ts + '|' + e.ip + '|' + e.kind + '|' + e.result;
				if (!prevKeys[k]) self.newKeys[k] = 1;
			});
			self.logs = next;
			self.renderLogs();
		}).catch(common.fail);
	},

	handleFix: function (ev, id) {
		var self = this;
		var btn = ev.currentTarget;
		btn.disabled = true;
		return callFix(id).then(function (r) {
			var what = (r && r.action) || 'done';
			ui.addNotification(null, E('p', {}, _('Repair started') + ': ' + what), 'info');
			window.setTimeout(function () { self.refreshHealth(); }, 2500);
			window.setTimeout(function () { self.refreshHealth(); }, 8000);
		}).catch(function (e) {
			ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error');
		}).finally(function () { btn.disabled = false; });
	},

	handleLogClear: function (ev) {
		var self = this;
		if (!confirm(_('Clear the login log?'))) return;
		var btn = ev.currentTarget;
		btn.disabled = true;
		return callLogClear().then(function () {
			self.logs = [];
			self.newKeys = {};
			self.renderLogs();
			ui.addNotification(null, E('p', {}, _('Log cleared')), 'info');
		}).catch(function (e) {
			ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error');
		}).finally(function () {
			btn.disabled = false;
		});
	},

	logDayLabel: function (ts) {
		var d = new Date(ts * 1000);
		var now = new Date();
		var same = function (a, b) {
			return a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth()
				&& a.getDate() === b.getDate();
		};
		var y = new Date(now.getTime() - 86400000);
		function p(x) { return (x < 10 ? '0' : '') + x; }
		if (same(d, now)) return { label: _('Today'), key: 'today' };
		if (same(d, y)) return { label: _('Yesterday'), key: 'yday' };
		return { label: d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate()),
		         key: 'd' + d.getFullYear() + p(d.getMonth() + 1) + p(d.getDate()) };
	},

	logResultClass: function (r) {
		if (r === 'success') return 'r-ok';
		if (r === 'failure') return 'r-fail';
		return 'r-end';
	},

	// ssh_password / ssh_user -> SSH, web / web_auth -> LuCI
	logSource: function (kind) {
		if (!kind) return null;
		if (kind.indexOf('ssh') === 0) return { label: 'SSH', cls: 'cb-src-ssh' };
		if (kind.indexOf('web') === 0) return { label: 'LuCI', cls: 'cb-src-web' };
		return null;
	},

	// only auth=... details carry a method
	logAuth: function (detail) {
		var m = (detail || '').match(/^auth=(\w+)$/);
		return m ? m[1] : null;
	},

	renderLogs: function () {
		var tbody = document.getElementById('cb-log-tbody');
		if (!tbody) return;
		while (tbody.firstChild) tbody.removeChild(tbody.firstChild);

		var self = this;
		var all = this.logs || [];
		var q = (this.logQuery || '').toLowerCase().trim();
		var kindF = this.logKind || 'all';
		var resF = this.logResult || 'all';
		var newKeys = this.newKeys || {};

		var list = all.filter(function (e) {
			if (kindF !== 'all') {
				if (kindF === 'ssh') { if (String(e.kind).indexOf('ssh') !== 0) return false; }
				else if (kindF === 'web') { if (String(e.kind).indexOf('web') !== 0) return false; }
				else if (e.kind !== kindF) return false;
			}
			if (resF === 'ok' && e.result !== 'success') return false;
			if (resF === 'fail' && e.result !== 'failure') return false;
			if (resF === 'end' && e.result !== 'disconnect') return false;
			if (q) {
				var hay = [ e.ip, e.user, e.detail, e.host ].join(' ').toLowerCase();
				if (hay.indexOf(q) === -1) return false;
			}
			return true;
		});

		if (!list.length) {
			tbody.appendChild(E('tr', {}, E('td', { 'colspan': 7, 'class': 'cb-empty' },
				all.length ? _('No entries match the filter') : _('No activity recorded yet'))));
		}

		var lastDay = null;
		list.forEach(function (e) {
			var day = self.logDayLabel(e.ts);
			if (day.key !== lastDay) {
				lastDay = day.key;
				tbody.appendChild(E('tr', { 'class': 'cb-day' }, E('td', { 'colspan': 7 },
					day.key === 'today' || day.key === 'yday'
						? E('span', {}, E('em', {}, day.label), ' ', fmtTime(e.ts).split(' ')[0])
						: day.label)));
			}

			var resLabel = e.result === 'success' ? 'success'
				: (e.result === 'failure' ? 'failure' : 'closed');
			var resBadge = E('span', { 'class': 'cb-res cb-res-' +
				(e.result === 'success' ? 'ok' : (e.result === 'failure' ? 'fail' : 'end')) }, resLabel);

			var src = self.logSource(e.kind);
			var srcBadge = src
				? E('span', { 'class': 'cb-res ' + src.cls }, src.label)
				: E('span', { 'class': 'cb-drop' }, '-');

			var auth = self.logAuth(e.detail);
			var authBadge = auth
				? E('span', { 'class': 'cb-auth cb-auth-' + auth }, auth)
				: E('span', { 'class': 'cb-auth cb-auth-na' }, 'n/a');

			// the auth method is its own column now; drop it from the detail text
			var reason = String(e.detail || '').replace(/^auth=\w+\s*/, '').trim();

			var cc = e.geo ? (String(e.geo).split('|')[4] || '').trim() : '';
			var geoCell = e.geo
				? E('span', { 'class': 'cb-geo', 'title': fmtGeo(e.geo) }, cc || '?')
				: '';

			var key = e.ts + '|' + e.ip + '|' + e.kind + '|' + e.result;
			var cls = self.logResultClass(e.result) + (newKeys[key] ? ' cb-new' : '');

			tbody.appendChild(E('tr', { 'class': cls }, [
				E('td', { 'class': 'cb-t' }, (function () {
					// the day separator already carries the date; on a phone the
					// column only needs the clock
					var ft = fmtTime(e.ts), sp = ft.indexOf(' ');
					if (sp < 0) return ft;
					return [ E('span', { 'class': 'cb-date' }, ft.slice(0, sp)), ' ', ft.slice(sp + 1) ];
				})()),
				E('td', {}, resBadge),
				E('td', {}, srcBadge),
				E('td', { 'class': 'cb-hide-sm' }, authBadge),
				E('td', { 'class': 'cb-ip' }, [
					e.ip || '-',
					e.host ? E('span', { 'class': 'cb-drop' }, ' ' + e.host) : ''
				]),
				E('td', { 'class': 'cb-u cb-hide-sm' }, e.user || '-'),
				E('td', { 'class': 'cb-detail' }, reason || geoCell
					? [ geoCell, geoCell && reason ? ' ' : '', reason ]
					: '')
			]));
		});

		var cnt = document.getElementById('cb-log-count');
		if (cnt) cnt.textContent = list.length + ' / ' + all.length + ' ' + _('entries');
	},

	refreshAuto: function () {
		var self = this;
		return callAutoGet().then(function (res) {
			self.auto = res || {};
			self.renderAuto();
		}).catch(common.fail);
	},

	handleAutoToggle: function (ev) {
		var self = this;
		var on = ev.target.checked;
		return callAutoSet(on, this.auto.threshold, this.auto.window, this.auto.ttl)
			.then(function (res) {
				self.auto = res || self.auto;
				ui.addNotification(null, E('p', {},
					on ? _('Automatic blocking enabled') : _('Automatic blocking disabled')), 'info');
			}).catch(function (e) {
				ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error');
			});
	},

	handleAutoSave: function (ev) {
		var self = this;
		var t = document.getElementById('cb-auto-threshold');
		var w = document.getElementById('cb-auto-window');
		var l = document.getElementById('cb-auto-ttl');
		function trig(key) {
			var el = document.getElementById('cb-trig-' + key);
			return el && el.checked ? '1' : '0';
		}
		var btn = ev.currentTarget;
		btn.disabled = true;
		return callAutoSet(
				self.auto.enabled ? '1' : '0',
				t ? t.value : '', w ? w.value : '', l ? l.value : '',
				trig('ssh_password'), trig('ssh_user'), trig('web_auth'))
			.then(function (res) {
				if (res && res.success === false) throw new Error(res.error || _('Failed'));
				self.auto = res || self.auto;
				self.renderAuto();
				ui.addNotification(null, E('p', {}, _('Settings saved')), 'info');
			}).catch(function (e) {
				ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error');
			}).finally(function () {
				btn.disabled = false;
			});
	},

	handleScanNow: function (ev) {
		var self = this;
		var btn = ev.currentTarget;
		btn.disabled = true;
		return callScan().then(function (res) {
			var banned = (res && res.banned) || [];
			ui.addNotification(null, E('p', {}, banned.length
				? _('Blocked') + ' ' + banned.length + ': ' + banned.join(', ')
				: _('No new offenders')), 'info');
			return self.refreshIps();
		}).catch(function (e) {
			ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error');
		}).finally(function () {
			btn.disabled = false;
		});
	},

	renderAuto: function () {
		var box = document.getElementById('cb-auto-body');
		if (!box) return;
		while (box.firstChild) box.removeChild(box.firstChild);

		var a = this.auto || {};
		var self = this;
		var on = !!a.enabled;

		box.appendChild(E('label', { 'class': 'cb-switch' }, [
			E('input', {
				'type': 'checkbox',
				'checked': on ? 'checked' : null,
				'change': function (ev) { self.handleAutoToggle(ev); }
			}),
			E('span', { 'class': 'cb-track' }),
			E('span', {}, on ? _('Protection on') : _('Protection off'))
		]));

		var kinds = [
			{ key: 'ssh_password', label: _('SSH password failure'), code: 'Bad password / Max auth tries' },
			{ key: 'ssh_user',     label: _('SSH unknown user'),     code: 'nonexistent user' },
			{ key: 'web_auth',     label: _('LuCI login failure'),   code: 'failed login' }
		];
		var chips = E('div', { 'class': 'cb-triggers', 'id': 'cb-trigger-group' });
		kinds.forEach(function (k) {
			var checked = a[k.key] !== false;
			chips.appendChild(E('label', { 'class': 'cb-chip' + (checked ? ' on' : '') }, [
				E('input', {
					'type': 'checkbox',
					'id': 'cb-trig-' + k.key,
					'checked': checked ? 'checked' : null,
					'change': function (ev) {
						ev.target.parentNode.classList.toggle('on', ev.target.checked);
					}
				}),
				E('span', {}, k.label),
				E('span', { 'class': 'cb-chip-code' }, k.code)
			]));
		});

		box.appendChild(chips);
		box.appendChild(E('div', { 'class': 'cb-fields' }, [
			E('label', { 'class': 'cb-field' }, [
				E('span', {}, _('Trigger after')),
				E('input', { 'type': 'number', 'id': 'cb-auto-threshold', 'min': '1', 'max': '100',
					'value': a.threshold || 5 })
			]),
			E('label', { 'class': 'cb-field' }, [
				E('span', {}, _('Within (seconds)')),
				E('input', { 'type': 'number', 'id': 'cb-auto-window', 'min': '60', 'max': '86400',
					'value': a.window || 600 })
			]),
			E('label', { 'class': 'cb-field' }, [
				E('span', {}, _('Expire after (0 = never)')),
				E('input', { 'type': 'number', 'id': 'cb-auto-ttl', 'min': '0', 'max': '2592000',
					'value': a.ttl === 0 ? 0 : (a.ttl || 86400) })
			]),
			E('div', { 'class': 'cb-actions' }, [
				E('button', { 'class': 'cb-btn cb-btn-primary',
					'click': function (ev) { self.handleAutoSave(ev); } }, _('Save')),
				E('button', { 'class': 'cb-btn',
					'click': function (ev) { self.handleScanNow(ev); } }, _('Scan now'))
			])
		]));

		box.appendChild(E('div', { 'class': 'cb-subhead' }, _('Trusted proxies')));
		box.appendChild(E('p', { 'class': 'cb-note' },
			_('A reverse proxy in front of the LAN makes every request look like it came from the proxy itself. Addresses listed here are never blocked, and when a log line names one of them as the source, the real client is read from X-Forwarded-For / X-Real-IP instead.')));
		box.appendChild(E('div', { 'class': 'cb-proxylist', 'id': 'cb-proxy-list' }, []));
		box.appendChild(E('div', { 'class': 'cb-actions' }, [
			E('input', {
				'type': 'text', 'id': 'cb-proxy-input', 'class': 'cb-input',
				'placeholder': '192.168.1.5',
				'style': 'max-width:14rem'
			}),
			E('button', { 'class': 'cb-btn cb-btn-primary',
				'click': function (ev) { self.handleProxyAdd(ev); } }, _('Add')),
			E('button', { 'class': 'cb-btn',
				'click': function () {
					var el = document.getElementById('cb-proxy-input');
					if (el) el.value = '192.168.1.5';
				} }, _('Use router address'))
		]));

	},

	refreshProxies: function () {
		var self = this;
		var box = document.getElementById('cb-proxy-list');
		if (!box) return;
		return callProxyList().then(function (res) {
			var list = (res && res.proxies) || [];
			while (box.firstChild) box.removeChild(box.firstChild);
			if (!list.length) {
				box.appendChild(E('span', { 'class': 'cb-note' }, _('None configured')));
				return;
			}
			list.forEach(function (p) {
				box.appendChild(E('span', { 'class': 'cb-proxychip' }, [
					E('span', { 'class': 'cb-mono' }, p.ip),
					E('button', {
						'class': 'cb-proxyx',
						'title': _('Remove'),
						'click': function () {
							return callProxyDel(p.ip).then(function () {
								return self.refreshProxies();
							});
						}
					}, '\u00d7')
				]));
			});
		}).catch(common.fail);
	},

	handleProxyAdd: function (ev) {
		var self = this;
		var el = document.getElementById('cb-proxy-input');
		if (!el) return;
		var ip = (el.value || '').trim();
		if (!ip) { el.focus(); return; }
		var btn = ev.currentTarget;
		btn.disabled = true;
		return callProxyAdd(ip).then(function (res) {
			if (res && res.success === false)
				throw new Error(res.error || _('Failed'));
			el.value = '';
			return self.refreshProxies();
		}).catch(function (e) {
			ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error');
		}).finally(function () {
			btn.disabled = false;
		});
	},

	refreshIps: function () {
		var self = this;
		return callIpList(0, this.ipCat || '').then(function (res) {
			self.ips = (res && res.ips) || [];
			self.ipCount = (res && res.count) || 0;
			self.ipMatched = (res && res.matched) || 0;
			self.ipCats = (res && res.categories) || [];
			self.renderIpChips();
			self.renderIps();
		}).catch(function () {
			self.renderIps();
		});
	},

	handleIpAdd: function (ev) {
		var self = this;
		var ipEl = document.getElementById('cb-ip-input');
		var noteEl = document.getElementById('cb-ip-note');
		if (!ipEl) return;
		var ip = (ipEl.value || '').trim();
		if (!ip) {
			ipEl.focus();
			return;
		}
		var btn = ev.currentTarget;
		btn.disabled = true;
		return callIpAdd(ip, (noteEl && noteEl.value) || '').then(function (res) {
			if (res && res.success === false)
				throw new Error(res.error || _('Failed'));
			ipEl.value = '';
			if (noteEl) noteEl.value = '';
			return self.refreshIps();
		}).catch(function (e) {
			ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error');
		}).finally(function () {
			btn.disabled = false;
		});
	},

	handleIpDel: function (ip, ev) {
		var self = this;
		var btn = ev.currentTarget;
		btn.disabled = true;
		return callIpDel(ip).then(function (res) {
			if (res && res.success === false)
				throw new Error(res.error || _('Failed'));
			return self.refreshIps();
		}).catch(function (e) {
			ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error');
			return self.refreshIps();
		});
	},

	handleIpFlush: function (ev) {
		var self = this;
		if (!confirm(_('Remove all blocked IPs?')))
			return;
		var btn = ev.currentTarget;
		btn.disabled = true;
		return callIpFlush('yes').then(function () {
			return self.refreshIps();
		}).catch(function (e) {
			ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error');
			return self.refreshIps();
		});
	},

	renderIpChips: function () {
		var box = document.getElementById('cb-ip-cats');
		if (!box) return;
		var self = this;
		while (box.firstChild) box.removeChild(box.firstChild);

		var counts = { '': this.ipCount || 0 };
		(this.ipCats || []).forEach(function (c) { counts[c.key] = c.count; });

		IP_CATS.forEach(function (c) {
			var n = counts[c.key];
			// keep the full taxonomy visible so it is discoverable; "other" is
			// the catch-all and only appears when something landed in it
			if (c.key === 'other' && !n) return;
			var on = (self.ipCat || '') === c.key;
			box.appendChild(E('button', {
				'class': 'cb-catchip' + (on ? ' cb-catchip-on' : '') + (n ? '' : ' cb-catchip-zero'),
				'click': function () {
					self.ipCat = c.key;
					self.refreshIps();
				}
			}, [
				E('span', { 'class': 'cb-src ' + c.cls, 'style': 'margin-right:.35rem' }, c.label),
				E('span', {}, String(n || 0))
			]));
		});
	},

	renderIps: function () {
		var tbody = document.getElementById('cb-ip-tbody');
		if (!tbody) return;
		while (tbody.firstChild) tbody.removeChild(tbody.firstChild);

		var list = this.ips || [];
		var self = this;
		var q = (this.ipQuery || '').toLowerCase().trim();
		if (q)
			list = list.filter(function (r) {
				return (r.ip || '').toLowerCase().indexOf(q) !== -1 ||
					(r.note || '').toLowerCase().indexOf(q) !== -1;
			});

		if (!list.length) {
			var emptyCell = E('td', { 'colspan': 6, 'class': 'cb-empty' });
			if (this.ipCat && !q) {
				emptyCell.appendChild(document.createTextNode(
					_('No entries in this category')));
				tbody.appendChild(E('tr', {}, emptyCell));
				var cnt0 = document.getElementById('cb-ip-count');
				if (cnt0) cnt0.textContent = '0 / ' + (this.ipCount || 0) + ' ' + _('blocked');
				return;
			}
			if (q) {
				emptyCell.appendChild(document.createTextNode(_('No entries match the filter')));
			} else {
				emptyCell.appendChild(E('div', { 'style': 'font-weight:600;margin-bottom:.35rem' },
					_('No blocked IPs yet')));
				emptyCell.appendChild(E('div', {},
					_('Type an address above and press Block IP. Single addresses and CIDR ranges both work.')));
				emptyCell.appendChild(E('div', { 'style': 'margin-top:.9rem' },
					E('button', {
						'style': 'font-size:.78rem;padding:.15rem .5rem;opacity:.55;cursor:pointer;background:none;border:none;color:inherit;text-decoration:underline',
						'click': function () {
							var el = document.getElementById('cb-ip-input');
							if (el) el.focus();
						}
					}, _('Jump to the input field'))));
			}
			tbody.appendChild(E('tr', {}, emptyCell));
		}

		list.forEach(function (r) {
			tbody.appendChild(E('tr', {}, [
				E('td', { 'style': 'white-space:nowrap' }, [
					r.ip,
					' ',
					E('span', { 'class': 'cb-fam' }, '(IPv' + (r.family === 'ipv6' ? '6' : '4') + ')')
				].concat((function () {
					var c = catMeta(r.category);
					var text = (r.category === 'feed' && r.feed_name) ? r.feed_name : c.label;
					return [ ' ', E('span', { 'class': 'cb-src ' + c.cls, 'title': c.label }, text) ];
				})())),
				E('td', { 'class': 'cb-hide-sm', 'style': 'font-size:.8rem;opacity:.85' }, fmtGeo(r.geo) || E('span', { 'class': 'cb-drop' }, '-')),
				E('td', {}, r.note || ''),
				E('td', { 'class': 'cb-drop cb-hide-sm' }, (r.drop_packets || 0) + ' pkt / ' + fmtBytes(r.drop_bytes)),
				E('td', { 'class': 'cb-drop' }, fmtTime(r.since)),
				E('td', { 'style': 'text-align:right' },
					E('button', {
						'class': 'cb-btn cb-btn-ok',
						'click': function (ev) { self.handleIpDel(r.ip, ev); }
					}, _('Unblock')))
			]));
		});

		var cnt = document.getElementById('cb-ip-count');
		if (cnt) {
			var matched = this.ipCat ? (this.ipMatched || 0) : (this.ipCount || 0);
			var txt = (this.ipCat ? matched + ' / ' + (this.ipCount || 0) : matched) + ' ' + _('blocked');
			if (matched > list.length)
				txt += ' · ' + _('showing first') + ' ' + list.length;
			cnt.textContent = txt;
		}
	},

	// One tab may own several panes (Settings groups protection, notifications,
	// health and backup).
	tabPanes: {
		overview: [ 'dash' ],
		devices: [ 'devices' ],
		apps: [ 'apps' ],
		ips: [ 'ips', 'sched' ],
		feeds: [ 'feeds' ],
		logs: [ 'logs' ],
		settings: [ 'auto', 'notify', 'health', 'backup' ]
	},

	switchTab: function (name) {
		this.tab = name;
		var self = this;
		var all = [];
		Object.keys(this.tabPanes).forEach(function (k) { all = all.concat(self.tabPanes[k]); });
		var mine = this.tabPanes[name] || [];
		all.forEach(function (p) {
			var el = document.getElementById('cb-pane-' + p);
			if (el) el.classList.toggle('active', mine.indexOf(p) !== -1);
		});
		['overview', 'devices', 'apps', 'ips', 'feeds', 'logs', 'settings'].forEach(function (t) {
			var btn = document.getElementById('cb-tab-' + t);
			if (btn) btn.classList.toggle('active', t === name);
		});
		if (name === 'overview') return this.refreshDash();
		if (name === 'devices') {
			var selfD = this;
			return Promise.all([ this.refresh(), callList('0') ]).then(function (r) {
				selfD.devices = (r[1] && r[1].devices) || selfD.devices || [];
				return Promise.all([ selfD.refreshApps(), selfD.refreshQos() ]);
			});
		}
		if (name === 'ips') return Promise.all([ this.refreshIps(), this.refreshDomains(),
			this.refreshSched(), this.refreshGroups(), this.refreshPorts() ]);
		if (name === 'apps') {
			var selfA = this;
			return Promise.all([ this.refreshApps(), this.refreshAppStats(), callList('0'), this.refreshSample(), this.refreshDomainHits() ])
				.then(function (r) {
					selfA.devices = (r[2] && r[2].devices) || selfA.devices || [];
					return selfA.refreshQos();
				});
		}
		if (name === 'feeds') return this.refreshFeeds();
		if (name === 'logs') return this.refreshLogs();
		if (name === 'settings') {
			var self2 = this;
			return Promise.all([ this.refreshAuto(), this.refreshNotify(), this.refreshHealth() ])
				.then(function () { return self2.refreshProxies(); });
		}
	},

	renderTable: function () {
		var tbody = document.getElementById('cb-tbody');
		if (!tbody) return;
		while (tbody.firstChild) tbody.removeChild(tbody.firstChild);

		var rows = this.filterRows() || [];
		var self = this;

		if (!rows.length) {
			tbody.appendChild(E('tr', {}, E('td', { 'colspan': 7, 'class': 'cb-empty' },
				_('No devices match the filter'))));
		}

		rows.forEach(function (d) {
			var newBadge = d.is_new
				? E('span', { 'class': 'cb-res cb-sched-on', 'style': 'margin-left:.35rem' }, _('new'))
				: '';
			var conflictBadge = d.conflict
				? E('span', {
					'class': 'cb-src cb-src-panic', 'style': 'margin-left:.35rem',
					'title': _('this address is also claimed by') + ' ' + d.conflict
				}, _('IP conflict'))
				: '';

			var stateBadge = d.blocked
				? E('span', { 'class': 'cb-badge cb-badge-blocked' }, _('Blocked'))
				: (d.online
					? E('span', { 'class': 'cb-badge cb-badge-on' }, _('Online'))
					: E('span', { 'class': 'cb-badge cb-badge-off' }, _('Offline')));

			var trustBtn = d.is_new
				? E('button', {
					'class': 'cb-btn cb-btn-primary',
					'style': 'margin-right:.3rem',
					'title': _('Accept this device as known'),
					'click': function (ev) { self.handleAccept(d, ev); }
				}, _('Allow'))
				: '';

			var action;
			if (d.blocked) {
				action = E('button', {
					'class': 'cb-btn cb-btn-ok',
					'click': function (ev) { self.handleUnblock(d, ev); }
				}, _('Unblock'));
			} else {
				action = E('button', {
					'class': 'cb-btn cb-btn-danger',
					'click': function (ev) { self.handleBlock(d, ev); }
				}, _('Block'));
			}

			var dropText = d.blocked
				? E('span', { 'class': 'cb-drop' },
					(d.drop_packets || 0) + ' pkt / ' + fmtBytes(d.drop_bytes))
				: '';

			var nameCell = d.blocked
				? E('a', {
					'href': '#',
					'title': _('Rename'),
					'style': 'color:inherit;text-decoration:none;border-bottom:1px dotted currentColor',
					'click': function (ev) {
						ev.preventDefault();
						self.handleRename(d);
					}
				}, d.host || _('(unnamed)'))
				: (d.host || E('span', { 'class': 'cb-mono' }, _('(unnamed)')));

			// a container or VM on the same box answers with its own generated
			// MAC; offer to fold it into the physical device
			var mergeBtn = (d.local_mac && d.conflict)
				? E('button', {
					'class': 'cb-btn', 'style': 'margin-right:.3rem',
					'title': _('this interface belongs to another device'),
					'click': function () {
						callDevMerge(d.mac, d.conflict).then(function () {
							return self.refresh();
						}).catch(function (e) {
							ui.addNotification(null, E('p', {}, e.message || _('Failed')), 'error');
						});
					}
				}, _('Merge into') + ' ' + d.conflict)
				: '';

			var aliasNote = (d.aliases && d.aliases.length)
				? E('div', { 'class': 'cb-drop', 'style': 'margin-top:.15rem' }, [
					d.aliases.length + ' ' + _('merged interface(s)'),
					E('button', {
						'class': 'cb-proxyx', 'title': _('Undo merge'),
						'click': function () {
							callDevUnmerge(d.aliases[0]).then(function () { return self.refresh(); })
								.catch(common.fail);
						}
					}, '\u00d7')
				])
				: '';

			tbody.appendChild(E('tr', { 'class': d.blocked ? 'cb-blocked' : (d.online ? '' : 'cb-offline') }, [
				E('td', {}, [ stateBadge, newBadge, conflictBadge ]),
				E('td', {}, [
					nameCell,
					(d.vendor || d.device_type)
						? E('div', { 'class': 'cb-drop cb-vendor', 'title': (d.vendor || '') + ' · ' + typeLabel(d.device_type) },
							(d.vendor || _('unknown vendor')) + ' · ' + typeLabel(d.device_type))
						: '',
					aliasNote
				]),
				E('td', { 'class': 'cb-mono' }, d.ip || '-'),
				E('td', { 'class': 'cb-mono cb-hide-sm' }, d.mac),
				E('td', { 'class': 'cb-drop cb-hide-sm' }, d.first_seen
					? ((d.first_assumed ? '≈ ' : '') + fmtTime(d.first_seen))
					: '-'),
				E('td', { 'class': 'cb-hide-sm' }, d.blocked ? [ dropText, E('br'), E('span', { 'class': 'cb-drop' }, fmtTime(d.blocked_at)) ] : ''),
				E('td', { 'style': 'text-align:right;white-space:nowrap' }, [ mergeBtn, trustBtn, action ])
			]));
		});

		var cnt = document.getElementById('cb-count');
		if (cnt)
			cnt.textContent = (this.devices || []).length + ' ' + _('devices') + ', ' +
				(this.blockedCount || 0) + ' ' + _('blocked');
	},

	render: function (data) {
		this.devices = (data && data.devices) || [];
		this.blockedCount = (data && data.blocked_count) || 0;
		this.ips = (data && data.ips) || [];
		this.ipCount = (data && data.ip_count) || 0;
		this.auto = (data && data.auto) || {};
		this.logs = (data && data.logs) || [];
		this.sched = (data && data.sched) || [];
		this.logQuery = '';
		this.logKind = 'all';
		this.logResult = 'all';
		this.query = '';
		this.ipQuery = '';
		this.tab = 'overview';
		var self = this;

		var search = E('input', {
			'type': 'text',
			'placeholder': _('Filter by name, IP or MAC'),
			'value': this.query || '',
			'input': function (ev) {
				self.query = ev.target.value;
				self.renderTable();
			}
		});

		var rescanBtn = E('button', { 'class': 'cb-btn', 'click': function (ev) { self.handleProbe(ev); } },
			_('Rescan devices'));
		var unblockAllBtn = E('button', { 'class': 'cb-btn', 'click': function (ev) { self.handleUnblockAll(ev); } },
			_('Unblock all'));

		var ipSearch = E('input', {
			'type': 'text',
			'placeholder': _('Filter by IP or note'),
			'input': function (ev) {
				self.ipQuery = ev.target.value;
				self.renderIps();
			}
		});

		var ipInput = E('input', {
			'type': 'text',
			'class': 'cb-ip',
			'id': 'cb-ip-input',
			'placeholder': '1.2.3.4  /  1.2.3.0/24  /  2001:db8::1',
			'keydown': function (ev) { if (ev.key === 'Enter') self.handleIpAdd(ev); }
		});
		var ipNote = E('input', {
			'type': 'text',
			'class': 'cb-note',
			'id': 'cb-ip-note',
			'placeholder': _('Note (optional)'),
			'keydown': function (ev) { if (ev.key === 'Enter') self.handleIpAdd(ev); }
		});

		var tabBtn = function (name, label) {
			var btn = E('button', {
				'class': 'cb-tab' + (name === 'overview' ? ' active' : ''),
				'id': 'cb-tab-' + name,
				'click': function () { self.switchTab(name); }
			}, label);
			// 健康项失败时给对应 tab 打红点,不用点开就知道
			if (name === 'overview' || name === 'settings') {
				self._alertTabs = self._alertTabs || [];
				self._alertTabs.push([ name, btn ]);
			}
			return btn;
		};

		var autoPane = E('div', {
			'class': 'cb-pane',
			'id': 'cb-pane-auto'
		}, [
			E('div', { 'class': 'cb-card' }, [
				E('div', { 'class': 'cb-card-head' }, [
					E('span', { 'class': 'cb-dot' }),
					E('span', {}, _('Automatic protection'))
				]),
				E('div', { 'class': 'cb-card-body' }, [
					E('div', { 'class': 'cb-auto-body', 'id': 'cb-auto-body' }),
					E('div', { 'class': 'cb-card-hint', 'style': 'margin-top:.75rem' },
						_('A source is blocked once it produces the selected failures often enough within the window. Detection is live, not polled.'))
				])
			])
		]);

		var backupPane = E('div', {
			'class': 'cb-pane',
			'id': 'cb-pane-backup'
		}, [
			E('div', { 'class': 'cb-card' }, [
				E('div', { 'class': 'cb-card-head' }, [
					E('span', { 'class': 'cb-dot' }),
					E('span', {}, _('Backup and restore'))
				]),
				E('div', { 'class': 'cb-card-body' }, [
					E('div', { 'class': 'cb-card-hint', 'style': 'margin-bottom:.7rem' },
						_('Everything that survives a reflash: block lists, schedules, groups, ports, whitelist, feeds, protection settings, the app library and the addresses it learned. Traffic counters and caches rebuild themselves and are not included.')),
					E('div', { 'style': 'display:flex;gap:.5rem;flex-wrap:wrap' }, [
						E('button', { 'class': 'cb-btn cb-btn-primary',
							'click': function (ev) { self.handleExport(ev); } }, _('Download backup')),
						E('label', { 'class': 'cb-btn', 'style': 'cursor:pointer;margin:0' }, [
							_('Choose file'),
							E('input', {
								'type': 'file', 'accept': '.json,application/json',
								'style': 'display:none',
								'change': function (ev) { self.handleImportFile(ev); }
							})
						]),
						E('button', { 'class': 'cb-btn',
							'click': function (ev) { self.handleImport(ev); } }, _('Import'))
					]),
					E('textarea', {
						'id': 'cb-backup-text',
						'style': 'width:100%;height:9rem;margin-top:.7rem;font-family:var(--font-mono);font-size:.75rem;' +
							'padding:.5rem;border-radius:.3rem;border:1px solid var(--hairline);background:var(--surface-sunken);color:inherit',
						'placeholder': _('Paste a backup here, then press Import')
					})
				])
			])
		]);

		var dashPane = E('div', {
			'class': 'cb-pane active',
			'id': 'cb-pane-dash'
		}, [
			E('p', { 'style': 'opacity:.75;margin:.25rem 0 1rem' },
				_('Overview only. No device addresses are shown here; open the Devices tab for the full inventory.')),
			E('div', { 'id': 'cb-dash-body' })
		]);

		var devicesPane = E('div', {
			'class': 'cb-pane',
			'id': 'cb-pane-devices'
		}, [
E('div', { 'class': 'cb-card' }, [
				E('div', { 'class': 'cb-card-head' }, [
					E('span', { 'class': 'cb-dot' }), E('span', {}, _('Rate rules'))
				]),
				E('div', { 'class': 'cb-card-body' }, [
					E('p', { 'class': 'cb-note' },
						_('Sets a DSCP class on matching traffic; qosmate turns that into an hfsc class. Choosing block drops the traffic outright, which also works for proxied apps because the drop happens before Clash can pick the packet up. Leave the device empty to cover every device.')),
					E('div', { 'class': 'cb-actions', 'style': 'margin-bottom:.6rem' }, [
						E('select', { 'id': 'cb-qos-dev', 'class': 'cb-sel' }, []),
						E('select', { 'id': 'cb-qos-app', 'class': 'cb-sel' }, []),
						E('select', { 'id': 'cb-qos-dscp', 'class': 'cb-sel' }, [
							E('option', { 'value': 'cs1' }, _('lowest (cs1)')),
							E('option', { 'value': 'af11' }, _('low (af11)')),
							E('option', { 'value': 'cs0' }, _('normal (cs0)')),
							E('option', { 'value': 'cs4' }, _('high (cs4)')),
							E('option', { 'value': 'ef' }, _('highest (ef)')),
							E('option', { 'value': 'block' }, _('block entirely'))
						]),
						E('button', { 'class': 'cb-btn cb-btn-primary',
							'click': function (ev) { self.handleQosAdd(ev); } }, _('Add rule'))
					]),
					E('div', { 'class': 'cb-tablewrap' }, [
						E('table', { 'class': 'cb-table' }, [
							E('thead', {}, E('tr', {}, [
								E('th', {}, _('Device')),
								E('th', {}, _('App')),
								E('th', {}, _('Class')),
								E('th', { 'class': 'cb-hide-sm' }, _('Addresses')),
								E('th', { 'style': 'text-align:right' }, _('Action'))
							])),
							E('tbody', { 'id': 'cb-qos-tbody' })
						])
					])
				])
			]),
			E('p', { 'style': 'opacity:.75;margin:.25rem 0 1rem' },
				_('Blocked devices lose all traffic through this router: Internet, DNS, DHCP and gateway services. Their packets are dropped at every interface.')),
			E('div', { 'class': 'cb-toolbar' }, [
				search,
				rescanBtn,
				unblockAllBtn,
				E('span', { 'class': 'cb-count', 'id': 'cb-count' }, '')
			]),
			E('table', { 'class': 'cb-table' }, [
				E('thead', {}, E('tr', {}, [
					E('th', {}, _('Status')),
					E('th', {}, _('Name')),
					E('th', {}, _('IP')),
					E('th', { 'class': 'cb-hide-sm' }, _('MAC')),
					E('th', { 'class': 'cb-hide-sm' }, _('First seen')),
					E('th', { 'class': 'cb-hide-sm' }, _('Dropped')),
					E('th', { 'style': 'text-align:right' }, _('Action'))
				])),
				E('tbody', { 'id': 'cb-tbody' })
			]),
			E('div', { 'class': 'cb-card', 'style': 'margin-top:1.2rem' }, [
				E('div', { 'class': 'cb-card-head' }, [
					E('span', { 'class': 'cb-dot' }),
					E('span', {}, _('Port restrictions'))
				]),
				E('div', { 'class': 'cb-card-body' }, [
					E('div', { 'class': 'cb-card-hint', 'style': 'margin-bottom:.7rem' },
						_('Let a device use the internet but block specific local services, e.g. keep IoT off SMB/445 or telnet.')),
					E('div', { 'class': 'cb-sched-form', 'style': 'padding:0;border:none;background:none;margin-bottom:.8rem' }, [
						E('label', {}, [ E('span', {}, _('Device')),
							E('select', { 'id': 'cb-port-mac', 'style': 'min-width:14rem' }) ]),
						E('label', {}, [ E('span', {}, _('Protocol')),
							E('select', { 'id': 'cb-port-proto' }, [
								E('option', { 'value': 'tcp' }, 'tcp'),
								E('option', { 'value': 'udp' }, 'udp') ]) ]),
						E('label', {}, [ E('span', {}, _('Port')),
							E('input', { 'type': 'number', 'id': 'cb-port-num', 'min': '1', 'max': '65535', 'value': '445',
								'style': 'width:6rem;padding:.35rem .5rem;border-radius:.3rem;border:1px solid var(--hairline);background:var(--surface-sunken);color:inherit' }) ]),
						E('label', {}, [ E('span', {}, _('Note')),
							E('input', { 'type': 'text', 'id': 'cb-port-note', 'placeholder': _('optional'),
								'style': 'width:10rem;padding:.35rem .5rem;border-radius:.3rem;border:1px solid var(--hairline);background:var(--surface-sunken);color:inherit' }) ]),
						E('label', {}, [ E('span', {}, _('Preset')),
							E('select', { 'id': 'cb-port-preset' }, [
								E('option', { 'value': 'iot' }, 'IoT'),
								E('option', { 'value': 'smb' }, 'SMB'),
								E('option', { 'value': 'remote' }, 'Remote')
							]) ]),
						E('button', { 'class': 'cb-btn cb-btn-primary',
							'click': function (ev) { self.handlePortAdd(ev); } }, _('Block port')),
						E('button', { 'class': 'cb-btn',
							'click': function (ev) { self.handlePortPreset(ev); } }, _('Apply preset'))
					]),
					E('table', { 'class': 'cb-table' }, [
						E('thead', {}, E('tr', {}, [
							E('th', {}, _('Device')), E('th', {}, _('Port')),
							E('th', {}, _('Note')), E('th', { 'style': 'text-align:right' }, _('Action'))
						])),
						E('tbody', { 'id': 'cb-port-tbody' })
					])
				])
			])
		]);

		var ipsPane = E('div', {
			'class': 'cb-pane',
			'id': 'cb-pane-ips'
		}, [
			E('p', { 'style': 'opacity:.75;margin:.25rem 0 1rem' },
				_('Blocked addresses cannot be reached from your LAN, and cannot reach it. Both directions are dropped. CIDR ranges are supported.')),
			,
			E('div', { 'style': 'display:flex;gap:.35rem;flex-wrap:wrap;margin-bottom:.6rem' }, [
				E('span', { 'style': 'font-size:.8rem;opacity:.6;align-self:center' }, _('Quick fill:')),
				E('button', {
					'class': 'cb-btn', 'style': 'font-size:.75rem;padding:.15rem .5rem',
					'click': function () { document.getElementById('cb-ip-input').value = '1.1.1.1'; }
				}, '1.1.1.1'),
				E('button', {
					'class': 'cb-btn', 'style': 'font-size:.75rem;padding:.15rem .5rem',
					'click': function () { document.getElementById('cb-ip-input').value = '8.8.8.8'; }
				}, '8.8.8.8'),
				E('button', {
					'class': 'cb-btn', 'style': 'font-size:.75rem;padding:.15rem .5rem',
					'click': function () { document.getElementById('cb-ip-input').value = '1.2.3.0/24'; document.getElementById('cb-ip-input').focus(); }
				}, '1.2.3.0/24')
			]),
			E('div', { 'class': 'cb-ipform' }, [
				ipInput,
				ipNote,
				E('button', { 'class': 'cb-btn', 'click': function (ev) { self.handleIpAdd(ev); } }, _('Block IP')),
				E('button', { 'class': 'cb-btn cb-btn-danger', 'click': function (ev) { self.handleIpFlush(ev); } }, _('Unblock all'))
			]),
			E('div', { 'class': 'cb-ipcats', 'id': 'cb-ip-cats' }, []),
			E('div', { 'class': 'cb-toolbar' }, [
				ipSearch,
				E('span', { 'class': 'cb-count', 'id': 'cb-ip-count' }, '')
			]),
			E('table', { 'class': 'cb-table' }, [
				E('thead', {}, E('tr', {}, [
					E('th', {}, _('Address')),
					E('th', { 'class': 'cb-hide-sm' }, _('Region')),
					E('th', {}, _('Note')),
					E('th', {}, _('Dropped')),
					E('th', {}, _('Since')),
					E('th', { 'style': 'text-align:right' }, _('Action'))
				])),
				E('tbody', { 'id': 'cb-ip-tbody' })
			]),
			E('div', { 'class': 'cb-card', 'style': 'margin-top:1rem' }, [
				E('div', { 'class': 'cb-card-head' }, [
					E('span', { 'class': 'cb-dot' }),
					E('span', {}, _('Domain blocking')),
					E('span', { 'class': 'cb-count', 'id': 'cb-domain-count', 'style': 'margin-left:auto' }, '')
				]),
				E('div', { 'class': 'cb-card-body' }, [
					E('p', { 'class': 'cb-note' },
						_('Domains are answered with 0.0.0.0 and :: by dnsmasq, so the whole LAN is covered without touching the firewall. Feed entries that are hostnames land here instead of the address list.')),
					E('div', { 'class': 'cb-actions', 'style': 'margin-bottom:.6rem' }, [
						E('input', { 'type': 'text', 'id': 'cb-domain-input', 'class': 'cb-input',
							'placeholder': 'ads.example.com', 'style': 'max-width:16rem' }),
						E('button', { 'class': 'cb-btn cb-btn-primary',
							'click': function (ev) { self.handleDomainAdd(ev); } }, _('Block domain')),
						E('label', { 'class': 'cb-chip', 'style': 'margin:0' }, [
							E('input', { 'type': 'checkbox', 'id': 'cb-domain-enabled',
								'change': function (ev) { self.handleDomainToggle(ev.target.checked); } }),
							E('span', {}, _('enabled'))
						])
					]),
					E('div', { 'class': 'cb-proxylist', 'id': 'cb-domain-list' }, [])
				])
			])
		]);

		var feedsPane = E('div', {
			'class': 'cb-pane',
			'id': 'cb-pane-feeds'
		}, [
			E('p', { 'style': 'opacity:.75;margin:.25rem 0 1rem' },
				_('Lists pulled from the internet. Each one declares what it feeds: an IP list becomes blocked addresses, a domain list becomes DNS blocks, an app list becomes the signatures used to recognise an app.')),
			E('div', { 'class': 'cb-note', 'style': 'margin:0 0 1rem;line-height:1.7' }, [
				E('div', {}, _('IP list') + ' — ' + _('one address or CIDR per line; # comments, CSV columns and Spamhaus ; tails are tolerated')),
				E('div', {}, _('Domain list') + ' — ' + _('one hostname per line; # comments ignored')),
				E('div', {}, _('App signatures') + ' — ' + _('OAF format v3.0: id name:[proto;sport;dport;host;request;dict]')),
				E('div', {}, _('Geosite bundle') + ' — ' + _('a v2ray .dat file holding every category at once; routing categories are skipped'))
			]),
E('div', { 'class': 'cb-card' }, [
				E('div', { 'class': 'cb-card-head' }, [
					E('span', { 'class': 'cb-dot' }),
					E('span', {}, _('Blocklist subscriptions'))
				]),
				E('div', { 'class': 'cb-card-body' }, [
					E('div', { 'class': 'cb-card-hint', 'style': 'margin-bottom:.7rem' },
						_('Pull public blocklists on demand and merge them here. Entries are tagged with their feed so removing the feed also removes them.')),
					E('div', { 'class': 'cb-sched-form', 'style': 'padding:0;border:none;background:none;margin-bottom:.6rem' }, [
						E('label', {}, [ E('span', {}, _('Name')),
							E('input', { 'type': 'text', 'id': 'cb-feed-name', 'placeholder': _('optional'),
								'style': 'width:9rem;padding:.35rem .5rem;border-radius:.3rem;border:1px solid var(--hairline);background:var(--surface-sunken);color:inherit' }) ]),
						E('label', {}, [ E('span', {}, _('Type')),
							E('select', { 'id': 'cb-feed-kind', 'class': 'cb-sel' }, [
								E('option', { 'value': 'ip' }, _('IP list')),
								E('option', { 'value': 'domain' }, _('Domain list')),
								E('option', { 'value': 'app' }, _('App signatures')),
								E('option', { 'value': 'geosite' }, _('Geosite bundle'))
							]) ]),
						E('label', {}, [ E('span', {}, _('List URL')),
							E('input', { 'type': 'text', 'id': 'cb-feed-url', 'placeholder': 'https://host/list.netset',
								'style': 'width:18rem;padding:.35rem .5rem;border-radius:.3rem;border:1px solid var(--hairline);background:var(--surface-sunken);color:inherit' }) ]),
						E('button', { 'class': 'cb-btn',
							'click': function (ev) { self.handleFeedAdd(ev); } }, _('Add feed')),
						E('input', { 'type': 'file', 'id': 'cb-feed-file', 'style': 'max-width:14rem' }),
						E('button', { 'class': 'cb-btn',
							'click': function (ev) { self.handleFeedUpload(ev); } }, _('Upload file'))
					]),
					E('div', { 'class': 'cb-tablewrap' }, [
						E('table', { 'class': 'cb-table' }, [
							E('thead', {}, E('tr', {}, [
								E('th', {}, _('Name')), E('th', { 'class': 'cb-hide-sm' }, _('Type')),
							E('th', { 'class': 'cb-hide-sm' }, _('Feeds into')), E('th', {}, _('Imported')),
								E('th', {}, _('Refresh')), E('th', {}, _('Last fetch')),
								E('th', { 'style': 'text-align:right' }, _('Action'))
							])),
							E('tbody', { 'id': 'cb-feed-tbody' })
						])
					])
				])
			])
		]);

		var appsPane = E('div', {
			'class': 'cb-pane',
			'id': 'cb-pane-apps'
		}, [
			E('p', { 'style': 'opacity:.75;margin:.25rem 0 1rem' },
				_('Traffic attributed to applications. Proxied flows are named by the hostname Clash reports; everything else is matched from the router flow table by port or address range.')),
			E('div', { 'class': 'cb-card' }, [
				E('div', { 'class': 'cb-card-head' }, [
					E('span', { 'class': 'cb-dot' }),
					E('span', {}, _('Traffic by app')),
					E('span', { 'style': 'margin-left:auto;display:flex;gap:.3rem' },
						[ [ 'today', _('Today') ], [ 'yesterday', _('Yesterday') ],
						  [ 'week', _('Last 7 days') ] ].map(function (p) {
							return E('button', {
								'class': 'cb-btn cb-range' + (p[0] === 'today' ? ' cb-range-on' : ''),
								'click': function (ev) {
									ev.currentTarget.parentNode.querySelectorAll('.cb-range')
										.forEach(function (b) { b.classList.remove('cb-range-on'); });
									ev.currentTarget.classList.add('cb-range-on');
									self.refreshAppStats(p[0]);
								}
							}, p[1]);
						}))
				]),
				E('div', { 'class': 'cb-card-body' }, [
					E('div', { 'class': 'cb-tablewrap' }, [
						E('table', { 'class': 'cb-table' }, [
							E('thead', {}, E('tr', {}, [
								E('th', {}, _('App')),
								E('th', { 'class': 'cb-hide-sm' }, _('Class')),
								E('th', { 'class': 'cb-hide-sm' }, _('Rules')),
								E('th', { 'style': 'text-align:right' }, _('Traffic'))
							])),
							E('tbody', { 'id': 'cb-app-tbody' })
						])
					]),
					E('div', { 'class': 'cb-actions', 'style': 'margin-top:.7rem' }, [
						E('button', { 'class': 'cb-btn', 'click': function (ev) { self.refreshAppStats(ev); } }, _('Refresh')),
						E('button', { 'class': 'cb-btn cb-btn-danger', 'click': function (ev) { self.handleAppReset(ev); } }, _('Reset counters'))
					])
				])
			]),
			E('div', { 'class': 'cb-card' }, [
				E('div', { 'class': 'cb-card-head' }, [
					E('span', { 'class': 'cb-dot' }), E('span', {}, _('Proxy quota')),
					E('span', { 'id': 'cb-proxy-total', 'class': 'cb-count', 'style': 'margin-left:auto' }, ''),
					E('span', { 'style': 'display:flex;gap:.3rem;margin-left:.6rem' },
						[ [ 10, '10' ], [ 20, '20' ], [ 30, '30' ], [ 0, _('All') ] ].map(function (p) {
							return E('button', {
								'class': 'cb-btn cb-range' + (p[0] === (self.proxyTop === undefined ? 10 : self.proxyTop) ? ' cb-range-on' : ''),
								'click': function (ev) {
									ev.currentTarget.parentNode.querySelectorAll('.cb-range')
										.forEach(function (b) { b.classList.remove('cb-range-on'); });
									ev.currentTarget.classList.add('cb-range-on');
									self.proxyTop = p[0];
									self.renderAppStats();
								}
							}, p[1]);
						}))
				]),
				E('div', { 'class': 'cb-card-body' }, [
					E('div', { 'style': 'margin-bottom:.6rem' }, [
						E('input', {
							'class': 'cb-input', 'type': 'text', 'placeholder': _('Filter domains, nodes or groups'),
							'value': this.proxyFilter || '',
							'input': function (ev) { self.proxyFilter = ev.currentTarget.value; self.renderAppStats(); }
						})
					]),
					E('div', { 'class': 'cb-tablewrap' }, [
						E('table', { 'class': 'cb-table' }, [
							E('thead', {}, E('tr', {}, [
								E('th', {}, _('Domain')),
								E('th', { 'class': 'cb-hide-sm' }, _('Route')),
								E('th', { 'style': 'text-align:right;width:9rem' }, _('Traffic'))
							])),
							E('tbody', { 'id': 'cb-proxy-tbody' })
						])
					]),
					E('div', { 'style': 'margin-top:.5rem;font-size:.78rem;opacity:.65' },
						_('Counted from the routing decision Clash already made. Nothing is added to the packet path.'))
				])
			]),
			E('div', { 'class': 'cb-card' }, [
				E('div', { 'class': 'cb-card-head' }, [
					E('span', { 'class': 'cb-dot' }), E('span', {}, _('Blocked domains')),
					E('span', { 'class': 'cb-count', 'id': 'cb-dh-state', 'style': 'margin-left:auto' }, '')
				]),
				E('div', { 'class': 'cb-card-body' }, [
					E('div', { 'class': 'cb-actions', 'style': 'margin-bottom:.5rem' }, [
						E('button', { 'class': 'cb-btn',
							'click': function (ev) { self.handleDomainLog(ev); } }, _('Enable DNS logging')),
						E('span', { 'class': 'cb-note' },
							_('Hits are only visible in dnsmasq\'s query log, which records one line per query.'))
					]),
					E('div', { 'class': 'cb-tablewrap' }, [
						E('table', { 'class': 'cb-table' }, [
							E('thead', {}, E('tr', {}, [
								E('th', {}, _('Domain')),
								E('th', {}, _('Device'))
							])),
							E('tbody', { 'id': 'cb-dh-tbody' })
						])
					])
				])
			]),
			E('div', { 'class': 'cb-card' }, [
				E('div', { 'class': 'cb-card-head' }, [
					E('span', { 'class': 'cb-dot' }), E('span', {}, _('By device'))
				]),
				E('div', { 'class': 'cb-card-body' }, E('div', { 'id': 'cb-app-dev', 'class': 'cb-dash-rows' }))
			]),
			E('div', { 'class': 'cb-card' }, [
				E('div', { 'class': 'cb-card-head' }, [
					E('span', { 'class': 'cb-dot' }), E('span', {}, _('Signature library'))
				]),
				E('div', { 'class': 'cb-card-body' }, [
					E('p', { 'class': 'cb-note' },
						_('Paste a feature library (OAF format v3.0) to import it. Entries are matched by hostname, address range or a distinctive port; signatures that only name port 80/443 are skipped because they would claim the whole web.')),
					E('textarea', {
						'id': 'cb-app-import', 'class': 'cb-import',
						'rows': '6', 'placeholder': '#class game 2 游戏\n2001 王者荣耀:[tcp;;6000-9000;;;]'
					}),
					E('div', { 'class': 'cb-actions', 'style': 'margin-top:.6rem' }, [
						E('button', { 'class': 'cb-btn cb-btn-primary',
							'click': function (ev) { self.handleAppImport(ev); } }, _('Import')),
						E('span', { 'class': 'cb-count', 'id': 'cb-app-count' }, '')
					]),
					E('div', { 'class': 'cb-actions', 'style': 'margin:.6rem 0' }, [
						E('input', { 'type': 'text', 'id': 'cb-app-url', 'class': 'cb-input',
							'placeholder': 'https://raw.githubusercontent.com/v2fly/domain-list-community/master/data/bilibili',
							'style': 'flex:1 1 18rem' }),
						E('input', { 'type': 'text', 'id': 'cb-app-urlname', 'class': 'cb-input',
							'placeholder': _('app name'), 'style': 'max-width:10rem' }),
						E('button', { 'class': 'cb-btn cb-btn-primary',
							'click': function (ev) { self.handleAppUrlImport(ev); } }, _('Add from URL'))
					]),
					E('div', { 'class': 'cb-actions', 'style': 'margin-bottom:.5rem' }, [
						E('select', { 'id': 'cb-sig-app', 'class': 'cb-sel',
							'change': function (ev) { self.loadSigs(ev.target.value); } }, []),
						E('span', { 'class': 'cb-count', 'id': 'cb-sig-count' }, '')
					]),
					E('div', { 'class': 'cb-tablewrap' }, [
						E('table', { 'class': 'cb-table' }, [
							E('thead', {}, E('tr', {}, [
								E('th', {}, _('Proto')),
								E('th', {}, _('Port')),
								E('th', {}, _('Host')),
								E('th', {}, _('Fingerprint')),
								E('th', { 'style': 'text-align:right' }, _('Action'))
							])),
							E('tbody', { 'id': 'cb-sig-tbody' })
						])
					])
				])
			]),
			
			E('div', { 'class': 'cb-card' }, [
				E('div', { 'class': 'cb-card-head' }, [
					E('span', { 'class': 'cb-dot' }), E('span', {}, _('Sample traffic')),
					E('span', { 'class': 'cb-count', 'id': 'cb-sample-state', 'style': 'margin-left:auto' }, '')
				]),
				E('div', { 'class': 'cb-card-body' }, [
					E('p', { 'class': 'cb-note' },
						_('Game signatures are not published anywhere, so record them: start a capture, play, then save the flow that appears. Flows are grouped by port and by the first four bytes of the payload.')),
					E('div', { 'class': 'cb-actions', 'style': 'margin-bottom:.6rem' }, [
						E('select', { 'id': 'cb-sample-dur', 'class': 'cb-sel' }, [
							E('option', { 'value': '30' }, '30 s'),
							E('option', { 'value': '60', 'selected': 'selected' }, '60 s'),
							E('option', { 'value': '120' }, '120 s')
						]),
						E('button', { 'class': 'cb-btn cb-btn-primary', 'id': 'cb-sample-start',
							'click': function (ev) { self.handleSampleStart(ev); } }, _('Start sampling')),
						E('button', { 'class': 'cb-btn', 'id': 'cb-sample-stop',
							'click': function (ev) { self.handleSampleStop(ev); } }, _('Stop')),
						E('span', { 'id': 'cb-sample-live', 'style': 'align-self:center;font-size:.8rem' }, '')
					]),
					E('div', { 'class': 'cb-tablewrap' }, [
						E('table', { 'class': 'cb-table' }, [
							E('thead', {}, E('tr', {}, [
								E('th', {}, _('Proto')),
								E('th', {}, _('Port')),
								E('th', {}, _('First bytes')),
								E('th', { 'class': 'cb-hide-sm' }, _('Hits')),
								E('th', { 'class': 'cb-hide-sm' }, _('Peer')),
								E('th', { 'style': 'text-align:right' }, _('Action'))
							])),
							E('tbody', { 'id': 'cb-sample-tbody' })
						])
					])
				])
			])
		]);

		var logsPane = E('div', {
			'class': 'cb-pane',
			'id': 'cb-pane-logs'
		}, [
			E('p', { 'style': 'opacity:.75;margin:.25rem 0 1rem' },
				_('Every successful and failed login through SSH or LuCI, newest first. Kept in memory-backed storage, capped at 500 entries.')),
			E('div', { 'class': 'cb-log-filters' }, [
				E('input', {
					'type': 'text',
					'placeholder': _('Filter by IP, user or detail'),
					'input': function (ev) { self.logQuery = ev.target.value; self.renderLogs(); }
				}),
				E('select', {
					'change': function (ev) { self.logKind = ev.target.value; self.renderLogs(); }
				}, [
					E('option', { 'value': 'all' }, _('All sources')),
					E('option', { 'value': 'ssh' }, 'SSH'),
					E('option', { 'value': 'web' }, 'LuCI')
				]),
				E('select', {
					'change': function (ev) { self.logResult = ev.target.value; self.renderLogs(); }
				}, [
					E('option', { 'value': 'all' }, _('All results')),
					E('option', { 'value': 'ok' }, _('Success only')),
					E('option', { 'value': 'fail' }, _('Failures only'))
				]),
				E('span', { 'class': 'cb-count', 'id': 'cb-log-count' }, ''),
				E('button', { 'class': 'cb-btn cb-btn-danger',
					'click': function (ev) { self.handleLogClear(ev); } }, _('Clear log'))
			]),
			E('div', { 'class': 'cb-tablewrap' }, [
				E('table', { 'class': 'cb-table cb-log' }, [
					E('thead', {}, E('tr', {}, [
						E('th', {}, _('Time')),
						E('th', {}, _('Result')),
						E('th', {}, _('Source')),
						E('th', { 'class': 'cb-hide-sm' }, _('Auth')),
						E('th', {}, _('IP')),
						E('th', { 'class': 'cb-hide-sm' }, _('User')),
						E('th', {}, _('Detail'))
					])),
					E('tbody', { 'id': 'cb-log-tbody' })
				])
			])
		]);

		var schedPane = E('div', {
			'class': 'cb-pane',
			'id': 'cb-pane-sched'
		}, [
			E('p', { 'style': 'opacity:.75;margin:.25rem 0 1rem' },
				_('Block a device on a weekly schedule. A window that ends before it starts crosses midnight, and its days refer to the day the window begins.')),
			E('div', { 'class': 'cb-sched-form' }, [
				E('label', {}, [
					E('span', {}, _('Device')),
					E('select', { 'id': 'cb-sched-mac', 'style': 'min-width:14rem' })
				]),
				E('label', {}, [
					E('span', {}, _('Days')),
					E('div', { 'class': 'cb-days', 'id': 'cb-sched-days' },
						['S','M','T','W','T','F','S'].map(function (ch, i) {
							return E('div', { 'class': 'cb-dchip', 'data-day': String(i),
								'click': function (ev) { ev.currentTarget.classList.toggle('on'); } }, ch);
						}))
				]),
				E('label', {}, [
					E('span', {}, _('From')),
					E('input', { 'type': 'time', 'id': 'cb-sched-start', 'value': '21:00' })
				]),
				E('label', {}, [
					E('span', {}, _('To')),
					E('input', { 'type': 'time', 'id': 'cb-sched-stop', 'value': '07:00' })
				]),
				E('button', { 'class': 'cb-btn cb-btn-primary',
					'click': function (ev) { self.handleSchedAdd(ev); } }, _('Add rule'))
			]),
			E('table', { 'class': 'cb-table' }, [
				E('thead', {}, E('tr', {}, [
					E('th', {}, _('Device')),
					E('th', {}, _('Days')),
					E('th', {}, _('Window')),
					E('th', {}, _('Status')),
					E('th', { 'style': 'text-align:right' }, _('Action'))
				])),
				E('tbody', { 'id': 'cb-sched-tbody' })
			]),
			E('div', { 'class': 'cb-card', 'style': 'margin-top:1.2rem' }, [
				E('div', { 'class': 'cb-card-head' }, [
					E('span', { 'class': 'cb-dot' }),
					E('span', {}, _('Groups and curfew'))
				]),
				E('div', { 'class': 'cb-card-body' }, [
					E('div', { 'class': 'cb-card-hint', 'style': 'margin-bottom:.7rem' },
						_('Group devices (family / kids / IoT) and block them all at once. Curfew blocks the group until 08:00.')),
					E('div', { 'class': 'cb-sched-form', 'style': 'padding:0;border:none;background:none;margin-bottom:.6rem' }, [
						E('label', {}, [ E('span', {}, _('New group')),
							E('input', { 'type': 'text', 'id': 'cb-group-name', 'placeholder': _('e.g. Kids'),
								'style': 'width:12rem;padding:.35rem .5rem;border-radius:.3rem;border:1px solid var(--hairline);background:var(--surface-sunken);color:inherit' }) ]),
						E('button', { 'class': 'cb-btn',
							'click': function (ev) { self.handleGroupAdd(ev); } }, _('Add group'))
					]),
					E('div', { 'id': 'cb-sched-groups' })
				])
			])
		]);

		var notifyPane = E('div', {
			'class': 'cb-pane',
			'id': 'cb-pane-notify'
		}, [
			E('p', { 'style': 'opacity:.75;margin:.25rem 0 1rem' },
				_('Send a message when something happens. Every channel is tried independently; a broken one never blocks the action.')),
			E('div', { 'class': 'cb-sched-form' }, [
				E('label', {}, [ E('span', {}, _('Type')),
					E('select', { 'id': 'cb-nt-type' }, [
						E('option', { 'value': 'telegram' }, 'Telegram'),
						E('option', { 'value': 'bark' }, 'Bark'),
						E('option', { 'value': 'webhook' }, _('Webhook'))
					]) ]),
				E('label', {}, [ E('span', {}, _('Name')),
					E('input', { 'type': 'text', 'id': 'cb-nt-name', 'placeholder': _('optional'),
						'style': 'width:9rem;padding:.35rem .5rem;border-radius:.3rem;border:1px solid var(--hairline);background:var(--surface-sunken);color:inherit' }) ]),
				E('label', {}, [ E('span', {}, _('URL (bark / webhook)')),
					E('input', { 'type': 'text', 'id': 'cb-nt-url', 'placeholder': 'https://api.day.app/KEY',
						'style': 'width:16rem;padding:.35rem .5rem;border-radius:.3rem;border:1px solid var(--hairline);background:var(--surface-sunken);color:inherit' }) ]),
				E('label', {}, [ E('span', {}, _('Bot token (telegram)')),
					E('input', { 'type': 'text', 'id': 'cb-nt-token',
						'style': 'width:12rem;padding:.35rem .5rem;border-radius:.3rem;border:1px solid var(--hairline);background:var(--surface-sunken);color:inherit' }) ]),
				E('label', {}, [ E('span', {}, _('Chat ID (telegram)')),
					E('input', { 'type': 'text', 'id': 'cb-nt-chat',
						'style': 'width:8rem;padding:.35rem .5rem;border-radius:.3rem;border:1px solid var(--hairline);background:var(--surface-sunken);color:inherit' }) ]),
				E('button', { 'class': 'cb-btn cb-btn-primary',
					'click': function (ev) { self.handleNotifyAdd(ev); } }, _('Add channel'))
			]),
			E('div', { 'style': 'margin:.2rem 0 .5rem;font-size:.8rem;color:var(--text-muted)' }, _('Notify me when:')),
			E('div', { 'class': 'cb-days', 'id': 'cb-nt-events', 'style': 'margin-bottom:1rem' }),
			E('button', { 'class': 'cb-btn', 'style': 'margin-bottom:1rem',
				'click': function (ev) { self.handleNotifyEvents(ev); } }, _('Save events')),
			E('table', { 'class': 'cb-table' }, [
				E('thead', {}, E('tr', {}, [
					E('th', {}, _('Type')), E('th', {}, _('Name')),
					E('th', {}, _('Target')), E('th', { 'style': 'text-align:right' }, _('Action'))
				])),
				E('tbody', { 'id': 'cb-nt-tbody' })
			])
		]);

		var healthPane = E('div', {
			'class': 'cb-pane',
			'id': 'cb-pane-health'
		}, [
			E('p', { 'style': 'opacity:.75;margin:.25rem 0 1rem' },
				_('Live checks on the parts that silently fail: the watcher process, the log stream it reads, and whether saved state actually reached the kernel.')),
			E('div', { 'class': 'cb-health-head' }, [
				E('span', { 'id': 'cb-health-head', 'style': 'display:flex;gap:.5rem;align-items:center' }),
				E('button', { 'class': 'cb-btn', 'style': 'margin-left:auto',
					'click': function (ev) { self.refreshHealth(); } }, _('Re-run')),
				E('button', { 'class': 'cb-btn',
					'click': function (ev) { self.handleSync(ev); } }, _('Sync to kernel'))
			]),
			E('div', { 'class': 'cb-checks', 'id': 'cb-health-body' })
		]);

		var root = E('div', { 'class': 'cb-wrap' }, [
			E('div', { 'class': 'cb-strip', 'id': 'cb-status-strip', 'hidden': 'hidden' }),
			E('style', {}, STYLE),
			E('h2', {}, _('LAN Guard')),
			E('div', { 'class': 'cb-tabs' }, [
				tabBtn('overview', _('Overview')),
				tabBtn('devices', _('Devices')),
				tabBtn('apps', _('Traffic')),
				tabBtn('ips', _('Policy')),
				tabBtn('feeds', _('Feeds')),
				tabBtn('logs', _('Log')),
				tabBtn('settings', _('Settings'))
			]),
			dashPane,
			devicesPane,
			ipsPane,
			appsPane,
			feedsPane,
			autoPane,
			backupPane,
			logsPane,
			schedPane,
			notifyPane,
			healthPane
		]);

		window.setTimeout(function () {
			// skeletons first so the page is never blank
			self.renderDash();
			self.renderTable();
			self.renderAuto();
			self.renderLogs();
			self.renderSched();
			self.renderNotify();
			self.renderPorts();
			self.renderGroups();
			self.renderFeeds();
			self.renderTrend();

			// the visible tab streams in; the device list is prefetched right
			// after so switching to it is instant, while the two heavy panes
			// (addresses, log) stay lazy until they are opened
			self.refreshDash().then(function () {
				window.setTimeout(function () { self.refresh(); }, 30);
			});
		}, 0);

		poll.add(function () {
			// a hidden tab has no business polling
			if (document.hidden) return;
			if (self.tab === 'overview') return self.refreshDash();
			if (self.tab === 'ips') return self.refreshIps();
			if (self.tab === 'logs') return self.refreshLogs();
			if (self.tab === 'policy') return self.refreshSched();
			if (self.tab === 'apps') {
				// 账本是每 60 秒 tick 一次才更新的,15 秒轮询足够,不必每轮都问
				var now = Date.now();
				if (now - (self.appStatsAt || 0) < 15000) return;
				self.appStatsAt = now;
				return self.refreshAppStats();
			}
			if (self.tab === 'settings') return self.refreshNotify();

			return self.refresh();
		}, 10);

		return root;
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
