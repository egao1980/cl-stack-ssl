# Build shared OpenSSL (libssl + libcrypto) into lib/windows-amd64/ for cl+ssl.
# Requires: Visual Studio Build Tools (nmake/cl), Perl (Strawberry), curl.
# Usage: .\scripts\build-openssl.ps1
# Env: OPENSSL_VERSION (default 3.4.1), DEST_DIR (optional)
$ErrorActionPreference = "Stop"

$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$OpenSslVersion = if ($env:OPENSSL_VERSION) { $env:OPENSSL_VERSION } else { "3.4.1" }
$Os = "windows"
$Arch = "amd64"
$Out = if ($env:DEST_DIR) { $env:DEST_DIR } else { Join-Path $Root "lib\$Os-$Arch" }
$Build = Join-Path $Root "build\openssl-$OpenSslVersion-$Os-$Arch"
$SrcTgz = Join-Path $Root "build\openssl-$OpenSslVersion.tar.gz"
$SrcUrl = "https://github.com/openssl/openssl/releases/download/openssl-$OpenSslVersion/openssl-$OpenSslVersion.tar.gz"

New-Item -ItemType Directory -Force -Path (Join-Path $Root "build") | Out-Null
New-Item -ItemType Directory -Force -Path $Out | Out-Null

if (-not (Test-Path $SrcTgz)) {
  Write-Host "==> download $SrcUrl"
  Invoke-WebRequest -Uri $SrcUrl -OutFile $SrcTgz
}

if (Test-Path $Build) { Remove-Item -Recurse -Force $Build }
New-Item -ItemType Directory -Force -Path $Build | Out-Null
tar -xzf $SrcTgz -C $Build --strip-components=1

# Prefer VS developer environment if available
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (Test-Path $vswhere) {
  $vsDevCmd = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
    -property installationPath
  if ($vsDevCmd) {
    $devCmd = Join-Path $vsDevCmd "Common7\Tools\VsDevCmd.bat"
    if (Test-Path $devCmd) {
      Write-Host "==> enter VS x64 env via VsDevCmd.bat"
      cmd /c "`"$devCmd`" -arch=amd64 -host_arch=amd64 && set" | ForEach-Object {
        if ($_ -match '^(.*?)=(.*)$') { Set-Item -Path "env:$($matches[1])" -Value $matches[2] }
      }
    }
  }
}

if (-not (Get-Command perl -ErrorAction SilentlyContinue)) {
  throw "perl not found (install Strawberry Perl)"
}
if (-not (Get-Command nmake -ErrorAction SilentlyContinue)) {
  throw "nmake not found (install VS Build Tools with C++ tools)"
}

$Prefix = Join-Path $Build "prefix"
Write-Host "==> configure OpenSSL $OpenSslVersion -> $Out"
Push-Location $Build
try {
  perl Configure VC-WIN64A shared no-tests --prefix="$Prefix" --libdir=lib
  nmake
  nmake install_sw
} finally {
  Pop-Location
}

Write-Host "==> stage DLLs into $Out"
if (Test-Path $Out) { Remove-Item -Recurse -Force $Out }
New-Item -ItemType Directory -Force -Path $Out | Out-Null

$binDir = Join-Path $Prefix "bin"
$candidates = @(
  "libssl-3-x64.dll",
  "libcrypto-3-x64.dll",
  "libssl-3.dll",
  "libcrypto-3.dll"
)
$copied = @()
foreach ($name in $candidates) {
  $src = Join-Path $binDir $name
  if (Test-Path $src) {
    Copy-Item $src (Join-Path $Out $name)
    $copied += $name
  }
}

# Also copy from lib/ if Configure put them there
Get-ChildItem -Path (Join-Path $Prefix "lib") -Filter "*.dll" -ErrorAction SilentlyContinue | ForEach-Object {
  Copy-Item $_.FullName (Join-Path $Out $_.Name) -Force
  $copied += $_.Name
}

if (-not ($copied -match "libssl")) { throw "libssl DLL not found under $Prefix" }
if (-not ($copied -match "libcrypto")) { throw "libcrypto DLL not found under $Prefix" }

# cl+ssl looks for libssl-3-x64.dll / libcrypto-3-x64.dll on win x64
if ((Test-Path (Join-Path $Out "libssl-3.dll")) -and -not (Test-Path (Join-Path $Out "libssl-3-x64.dll"))) {
  Copy-Item (Join-Path $Out "libssl-3.dll") (Join-Path $Out "libssl-3-x64.dll")
}
if ((Test-Path (Join-Path $Out "libcrypto-3.dll")) -and -not (Test-Path (Join-Path $Out "libcrypto-3-x64.dll"))) {
  Copy-Item (Join-Path $Out "libcrypto-3.dll") (Join-Path $Out "libcrypto-3-x64.dll")
}

Get-ChildItem $Out | Format-Table Name, Length
Write-Host "OK: OpenSSL $OpenSslVersion -> $Os/$Arch"
