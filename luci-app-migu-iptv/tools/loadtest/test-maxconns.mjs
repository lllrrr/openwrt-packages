// test-maxconns.mjs —— 用真实的「半开 TCP 连接」验证 migu.uc 的 maxConns 超限 503 分支
// 为什么不用 busybox nc：路由器上的 nc 是单发版（Usage: nc [IPADDR PORT]），
// 收完 stdin 就退出，连接根本挂不住，connections 数组里始终只有 1 条。
// 本脚本用 node 的 net.Socket 开若干条「只 connect、不发数据」的连接——
// migu.uc 的 onAccept() 一 accept 就 push 进 connections，所以不发数据也能占住名额。
import net from 'node:net';
import { execFileSync } from 'node:child_process';

const HOST = '192.168.69.1';
const PORT = 8788;
const PLINK = 'D:\\AI\\_tools\\plink.exe';
const HOSTKEY = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAID8sdP+GKwfwLjbCIZrnMqX9VfLr3ED9otte3PL9Fnk+';

function router(cmd) {
  return execFileSync(PLINK, ['-ssh', '-pw', (process.env.ROUTER_PASS || ''), '-hostkey', HOSTKEY,
    `root@${HOST}`, cmd], { encoding: 'utf8', timeout: 60000 });
}

function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

// 原始 socket 请求：返回 { code, headers, body }
// 用 Buffer 累积 —— 响应体是 UTF-8 中文，按 latin1 拼字符串会变乱码
// 且 UTF-8 多字节字符可能被 TCP 分段截断，必须最后整体 toString('utf8')
function request(path) {
  return new Promise((resolve, reject) => {
    const sock = net.connect(PORT, HOST);
    const chunks = [];
    let done = false;
    const finish = (err) => {
      if (done) return;
      done = true;
      clearTimeout(t);
      if (err) return reject(err);
      const buf = Buffer.concat(chunks);
      const idx = buf.indexOf('\r\n\r\n');
      const head = (idx >= 0 ? buf.subarray(0, idx) : buf).toString('latin1');
      const body = (idx >= 0 ? buf.subarray(idx + 4) : Buffer.alloc(0)).toString('utf8');
      const code = (head.match(/^HTTP\/1\.\d (\d+)/) || [])[1];
      const headers = {};
      for (const line of head.split('\r\n').slice(1)) {
        const i = line.indexOf(':');
        if (i > 0) headers[line.slice(0, i).trim().toLowerCase()] = line.slice(i + 1).trim();
      }
      resolve({ code, headers, body });
    };
    const t = setTimeout(() => { sock.destroy(); finish(new Error('timeout ' + path)); }, 15000);
    sock.on('connect', () => sock.write(`GET ${path} HTTP/1.1\r\nHost: ${HOST}:${PORT}\r\nConnection: close\r\n\r\n`));
    sock.on('data', d => chunks.push(d));
    // 关键：超限连接在回完 503 后会被服务端直接 destroy，客户端收到的是
    // ECONNRESET 而不是干净的 FIN。此时响应已经收全，应当按成功处理，
    // 否则一次 ECONNRESET 就会把整个测试脚本中断掉（v1 就是这么挂的）。
    sock.on('error', e => finish(e.code === 'ECONNRESET' && chunks.length ? null : e));
    sock.on('close', () => finish(null));
  });
}

// 只连不发，占住 connections 名额
function hold() {
  return new Promise((resolve, reject) => {
    const sock = net.connect(PORT, HOST);
    sock.on('connect', () => resolve(sock));
    sock.on('error', reject);
    sock.setTimeout(0);
  });
}

function health() {
  return request('/health').then(r => { try { return JSON.parse(r.body); } catch { return { _raw: r.body, _code: r.code }; } })
    .catch(e => ({ _err: e.message }));
}

const held = [];
function log(s) { console.log(s); }

// 把每个测量段落都包起来：任一步失败也不能跳过最后的复原
async function step(title, fn) {
  log(title);
  try { await fn(); } catch (e) { log('\t!!! 本段出错（继续）: ' + e.message); }
}

try {
  await step('=== 0. 现状 ===', async () => {
    const h = await health();
    log(`\tversion=${h.version} activeConns=${h.activeConns} maxConns=${h.maxConns} rejectedByLimit=${h.rejectedByLimit}`);
  });

  await step('=== 1. 把 maxConns 临时降到下限 4 并重启服务 ===', async () => {
    log('\t' + router(`uci set migu.main.maxConns='4'; uci commit migu; /etc/init.d/migu restart; sleep 6; echo restarted`).trim());
    const h = await health();
    log(`\t重启后 activeConns=${h.activeConns} maxConns=${h.maxConns} rejectedByLimit=${h.rejectedByLimit}`);
  });

  await step('=== 2. 开 3 条半开连接（只 connect 不发数据） ===', async () => {
    for (let i = 0; i < 3; i++) held.push(await hold());
    await sleep(800);
    const h = await health();
    log(`\t3 条占位 + 本次 /health 自身 = 应为 4：activeConns=${h.activeConns} maxConns=${h.maxConns}`);
  });

  await step('=== 3. 名额已满时再发请求，应得 503 ===', async () => {
    const over = await request('/health');
    log(`\t超限 /health => HTTP ${over.code}`);
    log(`\tRetry-After=${over.headers['retry-after']} Content-Type=${over.headers['content-type']} Content-Length=${over.headers['content-length']}`);
    log(`\t响应体(UTF-8)= ${over.body}`);
    // 逐个字节核对 Content-Length 与中文 UTF-8 长度是否一致
    const bytes = Buffer.byteLength(over.body, 'utf8');
    log(`\t响应体 UTF-8 字节数=${bytes}（服务端 Content-Length=${over.headers['content-length']}，一致=${String(bytes) === over.headers['content-length']}）`);
  });

  await step('=== 4. 超限时 /m3u 与 /ch 同样被拒（不是只挡 /health） ===', async () => {
    for (const p of ['/m3u', '/ch/608807420', '/txt']) {
      const r = await request(p);
      log(`\t${p} => HTTP ${r.code}${r.code === '503' ? ' body=' + r.body : ''}`);
    }
  });

  await step('=== 5. 释放全部占位连接后应恢复 ===', async () => {
    for (const s of held) { try { s.destroy(); } catch {} }
    held.length = 0;
    await sleep(1500);
    const h = await health();
    log(`\t释放后 activeConns=${h.activeConns} rejectedByLimit=${h.rejectedByLimit}（应 ≥3，证明拒绝计数在涨）`);
    const back = await request('/m3u');
    log(`\t/m3u 恢复 => HTTP ${back.code}，${Buffer.byteLength(back.body, 'utf8')} 字节`);
  });
} finally {
  for (const s of held) { try { s.destroy(); } catch {} }
  held.length = 0;
  log('=== 6. 复原 maxConns=64（无论上面成败都必须执行） ===');
  try {
    log('\t' + router(`uci set migu.main.maxConns='64'; uci commit migu; /etc/init.d/migu restart; sleep 6; echo ok`).trim());
    const h = await health();
    log(`\tversion=${h.version} activeConns=${h.activeConns} maxConns=${h.maxConns} rejectedByLimit=${h.rejectedByLimit}`);
  } catch (e) {
    log('\t!!! 复原失败，请手动执行 uci set migu.main.maxConns=64 && uci commit migu && /etc/init.d/migu restart: ' + e.message);
  }
}
