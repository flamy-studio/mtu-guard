#requires -version 5.1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path $PSScriptRoot -Parent
foreach ($name in @('manual-mtu.ps1', 'manual-common.ps1')) {
    $tokens = $null; $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile((Join-Path $root "tools\$name"), [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) { throw "PowerShell parse failure in $name" }
}
. (Join-Path $root 'tools\manual-common.ps1')
$nativeSnapshot = ${function:Get-ManualSnapshot}
$global:manualMtuTestState = @{}
$global:manualMtuTestState.testCount = 0
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Assert-Throws([scriptblock]$Action, [string]$Pattern = '*') {
    $caught = $null
    try { & $Action | Out-Null } catch { $caught = $_.Exception.Message }
    Assert ($null -ne $caught -and $caught -like $Pattern) "Expected failure $Pattern; got $caught"
}
function Case([string]$Name, [scriptblock]$Body) {
    Reset-Fakes
    try { & $Body; $global:manualMtuTestState.testCount++ } catch { throw "Manual test '$Name': $($_.Exception.Message)" }
}
function Reset-Fakes {
    $global:manualMtuTestState.adapters = @(); $global:manualMtuTestState.ipRows = @(); $global:manualMtuTestState.adapterFailure = $false; $global:manualMtuTestState.ipFailure = $false
    $global:manualMtuTestState.adapterReads = 0; $global:manualMtuTestState.ipReads = 0; $global:manualMtuTestState.setFailure = $false
    $global:manualMtuTestState.writes = New-Object 'System.Collections.Generic.List[object]'
    $global:manualMtuTestState.scans = New-Object Collections.Queue
    $global:manualMtuTestState.useFixture = $false; $global:manualMtuTestState.waits = 0
    $global:manualMtuTestState.launch = $null; $global:manualMtuTestState.launchCode = 0; $global:manualMtuTestState.launchFailure = $false; $global:manualMtuTestState.disposed = $false
    $global:manualMtuTestState.prompts = New-Object 'System.Collections.Generic.List[string]'
    $global:manualMtuTestState.answers = New-Object Collections.Queue
}
function Adapter([string]$Alias = 'AmneziaVPN', [uint32]$Index = 1, [bool]$Up = $true, [bool]$Hardware = $false) {
    [pscustomobject]@{ Name = $Alias; ifIndex = $Index; InterfaceGuid = [guid]('00000000-0000-0000-0000-{0:x12}' -f $Index)
        Status = $(if ($Up) { 'Up' } else { 'Down' }); HardwareInterface = $Hardware; InterfaceDescription = 'WireGuard Tunnel' }
}
function IpRow([string]$Alias = 'AmneziaVPN', [uint32]$Index = 1, $Mtu = 1376) {
    [pscustomobject]@{ InterfaceAlias = $Alias; InterfaceIndex = $Index; AddressFamily = 'IPv4'; NlMtu = $Mtu; CompartmentId = 1 }
}
function Record([string]$Alias = 'AmneziaVPN', [uint32]$Index = 1, $Mtu = 1376) {
    $adapter = Adapter $Alias $Index
    [pscustomobject]@{ Alias = $Alias; Index = $Index; Guid = $adapter.InterfaceGuid; Mtu = $Mtu; Compartment = 1
        Up = $true; Virtual = $true; IPv4 = $true; Description = 'WireGuard Tunnel' }
}
function Snapshot($Records = @()) { [pscustomobject]@{ Found = @($Records); Eligible = @($Records) } }
function Get-NetAdapter {
    [CmdletBinding()]param([switch]$IncludeHidden)
    Assert $IncludeHidden 'Hidden adapters must be enumerated'
    $global:manualMtuTestState.adapterReads++
    if ($global:manualMtuTestState.adapterFailure) { throw 'adapter enumeration failed' }
    $global:manualMtuTestState.adapters
}
function Get-NetIPInterface {
    [CmdletBinding()]param([string]$AddressFamily, [string]$PolicyStore)
    Assert ($AddressFamily -eq 'IPv4' -and $PolicyStore -eq 'ActiveStore') 'Only active IPv4 rows may be queried'
    $global:manualMtuTestState.ipReads++
    if ($global:manualMtuTestState.ipFailure) { throw 'IPv4 access denied' }
    $global:manualMtuTestState.ipRows
}
function Set-NetIPInterface {
    [CmdletBinding(SupportsShouldProcess = $true)]param(
        [uint32]$InterfaceIndex, [string]$InterfaceAlias, [string]$AddressFamily,
        [uint32]$CompartmentId, [uint32]$NlMtuBytes, [string]$PolicyStore
    )
    $global:manualMtuTestState.writes.Add(@{} + $PSBoundParameters)
    if ($global:manualMtuTestState.setFailure) { throw 'set access denied' }
}
function Wait-ManualVerification { $global:manualMtuTestState.waits++ }
function Get-ManualSnapshot {
    if (-not $global:manualMtuTestState.useFixture) { return & $nativeSnapshot }
    if ($global:manualMtuTestState.scans.Count -eq 0) { throw 'Unexpected snapshot read' }
    return $global:manualMtuTestState.scans.Dequeue()
}
function Start-Process {
    [CmdletBinding()]param([string]$FilePath, [string]$ArgumentList, [string]$Verb, [string]$WindowStyle, [switch]$Wait, [switch]$PassThru)
    $global:manualMtuTestState.launch = @{} + $PSBoundParameters
    if ($global:manualMtuTestState.launchFailure) { throw 'UAC cancelled' }
    $process = [pscustomobject]@{ ExitCode = $global:manualMtuTestState.launchCode }
    $process | Add-Member -MemberType ScriptMethod -Name Dispose -Value { $global:manualMtuTestState.disposed = $true }
    return $process
}
function Read-Host([string]$Prompt) {
    $global:manualMtuTestState.prompts.Add($Prompt)
    if ($global:manualMtuTestState.answers.Count -eq 0) { throw 'Unexpected interactive prompt' }
    return $global:manualMtuTestState.answers.Dequeue()
}

Case 'strict alias family' {
    foreach ($name in @('AmneziaVPN', 'AMNEZIAVPN', 'AmneziaVPN 1', 'amneziavpn 2', 'AmneziaVPN 4294967295')) { Assert (Test-ManualAlias $name) "Rejected $name" }
    foreach ($name in @('', 'AmneziaVPN +2', 'AmneziaVPN 0', 'AmneziaVPN 02', 'AmneziaVPN  2', 'AmneziaVPN 2 ',
        'AmneziaVPN 4294967296', 'AmneziaVPN Backup', 'AmneziaWG', 'Ethernet', "AmneziaVPN`t2", "AmneziaVPN 2`n", "AmneziaVPN 2`r`n", ('AmneziaVPN ' + [char]0xff12))) { Assert (-not (Test-ManualAlias $name)) "Accepted $name" }
}
Case 'native snapshot reads actual NlMtu and ignores stale/hardware entries' {
    $global:manualMtuTestState.adapters = @((Adapter 'AmneziaVPN' 1 $false), (Adapter 'amneziavpn 1' 2), (Adapter 'AmneziaVPN 2' 3 $true $true), (Adapter 'Ethernet' 4))
    $ip = IpRow 'amneziavpn 1' 2 1280
    $ip | Add-Member NoteProperty NlMtuBytes 999
    $global:manualMtuTestState.ipRows = @($ip)
    $scan = Get-ManualSnapshot
    Assert ($scan.Found.Count -eq 3 -and $scan.Eligible.Count -eq 1) 'Wrong eligible set'
    Assert ($scan.Eligible[0].Alias -ceq 'amneziavpn 1' -and $scan.Eligible[0].Mtu -eq 1280) 'NlMtu or actual alias lost'
    Assert ($global:manualMtuTestState.ipReads -eq 1 -and $null -eq $scan.Found[0].IPv4) 'Inactive adapters must not be queried individually'
}
Case 'ASCII alias matching does not depend on Windows culture' {
    $thread = [Threading.Thread]::CurrentThread
    $previous = $thread.CurrentCulture
    try {
        $thread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('tr-TR')
        Assert (Test-ManualAlias 'AMNEZIAVPN 1') 'ASCII uppercase alias rejected under Turkish culture'
        Assert (-not (Test-ManualAlias ('Amnez' + [char]0x0131 + 'aVPN 1'))) 'Non-ASCII alias accepted'
    } finally { $thread.CurrentCulture = $previous }
}
Case 'adapter enumeration error aborts' {
    $global:manualMtuTestState.adapterFailure = $true
    Assert-Throws { Get-ManualSnapshot } '*enumeration failed*'
}
Case 'IPv4 API error is never hidden from selection' {
    $global:manualMtuTestState.adapters = @((Adapter), (Adapter 'AmneziaVPN 2' 2)); $global:manualMtuTestState.ipFailure = $true
    Assert-Throws { Get-ManualSnapshot } '*access denied*'
    Assert ($global:manualMtuTestState.writes.Count -eq 0) 'Wrote after API error'
}
Case 'missing IPv4 waits' {
    $global:manualMtuTestState.adapters = @((Adapter))
    $result = Invoke-ManualOperation -Mode Fix -Snapshot (Get-ManualSnapshot)
    Assert ($result.ExitCode -eq 3 -and $result.Action -eq 'Complete') 'Missing IPv4 must wait'
}
Case 'unknown hardware flag is excluded' {
    $item = Adapter; $item.PSObject.Properties.Remove('HardwareInterface'); $global:manualMtuTestState.adapters = @($item)
    Assert ((Get-ManualSnapshot).Eligible.Count -eq 0 -and $global:manualMtuTestState.ipReads -eq 0) 'Unknown hardware flag was trusted'
}
Case 'missing GUID aborts' {
    $item = Adapter; $item.InterfaceGuid = ''; $global:manualMtuTestState.adapters = @($item)
    Assert-Throws { Get-ManualSnapshot } '*GUID*'
}
Case 'changed alias or family while enumerating aborts' {
    $global:manualMtuTestState.adapters = @((Adapter)); $global:manualMtuTestState.ipRows = @((IpRow 'Ethernet'))
    Assert-Throws { Get-ManualSnapshot } '*identity changed*'
    $ip = IpRow; $ip.AddressFamily = 'IPv6'; $global:manualMtuTestState.ipRows = @($ip)
    Assert-Throws { Get-ManualSnapshot } '*identity changed*'
}
Case 'duplicate IPv4 rows abort' {
    $global:manualMtuTestState.adapters = @((Adapter)); $global:manualMtuTestState.ipRows = @((IpRow), (IpRow))
    Assert-Throws { Get-ManualSnapshot } '*Multiple IPv4 rows*'
}
Case 'unknown MTU still counts as eligible and prevents a blind write' {
    $global:manualMtuTestState.adapters = @((Adapter)); $ip = IpRow; $ip.PSObject.Properties.Remove('NlMtu'); $global:manualMtuTestState.ipRows = @($ip)
    $scan = Get-ManualSnapshot
    Assert ($scan.Eligible.Count -eq 1) 'Unreadable MTU must not hide an eligible adapter'
    Assert-Throws { Invoke-ManualOperation -Mode Fix -Snapshot $scan -IsAdmin $true } '*refusing a blind change*'
    Assert ($global:manualMtuTestState.writes.Count -eq 0) 'Blind MTU write'
}
Case 'two eligible adapters are ambiguous even when one MTU is unreadable' {
    $scan = Snapshot @((Record), (Record 'AmneziaVPN 2' 2 $null))
    Assert-Throws { Invoke-ManualOperation -Mode Fix -Snapshot $scan -IsAdmin $true } '*AMBIGUOUS*'
    Assert ($global:manualMtuTestState.writes.Count -eq 0) 'Ambiguous write'
}
Case 'check codes do not request elevation or write' {
    Assert ((Invoke-ManualOperation -Mode Check -Snapshot (Snapshot)).ExitCode -eq 3) 'Wrong WAITING code'
    Assert ((Invoke-ManualOperation -Mode Check -Snapshot (Snapshot @((Record)))).ExitCode -eq 4) 'Wrong drift code'
    Assert ((Invoke-ManualOperation -Mode Check -Snapshot (Snapshot @((Record 'AMNEZIAVPN 1' 2 1280)))).ExitCode -eq 0) 'Wrong healthy code'
    Assert ($global:manualMtuTestState.writes.Count -eq 0 -and $null -eq $global:manualMtuTestState.launch) 'Check modified the system'
}
Case 'already correct fix never needs UAC' {
    $result = Invoke-ManualOperation -Mode Fix -Snapshot (Snapshot @((Record 'AmneziaVPN' 1 1280)))
    Assert ($result.Action -eq 'Complete' -and $result.ExitCode -eq 0 -and $global:manualMtuTestState.writes.Count -eq 0) 'Repeated correction'
}
Case 'unprivileged drift returns pinned elevation target' {
    $result = Invoke-ManualOperation -Mode Fix -Snapshot (Snapshot @((Record)))
    Assert ($result.Action -eq 'Elevate' -and $result.Target.Guid -eq (Record).Guid -and $global:manualMtuTestState.writes.Count -eq 0) 'Wrong elevation target'
}
Case 'failed elevation is not recursively retried' {
    Assert-Throws { Invoke-ManualOperation -Mode Fix -Snapshot (Snapshot @((Record))) -ElevationAttempted } '*no repeated UAC*'
}
Case 'identity is pinned across UAC' {
    $scan = Snapshot @((Record))
    Assert-Throws { Invoke-ManualOperation -Mode Fix -Snapshot $scan -IsAdmin $true -ExpectedGuid (Record 'AmneziaVPN' 2).Guid -ExpectedIndex 1 -ExpectedAlias 'AmneziaVPN' -ExpectedCompartment 1 } '*waiting for UAC*'
    Assert-Throws { Invoke-ManualOperation -Mode Fix -Snapshot $scan -IsAdmin $true -ExpectedGuid (Record).Guid -ExpectedIndex 1 -ExpectedAlias 'AmneziaVPN' -ExpectedCompartment 2 } '*waiting for UAC*'
    Assert ($global:manualMtuTestState.writes.Count -eq 0) 'Wrote to a replacement after UAC'
}
Case 'successful correction changes only active IPv4 MTU parameters' {
    $global:manualMtuTestState.useFixture = $true
    $global:manualMtuTestState.scans.Enqueue((Snapshot @((Record)))); $global:manualMtuTestState.scans.Enqueue((Snapshot @((Record 'AmneziaVPN' 1 1280))))
    $result = Invoke-ManualOperation -Mode Fix -Snapshot (Snapshot @((Record))) -IsAdmin $true
    Assert ($result.ExitCode -eq 0 -and $global:manualMtuTestState.writes.Count -eq 1 -and $global:manualMtuTestState.waits -eq 1 -and $global:manualMtuTestState.scans.Count -eq 0) 'Correction was not verified'
    $write = $global:manualMtuTestState.writes[0]
    Assert ($write.NlMtuBytes -eq 1280 -and $write.PolicyStore -eq 'ActiveStore' -and $write.AddressFamily -eq 'IPv4' -and
        $write.InterfaceIndex -eq 1 -and $write.InterfaceAlias -ceq 'AmneziaVPN' -and $write.CompartmentId -eq 1) 'Wrong setter target'
    Assert (@($write.Keys | Where-Object { $_ -notin @('InterfaceIndex', 'InterfaceAlias', 'AddressFamily', 'CompartmentId', 'NlMtuBytes', 'PolicyStore', 'Confirm', 'ErrorAction') }).Count -eq 0) 'Unexpected network setting passed to setter'
}
Case 'disappearance or a second candidate before writing cancels the write' {
    $global:manualMtuTestState.useFixture = $true
    $global:manualMtuTestState.scans.Enqueue((Snapshot))
    Assert-Throws { Invoke-ManualOperation -Mode Fix -Snapshot (Snapshot @((Record))) -IsAdmin $true } '*changed before*'
    $global:manualMtuTestState.scans.Enqueue((Snapshot @((Record), (Record 'AmneziaVPN 2' 2))))
    Assert-Throws { Invoke-ManualOperation -Mode Fix -Snapshot (Snapshot @((Record))) -IsAdmin $true } '*AMBIGUOUS*'
    Assert ($global:manualMtuTestState.writes.Count -eq 0) 'Wrote after eligibility changed'
}
Case 'GUID/index/alias/compartment changes before writing cancel the write' {
    $global:manualMtuTestState.useFixture = $true
    foreach ($property in @('Guid', 'Index', 'Alias', 'Compartment')) {
        $changed = Record
        switch ($property) { 'Guid' { $changed.Guid = (Record 'AmneziaVPN' 2).Guid }; 'Index' { $changed.Index = 2 }; 'Alias' { $changed.Alias = 'AmneziaVPN 2' }; 'Compartment' { $changed.Compartment = 2 } }
        $global:manualMtuTestState.scans.Enqueue((Snapshot @($changed)))
        Assert-Throws { Invoke-ManualOperation -Mode Fix -Snapshot (Snapshot @((Record))) -IsAdmin $true } '*changed before*'
    }
    Assert ($global:manualMtuTestState.writes.Count -eq 0) 'Wrote to a changed identity'
}
Case 'unreadable fresh MTU cancels the write' {
    $global:manualMtuTestState.useFixture = $true; $global:manualMtuTestState.scans.Enqueue((Snapshot @((Record 'AmneziaVPN' 1 $null))))
    Assert-Throws { Invoke-ManualOperation -Mode Fix -Snapshot (Snapshot @((Record))) -IsAdmin $true } '*Cannot read MTU before*'
    Assert ($global:manualMtuTestState.writes.Count -eq 0) 'Blind fresh write'
}
Case 'another process correcting MTU prevents duplicate writes' {
    $global:manualMtuTestState.useFixture = $true; $global:manualMtuTestState.scans.Enqueue((Snapshot @((Record 'AmneziaVPN' 1 1280))))
    Assert ((Invoke-ManualOperation -Mode Fix -Snapshot (Snapshot @((Record))) -IsAdmin $true).ExitCode -eq 0) 'External correction not accepted'
    Assert ($global:manualMtuTestState.writes.Count -eq 0 -and $global:manualMtuTestState.waits -eq 0) 'Duplicate write'
}
Case 'missing compartment prevents the setter' {
    $global:manualMtuTestState.useFixture = $true; $fresh = Record; $fresh.Compartment = $null
    $initial = Record; $initial.Compartment = $null; $global:manualMtuTestState.scans.Enqueue((Snapshot @($fresh)))
    Assert-Throws { Invoke-ManualOperation -Mode Fix -Snapshot (Snapshot @($initial)) -IsAdmin $true } '*compartment*'
    Assert ($global:manualMtuTestState.writes.Count -eq 0) 'Unknown compartment was written'
}
Case 'setter error is not reported as success' {
    $global:manualMtuTestState.useFixture = $true; $global:manualMtuTestState.setFailure = $true; $global:manualMtuTestState.scans.Enqueue((Snapshot @((Record))))
    Assert-Throws { Invoke-ManualOperation -Mode Fix -Snapshot (Snapshot @((Record))) -IsAdmin $true } '*set access denied*'
    Assert ($global:manualMtuTestState.waits -eq 0) 'Waited after failed setter'
}
Case 'wrong MTU after writing fails verification' {
    $global:manualMtuTestState.useFixture = $true; $global:manualMtuTestState.scans.Enqueue((Snapshot @((Record)))); $global:manualMtuTestState.scans.Enqueue((Snapshot @((Record))))
    Assert-Throws { Invoke-ManualOperation -Mode Fix -Snapshot (Snapshot @((Record))) -IsAdmin $true } '*verification failed*'
}
Case 'disappearance replacement and ambiguity after writing fail verification' {
    $global:manualMtuTestState.useFixture = $true
    foreach ($after in @((Snapshot), (Snapshot @((Record 'AmneziaVPN' 2 1280))), (Snapshot @((Record), (Record 'AmneziaVPN 2' 2))))) {
        $global:manualMtuTestState.scans.Enqueue((Snapshot @((Record)))); $global:manualMtuTestState.scans.Enqueue($after)
        Assert-Throws { Invoke-ManualOperation -Mode Fix -Snapshot (Snapshot @((Record))) -IsAdmin $true }
    }
}
Case 'custom MTU is validated and verified' {
    $global:manualMtuTestState.useFixture = $true; $global:manualMtuTestState.scans.Enqueue((Snapshot @((Record)))); $global:manualMtuTestState.scans.Enqueue((Snapshot @((Record 'AmneziaVPN' 1 1200))))
    Assert ((Invoke-ManualOperation -Mode Fix -Mtu 1200 -Snapshot (Snapshot @((Record))) -IsAdmin $true).ExitCode -eq 0) 'Custom MTU failed'
    Assert ($global:manualMtuTestState.writes[0].NlMtuBytes -eq 1200) 'Wrong custom MTU'
    Assert-Throws { Invoke-ManualOperation -Mode Fix -Mtu 575 -Snapshot (Snapshot @((Record))) }
    Assert-Throws { Invoke-ManualOperation -Mode Fix -Mtu 9001 -Snapshot (Snapshot @((Record))) }
}
Case 'UAC uses a quoted script path and the original adapter identity' {
    $code = Start-ManualElevation -ScriptPath 'C:\test folder\manual-mtu.ps1' -Target (Record 'AMNEZIAVPN 2' 2) -Mtu 1280
    Assert ($code -eq 0 -and $global:manualMtuTestState.disposed -and $global:manualMtuTestState.launch.Verb -eq 'RunAs' -and $global:manualMtuTestState.launch.WindowStyle -eq 'Hidden') 'Wrong UAC process options'
    $arguments = $global:manualMtuTestState.launch.ArgumentList
    Assert ($arguments.Contains('-File "C:\test folder\manual-mtu.ps1"') -and $arguments.Contains('-ExpectedAlias "AMNEZIAVPN 2"') -and
        $arguments.Contains('-ExpectedIndex 2') -and $arguments.Contains('-ExpectedCompartment 1') -and $arguments.Contains('-ExpectedGuid 00000000-0000-0000-0000-000000000002')) 'UAC identity/path was not preserved'
    Assert ($arguments -notlike '*-Probe*' -and $arguments -like '*-NoPause*') 'Background helper should only perform correction'
}
Case 'UAC cancellation and child exit codes are preserved' {
    $global:manualMtuTestState.launchCode = 3
    Assert ((Start-ManualElevation -ScriptPath 'C:\manual.ps1' -Target (Record) -Mtu 1280) -eq 3) 'Lost child code'
    $global:manualMtuTestState.launchFailure = $true
    Assert-Throws { Start-ManualElevation -ScriptPath 'C:\manual.ps1' -Target (Record) -Mtu 1280 } '*UAC cancelled*'
}
Case 'real CLI check pauses exactly once and never elevates or writes' {
    $global:manualMtuTestState.adapters = @((Adapter)); $global:manualMtuTestState.ipRows = @((IpRow 'AmneziaVPN' 1 1280)); $global:manualMtuTestState.answers.Enqueue('')
    $output = @(& (Join-Path $root 'tools\manual-mtu.ps1') -Mode Check 6>&1)
    Assert ($LASTEXITCODE -eq 0 -and $global:manualMtuTestState.prompts.Count -eq 1 -and $global:manualMtuTestState.prompts[0] -eq 'Press Enter to close') 'Wrong pause/code in CLI'
    Assert ($null -eq $global:manualMtuTestState.launch -and $global:manualMtuTestState.writes.Count -eq 0) 'Check invoked UAC or setter'
    Assert (($output | Out-String) -like '*[[]PASS[]]*IPv4 MTU = 1280*') 'CLI omitted healthy MTU'
}
Case 'real menu exit never claims a successful MTU check' {
    $global:manualMtuTestState.answers.Enqueue('4'); $global:manualMtuTestState.answers.Enqueue('')
    $output = @(& (Join-Path $root 'tools\manual-mtu.ps1') -Mode Menu 6>&1)
    $text = $output | Out-String
    Assert ($LASTEXITCODE -eq 0 -and $global:manualMtuTestState.prompts.Count -eq 2 -and $global:manualMtuTestState.adapterReads -eq 0) 'Cancel should not inspect network'
    Assert ($text -like '*Cancelled*' -and $text -notlike '*[[]PASS[]]*') 'Cancel falsely claimed MTU success'
}
Write-Host "[PASS] Manual MTU: $($global:manualMtuTestState.testCount) behavioral tests; all network setters, UAC and waits are mocked"

Remove-Variable -Name manualMtuTestState -Scope Global
