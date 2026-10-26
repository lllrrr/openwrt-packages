'use strict';

/*
 * smartmwan —— rpcd ucode 桥（零 Lua）
 *
 * 位置：/usr/share/rpcd/ucode/smartmwan.uc（rpcd 启动时加载）。
 * 职责只有三件事：
 *   1. 声明 ubus 对象 `smartmwan` 的 29 个方法及其参数策略（rpcd 据此做
 *      ACL 与参数校验，本文件不做任何业务判断）；
 *   2. 连接守护进程的 Unix socket（global.rpc_socket），按
 *      「4 字节大端长度前缀 + JSON」帧转发请求；
 *   3. 把传输层错误映射成 rpcd 状态码，守护进程的业务信封（ok/data/error）
 *      原样透传给前端 —— 语义只在 Rust 侧产生，这里不补刀。
 *
 * 授权粒度在 root/usr/share/rpcd/acl.d/luci-app-smartmwan.json，按方法逐个授权。
 *
 * 同步约束：增改方法必须同时改 src/rpc/mod.rs::METHODS、
 * docs/ARCHITECTURE.md §6 方法表、以及本文件。
 */

const fs = require('fs');
const socket = require('socket');

/* ---- 配置 ---- */

// 与 schema.rs 的默认值一致；UCI 里的 global.rpc_socket 优先。
const DEFAULT_SOCKET_PATH = '/var/run/smartmwan/rpc.sock';
const CONFIG_FILE = '/etc/config/smartmwan';

// 传输层超时：一次 apply 含探测轮与完整事务（nft 5s 级），给足余量。
// 到点读不到完整帧就断，绝不把 rpcd 主loop 无限期占住。
const IO_TIMEOUT_SEC = 15;

// 与 src/rpc/mod.rs 的 MAX_FRAME_BYTES 一致；超大帧直接判传输错误。
const FRAME_MAX = 512 * 1024;

/* ---- socket 路径解析 ----
 *
 * 优先 uci 模块（rpcd 的 VM 默认带）；取不到再退回直接解析 UCI 文本
 * （uci 模块缺失时桥仍然可用）；最后才是编译期默认值。
 * 三层都不猜：拿不到就当配了默认值，并在日志里说明用了哪一层。
 */

function path_from_uci_module() {
	const uci = require('uci');
	const ctx = uci.cursor();
	const path = ctx.get('smartmwan', '@global[-1]', 'rpc_socket');
	return (path && length(path)) ? path : null;
}

function path_from_config_text() {
	const f = fs.open(CONFIG_FILE, 'r');
	if (!f)
		return null;
	const text = f.read('all');
	f.close();
	if (!text)
		return null;
	// 只认 config smartmwan 'global' 段里的 option rpc_socket '...'。
	// 手写解析而非全局扫描：段边界要算准，不能把别处的同名键捡回来。
	let in_global = false;
	const lines = split(text, "\n");
	for (let i = 0; i < length(lines); i++) {
		const line = trim(lines[i]);
		if (match(line, /^config\s+smartmwan\s+'global'/))
			in_global = true;
		else if (match(line, /^config\s+/))
			in_global = false;
		else if (in_global && match(line, /^option\s+rpc_socket\s+'([^']+)'/))
			return match(line, /^option\s+rpc_socket\s+'([^']+)'/)[1];
	}
	return null;
}

function socket_path() {
	try {
		const p = path_from_uci_module();
		if (p)
			return p;
	} catch (e) {
		// uci 模块不可用：不是错误，走下一层。
	}
	try {
		const p = path_from_config_text();
		if (p)
			return p;
	} catch (e) {
		// 配置文件读不到：用默认值。
	}
	return DEFAULT_SOCKET_PATH;
}

/* ---- 帧编解码（与 src/rpc/mod.rs 的 encode_frame/read_frame 对应） ---- */

function frame_encode(obj) {
	// 注意：ucode 的 json() 只做**解析**；序列化是 sprintf('%J', …)。
	const body = sprintf('%J', obj);
	const n = length(body);
	if (n > FRAME_MAX)
		return null;
	// 4 字节大端长度前缀。chr() 按字节构串，>127 的值也安全。
	const prefix = chr((n >> 24) & 0xff, (n >> 16) & 0xff, (n >> 8) & 0xff, n & 0xff);
	return prefix + body;
}

function frame_read(sock) {
	let head = '';
	while (length(head) < 4) {
		const chunk = sock.recv(4 - length(head));
		if (chunk === null || chunk === '')
			return null;
		head += chunk;
	}
	const n = (ord(head, 0) << 24) | (ord(head, 1) << 16) | (ord(head, 2) << 8) | ord(head, 3);
	if (n <= 0 || n > FRAME_MAX)
		return null;
	let body = '';
	while (length(body) < n) {
		const chunk = sock.recv(n - length(body));
		if (chunk === null || chunk === '')
			return null;
		body += chunk;
	}
	return body;
}

/* ---- 转发 ---- */

