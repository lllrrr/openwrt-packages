'use strict';
'require view';
'require form';
'require uci';
'require rpc';
'require ui';
'require dom';

// ---------------------------------------------------------------------------
// RPC 声明（ubus 对象：vnt2web）
// ---------------------------------------------------------------------------
const callStatus = rpc.declare({ object: 'vnt2web', method: 'status' });
const callPanel = rpc.declare({ object: 'vnt2web', method: 'panel' });
const callCheck = rpc.declare({ object: 'vnt2web', method: 'check_update' });
const callUpdate = rpc.declare({ object: 'vnt2web', method: 'update', params: [ 'ver' ] });
// 启停与令牌均交由「配置项 + 保存」驱动（uci 提交后 procd 自动 reload），
// 前端不再直接调用 start/stop/restart/set_token 等 RPC。
const callLogs = rpc.declare({ object: 'vnt2web', method: 'logs', params: [ 'name', 'lines' ] });
const callClearLog = rpc.declare({ object: 'vnt2web', method: 'clear_log', params: [ 'name' ] });
const callDiag = rpc.declare({ object: 'vnt2web', method: 'diag' });
const callNetTest = rpc.declare({ object: 'vnt2web', method: 'net_test' });

let ST = {};

// ---------------------------------------------------------------------------
// 小组件
// ---------------------------------------------------------------------------
function badge(text, kind) {
	const colors = {
		ok: 'border-color:#4caf50;color:#2e7d32',
		bad: 'border-color:#e53935;color:#c62828',
		'': 'border-color:#bbb;color:#666'
	};
	return E('span', {
		'style': 'display:inline-block;padding:2px 10px;border-radius:10px;font-size:12px;' +
			'margin:2px 6px 2px 0;border:1px solid ' + (colors[kind] || colors['']) +
			';' + (colors[kind] || '')
	}, text);
}

