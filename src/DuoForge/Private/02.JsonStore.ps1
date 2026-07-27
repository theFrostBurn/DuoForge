function Write-DuoForgeJsonAtomic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        $Value
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $directory = [System.IO.Path]::GetDirectoryName($fullPath)
    if (-not [string]::IsNullOrWhiteSpace($directory)) {
        [System.IO.Directory]::CreateDirectory($directory) | Out-Null
    }

    $tempPath = "$fullPath.$([Guid]::NewGuid().ToString('N')).tmp"
    $json = $Value | ConvertTo-Json -Depth 100
    $encoding = [System.Text.UTF8Encoding]::new($false)

    try {
        $stream = [System.IO.FileStream]::new(
            $tempPath,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None,
            4096,
            [System.IO.FileOptions]::WriteThrough
        )
        try {
            $bytes = $encoding.GetBytes($json + [Environment]::NewLine)
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
        }
        finally {
            $stream.Dispose()
        }

        [System.IO.File]::Move($tempPath, $fullPath, $true)
    }
    finally {
        if (Test-Path -LiteralPath $tempPath) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Write-DuoForgeTextAtomic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [AllowEmptyString()][Parameter(Mandatory)][string]$Text
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $directory = [System.IO.Path]::GetDirectoryName($fullPath)
    if (-not [string]::IsNullOrWhiteSpace($directory)) {
        [System.IO.Directory]::CreateDirectory($directory) | Out-Null
    }

    $tempPath = "$fullPath.$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        [System.IO.File]::WriteAllText($tempPath, $Text, [System.Text.UTF8Encoding]::new($false))
        [System.IO.File]::Move($tempPath, $fullPath, $true)
    }
    finally {
        if (Test-Path -LiteralPath $tempPath) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Read-DuoForgeJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw (New-DuoForgeException -Code 'DF-JSON-NOT-FOUND' -Message "JSON 파일을 찾을 수 없습니다: $Path")
    }

    try {
        $text = [System.IO.File]::ReadAllText($Path, [System.Text.UTF8Encoding]::new($false, $true))
        return $text | ConvertFrom-Json -Depth 100
    }
    catch {
        throw (New-DuoForgeException -Code 'DF-JSON-INVALID' -Message "JSON 파일이 손상되었거나 UTF-8이 아닙니다: $Path")
    }
}

function Add-DuoForgeJsonLine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        $Value
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($fullPath)) | Out-Null
    $json = $Value | ConvertTo-Json -Depth 100 -Compress
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($json + [Environment]::NewLine)
    $stream = [System.IO.FileStream]::new(
        $fullPath,
        [System.IO.FileMode]::Append,
        [System.IO.FileAccess]::Write,
        [System.IO.FileShare]::Read,
        4096,
        [System.IO.FileOptions]::WriteThrough
    )
    try {
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    }
    finally {
        $stream.Dispose()
    }
}

function Read-DuoForgeJsonLines {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$AllowMissing
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        if ($AllowMissing) { return @() }
        throw (New-DuoForgeException -Code 'DF-JSONL-NOT-FOUND' -Message "JSONL 파일을 찾을 수 없습니다: $Path")
    }
    $records = [System.Collections.Generic.List[object]]::new()
    $lineNumber = 0
    foreach ($line in [System.IO.File]::ReadLines($Path, [System.Text.UTF8Encoding]::new($false, $true))) {
        $lineNumber++
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $records.Add((ConvertTo-DuoForgeHashtable -InputObject ($line | ConvertFrom-Json -Depth 100))) }
        catch { throw (New-DuoForgeException -Code 'DF-JSONL-INVALID' -Message "JSONL $lineNumber 번째 줄이 손상되었습니다: $Path") }
    }
    return @($records)
}

function Get-DuoForgeSha256 {
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Path')]
        [string]$Path,

        [Parameter(Mandatory, ParameterSetName = 'Bytes')]
        [byte[]]$Bytes
    )

    if ($PSCmdlet.ParameterSetName -eq 'Path') {
        $stream = [System.IO.File]::OpenRead([System.IO.Path]::GetFullPath($Path))
        try {
            $hashBytes = [System.Security.Cryptography.SHA256]::HashData($stream)
        }
        finally {
            $stream.Dispose()
        }
    }
    else {
        $hashBytes = [System.Security.Cryptography.SHA256]::HashData($Bytes)
    }

    return 'sha256:' + [Convert]::ToHexString($hashBytes).ToLowerInvariant()
}
