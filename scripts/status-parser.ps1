#requires -version 5.1
function ConvertFrom-GuardStatus([string]$Text) {
    $result = [pscustomobject]@{ Alias = $null; Mtu = $null; Luid = $null; Index = $null }
    $pattern = '^\[(?:PASS|WARN)\] (?<alias>AmneziaVPN(?: (?<suffix>[1-9][0-9]*))?) IPv4 MTU = (?<mtu>[0-9]+)[^\r\n]*?; LUID=(?<luid>0x[0-9a-f]{1,16}) ifIndex=(?<index>[0-9]+)(?:;|$)'
    $options = [Text.RegularExpressions.RegexOptions]::IgnoreCase -bor
        [Text.RegularExpressions.RegexOptions]::Multiline -bor [Text.RegularExpressions.RegexOptions]::CultureInvariant
    $match = [regex]::Match($Text, $pattern, $options)
    if (-not $match.Success) { return $result }
    [uint32]$mtu = 0
    [uint32]$index = 0
    [uint32]$suffix = 0
    if (-not [uint32]::TryParse($match.Groups['mtu'].Value, [ref]$mtu) -or
        -not [uint32]::TryParse($match.Groups['index'].Value, [ref]$index)) { return $result }
    if ($match.Groups['suffix'].Success -and
        -not [uint32]::TryParse($match.Groups['suffix'].Value, [ref]$suffix)) { return $result }
    $result.Alias = $match.Groups['alias'].Value
    $result.Mtu = $mtu
    $result.Luid = $match.Groups['luid'].Value
    $result.Index = $index
    return $result
}

function Read-GuardStatus([string]$BinaryPath) {
    # Ambiguity/API errors must be recorded, not terminate a monitoring session.
    $ErrorActionPreference = 'Continue'
    $output = @(& $BinaryPath status 2>&1)
    $code = $LASTEXITCODE
    if ($null -eq $code -or ($code -eq 0 -and @($output | Where-Object { $_ -is [Management.Automation.ErrorRecord] }).Count -gt 0)) { $code = 1 }
    $text = ($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
    [pscustomobject]@{ Text = $text.Trim(); ExitCode = $code }
}