// 返回守护进程的信封对象；传输层失败返回 null（调用方映射成 rpcd 错误）。
function forward(method, params) {
	const path = socket_path();
	// unix socket 必须走「create + 实例 connect」：高层 socket.connect() 走
	// getaddrinfo，只认 IP/主机名；实例 connect 的字符串参数含 '/' 时按
	// AF_UNIX 路径解析（见 ucode socket 模块的 uv_to_sockaddr）。
	const sock = socket.create(socket.AF_UNIX, socket.SOCK_STREAM, 0);
	if (!sock)
		return null;
	if (!sock.connect(path)) {
		sock.close();
		return null;
	}
	// 读超时：守护进程应在秒级应答；到点不断就把连接断掉。
	sock.setopt(socket.SOL_SOCKET, socket.SO_RCVTIMEO, { tv_sec: IO_TIMEOUT_SEC, tv_usec: 0 });
	// ucode 的 try 不支持 finally，关连接只能各路径显式做 —— 两条 return 前都关。
	let env = null;
	try {
		const frame = frame_encode({ method: method, params: params ?? {} });
		if (frame !== null && sock.send(frame) === length(frame)) {
			const body = frame_read(sock);
			if (body !== null)
				env = json(body);
		}
	} catch (e) {
		env = null;
	}
	sock.close();
	return env;
}

/* ---- 方法实现 ----
 *
 * 每个方法做三件事：转发、把信封原样返回（ok=false 也要带 details 回去，
 * 前端四态渲染要靠它）、传输层失败才 req.error()。
 */

function call_daemon(req, method) {
	const env = forward(method, req.args);
	if (env === null) {
		req.error(UBUS_STATUS_CONNECTION_FAILED,
			sprintf('无法连接 smartmwan 守护进程（%s）：检查是否已启动', socket_path()));
		return null;
	}
	return env;
}

const no_args = {};
const line_arg = { wan: "" };
// 注意：rpcd-mod-ucode 把整数 typehint 的**值**当位宽（8→INT8、16→INT16、64→INT64、
// 其余→INT32），不是默认值 —— 声明 limit:16 会让 INT32 实参被拒（真机实测踩坑）。
// 数字参数一律写 0（→INT32），默认值由守护进程侧解析兜底。
const log_args = { level: "", limit: 0 };
const config_arg = { config: {} };
const force_args = { wan: "", confirm: true };
const maint_args = { wan: "", on: true };
// 便捷设置：只传一个字段，由守护进程校验并触发一轮事务。
const mode_arg = { mode: "" };
const algorithm_arg = { algorithm: "" };
const primary_arg = { wan: "" };
const order_arg = { order: [] };

return {
	smartmwan: {
		hello: {
			call: function(req) { return call_daemon(req, 'smartmwan.hello'); }
		},
		getStatus: {
			call: function(req) { return call_daemon(req, 'smartmwan.getStatus'); }
		},
		getLines: {
			call: function(req) { return call_daemon(req, 'smartmwan.getLines'); }
		},
		getLine: {
			args: line_arg,
			call: function(req) { return call_daemon(req, 'smartmwan.getLine'); }
		},
		getBalance: {
			call: function(req) { return call_daemon(req, 'smartmwan.getBalance'); }
		},
		getFailover: {
			call: function(req) { return call_daemon(req, 'smartmwan.getFailover'); }
		},
		getGames: {
			call: function(req) { return call_daemon(req, 'smartmwan.getGames'); }
		},
		getGameQuality: {
			call: function(req) { return call_daemon(req, 'smartmwan.getGameQuality'); }
		},
		getConnections: {
			call: function(req) { return call_daemon(req, 'smartmwan.getConnections'); }
		},
		getTraffic: {
			call: function(req) { return call_daemon(req, 'smartmwan.getTraffic'); }
		},
		getLogs: {
			args: log_args,
			call: function(req) { return call_daemon(req, 'smartmwan.getLogs'); }
		},
		getConfig: {
			call: function(req) { return call_daemon(req, 'smartmwan.getConfig'); }
		},
		getCapabilities: {
			call: function(req) { return call_daemon(req, 'smartmwan.getCapabilities'); }
		},
		validate: {
			args: config_arg,
			call: function(req) { return call_daemon(req, 'smartmwan.validate'); }
		},
		diff: {
			call: function(req) { return call_daemon(req, 'smartmwan.diff'); }
		},
		save: {
			args: config_arg,
			call: function(req) { return call_daemon(req, 'smartmwan.save'); }
		},
		apply: {
			call: function(req) { return call_daemon(req, 'smartmwan.apply'); }
		},
		rollback: {
			call: function(req) { return call_daemon(req, 'smartmwan.rollback'); }
		},
		forceWan: {
			args: force_args,
			call: function(req) { return call_daemon(req, 'smartmwan.forceWan'); }
		},
		releaseForced: {
			call: function(req) { return call_daemon(req, 'smartmwan.releaseForced'); }
		},
		setMaintenance: {
			args: maint_args,
			call: function(req) { return call_daemon(req, 'smartmwan.setMaintenance'); }
		},
		probeNow: {
			call: function(req) { return call_daemon(req, 'smartmwan.probeNow'); }
		},
		reload: {
			call: function(req) { return call_daemon(req, 'smartmwan.reload'); }
		},
		switchMode: {
			args: mode_arg,
			call: function(req) { return call_daemon(req, 'smartmwan.switchMode'); }
		},
		setPrimary: {
			args: primary_arg,
			call: function(req) { return call_daemon(req, 'smartmwan.setPrimary'); }
		},
		setBackupOrder: {
			args: order_arg,
			call: function(req) { return call_daemon(req, 'smartmwan.setBackupOrder'); }
		},
		setAlgorithm: {
			args: algorithm_arg,
			call: function(req) { return call_daemon(req, 'smartmwan.setAlgorithm'); }
		},
		failback: {
			call: function(req) { return call_daemon(req, 'smartmwan.failback'); }
		},
		diagnostics: {
			call: function(req) { return call_daemon(req, 'smartmwan.diagnostics'); }
		}
	}
};
