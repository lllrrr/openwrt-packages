// test-rst-141.mjs —— 1.4.1 修复后的丢包率复测（纯 socket，不 spawn 任何子进程）
//
// 前置：maxConns 已由外部设为 4（本脚本不碰路由器，只打 socket）。
// 判据：变体 A（连上后立即发请求 = 修复前 58.3% 丢包的那个变体）
//       修复后应显著降到 0。
//       变体 C（不发字节）作为对照，应保持 0 丢包。
import net from 'node:net';

const HOST = '192.168.69.1', PORT = 8788;
const EXPECT = 218;          // 503 响应总字节数
const ROUNDS = 3, PER = 20;  // 每变体 60 次

const sleep = ms => new Promise(r => setTimeout(r, ms));
const hold = () => new Promise((res, rej) => {
  const s = net.connect(PORT, HOST);
  s.on('connect', () => res(s));
  s.on('error', rej);
});

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
async function variant(name, sendRequest) {
  console.log(`\n=== 变体 ${name}：${sendRequest ? '连上后立即发请求（接收队列非空）' : '连上后不发任何字节（接收队列为空）'} === 每轮 ${PER} 次`);
  let ok = 0, bad = 0, tot = 0;
  for (let round = 0; round < ROUNDS; round++) {
    while (held.length) { try { held.pop().destroy(); } catch {} }
    await sleep(400);
    for (let i = 0; i < 4; i++) held.push(await hold());   // 占满 maxConns=4
    await sleep(600);
    for (let i = 0; i < PER; i++) {
      const r = await probe({ sendRequest });
      tot++;
      if (r.bytes === EXPECT) ok++; else { bad++; console.log(`\t  丢包: ev=${r.ev} bytes=${r.bytes}`); }
      await sleep(60);
    }
    console.log(`\t第 ${round + 1} 轮：累计 ${ok}/${tot} 完整，${bad} 丢包`);
  }
  console.log(`  汇总：${ok}/${tot} 完整，丢包 ${bad} 次（${(bad / tot * 100).toFixed(1)}%）`);
  return { ok, bad, tot };
}

try {
  console.log('注意：需先把 maxConns 设为 4（由外部完成），本脚本只做 socket 探测。');
  const a = await variant('A', true);
  const c = await variant('C', false);

  console.log('\n================ 结论 ================');
  console.log(`变体 A（修复前的故障变体）：丢包 ${a.bad}/${a.tot}（${(a.bad / a.tot * 100).toFixed(1)}%）  修复前是 35/60 = 58.3%`);
  console.log(`变体 C（对照）：            丢包 ${c.bad}/${c.tot}（${(c.bad / c.tot * 100).toFixed(1)}%）  修复前是 0/60`);
  console.log(a.bad === 0
    ? '✅ 修复生效：变体 A 丢包归零'
    : `⚠️ 变体 A 仍有丢包（${a.bad}/${a.tot}），修复不完整或样本不足`);
} finally {
  while (held.length) { try { held.pop().destroy(); } catch {} }
}
