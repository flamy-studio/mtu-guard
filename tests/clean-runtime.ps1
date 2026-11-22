#requires -version 5.1
param(
    [string]$OutputPath = (Join-Path $env:TEMP 'MTU-Guard-runtime-check.json'),
    [switch]$RequireCleanMachine
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path $PSScriptRoot -Parent
$binary = Join-Path $root 'withen-mtu-guard.exe'
. (Join-Path $root 'scripts\pe-imports.ps1')
$imports = @(Get-PeImports $binary)
Assert-StandaloneImports $imports
$expected = (Get-Content -LiteralPath (Join-Path $root 'VERSION') -Raw).Trim() + '.0'
$actual = (& $binary --version | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $actual -cne $expected) { throw 'CLI version check failed' }
& $binary --help | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'CLI help failed' }
$status = (& $binary status 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0) { throw "Read-only status failed: $status" }
$check = (& $binary check 2>&1 | Out-String).Trim()
$checkCode = $LASTEXITCODE
if ($checkCode -notin @(0, 3, 4)) { throw "Health check failed: $check" }
$expectedCheckCode = if ($check.StartsWith('[PASS]')) { 0 } elseif ($check.StartsWith('[WAITING]')) { 3 } elseif ($check.StartsWith('[WARN]')) { 4 } else { -1 }
if ($checkCode -ne $expectedCheckCode) { throw "Health check exit does not match its state: $checkCode / $check" }
$redist = @(foreach ($key in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')) {
    Get-ChildItem -LiteralPath $key -ErrorAction SilentlyContinue |
        Get-ItemProperty -ErrorAction SilentlyContinue |
        Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.DisplayName -match 'Microsoft Visual C\+\+.*(Redistributable|Runtime)' }
})
$developerTools = (Test-Path -LiteralPath (Join-Path $env:USERPROFILE '.rustup\toolchains')) -or
    (Test-Path -LiteralPath 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe') -or
    (Test-Path -LiteralPath 'C:\Program Files (x86)\Windows Kits\10\bin')
$clean = $redist.Count -eq 0 -and -not $developerTools
$os = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$result = [ordered]@{
    utc = [DateTime]::UtcNow.ToString('o')
    version = $actual
    windows_build = "$($os.CurrentBuild).$($os.UBR)"
    windows_display_version = $os.DisplayVersion
    imports = $imports
    standalone_imports = 'PASS'
    cli = 'PASS'
    check_exit = $checkCode
    status = $status
    vc_redist_registrations = $redist.Count
    developer_tools_detected = [bool]$developerTools
    clean_machine = [bool]$clean
    clean_machine_qualification = $(if ($clean) { 'PASS' } else { 'NOT RUN: use a clean Windows VM' })
}
$output = [IO.Path]::GetFullPath($OutputPath)
[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($output)) | Out-Null
[IO.File]::WriteAllText($output, ($result | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding($false)))
Write-Host "[PASS] Standalone imports and CLI; clean_machine=$clean; evidence: $output"
if ($RequireCleanMachine -and -not $clean) { throw 'This machine has VC++ Runtime or developer tools; clean-machine qualification is NOT RUN' }
