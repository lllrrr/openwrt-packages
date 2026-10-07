// probe-sock2.uc —— 第二轮：搞清非阻塞 recv 的返回语义 + shutdown 行为
// 第一轮已确认存在：socket.MSG_DONTWAIT=64, socket.MSG_PEEK=2,
//                     socket.SHUT_WR=1, socket.SHUT_RDWR=2, socket.SO_LINGER=13
import * as socket from 'socket';

function t(v) {
	// ucode 里 typeof 是函数；这里包一层避免整脚本被异常带走
	let s = '?';
	try { s = type(v); } catch (e) { s = 'type-err'; }
	return s;
}

let srv = socket.create(socket.AF_INET, socket.SOCK_STREAM, 0);
srv.setopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, true);
if (!srv.bind('127.0.0.1:18799')) { print('bind failed: ' + srv.error() + '\n'); exit(1); }
srv.listen(8);

// 场景 1：客户端发一个完整请求，服务端**从不 recv**，直接看 MSG_DONTWAIT 能不能读出来
let cli = socket.create(socket.AF_INET, socket.SOCK_STREAM, 0);
cli.connect('127.0.0.1:18799');
cli.send('GET /health HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n');
let addr = {};
let peer = srv.accept(addr, socket.SOCK_CLOEXEC);
print('--- 场景1：有数据时 MSG_DONTWAIT recv ---\n');
for (let i = 0; i < 4; i++) {
	let got = null, err = null;
	try { got = peer.recv(8192, socket.MSG_DONTWAIT); } catch (e) { err = '' + e; }
	if (err) { print(sprintf('  #%d threw: %s\n', i, err)); break; }
	if (got === null) { print(sprintf('  #%d -> null (err=%s)\n', i, peer.error())); break; }
	print(sprintf('  #%d -> type=%s len=%d head=%s\n', i, t(got), length(got), substr('' + got, 0, 30)));
	if (length(got) === 0) break;
}

// 场景 2：读空之后 shutdown(SHUT_WR) 是否可用（这是我们想用来「优雅收尾」的手段）
print('--- 场景2：shutdown(SHUT_WR) ---\n');
let r1 = 'n/a';
try { r1 = '' + peer.shutdown(socket.SHUT_WR); } catch (e) { r1 = 'threw: ' + e; }
print('  peer.shutdown(SHUT_WR) = ' + r1 + '\n');

// 客户端此时应能读到 EOF（说明 FIN 已发）
let cliData = null;
try {
	// 阻塞读，应立刻拿到 EOF/false
	cli.setopt(socket.SOL_SOCKET, socket.SO_RCVTIMEO, 2000);
} catch (e) { }
try { cliData = cli.recv(4096, 0); } catch (e) { print('  cli.recv threw: ' + e + '\n'); }
print('  客户端读到: ' + (cliData === null ? 'null(EOF/超时)' : (t(cliData) + ' len=' + length(cliData))) + '\n');

try { peer.close(); } catch (e) { }
try { cli.close(); } catch (e) { }

// 场景 3：不发任何字节的连接上，MSG_DONTWAIT recv 返回什么？（这是拒绝路径的真实情形）
print('--- 场景3：客户端不发数据时 MSG_DONTWAIT recv ---\n');
let cli2 = socket.create(socket.AF_INET, socket.SOCK_STREAM, 0);
cli2.connect('127.0.0.1:18799');
let addr2 = {};
let peer2 = srv.accept(addr2, socket.SOCK_CLOEXEC);
for (let i = 0; i < 2; i++) {
	let got = null, err = null;
	try { got = peer2.recv(8192, socket.MSG_DONTWAIT); } catch (e) { err = '' + e; }
	if (err) { print(sprintf('  #%d threw: %s\n', i, err)); break; }
	if (got === null) { print(sprintf('  #%d -> null (err=%s)\n', i, peer2.error())); break; }
	print(sprintf('  #%d -> type=%s len=%d\n', i, t(got), length(got)));
	if (length(got) === 0) break;
}

// 场景 4：SO_LINGER 能不能设（若 recv 方案不可行，这是备选）
print('--- 场景4：SO_LINGER getopt/setopt ---\n');
try {
	let cur = peer2.getopt(socket.SOL_SOCKET, socket.SO_LINGER);
	print('  getopt(SO_LINGER) = ' + (cur === null ? 'null' : t(cur)) + '\n');
} catch (e) { print('  getopt threw: ' + e + '\n'); }
try {
	let ok = peer2.setopt(socket.SOL_SOCKET, socket.SO_LINGER, { onoff: 1, linger: 1 });
	print('  setopt(SO_LINGER,{onoff:1,linger:1}) = ' + ok + '\n');
} catch (e) { print('  setopt threw: ' + e + '\n'); }

try { peer2.close(); } catch (e) { }
try { cli2.close(); } catch (e) { }
try { srv.close(); } catch (e) { }
print('--- done ---\n');
