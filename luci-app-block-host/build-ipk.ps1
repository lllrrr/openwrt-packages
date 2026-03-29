# Build IPK package for Windows
$ErrorActionPreference = "Stop"

$PKG_NAME = "luci-app-block-host"
$PKG_VERSION = "1.0.0"
$PKG_RELEASE = "1"
$PKG_ARCH = "all"
$PKG_FULLNAME = "${PKG_NAME}_${PKG_VERSION}-${PKG_RELEASE}_${PKG_ARCH}"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$BuildDir = Join-Path $ScriptDir "build"
$IpkgDir = Join-Path $ScriptDir "ipkg"

Write-Host "Building ${PKG_FULLNAME}..."

if (Test-Path $BuildDir) {
    Remove-Item -Path $BuildDir -Recurse -Force
}
New-Item -ItemType Directory -Path $BuildDir | Out-Null

Push-Location $BuildDir

"2.0" | Out-File -FilePath "debian-binary" -Encoding ASCII

New-Item -ItemType Directory -Path "control" | Out-Null
Copy-Item -Path (Join-Path $IpkgDir "control") -Destination "control/"

# Create control.tar.gz
tar -czf "control.tar.gz" -C "control" .

New-Item -ItemType Directory -Path "data" | Out-Null

# Copy root files
$RootDir = Join-Path $ScriptDir "root"
if (Test-Path $RootDir) {
    Copy-Item -Path (Join-Path $RootDir "*") -Destination "data/" -Recurse
}

# Set executable permissions (for documentation purposes)
$BindScript = Join-Path "data" "usr/bin/bind_and_block.sh"
if (Test-Path $BindScript) {
    Write-Host "Note: In real OpenWrt, this script would have executable permissions"
}

$InitScript = Join-Path "data" "etc/init.d/block_host"
if (Test-Path $InitScript) {
    Write-Host "Note: In real OpenWrt, this script would have executable permissions"
}

# Create data.tar.gz
tar -czf "data.tar.gz" -C "data" .

# Create final IPK
tar -czf (Join-Path $ScriptDir "${PKG_FULLNAME}.ipk") debian-binary control.tar.gz data.tar.gz

Pop-Location

Remove-Item -Path $BuildDir -Recurse -Force

Write-Host "Successfully created ${PKG_FULLNAME}.ipk"
Get-ChildItem (Join-Path $ScriptDir "${PKG_FULLNAME}.ipk") | Select-Object Name, Length