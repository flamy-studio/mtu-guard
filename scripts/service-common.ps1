#requires -version 5.1
function Get-GuardPaths {
    $programRoot = [Environment]::GetFolderPath('ProgramFiles')
    $dataRoot = [Environment]::GetFolderPath('CommonApplicationData')
    [pscustomobject]@{
        ProgramRoot = $programRoot
        DataRoot = $dataRoot
        Install = (Join-Path $programRoot 'WITHEN\MTU Guard')
        Logs = (Join-Path $dataRoot 'WITHEN\MTU Guard')
    }
}

function Assert-GuardDirectory([string]$Directory, [string]$Root) {
    $absoluteRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $expected = [IO.Path]::GetFullPath((Join-Path $absoluteRoot 'WITHEN\MTU Guard'))
    $absolute = [IO.Path]::GetFullPath($Directory).TrimEnd('\')
    if (-not $absolute.Equals($expected, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing unexpected MTU Guard directory: $absolute"
    }
    foreach ($entry in @($absoluteRoot, (Join-Path $absoluteRoot 'WITHEN'), $absolute)) {
        if (Test-Path -LiteralPath $entry) {
            $item = Get-Item -LiteralPath $entry -Force
            if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                throw "Refusing a file, junction or symbolic link in installation path: $entry"
            }
        }
    }
}

function Wait-GuardMtu([string]$BinaryPath, [int]$TimeoutSeconds = 15) {
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $message = (& $BinaryPath check 2>&1 | Out-String).Trim()
        $code = $LASTEXITCODE
        if ($code -eq 0) {
            Write-Host $message
            Write-Host '[PASS] IPv4 MTU 1280 verified through Windows API'
            return
        }
        if ($code -eq 3) {
            Write-Host $message
            Write-Host '[WAITING] Service installed; MTU will be checked when the VPN interface appears'
            return
        }
        if ($code -ne 4) { throw "Health check failed (exit $code): $message" }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Service is running but MTU did not converge within $TimeoutSeconds seconds: $message"
}
