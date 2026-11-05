// Run with Node and Playwright installed; uses an isolated browser and fake RPCs.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const {chromium}=require('playwright');
const root=path.resolve(__dirname,'..');
const wan=fs.existsSync(path.join(root,'files/www/wan-latency/index.html'));
const source=fs.readFileSync(path.join(root,wan?'files/www/wan-latency/index.html':'root/www/luci-static/resources/cpemonitor/carrier.js'),'utf8');
let state={ok:true,code:3,sim:0,mode:'auto',source:'auto',switch_supported:true},requests=[];
const now=Math.floor(Date.now()/1000),targets=[{id:'ali',name:'阿里云',host:'223.5.5.5',color:'#ff7a1a',region:'domestic'}];
async function bridge(query,value){
 let q=new URLSearchParams(query.startsWith('action=')?query:'action='+query),action=q.get('action').replace(/^carrier_/,''),v=q.get('value')??value;requests.push({action,v,carrier:q.get('carrier')});
 if(action==='status')return {...state};
 if(action==='set'){state={...state,code:Number(v),mode:String(v),source:'manual'};return {...state};}
 if(action==='switch')return {ok:1,id:'abcdefgh12',started:1};
 if(action==='job'){state={...state,sim:1};return {ok:1,state:'done'};}
 if(action==='latest')return {ts:now,items:[{...targets[0],rtt:20,method:'icmp'}]};
 if(action==='targets')return {ok:true,targets};
 if(action==='settings')return {ok:true,interval:10,timeout:3,retain_days:366,latency_threshold_ms:150};
 if(action==='query')return {ok:true,from:now-600,to:now,t:[now-30,now-20,now-10],step:10,interval:10,count:3,targets,series:{ali:{avg:[20,null,30],min:[20,null,30],max:[20,null,30]}},stats:{ali:{avg:25,loss:33}},carriers:[{carrier:1,target:'ali',count:2,avg:20,min:20,max:20,loss:50},{carrier:3,target:'ali',count:1,avg:30,min:30,max:30,loss:0}],meta:{samples:3,bytes:32,retain_days:366},latest:{ts:now,items:[{...targets[0],rtt:30,method:'icmp'}]}};
 throw Error('Unexpected RPC '+action);
}
(async()=>{
 const browser=await chromium.launch({headless:true,...(process.env.CHROME_BIN?{executablePath:process.env.CHROME_BIN}:{})});
 try {
 const page=await browser.newPage({viewport:{width:1200,height:960}}),errors=[];
 page.on('pageerror',e=>{errors.push(e.message);console.error('PAGE ERROR:',e.message);});await page.exposeFunction('fixtureBridge',bridge);
 await page.addInitScript(()=>{window.wanLatencyApi=q=>window.fixtureBridge(q);window.fixtureApi=(q,v)=>window.fixtureBridge(q,v);});
 let html=source;
 if(!wan){html='<html><head><meta charset="utf-8"></head><body><div id="root"></div><script>const panel=new Function("rpc",'+JSON.stringify(source)+')({declare:o=>v=>window.fixtureApi(o.method,v)}).create(v=>{window.selectedFilter=v;});window.testPanel=panel;document.getElementById("root").appendChild(panel.node);panel.report([{id:1,count:2,download:300,upload:50,aliyun_avg:20,aliyun_loss:50,tencent_avg:30,tencent_loss:0,unaccounted:0}]);panel.refresh();</script></body></html>';}
 await page.route('http://monitor.test/**',route=>route.fulfill({contentType:'text/html; charset=utf-8',body:html}));await page.goto('http://monitor.test/');
 await page.getByText('当前：中国电信',{exact:false}).waitFor();
 await page.getByLabel('历史运营商筛选').selectOption('1');
 await page.waitForFunction(()=>document.querySelector('.carrier-panel table'));
 if(wan)assert(requests.some(r=>r.action==='query'&&r.carrier==='1'));else assert.equal(await page.evaluate(()=>window.selectedFilter),'1');
 await page.getByLabel('当前 SIM 的运营商标记').selectOption('1');await page.getByRole('button',{name:'保存标记',exact:true}).click();await page.getByText('标记已保存，仅用于后续记录；已有历史未改变。',{exact:true}).waitFor();
 page.once('dialog',d=>d.dismiss());await page.getByRole('button',{name:'切换数据 SIM',exact:true}).click();assert(!requests.some(r=>r.action==='switch'),'cancel must not switch');
 page.once('dialog',d=>d.accept());await page.getByRole('button',{name:'切换数据 SIM',exact:true}).click();await page.getByText('切换成功，等待新运营商识别；历史和累计流量继续保留。',{exact:true}).waitFor();assert.equal(requests.filter(r=>r.action==='switch').length,1);
 await page.setViewportSize({width:390,height:844});await page.locator('.carrier-panel').scrollIntoViewIfNeeded();
 const overflow=await page.locator('.carrier-panel').evaluate(n=>n.getBoundingClientRect().width>window.innerWidth+1);assert(!overflow,'panel fits a narrow screen');
 assert.deepEqual(errors,[]);console.log('PASS '+(wan?'WAN':'CPE')+' real-browser rendering, filtering, SIM-scoped mark, switch confirmation/cancel and narrow layout');
 } finally {await browser.close();}
})().catch(e=>{console.error(e);process.exit(1);});
