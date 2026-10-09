'use strict';
'require view';
'require rpc';
'require ui';
'require dom';

// AI 中转服务器 —— 状态页（只读）
//
// 设计约定（v1.5.0）：
//   本页只做「看」：展示运行状态、凭据数量、可用模型与管理页入口。
//   日常管理（API 密钥、服务器与 Key、凭据池、模型策略）都在独立管理网页
//   /admin 完成，避免同一份配置在两处维护。管理员密码也在本页设置一次即可。
//
// 说明：本文件路径与 rpcd 对象仍叫 workbuddy（内部标识符不改），
// 页面标题与界面文案统一用产品名「AI 中转服务器」。

var callStatus = rpc.declare({
	object: 'workbuddy',
	method: 'status',
	expect: { }
});

var callModels = rpc.declare({
	object: 'workbuddy',
	method: 'models',
	expect: { }
});

var callCredsList = rpc.declare({
	object: 'workbuddy',
	method: 'creds_list',
	expect: { }
});

var callAdminStatus = rpc.declare({
	object: 'workbuddy',
	method: 'admin_status',
	expect: { }
});

var callAdminSetPassword = rpc.declare({
	object: 'workbuddy',
	method: 'admin_set_password',
	params: [ 'password' ],
	expect: { }
});

var callReload = rpc.declare({
	object: 'workbuddy',
	method: 'reload',
	expect: { }
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
	return E('div', { 'style': 'display:flex;padding:7px 0;border-bottom:1px solid rgba(128,128,128,.18);align-items:center;' }, [
		E('div', { 'style': 'flex:0 0 180px;font-weight:600;opacity:.85;' }, [ label ]),
		E('div', { 'style': 'flex:1;min-width:0;word-break:break-all;' }, [ valueNode ]),
		hint ? E('div', { 'style': 'flex:0 0 auto;font-size:12px;opacity:.6;margin-left:10px;' }, [ hint ]) : ''
	]);
}

function mono(s) {
	return E('code', { 'style': 'font-family:monospace;font-size:13px;' }, [ '' + s ]);
}

// 取出一个「可直接点击打开」的管理页地址。
// rpcd 返回的 baseUrl 在监听 0.0.0.0 时会是 127.0.0.1，对用户没用；
// 这里改用浏览器当前访问 LuCI 的主机名，保证点开就能用。
function adminUrlFor(status) {
	var port = status.port || 8789;
	var host = window.location.hostname || '';

	// IPv6 字面量要加方括号
	if (host.indexOf(':') >= 0 && host.charAt(0) !== '[') host = '[' + host + ']';
	if (!host) host = '127.0.0.1';

	return 'http://' + host + ':' + port + '/admin';
}

return view.extend({
	load: function() {
		return Promise.all([
			callStatus(),
			callModels(),
			callCredsList(),
			callAdminStatus()
		]);
	},

	render: function(data) {
		var status = data[0] || {};
		var models = data[1] || {};
		var creds = data[2] || {};
		var admin = data[3] || {};
		var self = this;

		var adminUrl = adminUrlFor(status);

		var runningBadge = status.running
			? badge(_('运行中'), 'ok')
			: badge(_('未运行'), 'err');

		var reachBadge = status.reachable
			? badge(_('可访问'), 'ok')
			: badge(_('无响应'), 'warn');

		var authBadge = (status.apiKeysDefined > 0)
			? badge(_('已启用') + '（' + status.apiKeys + '/' + status.apiKeysDefined + '）', 'ok')
			: badge(_('未启用'), 'warn');

		var freeBadge = status.onlyFree
			? badge(_('仅免费模型'), 'ok')
			: badge(_('全部模型'), 'warn');

		// ---------- 概览 ----------
		var overview = E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, [ _('服务状态') ]),
			E('div', { 'style': 'padding:4px 0;' }, [
				runningBadge,
				' ',
				reachBadge,
				' ',
				authBadge,
				' ',
				freeBadge
			]),
			E('div', { 'style': 'margin-top:10px;' }, [
				row(_('监听地址'), mono((status.host || '0.0.0.0') + ':' + (status.port || 8789))),
				row(_('内置服务器地址'), mono(status.endpoint || '-')),
				row(_('客户端版本'), mono(status.clientVersion || '-'),
					status.autoVersion ? _('自动获取') : _('固定值')),
				row(_('凭据数量'), mono(status.credentials || 0),
					(status.credentials > 1) ? _('轮询负载均衡') : ''),
				row(_('API 密钥'), mono((status.apiKeys || 0) + ' / ' + (status.apiKeysDefined || 0) + ' ' + _('启用中'))),
				row(_('WorkBuddy 账号'), status.token && status.token.present
					? badge(_('已登录'), 'ok')
					: badge(_('未登录'), 'warn'),
					status.token && status.token.syncedAt ? String(status.token.syncedAt).replace('T', ' ').substring(0, 19) : '')
			])
		]);

		// ---------- 管理页入口 ----------
		var adminSection = E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, [ _('管理网页') ]),
			E('p', { 'style': 'opacity:.8;margin:6px 0 12px;' }, [
				_('API 密钥、凭据池、模型策略等日常管理，请打开独立管理网页使用管理员密码登录。')
			]),
			E('div', { 'style': 'display:flex;align-items:center;flex-wrap:wrap;gap:10px;' }, [
				E('a', {
					'href': adminUrl,
					'target': '_blank',
					'rel': 'noopener noreferrer',
					'class': 'btn cbi-button cbi-button-action',
					'style': 'text-decoration:none;'
				}, [ _('打开管理网页') ]),
				E('code', { 'style': 'font-family:monospace;font-size:13px;opacity:.85;' }, [ adminUrl ])
			]),
			E('div', { 'style': 'margin-top:14px;' }, [
				admin.enabled
					? E('div', {}, [ badge(_('管理员密码已设置'), 'ok') ])
					: E('div', {}, [ badge(_('尚未设置管理员密码 —— 管理网页暂不可用'), 'warn') ])
			])
		]);

		// ---------- 管理员密码 ----------
		var pw1 = E('input', {
			'type': 'password',
			'class': 'cbi-input-text',
			'style': 'width:100%;max-width:320px;',
			'autocomplete': 'new-password',
			'placeholder': _('至少 6 位')
		});

		var pw2 = E('input', {
			'type': 'password',
			'class': 'cbi-input-text',
			'style': 'width:100%;max-width:320px;',
			'autocomplete': 'new-password',
			'placeholder': _('再输入一次')
		});

		function savePassword() {
			var a = pw1.value || '';
			var b = pw2.value || '';

			if (a !== b) {
				ui.addNotification(null, E('p', {}, [ _('两次输入的密码不一致') ]), 'error');
				return;
			}
			if (a.length > 0 && a.length < 6) {
				ui.addNotification(null, E('p', {}, [ _('密码至少 6 位') ]), 'error');
				return;
			}

			ui.showModal(_('正在保存'), [
				E('p', { 'class': 'spinning' }, [ _('正在应用新密码…') ])
			]);

			return callAdminSetPassword(a).then(function(res) {
				if (!res || res.ok !== true) {
					ui.hideModal();
					ui.addNotification(null,
						E('p', {}, [ _('保存失败：') + ((res && res.error) || _('未知错误')) ]), 'error');
					return;
				}
				// 让新密码立即生效（否则要等下一次重启）
				return callReload();
			}).then(function() {
				ui.hideModal();
				pw1.value = '';
				pw2.value = '';
				ui.addNotification(null, E('p', {}, [
					a.length > 0
						? _('管理员密码已更新，管理网页会立即使用新密码。')
						: _('管理员密码已清除，管理网页已停用。')
				]), 'info');
				window.setTimeout(function() { window.location.reload(); }, 900);
			}).catch(function(e) {
				ui.hideModal();
				ui.addNotification(null, E('p', {}, [ _('保存失败：') + e ]), 'error');
			});
		}

		var pwSection = E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, [ _('管理员密码') ]),
			E('p', { 'style': 'opacity:.8;margin:6px 0 12px;' }, [
				_('设置后即可用该密码登录管理网页。留空并保存可停用管理网页。'),
				E('br'),
				_('修改密码会让所有已登录的管理会话立即失效；连续输错 8 次会锁定 5 分钟。')
			]),
			E('div', { 'style': 'display:flex;flex-direction:column;gap:10px;' }, [
				E('div', {}, [
					E('div', { 'style': 'font-weight:600;margin-bottom:4px;' }, [ _('新密码') ]),
					pw1
				]),
				E('div', {}, [
					E('div', { 'style': 'font-weight:600;margin-bottom:4px;' }, [ _('确认密码') ]),
					pw2
				]),
				E('div', {}, [
					E('button', {
						'class': 'btn cbi-button cbi-button-apply',
						'click': ui.createHandlerFn(this, savePassword)
					}, [ _('保存密码') ])
				])
			])
		]);

		// ---------- 凭据池 ----------
		var credRows = [];
		var list = creds.credentials || [];
		if (list.length === 0) {
			credRows.push(E('div', { 'style': 'opacity:.7;padding:8px 0;' }, [
				_('暂无凭据。请先在管理网页登录 WorkBuddy 账号，或添加 access token。')
			]));
		} else {
			for (var i = 0; i < list.length; i++) {
				var c = list[i];
				credRows.push(row(
					c.name || c.id,
					E('span', {}, [
						mono('…' + (c.tail || '')),
						' ',
						c.enabled ? badge(_('启用'), 'ok') : badge(_('停用'), 'dim'),
						(c.source === 'legacy')
							? badge(_('网页登录'), 'info')
							: badge(_('手动添加'), 'dim')
					]),
					c.syncedAt ? String(c.syncedAt).replace('T', ' ').substring(0, 19) : ''
				));
			}
		}

		var credSection = E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, [ _('凭据池') ]),
			E('p', { 'style': 'opacity:.8;margin:6px 0 10px;' }, [
				_('多条凭据会轮流使用，避免单账号被限流；某条失败会自动冷却并切到下一条。'),
				E('br'),
				_('凭据的增删与启停请到管理网页操作。')
			])
		].concat(credRows));

		// ---------- 可用模型 ----------
		var modelRows = [];
		var mlist = models.models || [];
		if (!models.ok) {
			modelRows.push(E('div', { 'style': 'color:#c62828;padding:8px 0;' }, [
				_('无法获取模型列表：') + (models.error || _('未知错误'))
			]));
		} else if (mlist.length === 0) {
			modelRows.push(E('div', { 'style': 'opacity:.7;padding:8px 0;' }, [ _('暂无可用模型') ]));
		} else {
			for (var j = 0; j < mlist.length; j++) {
				modelRows.push(row(
					mlist[j].id,
					mono(mlist[j].name || mlist[j].id),
					''
				));
			}
		}

		var modelSection = E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, [ _('当前可用模型') + (models.ok ? '（' + (models.count || 0) + '）' : '') ]),
			E('p', { 'style': 'opacity:.8;margin:6px 0 10px;' }, [
				status.onlyFree
					? _('已开启「仅免费模型」，下面只显示免费额度模型，收费模型会被自动替换。')
					: _('当前允许全部模型，请注意收费模型的额度消耗。')
			])
		].concat(modelRows));

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', { 'name': 'content' }, [ _('AI 中转服务器') ]),
			E('div', { 'class': 'cbi-map-descr' }, [
				_('把本机 WorkBuddy 与任意多个第三方 OpenAI 兼容服务器聚合成本地统一接口，' +
				  '每台服务器可配多条 Key 做负载均衡，供其他程序调用。')
			]),
			overview,
			adminSection,
			pwSection,
			credSection,
			modelSection
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
