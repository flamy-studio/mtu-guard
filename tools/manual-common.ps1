#requires -version 5.1
# MTU Guard manual tool. Copyright 2026 Flamy Studio. Apache-2.0.

function Test-ManualAlias([string]$Name) {
    if ($Name -cmatch '[^\x00-\x7f]') { return $false }
    $canonical = $Name.ToLowerInvariant()
    if ($canonical -ceq 'amneziavpn') { return $true }
    if ($canonical -cnotmatch '^amneziavpn ([1-9][0-9]*)\z') { return $false }
    [uint32]$number = 0
    return [uint32]::TryParse($Matches[1], [ref]$number)
}

function Test-ManualAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } finally { $identity.Dispose() }
}

function Get-ManualSnapshot {
    $adapters = @(Get-NetAdapter -IncludeHidden -ErrorAction Stop)
    $potential = @($adapters | Where-Object {
        (Test-ManualAlias ([string]$_.Name)) -and ([string]$_.Status -eq 'Up') -and
        $null -ne $_.PSObject.Properties['HardwareInterface'] -and $_.HardwareInterface -eq $false
    })
    # Enumerate the ActiveStore once. Missing rows are WAITING; API failures must
    # abort the entire selection instead of hiding a potentially active adapter.
    $ipv4Rows = @()
    if ($potential.Count -gt 0) {
        $ipv4Rows = @(Get-NetIPInterface -AddressFamily IPv4 -PolicyStore ActiveStore -ErrorAction Stop)
    }
    $found = New-Object 'System.Collections.Generic.List[object]'
    $eligible = New-Object 'System.Collections.Generic.List[object]'
    foreach ($adapter in $adapters) {
        $alias = [string]$adapter.Name
        if (-not (Test-ManualAlias $alias)) { continue }
        $up = [string]$adapter.Status -eq 'Up'
        $virtual = $null -ne $adapter.PSObject.Properties['HardwareInterface'] -and $adapter.HardwareInterface -eq $false
        [uint32]$index = 0
        if (-not [uint32]::TryParse([string]$adapter.ifIndex, [ref]$index) -or $index -eq 0) { throw 'Invalid adapter index; no MTU written.' }
        [guid]$guid = [guid]::Empty
        $guidProperty = $adapter.PSObject.Properties['InterfaceGuid']
        if ($null -ne $guidProperty) { [void][guid]::TryParse([string]$guidProperty.Value, [ref]$guid) }
        $ipv4 = $null
        $mtu = $null
        $compartment = $null
        if ($up -and $virtual) {
            $ipv4 = $false
            if ($guid -eq [guid]::Empty) { throw "Cannot identify '$alias' by GUID; no MTU written." }
            $rows = @($ipv4Rows | Where-Object { $_.InterfaceIndex -eq $index })
            if ($rows.Count -gt 1) { throw "Multiple IPv4 rows for '$alias'; no MTU written." }
            if ($rows.Count -eq 1) {
                $row = $rows[0]
                if (-not [string]::Equals([string]$row.InterfaceAlias, $alias, [StringComparison]::OrdinalIgnoreCase) -or
                    [string]$row.AddressFamily -ne 'IPv4') { throw 'Adapter identity changed during IPv4 enumeration; no MTU written.' }
                $ipv4 = $true
                # MSFT_NetIPInterface stores NlMtu. NlMtuBytes is a cmdlet
                # parameter, not the CIM property (Microsoft provider contract).
                $mtuProperty = $row.PSObject.Properties['NlMtu']
                [uint32]$parsedMtu = 0
                if ($null -ne $mtuProperty -and [uint32]::TryParse([string]$mtuProperty.Value, [ref]$parsedMtu) -and $parsedMtu -gt 0) { $mtu = $parsedMtu }
                $compartmentProperty = $row.PSObject.Properties['CompartmentId']
                [uint32]$parsedCompartment = 0
                if ($null -ne $compartmentProperty -and [uint32]::TryParse([string]$compartmentProperty.Value, [ref]$parsedCompartment)) { $compartment = $parsedCompartment }
            }
        }
        $record = [pscustomobject]@{
            Alias = $alias; Index = $index; Guid = $guid; Up = $up; Virtual = $virtual
            IPv4 = $ipv4; Mtu = $mtu; Compartment = $compartment
            Description = [string]$adapter.InterfaceDescription
        }
        $found.Add($record)
        if ($up -and $virtual -and $ipv4) { $eligible.Add($record) }
    }
    [pscustomobject]@{ Found = @($found.ToArray()); Eligible = @($eligible.ToArray()) }
}

