#requires -version 5.1
param([switch]$FromUac, [switch]$NonInteractive)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'service-common.ps1')

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    if ($NonInteractive) { throw 'Run the noninteractive uninstaller from an elevated PowerShell' }
    $cmd = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -FromUac' -f $PSCommandPath.Replace('"','')
    try {
        $proc = Start-Process -FilePath "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" `
            -Verb RunAs -ArgumentList $cmd -PassThru -Wait
        exit $proc.ExitCode
    } catch { Write-Host '[FAIL] Elevation denied'; exit 1 }
}

try {
    $paths = Get-GuardPaths
    Assert-GuardDirectory $paths.Install $paths.ProgramRoot
    Assert-GuardDirectory $paths.Logs $paths.DataRoot
    $name = 'WithenMtuGuard'
    $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
    if ($null -ne $svc) {
        try {
            if ($svc.Status -ne 'Stopped') {
                $svc.Stop()
                $svc.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(20))
            }
        } finally { $svc.Dispose() }
        & "$env:WINDIR\System32\sc.exe" delete $name | Out-Host
        if ($LASTEXITCODE -ne 0) { throw 'Service deletion failed' }
        $deadline = [DateTime]::UtcNow.AddSeconds(20)
        $serviceKey = "HKLM:\SYSTEM\CurrentControlSet\Services\$name"
        while (Test-Path -LiteralPath $serviceKey) {
            if ([DateTime]::UtcNow -ge $deadline) { throw 'Service is still marked for deletion; close Services consoles and retry' }
            Start-Sleep -Milliseconds 200
        }
        Write-Host '[PASS] Service stopped and deleted'
    } else { Write-Host '[PASS] Service is already absent' }

    $folder = $paths.Install
    if (Test-Path -LiteralPath $folder) {
        Remove-Item -LiteralPath $folder -Recurse -Force
        Write-Host '[PASS] Program files removed'
    }
    $logFolder = $paths.Logs
    if (Test-Path -LiteralPath $logFolder) {
        Remove-Item -LiteralPath $logFolder -Recurse -Force
        Write-Host '[PASS] Service logs removed'
    }
    Write-Host '[PASS] Uninstall complete. VPN adapter MTU is not modified by uninstall.'
    if ($FromUac -and -not $NonInteractive) { [void](Read-Host 'Press Enter to close this administrator window') }
} catch {
    Write-Host "[FAIL] $($_.Exception.Message)"
    if ($FromUac -and -not $NonInteractive) { [void](Read-Host 'Press Enter to close this administrator window') }
    exit 1
}
