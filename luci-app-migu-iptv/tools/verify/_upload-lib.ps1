# 加固版上传：每块写独立文件 → 按序 cat → 校验长度与 md5 → 失败自动重试
#
# 两个已踩过的坑（务必保留注释，避免重犯）：
#   1) PowerShell 变量名大小写不敏感：$R 与 $r 是同一个变量。
#      若用 $r 接收命令输出，会把目标主机名覆盖成命令结果，
#      后续 ssh 报 "Could not resolve hostname /root" /
#      "hostname contains invalid characters"。故主机名变量命名为 $SSH_TARGET。
#   2) .ps1 必须带 UTF-8 BOM，否则 PS 5.1 按 GBK 解码中文，导致语法错误。

$ErrorActionPreference = 'Continue'
$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
chcp 65001 > $null

$env:SSH_ASKPASS = 'D:\AI\_mt\askpass.cmd'
$env:SSH_ASKPASS_REQUIRE = 'force'
$env:DISPLAY = 'localhost:0'
$SSH = 'D:\AI\_tools\MinGit\usr\bin\ssh.exe'
$KH  = 'D:\AI\_mt\known_hosts'
$SSH_TARGET = 'root@192.168.69.1'

function Invoke-Remote {
  param([string]$Cmd)
  $out = & $SSH -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$KH" `
    -o ConnectTimeout=40 -o ServerAliveInterval=15 $SSH_TARGET $Cmd 2>$null
  return (($out | Out-String) -replace "`r", '').Trim()
}

# 用哨兵包裹返回值，避免 stderr 噪声混入后误判
function Remote-Value {
  param([string]$Cmd)
  $out = Invoke-Remote "$Cmd; echo __END__"
  $s = [string]$out
  $i = $s.IndexOf('__END__')
  if ($i -lt 0) { return $s.Trim() }
  return $s.Substring(0, $i).Trim()
}

function Send-FileHarden {
  param([string]$Local, [string]$Remote)

  $bytes = [IO.File]::ReadAllBytes($Local)
  $localMd5 = (Get-FileHash $Local -Algorithm MD5).Hash.ToLower()
  $localLen = $bytes.Length
  $b64 = [Convert]::ToBase64String($bytes)
  # 分块 4000：单条 printf 命令实测 ≤6000 b64 字符安全；
  # 分块越大 ssh 会话越少（46KB 文件从 52 次降到 ~16 次），抗链路抖动
  $chunk = 4000
  $n = [Math]::Ceiling($b64.Length / $chunk)

  for ($attempt = 1; $attempt -le 4; $attempt++) {
    Invoke-Remote "rm -rf /tmp/upx; mkdir -p /tmp/upx" | Out-Null

    # 逐块上传：每块独立文件，写完立刻回读长度确认
    $bad = -1
    $gotBad = ''
    for ($i = 0; $i -lt $n; $i++) {
      $s = $i * $chunk
      $len = [Math]::Min($chunk, $b64.Length - $s)
      $part = $b64.Substring($s, $len)
      $idx = '{0:D5}' -f $i
      $got = Remote-Value "printf '%s' '$part' > /tmp/upx/p$idx; wc -c < /tmp/upx/p$idx"
      if ("$got" -ne "$len") { $bad = $i; $gotBad = "$got"; break }
    }
    if ($bad -ge 0) {
      Write-Host ("       第 {0} 次尝试：第 {1} 块长度不符（期望 {2} 实得 {3}）" -f `
        $attempt, $bad, ([Math]::Min($chunk, $b64.Length - $bad * $chunk)), $gotBad)
      continue
    }

    # 按序拼接并校验
    $v = Remote-Value "cd /tmp/upx; cat p* > all.b64; wc -c < all.b64; openssl base64 -d -A -in all.b64 -out out.bin; wc -c < out.bin; md5sum out.bin | cut -d' ' -f1"
    $lines = ([string]$v) -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    $b64Len = if ($lines.Count -ge 1) { $lines[0] } else { '' }
    $gotLen = if ($lines.Count -ge 2) { $lines[1] } else { '' }
    $gotMd5 = if ($lines.Count -ge 3) { $lines[2] } else { '' }

    if ($gotMd5 -eq $localMd5 -and "$gotLen" -eq "$localLen") {
      $cp = Remote-Value "cp /tmp/upx/out.bin '$Remote' && rm -rf /tmp/upx && echo COPIED"
      if ($cp -notlike '*COPIED*') {
        Write-Host ("       第 {0} 次尝试：写入 {1} 失败" -f $attempt, $Remote)
        continue
      }
      Write-Host ("  [OK  ] {0}  ({1} 字节, {2} 块)" -f $Remote, $localLen, $n)
      return $true
    }
    Write-Host ("       第 {0} 次尝试：b64 {1}/{2} 解码后 {3}/{4} md5 {5}" -f `
      $attempt, $b64Len, $b64.Length, $gotLen, $localLen, $gotMd5)
  }

  Write-Host ("  [FAIL] {0}  （期望 {1} 字节 / {2}）" -f $Remote, $localLen, $localMd5)
  return $false
}
