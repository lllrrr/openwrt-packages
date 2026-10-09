'use strict';
'require view';
'require form';
'require rpc';
'require uci';
'require ui';
'require poll';
'require dom';

const CONFIG = 'frpc_multi';

const callStatus = rpc.declare({ object: 'luci.frpc-multi', method: 'status', expect: { connections: [] } });
const callLog = rpc.declare({ object: 'luci.frpc-multi', method: 'log', params: ['id', 'lines'], expect: { log: '' } });
const callAction = rpc.declare({ object: 'luci.frpc-multi', method: 'action', params: ['id', 'op'] });

const STYLE = E('style', {}, [`
.fm-cards{display:grid;grid-template-columns:repeat(auto-fill,minmax(340px,1fr));gap:12px;margin:8px 0 18px}
.fm-card{border:1px solid var(--border-color-medium,#ddd);border-radius:8px;padding:12px 16px;background:var(--background-color-high,#fff)}
.fm-head{display:flex;align-items:center;gap:8px;flex-wrap:wrap}
.fm-head b{font-size:1.05em}
.fm-head>span{margin-left:auto;font-size:.9em}
.fm-dot{width:10px;height:10px;border-radius:50%;display:inline-block;flex:0 0 auto}
.fm-ok{background:#2e9e44}.fm-warn{background:#e0a100}.fm-bad{background:#d63b3b}.fm-off{background:#999}
.fm-sub{opacity:.75;font-size:.9em;margin:2px 0 8px}
.fm-plist{width:100%;border-collapse:collapse;font-size:.88em}
.fm-plist td{padding:3px 4px;border-top:1px solid var(--border-color-low,#eee);vertical-align:top}
.fm-err{color:#d63b3b;font-size:.85em;word-break:break-all}
.fm-btns{margin-top:10px;display:flex;gap:6px;flex-wrap:wrap}
.fm-log{white-space:pre-wrap;font-family:monospace;font-size:12px;max-height:60vh;overflow:auto;background:#111;color:#ddd;padding:10px;border-radius:6px}
`]);

function badge(cls, text) {
	return E('span', {}, [E('span', { 'class': 'fm-dot ' + cls }), ' ', text]);
}

function connBadge(c) {
	if (!c.enabled) return badge('fm-off', _('已停用'));
	if (!c.running) return badge('fm-bad', _('未运行'));
	if (c.api != 'ok') return badge('fm-warn', _('运行中'));
	const live = Object.values(c.live);
	if (live.length && live.every(p => p.status == 'running')) return badge('fm-ok', _('已连接'));
	if (live.some(p => p.status == 'running')) return badge('fm-warn', _('部分异常'));
	return badge('fm-warn', _('未连接'));
}

function proxyBadge(c, p) {
	if (!p.enabled) return badge('fm-off', _('停用'));
	const l = c.live[p.name];
	if (!c.running || !l) return badge('fm-off', '—');
	if (l.status == 'running') return badge('fm-ok', _('在线'));
	return badge('fm-bad', l.status || _('异常'));
}

function showLog(id, name) {
	const pre = E('div', { 'class': 'fm-log' }, _('加载中…'));
	ui.showModal(_('日志') + ' — ' + name, [
		pre,
		E('div', { 'class': 'right', 'style': 'margin-top:8px' }, [
			E('button', { 'class': 'btn', 'click': () => callLog(id, 300).then(t => { pre.textContent = t || _('暂无日志'); pre.scrollTop = pre.scrollHeight; }) }, _('刷新')),
			' ',
			E('button', { 'class': 'btn cbi-button-neutral', 'click': ui.hideModal }, _('关闭'))
		])
	]);
	callLog(id, 300).then(t => { pre.textContent = t || _('暂无日志'); pre.scrollTop = pre.scrollHeight; });
}

function doAction(id, op) {
	if (op == 'disable' && !confirm(_('停用后该连接将断开，开机和看门狗都不会再启动它。确定停用？')))
		return Promise.resolve();
	return callAction(id, op).then(r => {
		if (r && r.error) {
			ui.addNotification(null, E('p', r.error), 'danger');
			return refresh();
		}
		// enable/disable changed the saved config: reload so the forms below match it
		if (op != 'restart') {
			window.location.reload();
			return;
		}
		return refresh();
	});
}

let cardsEl;

