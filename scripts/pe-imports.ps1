#requires -version 5.1
# PE imports are read as data. No EXE execution, SDK, Python or external DLL is needed.
# https://learn.microsoft.com/en-us/windows/win32/debug/pe-format
function Assert-StandaloneImports([string[]]$Imports) {
    if ($Imports.Count -eq 0) { throw 'No PE imports found' }
    $systemDlls = @('advapi32.dll', 'bcrypt.dll', 'bcryptprimitives.dll', 'iphlpapi.dll',
        'kernel32.dll', 'kernelbase.dll', 'ntdll.dll', 'ole32.dll', 'psapi.dll',
        'secur32.dll', 'shell32.dll', 'user32.dll', 'userenv.dll', 'ws2_32.dll')
    foreach ($dll in $Imports) {
        if ($dll -match '^(vcruntime|msvcp|msvcr|concrt|ucrtbase|api-ms-win-crt-)' -or $dll -eq 'msvcrt.dll') {
            throw "Non-standalone EXE imports C/C++ runtime: $dll. Build with +crt-static."
        }
        if ($dll -notin $systemDlls -and $dll -notmatch '^(api-ms-win-core-|api-ms-win-security-|ext-ms-win-).+\.dll$') {
            throw "Non-system DLL import requires review: $dll"
        }
    }
}

function Get-PeImports([string]$Path) {
    $image = [IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $Path).Path)
    function Assert-Range([long]$Offset, [long]$Size) {
        if ($Offset -lt 0 -or $Size -lt 0 -or $Offset + $Size -gt $image.LongLength) {
            throw 'Invalid PE: file offset is out of bounds'
        }
    }
    function Read-U16([long]$Offset) { Assert-Range $Offset 2; [BitConverter]::ToUInt16($image, $Offset) }
    function Read-U32([long]$Offset) { Assert-Range $Offset 4; [BitConverter]::ToUInt32($image, $Offset) }
    function Read-U64([long]$Offset) { Assert-Range $Offset 8; [BitConverter]::ToUInt64($image, $Offset) }
    if ((Read-U16 0) -ne 0x5a4d) { throw 'Invalid PE: DOS signature' }
    $peOffset = Read-U32 0x3c
    if ((Read-U32 $peOffset) -ne 0x4550) { throw 'Invalid PE signature' }
    $sectionCount = Read-U16 ($peOffset + 6)
    $optionalSize = Read-U16 ($peOffset + 20)
    $optional = $peOffset + 24
    if ((Read-U16 $optional) -ne 0x20b -or $optionalSize -lt 112) { throw 'Expected PE32+' }
    Assert-Range $optional $optionalSize
    $directoryCount = Read-U32 ($optional + 108)
    $headersSize = Read-U32 ($optional + 60)
    $imageBase = Read-U64 ($optional + 24)
    $sections = $optional + $optionalSize
    Assert-Range $sections ($sectionCount * 40)
    function Get-FileOffset([long]$Rva) {
        if ($Rva -lt $headersSize) { Assert-Range $Rva 1; return $Rva }
        for ($i = 0; $i -lt $sectionCount; $i++) {
            $section = $sections + $i * 40
            $address = Read-U32 ($section + 12)
            $rawSize = Read-U32 ($section + 16)
            $rawOffset = Read-U32 ($section + 20)
            if ($Rva -ge $address -and $Rva - $address -lt $rawSize) {
                $offset = [long]$rawOffset + $Rva - $address
                Assert-Range $offset 1
                return $offset
            }
        }
        throw "Invalid PE: unmapped RVA $Rva"
    }
    function Read-DllName([long]$Rva) {
        $offset = Get-FileOffset $Rva
        $end = $offset
        while ($end -lt $image.LongLength -and $image[$end] -ne 0 -and $end - $offset -lt 260) { $end++ }
        if ($end -eq $image.LongLength -or $end - $offset -ge 260) { throw 'Invalid PE DLL name' }
        $name = [Text.Encoding]::ASCII.GetString($image, $offset, $end - $offset).ToLowerInvariant()
        if ($name -notmatch '^[a-z0-9._-]+\.dll$') { throw 'Invalid PE import name' }
        return $name
    }
    $names = New-Object 'Collections.Generic.List[string]'
    foreach ($directory in @(1, 13)) {
        if ($directory -ge $directoryCount) { continue }
        if (112 + ($directory + 1) * 8 -gt $optionalSize) { throw 'Invalid PE data directories' }
        $rva = Read-U32 ($optional + 112 + $directory * 8)
        $size = Read-U32 ($optional + 116 + $directory * 8)
        if ($rva -eq 0 -and $size -eq 0) { continue }
        if ($rva -eq 0 -or $size -eq 0) { throw 'Invalid PE import directory' }
        $descriptorSize = if ($directory -eq 1) { 20 } else { 32 }
        $terminated = $false
        for ($used = 0; $used + $descriptorSize -le $size; $used += $descriptorSize) {
            $descriptor = Get-FileOffset ($rva + $used)
            Assert-Range $descriptor $descriptorSize
            $zero = $true
            for ($word = 0; $word -lt $descriptorSize; $word += 4) {
                if ((Read-U32 ($descriptor + $word)) -ne 0) { $zero = $false }
            }
            if ($zero) { $terminated = $true; break }
            if ($directory -eq 1) {
                $nameRva = Read-U32 ($descriptor + 12)
            } else {
                $attributes = Read-U32 $descriptor
                $nameRva = [long](Read-U32 ($descriptor + 4))
                if ($attributes -eq 0) { $nameRva -= $imageBase }
                elseif ($attributes -ne 1) { throw 'Invalid PE delay-import attributes' }
            }
            if ($nameRva -le 0) { throw 'Invalid PE import name RVA' }
            $names.Add((Read-DllName $nameRva))
        }
        if (-not $terminated) { throw 'Unterminated PE import directory' }
    }
    $names | Sort-Object -Unique
}