function Show-ManualSnapshot($Snapshot) {
    Write-Host "[INFO] AmneziaVPN adapter names found: $($Snapshot.Found.Count)"
    if ($Snapshot.Found.Count -gt 1) { Write-Host '[INFO] Multiple entries can be normal; they do not prove a broken driver installation.' }
    foreach ($adapter in $Snapshot.Found) {
        $mtu = if ($null -eq $adapter.Mtu) { 'n/a' } else { [string]$adapter.Mtu }
        $ipv4 = if ($null -eq $adapter.IPv4) { 'not-queried' } else { [string]$adapter.IPv4 }
        Write-Host ("[INFO] Alias='{0}' Index={1} Up={2} Virtual={3} IPv4={4} MTU={5} Description='{6}'" -f
            $adapter.Alias, $adapter.Index, $adapter.Up, $adapter.Virtual, $ipv4, $mtu, $adapter.Description)
    }
}

function Get-ManualTarget($Snapshot) {
    if ($Snapshot.Eligible.Count -gt 1) { throw 'AMBIGUOUS: multiple eligible active IPv4 adapters; no MTU written.' }
    if ($Snapshot.Eligible.Count -eq 0) { return $null }
    return $Snapshot.Eligible[0]
}

function Test-ManualIdentity($First, $Second) {
    return $null -ne $First -and $null -ne $Second -and
        $First.Guid -eq $Second.Guid -and $First.Guid -ne [guid]::Empty -and
        $First.Index -eq $Second.Index -and $First.Alias -ceq $Second.Alias -and
        $First.Compartment -eq $Second.Compartment
}