// ---------------------------------------------------------------------------
// 视觉样式
//
// 与 fnos 版（github.com/virkingz/fnos-vnt2）保持一致的观感：
// 浅灰底、白色圆角卡片、蓝色主色。
// 所有类名加 vnt- 前缀，避免影响 LuCI 自身的样式。
// ---------------------------------------------------------------------------
const STYLE_ID = 'vnt2web-style';
const STYLE_CSS = `
.vnt-pane-wrap { --vnt-bg:#f4f6f8; --vnt-card:#fff; --vnt-line:#e3e7ec;
  --vnt-text:#1d2129; --vnt-muted:#6b7280; --vnt-hint:#99a0aa;
  --vnt-blue:#185fa5; --vnt-blue-d:#0c447c; --vnt-teal:#0f6e56;
  --vnt-red:#a32d2d; --vnt-radius:12px;
  color:var(--vnt-text); }
.vnt-pane-wrap * { box-sizing:border-box; }

/* 头部卡片：标题 + 说明 + 状态条（对应 fnos 的品牌栏） */
.vnt-pane-wrap .vnt-header { padding:14px 18px 10px; }
.vnt-pane-wrap .vnt-header h2 { margin:0 0 4px; font-size:16px;
  font-weight:500; color:var(--vnt-text); }
.vnt-pane-wrap .vnt-header .cbi-map-descr { margin:0; color:var(--vnt-hint);
  font-size:12px; line-height:1.6; }

/* 状态条 */
.vnt-status { display:flex; flex-wrap:wrap; gap:8px; align-items:center;
  padding:10px 0 2px; }
.vnt-pill { display:inline-block; padding:3px 10px; border-radius:999px;
  font-size:12px; border:1px solid var(--vnt-line);
  background:#f7f8fa; color:var(--vnt-muted); }
.vnt-pill.on { background:#e1f5ee; border-color:#9fe1cb; color:var(--vnt-teal); }
.vnt-pill.off { background:#fcebeb; border-color:#f7c1c1; color:var(--vnt-red); }

/* 标签栏 */
.vnt-tabs { display:flex; gap:4px; margin:0 0 14px;
  border-bottom:1px solid var(--vnt-line); overflow-x:auto; }
.vnt-tab { appearance:none; border:none; background:none; cursor:pointer;
  padding:9px 14px; font-size:13px; color:var(--vnt-muted);
  border-bottom:2px solid transparent; white-space:nowrap; font-family:inherit; }
.vnt-tab:hover { color:var(--vnt-text); }
.vnt-tab.active { color:var(--vnt-blue-d); border-bottom-color:var(--vnt-blue);
  font-weight:500; }

/* 标签内容区。
   显隐一律走 .active 类，且在这里给出**默认隐藏**的规则 ——
   早先只用内联 style 控制，一旦框架重排或时序错开就会出现
   「标签点不动 / 内容全看不见」，需要刷新才恢复。
   有 CSS 兜底后，即使 JS 时机不准，默认也是「只显示第一个」。 */
.vnt-pane { display:none; }
.vnt-pane.active { display:block; }

/* 卡片 */
.vnt-card { background:var(--vnt-card); border:1px solid var(--vnt-line);
  border-radius:var(--vnt-radius); padding:16px 18px; margin:0 0 14px; }
.vnt-card > h2 { margin:0 0 12px; font-size:14px; font-weight:500;
  color:var(--vnt-text); }
.vnt-hint { color:var(--vnt-hint); font-size:12px; margin:6px 0 0;
  line-height:1.6; }
.vnt-hint code { background:#f0f2f5; padding:1px 5px; border-radius:4px;
  font-size:11px; }

/* 键值列表 */
.vnt-kv { margin:0; display:grid; gap:0; }
.vnt-kv > div { display:flex; justify-content:space-between; gap:16px;
  padding:7px 0; border-bottom:1px dashed var(--vnt-line); }
.vnt-kv > div:last-child { border-bottom:none; }
.vnt-kv dt { color:var(--vnt-muted); flex:none; }
.vnt-kv dd { margin:0; text-align:right; word-break:break-all; }

/* 按钮行 */
.vnt-row { display:flex; gap:8px; align-items:center; flex-wrap:wrap;
  margin-top:14px; }
.vnt-btn { appearance:none; cursor:pointer; border:1px solid var(--vnt-line);
  background:#fff; color:var(--vnt-text); font-size:13px;
  padding:7px 14px; border-radius:8px; font-family:inherit; }
.vnt-btn:hover { border-color:#c8ced6; }
.vnt-btn.primary { background:var(--vnt-blue); border-color:var(--vnt-blue);
  color:#fff; }
.vnt-btn.primary:hover { background:var(--vnt-blue-d);
  border-color:var(--vnt-blue-d); }
.vnt-btn:disabled { opacity:.5; cursor:not-allowed; }
.vnt-grow { flex:1 1 240px; }

/* 输入框（含 LuCI 表单里的），统一成卡片的观感 */
.vnt-pane-wrap input[type=text],
.vnt-pane-wrap select {
  width:100%; padding:8px 11px; font-size:13px;
  border:1px solid var(--vnt-line); border-radius:8px;
  background:#fff; color:var(--vnt-text); font-family:inherit;
}
.vnt-pane-wrap input[type=text]:focus,
.vnt-pane-wrap select:focus {
  outline:none; border-color:var(--vnt-blue); box-shadow:0 0 0 3px #e6f1fb;
}

/* 日志 / 自检输出 */
.vnt-log { background:#f7f8fa; border:1px solid var(--vnt-line);
  border-radius:8px; padding:10px 12px; margin:10px 0 0; font-size:12px;
  font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;
  white-space:pre-wrap; word-break:break-all; max-height:230px;
  overflow:auto; color:#3d4450; }
.vnt-log.tall { max-height:460px; }

/* 内嵌面板 */
.vnt-frame-wrap { margin-top:12px; border:1px solid var(--vnt-line);
  border-radius:10px; overflow:hidden; background:#fff; }
.vnt-frame-wrap iframe { display:block; width:100%; height:640px; border:0; }

/* 提示条 */
.vnt-tip { margin-top:10px; padding:9px 12px; border-radius:8px; font-size:12px;
  background:#faeeda; border:1px solid #fac775; color:#854f0b; }

/* 让 LuCI 表单在卡片里更贴合 */
.vnt-pane-wrap .cbi-section { background:var(--vnt-card);
  border:1px solid var(--vnt-line); border-radius:var(--vnt-radius);
  padding:16px 18px; margin:0 0 14px; }
.vnt-pane-wrap .cbi-section > h3 { margin:0 0 12px; font-size:14px;
  font-weight:500; }
.vnt-pane-wrap .cbi-value { padding:4px 0; }
.vnt-pane-wrap .cbi-value-title { color:var(--vnt-muted); }
.vnt-pane-wrap .cbi-value-description { color:var(--vnt-hint);
  font-size:12px; line-height:1.6; }
.vnt-pane-wrap .cbi-section-descr { color:var(--vnt-hint); font-size:12px; }
.vnt-pane-wrap .cbi-input-text,
.vnt-pane-wrap .cbi-input-select { max-width:100%; }
/* 令牌输入框等长条输入占满一行 */
.vnt-pane-wrap .vnt-token-row input { min-width:260px; }
`;

