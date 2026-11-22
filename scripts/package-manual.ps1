#requires -version 5.1
param([switch]$Overwrite)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path $PSScriptRoot -Parent
$version = '0.1'
& (Join-Path $root 'tests\manual-mtu.Tests.ps1')
$dist = Join-Path $root 'dist'
[IO.Directory]::CreateDirectory($dist) | Out-Null
$name = "MTU-Guard-manual-$version-win-x64-candidate.zip"
$archive = Join-Path $dist $name
if ((Test-Path -LiteralPath $archive) -and -not $Overwrite) { throw 'Manual package already exists. Use -Overwrite to replace a local candidate.' }
$stage = Join-Path $dist ('manual-stage-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory((Join-Path $stage 'tools')) | Out-Null
[IO.Directory]::CreateDirectory((Join-Path $stage 'docs')) | Out-Null
foreach ($file in @('manual-mtu.cmd', 'manual-check.cmd', 'README_MANUAL_RU.txt', 'LICENSE', 'NOTICE')) {
    Copy-Item -LiteralPath (Join-Path $root $file) -Destination $stage
}
foreach ($file in @('manual-mtu.ps1', 'manual-common.ps1')) {
    Copy-Item -LiteralPath (Join-Path $root "tools\$file") -Destination (Join-Path $stage 'tools')
}
Copy-Item -LiteralPath (Join-Path $root 'docs\MANUAL_MTU.md') -Destination (Join-Path $stage 'docs')
$records = foreach ($file in (Get-ChildItem -LiteralPath $stage -File -Recurse | Sort-Object FullName)) {
    $relative = $file.FullName.Substring($stage.Length + 1).Replace('\', '/')
    $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    "$hash  $relative"
}
$records | Set-Content -LiteralPath (Join-Path $stage 'SHA256SUMS.txt') -Encoding ascii
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $archive -CompressionLevel Optimal -Force
$checksum = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
"$checksum  $name" | Set-Content -LiteralPath ($archive + '.sha256') -Encoding ascii
Write-Host "[PASS] Standalone manual candidate: $archive"