function Set-ManualMtu($Target, [uint32]$Mtu) {
    if ($null -eq $Target.Compartment) { throw 'Cannot identify the IPv4 compartment; no MTU written.' }
    Set-NetIPInterface -InterfaceIndex $Target.Index -InterfaceAlias $Target.Alias -AddressFamily IPv4 `
        -CompartmentId $Target.Compartment -NlMtuBytes $Mtu -PolicyStore ActiveStore -Confirm:$false -ErrorAction Stop
}

function Wait-ManualVerification { Start-Sleep -Milliseconds 300 }

function Invoke-ManualOperation {
    param(
        [ValidateSet('Check', 'Fix')][string]$Mode,
        [ValidateRange(576, 9000)][int]$Mtu = 1280,
        [Parameter(Mandatory = $true)]$Snapshot,
        [bool]$IsAdmin = $false,
        [switch]$ElevationAttempted,
        [guid]$ExpectedGuid = [guid]::Empty,
        [uint32]$ExpectedIndex = 0,
        [string]$ExpectedAlias = '',
        [uint32]$ExpectedCompartment = 0
    )
    $target = Get-ManualTarget $Snapshot
    if ($null -eq $target) {
        return [pscustomobject]@{ Action = 'Complete'; ExitCode = 3; Message = 'No eligible active IPv4 adapter; connect AmneziaVPN and retry.' }
    }
    if ($ExpectedGuid -ne [guid]::Empty -and ($target.Guid -ne $ExpectedGuid -or
        $target.Index -ne $ExpectedIndex -or $target.Alias -cne $ExpectedAlias -or $target.Compartment -ne $ExpectedCompartment)) {
        throw 'Adapter changed while waiting for UAC; no MTU written. Run the tool again.'
    }
    if ($null -eq $target.Mtu) { throw "Cannot read IPv4 NlMtu for '$($target.Alias)'; refusing a blind change." }
    if ($Mode -eq 'Check') {
        $code = if ($target.Mtu -eq 1280) { 0 } else { 4 }
        return [pscustomobject]@{ Action = 'Complete'; ExitCode = $code; Message = "$($target.Alias) IPv4 MTU = $($target.Mtu); expected 1280." }
    }
    if ($target.Mtu -eq $Mtu) {
        return [pscustomobject]@{ Action = 'Complete'; ExitCode = 0; Message = "$($target.Alias) IPv4 MTU is already $Mtu; no change required." }
    }
    if (-not $IsAdmin) {
        if ($ElevationAttempted) { throw 'Administrator privileges were not granted; no repeated UAC request.' }
        return [pscustomobject]@{ Action = 'Elevate'; ExitCode = 1; Target = $target }
    }
    $fresh = Get-ManualTarget (Get-ManualSnapshot)
    if (-not (Test-ManualIdentity $target $fresh)) { throw 'Adapter changed before correction; no MTU written. Retry.' }
    if ($null -eq $fresh.Mtu) { throw 'Cannot read MTU before correction; no MTU written.' }
    if ($fresh.Mtu -eq $Mtu) {
        return [pscustomobject]@{ Action = 'Complete'; ExitCode = 0; Message = "$($fresh.Alias) IPv4 MTU is already $Mtu; another process corrected it." }
    }
    $oldMtu = $fresh.Mtu
    Set-ManualMtu -Target $fresh -Mtu $Mtu
    Wait-ManualVerification
    $after = Get-ManualTarget (Get-ManualSnapshot)
    if (-not (Test-ManualIdentity $fresh $after)) { throw 'Adapter changed after correction; no verified result. Retry.' }
    if ($null -eq $after.Mtu -or $after.Mtu -ne $Mtu) { throw "MTU verification failed; expected $Mtu." }
    [pscustomobject]@{ Action = 'Complete'; ExitCode = 0; Message = "$($after.Alias) IPv4 MTU: $oldMtu -> $($after.Mtu); verified (one-time ActiveStore change)." }
}

function Start-ManualElevation {
    param([string]$ScriptPath, $Target, [ValidateRange(576, 9000)][int]$Mtu)
    if (-not (Test-ManualAlias $Target.Alias) -or $Target.Guid -eq [guid]::Empty -or $null -eq $Target.Compartment) { throw 'Invalid elevation target.' }
    $powershell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Mode Fix -Mtu {1} -Elevated -NoPause -ExpectedGuid {2} -ExpectedIndex {3} -ExpectedAlias "{4}" -ExpectedCompartment {5}' -f
        $ScriptPath.Replace('"', ''), $Mtu, $Target.Guid.ToString('D'), $Target.Index, $Target.Alias, $Target.Compartment
    # The parent owns the output, optional probe and pause. Only the writer elevates.
    $process = Start-Process -FilePath $powershell -ArgumentList $arguments -Verb RunAs -WindowStyle Hidden -Wait -PassThru
    try { return [int]$process.ExitCode } finally { $process.Dispose() }
}

function Invoke-ManualHttpsProbe {
    Write-Host '[INFO] Direct IPv4 HTTPS test to Cloudflare 1.1.1.1; response body is not saved.'
    $client = $null
    $response = $null
    $tlsBefore = [Net.ServicePointManager]::SecurityProtocol
    try {
        Add-Type -AssemblyName System.Net.Http
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $handler = New-Object Net.Http.HttpClientHandler
        $handler.UseProxy = $false
        $handler.AllowAutoRedirect = $false
        $client = New-Object Net.Http.HttpClient($handler)
        $client.Timeout = [TimeSpan]::FromSeconds(8)
        $response = $client.GetAsync('https://1.1.1.1/cdn-cgi/trace', [Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        $status = [int]$response.StatusCode
        if ($status -ge 200 -and $status -lt 300) { Write-Host "[PASS] HTTPS IPv4: HTTP $status (MTU result is separate)." }
        else { Write-Host "[WARN] HTTPS IPv4: HTTP $status (MTU result is separate)." }
    } catch { Write-Host "[WARN] HTTPS probe failed: $($_.Exception.Message) (MTU result is separate)." }
    finally {
        if ($null -ne $response) { $response.Dispose() }
        if ($null -ne $client) { $client.Dispose() }
        [Net.ServicePointManager]::SecurityProtocol = $tlsBefore
    }
}
