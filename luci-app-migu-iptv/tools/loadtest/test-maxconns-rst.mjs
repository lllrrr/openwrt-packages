// test-maxconns-rst.mjs —— 判定 503 拒绝路径上「客户端读到 ECONNRESET」的确切成因。
// 假设：服务端 send() 后立刻 close()，而客户端的请求字节此时还在服务端的**接收队列里没被读**
//       —— Linux 在「关闭时接收队列非空」的情况下发 RST 而不是 FIN，RST 会把已发出的
//       80 字节响应一并丢掉。若假设成立，则「连上后先不发请求、等服务端关闭后再发」的客户端
//       应当读不到 body（RST），而「请求早已在队列里」的场景随机命中。
// 对照：curl（本机、发请求后立刻读）实测能完整拿到 80 字节 —— 说明这不是必然丢，是竞态。
import net from 'node:net';
import { execFileSync } from 'node:child_process';

const HOST = '192.168.69.1', PORT = 8788;
const PLINK = 'D:\\AI\\_tools\\plink.exe';
const HOSTKEY = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAID8sdP+GKwfwLjbCIZrnMqX9VfLr3ED9otte3PL9Fnk+';
const router = c => execFileSync(PLINK, ['-ssh', '-pw', (process.env.ROUTER_PASS || ''), '-hostkey', HOSTKEY, `root@${HOST}`, c], { encoding: 'utf8', timeout: 90000 });
const sleep = ms => new Promise(r => setTimeout(r, ms));
const hold = () => new Promise((res, rej) => { const s = net.connect(PORT, HOST); s.on('connect', () => res(s)); s.on('error', rej); });

// 变体 A：连上后**立即**发请求（请求很可能已在服务端接收队列里）
function probeImmediate() {
  return new Promise(res => {
    const s = net.connect(PORT, HOST);
    const chunks = []; let ev = null;
    s.on('connect', () => s.write(`GET /health HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n`));
    s.on('data', d => chunks.push(d));
    s.on('error', e => { ev = 'error:' + e.code; });
    s.on('close', () => res({ ev: ev || 'close', bytes: Buffer.concat(chunks).length, body: Buffer.concat(chunks).toString('utf8') }));
    setTimeout(() => { try { s.destroy(); } catch {} ; res({ ev: ev || 'timeout', bytes: Buffer.concat(chunks).length, body: Buffer.concat(chunks).toString('utf8') }); }, 4000);
  });
}

// 变体 B：连上后**等 300ms 再发**（服务端在这期间应已因超限而 close → 接收队列为空）
function probeDelayed() {
  return new Promise(res => {
    const s = net.connect(PORT, HOST);
    const chunks = []; let ev = null;
    s.on('connect', () => setTimeout(() => {
      try { s.write(`GET /health HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n`); } catch (e) { ev = 'write-failed:' + e.code; }
    }, 300));
    s.on('data', d => chunks.push(d));
    s.on('error', e => { ev = 'error:' + e.code; });
    s.on('close', () => res({ ev: ev || 'close', bytes: Buffer.concat(chunks).length, body: Buffer.concat(chunks).toString('utf8') }));
    setTimeout(() => { try { s.destroy(); } catch {} ; res({ ev: ev || 'timeout', bytes: Buffer.concat(chunks).length, body: Buffer.concat(chunks).toString('utf8') }); }, 4000);
  });
}

const held = [];
const log = s => console.log(s);

try {
  log('=== 设 maxConns=4 并重启 ===');
  log('\t' + router(`uci set migu.main.maxConns='4'; uci commit migu; /etc/init.d/migu restart; sleep 6; echo up`).trim());
  for (let i = 0; i < 4; i++) held.push(await hold());
  await sleep(1000);
  log('\t已占满 4/4 条半开连接');

  log('\n=== 变体 A：连上立即发请求 × 5 ===');
  for (let i = 0; i < 5; i++) {
    const r = await probeImmediate();
    log(`\t#${i + 1} 事件=${r.ev} 收到字节=${r.bytes} body=${JSON.stringify(r.body.slice(0, 70))}`);
    await sleep(200);
  }

  log('\n=== 变体 B：连上后等 300ms 再发请求 × 3（此时服务端应已 close） ===');
  for (let i = 0; i < 3; i++) {
    const r = await probeDelayed();
    log(`\t#${i + 1} 事件=${r.ev} 收到字节=${r.bytes} body=${JSON.stringify(r.body.slice(0, 70))}`);
    await sleep(600);
  }
} finally {
  for (const s of held) { try { s.destroy(); } catch {} }
  log('\n=== 复原 maxConns=64 ===');
  try { log('\t' + router(`uci set migu.main.maxConns='64'; uci commit migu; /etc/init.d/migu restart; sleep 6; echo ok`).trim()); } catch (e) { log('\t!!! ' + e.message); }
}
