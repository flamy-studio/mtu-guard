#requires -version 5.1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Set-Location $PSScriptRoot
& (Join-Path $PSScriptRoot 'tests\pe-imports.Tests.ps1')
& (Join-Path $PSScriptRoot 'tests\installer.Tests.ps1')
& (Join-Path $PSScriptRoot 'tests\status-parser.Tests.ps1')
& (Join-Path $PSScriptRoot 'tests\manual-mtu.Tests.ps1')
$cargo = 'cargo.exe'
if (-not (Get-Command $cargo -ErrorAction SilentlyContinue)) {
    $cargo = Join-Path $env:USERPROFILE '.cargo\bin\cargo.exe'
    if (-not (Test-Path -LiteralPath $cargo -PathType Leaf)) {
        throw 'Cargo not found. Install Rust stable with the x86_64-pc-windows-msvc toolchain.'
    }
}
& $cargo fmt --all -- --check
if ($LASTEXITCODE -ne 0) { throw 'cargo fmt failed' }
& $cargo test --locked --all-targets --target x86_64-pc-windows-msvc
if ($LASTEXITCODE -ne 0) { throw 'cargo test failed' }
& $cargo clippy --locked --all-targets --target x86_64-pc-windows-msvc -- -D warnings
if ($LASTEXITCODE -ne 0) { throw 'cargo clippy failed' }
& $cargo build --locked --release --target x86_64-pc-windows-msvc
if ($LASTEXITCODE -ne 0) { throw 'cargo build failed' }
$exe = Join-Path $PSScriptRoot 'target\x86_64-pc-windows-msvc\release\withen-mtu-guard.exe'
& (Join-Path $PSScriptRoot 'scripts\verify-build.ps1') -BinaryPath $exe
Copy-Item -LiteralPath $exe -Destination (Join-Path $PSScriptRoot 'withen-mtu-guard.exe') -Force
Copy-Item -LiteralPath ([IO.Path]::Combine([IO.Path]::GetDirectoryName($exe), 'withen_mtu_guard.pdb')) -Destination $PSScriptRoot -Force
$hashes = foreach ($name in @('withen-mtu-guard.exe', 'withen_mtu_guard.pdb')) {
    $hash = (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $name) -Algorithm SHA256).Hash.ToLowerInvariant()
    "$hash  $name"
}
$hashes | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'SHA256SUMS.txt') -Encoding ascii
Write-Host '[PASS] MTU Guard EXE and PDB built in repository root. Run install.cmd to install.'
