#!/bin/sh
# 判定 busybox nc 在 stdin EOF 时是否关闭/半关闭套接字。
#
# 【为什么关键】回环桥靠"socket 收到 EOF"判定上游响应结束。若 nc 在 stdin EOF
# 后既不关闭连接也不半关闭，ucode 侧就永远等不到 EOF —— 死锁：
# ucode 等 nc 关连接，nc 等 ucode 关连接。
#
# 用 heredoc 写 ucode 脚本，避免单引号/多行命令在 ssh 传输中被破坏。

echo "== busybox nc usage =="
nc --help 2>&1 | head -25

echo
echo "== test 1: busybox nc -l 作接收端，客户端 stdin EOF =="
rm -f /tmp/nclisten.out
nc -l -p 9922 > /tmp/nclisten.out 2>&1 &
LP=$!
sleep 1
{ printf 'id1\n'; printf 'AAAA\n'; printf 'BBBB\n'; } | nc 127.0.0.1 9922
echo "client_rc=$?"
sleep 3
echo "-- listener output --"
cat /tmp/nclisten.out 2>/dev/null
echo "-- listener alive? --"
if kill -0 $LP 2>/dev/null; then
	echo "ALIVE => 客户端 nc 没关闭连接"
	kill $LP 2>/dev/null
else
	echo "GONE => 客户端 nc 关闭了连接"
fi

echo
echo "== test 2: ucode 服务端能否看到 EOF =="
cat > /tmp/ncsrv.uc <<'UCEOF'
import * as socket from "socket";
import * as uloop from "uloop";
let s = socket.create(socket.AF_INET, socket.SOCK_STREAM, 0);
s.setopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1);
s.bind("127.0.0.1:9923");
s.listen(8);
printf("server listening\n");
uloop.init();
uloop.handle(s, () => {
	let p = s.accept({}, socket.SOCK_CLOEXEC);
	printf("accepted\n");
	let n = 0, t0 = time();
	uloop.handle(p, () => {
		let c = p.recv(512);
		if (c === null) { printf("recv NULL after %d bytes (%.2fs)\n", n, time() - t0); uloop.end(); return; }
		if (length(c) === 0) { printf("recv EMPTY=EOF after %d bytes (%.2fs)\n", n, time() - t0); uloop.end(); return; }
		n += length(c);
		printf("recv %d bytes total=%d\n", length(c), n);
	}, uloop.ULOOP_READ | uloop.ULOOP_BLOCKING);
}, uloop.ULOOP_READ | uloop.ULOOP_BLOCKING);
uloop.timer(8000, () => { printf("TIMEOUT: no EOF seen in 8s\n"); uloop.end(); });
uloop.run();
printf("server done\n");
UCEOF
rm -f /tmp/ncsrv.out
ucode /tmp/ncsrv.uc > /tmp/ncsrv.out 2>&1 &
SP=$!
sleep 1
{ printf 'id1\n'; printf 'CCCC\n'; printf 'DDDD\n'; } | nc 127.0.0.1 9923
echo "client_rc=$?"
sleep 9
echo "-- ucode server output --"
cat /tmp/ncsrv.out 2>/dev/null
if kill -0 $SP 2>/dev/null; then kill $SP 2>/dev/null; fi
echo
echo "DONE"
