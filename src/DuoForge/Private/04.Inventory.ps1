function Test-DuoForgeUtf8File {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    try {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        $null = [System.Text.UTF8Encoding]::new($false, $true).GetString($bytes)
        return $true
    }
    catch [System.Text.DecoderFallbackException] {
        return $false
    }
}

function Get-DuoForgeMarkdownInventoryInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Directory,

        [long]$MaximumFileBytes = 2097152,

        [switch]$Recurse
    )

    $fullDirectory = Resolve-DuoForgePathInternal -Path $Directory -ExpectedType Directory
    $files = Get-ChildItem -LiteralPath $fullDirectory -File -Filter '*.md' -Recurse:$Recurse -Force |
        Sort-Object FullName

    $items = foreach ($file in $files) {
        $reason = $null
        $included = $true
        if (($file.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            $included = $false
            $reason = 'reparse-point'
        }
        elseif ($file.Length -gt $MaximumFileBytes) {
            $included = $false
            $reason = 'file-size-limit'
        }
        elseif (-not (Test-DuoForgeUtf8File -Path $file.FullName)) {
            $included = $false
            $reason = 'invalid-utf8'
        }

        [ordered]@{
            path = $file.FullName
            relativePath = [System.IO.Path]::GetRelativePath($fullDirectory, $file.FullName)
            bytes = [long]$file.Length
            sha256 = Get-DuoForgeSha256 -Path $file.FullName
            included = $included
            exclusionReason = $reason
        }
    }

    $includedItems = @($items | Where-Object { $_.included })
    $excludedItems = @($items | Where-Object { -not $_.included })
    [long]$includedBytes = 0
    [long]$totalBytes = 0
    foreach ($inventoryItem in @($items)) {
        $totalBytes += [long]$inventoryItem.bytes
        if ($inventoryItem.included) { $includedBytes += [long]$inventoryItem.bytes }
    }
    return [ordered]@{
        root = $fullDirectory
        generatedAt = Get-DuoForgeUtcNow
        files = @($items)
        includedFiles = $includedItems.Count
        excludedFiles = $excludedItems.Count
        includedBytes = $includedBytes
        totalBytes = $totalBytes
    }
}

function Assert-DuoForgeMarkdownFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [long]$MaximumBytes = 2097152
    )

    $fullPath = Resolve-DuoForgePathInternal -Path $Path -ExpectedType File
    if ([System.IO.Path]::GetExtension($fullPath) -ine '.md') {
        throw (New-DuoForgeException -Code 'DF-INPUT-NOT-MARKDOWN' -Message "v1 문서 입력은 Markdown(.md)이어야 합니다: $fullPath")
    }

    $item = Get-Item -LiteralPath $fullPath -Force
    if ($item.Length -gt $MaximumBytes) {
        throw (New-DuoForgeException -Code 'DF-INPUT-SIZE-LIMIT' -Message "문서가 기본 제한 $MaximumBytes 바이트를 초과했습니다: $fullPath")
    }
    if (-not (Test-DuoForgeUtf8File -Path $fullPath)) {
        throw (New-DuoForgeException -Code 'DF-INPUT-UTF8' -Message "문서가 유효한 UTF-8이 아닙니다: $fullPath")
    }
    if (@(Get-DuoForgeReparsePointsInPath -Path $fullPath).Count -gt 0) {
        throw (New-DuoForgeException -Code 'DF-PATH-REPARSE' -Message "입력 경로에 정션 또는 심볼릭 링크가 포함되어 있습니다: $fullPath")
    }

    return [ordered]@{
        path = $fullPath
        bytes = [long]$item.Length
        sha256 = Get-DuoForgeSha256 -Path $fullPath
        validUtf8 = $true
    }
}

function New-DuoForgeFileSnapshots {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DestinationDirectory,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary[]]$Files
    )

    [System.IO.Directory]::CreateDirectory($DestinationDirectory) | Out-Null
    $records = [System.Collections.Generic.List[object]]::new()
    $index = 0
    foreach ($file in $Files) {
        $index++
        $extension = [System.IO.Path]::GetExtension([string]$file.path)
        $snapshotName = 'S{0:D6}{1}' -f $index, $extension.ToLowerInvariant()
        $snapshotPath = Join-Path $DestinationDirectory $snapshotName
        [System.IO.File]::Copy([string]$file.path, $snapshotPath, $false)
        $snapshotHash = Get-DuoForgeSha256 -Path $snapshotPath
        if ($snapshotHash -ne [string]$file.sha256) {
            throw (New-DuoForgeException -Code 'DF-SNAPSHOT-HASH' -Message "스냅샷 해시가 원본과 다릅니다: $($file.path)")
        }

        $records.Add([ordered]@{
            sourcePath = [string]$file.path
            sourceHash = [string]$file.sha256
            snapshotName = $snapshotName
            snapshotPath = $snapshotPath
            snapshotHash = $snapshotHash
            bytes = [long]$file.bytes
        })
    }

    return @($records)
}
