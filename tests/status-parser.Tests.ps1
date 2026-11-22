#requires -version 5.1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts\status-parser.ps1')
foreach ($alias in @('AmneziaVPN', 'AmneziaVPN 1', 'AMNEZIAVPN 2', 'amneziavpn 12', 'AmneziaVPN 4294967295')) {
    foreach ($level in @('PASS', 'WARN')) {
        $text = "[$level] $alias IPv4 MTU = 1376, expected 1280; LUID=0x0000000000000042 ifIndex=4294967295; description=`"WireGuard Tunnel`" type=53"
        $parsed = ConvertFrom-GuardStatus $text
        if ($parsed.Alias -cne $alias -or $parsed.Mtu -ne 1376 -or $parsed.Index -ne [uint32]::MaxValue -or
            $parsed.Luid -ne '0x0000000000000042') { throw "Incorrect status fields for $alias" }
    }
}
foreach ($alias in @('AmneziaVPN +2', 'AmneziaVPN 0', 'AmneziaVPN 02', 'AmneziaVPN  2', 'AmneziaVPN 4294967296', 'Ethernet 2')) {
    $parsed = ConvertFrom-GuardStatus "[PASS] $alias IPv4 MTU = 1280; LUID=0x42 ifIndex=2"
    if ($null -ne $parsed.Alias) { throw "Invalid alias parsed: $alias" }
}
foreach ($text in @('[WAITING] no eligible adapter', '[FAIL] AMBIGUOUS: two active adapters',
    '[PASS] AmneziaVPN 2 IPv4 MTU = 4294967296; LUID=0x42 ifIndex=2')) {
    if ($null -ne (ConvertFrom-GuardStatus $text).Alias) { throw 'Non-adapter state produced adapter fields' }
}
function Fake-Healthy { $global:LASTEXITCODE = 0; '[PASS] AmneziaVPN 2 IPv4 MTU = 1280; LUID=0x42 ifIndex=2' }
function Fake-Ambiguous { $global:LASTEXITCODE = 1; Write-Error '[FAIL] AMBIGUOUS: two active adapters' }
$healthy = Read-GuardStatus 'Fake-Healthy'
if ($healthy.ExitCode -ne 0 -or (ConvertFrom-GuardStatus $healthy.Text).Alias -ne 'AmneziaVPN 2') { throw 'Healthy status capture failed' }
$ambiguous = Read-GuardStatus 'Fake-Ambiguous'
if ($ambiguous.ExitCode -ne 1 -or $ambiguous.Text -notlike '*AMBIGUOUS*') { throw 'Failed status capture did not preserve error' }
Write-Host '[PASS] Status parser: real aliases/case, suffix 1, UInt32 bounds, invalid names and nonterminating ambiguity capture'
