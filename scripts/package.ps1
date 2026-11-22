#requires -version 5.1
param(
    [string]$BinaryPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'target\x86_64-pc-windows-msvc\release\withen-mtu-guard.exe'),
    [switch]$Overwrite
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path $PSScriptRoot -Parent
& (Join-Path $PSScriptRoot 'verify-build.ps1') -BinaryPath $BinaryPath
$binary = (Resolve-Path -LiteralPath $BinaryPath).Path
$version = [Diagnostics.FileVersionInfo]::GetVersionInfo($binary).ProductVersion
$dist = Join-Path $root 'dist'
New-Item -ItemType Directory -Path $dist -Force | Out-Null
$zipName = "MTU-Guard-$version-win-x64.zip"
$zip = Join-Path $dist $zipName
if ((Test-Path -LiteralPath $zip) -and -not $Overwrite) { throw 'Package already exists. Assign a new release version or use -Overwrite for a local candidate.' }
$stage = Join-Path $dist ('stage-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $stage 'scripts') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $stage 'docs') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $stage 'tests') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $stage 'tools') -Force | Out-Null
foreach ($name in @('manual-mtu.ps1', 'manual-common.ps1')) {
    Copy-Item -LiteralPath (Join-Path $root "tools\$name") -Destination (Join-Path $stage 'tools')
}
Copy-Item -LiteralPath $binary -Destination $stage
Copy-Item -LiteralPath (Join-Path ([IO.Path]::GetDirectoryName($binary)) 'withen_mtu_guard.pdb') -Destination $stage
foreach ($name in @('install.cmd', 'uninstall.cmd', 'status.cmd', 'manual-mtu.cmd', 'manual-check.cmd', 'README.md', 'README_USER_RU.txt', 'README_MANUAL_RU.txt', 'LICENSE', 'NOTICE', 'CHANGELOG.md', 'CONTRIBUTING.md', 'VERSION')) {
    Copy-Item -LiteralPath (Join-Path $root $name) -Destination $stage
}
foreach ($name in @('install.ps1', 'uninstall.ps1', 'service-common.ps1', 'pe-imports.ps1', 'collect-evidence.ps1', 'status-parser.ps1')) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $stage 'scripts')
}
foreach ($name in @('clean-runtime.ps1', 'windows-integration.ps1')) {
    Copy-Item -LiteralPath (Join-Path $root "tests\$name") -Destination (Join-Path $stage 'tests')
}
foreach ($file in (Get-ChildItem -LiteralPath (Join-Path $root 'docs') -Filter '*.md' -Recurse -File)) {
    $relative = $file.FullName.Substring((Join-Path $root 'docs').Length + 1)
    $destination = Join-Path (Join-Path $stage 'docs') $relative
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination)) | Out-Null
    Copy-Item -LiteralPath $file.FullName -Destination $destination
}
$hashes = foreach ($file in (Get-ChildItem -LiteralPath $stage -Recurse -File | Sort-Object FullName)) {
    $name = $file.FullName.Substring($stage.Length + 1).Replace('\', '/')
    $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    "$hash  $name"
}
$hashes | Set-Content -LiteralPath (Join-Path $stage 'SHA256SUMS.txt') -Encoding ascii
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -CompressionLevel Optimal -Force
$zipHash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
"$zipHash  $zipName" | Set-Content -LiteralPath (Join-Path $dist 'RELEASE_SHA256SUMS.txt') -Encoding ascii
# Keep the staged files for inspection; package creation never deletes existing output.
Write-Host "[PASS] MTU Guard package: $zip"
