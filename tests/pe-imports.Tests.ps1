#requires -version 5.1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'scripts\pe-imports.ps1')
$fixtures = Join-Path $root ('target\pe-fixtures-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixtures -Force | Out-Null

function New-PeFixture([string]$DirectDll, [string]$DelayDll, [switch]$CorruptName) {
    $data = New-Object byte[] 2048
    function U16([int]$Offset, [uint16]$Value) { [BitConverter]::GetBytes($Value).CopyTo($data, $Offset) }
    function U32([int]$Offset, [uint32]$Value) { [BitConverter]::GetBytes($Value).CopyTo($data, $Offset) }
    U16 0 0x5a4d
    U32 0x3c 128
    U32 128 0x4550
    U16 132 0x8664
    U16 134 1
    U16 148 240
    $optional = 152
    U16 $optional 0x20b
    U32 ($optional + 60) 512
    U32 ($optional + 108) 16
    U32 ($optional + 120) 0x1000
    U32 ($optional + 124) 40
    U32 ($optional + 216) 0x1100
    U32 ($optional + 220) 64
    $section = $optional + 240
    U32 ($section + 8) 1536
    U32 ($section + 12) 0x1000
    U32 ($section + 16) 1536
    U32 ($section + 20) 512
    U32 (512 + 12) 0x1080
    if ($CorruptName) { U32 (512 + 12) 0x500000 }
    [Text.Encoding]::ASCII.GetBytes($DirectDll + [char]0).CopyTo($data, 640)
    U32 768 1
    U32 772 0x1180
    [Text.Encoding]::ASCII.GetBytes($DelayDll + [char]0).CopyTo($data, 896)
    $path = Join-Path $fixtures ([Guid]::NewGuid().ToString('N') + '.bin')
    [IO.File]::WriteAllBytes($path, $data)
    return $path
}
function Expect-Rejection([scriptblock]$Action, [string]$Pattern) {
    try { & $Action } catch {
        if ($_.Exception.Message -like $Pattern) { return }
        throw
    }
    throw "Expected rejection matching: $Pattern"
}

$valid = @(Get-PeImports (New-PeFixture 'kernel32.dll' 'iphlpapi.dll'))
if ($valid.Count -ne 2 -or 'kernel32.dll' -notin $valid -or 'iphlpapi.dll' -notin $valid) {
    throw 'Normal and delay imports were not both found'
}
Assert-StandaloneImports $valid
$crt = @(Get-PeImports (New-PeFixture 'VCRUNTIME140.dll' 'kernel32.dll'))
Expect-Rejection { Assert-StandaloneImports $crt } '*C/C++ runtime*'
$delayed = @(Get-PeImports (New-PeFixture 'kernel32.dll' 'MSVCP140.dll'))
Expect-Rejection { Assert-StandaloneImports $delayed } '*C/C++ runtime*'
$external = @(Get-PeImports (New-PeFixture 'kernel32.dll' 'unexpected-plugin.dll'))
Expect-Rejection { Assert-StandaloneImports $external } '*Non-system DLL*'
$broken = New-PeFixture 'kernel32.dll' 'iphlpapi.dll' -CorruptName
Expect-Rejection { Get-PeImports $broken } '*unmapped RVA*'
Write-Host '[PASS] PE import guard: Windows DLLs, direct/delayed CRT, external DLL, malformed RVA'
