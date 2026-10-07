# 复测：点击生成令牌 → 用正确选择器读值 → 确认通知 → 确认未落盘
$ErrorActionPreference = 'Stop'
$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
chcp 65001 > $null
try { Add-Type -AssemblyName System.Net.WebSockets } catch { }

$thorium = 'D:\浏览器\BIN\thorium.exe'
$prof    = 'D:\AI\_mt\thorium-prof-migu4'
$port    = 9349
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
Send-CDP -Method 'Runtime.evaluate' -Params @{expression='window.__errs=[];window.addEventListener("error",e=>window.__errs.push(e.message));"ok"'}|Out-Null

# 登录
Send-CDP -Method 'Page.navigate' -Params @{url='http://192.168.69.1/cgi-bin/luci/'}|Out-Null
Start-Sleep -Seconds 4
if ((Eval-JS 'document.querySelector("input[name=luci_username]")?"y":"n"') -eq 'y') {
  Eval-JS ('document.querySelector("input[name=luci_username]").value="root";document.querySelector("input[name=luci_password]").value="__ROUTER_PASS__";document.querySelector("form").submit();"s"'.Replace('__ROUTER_PASS__', $env:ROUTER_PASS))|Out-Null
  Start-Sleep -Seconds 5
}
# 设置页
Send-CDP -Method 'Page.navigate' -Params @{url='http://192.168.69.1/cgi-bin/luci/admin/services/migu/config'}|Out-Null
Start-Sleep -Seconds 10

Write-Host "=== 1) 令牌输入框定位（双选择器）==="
$loc = Eval-JS @'
(function(){
  var byData = document.querySelector('[data-widget-id="widget.cbid.migu.main.publicToken"]');
  var byId   = document.getElementById('widget.cbid.migu.main.publicToken');
  return JSON.stringify({
    byData: byData ? (byData.tagName+'/'+byData.type) : null,
    byId:   byId   ? (byId.tagName+'/'+byId.type)   : null,
    beforeVal: (byId||byData) ? (byId||byData).value : null
  });
})()
'@
Write-Host "  $loc"

Write-Host ""
Write-Host "=== 2) 点击「随机生成一个 32 位令牌」==="
Eval-JS @'
(function(){
  var b=document.querySelectorAll('button, input[type=button], input[type=submit]');
  for(var i=0;i<b.length;i++){
    var t=(b[i].value||b[i].textContent||'').trim();
    if(t.indexOf('随机生成')>=0){b[i].click();return 'CLICKED';}
  } return 'NOT-FOUND';
})()
'@ | Out-Null
# gentoken 走 ubus，留足时间
Start-Sleep -Seconds 6

$after = Eval-JS @'
(function(){
  var el = document.getElementById('widget.cbid.migu.main.publicToken')
        || document.querySelector('[data-widget-id="widget.cbid.migu.main.publicToken"]');
  var v = el ? el.value : 'NO-ELEM';
  var notif = document.querySelector('.notification-message,[class*=notification]');
  return JSON.stringify({value: v, len: (v==='NO-ELEM'?-1:v.length),
    hex32: /^[0-9a-f]{32}$/.test(v),
    notif: notif ? notif.innerText.slice(0,100) : null});
})()
'@
Write-Host "  $after"

Write-Host ""
Write-Host "=== 3) JS 报错 ==="
Write-Host "  $(Eval-JS 'JSON.stringify(window.__errs||[])')"

Write-Host ""
Write-Host "=== 4) 路由器 UCI 实值（应仍为空 = 未落盘）==="
. 'D:\AI\_mt\_upload-lib.ps1'
$uci = Invoke-Remote "echo `"pk=`$(uci -q get migu.main.publicToken)`; pa=`$(uci -q get migu.main.publicAccess)`""
Write-Host "  $uci"

$shot = Send-CDP -Method 'Page.captureScreenshot' -Params @{format='png';fullPage=$true}
if ($shot -and $shot.result -and $shot.result.data) {
  [IO.File]::WriteAllBytes('D:\AI\_mt\migu-config-final.png',[Convert]::FromBase64String($shot.result.data))
  Write-Host "[截图] D:\AI\_mt\migu-config-final.png"
}
$ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure,'done',$ct).Wait(3000)|Out-Null
$proc | Stop-Process -Force
Write-Host "[完成]"
