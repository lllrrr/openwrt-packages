param(
  [string]$Root = 'D:\AI\luci-app-migu-iptv\files'
)
$ErrorActionPreference = 'Stop'
chcp 65001 > $null
$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8

$env:SSH_ASKPASS = 'D:\AI\_mt\askpass.cmd'
$env:SSH_ASKPASS_REQUIRE = 'force'
$env:DISPLAY = 'localhost:0'
$ssh = 'D:\AI\_tools\MinGit\usr\bin\ssh.exe'
$kh  = 'D:\AI\_mt\known_hosts'
$a0  = @('-o','StrictHostKeyChecking=accept-new','-o',"UserKnownHostsFile=$kh",
         '-o','ConnectTimeout=40','-o','ServerAliveInterval=15')
$R = 'root@192.168.69.1'

function Push-File {
  param([string]$LocalRel, [string]$Remote)
  $lp = Join-Path $Root $LocalRel
  if (-not (Test-Path $lp)) { Write-Host "  [MISS] $LocalRel"; return $false }
  $want = (Get-FileHash $lp -Algorithm MD5).Hash.ToLower()
  $b64  = [Convert]::ToBase64String([IO.File]::ReadAllBytes($lp))
  $dir  = $Remote.Substring(0, $Remote.LastIndexOf('/'))

  for ($attempt = 1; $attempt -le 3; $attempt++) {
    & $ssh @a0 $R "rm -rf /tmp/up; mkdir -p /tmp/up" 2>&1 | Out-Null
    $size  = 1400
    $parts = [Math]::Ceiling($b64.Length / $size)
    $bad = $false
    for ($k = 0; $k -lt $parts; $k++) {
      $chunk = $b64.Substring($k * $size, [Math]::Min($size, $b64.Length - $k * $size))
      $fn = "/tmp/up/{0:D4}" -f $k
      $ok = $false
      for ($t = 1; $t -le 2 -and -not $ok; $t++) {
        & $ssh @a0 $R "printf '%s' '$chunk' > $fn" 2>&1 | Out-Null
        $got = ((& $ssh @a0 $R "wc -c < $fn" 2>&1) -join '').Trim()
        if ($got -eq "$($chunk.Length)") { $ok = $true }
      }
      if (-not $ok) { $bad = $true; break }
    }
    if ($bad) { continue }
    & $ssh @a0 $R "mkdir -p '$dir'; cat /tmp/up/* | openssl base64 -d -A > '$Remote'; rm -rf /tmp/up" 2>&1 | Out-Null
    $got = ((& $ssh @a0 $R "md5sum '$Remote' | cut -d' ' -f1" 2>&1) -join '').Trim()
    if ($got -eq $want) { Write-Host "  [OK  ] $Remote"; return $true }
    Write-Host "  [retry] $Remote md5 不符，重试"
  }
  Write-Host "  [FAIL] $Remote"
  return $false
}

Write-Host "=== 上传插件文件 ==="
Push-File 'usr\share\ucode\migu.uc'                              '/usr/share/ucode/migu.uc'
Push-File 'usr\share\rpcd\ucode\migu'                            '/usr/share/rpcd/ucode/migu'
Push-File 'usr\share\luci\menu.d\luci-app-migu-iptv.json'        '/usr/share/luci/menu.d/luci-app-migu-iptv.json'
Push-File 'usr\share\rpcd\acl.d\luci-app-migu-iptv.json'         '/usr/share/rpcd/acl.d/luci-app-migu-iptv.json'
Push-File 'www\luci-static\resources\view\migu\config.js'        '/www/luci-static/resources/view/migu/config.js'
Push-File 'www\luci-static\resources\view\migu\status.js'        '/www/luci-static/resources/view/migu/status.js'

Write-Host ""
Write-Host "=== 重启服务 + rpcd + 清缓存 ==="
$t = @'
ucode -c /usr/share/ucode/migu.uc && echo "  migu.uc     语法 OK"
ucode -c /usr/share/rpcd/ucode/migu  && echo "  rpcd/migu   语法 OK"
/etc/init.d/migu restart 2>&1 | sed 's/^/  /'
/etc/init.d/rpcd restart 2>&1 | sed 's/^/  /'
rm -rf /tmp/luci-indexcache /tmp/luci-modulecache 2>/dev/null
sleep 3
echo ""
echo "  服务状态: $(/etc/init.d/migu status 2>&1)"
echo "  ubus 对象: $(ubus list 2>/dev/null | grep -c '^migu$')"
echo ""
echo "  --- 后端接口自测 ---"
echo -n "  /health : "
curl -s -m 10 http://127.0.0.1:8788/health
echo ""
echo -n "  /        : "
curl -s -m 5 -o /dev/null -w "%{http_code} -> %{redirect_url}" http://127.0.0.1:8788/
echo ""
echo -n "  /admin   : "
curl -s -m 5 -o /dev/null -w "%{http_code} -> %{redirect_url}" http://127.0.0.1:8788/admin
echo ""
echo -n "  /m3u 前3行:" 
curl -s -m 30 http://127.0.0.1:8788/m3u | head -3 | sed 's/^/\n    /'
'@
$b64o = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($t))
& $ssh @a0 $R "echo $b64o | openssl base64 -d -A > /tmp/rs.sh; sh /tmp/rs.sh" 2>&1 | ForEach-Object { Write-Host $_ }
