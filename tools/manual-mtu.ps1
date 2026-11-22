#requires -version 5.1
<#
.SYNOPSIS
  MTU Guard manual check and one-time IPv4 MTU correction, without a service.
.EXAMPLE
  .\tools\manual-mtu.ps1 -Mode Check -NoPause
.EXAMPLE
  .\tools\manual-mtu.ps1 -Mode Fix -Mtu 1280 -Probe -NoPause
#>
[CmdletBinding()]
param(
    [ValidateSet('Menu', 'Check', 'Fix')][string]$Mode = 'Menu',
    [ValidateRange(576, 9000)][int]$Mtu = 1280,
    [switch]$Probe,
    [switch]$Elevated,
    [switch]$NoPause,
    [guid]$ExpectedGuid = [guid]::Empty,
    [uint32]$ExpectedIndex = 0,
    [string]$ExpectedAlias = '',
    [uint32]$ExpectedCompartment = 0
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'manual-common.ps1')
$code = 1
try {
    Write-Host 'MTU Guard | Flamy Studio / Withen Network | Manual tool 0.1'
    $cancelled = $false
    if ($Mode -eq 'Menu') {
        Write-Host '1. Check adapters and MTU'
        Write-Host '2. Set AmneziaVPN IPv4 MTU to 1280'
        Write-Host '3. Set custom IPv4 MTU (advanced)'
        Write-Host '4. Exit'
        switch ((Read-Host 'Choose 1-4').Trim()) {
            '1' { $Mode = 'Check' }
            '2' { $Mode = 'Fix'; $Mtu = 1280 }
            '3' {
                [int]$custom = 0
                if (-not [int]::TryParse((Read-Host 'IPv4 MTU (576-9000; 1280 recommended)').Trim(), [ref]$custom) -or
                    $custom -lt 576 -or $custom -gt 9000) { throw 'MTU must be an integer between 576 and 9000.' }
                $Mode = 'Fix'; $Mtu = $custom
            }
            '4' { $cancelled = $true; $code = 0; Write-Host '[INFO] Cancelled; no check or change performed.' }
            default { throw 'Invalid menu choice.' }
        }
        if (-not $cancelled -and -not $Probe) {
            $Probe = (Read-Host 'Run an optional HTTPS test to Cloudflare after the result? [y/N]').Trim() -ieq 'y'
        }
    }
    if (-not $cancelled) {
        if ($Mode -eq 'Fix' -and $Mtu -ne 1280) {
            Write-Host "[WARN] Custom MTU $Mtu differs from WITHEN recommendation 1280. A running MTU Guard service will restore 1280."
        }
        $snapshot = Get-ManualSnapshot
        Show-ManualSnapshot $snapshot
        $isAdmin = $Mode -eq 'Fix' -and (Test-ManualAdmin)
        $result = Invoke-ManualOperation -Mode $Mode -Mtu $Mtu -Snapshot $snapshot -IsAdmin $isAdmin `
            -ElevationAttempted:$Elevated -ExpectedGuid $ExpectedGuid -ExpectedIndex $ExpectedIndex -ExpectedAlias $ExpectedAlias -ExpectedCompartment $ExpectedCompartment
        if ($result.Action -eq 'Elevate') {
            Write-Host '[INFO] Requesting administrator approval to change MTU.'
            $code = Start-ManualElevation -ScriptPath $PSCommandPath -Target $result.Target -Mtu $Mtu
            if ($code -eq 0) {
                $after = Get-ManualTarget (Get-ManualSnapshot)
                if (-not (Test-ManualIdentity $result.Target $after) -or $after.Mtu -ne $Mtu) { throw 'Adapter or MTU changed after UAC; no verified result. Retry.' }
                Write-Host "[PASS] $($after.Alias) IPv4 MTU: $($result.Target.Mtu) -> $($after.Mtu); verified."
                if ($Probe) { Invoke-ManualHttpsProbe }
            } elseif ($code -eq 3) { Write-Host '[WAITING] Adapter disappeared during UAC; connect AmneziaVPN and retry.' }
            else { Write-Host "[FAIL] Elevated helper did not confirm MTU (exit $code); run manual-check.cmd or use an administrator PowerShell for details." }
        } else {
            $code = $result.ExitCode
            $level = switch ($code) { 0 { 'PASS' }; 3 { 'WAITING' }; 4 { 'WARN' }; default { 'FAIL' } }
            Write-Host "[$level] $($result.Message)"
            if ($Probe -and $code -in @(0, 4)) { Invoke-ManualHttpsProbe }
        }
    }
} catch { Write-Host "[FAIL] $($_.Exception.Message)"; $code = 1 }
finally { if (-not $NoPause) { [void](Read-Host 'Press Enter to close') } }
exit $code
