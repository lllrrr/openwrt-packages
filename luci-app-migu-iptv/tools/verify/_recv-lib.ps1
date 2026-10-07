# 从路由器拉取文件的加固版：tail -c +N | head -c M | openssl base64 -A 分块取回 → 本地解码 → md5 校验
#
# 依赖：先 dot-source _upload-lib.ps1（提供 Remote-Value / $SSH / $SSH_TARGET / $KH）
#
# 两个坑（保留注释，避免重犯）：
#   1) 本机与路由器 busybox 都没有 base64 命令（实测 command -v base64 = MISSING），
#      但两边都有 openssl，故统一走 `openssl base64 -A`（-A = 不换行，省得再去空白）。
#   2) 分块取字节必须用 `tail -c +N`（1-based，加号不能省），不能用 `dd bs=1 skip=N`——
#      dd 逐字节读 24KB 在 aarch64 软路由上要好几秒，tail 是瞬间。

$script:RecvChunk = 24000

function Receive-RemoteFile {
  param([string]$Remote, [string]$Local)

  $lenRaw = Remote-Value "wc -c < '$Remote'"
  $len = 0
  [void][int]::TryParse(($lenRaw -replace '\D', ''), [ref]$len)
  if ($len -le 0) { Write-Host ("  [FAIL] 取长度失败: {0} -> '{1}'" -f $Remote, $lenRaw); return $false }
  $md5 = (Remote-Value "md5sum '$Remote' | cut -d' ' -f1").Trim()

  $sb = New-Object System.Text.StringBuilder
  for ($offset = 0; $offset -lt $len; $offset += $script:RecvChunk) {
    $start = $offset + 1
    $part = (Remote-Value "tail -c +$start '$Remote' | head -c $script:RecvChunk | openssl base64 -A").Trim()
    if (-not $part) { Write-Host ("  [FAIL] 第 {0} 块为空" -f [int]($offset / $script:RecvChunk)); return $false }
    [void]$sb.Append($part)
  }

  $bytes = [Convert]::FromBase64String($sb.ToString())
  $dir = Split-Path -Parent $Local
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { [void][IO.Directory]::CreateDirectory($dir) }
  [IO.File]::WriteAllBytes($Local, $bytes)

  $gotMd5 = (Get-FileHash -LiteralPath $Local -Algorithm MD5).Hash.ToLower()
  if ($gotMd5 -ne $md5.ToLower() -or $bytes.Length -ne $len) {
    Write-Host ("  [FAIL] {0}: 本地 {1}B/{2} vs 远端 {3}B/{4}" -f $Remote, $bytes.Length, $gotMd5, $len, $md5)
    return $false
  }
  Write-Host ("  [OK  ] {0} -> {1}  ({2} 字节, md5 {3})" -f $Remote, $Local, $len, $gotMd5)
  return $true
}
