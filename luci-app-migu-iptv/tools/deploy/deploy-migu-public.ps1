$ErrorActionPreference = 'Continue'
$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
chcp 65001 > $null

. 'D:\AI\_mt\_upload-lib.ps1'

$SRC = 'D:\AI\luci-app-migu-iptv\files'
$map = @(
  @{ L = 'usr\share\ucode\migu.uc';                                  R = '/usr/share/ucode/migu.uc' },
  @{ L = 'usr\share\rpcd\ucode\migu';                                R = '/usr/share/rpcd/ucode/migu' },
  @{ L = 'www\luci-static\resources\view\migu\config.js';            R = '/www/luci-static/resources/view/migu/config.js' }
)

Write-Host '=== 上传 migu 插件文件 ==='
$allOk = $true
foreach ($f in $map) {
  $ok = Send-FileHarden (Join-Path $SRC $f.L) $f.R
  if (-not $ok) { $allOk = $false }
}
Write-Host ''
if (-not $allOk) { Write-Host '  [!] 上传失败，停止'; exit 1 }

Write-Host '=== 语法检查 + 重启 rpcd ==='
$t = @'
echo "--- ucode 语法 ---"
ucode -c /usr/share/ucode/migu.uc && echo "  migu.uc OK"
ucode -c /usr/share/rpcd/ucode/migu && echo "  rpcd-migu OK"

echo ""
echo "--- 当前 UCI 公网相关配置 ---"
for k in publicAccess publicToken publicBaseUrl; do
  printf "  %-16s = [%s]\n" "$k" "$(uci -q get migu.main.$k)"
done

echo ""
echo "--- 重启 rpcd ---"
/etc/init.d/rpcd restart
sleep 2
echo "  rpcd: $(/etc/init.d/rpcd status 2>&1 | head -1)"

echo ""
echo "--- ubus: migu 方法列表 ---"
ubus -v list migu 2>/dev/null | sed 's/^/  /'
'@
$b64o = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($t))
Invoke-Remote "echo $b64o | openssl base64 -d -A > /tmp/d.sh; sh /tmp/d.sh 2>&1" | ForEach-Object { Write-Host $_ }
