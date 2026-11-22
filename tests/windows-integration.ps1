#requires -version 5.1
#requires -RunAsAdministrator
param(
    [string]$OutputPath = (Join-Path $env:TEMP 'MTU-Guard-SCM-check.json'),
    [ValidateRange(1, 3600)][int]$IdleSampleSeconds = 5
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'scripts\service-common.ps1')
$paths = Get-GuardPaths
$serviceName = 'WithenMtuGuard'
$serviceKey = "HKLM:\SYSTEM\CurrentControlSet\Services\$serviceName"
if ((Test-Path -LiteralPath $serviceKey) -or (Test-Path -LiteralPath $paths.Install) -or (Test-Path -LiteralPath $paths.Logs)) {
    throw 'Integration test requires no existing MTU Guard installation or logs. Existing data will not be replaced.'
}
function Invoke-Installer([string]$Name) {
    & "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $root "scripts\$Name.ps1") -NonInteractive | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "$Name failed with exit code $LASTEXITCODE" }
}
function Assert-ScmConfiguration {
    $service = Get-CimInstance -ClassName Win32_Service -Filter "Name='$serviceName'"
    $expected = '"' + (Join-Path $paths.Install 'withen-mtu-guard.exe') + '" service'
    if ($null -eq $service -or $service.PathName -cne $expected -or $service.StartMode -ne 'Auto' -or
        $service.StartName -ne 'LocalSystem' -or $service.State -ne 'Running') { throw 'SCM configuration/state check failed' }
    $expectedVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $root 'withen-mtu-guard.exe')).ProductVersion
    $installedVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $paths.Install 'withen-mtu-guard.exe')).ProductVersion
    if ($installedVersion -cne $expectedVersion) { throw 'Installed binary version mismatch' }
}
$result = [ordered]@{ utc = [DateTime]::UtcNow.ToString('o'); result = 'FAIL'; stop_seconds = @() }
$started = $false
try {
    $started = $true
    Invoke-Installer 'install'
    Assert-ScmConfiguration
    $result['install_and_quoted_image_path'] = 'PASS'
    $servicePid = (Get-CimInstance -ClassName Win32_Service -Filter "Name='$serviceName'").ProcessId
    $process = Get-Process -Id $servicePid
    try {
        $cpuBefore = $process.TotalProcessorTime.TotalSeconds
        $sample = [Diagnostics.Stopwatch]::StartNew()
        Start-Sleep -Seconds $IdleSampleSeconds
        $process.Refresh()
        $cpuDelta = $process.TotalProcessorTime.TotalSeconds - $cpuBefore
        $result['idle_sample_seconds'] = [Math]::Round($sample.Elapsed.TotalSeconds, 3)
        $result['idle_cpu_seconds'] = $cpuDelta
        $result['idle_cpu_percent_one_core'] = [Math]::Round(100 * $cpuDelta / $sample.Elapsed.TotalSeconds, 4)
        $result['working_set_bytes'] = $process.WorkingSet64
        $result['private_bytes'] = $process.PrivateMemorySize64
    } finally { $process.Dispose() }
    foreach ($directory in @($paths.Install, $paths.Logs)) {
        foreach ($rule in (Get-Acl -LiteralPath $directory).Access) {
            $sid = $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
            if ($sid -in @('S-1-1-0', 'S-1-5-11', 'S-1-5-32-545') -and
                $rule.AccessControlType -eq 'Allow' -and
                ($rule.FileSystemRights -band ([Security.AccessControl.FileSystemRights]::Write -bor [Security.AccessControl.FileSystemRights]::Delete))) {
                throw "Unprivileged write permission on $directory"
            }
        }
    }
    $result['directory_acl'] = 'PASS'
    for ($i = 0; $i -lt 2; $i++) {
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $controller = Get-Service -Name $serviceName
        try { $controller.Stop(); $controller.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(20)) } finally { $controller.Dispose() }
        $clock.Stop()
        $result['stop_seconds'] += [Math]::Round($clock.Elapsed.TotalSeconds, 3)
        Start-Service -Name $serviceName -ErrorAction Stop
        $controller = Get-Service -Name $serviceName
        try { $controller.WaitForStatus('Running', [TimeSpan]::FromSeconds(15)) } finally { $controller.Dispose() }
    }
    $result['start_stop'] = 'PASS'
    Invoke-Installer 'install'
    Assert-ScmConfiguration
    $result['upgrade_existing_running_service'] = 'PASS'
    $guardLog = Join-Path $paths.Logs 'guard.log'
    if (Test-Path -LiteralPath $guardLog) {
        $savedLog = [IO.Path]::GetFullPath($OutputPath) + '.guard.log'
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($savedLog)) | Out-Null
        Copy-Item -LiteralPath $guardLog -Destination $savedLog -Force
        $result['guard_log'] = $savedLog
    }
    Invoke-Installer 'uninstall'
    if ((Test-Path -LiteralPath $serviceKey) -or (Test-Path -LiteralPath $paths.Install) -or (Test-Path -LiteralPath $paths.Logs)) {
        throw 'Uninstall left service or files behind'
    }
    Invoke-Installer 'uninstall'
    $result['uninstall_and_repeat_uninstall'] = 'PASS'
    $result['result'] = 'PASS'
} catch {
    $result['error'] = $_.Exception.Message
    throw
} finally {
    if ($started -and ((Test-Path -LiteralPath $serviceKey) -or (Test-Path -LiteralPath $paths.Install) -or (Test-Path -LiteralPath $paths.Logs))) {
        try { Invoke-Installer 'uninstall' } catch { $result['cleanup_error'] = $_.Exception.Message; $result['result'] = 'FAIL' }
    }
    $output = [IO.Path]::GetFullPath($OutputPath)
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($output)) | Out-Null
    [IO.File]::WriteAllText($output, ($result | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
    Write-Host "SCM integration result: $($result['result']); evidence: $output"
}
if ($result['result'] -ne 'PASS') { exit 1 }