function ensureStyle() {
	if (document.getElementById(STYLE_ID)) return;
	document.head.appendChild(E('style', { 'id': STYLE_ID }, STYLE_CSS));
}

// 白色圆角卡片（对应 fnos 的 .card）
function card(title, hint, body) {
	const kids = [];
	if (title) kids.push(E('h2', {}, title));
	if (hint) kids.push(E('p', { 'class': 'vnt-hint' }, hint));
	if (body) kids.push(body);
	return E('div', { 'class': 'vnt-card' }, kids);
}

// 状态胶囊（对应 fnos 的 .pill）
function pill(text, kind) {
	return E('span', { 'class': 'vnt-pill' + (kind ? ' ' + kind : '') }, text);
}

// 键值行
function kvRow(label, value) {
	return E('div', {}, [
		E('dt', {}, label),
		E('dd', {}, value)
	]);
}

// 键值列表容器
function kvList(rows) {
	return E('dl', { 'class': 'vnt-kv' }, rows);
}


// ---------------------------------------------------------------------------
// 核心更新页（对应 fnos 的「核心更新」标签）
// ---------------------------------------------------------------------------
function buildOverview(view) {
	const s = ST;
	const rows = [];

	rows.push(kvRow('已安装核心', s.installed
		? E('strong', {}, 'v' + (s.version || '?'))
		: pill('未下载', 'off')));

	rows.push(kvRow('最新版本', E('span', { 'id': 'vnt-latest' }, '未检查')));

	rows.push(kvRow('核心进程', [
		pill(s.running ? '运行中' : '已停止', s.running ? 'on' : 'off'),
		s.running ? pill(s.port_listening ? '端口已监听' : '端口未监听',
			s.port_listening ? 'on' : 'off') : '',
		s.pid ? E('span', { 'class': 'mono',
			'style': 'color:#888;font-size:12px;margin-left:6px' },
			'(pid ' + s.pid + ')') : ''
	]));

	rows.push(kvRow('系统架构', [
		E('code', {}, s.arch || '?'),
		s.asset_triple
			? E('span', { 'style': 'color:#888;font-size:12px' }, ' → ' + s.asset_triple)
			: pill(' 无对应预编译包', 'off')
	]));

	rows.push(kvRow('面板端口', E('code', {},
		(s.bind || '0.0.0.0') + ':' + (s.port || '19099'))));

	rows.push(kvRow('已配置组网', s.instance_count > 0
		? E('span', {}, s.instance_count + ' 个（在面板中管理）')
		: E('span', { 'style': 'color:#888' }, '暂无，请在面板中添加')));

	rows.push(kvRow('运行环境', [
		pill(s.tun_ok ? 'TUN 可用' : 'TUN 缺失', s.tun_ok ? 'on' : 'off'),
		pill(s.http_client ? 'HTTP 可用' : 'HTTP 缺失', s.http_client ? 'on' : 'off'),
		pill(s.unzip_ok ? '解压可用' : '解压缺失', s.unzip_ok ? 'on' : 'off')
	]));

	rows.push(kvRow('核心路径', E('code', { 'style': 'font-size:12px' },
		s.bin_path || '-')));
	rows.push(kvRow('配置目录', E('code', { 'style': 'font-size:12px' },
		s.config_dir || '-')));
	rows.push(kvRow('日志目录', E('code', { 'style': 'font-size:12px' },
		s.log_dir || '-')));

	const btns = E('div', { 'class': 'vnt-row' }, [
		E('button', {
			'class': 'vnt-btn',
			'click': ui.createHandlerFn(view, 'handleCheck')
		}, '检查更新'),
		E('button', {
			'class': 'vnt-btn primary', 'id': 'vnt-btn-update',
			'click': ui.createHandlerFn(view, 'handleUpdate')
		}, s.installed ? '更新核心' : '下载核心'),
		// 测试连通性放在这里：下载走的就是更新源/代理，需与「更新核心」就近验证。
		// 结果提示复用 #vnt-net-msg，handleNetTest 无需改动。
		E('button', {
			'class': 'vnt-btn',
			'click': ui.createHandlerFn(view, 'handleNetTest')
		}, '测试连通性')
	]);

	return card('版本信息', null, E('div', {}, [
		kvList(rows),
		btns,
		E('p', { 'class': 'vnt-hint', 'id': 'vnt-update-msg' },
			'首次使用请点「检查更新」，确认可下载后再执行下载。'),
		E('div', { 'class': 'vnt-hint', 'id': 'vnt-net-msg',
			'style': 'min-height:18px' }, '')
	]));
}

