# 终验：按钮清单 + 点击「随机生成令牌」实测填值 + 关键文案确认
$ErrorActionPreference = 'Stop'
$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
chcp 65001 > $null
try { Add-Type -AssemblyName System.Net.WebSockets } catch { }

$thorium = 'D:\浏览器\BIN\thorium.exe'
$prof    = 'D:\AI\_mt\thorium-prof-migu3'
$port    = 9347
if (Test-Path $prof) { Remove-Item $prof -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Path $prof -Force | Out-Null

$proc = Start-Process -FilePath $thorium -PassThru -WindowStyle Hidden -ArgumentList @(
  '--headless=new', '--disable-gpu', '--no-sandbox', '--no-first-run',
  '--no-default-browser-check', '--disable-extensions', '--mute-audio',
  "--remote-debugging-port=$port", "--user-data-dir=$prof", 'about:blank'
)
$targets = $null
for ($i = 0; $i -lt 40; $i++) {
  Start-Sleep -Milliseconds 500
  try { $targets = Invoke-RestMethod -Uri "http://127.0.0.1:$port/json/list" -TimeoutSec 3; if ($targets) { break } } catch { }
}
if (-not $targets) { Write-Host "[FAIL] 端口未就绪"; $proc | Stop-Process -Force; exit 1 }
$page = $targets | Where-Object { $_.type -eq 'page' } | Select-Object -First 1
$ws = New-Object System.Net.WebSockets.ClientWebSocket
$ct = [Threading.CancellationToken]::None
$ws.ConnectAsync([Uri]$page.webSocketDebuggerUrl, $ct).Wait(10000) | Out-Null

$script:id = 0
function Send-CDP {
  param([string]$Method, [hashtable]$Params = @{})
  $script:id++
  $mid = $script:id
  $payload = @{ id = $mid; method = $Method; params = $Params } | ConvertTo-Json -Depth 20 -Compress
  $bytes = [Text.Encoding]::UTF8.GetBytes($payload)
  $seg = New-Object ArraySegment[byte] -ArgumentList @(,$bytes)
  $ws.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $ct).Wait(10000) | Out-Null
  $deadline = (Get-Date).AddSeconds(40)
  while ((Get-Date) -lt $deadline) {
    $buf = New-Object byte[] 131072
    $sb = New-Object System.Text.StringBuilder
    do {
      $rseg = New-Object ArraySegment[byte] -ArgumentList @(,$buf)
      $res = $ws.ReceiveAsync($rseg, $ct); $res.Wait(10000) | Out-Null
      [void]$sb.Append([Text.Encoding]::UTF8.GetString($buf, 0, $res.Result.Count))
    } while (-not $res.Result.EndOfMessage)
    $msg = $sb.ToString()
    try { $obj = $msg | ConvertFrom-Json } catch { continue }
    if ($obj.id -eq $mid) { return $obj }
  }
  return $null
}
function Eval-JS {
  param([string]$Expr)
  $r = Send-CDP -Method 'Runtime.evaluate' -Params @{ expression = $Expr; returnByValue = $true; awaitPromise = $true }
  if ($r -and $r.result -and $r.result.result) { return $r.result.result.value }
  return $null
}
Send-CDP -Method 'Page.enable' | Out-Null
Send-CDP -Method 'Runtime.enable' | Out-Null
Send-CDP -Method 'Runtime.evaluate' -Params @{ expression = 'window.__errs=[];window.addEventListener("error",e=>window.__errs.push(e.message));"ok"' } | Out-Null

# 登录
Send-CDP -Method 'Page.navigate' -Params @{ url = 'http://192.168.69.1/cgi-bin/luci/' } | Out-Null
Start-Sleep -Seconds 4
$hasForm = Eval-JS 'document.querySelector("input[name=luci_username]") ? "yes" : "no"'
if ($hasForm -eq 'yes') {
  Eval-JS ('document.querySelector("input[name=luci_username]").value="root"; document.querySelector("input[name=luci_password]").value="__ROUTER_PASS__"; document.querySelector("form").submit(); "s"'.Replace('__ROUTER_PASS__', $env:ROUTER_PASS)) | Out-Null
  Start-Sleep -Seconds 5
}