function renderCards(conns) {
	if (!conns.length)
		return E('p', { 'class': 'fm-sub' }, _('暂无连接，点击下方「添加连接…」开始配置。'));
	return E('div', { 'class': 'fm-cards' }, conns.map(c => {
		const rows = c.proxies.map(p => {
			const l = c.live[p.name];
			return E('tr', {}, [
				E('td', {}, [E('b', {}, p.name), E('div', { 'class': 'fm-sub' }, p.type + (p.role == 'visitor' ? ' visitor' : ''))]),
				E('td', {}, [p.local, ' → ', p.remote || '—']),
				E('td', {}, [proxyBadge(c, p), l && l.err ? E('div', { 'class': 'fm-err' }, l.err) : ''])
			]);
		});
		return E('div', { 'class': 'fm-card' }, [
			E('div', { 'class': 'fm-head' }, [E('b', {}, c.name), connBadge(c)]),
			E('div', { 'class': 'fm-sub' }, [c.server, c.pid ? '  ·  PID ' + c.pid : '']),
			rows.length ? E('table', { 'class': 'fm-plist' }, rows) : E('div', { 'class': 'fm-sub' }, _('暂无代理规则')),
			E('div', { 'class': 'fm-btns' }, [
				c.enabled
					? E('button', { 'class': 'btn cbi-button-action', 'click': ui.createHandlerFn(this, doAction, c.id, 'restart') }, _('重启'))
					: '',
				c.enabled
					? E('button', { 'class': 'btn cbi-button-reset', 'click': ui.createHandlerFn(this, doAction, c.id, 'disable') }, _('停用'))
					: E('button', { 'class': 'btn cbi-button-apply', 'click': ui.createHandlerFn(this, doAction, c.id, 'enable') }, _('启用')),
				E('button', { 'class': 'btn', 'click': () => showLog(c.id, c.name) }, _('日志'))
			])
		]);
	}));
}

function refresh() {
	return callStatus().then(conns => {
		if (cardsEl) dom.content(cardsEl, renderCards(conns));
	});
}

function connName(sid) {
	return uci.get(CONFIG, sid, 'alias') || sid;
}

function serverChoices(o) {
	uci.sections(CONFIG, 'server').forEach(s => o.value(s['.name'], s.alias || s['.name']));
}

// Internal ID for a new connection: c1, c2, ... (first one not already used).
// Only letters/digits, so it is valid for UCI and for the process/log tag frpc-<ID>.
function newConnId() {
	const used = {};
	uci.sections(CONFIG).forEach(s => { used[s['.name']] = true; });
	for (let i = 1; ; i++)
		if (!used['c' + i])
			return 'c' + i;
}

