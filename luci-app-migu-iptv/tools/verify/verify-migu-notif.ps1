# 微基准：猴补 ui.addNotification，复点生成令牌按钮，观察调用与异常
$ErrorActionPreference = 'Stop'
$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
chcp 65001 > $null
try { Add-Type -AssemblyName System.Net.WebSockets } catch { }

$thorium = 'D:\浏览器\BIN\thorium.exe'
$prof    = 'D:\AI\_mt\thorium-prof-migu6'
$port    = 9353
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
if (-not $targets) { $proc | Stop-Process -Force; exit 1 }
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

Send-CDP -Method 'Page.navigate' -Params @{url='http://192.168.69.1/cgi-bin/luci/'}|Out-Null
Start-Sleep -Seconds 4
if ((Eval-JS 'document.querySelector("input[name=luci_username]")?"y":"n"') -eq 'y') {
  Eval-JS ('document.querySelector("input[name=luci_username]").value="root";document.querySelector("input[name=luci_password]").value="__ROUTER_PASS__";document.querySelector("form").submit();"s"'.Replace('__ROUTER_PASS__', $env:ROUTER_PASS))|Out-Null
  Start-Sleep -Seconds 5
}
Send-CDP -Method 'Page.navigate' -Params @{url='http://192.168.69.1/cgi-bin/luci/admin/services/migu/config'}|Out-Null
Start-Sleep -Seconds 10

Write-Host "=== 1) 直接调用 ui.addNotification 看是否能渲染 ==="
$d = Eval-JS @'
L.require('ui').then(function(m){
  window.__uiMod = m;
  try {
    m.addNotification(null, E('p', {}, ['DIRECT_NOTIF_TEST_9f2a']), 'info');
    window.__direct = 'called';
  } catch(e) { window.__direct = 'THROW: ' + e; }
  return 'patched';
})
'@
Write-Host "  调用结果: $d"
Start-Sleep -Seconds 1
$t1 = Eval-JS '(document.body.innerText.indexOf("DIRECT_NOTIF_TEST_9f2a")>=0)?"FOUND":"MISSING"'
Write-Host "  直接调用渲染: $t1"

Write-Host ""
Write-Host "=== 2) 猴补 addNotification 后再点生成按钮 ==="
Eval-JS @'
L.require('ui').then(function(m){
  if(window.__patched) return 'already';
  window.__an=[]; window.__anErr=null;
  var orig = m.addNotification;
  m.addNotification = function(title, text, cls){
    try {
      var t = (text && text.outerHTML) ? text.outerHTML.slice(0,400) : (''+text).slice(0,400);
      window.__an.push({title:(''+title).slice(0,40), cls:(''+cls), text:t});
    } catch(e){ window.__an.push({err:''+e}); }
    try { return orig.apply(this, arguments); }
    catch(e){ window.__anErr = '' + e; throw e; }
  };
  window.__patched = true;
  return 'patched';
})
'@ | Out-Null
$before = Eval-JS '(function(){var e=document.getElementById("widget.cbid.migu.main.publicToken");return e?e.value.slice(0,8):"?"})()'
Write-Host "  点击前令牌前 8 位: $before"
Eval-JS @'
(function(){
  var b=document.querySelectorAll('button, input[type=button], input[type=submit]');
  for(var i=0;i<b.length;i++){
    var t=(b[i].value||b[i].textContent||'').trim();
    if(t.indexOf('随机生成')>=0){b[i].click();return 'CLICKED';}
  } return 'NOT-FOUND';
})()
'@ | Out-Null
Start-Sleep -Seconds 6

$an = Eval-JS 'JSON.stringify(window.__an||[])'
Write-Host "  addNotification 捕获: $an"
$anErr = Eval-JS 'window.__anErr===null?"无异常":(""+window.__anErr)'
Write-Host "  原始实现异常: $anErr"
$after = Eval-JS '(function(){var e=document.getElementById("widget.cbid.migu.main.publicToken");return e?e.value:"?"})()'
Write-Host "  点击后令牌: $after"
$found = Eval-JS '(document.body.innerText.indexOf("已生成令牌")>=0)?"页面可见":"页面上找不到成功文案"'
Write-Host "  $found"

$errs = Eval-JS 'JSON.stringify(window.__errs||[])'
Write-Host "  JS 错误: $errs"

$shot = Send-CDP -Method 'Page.captureScreenshot' -Params @{format='png';fullPage=$true}
if ($shot -and $shot.result -and $shot.result.data) {
  [IO.File]::WriteAllBytes('D:\AI\_mt\migu-notif.png',[Convert]::FromBase64String($shot.result.data))
  Write-Host "[截图] D:\AI\_mt\migu-notif.png"
}
$ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure,'done',$ct).Wait(3000)|Out-Null
$proc | Stop-Process -Force
Write-Host "[完成]"
