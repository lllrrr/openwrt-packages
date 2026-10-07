# 带网络钩子的点击实测：抓 ubus 请求/响应 + 通知 + 令牌值
$ErrorActionPreference = 'Stop'
$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
chcp 65001 > $null
try { Add-Type -AssemblyName System.Net.WebSockets } catch { }

$thorium = 'D:\浏览器\BIN\thorium.exe'
$prof    = 'D:\AI\_mt\thorium-prof-migu5'
$port    = 9351
if (Test-Path $prof) { Remove-Item $prof -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Path $prof -Force | Out-Null
$proc = Start-Process -FilePath $thorium -PassThru -WindowStyle Hidden -ArgumentList @(
  '--headless=new','--disable-gpu','--no-sandbox','--no-first-run',
  '--no-default-browser-check','--disable-extensions','--mute-audio',
  "--remote-debugging-port=$port","--user-data-dir=$prof",'about:blank'
)
$targets = $null
for ($i=0; $i -lt 40; $i++) { Start-Sleep -Milliseconds 500
  try { $targets = Invoke-RestMethod -Uri "http://127.0.0.1:$port/json/list" -TimeoutSec 3; if ($targets){break} } catch {} }
if (-not $targets) { $proc | Stop-Process -Force; Write-Host "[FAIL]端口"; exit 1 }
$page = $targets | Where-Object { $_.type -eq 'page' } | Select-Object -First 1
$ws = New-Object System.Net.WebSockets.ClientWebSocket
$ct = [Threading.CancellationToken]::None
$ws.ConnectAsync([Uri]$page.webSocketDebuggerUrl, $ct).Wait(10000) | Out-Null

$script:id = 0
function Send-CDP {
  param([string]$Method,[hashtable]$Params=@{})
  $script:id++; $mid=$script:id
  $payload = @{id=$mid;method=$Method;params=$Params} | ConvertTo-Json -Depth 20 -Compress
  $bytes=[Text.Encoding]::UTF8.GetBytes($payload)
  $seg=New-Object ArraySegment[byte] -ArgumentList @(,$bytes)
  $ws.SendAsync($seg,[System.Net.WebSockets.WebSocketMessageType]::Text,$true,$ct).Wait(10000)|Out-Null
  $deadline=(Get-Date).AddSeconds(40)
  while((Get-Date) -lt $deadline){
    $buf=New-Object byte[] 131072; $sb=New-Object System.Text.StringBuilder
    do { $rseg=New-Object ArraySegment[byte] -ArgumentList @(,$buf)
         $res=$ws.ReceiveAsync($rseg,$ct); $res.Wait(10000)|Out-Null
         [void]$sb.Append([Text.Encoding]::UTF8.GetString($buf,0,$res.Result.Count))
    } while(-not $res.Result.EndOfMessage)
    try { $obj=$sb.ToString()|ConvertFrom-Json } catch { continue }
    if($obj.id -eq $mid){return $obj}
  }
  return $null
}
function Eval-JS {
  param([string]$Expr)
  $r=Send-CDP -Method 'Runtime.evaluate' -Params @{expression=$Expr;returnByValue=$true;awaitPromise=$true}
  if($r -and $r.result -and $r.result.result){return $r.result.result.value}
  return $null
}
Send-CDP -Method 'Page.enable'|Out-Null
Send-CDP -Method 'Runtime.enable'|Out-Null

# 登录
Send-CDP -Method 'Page.navigate' -Params @{url='http://192.168.69.1/cgi-bin/luci/'}|Out-Null
Start-Sleep -Seconds 4
if ((Eval-JS 'document.querySelector("input[name=luci_username]")?"y":"n"') -eq 'y') {
  Eval-JS ('document.querySelector("input[name=luci_username]").value="root";document.querySelector("input[name=luci_password]").value="__ROUTER_PASS__";document.querySelector("form").submit();"s"'.Replace('__ROUTER_PASS__', $env:ROUTER_PASS))|Out-Null
  Start-Sleep -Seconds 5
}

# 装网络钩子（在设置页加载前装，SPA 换页不清 window）
Eval-JS @'
(function(){
  window.__net=[];
  if(!window.__netHooked){
    window.__netHooked=true;
    var XO=XMLHttpRequest.prototype.open, XS=XMLHttpRequest.prototype.send;
    XMLHttpRequest.prototype.open=function(m,u){this.__m=m;this.__u=u;return XO.apply(this,arguments)};
    XMLHttpRequest.prototype.send=function(b){
      var self=this;
      self.addEventListener('load',function(){
        window.__net.push({via:'xhr',url:(''+self.__u).slice(0,120),
          body:((''+(b||'')).indexOf('gentoken')>=0||(''+self.__u).indexOf('ubus')>=0)?(''+(b||'')).slice(0,300):'',
          status:self.status,resp:(''+(self.responseText||'')).slice(0,300)});
      });
      return XS.apply(this,arguments)};
    if(window.fetch){
      var OF=window.fetch;
      window.fetch=function(u,o){
        var body=(o&&o.body)?(''+o.body):'';
        return OF.apply(this,arguments).then(function(r){
          r.clone().text().then(function(t){
            if(body.indexOf('gentoken')>=0||(''+u).indexOf('ubus')>=0)
              window.__net.push({via:'fetch',url:(''+u).slice(0,120),body:body.slice(0,300),
                status:r.status,resp:t.slice(0,300)});
          });
          return r;
        });
      };
    }
  }
  return 'hooked';
})()
'@ | Out-Null

# 打开设置页
Send-CDP -Method 'Page.navigate' -Params @{url='http://192.168.69.1/cgi-bin/luci/admin/services/migu/config'}|Out-Null
Start-Sleep -Seconds 10
# SPA 导航可能重置 window，重装钩子
Eval-JS @'
(function(){
  if(window.__netHooked)return 'still-hooked';
  window.__net=[];window.__netHooked=true;
  var XO=XMLHttpRequest.prototype.open, XS=XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.open=function(m,u){this.__m=m;this.__u=u;return XO.apply(this,arguments)};
  XMLHttpRequest.prototype.send=function(b){
    var self=this;
    self.addEventListener('load',function(){
      window.__net.push({via:'xhr',url:(''+self.__u).slice(0,120),
        body:(''+(b||'')).slice(0,300),status:self.status,
        resp:(''+(self.responseText||'')).slice(0,300)});
    });
    return XS.apply(this,arguments)};
  if(window.fetch){var OF=window.fetch;
    window.fetch=function(u,o){
      var body=(o&&o.body)?(''+o.body):'';
      return OF.apply(this,arguments).then(function(r){
        r.clone().text().then(function(t){
          if(body.indexOf('gentoken')>=0||body.indexOf('ubus')>=0||(''+u).indexOf('ubus')>=0)
            window.__net.push({via:'fetch',url:(''+u).slice(0,120),body:body.slice(0,300),
              status:r.status,resp:t.slice(0,300)});
        });
        return r;});};}
  return 're-hooked';
})()
'@ | Out-Null

Write-Host "=== 点击「随机生成一个 32 位令牌」==="
$click = Eval-JS @'
(function(){
  var b=document.querySelectorAll('button, input[type=button], input[type=submit]');
  for(var i=0;i<b.length;i++){
    var t=(b[i].value||b[i].textContent||'').trim();
    if(t.indexOf('随机生成')>=0){b[i].click();return 'CLICKED:'+t;}
  } return 'NOT-FOUND';
})()
'@
Write-Host "  $click"
Start-Sleep -Seconds 6

Write-Host ""
Write-Host "=== 网络请求抓包（ubus 相关）==="
$net = Eval-JS 'JSON.stringify((window.__net||[]).filter(function(n){return (n.url+n.body).indexOf("ubus")>=0||(n.body||"").indexOf("gentoken")>=0}))'
Write-Host "  $net"

Write-Host ""
Write-Host "=== 令牌框值 + 通知 ==="
$state = Eval-JS @'
(function(){
  var el = document.getElementById('widget.cbid.migu.main.publicToken')
        || document.querySelector('[data-widget-id="widget.cbid.migu.main.publicToken"]');
  var notifs = document.querySelectorAll('.notification, [class*=notification]');
  var arr = Array.prototype.slice.call(notifs).map(function(n){
    return n.className+' :: '+(n.innerText||'').trim().slice(0,120);});
  return JSON.stringify({
    tokenValue: el ? el.value : 'NO-ELEM',
    tokenLen: el ? el.value.length : -1,
    hex32: el ? /^[0-9a-f]{32}$/.test(el.value) : false,
    notifs: arr
  });
})()
'@
Write-Host "  $state"

Write-Host ""
Write-Host "=== JS 错误 ==="
$err = Eval-JS 'JSON.stringify(window.__errs||[])'
Write-Host "  $err"

# 截图存证（不保存表单）
$shot = Send-CDP -Method 'Page.captureScreenshot' -Params @{format='png';fullPage=$true}
if ($shot -and $shot.result -and $shot.result.data) {
  [IO.File]::WriteAllBytes('D:\AI\_mt\migu-token-click.png',[Convert]::FromBase64String($shot.result.data))
  Write-Host "[截图] D:\AI\_mt\migu-token-click.png"
}
$ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure,'done',$ct).Wait(3000)|Out-Null
$proc | Stop-Process -Force
Write-Host "[完成]"
