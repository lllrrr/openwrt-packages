// test-maxconns-rst2.mjs —— 决定性判别 + 失效概率量化
//
// 理论：拒绝路径 `peer.send(503)` 后**立刻** `peer.close()`，但服务端从头到尾
//       没有读过这个连接的请求字节 → 关闭时接收队列非空 → Linux 发 RST 而不是 FIN
//       → RST 会把刚发出的 503 响应一起丢掉。
//
// 判别实验（若理论成立，结果必须是这样）：
//   变体 C：连上后**一个字节都不发** → 服务端接收队列为空 → 应发 FIN
//           → 应当**每次都**稳定收到完整的 218 字节（0 次丢包）
//   变体 A：连上后立即发请求 → 接收队列非空 → 应发 RST
//           → 应当**随机**丢包（0 字节 + ECONNRESET）
// C 稳定且 A 丢包 ⇒ 理论成立。
import net from 'node:net';
import { execFileSync } from 'node:child_process';

const HOST = '192.168.69.1', PORT = 8788;
const PLINK = 'D:\\AI\\_tools\\plink.exe';
const HOSTKEY = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAID8sdP+GKwfwLjbCIZrnMqX9VfLr3ED9otte3PL9Fnk+';
const router = c => execFileSync(PLINK, ['-ssh', '-pw', (process.env.ROUTER_PASS || ''), '-hostkey', HOSTKEY, `root@${HOST}`, c], { encoding: 'utf8', timeout: 90000 });
const sleep = ms => new Promise(r => setTimeout(r, ms));
const hold = () => new Promise((res, rej) => { const s = net.connect(PORT, HOST); s.on('connect', () => res(s)); s.on('error', rej); });

const EXPECT = 218; // 503 响应总字节数（状态行+头+80 字节 body）

function probe({ sendRequest }) {
  return new Promise(res => {
    const s = net.connect(PORT, HOST);
    const chunks = []; let ev = null, done = false;
    const fin = () => {
      if (done) return; done = true;
      res({ ev: ev || 'close', bytes: Buffer.concat(chunks).length });
      try { s.destroy(); } catch {}
    };
    s.on('connect', () => {
      if (sendRequest) s.write('GET /health HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n');
    });
    s.on('data', d => chunks.push(d));
    s.on('error', e => { ev = 'error:' + e.code; fin(); });
    s.on('close', fin);
    setTimeout(fin, 3000);
  });
}

const held = [];
const log = s => console.log(s);

try {
  log('=== 设 maxConns=4 并重启 ===');
  log('\t' + router(`uci set migu.main.maxConns='4'; uci commit migu; /etc/init.d/migu restart; sleep 6; echo up`).trim());

  log('\n=== 变体 C：连上后不发任何字节（服务端接收队列应为空）=== 每轮 20 次');
  // 每轮开始前重新占满 4 个名额（上一轮的探测连接会被服务端关掉，但自己的占位连接要重建）
  let cOk = 0, cBad = 0, cTot = 0;
  for (let round = 0; round < 3; round++) {
    while (held.length) { try { held.pop().destroy(); } catch {} }
    await sleep(400);
    for (let i = 0; i < 4; i++) held.push(await hold());
    await sleep(600);
    for (let i = 0; i < 20; i++) {
      const r = await probe({ sendRequest: false });
      cTot++;
      if (r.bytes === EXPECT) cOk++; else { cBad++; log(`\t  丢包: ev=${r.ev} bytes=${r.bytes}`); }
      await sleep(60);
    }
    log(`\t第 ${round + 1} 轮完成：累计 ${cOk}/${cTot} 完整，${cBad} 丢包`);
  }

  log(`\n=== 变体 C 汇总：${cOk}/${cTot} 收到完整 ${EXPECT} 字节，丢包 ${cBad} 次 ===`);

  log('\n=== 变体 A：连上后立即发请求 === 每轮 20 次');
  let aOk = 0, aBad = 0, aTot = 0;
  for (let round = 0; round < 3; round++) {
    while (held.length) { try { held.pop().destroy(); } catch {} }
    await sleep(400);
    for (let i = 0; i < 4; i++) held.push(await hold());
    await sleep(600);
    for (let i = 0; i < 20; i++) {
      const r = await probe({ sendRequest: true });
      aTot++;
      if (r.bytes === EXPECT) aOk++; else { aBad++; log(`\t  丢包: ev=${r.ev} bytes=${r.bytes}`); }
      await sleep(60);
    }
    log(`\t第 ${round + 1} 轮完成：累计 ${aOk}/${aTot} 完整，${aBad} 丢包`);
  }
  log(`\n=== 变体 A 汇总：${aOk}/${aTot} 收到完整 ${EXPECT} 字节，丢包 ${aBad} 次（${(aBad / aTot * 100).toFixed(1)}%）===`);
  log(`\n结论：C 丢包 ${cBad}/${cTot}，A 丢包 ${aBad}/${aTot} → ` +
      (cBad === 0 && aBad > 0 ? '理论成立：未读的请求字节导致 RST'
        : cBad > 0 ? '理论不成立（C 也丢包，另有成因）' : 'A 未复现丢包，需更多样本'));
} finally {
  while (held.length) { try { held.pop().destroy(); } catch {} }
  log('\n=== 复原 maxConns=64 ===');
  try { log('\t' + router(`uci set migu.main.maxConns='64'; uci commit migu; /etc/init.d/migu restart; sleep 6; echo ok`).trim()); } catch (e) { log('\t!!! ' + e.message); }
}