// ---------------------------------------------------------------------------
// 组网面板（内嵌 + 跳转）
// ---------------------------------------------------------------------------
function buildPanel(view) {
	const frame = E('iframe', {
		'id': 'vnt-frame',
		'src': 'about:blank',
		'title': 'vnt2_web 组网面板',
		'referrerpolicy': 'no-referrer'
	});

	const head = card('组网面板',
		'组网的添加、启动、查看节点与路由，全部在 vnt2_web 自带页面完成。' +
		'下面的内嵌面板已自动带上访问令牌，无需手工登录。',
		E('div', {}, [
			kvList([
				kvRow('面板地址', E('span', { 'class': 'mono', 'id': 'vnt-panel-url' },
					ST.panel_url || '-'))
			]),
			E('div', { 'class': 'vnt-row' }, [
				E('button', {
					'class': 'vnt-btn primary',
					'click': ui.createHandlerFn(view, 'handleOpenPanel')
				}, '在新窗口打开'),
				E('button', {
					'class': 'vnt-btn',
					'click': ui.createHandlerFn(view, 'handleReloadFrame')
				}, '重新加载'),
				E('button', {
					'class': 'vnt-btn',
					'click': ui.createHandlerFn(view, 'handleCopyPanel')
				}, '复制面板地址')
			])
		]));

	const body = card(null, null, E('div', {}, [
		E('div', { 'class': 'vnt-tip', 'id': 'vnt-frame-tip',
			'style': ST.running ? 'display:none' : null },
			'核心未运行，请先到「核心更新」下载并启用服务'),
		E('div', { 'class': 'vnt-frame-wrap' }, frame)
	]));

	return E('div', {}, [ head, body ]);
}

// ---------------------------------------------------------------------------
// 令牌
//
// 令牌只保留「服务设置」里的那一个输入框（见表单定义），不再另设显示区或按钮：
//   - 不显示当前令牌 —— 避免令牌明文出现在页面上（截屏/旁人可见）
//   - 不提供「随机生成/复制」—— 留空即由核心自动生成，界面无需介入
// 因此原先的 buildTokenTools 与相关处理函数已移除。
// ---------------------------------------------------------------------------

// 注：「测试连通性」按钮现在直接构建在「核心更新」的按钮行里
// （见 buildOverview），不再需要单独的构建函数与注入容器。

// ---------------------------------------------------------------------------
// 日志与自检
// ---------------------------------------------------------------------------
function buildLogs(view) {
	const sel = E('select', { 'id': 'vnt-log-name', 'style': 'max-width:220px' }, [
		E('option', { 'value': 'core' }, '核心 vnt2_web'),
		E('option', { 'value': 'main' }, '服务日志'),
		E('option', { 'value': 'update' }, '更新日志')
	]);

	const box = E('pre', { 'class': 'vnt-log tall', 'id': 'vnt-log-text' },
		'正在加载…');

	return card('日志',
		'核心运行日志与服务日志。单个日志超过 256 KB 时会自动截断，只保留最近部分。',
		E('div', {}, [
			E('div', { 'class': 'vnt-row', 'style': 'margin-top:0' }, [
				sel,
				E('button', {
					'class': 'vnt-btn',
					'click': ui.createHandlerFn(view, 'handleLoadLog')
				}, '刷新'),
				E('button', {
					'class': 'vnt-btn',
					'click': ui.createHandlerFn(view, 'handleClearLog')
				}, '清空')
			]),
			box
		]));
}

