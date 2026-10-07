# 状态页双状态验证（当前为「公网开启+令牌+自定义地址」态）
$ErrorActionPreference = 'Stop'
$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
chcp 65001 > $null
try { Add-Type -AssemblyName System.Net.WebSockets } catch { }

$thorium = 'D:\浏览器\BIN\thorium.exe'
$prof    = 'D:\AI\_mt\thorium-status-on'
$port    = 9357
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
Send-CDP -Method 'Runtime.evaluate' -Params @{expression='window.__errs=[];window.addEventListener("error",e=>window.__errs.push(e.message));"ok"'}|Out-Null

Send-CDP -Method 'Page.navigate' -Params @{url='http://192.168.69.1/cgi-bin/luci/'}|Out-Null
Start-Sleep -Seconds 4
if ((Eval-JS 'document.querySelector("input[name=luci_username]")?"y":"n"') -eq 'y') {
  Eval-JS ('document.querySelector("input[name=luci_username]").value="root";document.querySelector("input[name=luci_password]").value="__ROUTER_PASS__";document.querySelector("form").submit();"s"'.Replace('__ROUTER_PASS__', $env:ROUTER_PASS))|Out-Null
  Start-Sleep -Seconds 5
}
Send-CDP -Method 'Page.navigate' -Params @{url='http://192.168.69.1/cgi-bin/luci/admin/services/migu/status'}|Out-Null
Start-Sleep -Seconds 12

Write-Host "=== 「公网开启」状态下的状态页检查 ==="
foreach ($kw in @('公网访问','公网访问已开启','令牌校验（23 位）','公网订阅地址','M3U（公网）','TXT（公网）','https://migu.example.test','<令牌>/m3u','端口映射','服务状态','TV-BOX 订阅地址')) {
  $hit = Eval-JS ('(function(){return document.body.innerText.indexOf(' + ("'{0}'" -f $kw) + ')>=0})()')
  $isOk = ($hit -eq 'True' -or $hit -eq 'true')
  $mark = if ($isOk) { 'OK ' } else { 'MISS' }
  Write-Host ("  [{0}] {1}" -f $mark, $kw)
}

Write-Host ""
Write-Host "=== 不应出现的内容 ==="
foreach ($kw in @('未设令牌','你的公网地址或域名','[object Object]')) {
  $hit = Eval-JS ('(function(){return document.body.innerText.indexOf(' + ("'{0}'" -f $kw) + ')>=0})()')
  $isHit = ($hit -eq 'True' -or $hit -eq 'true')
  $mark = if ($isHit) { '异常出现' } else { '正确未出现' }
  Write-Host ("  [{0}] {1}" -f $mark, $kw)
}

Write-Host ""
Write-Host "=== 抓公网 M3U 输入框的值 ==="
$v = Eval-JS @'
(function(){
  var ins = document.querySelectorAll('input[readonly]');
  var out = [];
  for (var i=0;i<ins.length;i++){
    if (ins[i].value.indexOf('/m3u')>=0 || ins[i].value.indexOf('/txt')>=0) out.push(ins[i].value);
  }
  return JSON.stringify(out);
})()
'@
Write-Host "  $v"

Write-Host ""
Write-Host "=== JS 错误 ==="
Write-Host "  $(Eval-JS 'JSON.stringify(window.__errs||[])')"

$shot = Send-CDP -Method 'Page.captureScreenshot' -Params @{format='png';fullPage=$true}
if ($shot -and $shot.result -and $shot.result.data) {
  [IO.File]::WriteAllBytes('D:\AI\_mt\migu-status-pubon.png',[Convert]::FromBase64String($shot.result.data))
  Write-Host "[截图] D:\AI\_mt\migu-status-pubon.png"
}
$ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure,'done',$ct).Wait(3000)|Out-Null
$proc | Stop-Process -Force
Write-Host "[完成]"
