// probe-sock.uc —— 探测修「拒绝路径 RST 丢响应」所需的 socket 能力
// 目标：搞清楚能不能在 send(503) 前后把客户端已发来的请求字节读走。
import * as socket from 'socket';

function has(name) {
	try {
		let v = socket[name];
		return (v === undefined) ? 'undefined' : (v === null ? 'null' : '' + v);
	} catch (e) {
		return 'ERR:' + e;
	}
}

print('=== socket 常量/方法可用性 ===\n');
for (let k in ['MSG_DONTWAIT', 'MSG_PEEK', 'SHUT_WR', 'SHUT_RDWR', 'SO_LINGER', 'SOCK_CLOEXEC', 'IPPROTO_TCP', 'TCP_NODELAY']) {
	print(sprintf('socket.%-12s = %s\n', k, has(k)));
}

// 建一个临时监听口做真实验证（用 127.0.0.1:18799，不碰 8788）
let srv = socket.create(socket.AF_INET, socket.SOCK_STREAM, 0);
try { srv.setopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, true); } catch (e) { print('setopt SO_REUSEADDR: ' + e + '\n'); }
if (!srv.bind('127.0.0.1:18799')) { print('bind failed: ' + srv.error() + '\n'); exit(1); }
srv.listen(8);
print('\n=== 监听 127.0.0.1:18799 ok ===\n');

// 客户端：连上后立即发一个请求（复现「接收队列非空」的场景）
let cli = socket.create(socket.AF_INET, socket.SOCK_STREAM, 0);
cli.connect('127.0.0.1:18799');
cli.send('GET /health HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n');

// 服务端 accept
let addr = {};
let peer = srv.accept(addr, socket.SOCK_CLOEXEC);
print('accept ok, peer=' + (peer ? 'yes' : 'no') + ' addr=' + addr.address + '\n');

print('\n=== peer 上的可用方法 ===\n');
for (let m in ['recv', 'send', 'close', 'shutdown', 'setopt', 'getopt', 'fileno', 'error']) {
	let t = 'n/a';
	try { t = typeof(peer[m]); } catch (e) { t = 'ERR:' + e; }
	print(sprintf('peer.%-10s typeof = %s\n', m, t));
}

// 关键：非阻塞读能否拿到已排队的请求字节？recv 返回什么表示「没数据了」？
print('\n=== 非阻塞 recv 行为测试 ===\n');
let flags = (socket.MSG_DONTWAIT !== undefined && socket.MSG_DONTWAIT !== null) ? socket.MSG_DONTWAIT : 0;
print('使用 flags = ' + flags + '\n');
for (let i = 0; i < 4; i++) {
	let got;
	try {
		got = peer.recv(8192, flags);
	} catch (e) {
		print(sprintf('  #%d recv threw: %s\n', i, e));
		break;
	}
	if (got === null) {
		print(sprintf('  #%d recv = null  (→ 无更多数据/出错：%s)\n', i, peer.error()));
		break;
	}
	print(sprintf('  #%d recv len=%d  %s\n', i, length(got), JSON.stringify(substr('' + got, 0, 40))));
	if (length(got) === 0) break;
}

print('\n=== shutdown(SHUT_WR) 可用性 ===\n');
let shOk = 'unknown';
try {
	shOk = '' + peer.shutdown(socket.SHUT_WR);
} catch (e) {
	shOk = 'threw: ' + e;
}
print('peer.shutdown(SHUT_WR) = ' + shOk + '\n');

try { peer.close(); } catch (e) { print('peer.close err: ' + e + '\n'); }
try { cli.close(); } catch (e) { }
try { srv.close(); } catch (e) { }
print('\n=== done ===\n');