# 打开设置页
Send-CDP -Method 'Page.navigate' -Params @{ url = 'http://192.168.69.1/cgi-bin/luci/admin/services/migu/config' } | Out-Null
Start-Sleep -Seconds 10

Write-Host "=== 1) 页面上所有按钮的实际文本 ==="
$btnList = Eval-JS '(function(){var b=document.querySelectorAll("button, input[type=button], input[type=submit]");return JSON.stringify(Array.prototype.slice.call(b).map(function(x){return (x.value||x.textContent||"").trim().replace(/\s+/g," ")}))})()'
Write-Host "  $btnList"

Write-Host ""
Write-Host "=== 2) 关键文案确认（路径前缀 / 推荐）==="
foreach ($kw in @('路径前缀','兼容性最好','你的公网IP','端口映射','随机生成一个 32 位令牌')) {
  $hit = Eval-JS ('(function(){return document.body.innerText.indexOf(' + ("'{0}'" -f $kw) + ')>=0})()')
  $mark = if ($hit -eq 'True' -or $hit -eq 'true') { 'OK' } else { 'MISS' }
  Write-Host ("  [{0}] {1}" -f $mark, $kw)
}

Write-Host ""
Write-Host "=== 3) 点击「随机生成令牌」实测 ==="
$before = Eval-JS '(function(){var e=document.querySelector("[data-widget-id=\"widget.cbid.migu.main.publicToken\"]");return e?e.value:"NO-ELEM"})()'
Write-Host "  点击前 token 框值: [$before]"
$clicked = Eval-JS @'
(function(){
  var btns = document.querySelectorAll('button, input[type=button], input[type=submit]');
  for (var i=0;i<btns.length;i++){
    var t=(btns[i].value||btns[i].textContent||'').trim();
    if (t.indexOf('随机生成')>=0){ btns[i].click(); return 'CLICKED:'+t; }
  }
  return 'NOT-FOUND';
})()
'@
Write-Host "  点击结果: $clicked"
Start-Sleep -Seconds 3
$after = Eval-JS '(function(){var e=document.querySelector("[data-widget-id=\"widget.cbid.migu.main.publicToken\"]");return e?e.value:"NO-ELEM"})()'
Write-Host "  点击后 token 框值: [$after]"
$tokOk = ($after -match '^[0-9a-f]{32}$' -or ($after.Length -ge 16 -and $after -ne $before))
Write-Host ("  令牌是否生成并填入: {0}" -f $(if($tokOk){'YES ✓'}else{'NO ✗'}))

Write-Host ""
Write-Host "=== 4) 通知气泡是否弹出（前端交互成功提示）==="
$notif = Eval-JS '(function(){var n=document.querySelector(".notification-message, .cbi-notification, [class*=notification]");return n?n.innerText.slice(0,80):"无"})()'
Write-Host "  $notif"

Write-Host ""
Write-Host "=== 5) 页面 JS 错误 ==="
Write-Host "  $(Eval-JS 'JSON.stringify(window.__errs||[])')"

# 重要：点过按钮后【不要保存】，避免把测试令牌写进配置
Write-Host ""
Write-Host "=== 6) 确认未误保存（读取路由器 UCI 实值）==="
$uciNow = Invoke-Remote "uci -q get migu.main.publicToken; echo '|'; uci -q get migu.main.publicAccess"
Write-Host "  路由器 publicToken=[$uciNow] （应为空，测试未落盘）"

$shot = Send-CDP -Method 'Page.captureScreenshot' -Params @{ format = 'png'; fullPage = $true }
if ($shot -and $shot.result -and $shot.result.data) {
  [IO.File]::WriteAllBytes('D:\AI\_mt\migu-config-final.png', [Convert]::FromBase64String($shot.result.data))
  Write-Host ""
  Write-Host "[截图] D:\AI\_mt\migu-config-final.png"
}
$ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, 'done', $ct).Wait(3000) | Out-Null
$proc | Stop-Process -Force
Write-Host "[完成]"
