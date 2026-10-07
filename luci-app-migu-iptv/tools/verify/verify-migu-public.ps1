# 验证 migu 设置页新增的「公网访问」区块：开关、自定义按钮、地址格式提示
$ErrorActionPreference = 'Stop'
$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
chcp 65001 > $null

# .NET 4.x 上该程序集可能不存在，属正常；WebSocket 类已在 System.dll 中可用。
try { Add-Type -AssemblyName System.Net.WebSockets } catch { }

$thorium = 'D:\浏览器\BIN\thorium.exe'
$prof    = 'D:\AI\_mt\thorium-prof-migu'
$port    = 9345

if (Test-Path $prof) { Remove-Item $prof -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Path $prof -Force | Out-Null

$proc = Start-Process -FilePath $thorium -PassThru -WindowStyle Hidden -ArgumentList @(
  '--headless=new', '--disable-gpu', '--no-sandbox', '--no-first-run',
  '--no-default-browser-check', '--disable-extensions', '--mute-audio',
  "--remote-debugging-port=$port", "--user-data-dir=$prof", 'about:blank'
)
Write-Host "[1] 浏览器 PID=$($proc.Id)，等待端口…"

$targets = $null
for ($i = 0; $i -lt 40; $i++) {
  Start-Sleep -Milliseconds 500
  try {
    $targets = Invoke-RestMethod -Uri "http://127.0.0.1:$port/json/list" -TimeoutSec 3
    if ($targets) { break }
  } catch { }
}
if (-not $targets) { Write-Host "[FAIL] 端口未就绪"; $proc | Stop-Process -Force; exit 1 }

$page = $targets | Where-Object { $_.type -eq 'page' } | Select-Object -First 1
$ws = New-Object System.Net.WebSockets.ClientWebSocket
$ct = [Threading.CancellationToken]::None
$ws.ConnectAsync([Uri]$page.webSocketDebuggerUrl, $ct).Wait(10000) | Out-Null
Write-Host "[2] CDP 已连接"

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
  $r = Send-CDP -Method 'Runtime.evaluate' -Params @{
    expression = $Expr; returnByValue = $true; awaitPromise = $true
  }
  if ($r -and $r.result -and $r.result.result) { return $r.result.result.value }
  return $null
}

Send-CDP -Method 'Page.enable' | Out-Null
Send-CDP -Method 'Runtime.enable' | Out-Null

# 捕获页面 JS 错误
Send-CDP -Method 'Runtime.evaluate' -Params @{
  expression = 'window.__errs=[];window.addEventListener("error",e=>window.__errs.push(e.message));"ok"'
} | Out-Null

Write-Host "[3] 登录…"
Send-CDP -Method 'Page.navigate' -Params @{ url = 'http://192.168.69.1/cgi-bin/luci/' } | Out-Null
Start-Sleep -Seconds 4

$hasForm = Eval-JS 'document.querySelector("input[name=luci_username]") ? "yes" : "no"'
if ($hasForm -eq 'yes') {
  Eval-JS ('document.querySelector("input[name=luci_username]").value="root"; document.querySelector("input[name=luci_password]").value="__ROUTER_PASS__"; document.querySelector("form").submit(); "submitted"'.Replace('__ROUTER_PASS__', $env:ROUTER_PASS)) | Out-Null
  Start-Sleep -Seconds 5
}
Write-Host "    已登录，URL: $(Eval-JS 'window.location.href')"

Write-Host "[4] 打开 migu 设置页…"
Send-CDP -Method 'Page.navigate' -Params @{ url = 'http://192.168.69.1/cgi-bin/luci/admin/services/migu/config' } | Out-Null
Start-Sleep -Seconds 10

$dom = Eval-JS 'document.documentElement.outerHTML'
$dom | Set-Content -Path 'D:\AI\_mt\dom-migu-config2.html' -Encoding UTF8
Write-Host "    DOM 长度: $($dom.Length)"

Write-Host ""
Write-Host "=== 新增「公网访问」区块检查 ==="
$checks = @(
  '公网访问', '允许公网访问', '对外访问地址', '访问令牌',
  '生成令牌', '地址格式说明', '令牌路径前缀', '查询参数',
  '监听地址', '端口映射', '/m3u', '/txt', '/health',
  '0.0.0.0', '127.0.0.1'
)
foreach ($kw in $checks) {
  $n = ([regex]::Matches($dom, [regex]::Escape($kw))).Count
  $mark = if ($n -gt 0) { 'OK ' } else { '-- ' }
  Write-Host ("  {0} {1,-18} {2} 次" -f $mark, $kw, $n)
}

Write-Host ""
Write-Host "=== 表单控件实际渲染情况（用 DOM 查询，不看源码）==="
$js = @'
(function(){
  var out = {};
  function w(section, opt){
    var wid = 'widget.cbid.migu.' + section + '.' + opt;
    return document.querySelector('[data-widget-id="'+wid+'"]') || document.getElementById(wid);
  }
  var pa = w('main','publicAccess');
  out.chk_publicAccess = !!pa;
  out.val_publicAccess = pa ? (pa.type==='checkbox' ? pa.checked : pa.value) : null;
  out.chk_publicBaseUrl = !!w('main','publicBaseUrl');
  out.chk_publicToken   = !!w('main','publicToken');

  var btns = Array.prototype.slice.call(document.querySelectorAll('button, .cbi-button, input[type=button], input[type=submit], .btn'));
  var texts = btns.map(function(b){ return (b.value || b.textContent || '').trim(); });
  out.btnGenToken  = texts.some(function(t){ return t.indexOf('随机生成') >= 0; });
  out.btnSaveApply = texts.some(function(t){ return /保存.*应用/.test(t); });

  // 地址格式说明是否真的解析成 DOM 元素（关键：不是 innerhtml 属性）
  out.renderedTables = document.querySelectorAll('table.table').length;
  out.renderedCode   = document.querySelectorAll('code').length;
  out.renderedLi     = document.querySelectorAll('ul li').length;
  out.fakeInnerHtmlAttrs = document.querySelectorAll('[innerhtml]').length;

  var m = document.body.innerHTML.match(/http:\/\/[^"'<> ]*\/m3u/g) || [];
  out.m3uSamples = m.slice(0,5);

  return JSON.stringify(out);
})()
'@
$res = Eval-JS $js
Write-Host "  $res"

Write-Host ""
Write-Host "=== 页面 JS 报错 ==="
$errs = Eval-JS 'JSON.stringify(window.__errs||[])'
Write-Host "  $errs"

Write-Host ""
Write-Host "=== 全页关键字总览（确认没渲染成空白）==="
foreach ($kw in @('基本设置','咪咕账号','公网访问','启用服务','保存')) {
  $n = ([regex]::Matches($dom, [regex]::Escape($kw))).Count
  Write-Host ("  {0,-12} {1} 次" -f $kw, $n)
}

# 截图留证
$shot = Send-CDP -Method 'Page.captureScreenshot' -Params @{ format = 'png'; fullPage = $true }
if ($shot -and $shot.result -and $shot.result.data) {
  [IO.File]::WriteAllBytes('D:\AI\_mt\migu-config2.png', [Convert]::FromBase64String($shot.result.data))
  Write-Host ""
  Write-Host "[5] 截图已保存: D:\AI\_mt\migu-config2.png"
}

$ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, 'done', $ct).Wait(3000) | Out-Null
$proc | Stop-Process -Force
Write-Host "[完成]"
