#requires -version 5.1
param([switch]$FromUac, [switch]$NonInteractive)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'service-common.ps1')

function Write-Result([string]$Status, [string]$Message) {
    Write-Host "[$Status] $Message"
}

function Run-Sc([string[]]$Arguments) {
    & "$env:WINDIR\System32\sc.exe" @Arguments | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "sc.exe $($Arguments[0]): exit code $LASTEXITCODE" }
}

# Elevate once; service installation itself cannot be done as an unprivileged user.
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
$isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    if ($NonInteractive) { throw 'Run the noninteractive installer from an elevated PowerShell' }
    Write-Result 'INFO' 'Requesting administrator privileges (UAC)...'
    $cmd = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -FromUac' -f $PSCommandPath.Replace('"','')
    try {
        $proc = Start-Process -FilePath "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" `
            -Verb RunAs -ArgumentList $cmd -PassThru -Wait
        exit $proc.ExitCode
    } catch {
        Write-Result 'FAIL' "UAC was declined or could not start: $_"
        exit 1
    }
}

$service = 'WithenMtuGuard'
$sourceRoot = Split-Path -Parent $PSScriptRoot
$exe = Join-Path $sourceRoot 'withen-mtu-guard.exe'
$checksum = Join-Path $sourceRoot 'SHA256SUMS.txt'
$paths = Get-GuardPaths
$destination = $paths.Install
$target = Join-Path $destination 'withen-mtu-guard.exe'
$logDirectory = $paths.Logs

try {
    if (-not [Environment]::Is64BitProcess) { throw 'Use 64-bit Windows PowerShell for the x64 package' }
    Assert-GuardDirectory $destination $paths.ProgramRoot
    Assert-GuardDirectory $logDirectory $paths.DataRoot
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
        throw "Binary not found: $exe. Build the project or use the release ZIP (not source ZIP)."
    }
    if (Test-Path -LiteralPath $checksum) {
        $record = Get-Content -LiteralPath $checksum | Where-Object { $_ -match '\swithen-mtu-guard\.exe$' } | Select-Object -First 1
        if (-not $record) { throw 'SHA256SUMS.txt has no entry for withen-mtu-guard.exe' }
        $expected = ($record -split '\s+')[0].ToLowerInvariant()
        $actual = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($expected -ne $actual) { throw 'SHA-256 verification failed; do not install this binary' }
        Write-Result 'PASS' 'SHA-256 of binary verified'
    } else {
        Write-Result 'WARN' 'No SHA256SUMS.txt; source build is not independently verified'
    }

    New-Item -ItemType Directory -Path $destination -Force | Out-Null
    # Language-independent SIDs: SYSTEM, Administrators and Users (read/execute only).
    & icacls.exe $destination '/inheritance:r' '/grant:r' '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Failed to secure installation directory ACL' }

    New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
    & icacls.exe $logDirectory '/inheritance:r' '/grant:r' '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Failed to secure log directory ACL' }

    $existing = Get-Service -Name $service -ErrorAction SilentlyContinue
    $hasExisting = $null -ne $existing
    if ($hasExisting) {
        try {
            if ($existing.Status -ne 'Stopped') {
                $existing.Stop()
                $existing.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(20))
            }
        } finally { $existing.Dispose() }
    }

    Copy-Item -LiteralPath $exe -Destination $target -Force
    Write-Result 'PASS' 'Binary installed to protected Program Files directory'

    $binaryPath = '"' + $target + '" service'
    $description = 'MTU Guard by Flamy Studio for Withen Network. Maintains AmneziaVPN IPv4 MTU 1280.'
    if (-not $hasExisting) {
        # New-Service passes the quoted path to the SCM API without native-shell quoting.
        # https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.management/new-service
        New-Service -Name $service -BinaryPathName $binaryPath -DisplayName 'MTU Guard' `
            -Description $description -StartupType Automatic | Out-Null
        Write-Result 'PASS' 'Windows Service registered'
    } else {
        # CIM Change maps directly to SCM; PathName keeps quotes around Program Files.
        # https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/change-method-in-class-win32-service
        $change = Invoke-CimMethod -Query "SELECT * FROM Win32_Service WHERE Name='$service'" `
            -MethodName Change -Arguments @{ PathName = $binaryPath; StartMode = 'Automatic';
                StartName = 'LocalSystem'; DisplayName = 'MTU Guard' }
        if ($change.ReturnValue -ne 0) { throw "Service update failed: Win32_Service.Change returned $($change.ReturnValue)" }
        Set-Service -Name $service -Description $description
        Write-Result 'PASS' 'Existing service upgraded'
    }
    $configuration = Get-CimInstance -ClassName Win32_Service -Filter "Name='$service'"
    if ($configuration.PathName -cne $binaryPath -or $configuration.StartMode -ne 'Auto' -or
        $configuration.StartName -ne 'LocalSystem') { throw 'SCM configuration verification failed (ImagePath, Automatic, LocalSystem)' }
    Write-Result 'PASS' 'SCM ImagePath, Automatic startup and LocalSystem verified'
    Run-Sc -Arguments @('failure', $service, 'reset=', '86400', 'actions=', 'restart/5000/restart/10000/restart/30000')

    Start-Service -Name $service -ErrorAction Stop
    (Get-Service -Name $service).WaitForStatus('Running', [TimeSpan]::FromSeconds(15))
    Write-Result 'PASS' 'Service started (Automatic)'
    Wait-GuardMtu -BinaryPath $target
    Write-Host ''
    Write-Result 'INFO' 'If AmneziaVPN is closed, WAITING is normal. Open/connect VPN and run status.cmd.'
    Write-Result 'INFO' "Log: $logDirectory\guard.log"
    Write-Result 'PASS' 'Installation complete'
    if ($FromUac -and -not $NonInteractive) { [void](Read-Host 'Press Enter to close this administrator window') }
} catch {
    Write-Result 'FAIL' $_.Exception.Message
    Write-Result 'INFO' 'Check service status using status.cmd and log before retrying.'
    if ($FromUac -and -not $NonInteractive) { [void](Read-Host 'Press Enter to close this administrator window') }
    exit 1
}
