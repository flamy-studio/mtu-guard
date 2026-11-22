#requires -version 5.1
param(
    [ValidateRange(1, 86400)][int]$DurationSeconds = 60,
    [ValidateRange(100, 60000)][int]$IntervalMilliseconds = 500,
    [string]$OutputPath = (Join-Path $env:TEMP 'MTU-Guard-observations.jsonl'),
    [switch]$ProbeHttps
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'status-parser.ps1')
$root = Split-Path $PSScriptRoot -Parent
$binary = Join-Path $root 'withen-mtu-guard.exe'
if (-not (Test-Path -LiteralPath $binary)) { throw 'Run from a fully extracted MTU Guard package' }
$output = [IO.Path]::GetFullPath($OutputPath)
[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($output)) | Out-Null
$writer = New-Object IO.StreamWriter($output, $false, (New-Object Text.UTF8Encoding($false)))
$clock = [Diagnostics.Stopwatch]::StartNew()
$nextProbe = 0.0
$probe = $null
$httpClient = $null
$tlsBefore = [Net.ServicePointManager]::SecurityProtocol
$previousCpu = $null
$previousPid = $null
$previousTime = 0.0
try {
    if ($ProbeHttps) {
        Add-Type -AssemblyName System.Net.Http
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $handler = New-Object Net.Http.HttpClientHandler
        $handler.UseProxy = $false
        $handler.AllowAutoRedirect = $false
        $httpClient = New-Object Net.Http.HttpClient($handler)
        $httpClient.Timeout = [TimeSpan]::FromSeconds(8)
    }
    while ($clock.Elapsed.TotalSeconds -lt $DurationSeconds) {
        $status = Read-GuardStatus -BinaryPath $binary
        $text = $status.Text
        $statusCode = $status.ExitCode
        $adapterData = ConvertFrom-GuardStatus $text
        $service = Get-CimInstance -ClassName Win32_Service -Filter "Name='WithenMtuGuard'"
        $servicePid = if ($null -eq $service) { 0 } else { [int]$service.ProcessId }
        $process = if ($servicePid -gt 0) { Get-Process -Id $servicePid -ErrorAction SilentlyContinue } else { $null }
        $now = $clock.Elapsed.TotalSeconds
        $cpu = if ($null -eq $process) { $null } else { $process.TotalProcessorTime.TotalSeconds }
        $cpuPercentOneCore = $null
        if ($null -ne $cpu -and $null -ne $previousCpu -and $previousPid -eq $servicePid -and $now -gt $previousTime) {
            $cpuPercentOneCore = [Math]::Round(100 * ($cpu - $previousCpu) / ($now - $previousTime), 4)
        }
        $record = [ordered]@{
            utc = [DateTime]::UtcNow.ToString('o')
            elapsed_seconds = [Math]::Round($now, 3)
            adapter_status = $text
            adapter_alias = $adapterData.Alias
            interface_luid = $adapterData.Luid
            interface_index = $adapterData.Index
            mtu = $adapterData.Mtu
            status_exit = $statusCode
            service_state = $(if ($null -eq $service) { 'ABSENT' } else { $service.State })
            service_pid = $servicePid
            cpu_seconds = $cpu
            cpu_percent_one_core = $cpuPercentOneCore
            working_set_bytes = $(if ($null -eq $process) { $null } else { $process.WorkingSet64 })
            private_bytes = $(if ($null -eq $process) { $null } else { $process.PrivateMemorySize64 })
        }
        if ($ProbeHttps) {
            if ($null -ne $probe -and $probe.IsCompleted) {
                try {
                    $response = $probe.GetAwaiter().GetResult()
                    $record['https_exit'] = 0
                    $record['https_status'] = [int]$response.StatusCode
                    $response.Dispose()
                } catch { $record['https_exit'] = 1; $record['https_error'] = $_.Exception.Message }
                $probe = $null
            }
            if ($null -eq $probe -and $now -ge $nextProbe) {
                # Windows PowerShell's built-in .NET HTTP client, no curl or shell.
                # A numeric IPv4 URL and UseProxy=false match the direct IPv4 test.
                # Only headers are read; the response body/public IP is never logged.
                $probe = $httpClient.GetAsync('https://1.1.1.1/cdn-cgi/trace', [Net.Http.HttpCompletionOption]::ResponseHeadersRead)
                $nextProbe = $now + 10
            }
        }
        $writer.WriteLine(($record | ConvertTo-Json -Compress))
        $writer.Flush()
        $previousCpu = $cpu
        $previousPid = $servicePid
        $previousTime = $now
        $remainingMs = ($DurationSeconds - $clock.Elapsed.TotalSeconds) * 1000
        if ($remainingMs -gt 0) { Start-Sleep -Milliseconds ([int][Math]::Min($IntervalMilliseconds, $remainingMs)) }
    }
} finally {
    if ($null -ne $httpClient) {
        $httpClient.CancelPendingRequests()
        $httpClient.Dispose()
    }
    if ($ProbeHttps) { [Net.ServicePointManager]::SecurityProtocol = $tlsBefore }
    $writer.Dispose()
}
Write-Host "[PASS] Read-only observations saved: $output"
