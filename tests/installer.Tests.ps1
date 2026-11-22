#requires -version 5.1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'scripts\service-common.ps1')
$script:messages = New-Object 'Collections.Generic.List[string]'
function Write-Host([string]$Object) { $script:messages.Add($Object) }
function Fake-Waiting { $global:LASTEXITCODE = 3; '[WAITING] interface absent' }
function Fake-Healthy { $global:LASTEXITCODE = 0; '[PASS] MTU 1280' }
function Fake-Drift { $global:LASTEXITCODE = 4; '[WARN] MTU 1376' }
$script:attempts = 0
function Fake-Converging {
    $script:attempts++
    if ($script:attempts -lt 2) { Fake-Drift } else { Fake-Healthy }
}
function Expect-Rejection([scriptblock]$Action, [string]$Pattern) {
    try { & $Action } catch { if ($_.Exception.Message -like $Pattern) { return }; throw }
    throw "Expected rejection matching: $Pattern"
}
Wait-GuardMtu -BinaryPath 'Fake-Waiting'
if ($script:messages | Where-Object { $_ -like '*MTU 1280 verified*' }) { throw 'Installer claims MTU success while waiting' }
Wait-GuardMtu -BinaryPath 'Fake-Converging'
if ($script:attempts -ne 2 -or -not ($script:messages | Where-Object { $_ -like '*MTU 1280 verified*' })) {
    throw 'Installer did not wait for actual MTU convergence'
}
Expect-Rejection { Wait-GuardMtu -BinaryPath 'Fake-Drift' -TimeoutSeconds 0 } '*did not converge*'
$fixtureRoot = Join-Path $root ('target\installer-fixture-' + [Guid]::NewGuid().ToString('N'))
$expected = Join-Path $fixtureRoot 'WITHEN\MTU Guard'
Assert-GuardDirectory $expected $fixtureRoot
Expect-Rejection { Assert-GuardDirectory $fixtureRoot $fixtureRoot } '*unexpected MTU Guard directory*'
$elsewhere = Join-Path $fixtureRoot 'unrelated'
New-Item -ItemType Directory -Path $elsewhere -Force | Out-Null
New-Item -ItemType Directory -Path (Split-Path $expected -Parent) -Force | Out-Null
New-Item -ItemType Junction -Path $expected -Target $elsewhere | Out-Null
Expect-Rejection { Assert-GuardDirectory $expected $fixtureRoot } '*junction or symbolic link*'
Microsoft.PowerShell.Utility\Write-Host '[PASS] Installer: WAITING, delayed convergence, timeout, directory boundary and junction rejection'
