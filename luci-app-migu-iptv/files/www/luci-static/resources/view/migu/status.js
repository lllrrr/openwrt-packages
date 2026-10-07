'use strict';
'require view';
'require rpc';
'require ui';
'require dom';
'require poll';

// 咪咕直播 —— 状态页
//
// 职责：看运行状态、控服务、拿订阅地址、测频道、看日志。
// 配置项全部在「设置」页，本页不写任何 UCI，避免同一份配置两处维护。

var callStatus = rpc.declare({ object: 'migu', method: 'status', expect: { } });
var callChannels = rpc.declare({ object: 'migu', method: 'channels', expect: { } });
var callRestart = rpc.declare({ object: 'migu', method: 'restart', expect: { } });
var callStart = rpc.declare({ object: 'migu', method: 'start', expect: { } });
var callStop = rpc.declare({ object: 'migu', method: 'stop', expect: { } });
// 注意（实测）：ubus 的参数类型校验很严，后端把 lines 声明为 String，
// 传数字 40 会被 rpcd 直接拒掉（`Invalid argument`，请求根本进不到方法体）。
// 所以这里必须传字符串 '40'，不能传数字。
var LOG_LINES = '40';

var callTest = rpc.declare({
	object: 'migu', method: 'testchannel', params: [ 'pid' ], expect: { }
});
var callLogs = rpc.declare({
	object: 'migu', method: 'logs', params: [ 'lines' ], expect: { }
});

function badge(text, kind) {
	var colors = {
		ok: 'background:#2e7d32',
		err: 'background:#c62828',
		warn: 'background:#ef6c00',
		dim: 'background:#607d8b',
		info: 'background:#1565c0'
	};
	return E('span', {
		'style': 'display:inline-block;padding:2px 10px;border-radius:10px;font-size:12px;' +
			'color:#fff;margin-left:6px;vertical-align:middle;' + (colors[kind] || colors.dim)
	}, [ text ]);
}

function row(label, valueNode, hint) {
	return E('div', {
		'style': 'display:flex;padding:7px 0;border-bottom:1px solid rgba(128,128,128,.18);align-items:center;'
	}, [
		E('div', { 'style': 'flex:0 0 170px;font-weight:600;opacity:.85;' }, [ label ]),
		E('div', { 'style': 'flex:1;min-width:0;word-break:break-all;' }, [ valueNode ]),
		hint ? E('div', { 'style': 'flex:0 0 auto;font-size:12px;opacity:.6;margin-left:10px;' }, [ hint ]) : ''
	]);
}

function mono(s) {
	return E('code', { 'style': 'font-family:monospace;font-size:13px;' }, [ '' + s ]);
}

// 用浏览器当前访问 LuCI 的主机名拼地址，保证点开就能用（而不是 127.0.0.1）
function hostForUrl() {
	var h = window.location.hostname || '';
	if (h.indexOf(':') >= 0 && h.charAt(0) !== '[') h = '[' + h + ']';
	return h || '127.0.0.1';
}

function copyField(value) {
	var input = E('input', {
		'class': 'cbi-input-text',
		'style': 'width:100%;font-family:monospace;font-size:13px;',
		'readonly': 'readonly',
		'value': value,
		'click': function (ev) { ev.target.select(); }
	});
	return input;
}

var RATE_NAMES = {
	'2': _('标清 540p'),
	'3': _('高清 720p'),
	'4': _('蓝光 1080p'),
	'7': _('原画'),
	'9': _('4K')
};

