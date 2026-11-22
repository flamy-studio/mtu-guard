#requires -version 5.1
param([switch]$Verify)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path $PSScriptRoot -Parent
$manifestPath = Join-Path $root 'SHA256SUMS_SOURCE.txt'
if ($Verify) {
    foreach ($line in (Get-Content -LiteralPath $manifestPath)) {
        if ($line -notmatch '^([a-f0-9]{64})  (.+)$') { throw 'Invalid source checksum record' }
        $expected = $Matches[1]
        $relative = $Matches[2]
        $path = [IO.Path]::GetFullPath((Join-Path $root $relative))
        if (-not $path.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Source checksum escapes repository' }
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $expected) {
            throw "Source checksum mismatch: $relative"
        }
    }
    Write-Host '[PASS] Source SHA-256 manifest verified'
    return
}
$files = @(Get-ChildItem -LiteralPath $root -Force -File)
foreach ($name in @('.cargo', 'src', 'scripts', 'docs', 'tests', 'tools')) {
    $directory = Join-Path $root $name
    if (Test-Path -LiteralPath $directory) { $files += @(Get-ChildItem -LiteralPath $directory -Recurse -Force -File) }
}
$records = @(foreach ($file in ($files | Sort-Object FullName)) {
    if ($file.Name -in @('SHA256SUMS_SOURCE.txt', 'SHA256SUMS.txt', 'RELEASE_SHA256SUMS.txt') -or
        $file.Name -like '.env*' -or $file.Extension -in @('.exe', '.pdb', '.msi', '.zip', '.log', '.dmp', '.pyc')) { continue }
    $relative = $file.FullName.Substring($root.Length + 1).Replace('\', '/')
    $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    "$hash  $relative"
})
[IO.File]::WriteAllText($manifestPath, ($records -join "`n") + "`n", [Text.Encoding]::ASCII)
Write-Host "[PASS] $($records.Count) source checksums updated"