return view.extend({
	load() {
		return Promise.all([uci.load(CONFIG), callStatus()]);
	},

	render(data) {
		const m = new form.Map(CONFIG, _('frp 多客户端'),
			_('每个连接对应一个独立的 frpc 进程，可同时连接多个 frp 服务端。'));

		let s, o;

		// --- live status ---
		s = m.section(form.NamedSection, '_status');
		s.render = () => {
			cardsEl = E('div', {}, renderCards(data[1]));
			poll.add(refresh, 5);
			return E('div', { 'class': 'cbi-section' }, [STYLE, E('h3', {}, _('运行状态')), cardsEl]);
		};

		// --- global ---
		s = m.section(form.NamedSection, 'global', 'global', _('全局'));
		s.addremove = false;
		o = s.option(form.Flag, 'enabled', _('启用插件'));
		o.default = '1'; o.rmempty = false;
		o = s.option(form.Flag, 'watchdog', _('看门狗'), _('每分钟检查一次，自动拉起意外退出的连接。'));
		o.default = '1'; o.rmempty = false;

		// --- connections ---
		s = m.section(form.GridSection, 'server', _('连接'));
		s.addremove = true;
		// anonymous: no section-name input box; the visible name is the 名称 (alias) field.
		// Sections still get a stable internal ID (auto-generated for new ones) that is
		// only used for the process/log tag frpc-<ID>.
		s.anonymous = true;
		s.sortable = true;
		s.nodescriptions = true;
		s.addbtntitle = _('添加连接…');
		s.modaltitle = (sid) => _('连接') + ' — ' + (uci.get(CONFIG, sid, 'alias') || _('新连接'));
		s.handleAdd = function(ev) {
			return form.GridSection.prototype.handleAdd.call(this, ev, newConnId());
		};

		s.tab('basic', _('基本'));
		s.tab('transport', _('传输'));
		s.tab('advanced', _('高级'));

		o = s.taboption('basic', form.Value, 'alias', _('名称'),
			_('仅用于本页面显示，可随时修改。'));
		o.placeholder = _('例如：香港节点');
		o.rmempty = false;
		o.validate = function(sid, value) {
			value = (value || '').trim();
			if (!value)
				return _('请填写名称');
			const dup = uci.sections(CONFIG, 'server').some(x => x['.name'] != sid && (x.alias || '').trim() == value);
			return dup ? _('已有同名连接，请换一个名称') : true;
		};
		o = s.taboption('basic', form.Flag, 'enabled', _('启用'));
		o.default = '1'; o.rmempty = false; o.editable = true;
		o = s.taboption('basic', form.DummyValue, '_id', _('内部 ID'),
			_('自动生成，用于进程名和日志标识。'));
		o.modalonly = true;
		o.cfgvalue = (sid) => sid;
		o = s.taboption('basic', form.Value, 'server_addr', _('服务端地址'));
		o.datatype = 'host'; o.rmempty = false;
		o = s.taboption('basic', form.Value, 'server_port', _('服务端端口'));
		o.datatype = 'port'; o.placeholder = '7000';
		o = s.taboption('basic', form.Value, 'token', _('令牌'));
		o.password = true; o.modalonly = true;
		o = s.taboption('basic', form.Flag, 'login_fail_exit', _('登录失败即退出'),
			_('建议关闭，关闭后连接失败会持续重试，开机时网络较晚就绪也能自动连上。'));
		o.default = '0'; o.modalonly = true;
		o = s.taboption('basic', form.Value, 'user', _('用户名前缀'),
			_('多台客户端连接同一服务端时，用于区分代理名，一般留空。'));
		o.modalonly = true;

		o = s.taboption('transport', form.ListValue, 'protocol', _('协议'));
		['tcp', 'kcp', 'quic', 'websocket', 'wss'].forEach(v => o.value(v));
		o.default = 'tcp'; o.modalonly = true;
		o = s.taboption('transport', form.Flag, 'tls_enable', _('TLS 加密'), _('需与服务端设置一致。'));
		o.default = '1'; o.rmempty = false; o.modalonly = true;
		o = s.taboption('transport', form.Flag, 'tcp_mux', _('TCP 多路复用'));
		o.default = '1'; o.modalonly = true;
		o = s.taboption('transport', form.Value, 'pool_count', _('连接池数量'));
		o.datatype = 'uinteger'; o.placeholder = '0'; o.modalonly = true;
		o = s.taboption('transport', form.Value, 'heartbeat_interval', _('心跳间隔（秒）'));
		o.datatype = 'integer'; o.placeholder = '30'; o.modalonly = true;
		o = s.taboption('transport', form.Value, 'heartbeat_timeout', _('心跳超时（秒）'));
		o.datatype = 'integer'; o.placeholder = '90'; o.modalonly = true;
		o = s.taboption('transport', form.Value, 'http_proxy', _('通过代理连接'),
			_('如 http://127.0.0.1:7890 或 socks5://127.0.0.1:7891，留空为直连。'));
		o.modalonly = true;

		o = s.taboption('advanced', form.Value, 'dns_server', _('DNS 服务器'));
		o.datatype = 'ipaddr'; o.modalonly = true;
		o = s.taboption('advanced', form.ListValue, 'log_level', _('日志级别'));
		['trace', 'debug', 'info', 'warn', 'error'].forEach(v => o.value(v));
		o.default = 'info'; o.modalonly = true;
		o = s.taboption('advanced', form.Flag, 'respawn', _('异常退出后自动重启'));
		o.default = '1'; o.modalonly = true;
		o = s.taboption('advanced', form.DynamicList, 'extra', _('附加 TOML 行'),
			_('直接写入该连接配置，如 <code>transport.dialServerTimeout = 10</code>。'));
		o.modalonly = true;

		o = s.option(form.DummyValue, '_addr', _('服务端'));
		o.modalonly = false;
		o.textvalue = (sid) => (uci.get(CONFIG, sid, 'server_addr') || '?') + ':' + (uci.get(CONFIG, sid, 'server_port') || '7000');

		// --- proxies ---
		s = m.section(form.GridSection, 'proxy', _('代理规则'));
		s.addremove = true;
		s.anonymous = true;
		s.sortable = true;
		s.nodescriptions = true;
		s.addbtntitle = _('添加代理…');

		s.tab('general', _('常规'));
		s.tab('http', _('HTTP/域名'));
		s.tab('secret', _('STCP/XTCP'));
		s.tab('plugin', _('插件'));

		o = s.taboption('general', form.Flag, 'enabled', _('启用'));
		o.default = '1'; o.rmempty = false; o.editable = true;
		o = s.taboption('general', form.ListValue, 'server', _('所属连接'));
		serverChoices(o); o.rmempty = false;
		o.textvalue = (sid) => {
			const v = uci.get(CONFIG, sid, 'server');
			return v ? connName(v) : null;
		};
		o = s.taboption('general', form.Value, 'name', _('代理名'));
		o.rmempty = false; o.datatype = 'and(minlength(1),maxlength(64))';
		o = s.taboption('general', form.ListValue, 'type', _('类型'));
		['tcp', 'udp', 'http', 'https', 'tcpmux', 'stcp', 'xtcp', 'sudp'].forEach(v => o.value(v));
		o.default = 'tcp';
		o = s.taboption('general', form.Value, 'local_ip', _('本地地址'));
		o.datatype = 'host'; o.placeholder = '127.0.0.1'; o.modalonly = true;
		o = s.taboption('general', form.Value, 'local_port', _('本地端口'));
		o.datatype = 'port';
		o = s.taboption('general', form.Value, 'remote_port', _('远程端口'), _('服务端对外开放的端口，填 0 由服务端分配。'));
		o.datatype = 'port'; o.depends('type', 'tcp'); o.depends('type', 'udp');
		o = s.taboption('general', form.Flag, 'use_encryption', _('加密'));
		o.modalonly = true;
		o = s.taboption('general', form.Flag, 'use_compression', _('压缩'));
		o.modalonly = true;
		o = s.taboption('general', form.Value, 'bandwidth_limit', _('带宽限制'), _('如 1MB、500KB，留空不限制。'));
		o.modalonly = true;

		o = s.taboption('http', form.DynamicList, 'custom_domains', _('自定义域名'));
		['http', 'https', 'tcpmux'].forEach(t => o.depends('type', t)); o.modalonly = true;
		o = s.taboption('http', form.Value, 'subdomain', _('子域名'));
		['http', 'https', 'tcpmux'].forEach(t => o.depends('type', t)); o.modalonly = true;
		o = s.taboption('http', form.DynamicList, 'locations', _('路径（locations）'));
		o.depends('type', 'http'); o.modalonly = true;
		o = s.taboption('http', form.Value, 'http_user', _('HTTP 用户名'));
		o.depends('type', 'http'); o.modalonly = true;
		o = s.taboption('http', form.Value, 'http_password', _('HTTP 密码'));
		o.password = true; o.depends('type', 'http'); o.modalonly = true;
		o = s.taboption('http', form.Value, 'host_header_rewrite', _('改写 Host 头'));
		o.depends('type', 'http'); o.modalonly = true;

		o = s.taboption('secret', form.ListValue, 'role', _('角色'));
		o.value('server', _('被访问端')); o.value('visitor', _('访问端'));
		['stcp', 'xtcp', 'sudp'].forEach(t => o.depends('type', t)); o.modalonly = true;
		o = s.taboption('secret', form.Value, 'secret_key', _('密钥（secretKey）'));
		o.password = true; ['stcp', 'xtcp', 'sudp'].forEach(t => o.depends('type', t)); o.modalonly = true;
		o = s.taboption('secret', form.Value, 'server_name', _('要访问的代理名'));
		o.depends('role', 'visitor'); o.modalonly = true;
		o = s.taboption('secret', form.Value, 'bind_addr', _('本机监听地址'));
		o.placeholder = '127.0.0.1'; o.depends('role', 'visitor'); o.modalonly = true;
		o = s.taboption('secret', form.Value, 'bind_port', _('本机监听端口'));
		o.datatype = 'port'; o.depends('role', 'visitor'); o.modalonly = true;
		o = s.taboption('secret', form.DynamicList, 'allow_users', _('允许的访问用户'));
		o.depends('role', 'server'); o.modalonly = true;

		o = s.taboption('plugin', form.ListValue, 'plugin', _('插件'), _('使用插件时无需填写本地地址和端口。'));
		o.value('', _('不使用'));
		['http_proxy', 'socks5', 'static_file', 'unix_domain_socket'].forEach(v => o.value(v));
		o.modalonly = true;
		o = s.taboption('plugin', form.Value, 'plugin_user', _('插件用户名'));
		['http_proxy', 'socks5', 'static_file'].forEach(v => o.depends('plugin', v)); o.modalonly = true;
		o = s.taboption('plugin', form.Value, 'plugin_password', _('插件密码'));
		o.password = true; ['http_proxy', 'socks5', 'static_file'].forEach(v => o.depends('plugin', v)); o.modalonly = true;
		o = s.taboption('plugin', form.Value, 'plugin_local_path', _('文件目录'));
		o.depends('plugin', 'static_file'); o.modalonly = true;
		o = s.taboption('plugin', form.Value, 'plugin_unix_path', _('Unix 套接字路径'));
		o.depends('plugin', 'unix_domain_socket'); o.modalonly = true;

		return m.render();
	}
});
