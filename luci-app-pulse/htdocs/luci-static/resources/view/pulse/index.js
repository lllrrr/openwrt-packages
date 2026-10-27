
'use strict';
'require view';
'require rpc';
'require poll';
'require fs';
'require firewall';
'require pulse.storage as storage';

var devicesRPC = rpc.declare({object:'luci-rpc',method:'getNetworkDevices',expect:{'':{}}});
var interfacesRPC = rpc.declare({object:'network.interface',method:'dump',expect:{interface:[]}});
var infoRPC = rpc.declare({object:'system',method:'info',expect:{'':{}}});
var boardRPC = rpc.declare({object:'system',method:'board',expect:{'':{}}});
var mountsRPC = rpc.declare({object:'luci',method:'getMountPoints',expect:{result:[]}});
function loadStorage(){return Promise.all([fs.exec('/bin/cat',['/proc/self/mountinfo']).then(function(r){if(r.code!==0)throw new Error('Cannot read mount table');return r.stdout;}),mountsRPC()]).then(function(d){return storage.discover(d[0],d[1]);});}
var builtinPortsRPC=rpc.declare({object:'luci',method:'getBuiltinEthernetPorts',expect:{result:[]},reject:true});
function portNames(ports,board){
 var names=(ports||[]).map(function(p){return p.device;}).filter(function(n){return typeof n==='string'&&n;});
 if(!names.length)['lan','wan'].forEach(function(role){
  var entry=board&&board.network&&board.network[role];if(!entry)return;
  names=names.concat(Array.isArray(entry.ports)?entry.ports:typeof entry.device==='string'?[entry.device]:[]);
 });
 return Array.from(new Set(names.filter(function(n){return typeof n==='string'&&n;}))).sort(function(a,b){return a.localeCompare(b,'en',{numeric:true});});
}
function loadPorts(){
 return L.resolveDefault(builtinPortsRPC(),[]).then(function(ports){
  if(ports.length)return portNames(ports,null);
  return L.resolveDefault(fs.read('/etc/board.json'),'{}').then(function(raw){
   var board;try{board=JSON.parse(raw);}catch(e){board={};}return portNames([],board);
  });
 });
}
function parseDocker(output){
 var lines=output.trim().split('\n'),state=lines.shift();
 if(state==='absent'||state==='unavailable')return {state:state,containers:[]};
 if(state!=='ok')throw new Error('Invalid Docker response');
 var containers=lines.filter(Boolean).map(function(line){
  var item=JSON.parse(line);
  if(typeof item.name!=='string'||typeof item.state!=='string'||typeof item.status!=='string')throw new Error('Invalid container');
  var stopped=['created','exited','paused','removing'].includes(item.state);
  var kind=stopped?'stopped':item.state==='running'&&!/unhealthy|health: starting/i.test(item.status)?'running':'error';
  var label={created:_('Created','pulse'),exited:_('Stopped','pulse'),paused:_('Paused','pulse'),removing:_('Removing','pulse'),restarting:_('Restarting','pulse'),dead:_('Error','pulse')}[item.state];
  if(item.state==='running')label=/unhealthy/i.test(item.status)?_('Unhealthy','pulse'):/health: starting/i.test(item.status)?_('Starting','pulse'):_('Running','pulse');
  return {name:item.name,kind:kind,label:label||_('Unknown state','pulse'),status:item.status};
 }).sort(function(a,b){return a.name.localeCompare(b.name,'en',{numeric:true});});
 return {state:'ok',containers:containers};
}
var dockerCache=null,dockerFetched=0,dockerPending=null;
function loadDocker(){
 if(dockerPending)return dockerPending;
 if(dockerCache&&Date.now()-dockerFetched<10000)return Promise.resolve(dockerCache);
 dockerPending=fs.exec('/usr/libexec/pulse-docker',[]).then(function(result){
  if(result.code!==0)throw new Error('Docker query failed');
  return parseDocker(result.stdout||'');
 }).catch(function(){return {state:'unavailable',containers:[]};}).then(function(result){
  dockerCache=result;dockerFetched=Date.now();dockerPending=null;return result;
 });
 return dockerPending;
}
var zoneRequest=null;
function loadZones(){
 if(!zoneRequest)zoneRequest=L.resolveDefault(firewall.getZones().then(function(zones){
  return zones.map(function(zone){return {name:zone.getName(),networks:zone.getNetworks(),style:firewall.getZoneColorStyle(zone)};});
 }),[]);
 return zoneRequest;
}
function networkBadges(names,zones){
 return names.map(function(name){
  var matches=(zones||[]).filter(function(zone){return zone.networks.includes(name);});
  if(!matches.length)return E('span',{class:'hd-network-tag hd-network-unassigned'},name);
  return E('span',{class:'hd-network-tag-group'},matches.map(function(zone){
   return E('span',{class:'hd-network-tag',style:zone.style,'aria-label':_('%s, firewall zone %s','pulse').format(name,zone.name)},name);
  }));
 });
}
var trafficRPC=rpc.declare({object:'pulse',method:'history',params:['device'],expect:{'':{}},reject:true});
function loadTraffic(data){
 var names=visibleDeviceNames(data[0]),saved=prefs();
 var device=names.includes(saved)?saved:defaultDevice(names,data[1]);
 return Promise.all([L.resolveDefault(trafficRPC(device),null),loadDocker(),loadZones()]).then(function(results){return data.slice(0,10).concat(results);});
}
// Generated from Makefile; generate-version.sh refreshes this on build/deploy.
var VERSION='1.0.2'; // @pulse-version
var NS='http://www.w3.org/2000/svg', WINDOW_MS=5*60*1000, TRAFFIC_WINDOW_MS=1*60*1000;
function svg(tag, attrs) { var n=document.createElementNS(NS,tag); Object.keys(attrs||{}).forEach(function(k){n.setAttribute(k,attrs[k]);}); return n; }
function bytes(v) { if(v==null||!isFinite(v)) return '—'; var u=['B','KB','MB','GB','TB'],i=0; while(v>=1024&&i<4){v/=1024;i++;} return (v<10&&i?v.toFixed(2):v<100&&i?v.toFixed(1):Math.round(v))+' '+u[i]; }
function rate(v){return v==null?_('Sampling','pulse'):bytes(v)+'/s';}
function mean(a,key){var b=a.map(function(x){return x[key];}).filter(function(x){return x!=null;});return b.length?b.reduce(function(a,b){return a+b;},0)/b.length:0;}
function max(a,key){return Math.max.apply(null,[0].concat(a.map(function(x){return x[key]||0;})));}
function clock(t){return new Date(t).toLocaleTimeString(document.documentElement.lang||undefined,{hour12:false});}
function text(n,v){n.textContent=v;}
function prefs(){try{var current=localStorage.getItem('pulse.device'),legacy=localStorage.getItem('home-dashboard.device');if(current==null&&legacy){localStorage.setItem('pulse.device',legacy);current=legacy;}localStorage.removeItem('home-dashboard.device');return current||'';}catch(e){return '';}}
function visibleDeviceNames(devices) {
 return Object.keys(devices).filter(function(n){return n!=='lo'&&!/^veth/i.test(n);})
  .sort(function(a,b){return a.localeCompare(b,'en',{numeric:true});});
}
function defaultDevice(names, interfaces) {
 var candidates=interfaces.map(function(i){
  var name=(i.interface||'').toLowerCase();
  var device=[i.l3_device,i.device].find(function(n){return names.includes(n);});
  var route=(i.route||[]).some(function(r){return (r.target==='0.0.0.0'||r.target==='::')&&Number(r.mask)===0;});
  return {device:device,rank:name==='wan'?0:name.startsWith('wan')?1:route?2:3};
 }).filter(function(i){return i.device&&i.rank<3;});
 candidates.sort(function(a,b){return a.rank-b.rank;});
 return candidates.length?candidates[0].device:names[0]||'';
}
function deviceNetworks(name, devices, interfaces) {
 function contains(device, seen) {
  if(device===name)return true;
  if(!device||seen.has(device))return false;
  seen.add(device);
  var d=devices[device]||{},children=Array.isArray(d.ports)?d.ports.slice():[];
  // DSA parent is the CPU conduit, not another user-facing port.
  if(d.parent&&d.devtype!=='dsa')children.push(d.parent);
  return children.some(function(child){return contains(child,seen);});
 }
 return Array.from(new Set(interfaces.filter(function(i){
  return contains(i.device,new Set())||contains(i.l3_device,new Set());
 }).map(function(i){return i.interface;}).filter(Boolean)));
}
function deviceAddresses(name, devices, interfaces, version) {
 var entries=[],byAddress=new Map(),field=version===6?'ip6addrs':'ipaddrs';
 function add(address,network) {
  if(!address)return;
  var entry=byAddress.get(address);
  if(!entry){entry={address:address,networks:[]};byAddress.set(address,entry);entries.push(entry);}
  if(network&&!entry.networks.includes(network))entry.networks.push(network);
 }
 ((devices[name]||{})[field]||[]).forEach(function(a){add(a.address);});
 var networks=deviceNetworks(name,devices,interfaces);
 interfaces.filter(function(i){return networks.includes(i.interface);}).forEach(function(i){
  var addresses=i[version===6?'ipv6-address':'ipv4-address']||[];
  // The L3 device owns protocol addresses; the lower device may belong to another WAN.
  if(!addresses.length)addresses=((devices[i.l3_device||i.device]||{})[field]||[]);
  addresses.forEach(function(a){add(a.address,i.interface);});
 });
 if(version===6){
  function rank(a){return /^[23]/i.test(a.address)?0:/^f[cd]/i.test(a.address)?1:/^fe[89ab]/i.test(a.address)?3:2;}
  entries.sort(function(a,b){return rank(a)-rank(b);});
 }
 return entries;
}
function sortPorts(names,devices,interfaces) {
 var ranks={};
 names.forEach(function(name){
  var networks=deviceNetworks(name,devices,interfaces).map(function(n){return n.toLowerCase();});
  ranks[name]=networks.includes('wan')?0:networks.some(function(n){return n.startsWith('wan');})?1:2;
 });
 return names.slice().sort(function(a,b){return ranks[a]-ranks[b]||a.localeCompare(b,'en',{numeric:true});});
}
function trafficScale(peak) {
 var units=['MB/s','GB/s','TB/s'],unit=0,divisor=1024*1024;
 while(peak/divisor>=1024&&unit<units.length-1){unit++;divisor*=1024;}
 var value=peak/divisor;
 if(unit===0&&value<=4)return {ceiling:4*divisor,step:1,ticks:4,unit:units[unit]};
 var raw=Math.max(1,value/6),power=Math.pow(10,Math.floor(Math.log10(raw)));
 var step=Math.ceil(([1,2,2.5,5,10].find(function(n){return n*power>=raw;})||10)*power);
 var ticks=Math.max(4,Math.ceil(value*1.02/step));
 return {ceiling:step*ticks*divisor,step:step,ticks:ticks,unit:units[unit]};
}
function visualTraffic(samples) {
 // Centered three-point filter for drawing only; never modify measured samples.
 var result=samples.map(function(s){return Object.assign({},s);});
 ['up','down'].forEach(function(key){
  function valid(s){return Number.isFinite(s[key])&&s[key]>=0;}
  function connected(a,b){return b.t>a.t&&b.t-a.t<=Math.min(2500,(b.interval||1)*1000+1000);}
  samples.forEach(function(sample,i){
   if(!valid(sample)){result[i][key]=null;return;}
   var total=sample[key]*2,weight=2;
   [-1,1].forEach(function(direction){
    var j=i+direction;
    if(j<0||j>=samples.length||!valid(samples[j]))return;
    if(!connected(samples[Math.min(i,j)],samples[Math.max(i,j)]))return;
    total+=samples[j][key];weight++;
   });
   result[i][key]=total/weight;
  });
 });
 return result;
}
function trafficPeak(samples,key) {
 var peak=null;
 samples.forEach(function(s){
  if(Number.isFinite(s[key])&&s[key]>=0&&(!peak||s[key]>=peak.value))peak={t:s.t,key:key,value:s[key]};
 });
 return peak;
}
function markTrafficPeak(host,samples,ceiling) {
 var peaks=['up','down'].map(function(key){return trafficPeak(samples,key);}).filter(Boolean);
 var positions=[];
 peaks.forEach(function(peak){
  var x=100*(1-(samples[samples.length-1].t-peak.t)/TRAFFIC_WINDOW_MS),y=(175-165*peak.value/ceiling)/180*100;
  var color=peak.key==='up'?'var(--hd-secondary)':'var(--hd-blue)',offset='';
  if(positions.some(function(p){return Math.abs(p.x-x)*(host.clientWidth||650)/100<140&&Math.abs(p.y-y)*(host.clientHeight||180)/100<28;}))
   offset=y<80?';transform:translateY(8px)':';transform:translateY(calc(-100% - 32px))';
  positions.push({x:x,y:y});
  host.appendChild(E('span',{class:'hd-peak-dot',style:'left:'+x+'%;top:'+y+'%;background:'+color,'aria-hidden':'true'}));
  host.appendChild(E('span',{class:'hd-peak-label',style:'left:clamp(0px,calc('+x+'% - 65px),calc(100% - 130px));top:'+y+'%;color:'+color+offset},(peak.key==='up'?'↑ ':'↓ ')+rate(peak.value)));
 });
}
function linkRate(speed){
 return speed>=1000?(speed/1000)+' Gbit/s':speed+' Mbit/s';
}
function connectionState(device) {
 if(!device)return {kind:'unavailable',label:_('Device unavailable','pulse')};
 var carrier=device.link&&device.link.carrier;
 if(carrier===true)return {kind:'connected',label:_('Connected','pulse')};
 if(carrier===false||!device.up)return {kind:'disconnected',label:_('Disconnected','pulse')};
 return {kind:'enabled',label:_('Device enabled','pulse')};
}
function smoothPath(points) {
 if(!points.length)return '';
 var slopes=[],tangents=[],path='M'+points[0][0].toFixed(2)+','+points[0][1].toFixed(2);
 for(var i=1;i<points.length;i++){
  var dx=points[i][0]-points[i-1][0];
  slopes.push(dx>0?(points[i][1]-points[i-1][1])/dx:0);
 }
 for(var i=0;i<points.length;i++){
  var left=slopes[i-1],right=slopes[i];
  // Flatten turning points; bounded tangents avoid creating false peaks.
  tangents[i]=i===0?(right||0):i===points.length-1?(left||0):left*right>0?2*left*right/(left+right):0;
 }
 for(var i=1;i<points.length;i++){
  var a=points[i-1],b=points[i],step=(b[0]-a[0])/3;
  path+=' C'+(a[0]+step).toFixed(2)+','+(a[1]+step*tangents[i-1]).toFixed(2)+' '+(b[0]-step).toFixed(2)+','+(b[1]-step*tangents[i]).toFixed(2)+' '+b[0].toFixed(2)+','+b[1].toFixed(2);
 }
 return path;
}
function plot(host, samples, keys, colors, id, percent){
 host.replaceChildren();var w=800,h=180, ceiling=percent?100:Math.max(1,Math.max.apply(null,keys.map(function(k){return max(samples,k);}))*1.15);
 var root=svg('svg',{viewBox:'0 0 '+w+' '+h,preserveAspectRatio:'none','aria-hidden':'true'}),defs=svg('defs');root.appendChild(defs);
 var scale=null;if(keys.length>1){scale=trafficScale(Math.max.apply(null,keys.map(function(k){return max(samples,k);})) );ceiling=scale.ceiling;}
 if(keys.length>1)for(var j=0;j<=scale.ticks;j++)root.appendChild(svg('line',{x1:0,y1:10+j*165/scale.ticks,x2:w,y2:10+j*165/scale.ticks,stroke:'var(--hd-line)','stroke-dasharray':'3 5','stroke-width':1}));
 keys.forEach(function(k,idx){var g=svg('linearGradient',{id:id+idx,x1:0,y1:0,x2:0,y2:1});g.appendChild(svg('stop',{offset:'0%','stop-color':colors[idx],'stop-opacity':'.27'}));g.appendChild(svg('stop',{offset:'100%','stop-color':colors[idx],'stop-opacity':'.015'}));defs.appendChild(g);
 var segments=[],seg=[];samples.forEach(function(s,i){if(s[k]==null){if(seg.length)segments.push(seg);seg=[];return;}seg.push([w*(1-(samples[samples.length-1].t-s.t)/(id==='hd-main'?TRAFFIC_WINDOW_MS:WINDOW_MS)),h-5-(h-15)*Math.min(1,s[k]/ceiling)]);});if(seg.length)segments.push(seg);
 segments.forEach(function(a){var d=id==='hd-main'?smoothPath(a):a.map(function(p,i){return(i?'L':'M')+p[0].toFixed(1)+','+p[1].toFixed(1);}).join(' ');root.appendChild(svg('path',{d:d+' L'+a[a.length-1][0]+','+h+' L'+a[0][0]+','+h+' Z',fill:'url(#'+id+idx+')'}));root.appendChild(svg('path',{d:d,fill:'none',stroke:colors[idx],'stroke-width':1.7,'vector-effect':'non-scaling-stroke','stroke-linejoin':'round'}));});
 });host.appendChild(root);return scale||ceiling;
}
return view.extend({
 handleSaveApply:null,handleSave:null,handleReset:null,
 load:function(){return Promise.all([devicesRPC(),interfacesRPC(),infoRPC(),boardRPC(),Promise.resolve(''),L.resolveDefault(fs.read('/etc/resolv.conf'),''),L.resolveDefault(loadStorage(),null),Promise.resolve({}),Promise.resolve(null),loadPorts()]).then(loadTraffic);},
 render:function(data){
 var history=[],flow=[],drawFlow=[],choice=prefs(),selected='',latest=data, refs={},storageFetched=Date.now(),optionSignature='';
 var select=E('select',{'aria-label':_('Monitored network device','pulse')});
 function syncSelection(devices,interfaces) {
  var names=visibleDeviceNames(devices);
  if(choice&&!names.includes(choice)){choice='';try{localStorage.removeItem('pulse.device');}catch(e){}}
  var next=choice||defaultDevice(names,interfaces);
  if(next!==selected){flow=[];hideHover();selected=next;}
  function deviceLabel(n){var members=deviceNetworks(n,devices,interfaces);return n+(members.length?' / '+members.join(', '):'');}
  var automatic=defaultDevice(names,interfaces);
  var options=[['',_('Auto · %s','pulse').format(automatic?deviceLabel(automatic):_('No device available','pulse'))]].concat(names.map(function(n){return [n,deviceLabel(n)];})),signature=JSON.stringify(options);
  if(signature!==optionSignature){select.replaceChildren();options.forEach(function(o){select.appendChild(E('option',{value:o[0]},o[1]));});optionSignature=signature;}
  select.value=choice;select.title=choice?deviceLabel(selected):_('Auto · %s','pulse').format(selected?deviceLabel(selected):_('No device available','pulse'));
 }
 function field(key,cls,value){refs[key]=E('div',{class:cls},value||'—');return refs[key];}
 function meter(key){
  refs[key+'Segments']=Array.from({length:20},function(){return E('span',{'aria-hidden':'true'});});
  refs[key+'Meter']=E('div',{class:'hd-resource-meter',role:'img','aria-label':_('Collecting samples','pulse')},refs[key+'Segments']);
  return E('div',{class:'hd-meter-row'},refs[key+'Meter']);
 }
 function updateCpuMeter(sample){
  var parts=sample.cpuParts,valid=parts&&['user','system','steal'].every(function(k){return Number.isFinite(parts[k])&&parts[k]>=0;});
  var ends=valid?[parts.user,parts.user+parts.system,parts.user+parts.system+parts.steal]:[0,0,0];
  refs.cpuSegments.forEach(function(segment,i){
   var stops=ends.map(function(end){return Math.max(0,Math.min(100,(end-i*5)*20));});
   segment.style.background='linear-gradient(to right,var(--hd-cpu-user) 0 '+stops[0]+'%,var(--hd-cpu-system) '+stops[0]+'% '+stops[1]+'%,var(--hd-cpu-steal) '+stops[1]+'% '+stops[2]+'%,var(--hd-meter-empty) '+stops[2]+'% 100%)';
  });
  var label=valid?_('User (including nice): %s; system (including interrupts): %s; steal: %s','pulse').format(parts.user.toFixed(1)+' %',parts.system.toFixed(1)+' %',parts.steal.toFixed(1)+' %'):_('Collecting CPU statistics','pulse');
  refs.cpuMeter.setAttribute('aria-label',label);
 }
 function metricIcon(kind){
  var icon=svg('svg',{viewBox:'0 0 24 24',width:19,height:19,style:'display:block;width:19px;height:19px',fill:'none',stroke:'currentColor','stroke-width':1.7,'stroke-linecap':'round','stroke-linejoin':'round','aria-hidden':'true'});
  if(kind==='temperature'){
   icon.appendChild(svg('path',{d:'M10 13.54V5a2 2 0 0 1 4 0v8.54a4 4 0 1 1-4 0Z'}));
   icon.appendChild(svg('path',{d:'M12 8v9'}));
   icon.appendChild(svg('circle',{cx:12,cy:17,r:1.3,fill:'currentColor',stroke:'none'}));
  }else if(kind==='cpu'){
   icon.appendChild(svg('circle',{cx:12,cy:12,r:9}));
   icon.appendChild(svg('path',{d:'M12 3v9H3'}));
  }else if(kind==='mem'){
   icon.appendChild(svg('rect',{x:4,y:4,width:16,height:16,rx:1}));
   icon.appendChild(svg('path',{d:'M4 8h16M4 12h16M4 16h16'}));
  }else if(kind==='connections'){
   icon.appendChild(svg('path',{d:'M3 8h18l-4-4M21 16H3l4 4'}));
  }else{
   icon.appendChild(svg('circle',{cx:12,cy:12,r:9}));
   icon.appendChild(svg('circle',{cx:12,cy:12,r:3,fill:'currentColor',stroke:'none'}));
  }
  return E('span',{class:'hd-icon'},icon);
 }
 function tile(key,label,icon,unit){
  var chart=E('div',{class:'hd-mini'});refs[key+'Chart']=chart;
  return E('section',{class:'hd-card hd-metric-card'+(key==='mem'?' hd-memory-card':key==='cpu'?' hd-cpu-card':'')},[
   E('div',{class:'hd-tile-head'},[metricIcon(icon),E('span',{class:'hd-tile-title'},label)]),
   E('div',{class:'hd-value'},[field(key,'','—'),key==='mem'?field('memDetail','hd-memory-capacity',_('Loading','pulse')):'',unit?E('span',{class:'hd-unit'},unit):'']),
   key==='cpu'||key==='mem'?meter(key):field(key+'Detail','hd-detail',_('Loading','pulse')),
   E('div',{class:'hd-tile-foot'},[field(key+'Mean','',_('Avg —','pulse')),field(key+'Peak','',_('Peak —','pulse'))]),chart]);
 }

 function diskCard(key, isRoot) {
  var label=field(key+'Mount','hd-label',isRoot?_('Root filesystem /','pulse'):'');
  refs[key+'Ring']=E('div',{class:'hd-disk-ring',role:'img','aria-label':_('Loading disk capacity','pulse')},[field(key+'Percent','hd-disk-percent')]);
  refs[key+'Card']=E('section',{class:'hd-card hd-disk-card'+(isRoot?'':' hd-extra-disk')},[
   E('div',{class:'hd-tile-head'},[metricIcon('disk'),E('span',{class:'hd-tile-title'},_('Disk usage','pulse'))]),
   E('div',{class:'hd-disk-body'},[refs[key+'Ring'],E('div',{class:'hd-disk-details'},[
    label,field(key+'Used','hd-disk-used'),field(key+'Free','hd-sub'),field(key+'Total','hd-sub')])])]);
  return refs[key+'Card'];
 }
 function updateDisk(key,disk,label) {
  var total=disk&&disk.total,used=disk&&disk.used,free=disk&&disk.free;
  var valid=Number.isFinite(total)&&total>0&&Number.isFinite(used)&&used>=0;
  var percent=valid?Math.max(0,Math.min(100,used/total*100)):null,ring=refs[key+'Ring'];
  ring.style.setProperty('--disk-used',(percent||0)+'%');ring.classList.toggle('hd-disk-unknown',!valid);
  ring.setAttribute('aria-label',valid?_('%s: %s used, %s of %s','pulse').format(label,percent.toFixed(1)+' %',bytes(used),bytes(total)):_('%s: capacity unavailable','pulse').format(label));
  text(refs[key+'Percent'],valid?percent.toFixed(1)+' %':'—');text(refs[key+'Mount'],label);refs[key+'Mount'].title=label;
  text(refs[key+'Used'],valid?_('Used %s','pulse').format(bytes(used)):_('Capacity unavailable','pulse'));text(refs[key+'Free'],valid&&Number.isFinite(free)?_('Free %s','pulse').format(bytes(free)):_('Free —','pulse'));text(refs[key+'Total'],valid?_('Total %s','pulse').format(bytes(total)):_('Total —','pulse'));
 }
 function updateExtraDisks(disks) {
  var card=refs.extra0Card,disk=Array.isArray(disks)?disks[0]:null;
  var empty=Array.isArray(disks)&&!disk;
  card.hidden=empty;
  card.setAttribute('aria-hidden',empty?'true':'false');
  card.title=disk?disk.device+' · '+disk.type+' · '+disk.mount:'';
  if(!empty)updateDisk('extra0',disk,disk?disk.mount:_('Mount information unavailable','pulse'));
 }
 var copyNotice=E('div',{class:'hd-copy-notice',role:'status','aria-live':'polite',hidden:''}),copyTimer;
 function copyAddress(address,anchor){
  function fallback(){
   var focus=document.activeElement,input=E('textarea',{class:'hd-copy-input',readonly:'',tabindex:'-1'});
   input.value=address;document.body.appendChild(input);
   try{input.select();if(!document.execCommand('copy'))throw new Error('Copy failed');}
   finally{input.remove();if(focus&&focus.focus)focus.focus({preventScroll:true});}
  }
  var copying;
  try{copying=navigator.clipboard&&navigator.clipboard.writeText?navigator.clipboard.writeText(address).catch(fallback):Promise.resolve(fallback());}
  catch(e){copying=Promise.reject(e);}
  function feedback(message){
   clearTimeout(copyTimer);text(copyNotice,message);copyNotice.hidden=false;
   var box=anchor.getBoundingClientRect(),notice=copyNotice.getBoundingClientRect();
   copyNotice.style.left=Math.max(8,Math.min(box.left,window.innerWidth-notice.width-8))+'px';
   copyNotice.style.top=Math.max(8,box.bottom+6+notice.height<=window.innerHeight-8?box.bottom+6:box.top-notice.height-6)+'px';
   copyTimer=setTimeout(function(){copyNotice.hidden=true;},2000);
  }
  copying.then(function(){feedback(_('IP address copied','pulse'));},function(){feedback(_('Copy failed. Select and copy the address manually.','pulse'));});
 }
 var addressState={};
 function updateAddresses(key,device,addresses){
  var previous=addressState[key]||{},host=refs[key];
  var signature=JSON.stringify([selected,!!device,addresses]);if(signature===previous.signature)return;
  var scrollTop=previous.device===selected?host.scrollTop:0;
  addressState[key]={signature:signature,device:selected};host.replaceChildren();
  host.classList.add('hd-address-list');
  if(!addresses.length)text(host,device?_('Not assigned','pulse'):_('Device unavailable','pulse'));
  addresses.forEach(function(entry){
   host.appendChild(E('div',{},[entry.networks.length?entry.networks.join(', ')+' · ':'',E('button',{type:'button',class:'hd-copy-address','aria-label':_('Copy IP address %s','pulse').format(entry.address),click:function(event){copyAddress(entry.address,event.currentTarget);}},entry.address)]));
  });
  host.scrollTop=scrollTop;
 }
 var temperatureCard=tile('temperature',_('Temperature','pulse'),'temperature');
 var big=E('div',{class:'hd-chart'}),canvas=E('div',{class:'hd-plot'}),yaxis=E('div',{class:'hd-y-axis','aria-label':_('Traffic rate scale','pulse')}),tooltip=E('div',{class:'hd-tooltip',hidden:''}),guide=E('div',{class:'hd-pointer-guide',hidden:'','aria-hidden':'true'});var hoverTime=null,hoverCeiling=1,hoverDots=['up','down'].map(function(key){return E('span',{class:'hd-hover-dot hd-hover-'+key,hidden:'','aria-hidden':'true'});});big.append(yaxis,canvas,guide,hoverDots[0],hoverDots[1],tooltip);
 function hideHover(){hoverTime=null;tooltip.hidden=true;guide.hidden=true;hoverDots.forEach(function(dot){dot.hidden=true;});}
 function renderHover(){
  if(hoverTime==null)return;
  var sample=drawFlow.find(function(s){return s.t===hoverTime;});
  if(!sample||!['up','down'].some(function(k){return Number.isFinite(sample[k]);})){hideHover();return;}
  var box=canvas.getBoundingClientRect(),outer=big.getBoundingClientRect();
  var x=box.left-outer.left+box.width*(1-(flow[flow.length-1].t-sample.t)/TRAFFIC_WINDOW_MS);
  guide.hidden=false;guide.style.left=x+'px';
  ['up','down'].forEach(function(key,i){var dot=hoverDots[i];dot.hidden=!Number.isFinite(sample[key]);if(dot.hidden)return;
   dot.style.left=x+'px';dot.style.top=(box.top-outer.top+box.height*(175-165*sample[key]/hoverCeiling)/180)+'px';
  });
  tooltip.hidden=false;text(tooltip,clock(sample.t)+(sample.interval>6?' '+_('(%s-second average)','pulse').format(Math.round(sample.interval)):'')+'\n↑ '+_('Up','pulse')+' '+rate(sample.up)+'\n↓ '+_('Down','pulse')+' '+rate(sample.down));
  tooltip.style.left=Math.max(0,Math.min(outer.width-190,x+12))+'px';tooltip.style.top='12px';
 }

 function portIcon(up){
  var icon=svg('svg',{viewBox:'0 0 24 24',width:16,height:16,style:'width:16px;height:16px',fill:'none',stroke:'currentColor','stroke-width':1.6,'stroke-linecap':'round','stroke-linejoin':'round','aria-hidden':'true'});
  icon.appendChild(svg('path',{d:'M4 5h16v11h-4v3H8v-3H4Z'}));
  icon.appendChild(svg('path',{d:'M7.5 5v5M10.5 5v5M13.5 5v5M16.5 5v5'}));
  return E('div',{class:'hd-port-icon'+(up?'':' hd-down')},icon);
 }
 function statusIcon(kind){
  var icon=svg('svg',{width:19,height:19,style:'width:19px;height:19px;flex:0 0 19px',viewBox:'0 0 24 24',fill:'none',stroke:'currentColor','stroke-width':1.7,'stroke-linecap':'round','stroke-linejoin':'round','aria-hidden':'true',class:'hd-status-icon'});
  if(kind==='dns')icon.appendChild(svg('path',{d:'M12 3 4 6v6c0 4 4 7 8 9 4-2 8-5 8-9V6Z'}));
  else{
   icon.appendChild(svg('circle',{cx:12,cy:12,r:9}));
   if(kind==='clock')icon.appendChild(svg('path',{d:'M12 6v6l4 2'}));
   else{icon.appendChild(svg('ellipse',{cx:12,cy:12,rx:4,ry:9}));icon.appendChild(svg('path',{d:'M3 12h18M5 7h14M5 17h14'}));}
  }
  return icon;
 }
 var dockerCard=E('section',{class:'hd-card hd-docker-card',hidden:''},[
  E('div',{class:'hd-card-head'},[E('div',{},[E('h3',{},_('Docker status','pulse'))]),field('dockerCount','hd-label')]),field('dockerList','hd-docker-list')
 ]);
 var dockerSignature='';
 function makeNameObserver(){return typeof ResizeObserver==='function'?new ResizeObserver(function(entries){
  entries.forEach(function(entry){
   var host=entry.target,track=host.firstElementChild;
   if(!track.classList.contains('hd-name-track')){
    var original=track;
    track=E('span',{class:'hd-name-track'});
    host.replaceChildren(track);track.appendChild(original);
   }
   var label=track.firstElementChild,width=label.getBoundingClientRect().width,scrolling=width-host.clientWidth>1;
   if(scrolling&&track.children.length===1){
    var copy=label.cloneNode(true);copy.classList.add('hd-name-copy');copy.setAttribute('aria-hidden','true');track.appendChild(copy);
   }else if(!scrolling&&track.children.length>1)track.lastElementChild.remove();
   var distance=width+24;
   host.style.setProperty('--hd-name-shift',-distance+'px');
   host.style.setProperty('--hd-name-duration',distance/50+'s');
   host.classList.toggle('hd-name-scrolling',scrolling);
  });
 }):null;}
 var dockerNameObserver=makeNameObserver(),portNameObserver=makeNameObserver(),portSignature='';
 function updateDocker(data){
  data=data||{state:'unavailable',containers:[]};
  var visible=data.state!=='absent';dockerCard.hidden=!visible;
  root.querySelector('.hd-middle').classList.toggle('hd-with-docker',visible);
  var signature=JSON.stringify(data);if(signature===dockerSignature)return;dockerSignature=signature;
  if(dockerNameObserver)dockerNameObserver.disconnect();
  text(refs.dockerCount,data.state==='ok'?(data.containers.length===1?_('%s container','pulse'):_('%s containers','pulse')).format(data.containers.length):'');refs.dockerList.replaceChildren();
  if(data.state!=='ok'){text(refs.dockerList,_('Docker service unavailable','pulse'));return;}
  if(!data.containers.length){text(refs.dockerList,_('No containers','pulse'));return;}
  data.containers.forEach(function(container){
   var label=container.label||(container.kind==='running'?_('Running','pulse'):container.kind==='stopped'?_('Not running','pulse'):_('Error','pulse'));
   refs.dockerList.appendChild(E('div',{class:'hd-container hd-container-'+container.kind,'aria-label':container.name+': '+label},[
    E('span',{class:'hd-container-name',tabindex:'0','aria-label':container.name},[E('span',{class:'hd-container-name-text'},container.name)]),E('span',{class:'hd-container-state'},label)
   ]));
  });
  if(dockerNameObserver)refs.dockerList.querySelectorAll('.hd-container-name').forEach(function(name){dockerNameObserver.observe(name);});
 }
 var root=E('div',{class:'hd'},[
 E('section',{class:'hd-card hd-strip'},[
  E('div',{class:'hd-uptime'},[statusIcon('clock'),E('div',{class:'hd-label'},_('System uptime','pulse')),field('uptime','hd-stat')]),
  E('div',{class:'hd-connection'},[
   E('div',{class:'hd-connection-row'},[field('connection','hd-stat'),select]),
   E('div',{class:'hd-connection-totals'},[E('span',{class:'hd-label'},_('Device totals','pulse')),E('span',{class:'hd-transfer-total'},['↑ ',field('sent','','—')]),E('span',{class:'hd-transfer-total'},['↓ ',field('received','','—')])])
  ]),
  E('div',{class:'hd-network-addresses'},[
   E('div',{},[E('div',{class:'hd-address-heading'},[statusIcon('globe'),E('span',{class:'hd-label'},'IPv4')]),field('ipv4','hd-address')]),
   E('div',{},[E('div',{class:'hd-address-heading'},[statusIcon('globe'),E('span',{class:'hd-label'},'IPv6')]),field('ipv6','hd-address')]),
   E('div',{},[E('div',{class:'hd-address-heading'},[statusIcon('dns'),E('span',{class:'hd-label'},'DNS')]),field('dns','hd-address')])
  ])
 ]),
 E('div',{class:'hd-grid hd-vitals'},[tile('cpu',_('CPU usage','pulse'),'cpu'),tile('mem',_('Memory usage','pulse'),'mem'),tile('connections',_('Connections','pulse'),'connections'),diskCard('disk',true),diskCard('extra0',false)]),
 E('div',{class:'hd-grid hd-middle'},[
 E('section',{class:'hd-card hd-flow-card'},[
  E('div',{class:'hd-card-head'},[
   E('div',{class:'hd-flow-heading'},[E('h3',{},_('Network traffic','pulse')),E('div',{class:'hd-flow-controls'},[field('chartSub','hd-sub',_('Last 1 minute','pulse'))])]),
   E('div',{class:'hd-flow-summary'},[
    E('div',{class:'hd-legend'},[E('span',{class:'hd-gray'},['↑ '+_('Up','pulse')+' ',field('upLegend','','—')]),E('span',{class:'hd-blue'},['↓ '+_('Down','pulse')+' ',field('downLegend','','—')])])])
  ]),big,E('div',{class:'hd-axis'},[field('start','',_('Sampling started','pulse')),field('end','',_('Now','pulse'))])]),
 E('section',{class:'hd-card hd-ports-card'},[E('div',{class:'hd-card-head'},[E('div',{},[E('h3',{},_('Network ports','pulse'))]),field('portCount','hd-label')]),field('ports','hd-ports',_('Loading ports','pulse'))]),dockerCard]),
 ]);
 var githubIcon=svg('svg',{viewBox:'0 0 24 24',width:12,height:12,style:'display:block;width:1em;height:1em;flex:none',fill:'currentColor','aria-hidden':'true'});
 githubIcon.appendChild(svg('path',{d:'M12 .297C5.37.297 0 5.67 0 12.297c0 5.303 3.438 9.8 8.205 11.385.6.113.82-.258.82-.577 0-.285-.01-1.04-.015-2.04-3.338.724-4.043-1.61-4.043-1.61-.546-1.387-1.333-1.756-1.333-1.756-1.09-.745.083-.73.083-.73 1.205.084 1.838 1.237 1.838 1.237 1.07 1.835 2.809 1.305 3.495.998.108-.776.418-1.305.762-1.605-2.665-.305-5.467-1.334-5.467-5.93 0-1.31.469-2.381 1.236-3.221-.124-.303-.536-1.524.117-3.176 0 0 1.008-.322 3.301 1.23A11.52 11.52 0 0 1 12 6.097c1.02.005 2.045.138 3.003.405 2.291-1.552 3.297-1.23 3.297-1.23.655 1.652.243 2.873.12 3.176.77.84 1.235 1.911 1.235 3.221 0 4.609-2.807 5.621-5.479 5.921.43.372.823 1.102.823 2.222 0 1.606-.015 2.898-.015 3.293 0 .322.216.694.825.576C20.565 22.092 24 17.597 24 12.297c0-6.627-5.373-12-12-12'}));
 root.appendChild(E('small',{class:'hd-version'},E('a',{href:'https://github.com/w9315273/luci-app-pulse',target:'_blank',rel:'noopener noreferrer','aria-label':'GitHub · Pulse v'+VERSION},[githubIcon,E('span',{},'Pulse v'+VERSION)])));
 root.appendChild(copyNotice);
 var style=E('link',{rel:'stylesheet',href:L.resource('pulse/dashboard.css')+'?v=20261027-name-loop-1'});root.prepend(style);
 function update(d){
 updateDocker(d[11]);
 latest=d;syncSelection(d[0],d[1]);var devices=d[0],ifs=d[1],info=d[2],dev=devices[selected],now=Date.now();
 var traffic=d[10],flowNow=traffic&&traffic.now||now;
 flow=traffic&&traffic.device===selected&&Array.isArray(traffic.samples)?traffic.samples.filter(function(s){return s.t>=flowNow-TRAFFIC_WINDOW_MS;}):[];
 var rawFlow=traffic&&traffic.device===selected&&Array.isArray(traffic.samples)?traffic.samples:[];
 var live=rawFlow.length&&flowNow-rawFlow[rawFlow.length-1].t<=10000?rawFlow[rawFlow.length-1]:{};
 history=traffic&&Array.isArray(traffic.vitals)?traffic.vitals.filter(function(s){return s.t>=flowNow-WINDOW_MS;}):[];
 var sample=history.length&&flowNow-history[history.length-1].t<=10000?history[history.length-1]:{};
 var mem={total:sample.memoryTotal},sensor=Number.isFinite(sample.temperature)?{value:sample.temperature}:null;
 updateCpuMeter(sample);
 var parts=sample.memoryParts,valid=parts&&sample.memoryTotal>0;
 var ends=valid?[parts.used,parts.used+parts.buffers,parts.used+parts.buffers+parts.cache].map(function(n){return 100*n/sample.memoryTotal;}):[0,0,0];
 refs.memSegments.forEach(function(segment,i){
  var stops=ends.map(function(end){return Math.max(0,Math.min(100,(end-i*5)*20));});
  segment.style.background='linear-gradient(to right,var(--hd-memory-used) 0 '+stops[0]+'%,var(--hd-memory-buffer) '+stops[0]+'% '+stops[1]+'%,var(--hd-memory-cache) '+stops[1]+'% '+stops[2]+'%,var(--hd-meter-empty) '+stops[2]+'% 100%)';
 });
 refs.memMeter.setAttribute('aria-label',valid?_('Used %s; buffers %s; cache %s; free %s','pulse').format(bytes(parts.used),bytes(parts.buffers),bytes(parts.cache),bytes(parts.free)):_('Memory breakdown unavailable','pulse'));

 var vitals=root.querySelector('.hd-vitals');
 if(sensor){
  if(temperatureCard.parentNode!==vitals){vitals.prepend(temperatureCard);}
 }else if(temperatureCard.parentNode===vitals){temperatureCard.remove();}

 ['cpu','mem'].forEach(function(k){var known=history.some(function(s){return Number.isFinite(s[k]);});text(refs[k],sample[k]==null?'—':sample[k].toFixed(1)+' %');text(refs[k+'Mean'],_('Avg %s','pulse').format(known?mean(history,k).toFixed(1)+' %':'—'));text(refs[k+'Peak'],_('Peak %s','pulse').format(known?max(history,k).toFixed(1)+' %':'—'));plot(refs[k+'Chart'],history,[k],['var(--hd-blue)'],'hd-'+k,true);});
 if(sensor){
  text(refs.temperature,sensor.value.toFixed(1)+' °C');
  text(refs.temperatureDetail,'');
  text(refs.temperatureMean,_('Avg %s','pulse').format(mean(history,'temperature').toFixed(1)+' °C'));
  var readings=history.map(function(s){return s.temperature;}).filter(function(v){return v!=null;});
  text(refs.temperaturePeak,_('Peak %s','pulse').format(Math.max.apply(null,readings).toFixed(1)+' °C'));
  plot(refs.temperatureChart,history,['temperature'],['var(--hd-blue)'],'hd-temperature',false);
 }
 var count=sample.connections,limit=sample.connectionMax;
 text(refs.connections,count==null?'—':count.toLocaleString());
 text(refs.connectionsDetail,_('Limit %s · Used %s','pulse').format(limit>0?limit.toLocaleString():'—',count!=null&&limit>0?(count/limit*100).toFixed(1)+' %':'—'));
 var knownConnections=history.some(function(s){return s.connections!=null;});
 text(refs.connectionsMean,_('Avg %s','pulse').format(knownConnections?Math.round(mean(history,'connections')).toLocaleString():'—'));
 text(refs.connectionsPeak,_('Peak %s','pulse').format(knownConnections?max(history,'connections').toLocaleString():'—'));
 plot(refs.connectionsChart,history,['connections'],['var(--hd-blue)'],'hd-connections',false);
 var disk=info.root||{};updateDisk('disk',{total:disk.total*1024,used:disk.used*1024,free:disk.free*1024},_('Root filesystem /','pulse'));
 updateExtraDisks(d[6]);
 vitals.style.setProperty('--hd-card-count',Array.from(vitals.children).filter(function(card){return !card.hidden;}).length);
 text(refs.memDetail,bytes(mem.total*(sample.mem||0)/100)+' / '+bytes(mem.total));
 ['down','up'].forEach(function(k){text(refs[k+'Legend'],live[k]==null?'—':rate(live[k]));});
 drawFlow=visualTraffic(flow);
 var scale=plot(canvas,drawFlow,['up','down'],['var(--hd-secondary)','var(--hd-blue)'],'hd-main',false);if(!flow.some(function(s){return s.up!=null;}))canvas.appendChild(E('div',{class:'hd-chart-empty'},!traffic?_('Traffic sampling service unavailable','pulse'):dev?_('Waiting for traffic samples…','pulse'):_('Selected device unavailable','pulse')));
 yaxis.replaceChildren();for(var level=0;level<=scale.ticks;level++)yaxis.appendChild(E('span',{style:'top:'+((10+level*165/scale.ticks)/180*100)+'%'},Number((scale.step*(scale.ticks-level)).toPrecision(12))+' '+scale.unit));
 markTrafficPeak(canvas,drawFlow,scale.ceiling);hoverCeiling=scale.ceiling;renderHover();text(refs.chartSub,_('Last 1 minute','pulse'));text(refs.start,clock((flow.length?flow[flow.length-1].t:flowNow)-TRAFFIC_WINDOW_MS));text(refs.end,clock(flow.length?flow[flow.length-1].t:flowNow));text(refs.sent,bytes(dev&&dev.stats&&dev.stats.tx_bytes));text(refs.received,bytes(dev&&dev.stats&&dev.stats.rx_bytes));
 var names=sortPorts(d[9]||[],devices,ifs);
 var portKey=JSON.stringify([d[12],names.map(function(n){var link=(devices[n]||{}).link||{};return [n,link.carrier,link.speed,deviceNetworks(n,devices,ifs)];})]);
 if(portKey!==portSignature){
  portSignature=portKey;if(portNameObserver)portNameObserver.disconnect();
 text(refs.portCount,(names.length===1?_('%s device','pulse'):_('%s devices','pulse')).format(names.length));refs.ports.replaceChildren();
 names.forEach(function(n){
  var link=(devices[n]||{}).link||{},members=deviceNetworks(n,devices,ifs),up=link.carrier===true,known=typeof link.carrier==='boolean';
  refs.ports.appendChild(E('div',{class:'hd-port'+(known&&!up?' hd-port-offline':'')},[
   E('div',{class:'hd-port-heading'},[
    portIcon(up),
    E('div',{class:'hd-sub hd-port-summary',tabindex:'0','aria-label':n+(members.length?' '+members.join(', '):'')},[
     E('span',{class:'hd-container-name-text'},[E('span',{class:'hd-port-name'},n),E('span',{class:'hd-network-tags'},networkBadges(members,d[12]))])
    ]),
    E('span',{class:'hd-badge'+(up?'':' hd-down')},up&&link.speed>0?linkRate(link.speed):up?_('Unknown','pulse'):known?_('No link','pulse'):_('Unknown','pulse'))
   ])
  ]));
 });if(!names.length)text(refs.ports,_('No native port information found','pulse'));
  if(portNameObserver)refs.ports.querySelectorAll('.hd-port-summary').forEach(function(label){portNameObserver.observe(label);});
 }

 var related=ifs.filter(function(i){return i.l3_device===selected||i.device===selected;});var dns=[];related.forEach(function(i){dns=dns.concat(i['dns-server']||[]);});dns=dns.filter(Boolean);var dnsLabel='';if(!dns.length){dns=d[5].split('\n').filter(function(l){return /^\s*nameserver\s/.test(l);}).map(function(l){return l.trim().split(/\s+/)[1];}).filter(Boolean);dnsLabel=dns.length?' '+_('(system resolver)','pulse'):'';}
 updateAddresses('ipv4',dev,deviceAddresses(selected,devices,ifs,4));updateAddresses('ipv6',dev,deviceAddresses(selected,devices,ifs,6));text(refs.dns,dns.length?Array.from(new Set(dns)).join(', ')+dnsLabel:_('Unavailable','pulse'));
 var sec=info.uptime||0;text(refs.uptime,(sec>=86400?_('%sd %sh %sm','pulse').format(Math.floor(sec/86400),Math.floor(sec%86400/3600),Math.floor(sec%3600/60)):_('%sh %sm','pulse').format(Math.floor(sec/3600),Math.floor(sec%3600/60))));var state=connectionState(dev);text(refs.connection,state.label);refs.connection.className='hd-stat hd-connection-status hd-status-'+state.kind;
 }
 select.addEventListener('change',function(){choice=select.value;try{if(choice)localStorage.setItem('pulse.device',choice);else localStorage.removeItem('pulse.device');}catch(e){}hideHover();update(latest);loadTraffic(latest).then(update);});
 big.addEventListener('pointermove',function(e){
  var box=canvas.getBoundingClientRect();
  if(!flow.length||e.clientX<box.left||e.clientX>box.right){hideHover();return;}
  var target=flow[flow.length-1].t-TRAFFIC_WINDOW_MS+(e.clientX-box.left)/box.width*TRAFFIC_WINDOW_MS;
  var sample=flow.reduce(function(a,b){return Math.abs(b.t-target)<Math.abs(a.t-target)?b:a;});
  if(Math.abs(sample.t-target)>3000){hideHover();return;}
  hoverTime=sample.t;renderHover();
 });
 big.addEventListener('pointerleave',hideHover);

 update(data);
 poll.add(function(){var diskRequest=Date.now()-storageFetched>=15000?L.resolveDefault(loadStorage(),null).then(function(disks){storageFetched=Date.now();return disks;}):Promise.resolve(latest[6]);return Promise.all([devicesRPC(),interfacesRPC(),infoRPC(),Promise.resolve(latest[3]),Promise.resolve(''),L.resolveDefault(fs.read('/etc/resolv.conf'),''),diskRequest,Promise.resolve({}),Promise.resolve(null),loadPorts()]).then(loadTraffic).then(update).catch(function(){text(refs.upLegend,'—');text(refs.downLegend,'—');});},2);
 return root;
 }
});