return view.extend({
	load: function () {
		return Promise.all([
			callStatus(),
			callChannels(),
			callLogs(LOG_LINES)
		]);
	},

	render: function (data) {
		var status = data[0] || {};
		var chans = data[1] || {};
		var logs = data[2] || {};

		var host = hostForUrl();
		var port = status.port || 8788;
		var m3uUrl = 'http://' + host + ':' + port + '/m3u';
		var txtUrl = 'http://' + host + ':' + port + '/txt';

		/* ---------------- 服务状态 ---------------- */
		var runningBadge = status.running
			? badge(_('运行中'), 'ok')
			: badge(_('已停止'), 'err');
		var reachBadge = status.reachable
			? badge(_('接口正常'), 'ok')
			: badge(_('接口无响应'), 'warn');
		var enabledBadge = status.enabled
			? badge(_('开机自启'), 'info')
			: badge(_('已禁用'), 'dim');

		var accountNode;
		if (status.account && status.account.present) {
			accountNode = E('span', {}, [
				mono(status.account.userId),
				' ',
				badge(_('已登录'), 'ok'),
				status.account.tokenLength
					? E('span', { 'style': 'opacity:.6;font-size:12px;margin-left:8px;' },
						[ _('令牌') + ' …' + (status.account.tokenTail || '') ])
					: ''
			]);
		} else {
			accountNode = badge(_('游客模式（最高 540p）'), 'warn');
		}

		/* ---------------- 公网访问状态 ---------------- */
		var pubNode;
		if (status.publicAccess) {
			var parts = [ badge(_('公网访问已开启'), 'warn') ];
			if (status.publicTokenSet) {
				parts.push(' ', badge(_('令牌校验（') + (status.publicTokenLength || '?') + _(' 位）'), 'ok'));
			} else {
				parts.push(' ', badge(_('未设令牌（公网可无密码访问）'), 'err'));
			}
			pubNode = E('span', {}, parts);
		} else {
			pubNode = E('span', {}, [
				badge(_('关闭'), 'ok'),
				E('span', { 'style': 'opacity:.6;font-size:12px;margin-left:8px;' },
					[ _('仅局域网可访问') ])
			]);
		}

		var overview = E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, [ _('服务状态') ]),
			E('div', { 'style': 'padding:4px 0;' }, [ runningBadge, ' ', reachBadge, ' ', enabledBadge ]),
			E('div', { 'style': 'margin-top:10px;' }, [
				row(_('监听地址'), mono((status.host || '0.0.0.0') + ':' + port)),
				row(_('公网访问'), pubNode,
					status.publicAccess && status.publicBaseUrl ? mono(status.publicBaseUrl) : ''),
				row(_('当前画质'), mono(RATE_NAMES['' + (status.liveRateType || status.rateType || 3)] || '-'),
					status.guest ? _('游客降级') : ''),
				row(_('咪咕账号'), accountNode),
				row(_('频道数量'), mono((status.channels || 0) + ' 个 / ' + (status.groups || 0) + ' 组'),
					status.cacheAge ? _('缓存') + ' ' + Math.round(status.cacheAge / 60) + ' ' + _('分钟') : ''),
				row(_('版本'), mono(status.version || '-'))
			])
		]);

		/* ---------------- 节目单（EPG） ---------------- */
		var epgNode;
		if (!status.reachable) {
			epgNode = E('span', { 'style': 'opacity:.6;' }, [ _('服务未运行，无法查询') ]);
		} else if (!status.epgEnabled) {
			epgNode = E('span', {}, [
				badge(_('已关闭'), 'dim'),
				E('span', { 'style': 'opacity:.6;font-size:12px;margin-left:8px;' },
					[ _('tvg-id 将退回频道名，电视盒节目单为空') ])
			]);
		} else if (status.epgOk && status.epgIds > 0) {
			epgNode = E('span', {}, [
				badge(_('已就绪'), 'ok'),
				' ',
				mono(status.epgIds + ' ' + _('个频道 id')),
				E('span', { 'style': 'opacity:.6;font-size:12px;margin-left:8px;' },
					[ _('更新于') + ' ' + Math.round((status.epgAge || 0) / 60) + ' ' + _('分钟前') ])
			]);
		} else {
			epgNode = E('span', {}, [
				badge(_('未就绪'), 'warn'),
				E('span', { 'style': 'opacity:.6;font-size:12px;margin-left:8px;' },
					[ status.epgIds > 0
						? _('拉取失败，暂时沿用上一次的结果')
						: _('拉取失败，将在 5 分钟后自动重试') ])
			]);
		}

		/* ---------------- 运行指标（1.4.0） ---------------- */
		var hitPct = status.chHitRatePct || 0;
		var hitBadge = hitPct >= 80 ? 'ok' : (hitPct >= 40 ? 'info' : 'dim');
		var cacheNode = E('span', {}, [
			badge(_('命中 ') + hitPct + '%', hitBadge),
			' ',
			E('span', { 'style': 'font-size:12px;opacity:.75;' }, [
				_('成功') + ' ' + (status.chCacheHits || 0) +
				' / ' + _('未命中') + ' ' + (status.chCacheMisses || 0)
			])
		]);

		// 取流地址缓存 + 失败缓存
		var ttlNode = E('span', {}, [
			mono((status.streamTtl || 0) + 's'),
			E('span', { 'style': 'opacity:.6;font-size:12px;margin-left:6px;' }, [ _('成功') ]),
			' / ',
			mono((status.failTtl || 0) + 's'),
			E('span', { 'style': 'opacity:.6;font-size:12px;margin-left:6px;' }, [ _('失败') ]),
			(status.streamTtl === 0 || status.failTtl === 0)
				? badge(_('有缓存已关闭'), 'warn')
				: ''
		]);

		// 降级链：走备用源的次数（版权盾时段会升高）
		var fbText = (status.chFallback || 0) > 0
			? E('span', {}, [
				mono(status.chFallback + ' ' + _('次')),
				E('span', { 'style': 'opacity:.6;font-size:12px;margin-left:6px;' },
					[ _('咪咕取流失败后由备用源顶替') ])
			])
			: mono('0');

		var metrics = E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, [ _('运行指标') ]),
			E('p', { 'style': 'opacity:.8;margin:6px 0 12px;' }, [
				_('服务本次启动以来的累计数据（重启后归零）。'),
				' ',
				_('「缓存命中率」偏低通常是因为刚开始用、或频道换得比较分散。')
			]),
			E('div', {}, [
				row(_('频道请求'), mono((status.chRequests || 0) + ' ' + _('次')),
					status.avgResolveMs ? _('平均解析') + ' ' + status.avgResolveMs + ' ms' : ''),
				row(_('缓存命中率'), cacheNode),
				row(_('缓存时长'), ttlNode),
				row(_('降级次数'), fbText),
				row(_('节目单（EPG）'), epgNode,
					status.epgUrl ? mono(status.epgUrl) : ''),
				row(_('并发连接'), mono((status.activeConns || 0) + ' / ' + (status.maxConns || 64)),
					(status.rejectedByLimit || 0) > 0
						? _('已拒绝') + ' ' + status.rejectedByLimit + ' ' + _('个超限连接')
						: '')
			])
		]);

		/* ---------------- 服务控制 ---------------- */
		function doAction(fn, label) {
			ui.showModal(_('正在执行'), [
				E('p', { 'class': 'spinning' }, [ label + '…' ])
			]);
			return fn().then(function (res) {
				ui.hideModal();
				var ok = res && res.ok;
				ui.addNotification(null, E('p', {}, [
					ok ? label + _('成功。') : label + _('失败，请查看日志。')
				]), ok ? 'info' : 'warning');
				return callStatus();
			}).then(function (st) {
				// 就地刷新概览区，避免整页重载
				window.setTimeout(function () { window.location.reload(); }, 800);
				return st;
			}).catch(function (e) {
				ui.hideModal();
				ui.addNotification(null, E('p', {}, [ label + _('失败：') + e ]), 'error');
			});
		}

		var control = E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, [ _('服务控制') ]),
			E('p', { 'style': 'opacity:.8;margin:6px 0 12px;' },
				[ _('改动设置后如果没生效，可在此手动重启。') ]),
			E('div', { 'style': 'display:flex;gap:10px;flex-wrap:wrap;' }, [
				E('button', {
					'class': 'btn cbi-button cbi-button-apply',
					'click': ui.createHandlerFn(this, function () {
						return doAction(callRestart, _('重启'));
					})
				}, [ _('重启服务') ]),
				E('button', {
					'class': 'btn cbi-button',
					'click': ui.createHandlerFn(this, function () {
						return doAction(callStart, _('启动'));
					})
				}, [ _('启动') ]),
				E('button', {
					'class': 'btn cbi-button cbi-button-reset',
					'click': ui.createHandlerFn(this, function () {
						return doAction(callStop, _('停止'));
					})
				}, [ _('停止') ])
			])
		]);

		/* ---------------- 订阅地址 ---------------- */
		var subscribe = E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, [ _('TV-BOX 订阅地址') ]),
			E('p', { 'style': 'opacity:.8;margin:6px 0 12px;' },
				[ _('在 TiviMate / IPTV Pro / Kodi 等播放器里添加下面的地址即可，点输入框可全选复制。') ]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ _('M3U 播放列表') ]),
				E('div', { 'class': 'cbi-value-field' }, [ copyField(m3uUrl) ])
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ _('TXT 频道列表') ]),
				E('div', { 'class': 'cbi-value-field' }, [ copyField(txtUrl) ])
			]),
			E('p', { 'style': 'opacity:.7;font-size:12px;margin-top:10px;' }, [
				_('频道在播放时才实时取流，流地址短期有效、自动续期；播放器切台或重连会重新取新地址。')
			])
		]);

		/* ---------------- 公网订阅地址（开启公网时才显示）---------------- */
		var pubSubscribe = [];
		if (status.publicAccess) {
			// 自定义地址优先；没填就用占位提示（具体公网地址只有用户自己知道）
			var pubBase = status.publicBaseUrl ||
				('http://你的公网地址或域名:' + port);
			var tokSeg = status.publicTokenSet ? '/<令牌>' : '';

			// 描述行：对外地址 + 令牌状态提示（拆开构建，避免三元逗号语法坑）
			var desc = [];
			if (status.publicBaseUrl) {
				desc.push(_('对外地址：'));
				desc.push(mono(status.publicBaseUrl));
				desc.push('；');
			}
			if (status.publicTokenSet) {
				desc.push(_('已启用令牌校验，下面地址里的 '));
				desc.push(mono('<令牌>'));
				desc.push(_(' 替换成你在设置页看到的令牌即可。'));
			} else {
				desc.push(badge(_('未设令牌'), 'warn'));
				desc.push(_(' —— 任何人拿到地址都能访问，建议在设置页开启。'));
			}

			pubSubscribe = [
				E('div', { 'class': 'cbi-section' }, [
					E('h3', {}, [ _('公网订阅地址') ]),
					E('p', { 'style': 'opacity:.8;margin:6px 0 12px;' }, desc),
					E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, [ _('M3U（公网）') ]),
						E('div', { 'class': 'cbi-value-field' }, [
							copyField(pubBase + tokSeg + '/m3u')
						])
					]),
					E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, [ _('TXT（公网）') ]),
						E('div', { 'class': 'cbi-value-field' }, [
							copyField(pubBase + tokSeg + '/txt')
						])
					]),
					E('p', { 'style': 'opacity:.7;font-size:12px;margin-top:10px;' }, [
						_('前提是路由器已做端口映射（防火墙 → 端口转发），且「监听地址」为所有网络接口。')
					])
				])
			];
		}

		/* ---------------- 频道测试 ---------------- */
		var list = (chans && chans.list) ? chans.list : [];
		var testInput = E('input', {
			'type': 'number',
			'class': 'cbi-input-text',
			'style': 'width:160px;',
			'placeholder': _('频道 ID（数字）')
		});
		var testResult = E('div', { 'style': 'margin-top:12px;' }, []);

		// 频道下拉：按分组归类，方便挑一个测试
		var select = E('select', { 'class': 'cbi-input-select', 'style': 'max-width:320px;' }, [
			E('option', { 'value': '' }, [ _('— 从列表里选一个频道 —') ])
		]);
		var byGroup = {};
		for (var i = 0; i < list.length; i++) {
			var c = list[i];
			if (!c || !c.pid) continue;
			var g = c.group || _('其他');
			if (!byGroup[g]) byGroup[g] = [];
			byGroup[g].push(c);
		}
		Object.keys(byGroup).forEach(function (g) {
			var og = E('optgroup', { 'label': g }, []);
			byGroup[g].forEach(function (c) {
				og.appendChild(E('option', { 'value': c.pid }, [ c.name + '（' + c.pid + '）' ]));
			});
			select.appendChild(og);
		});
		select.addEventListener('change', function () {
			if (select.value) testInput.value = select.value;
		});

		function runTest() {
			var pid = (testInput.value || '').replace(/\D/g, '');
			if (!pid) {
				ui.addNotification(null, E('p', {}, [ _('请输入或选择一个频道 ID。') ]), 'error');
				return;
			}
			dom.content(testResult, E('p', { 'class': 'spinning' }, [ _('正在测试取流…') ]));
			return callTest(pid).then(function (res) {
				res = res || {};
				var node;
				if (res.ok) {
					node = E('div', {}, [
						badge(_('取流成功'), 'ok'),
						E('div', { 'style': 'margin-top:8px;' }, [
							row(_('最终地址'), mono(res.host || '-'), 'HTTP ' + (res.code || '302')),
							row(_('完整 URL'), mono(res.url || '-'))
						])
					]);
				} else {
					node = E('div', {}, [
						badge(_('取流失败'), 'err'),
						E('div', { 'style': 'margin-top:8px;' }, [
							row(_('原因'), E('span', {}, [ res.error || _('未知错误') ]), res.rid || ''),
							res.rid === 'COPYRIGHT_SHIELD_INVALID'
								? E('div', {
									'style': 'margin-top:8px;padding:8px 10px;border-radius:4px;' +
										'background:rgba(239,108,0,.12);font-size:13px;'
								}, [
									_('说明：这是咪咕服务端的时段性版权限制，') +
									_('该频道当前正在播出版权赛事，需登录咪咕体育会员后才能观看。') +
									_('非本插件故障，游客或普通账号无法绕过。')
								])
								: ''
						])
					]);
				}
				dom.content(testResult, node);
			}).catch(function (e) {
				dom.content(testResult, E('p', { 'style': 'color:#c62828;' }, [ _('测试失败：') + e ]));
			});
		}

		var test = E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, [ _('频道测试') ]),
			E('p', { 'style': 'opacity:.8;margin:6px 0 12px;' },
				[ _('实测某个频道的取流结果，用来确认账号权限与频道可用性。') ]),
			E('div', { 'style': 'display:flex;gap:10px;flex-wrap:wrap;align-items:center;' }, [
				select, testInput,
				E('button', {
					'class': 'btn cbi-button cbi-button-action',
					'click': ui.createHandlerFn(this, runTest)
				}, [ _('开始测试') ])
			]),
			testResult
		]);

		/* ---------------- 频道分组 ---------------- */
		var groups = (chans && chans.groups) ? chans.groups : [];
		var groupRows = [];
		if (!chans.ok) {
			groupRows.push(E('div', { 'style': 'color:#c62828;padding:8px 0;' },
				[ _('无法获取频道列表：') + (chans.error || _('未知错误')) ]));
		} else if (groups.length === 0) {
			groupRows.push(E('div', { 'style': 'opacity:.7;padding:8px 0;' }, [ _('暂无频道') ]));
		} else {
			groupRows.push(E('div', { 'style': 'display:flex;flex-wrap:wrap;gap:8px;padding:4px 0;' },
				groups.map(function (g) {
					return E('span', {
						'style': 'display:inline-block;padding:4px 10px;border-radius:4px;' +
							'background:rgba(128,128,128,.14);font-size:13px;'
					}, [ g.name + '（' + g.count + '）' ]);
				})));
		}

		var groupsSection = E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, [ _('频道分组') + (chans.ok ? '（' + (chans.total || 0) + ' 个频道）' : '') ]),
			E('p', { 'style': 'opacity:.8;margin:6px 0 10px;' },
				[ _('分组顺序按正常电视台习惯排列：央视（CCTV1 起）在最前。') ])
		].concat(groupRows));

		/* ---------------- 日志 ---------------- */
		var logLines = (logs && logs.lines) ? logs.lines : [];
		var logBox = E('pre', {
			'style': 'max-height:260px;overflow:auto;background:rgba(0,0,0,.28);padding:10px;' +
				'border-radius:4px;font-size:12px;line-height:1.5;margin:0;',
			'id': 'migu-logbox'
		}, [ logLines.length ? logLines.join('\n') : _('（暂无日志）') ]);

		var logSection = E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, [ _('服务日志') ]),
			E('p', { 'style': 'opacity:.8;margin:6px 0 10px;' }, [
				_('最近 40 条。开启「调试日志」后信息更详细。'),
				' ',
				E('button', {
					'class': 'btn cbi-button cbi-button-action',
					'style': 'margin-left:6px;',
					'click': ui.createHandlerFn(this, function () {
						return callLogs(LOG_LINES).then(function (r) {
							var ls = (r && r.lines) ? r.lines : [];
							dom.content(logBox, ls.length ? ls.join('\n') : _('（暂无日志）'));
							ui.addNotification(null, E('p', {}, [ _('日志已刷新。') ]), 'info');
						});
					})
				}, [ _('刷新') ])
			]),
			logBox
		]);

		// 注意（实测）：LuCI 的 dom.append 不展平嵌套数组——children 里的数组元素
		// 会被 toString() 变成文本节点 "[object Object]"。所以这里必须用 concat
		// 把 pubSubscribe 拍平进 children，不能直接嵌数组。
		return E('div', { 'class': 'cbi-map' }, [
			E('h2', { 'name': 'content' }, [ _('咪咕直播') ]),
			E('div', { 'class': 'cbi-map-descr' },
				[ _('咪咕视频直播频道 → TV-BOX 可订阅的 M3U 播放列表。配置项请到「设置」页。') ]),
			overview,
			metrics,
			control,
			subscribe
		].concat(pubSubscribe, [
			test,
			groupsSection,
			logSection
		]));
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
