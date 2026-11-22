#requires -version 5.1
param(
    [Parameter(Mandatory = $true)][string]$BinaryPath
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$binary = (Resolve-Path -LiteralPath $BinaryPath).Path
$manifest = Get-Content -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'Cargo.toml') -Raw
$version = [regex]::Match($manifest, '(?m)^version\s*=\s*"([^"]+)"').Groups[1].Value
if (-not $version) { throw 'Package version not found in Cargo.toml' }
$info = [Diagnostics.FileVersionInfo]::GetVersionInfo($binary)
$expected = @{
    ProductName = 'MTU Guard'
    CompanyName = 'Flamy Studio'
    FileDescription = 'MTU Guard - IPv4 MTU service for Withen Network'
    FileVersion = $version
    ProductVersion = $version
    OriginalFilename = 'withen-mtu-guard.exe'
    LegalCopyright = 'Copyright (c) 2026 Flamy Studio'
}
foreach ($field in $expected.Keys) {
    if ($info.$field -cne $expected[$field]) { throw "Incorrect EXE ${field}: $($info.$field)" }
}

$bytes = [IO.File]::ReadAllBytes($binary)
if ($bytes.Length -lt 64 -or [BitConverter]::ToUInt16($bytes, 0) -ne 0x5a4d) { throw 'Invalid DOS header' }
$pe = [BitConverter]::ToInt32($bytes, 0x3c)
if ($pe -lt 64 -or $pe + 26 -gt $bytes.Length -or [BitConverter]::ToUInt32($bytes, $pe) -ne 0x4550) {
    throw 'Invalid PE header'
}
if ([BitConverter]::ToUInt16($bytes, $pe + 4) -ne 0x8664 -or
    [BitConverter]::ToUInt16($bytes, $pe + 24) -ne 0x20b) { throw 'Expected a Windows x64 PE32+ binary' }

. (Join-Path $PSScriptRoot 'pe-imports.ps1')
$imports = @(Get-PeImports $binary)
Assert-StandaloneImports $imports
Write-Host "[PASS] Standalone EXE: normal/delay imports contain only Windows DLLs ($($imports -join ', '))"

# Map only resources, without executing the image or calling DllMain.
# https://learn.microsoft.com/en-us/windows/win32/api/libloaderapi/nf-libloaderapi-loadlibraryexw
if (-not ('MtuGuard.BuildResources' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace MtuGuard {
    public static class BuildResources {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern IntPtr LoadLibraryExW(string path, IntPtr file, uint flags);
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern IntPtr FindResourceW(IntPtr module, IntPtr name, IntPtr type);
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern uint SizeofResource(IntPtr module, IntPtr resource);
        [DllImport("kernel32.dll")]
        public static extern bool FreeLibrary(IntPtr module);
    }
}
'@
}
$module = [MtuGuard.BuildResources]::LoadLibraryExW($binary, [IntPtr]::Zero, 0x22)
if ($module -eq [IntPtr]::Zero) { throw "Cannot load EXE resources: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())" }
try {
    # winresource uses ID 1 for the main icon group and application manifest.
    foreach ($kind in @(14, 24)) {
        $resource = [MtuGuard.BuildResources]::FindResourceW($module, [IntPtr]1, [IntPtr]$kind)
        if ($resource -eq [IntPtr]::Zero -or [MtuGuard.BuildResources]::SizeofResource($module, $resource) -eq 0) {
            throw "Missing EXE resource type $kind (14=icon group, 24=manifest)"
        }
    }
} finally {
    [void][MtuGuard.BuildResources]::FreeLibrary($module)
}

$pdb = Join-Path ([IO.Path]::GetDirectoryName($binary)) 'withen_mtu_guard.pdb'
if (-not (Test-Path -LiteralPath $pdb -PathType Leaf)) { throw "Missing PDB: $pdb" }
$stream = [IO.File]::OpenRead($pdb)
try {
    $header = New-Object byte[] 24
    if ($stream.Read($header, 0, $header.Length) -ne $header.Length -or
        [Text.Encoding]::ASCII.GetString($header) -cne 'Microsoft C/C++ MSF 7.00') {
        throw 'Invalid MSVC PDB header'
    }
} finally {
    $stream.Dispose()
}
Write-Host '[PASS] Windows x64 EXE: metadata, icon, manifest and PDB verified'