function buildDiag(view) {
	const box = E('pre', { 'class': 'vnt-log', 'id': 'vnt-diag' },
		'点上方按钮开始自检');

	return card('自检',
		'逐项检查架构、下载工具、TUN、核心与端口状态，用于排查启动失败。',
		E('div', {}, [
			E('div', { 'class': 'vnt-row', 'style': 'margin-top:0' }, [
				E('button', {
					'class': 'vnt-btn',
					'click': ui.createHandlerFn(view, 'handleDiag')
				}, '开始自检')
			]),
			box
		]));
}

// ---------------------------------------------------------------------------
// 主视图
// ---------------------------------------------------------------------------
return view.extend({
	load: function () {
		return uci.load('vnt2web').then(function () {
			return callStatus();
		}).then(function (s) {
			ST = s || {};
			return uci.load('vnt2web');
		});
	},

	// ---------------- 操作 ----------------
	pickLog: function () {
		const el = document.getElementById('vnt-log-name');
		return el ? el.value : 'core';
	},

	reloadSoon: function (delay) {
		window.setTimeout(function () { location.reload(); }, delay || 1200);
	},

	handleCheck: function () {
		const msg = document.getElementById('vnt-update-msg');
		msg.innerHTML = '';
		msg.appendChild(badge('正在查询最新版本…', ''));
		return callCheck().then(function (r) {
			msg.innerHTML = '';
			// 「最新版本」那一行也要跟着更新 —— 否则永远停在「未检查」
			const latestEl = document.getElementById('vnt-latest');
			if (!r.ok) {
				if (latestEl) latestEl.textContent = '查询失败';
				msg.appendChild(badge(r.msg, 'bad'));
				return;
			}
			if (latestEl) latestEl.textContent = 'v' + (r.latest || '未知');
			msg.appendChild(badge(r.tip, r.action === 'none' ? 'ok' : ''));
			const btn = document.getElementById('vnt-btn-update');
			if (btn) {
				if (r.action === 'install') { btn.textContent = '下载核心'; btn.disabled = false; }
				else if (r.action === 'update') { btn.textContent = '更新到 v' + r.latest; btn.disabled = false; }
				else { btn.textContent = '已是最新'; btn.disabled = true; }
			}
			ST.latest = r.latest;
		});
	},

	handleUpdate: function () {
		const msg = document.getElementById('vnt-update-msg');
		const ver = ST.latest || '';
		msg.innerHTML = '';
		msg.appendChild(badge('正在下载并安装核心' + (ver ? ' v' + ver : '') +
			'，下载可能需要较长时间，请勿关闭页面…', ''));
		return callUpdate(ver).then(L.bind(function (r) {
			msg.innerHTML = '';
			msg.appendChild(badge(r.msg, r.ok ? 'ok' : 'bad'));
			if (r.ok) this.reloadSoon(1800);
		}, this));
	},

	// 启停不提供界面按钮：服务的启停由「服务设置 → 启用服务」开关 + 保存决定，
	// uci commit 后 procd 会依 procd_add_reload_trigger 自动 reload
	// （reload_service = stop + start，而 start 会检查 enabled）。

	// ---- 面板 ----
	handleOpenPanel: function () {
		return callPanel().then(function (r) {
			if (r && r.url) window.open(r.url, '_blank', 'noopener');
		});
	},

	handleReloadFrame: function () {
		const f = document.getElementById('vnt-frame');
		if (!f) return;
		f.src = 'about:blank';
		return callPanel().then(function (r) {
			if (r && r.url) f.src = r.url;
			const el = document.getElementById('vnt-panel-url');
			if (el && r && r.display_url) el.textContent = r.display_url;
		});
	},

	handleCopyPanel: function () {
		return callPanel().then(L.bind(function (r) {
			const tip = document.getElementById('vnt-frame-tip');
			const url = (r && r.url) ? r.url : '';
			const done = function () {
				if (tip) {
					tip.innerHTML = '';
					tip.appendChild(badge('已复制面板地址（含令牌）', 'ok'));
				}
			};
			if (navigator.clipboard && url) {
				navigator.clipboard.writeText(url).then(done, done);
			} else {
				ui.addNotification(null, E('p', {}, url), 'info');
			}
		}, this));
	},

	// ---- 令牌 ----
	// 令牌改由「服务设置」里的输入框 + 标准保存流程处理（uci 提交后
	// procd 自动 reload）。界面不再单独提供生成/复制/显示操作，故无处理函数。

	// ---- 日志 / 自检 / 网络 ----
	handleLoadLog: function () {
		const name = this.pickLog();
		const box = document.getElementById('vnt-log-text');
		if (!box) return;
		box.textContent = '正在加载…';
		return callLogs(name, 300).then(function (r) {
			box.textContent = (r && r.text) ? r.text : '(日志为空)';
		});
	},

	handleClearLog: function () {
		const name = this.pickLog();
		return callClearLog(name).then(L.bind(function (r) {
			ui.addNotification(null, E('p', {}, r.msg), 'info');
			this.handleLoadLog();
		}, this));
	},

	handleDiag: function () {
		const box = document.getElementById('vnt-diag');
		box.textContent = '正在自检…';
		return callDiag().then(function (r) {
			box.textContent = (r && r.text) ? r.text : '(无结果)';
		});
	},

	handleNetTest: function () {
		const msg = document.getElementById('vnt-net-msg');
		if (!msg) return;
		msg.innerHTML = '';
		msg.appendChild(badge('正在测试连通性…', ''));
		return callNetTest().then(function (r) {
			msg.innerHTML = '';
			msg.appendChild(badge(r.msg, r.ok ? 'ok' : 'bad'));
		});
	},

	// ---------------- 渲染 ----------------
	render: function () {
		const m = new form.Map('vnt2web', 'VNT 组网（Web 版）',
			'把 vnt2_web 封装成 OpenWrt 服务：本页只负责端口、监听地址、访问令牌与核心更新。' +
			'组网的新增与启停全部在 vnt2_web 自带的网页面板里完成。');

		// --- 服务设置（合并为单一区块）---
		// 原本分成「服务设置 / 存储路径 / 其它 / 核心更新源」四个独立框，
		// 视觉上过于零碎。这里合并成一个「服务设置」，用中文小标题分组，
		// 保持可读性的同时减少框的数量。
		const s1 = m.section(form.NamedSection, 'main', 'vnt2web', '服务设置',
			'所有设置项在同一个区块内，按功能分组。改完记得「保存并应用」——' +
			'保存后 procd 会自动重启服务使配置生效。');
		s1.anonymous = true;

		let o;

		// ---- 基本 ----
		o = s1.option(form.Flag, 'enabled', '启用服务',
			'关闭后即使调用启动也不会运行，适合临时停用而不丢配置。' +
			'勾选并保存即启动，取消并保存即停止。');
		o.rmempty = false;

		// 监听地址不再提供配置项：固定 0.0.0.0（局域网内可直接打开面板）。
		// 需要限制访问时用防火墙规则更合适，不必改应用配置。
		o = s1.option(form.Value, 'port', '监听端口',
			'组网面板的访问端口。监听 <code>0.0.0.0</code>（全部网卡），' +
			'局域网内其它设备也能直接打开。修改后需重启服务。');
		o.datatype = 'port';
		o.placeholder = '19099';
		o.default = '19099';
		o.rmempty = false;

		o = s1.option(form.Value, 'token', '访问令牌',
			'打开组网面板所需，<strong>至少 16 位</strong>。' +
			'留空则首次启动时自动随机生成一个。');
		o.placeholder = '至少 16 位，留空自动生成';
		o.rmempty = true;
		// 已填写时校验长度，避免存进去一个核心不接受的短令牌
		o.validate = function (section_id, value) {
			if (value == null || value === '')
				return true;
			if (String(value).length < 16)
				return '访问令牌至少需要 16 位';
			if (/\s/.test(String(value)))
				return '访问令牌不能包含空格';
			return true;
		};

		// ---- 存储路径 ----
		o = s1.option(form.Value, 'bin_path', '核心二进制路径',
			'默认 <code>/usr/bin/vnt2web</code>。<br>' +
			'<strong>权衡</strong>：<code>/usr</code> 在升级固件时会被系统替换，' +
			'核心需要重新下载；若改到 <code>/etc</code> 下（如 ' +
			'<code>/etc/vnt2web/bin/vnt2_web</code>），升级固件后核心仍在，可省去重新下载。' +
			'也可放到挂载的 U 盘上（如 <code>/mnt/sda1/vnt2_web</code>）以节省内置 Flash。');
		o.placeholder = '留空即 /usr/bin/vnt2web';
		o.rmempty = true;

		o = s1.option(form.Value, 'config_dir', '配置路径',
			'默认 <code>/etc/vnt2web/config</code>。放 <code>/etc</code> 下是有意的：' +
			'升级固件时 <code>sysupgrade</code> 只保留 <code>/etc</code>，组网配置得以延续。' +
			'核心会在该目录下创建 <code>vnt_config/</code>。日志固定放 <code>/tmp</code>，不占 Flash。');
		o.placeholder = '留空即 /etc/vnt2web/config';
		o.rmempty = true;

		// ---- 更新源 ----
		o = s1.option(form.Value, 'mirror', 'GitHub 代理地址',
			'下载核心时把 GitHub 地址改写到镜像站，只需 URL 拼接。' +
			'留空表示直连 GitHub。<br>例：<code>https://ghfast.top</code>');
		o.placeholder = '例如 https://ghfast.top';
		o.rmempty = true;

		o = s1.option(form.Value, 'proxy', 'SOCKS 代理地址',
			'让下载请求经由代理隧道。留空直连。<br>' +
			'支持 <code>socks5h://</code>（推荐，由代理解析 DNS）、' +
			'<code>socks5://</code>、<code>socks4://</code>、<code>http://</code>。<br>' +
			'<strong>走代理需要系统已安装 curl</strong>。例：<code>socks5h://127.0.0.1:1080</code>');
		o.placeholder = '例如 socks5h://127.0.0.1:1080';
		o.rmempty = true;

		// 「测试连通性」按钮不在这里 —— 它属于「核心更新」标签，
		// 与「更新核心」放在一起（下载走的就是这两项配置）。

		// ---- 其它 ----
		o = s1.option(form.ListValue, 'log_level', '日志级别',
			'核心日志的详细程度。排查问题时可用 <code>debug</code>。');
		o.value('error', 'error');
		o.value('warn', 'warn');
		o.value('info', 'info（默认）');
		o.value('debug', 'debug');
		o.default = 'info';
		o.rmempty = true;

		o = s1.option(form.Flag, 'fw_auto', '自动把虚拟网卡加入防火墙',
			'启动后自动把 vnt 网卡加入 lan 区域，否则跨网段（点对网）流量会被防火墙丢弃。');
		o.default = '1';

		return m.render().then(L.bind(function (node) {
			// m.render() 返回 <div class="cbi-map">，含标题(h2)与说明，
			// 以及表单渲染出的 <div class="cbi-section">。
			//
			// 这里把内容重组成「标签页 + 卡片」布局（对齐 fnos 版的观感）：
			//   状态条 → 标签栏 → 当前标签的卡片内容
			//   核心更新 / 访问设置 / 组网面板 / 日志
			//
			// 注意：LuCI 的「保存并应用」按钮在 mapEl **之外**（由 view 框架生成），
			// 因此只重排 mapEl 内部不会影响保存功能。
			const mapEl = node;
			ensureStyle();

			// 取出表单渲染出的 section（合并后只剩「服务设置」一个）
			let formSections = Array.prototype.slice.call(
				mapEl.querySelectorAll(':scope > .cbi-section'));
			if (formSections.length === 0) {
				// 老浏览器不支持 :scope 选择器时的兜底
				formSections = Array.prototype.slice.call(mapEl.childNodes)
					.filter(function (n) {
						return n.nodeType === 1 && n.classList &&
							n.classList.contains('cbi-section');
					});
			}

			// ---- 状态条 ----
			const statusBar = E('div', { 'class': 'vnt-status' }, [
				pill(ST.running ? '核心运行中' : '核心已停止',
					ST.running ? 'on' : 'off'),
				pill(ST.installed ? ('v' + (ST.version || '已安装')) : '核心未下载',
					ST.installed ? null : 'off'),
				ST.running && ST.port_listening ? pill('端口已监听', 'on') : '',
				ST.panel_url ? E('span', { 'class': 'mono',
					'style': 'color:#99a0aa;font-size:12px;margin-left:4px' },
					ST.panel_url) : ''
			]);

			// ---- 标签栏 ----
			const TAB_DEFS = [
				{ id: 'core', label: '核心更新' },
				{ id: 'access', label: '访问设置' },
				{ id: 'panel', label: '组网面板' },
				{ id: 'logs', label: '日志' }
			];
			const tabNav = E('nav', { 'class': 'vnt-tabs', 'role': 'tablist' });

			// ---- 各标签内容 ----
			// 表单 section 原地移入「访问设置」，这样 uci 读写与校验仍照常工作
			const paneAccess = E('div', { 'class': 'vnt-pane', 'data-pane': 'access' });
			formSections.forEach(function (sec) {
				paneAccess.appendChild(sec);   // 移动而非重建，表单状态不丢
			});

			const panes = {
				core: E('div', { 'class': 'vnt-pane', 'data-pane': 'core' },
					[ buildOverview(this) ]),
				access: paneAccess,
				panel: E('div', { 'class': 'vnt-pane', 'data-pane': 'panel' },
					[ buildPanel(this) ]),
				logs: E('div', { 'class': 'vnt-pane', 'data-pane': 'logs' },
					[ buildLogs(this), buildDiag(this) ])
			};

			// 标签切换：用 .active 类控制显隐（CSS 里已定义 .vnt-pane 默认隐藏）。
			// 不用内联 style —— 那样一旦被框架重排覆盖就会失效。
			let activeTab = 'core';
			const self = this;
			function switchTab(id) {
				activeTab = id;
				Array.prototype.forEach.call(
					tabNav.querySelectorAll('.vnt-tab'), function (b) {
						b.classList.toggle('active', b.getAttribute('data-tab') === id);
					});
				Object.keys(panes).forEach(function (k) {
					panes[k].classList.toggle('active', k === id);
				});
				// 切到「组网面板」时再载入 iframe，避免页面一打开就请求
				if (id === 'panel') self.handleReloadFrame();
			}

			TAB_DEFS.forEach(function (t) {
				tabNav.appendChild(E('button', {
					'class': 'vnt-tab' + (t.id === 'core' ? ' active' : ''),
					'data-tab': t.id, 'role': 'tab',
					'click': function () { switchTab(t.id); }
				}, t.label));
			});

			// 先定好初始标签（在挂载前就设好类，避免出现「全都显示/全都不显示」
			// 的一帧 —— 那正是需要刷新才恢复的闪烁来源）。
			switchTab('core');

			// 收集 LuCI 生成的标题(h2)与说明，稍后放进头部卡片
			const keep = [];
			Array.prototype.forEach.call(mapEl.childNodes, function (n) {
				if (n.nodeType === 1 && (n.tagName === 'H2' ||
					(n.classList && n.classList.contains('cbi-map-descr'))))
					keep.push(n);
			});

			// ---- 组装 ----
			// 头部卡片：把 LuCI 生成的标题与说明也放进卡片里（与 fnos 的
			// 品牌栏观感一致），右侧跟随核心状态胶囊。
			const headerCard = E('div', { 'class': 'vnt-card vnt-header' }, [
				E('div', { 'class': 'vnt-header-main' }, keep.concat([ statusBar ]))
			]);

			const wrap = E('div', { 'class': 'vnt-pane-wrap' }, [
				headerCard, tabNav,
				panes.core, panes.access, panes.panel, panes.logs
			]);

			// 清空 mapEl，把标题/说明交给头部卡片承载（不再直接挂在 mapEl 下）
			while (mapEl.firstChild) mapEl.removeChild(mapEl.firstChild);
			mapEl.appendChild(wrap);

			// 挂载后再确认一次标签状态，抵抗框架可能的重排
			switchTab('core');

			// 初始化：加载日志
			window.setTimeout(L.bind(function () {
				this.handleLoadLog();
			}, this), 300);
			return node;
		}, this));
	}

	// 注意：这里**故意不覆写 handleSaveApply**。
	//
	// LuCI 的标准保存流程（uci apply）会弹一个进度模态框，它没有确定按钮，
	// 靠「轮询 admin/uci/confirm 成功 → 自动刷新页面」来关闭。若在 super()
	// 之后再自行调用 RPC 去重启服务（此前的做法），会与这个轮询互相干扰，
	// 导致模态框一直收不到成功响应、**永远关不掉**（表现为「点击不了确定」）。
	//
	// 本插件配置生效本来就不需要前端额外操作：init 脚本已声明
	//   procd_add_reload_trigger "vnt2web"
	// 因此 uci apply 之后，procd 会**自动**触发 reload_service（stop + start），
	// 新配置随之生效。前端什么都不用做。
});
