// test-maxconns-curl.mjs —— 确定性复核 503 分支：
// 用 node 精确占满 maxConns 条半开连接，然后用路由器**本机的 curl**（严格客户端）
// 发第 maxConns+1 条请求，看 503 的响应体是否完整到达（curl 会报 truncation）。
import net from 'node:net';
import { execFileSync } from 'node:child_process';

const HOST = '192.168.69.1', PORT = 8788;
const PLINK = 'D:\\AI\\_tools\\plink.exe';
const HOSTKEY = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAID8sdP+GKwfwLjbCIZrnMqX9VfLr3ED9otte3PL9Fnk+';
const router = c => execFileSync(PLINK, ['-ssh', '-pw', (process.env.ROUTER_PASS || ''), '-hostkey', HOSTKEY, `root@${HOST}`, c], { encoding: 'utf8', timeout: 90000 });
const sleep = ms => new Promise(r => setTimeout(r, ms));

const hold = () => new Promise((res, rej) => {
  const s = net.connect(PORT, HOST);
  s.on('connect', () => res(s));
  s.on('error', rej);
});

const held = [];
const out = [];
const log = s => { console.log(s); out.push(s); };

try {
  const MAX = 4;
  log(`=== 设 maxConns=${MAX} 并重启 ===`);
  log('\t' + router(`uci set migu.main.maxConns='${MAX}'; uci commit migu; /etc/init.d/migu restart; sleep 6; /etc/init.d/migu status >/dev/null 2>&1; echo up`).trim());

  log(`=== 精确占满 ${MAX} 条半开连接（只 connect，不发一个字节） ===`);
  for (let i = 0; i < MAX; i++) held.push(await hold());
  await sleep(1000);
  log('\t已开 ' + held.length + ' 条。此时任何新请求都应被拒。');

  log('=== 用路由器本机 curl 发请求（严格客户端，看响应体是否完整） ===');
  // -w 打印状态码；--max-time 防挂死；不带 -s 才能看到 curl 自己的错误
  const curl = (url) => router(
    `curl -sS --max-time 8 -o /tmp/_b.txt -w 'HTTP:%{http_code} SIZE:%{size_download} TIME:%{time_total}' ${url} 2>&1; echo; echo '--- body ---'; cat /tmp/_b.txt; echo; echo '--- body bytes ---'; wc -c < /tmp/_b.txt`
  );
  for (const p of ['/health', '/m3u', '/ch/608807420']) {
    log(`\n--- ${p} ---`);
    log(curl('http://127.0.0.1:8788' + p).trimEnd());
  }

  log('\n=== 释放后恢复（同一个 curl 命令应回到 200） ===');
  for (const s of held) { try { s.destroy(); } catch {} }
  held.length = 0;
  await sleep(1500);
  log(curl('http://127.0.0.1:8788/health').trimEnd());
} finally {
  for (const s of held) { try { s.destroy(); } catch {} }
  log('\n=== 复原 maxConns=64 ===');
  try {
    log('\t' + router(`uci set migu.main.maxConns='64'; uci commit migu; /etc/init.d/migu restart; sleep 6; echo ok`).trim());
    log('\t' + router(`curl -s http://127.0.0.1:8788/health`).trim());
  } catch (e) { log('\t!!! 复原失败: ' + e.message); }
}
