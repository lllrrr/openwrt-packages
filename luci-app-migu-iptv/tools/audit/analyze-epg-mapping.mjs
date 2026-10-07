// analyze-epg-mapping.mjs
// 本地量化分析：当前 /m3u 的 tvg-id 与 e.xml 标准 id 的映射质量
// 输入：本地 e.xml（已下载）、路由器 /m3u（HTTP 拉取）
import { readFileSync } from 'fs';
import { execFileSync } from 'child_process';

// 1. 提取 e.xml 的 channel id
const xml = readFileSync('D:/AI/_mt/e.xml', 'utf8');
const epgIds = [];
const re = /<channel[^>]*id="([^"]*)"/g;
let m;
while ((m = re.exec(xml)) !== null) epgIds.push(m[1]);
const uniqueEpg = [...new Set(epgIds)];
console.log('e.xml channel 总数:', epgIds.length, '唯一 id:', uniqueEpg.length);

// 2. 拉取路由器 /m3u
let m3u;
try {
  m3u = execFileSync('D:/DSH/runtime/node/node.exe', ['-e', `
    const http = require('http');
    http.get('http://192.168.69.1:8788/m3u', res => {
      let d = '';
      res.on('data', c => d += c);
      res.on('end', () => process.stdout.write(d));
    }).on('error', e => { console.error(e.message); process.exit(1); });
  `], { encoding: 'utf8', timeout: 30000 });
} catch (e) {
  console.error('拉取 /m3u 失败:', e.message);
  process.exit(1);
}
const lines = m3u.split('\n');
const infLines = lines.filter(l => l.startsWith('#EXTINF'));
console.log('M3U EXTINF 条数:', infLines.length);

// 3. 解析每条 EXTINF：tvg-id、tvg-name、显示名、group
const chans = [];
for (const l of infLines) {
  const idM = /tvg-id="([^"]*)"/.exec(l);
  const nameM = /tvg-name="([^"]*)"/.exec(l);
  const groupM = /group-title="([^"]*)"/.exec(l);
  const comma = l.lastIndexOf(',');
  const display = comma >= 0 ? l.slice(comma + 1) : '';
  chans.push({
    tvgId: idM ? idM[1] : '',
    tvgName: nameM ? nameM[1] : '',
    group: groupM ? groupM[1] : '',
    display,
  });
}

// 4. 规范化函数：去空格/括号/横线，转小写
const norm = s => s.toLowerCase().replace(/[\s()（）\-—]+/g, '');
const normEpgSet = new Set(uniqueEpg.map(norm));

// 5. 统计当前命中（tvg-id 是否在标准表内）
let hitExact = 0, hitNorm = 0, miss = 0;
const missList = [];
for (const c of chans) {
  if (uniqueEpg.includes(c.tvgId)) {
    hitExact++;
  } else if (normEpgSet.has(norm(c.tvgId))) {
    hitNorm++;
  } else {
    miss++;
    missList.push(`${c.group}|${c.display}|tvg=${c.tvgId}`);
  }
}
console.log('\n=== 映射统计 ===');
console.log('tvg-id 直接命中标准表:', hitExact);
console.log('tvg-id 规范化后命中:', hitNorm);
console.log('未命中(源里真没有):', miss);

// 6. 查看未命中清单，判断是否有「应命中却未命中」的（如 CCTV-1 写法差异）
console.log('\n=== 未命中清单（前 40 条） ===');
missList.slice(0, 40).forEach(x => console.log('  ' + x));

// 7. 检查前缀匹配风险：标准表里是否存在互为前缀的 id（CCTV1 vs CCTV1+1 之类）
console.log('\n=== 前缀风险检查 ===');
const sorted = [...uniqueEpg].sort();
let risk = 0;
for (let i = 0; i < sorted.length; i++) {
  for (let j = i + 1; j < sorted.length; j++) {
    if (sorted[j].startsWith(sorted[i]) && sorted[j].length > sorted[i].length) {
      console.log(`  风险: "${sorted[i]}" 是 "${sorted[j]}" 的前缀`);
      risk++;
    }
  }
}
if (risk === 0) console.log('  无互为前缀的标准 id');

// 8. 检查频道名本身（display）与 tvg-id 的对应，用于「频道名→EPG id 常量表」可行性
console.log('\n=== 频道名与 tvg-id 对照（抽样 15） ===');
chans.slice(0, 15).forEach(c => console.log(`  [${c.group}] ${c.display} -> tvg-id=${c.tvgId}`));