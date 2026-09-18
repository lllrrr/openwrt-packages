// Run with: node tests/realtime-ui.cjs
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');

const html = fs.readFileSync(path.join(__dirname, '../files/www/wan-latency/index.html'), 'utf8');
const script = html.match(/<script>([\s\S]*?)<\/script>/)?.[1];
assert.ok(script, 'inline dashboard script exists');
assert.match(html, /id=\"realtimeSection\"/);
assert.match(script, /getElementById\(\"realtimeSection\"\)/, 'renders cards into the real-time section');
assert.doesNotMatch(script, /getElementById\(\"cards\"\)/, 'does not use the removed cards id');
assert.match(html, /data-range=\"1800\">30分钟/, 'offers a 30-minute range');
const elements = new Map();
function element(id) {
  if (!elements.has(id)) elements.set(id, {
    id, value: id === 'pingInterval' ? '10' : '', textContent: '', innerHTML: '',
    style: {}, dataset: {}, clientWidth: 800, clientHeight: 380,
    classList: { add() {}, remove() {}, toggle() {}, contains() { return false; } },
    addEventListener() {}, querySelectorAll() { return []; }, getAttribute() { return ''; },
    getContext() { return { setTransform() {}, clearRect() {}, fillRect() {}, beginPath() {}, moveTo() {}, lineTo() {}, stroke() {}, fillText() {}, closePath() {}, fill() {} }; }
  });
  return elements.get(id);
}
const now = Math.floor(Date.now() / 1000);
const latest = { ts: now, items: [
  { id: 'ali', name: '阿里云', host: '223.5.5.5', color: '#ff7a1a', rtt: 31.1, method: 'icmp' },
  { id: 'steam', name: 'Steam', host: 'store.steampowered.com', color: '#8bdc63', rtt: 63.1, method: 'icmp' }
] };
const targets = latest.items.map(({id,name,host,color}) => ({id,name,host,color,region:id==='ali'?'domestic':'foreign'}));
let queryFails = true;
let queryResponder = null;
const api = async query => {
  const action = new URLSearchParams(query).get('action');
  if (action === 'latest') return latest;
  if (action === 'targets') return {ok:true,targets};
  if (action === 'settings') return {ok:true,interval:10,timeout:3,latency_threshold_ms:150,retain_days:366};
  if (action === 'query') {
    if(queryResponder) return queryResponder(query);
    if(queryFails) throw Error('history unavailable');
    return {ok:true,latest:{ts:now-5,items:[{id:"ali",rtt:1}]},targets,interval:10,stats:{ali:{avg:30,loss:0},steam:{avg:60,loss:0}},t:[],series:{},count:20,step:10};
  }
  throw Error('unexpected action '+action);
};
const context = vm.createContext({
  document: {getElementById:element,querySelectorAll(){return [];},querySelector(){return null;}},
  window: {parent:{wanLatencyApi:api},addEventListener(){},devicePixelRatio:1},
  localStorage: {getItem(){return null;},setItem(){}},
  setInterval(){return 1;},clearInterval(){},setTimeout,URL,Blob,Date,console
});
vm.runInContext(script,context,{filename:'index.html'});
(async () => {
  await new Promise(resolve => setTimeout(resolve,20));
  assert.equal(element('heroAvg').textContent,'47.1 ms');
  assert.equal(element('ovCur').textContent,'47.1 ms');
  assert.equal(element('heroOnline').textContent,2);
  assert.match(element('realtimeSection').innerHTML,/31\.1<small>ms/);
  assert.match(element('statusLine').textContent,/历史数据加载失败/);
  queryFails = false;
  await vm.runInContext('loadQuery()',context);
  assert.equal(element('heroAvg').textContent,'47.1 ms');
  assert.equal(element('ovAvg').textContent,'45.0 ms');
  assert.match(element('statusLine').innerHTML,/采集正常/);
  latest.ts = now + 1; latest.items[0].rtt = 41.1;
  await vm.runInContext('loadRealtime()',context);
  assert.equal(element('heroAvg').textContent,'52.1 ms');
  assert.match(element('realtimeSection').innerHTML,/41\.1<small>ms/);

  queryResponder = query => {
    const params = new URLSearchParams(query);
    const from = Number(params.get('from')), to = Number(params.get('to'));
    const span = to - from;
    const series = Object.fromEntries(targets.map(t => [t.id,{avg:[20,21],min:[19,20],max:[21,22]}]));
    const response = {ok:true,from,to,latest,targets,interval:10,stats:{},t:[from,to],series,count:2,step:10};
    return new Promise(resolve => setTimeout(() => resolve(response), span === 900 ? 30 : 0));
  };
  const oldRange = vm.runInContext('(rangeSec=900, custom=false, loadQuery())',context);
  const newRange = vm.runInContext('(rangeSec=3600, custom=false, loadQuery())',context);
  await Promise.all([oldRange,newRange]);
  assert.equal(vm.runInContext('data.to-data.from',context),3600,'older range response cannot overwrite the newest selection');
  console.log('Realtime UI smoke test passed (rendering, failure recovery, and range race).');
})().catch(err=>{console.error(err);process.exitCode=1;});

