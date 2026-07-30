function Get-DuoForgeValidationSourceRecordsInternal {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$ValidationResult)

    $records = [System.Collections.Generic.List[object]]::new()
    if ([string]$ValidationResult.request.mode -eq 'shared-document') {
        $records.Add($ValidationResult.inputs.primary)
    }
    elseif ([string]$ValidationResult.request.mode -in @('document-merge', 'dual-document')) {
        $seen = @{}
        foreach ($documentId in @('A', 'B')) {
            $primary = $ValidationResult.inputs.documents[$documentId].primary
            if (-not $seen.ContainsKey([string]$primary.path)) { $records.Add($primary); $seen[[string]$primary.path] = $true }
            foreach ($file in @($ValidationResult.inputs.documents[$documentId].context.files | Where-Object { [bool]$_.included })) {
                if (-not $seen.ContainsKey([string]$file.path)) { $records.Add($file); $seen[[string]$file.path] = $true }
            }
        }
    }
    return @($records)
}

function Get-DuoForgeValidationSourceDescriptorsInternal {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$ValidationResult)

    $descriptors = [System.Collections.Generic.List[object]]::new()
    $seen = @{}
    $addSource = {
        param($Source, [string]$Role, [string]$DocumentId)
        $path = [string]$Source.path
        if ([string]::IsNullOrWhiteSpace($path) -or $seen.ContainsKey($path)) { return }
        $seen[$path] = $true
        $ordinal = $descriptors.Count + 1
        $descriptors.Add([ordered]@{
            sourceOrdinal = $ordinal
            sourceId = 'source-{0:D3}' -f $ordinal
            path = $path
            sourceSha256 = [string]$Source.sha256
            bytes = [long]$Source.bytes
            role = $Role
            documentId = $DocumentId
        })
    }.GetNewClosure()

    if ([string]$ValidationResult.request.mode -eq 'shared-document') {
        & $addSource $ValidationResult.inputs.primary 'shared-primary' 'brief'
    }
    elseif ([string]$ValidationResult.request.mode -in @('document-merge', 'dual-document')) {
        foreach ($documentId in @('A', 'B')) {
            & $addSource $ValidationResult.inputs.documents[$documentId].primary "document-$($documentId.ToLowerInvariant())-primary" $documentId
            foreach ($file in @($ValidationResult.inputs.documents[$documentId].context.files | Where-Object { [bool]$_.included })) {
                & $addSource $file "document-$($documentId.ToLowerInvariant())-context" $documentId
            }
        }
    }
    return @($descriptors)
}

function Get-DuoForgeByteSliceInternal {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][Parameter(Mandatory)][byte[]]$Bytes,
        [Parameter(Mandatory)][ValidateRange(0, 2147483647)][int]$Start,
        [Parameter(Mandatory)][ValidateRange(0, 2147483647)][int]$End
    )

    if ($End -lt $Start -or $End -gt $Bytes.Length) {
        throw (New-DuoForgeException -Code 'DF-CONTEXT-RANGE' -Message '문맥 바이트 범위가 원본을 벗어났습니다.')
    }
    $length = $End - $Start
    $result = [byte[]]::new($length)
    if ($length -gt 0) { [Array]::Copy($Bytes, $Start, $result, 0, $length) }
    return ,$result
}

function Get-DuoForgeContextEscapedByteCountInternal {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][Parameter(Mandatory)][byte[]]$Bytes,
        [Parameter(Mandatory)][ValidateRange(0, 2147483647)][int]$Start,
        [Parameter(Mandatory)][ValidateRange(0, 2147483647)][int]$End
    )

    $slice = Get-DuoForgeByteSliceInternal -Bytes $Bytes -Start $Start -End $End
    try { $text = [System.Text.UTF8Encoding]::new($false, $true).GetString($slice) }
    catch { throw (New-DuoForgeException -Code 'DF-CONTEXT-UTF8' -Message '문맥 범위가 유효한 UTF-8이 아닙니다.') }
    $escaped = ConvertTo-DuoForgeContextEnvelopeTextInternal -Text $text
    return [long][System.Text.UTF8Encoding]::new($false).GetByteCount($escaped)
}

function Get-DuoForgeUtf8LineRecordsInternal {
    [CmdletBinding()]
    param([AllowEmptyCollection()][Parameter(Mandatory)][byte[]]$Bytes)

    $encoding = [System.Text.UTF8Encoding]::new($false, $true)
    try { $text = $encoding.GetString($Bytes) }
    catch { throw (New-DuoForgeException -Code 'DF-CONTEXT-UTF8' -Message '문맥 스냅샷이 유효한 UTF-8이 아닙니다.') }

    $records = [System.Collections.Generic.List[object]]::new()
    $charStart = 0
    $byteStart = 0
    $lineNumber = 1
    while ($charStart -lt $text.Length) {
        $cursor = $charStart
        while ($cursor -lt $text.Length -and $text[$cursor] -ne "`r" -and $text[$cursor] -ne "`n") { $cursor++ }
        $contentEnd = $cursor
        if ($cursor -lt $text.Length) {
            if ($text[$cursor] -eq "`r" -and ($cursor + 1) -lt $text.Length -and $text[$cursor + 1] -eq "`n") { $cursor += 2 }
            else { $cursor++ }
        }
        $lineText = $text.Substring($charStart, $cursor - $charStart)
        $rawText = $text.Substring($charStart, $contentEnd - $charStart)
        $lineBytes = $encoding.GetByteCount($lineText)
        $records.Add([ordered]@{
            lineNumber = $lineNumber
            charStart = $charStart
            charEnd = $cursor
            byteStart = $byteStart
            byteEnd = $byteStart + $lineBytes
            rawText = $rawText
            text = $lineText
        })
        $charStart = $cursor
        $byteStart += $lineBytes
        $lineNumber++
    }
    if ($text.Length -eq 0) {
        $records.Add([ordered]@{ lineNumber = 1; charStart = 0; charEnd = 0; byteStart = 0; byteEnd = 0; rawText = ''; text = '' })
    }
    return [ordered]@{ text = $text; lines = @($records) }
}

function Test-DuoForgeMarkdownFenceOpeningInternal {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Line)

    $match = [regex]::Match($Line, '^\s{0,3}(`{3,}|~{3,})')
    if (-not $match.Success) { return $null }
    $marker = [string]$match.Groups[1].Value
    return [ordered]@{ character = [string]$marker[0]; length = $marker.Length }
}

function Test-DuoForgeMarkdownAtxHeadingInternal {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Line)

    $match = [regex]::Match($Line, '^\s{0,3}(#{1,6})\s+(.+?)\s*#*\s*$')
    if (-not $match.Success) { return $null }
    return [ordered]@{ level = $match.Groups[1].Value.Length; text = [string]$match.Groups[2].Value.Trim() }
}

function Test-DuoForgeMarkdownTableDelimiterInternal {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Line)

    return [bool]($Line -match '^\s*\|?\s*:?-{3,}:?\s*(?:\|\s*:?-{3,}:?\s*)+\|?\s*$')
}

function Get-DuoForgeMarkdownBlocksInternal {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Lines)

    $blocks = [System.Collections.Generic.List[object]]::new()
    $index = 0
    while ($index -lt $Lines.Count) {
        $line = $Lines[$index]
        $raw = [string]$line.rawText
        if ($index -eq 0) { $raw = $raw.TrimStart([char]0xFEFF) }
        $start = $index
        $kind = 'paragraph'
        $headingLevel = 0
        $headingText = ''

        $fence = Test-DuoForgeMarkdownFenceOpeningInternal -Line $raw
        if ($null -ne $fence) {
            $kind = 'fenced-code'
            $index++
            $closingPattern = '^\s{0,3}' + [regex]::Escape(([string]$fence.character) * [int]$fence.length) + ([regex]::Escape([string]$fence.character)) + '*\s*$'
            while ($index -lt $Lines.Count) {
                $closingLine = [string]$Lines[$index].rawText
                $index++
                if ($closingLine -match $closingPattern) { break }
            }
        }
        elseif ([string]::IsNullOrWhiteSpace($raw)) {
            $kind = 'blank'
            $index++
            while ($index -lt $Lines.Count -and [string]::IsNullOrWhiteSpace([string]$Lines[$index].rawText)) { $index++ }
        }
        else {
            $atx = Test-DuoForgeMarkdownAtxHeadingInternal -Line $raw
            $setext = $null
            if ($index + 1 -lt $Lines.Count) {
                $underline = [string]$Lines[$index + 1].rawText
                if ($underline -match '^\s*(=+|-+)\s*$' -and -not (Test-DuoForgeMarkdownTableDelimiterInternal -Line $underline)) {
                    $setext = [ordered]@{ level = if ($Matches[1][0] -eq '=') { 1 } else { 2 }; text = $raw.Trim() }
                }
            }
            if ($null -ne $atx) {
                $kind = 'heading'
                $headingLevel = [int]$atx.level
                $headingText = [string]$atx.text
                $index++
            }
            elseif ($null -ne $setext) {
                $kind = 'heading'
                $headingLevel = [int]$setext.level
                $headingText = [string]$setext.text
                $index += 2
            }
            elseif (($index + 1) -lt $Lines.Count -and $raw.Contains('|') -and (Test-DuoForgeMarkdownTableDelimiterInternal -Line ([string]$Lines[$index + 1].rawText))) {
                $kind = 'table'
                $index += 2
                while ($index -lt $Lines.Count -and -not [string]::IsNullOrWhiteSpace([string]$Lines[$index].rawText) -and ([string]$Lines[$index].rawText).Contains('|')) { $index++ }
            }
            elseif ($raw -match '^\s{0,3}(?:[-+*]|\d+[.)])\s+') {
                $kind = 'list'
                $index++
                while ($index -lt $Lines.Count) {
                    $candidate = [string]$Lines[$index].rawText
                    if ($candidate -match '^\s{0,3}(?:[-+*]|\d+[.)])\s+' -or $candidate -match '^\s{2,}\S') { $index++; continue }
                    if ([string]::IsNullOrWhiteSpace($candidate) -and ($index + 1) -lt $Lines.Count) {
                        $next = [string]$Lines[$index + 1].rawText
                        if ($next -match '^\s{0,3}(?:[-+*]|\d+[.)])\s+' -or $next -match '^\s{2,}\S') { $index++; continue }
                    }
                    break
                }
            }
            else {
                $kind = 'paragraph'
                $index++
                while ($index -lt $Lines.Count) {
                    $candidate = [string]$Lines[$index].rawText
                    if ([string]::IsNullOrWhiteSpace($candidate)) { break }
                    if ($null -ne (Test-DuoForgeMarkdownFenceOpeningInternal -Line $candidate)) { break }
                    if ($null -ne (Test-DuoForgeMarkdownAtxHeadingInternal -Line $candidate)) { break }
                    if ($candidate -match '^\s{0,3}(?:[-+*]|\d+[.)])\s+') { break }
                    if (($index + 1) -lt $Lines.Count -and $candidate.Contains('|') -and (Test-DuoForgeMarkdownTableDelimiterInternal -Line ([string]$Lines[$index + 1].rawText))) { break }
                    if (($index + 1) -lt $Lines.Count -and ([string]$Lines[$index + 1].rawText) -match '^\s*(=+|-+)\s*$') { break }
                    $index++
                }
            }
        }

        $end = [Math]::Max($start, $index - 1)
        $blocks.Add([ordered]@{
            kind = $kind
            lineStart = [int]$Lines[$start].lineNumber
            lineEnd = [int]$Lines[$end].lineNumber
            byteStart = [long]$Lines[$start].byteStart
            byteEnd = [long]$Lines[$end].byteEnd
            headingLevel = $headingLevel
            headingText = $headingText
        })
    }
    return @($blocks)
}

function Get-DuoForgeLineRangeForBytesInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Lines,
        [Parameter(Mandatory)][long]$ByteStart,
        [Parameter(Mandatory)][long]$ByteEnd
    )

    $startLine = @($Lines | Where-Object { [long]$_.byteStart -le $ByteStart -and [long]$_.byteEnd -gt $ByteStart } | Select-Object -First 1)
    if ($startLine.Count -eq 0) { $startLine = @($Lines | Select-Object -Last 1) }
    $lastByte = [Math]::Max($ByteStart, $ByteEnd - 1)
    $endLine = @($Lines | Where-Object { [long]$_.byteStart -le $lastByte -and [long]$_.byteEnd -gt $lastByte } | Select-Object -First 1)
    if ($endLine.Count -eq 0) { $endLine = @($Lines | Select-Object -Last 1) }
    return [ordered]@{ lineStart = [int]$startLine[0].lineNumber; lineEnd = [int]$endLine[0].lineNumber }
}

function Get-DuoForgeUtf8SafeChunkRangesInternal {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][Parameter(Mandatory)][byte[]]$Bytes,
        [Parameter(Mandatory)][int]$Start,
        [Parameter(Mandatory)][int]$End,
        [Parameter(Mandatory)][ValidateRange(1, 10485760)][int]$MaximumBytes,
        [ValidateRange(1, 2147483647)][long]$MaximumEscapedBytes = 2147483647
    )

    $ranges = [System.Collections.Generic.List[object]]::new()
    $offset = $Start
    while ($offset -lt $End) {
        $candidateEnd = [Math]::Min($End, $offset + $MaximumBytes)
        while ($candidateEnd -gt $offset -and $candidateEnd -lt $End -and (($Bytes[$candidateEnd] -band 0xC0) -eq 0x80)) { $candidateEnd-- }
        if ($candidateEnd -le $offset) { throw (New-DuoForgeException -Code 'DF-CONTEXT-UTF8-BOUNDARY' -Message 'UTF-8 코드포인트 경계를 보존해 문맥을 나눌 수 없습니다.') }
        if ((Get-DuoForgeContextEscapedByteCountInternal -Bytes $Bytes -Start $offset -End $candidateEnd) -gt $MaximumEscapedBytes) {
            $low = $offset + 1
            $high = $candidateEnd
            $best = -1
            while ($low -le $high) {
                $middle = [int][Math]::Floor(($low + $high) / 2)
                $boundary = $middle
                while ($boundary -gt $offset -and $boundary -lt $End -and (($Bytes[$boundary] -band 0xC0) -eq 0x80)) { $boundary-- }
                if ($boundary -le $offset) { $low = $middle + 1; continue }
                $escapedBytes = Get-DuoForgeContextEscapedByteCountInternal -Bytes $Bytes -Start $offset -End $boundary
                if ($escapedBytes -le $MaximumEscapedBytes) {
                    $best = [Math]::Max($best, $boundary)
                    $low = $middle + 1
                }
                else { $high = $boundary - 1 }
            }
            if ($best -le $offset) { throw (New-DuoForgeException -Code 'DF-CONTEXT-UTF8-BOUNDARY' -Message '호출 봉투의 escape 상한 안에서 UTF-8 문맥을 나눌 수 없습니다.') }
            $candidateEnd = $best
        }
        $ranges.Add([ordered]@{ byteStart = [long]$offset; byteEnd = [long]$candidateEnd; splitReason = 'utf8-bytes' })
        $offset = $candidateEnd
    }
    return @($ranges)
}

function New-DuoForgeMarkdownStructureMapInternal {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][Parameter(Mandatory)][byte[]]$Bytes,
        [Parameter(Mandatory)][string]$SourceSha256,
        [string]$SourceId = '',
        [Parameter(Mandatory)][ValidateRange(1024, 10485760)][int]$MaximumSectionBytes,
        [ValidateRange(1024, 2147483647)][long]$MaximumEscapedSectionBytes = 2147483647
    )

    $lineMap = Get-DuoForgeUtf8LineRecordsInternal -Bytes $Bytes
    $lines = @($lineMap.lines)
    $blocks = @(Get-DuoForgeMarkdownBlocksInternal -Lines $lines)
    $rawSections = [System.Collections.Generic.List[object]]::new()
    $currentBlocks = [System.Collections.Generic.List[object]]::new()
    $currentKind = 'preamble'
    $currentHeadingText = ''
    $currentHeadingLevel = 0
    $currentHeadingPath = @()
    $headingStack = @()
    foreach ($block in $blocks) {
        if ([string]$block.kind -eq 'heading') {
            if ($currentBlocks.Count -gt 0) {
                $rawSections.Add([ordered]@{
                    kind = $currentKind
                    headingText = $currentHeadingText
                    headingLevel = $currentHeadingLevel
                    headingPathText = @($currentHeadingPath)
                    blocks = @($currentBlocks)
                    byteStart = [long]$currentBlocks[0].byteStart
                    byteEnd = [long]$currentBlocks[$currentBlocks.Count - 1].byteEnd
                    lineStart = [int]$currentBlocks[0].lineStart
                    lineEnd = [int]$currentBlocks[$currentBlocks.Count - 1].lineEnd
                })
                $currentBlocks = [System.Collections.Generic.List[object]]::new()
            }
            $level = [int]$block.headingLevel
            $headingStack = @($headingStack | Where-Object { [int]$_.level -lt $level })
            $headingStack += @([ordered]@{ level = $level; text = [string]$block.headingText })
            $currentKind = 'section'
            $currentHeadingText = [string]$block.headingText
            $currentHeadingLevel = $level
            $currentHeadingPath = @($headingStack | ForEach-Object { [string]$_.text })
        }
        $currentBlocks.Add($block)
    }
    if ($currentBlocks.Count -gt 0) {
        $rawSections.Add([ordered]@{
            kind = $currentKind
            headingText = $currentHeadingText
            headingLevel = $currentHeadingLevel
            headingPathText = @($currentHeadingPath)
            blocks = @($currentBlocks)
            byteStart = [long]$currentBlocks[0].byteStart
            byteEnd = [long]$currentBlocks[$currentBlocks.Count - 1].byteEnd
            lineStart = [int]$currentBlocks[0].lineStart
            lineEnd = [int]$currentBlocks[$currentBlocks.Count - 1].lineEnd
        })
    }

    $sections = [System.Collections.Generic.List[object]]::new()
    $baseOrder = 0
    foreach ($rawSection in $rawSections) {
        $baseOrder++
        $baseSeed = '{0}|{1}|{2}|{3}|{4}|{5}' -f $SourceId,$SourceSha256,$baseOrder,[long]$rawSection.byteStart,[long]$rawSection.byteEnd,[string]$rawSection.kind
        $baseHash = Get-DuoForgeSha256 -Bytes ([System.Text.UTF8Encoding]::new($false).GetBytes($baseSeed))
        $baseId = 'section-{0:D4}-{1}' -f $baseOrder,$baseHash.Substring(7, 12)
        $units = [System.Collections.Generic.List[object]]::new()
        foreach ($block in @($rawSection.blocks)) {
            $blockBytes = [long]$block.byteEnd - [long]$block.byteStart
            $blockEscapedBytes = Get-DuoForgeContextEscapedByteCountInternal -Bytes $Bytes -Start ([int]$block.byteStart) -End ([int]$block.byteEnd)
            if ($blockBytes -le $MaximumSectionBytes -and $blockEscapedBytes -le $MaximumEscapedSectionBytes) {
                $units.Add([ordered]@{ byteStart = [long]$block.byteStart; byteEnd = [long]$block.byteEnd; escapedBytes = $blockEscapedBytes; splitReason = 'semantic-block'; kind = [string]$block.kind })
                continue
            }
            $blockLines = @($lines | Where-Object { [int]$_.lineNumber -ge [int]$block.lineStart -and [int]$_.lineNumber -le [int]$block.lineEnd })
            foreach ($blockLine in $blockLines) {
                $lineBytes = [long]$blockLine.byteEnd - [long]$blockLine.byteStart
                $lineEscapedBytes = Get-DuoForgeContextEscapedByteCountInternal -Bytes $Bytes -Start ([int]$blockLine.byteStart) -End ([int]$blockLine.byteEnd)
                if ($lineBytes -le $MaximumSectionBytes -and $lineEscapedBytes -le $MaximumEscapedSectionBytes) {
                    $units.Add([ordered]@{ byteStart = [long]$blockLine.byteStart; byteEnd = [long]$blockLine.byteEnd; escapedBytes = $lineEscapedBytes; splitReason = 'line'; kind = [string]$block.kind })
                }
                else {
                    foreach ($range in @(Get-DuoForgeUtf8SafeChunkRangesInternal -Bytes $Bytes -Start ([int]$blockLine.byteStart) -End ([int]$blockLine.byteEnd) -MaximumBytes $MaximumSectionBytes -MaximumEscapedBytes $MaximumEscapedSectionBytes)) {
                        $units.Add([ordered]@{ byteStart = [long]$range.byteStart; byteEnd = [long]$range.byteEnd; escapedBytes = Get-DuoForgeContextEscapedByteCountInternal -Bytes $Bytes -Start ([int]$range.byteStart) -End ([int]$range.byteEnd); splitReason = [string]$range.splitReason; kind = [string]$block.kind })
                    }
                }
            }
        }

        if ($units.Count -gt 1 -and [string]$rawSection.blocks[0].kind -eq 'heading') {
            $headingStart = [long]$units[0].byteStart
            $bodyUnitIndex = -1
            for ($unitIndex = 1; $unitIndex -lt $units.Count; $unitIndex++) {
                if ([string]$units[$unitIndex].kind -notin @('heading', 'blank')) { $bodyUnitIndex = $unitIndex; break }
            }
            $nextUnit = if ($bodyUnitIndex -ge 0) { $units[$bodyUnitIndex] } else { $null }
            $prefixBytes = if ($null -ne $nextUnit) { [long]$nextUnit.byteStart - $headingStart } else { $MaximumSectionBytes }
            $firstBodyCapacity = [int]($MaximumSectionBytes - $prefixBytes)
            $nextBytes = if ($null -ne $nextUnit) { [long]$nextUnit.byteEnd - [long]$nextUnit.byteStart } else { 0L }
            $prefixEscapedBytes = if ($null -ne $nextUnit) { Get-DuoForgeContextEscapedByteCountInternal -Bytes $Bytes -Start ([int]$headingStart) -End ([int]$nextUnit.byteStart) } else { $MaximumEscapedSectionBytes }
            $firstBodyEscapedCapacity = [long]$MaximumEscapedSectionBytes - [long]$prefixEscapedBytes
            $nextEscapedBytes = if ($null -ne $nextUnit) { Get-DuoForgeContextEscapedByteCountInternal -Bytes $Bytes -Start ([int]$nextUnit.byteStart) -End ([int]$nextUnit.byteEnd) } else { 0L }
            if ($bodyUnitIndex -ge 0 -and $firstBodyCapacity -gt 0 -and $firstBodyEscapedCapacity -gt 0 -and ($nextBytes -gt $firstBodyCapacity -or $nextEscapedBytes -gt $firstBodyEscapedCapacity)) {
                $replacement = @(Get-DuoForgeUtf8SafeChunkRangesInternal -Bytes $Bytes -Start ([int]$nextUnit.byteStart) -End ([int]$nextUnit.byteEnd) -MaximumBytes $firstBodyCapacity -MaximumEscapedBytes $firstBodyEscapedCapacity)
                $units.RemoveAt($bodyUnitIndex)
                for ($replacementIndex = 0; $replacementIndex -lt $replacement.Count; $replacementIndex++) {
                    $units.Insert($bodyUnitIndex + $replacementIndex, [ordered]@{
                        byteStart = [long]$replacement[$replacementIndex].byteStart
                        byteEnd = [long]$replacement[$replacementIndex].byteEnd
                        escapedBytes = Get-DuoForgeContextEscapedByteCountInternal -Bytes $Bytes -Start ([int]$replacement[$replacementIndex].byteStart) -End ([int]$replacement[$replacementIndex].byteEnd)
                        splitReason = [string]$replacement[$replacementIndex].splitReason
                        kind = [string]$nextUnit.kind
                    })
                }
            }
        }

        $fragments = [System.Collections.Generic.List[object]]::new()
        $fragmentStart = $null
        $fragmentEnd = $null
        $fragmentEscapedBytes = 0L
        $fragmentReason = 'none'
        foreach ($unit in $units) {
            if ($null -eq $fragmentStart) {
                $fragmentStart = [long]$unit.byteStart
                $fragmentEnd = [long]$unit.byteEnd
                $fragmentEscapedBytes = [long]$unit.escapedBytes
                $fragmentReason = [string]$unit.splitReason
                continue
            }
            $combinedBytes = [long]$unit.byteEnd - [long]$fragmentStart
            $combinedEscapedBytes = $fragmentEscapedBytes + [long]$unit.escapedBytes
            if ($combinedBytes -le $MaximumSectionBytes -and $combinedEscapedBytes -le $MaximumEscapedSectionBytes) {
                $fragmentEnd = [long]$unit.byteEnd
                $fragmentEscapedBytes = $combinedEscapedBytes
                if ([string]$unit.splitReason -eq 'utf8-bytes') { $fragmentReason = 'utf8-bytes' }
            }
            else {
                $fragments.Add([ordered]@{ byteStart = [long]$fragmentStart; byteEnd = [long]$fragmentEnd; escapedBytes = $fragmentEscapedBytes; splitReason = $fragmentReason })
                $fragmentStart = [long]$unit.byteStart
                $fragmentEnd = [long]$unit.byteEnd
                $fragmentEscapedBytes = [long]$unit.escapedBytes
                $fragmentReason = [string]$unit.splitReason
            }
        }
        if ($null -ne $fragmentStart) { $fragments.Add([ordered]@{ byteStart = [long]$fragmentStart; byteEnd = [long]$fragmentEnd; escapedBytes = $fragmentEscapedBytes; splitReason = $fragmentReason }) }

        $fragmentCount = $fragments.Count
        for ($fragmentIndex = 0; $fragmentIndex -lt $fragmentCount; $fragmentIndex++) {
            $fragment = $fragments[$fragmentIndex]
            $range = Get-DuoForgeLineRangeForBytesInternal -Lines $lines -ByteStart ([long]$fragment.byteStart) -ByteEnd ([long]$fragment.byteEnd)
            $slice = Get-DuoForgeByteSliceInternal -Bytes $Bytes -Start ([int]$fragment.byteStart) -End ([int]$fragment.byteEnd)
            $sectionId = if ($fragmentCount -eq 1) { $baseId } else { '{0}-fragment-{1:D3}' -f $baseId,($fragmentIndex + 1) }
            $sections.Add([ordered]@{
                sectionId = $sectionId
                parentSectionId = if ($fragmentCount -eq 1) { $null } else { $baseId }
                order = $sections.Count + 1
                kind = [string]$rawSection.kind
                headingText = [string]$rawSection.headingText
                headingLevel = [int]$rawSection.headingLevel
                headingPathText = @($rawSection.headingPathText)
                blocks = @($rawSection.blocks | Where-Object { [long]$_.byteEnd -gt [long]$fragment.byteStart -and [long]$_.byteStart -lt [long]$fragment.byteEnd })
                lineStart = [int]$range.lineStart
                lineEnd = [int]$range.lineEnd
                byteStart = [long]$fragment.byteStart
                byteEnd = [long]$fragment.byteEnd
                bytes = [long]$slice.Length
                escapedBytes = [long]$fragment.escapedBytes
                sha256 = Get-DuoForgeSha256 -Bytes $slice
                splitReason = if ($fragmentCount -eq 1) { $null } else { [string]$fragment.splitReason }
                continuationId = if ($fragmentCount -eq 1) { $null } else { $baseId }
                continuationIndex = if ($fragmentCount -eq 1) { 0 } else { $fragmentIndex + 1 }
                continuationCount = if ($fragmentCount -eq 1) { 0 } else { $fragmentCount }
            })
        }
    }
    return [ordered]@{
        schemaVersion = 1
        sourceSha256 = $SourceSha256
        bytes = [long]$Bytes.Length
        lineCount = $lines.Count
        sections = @($sections)
        text = [string]$lineMap.text
    }
}

function New-DuoForgeSemanticBatchBlueprintsInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Source,
        [Parameter(Mandatory)][System.Collections.IDictionary]$StructureMap,
        [Parameter(Mandatory)][ValidateRange(1024, 10485760)][int]$TargetCoreBytes,
        [Parameter(Mandatory)][ValidateRange(1024, 2147483647)][long]$MaximumEscapedCoreBytes
    )

    $blueprints = [System.Collections.Generic.List[object]]::new()
    $current = [System.Collections.Generic.List[object]]::new()
    $currentBytes = 0L
    $currentEscapedBytes = 0L
    foreach ($section in @($StructureMap.sections)) {
        $combinedEscapedBytes = $currentEscapedBytes + [long]$section.escapedBytes
        if ($current.Count -gt 0 -and (($currentBytes + [long]$section.bytes) -gt $TargetCoreBytes -or $combinedEscapedBytes -gt $MaximumEscapedCoreBytes)) {
            $first = $current[0]
            $last = $current[$current.Count - 1]
            $seed = '{0}|{1}|{2}|{3}' -f [string]$Source.sourceSha256,$blueprints.Count,[long]$first.byteStart,[long]$last.byteEnd
            $hash = Get-DuoForgeSha256 -Bytes ([System.Text.UTF8Encoding]::new($false).GetBytes($seed))
            $blueprints.Add([ordered]@{
                candidateId = ('candidate-{0:D3}-{1:D4}-{2}' -f ([int]$Source.sourceOrdinal),($blueprints.Count + 1),$hash.Substring(7, 10))
                sourceOrdinal = [int]$Source.sourceOrdinal
                sourceId = [string]$Source.sourceId
                sourceSha256 = [string]$Source.sourceSha256
                role = [string]$Source.role
                documentId = [string]$Source.documentId
                localOrder = $blueprints.Count + 1
                sectionIds = @($current | ForEach-Object { [string]$_.sectionId })
                byteStart = [long]$first.byteStart
                byteEnd = [long]$last.byteEnd
                coreBytes = [long]$last.byteEnd - [long]$first.byteStart
                lineStart = [int]$first.lineStart
                lineEnd = [int]$last.lineEnd
            })
            $current = [System.Collections.Generic.List[object]]::new()
            $currentBytes = 0L
            $currentEscapedBytes = 0L
        }
        $current.Add($section)
        $currentBytes += [long]$section.bytes
        $currentEscapedBytes += [long]$section.escapedBytes
    }
    if ($current.Count -gt 0) {
        $first = $current[0]
        $last = $current[$current.Count - 1]
        $seed = '{0}|{1}|{2}|{3}' -f [string]$Source.sourceSha256,$blueprints.Count,[long]$first.byteStart,[long]$last.byteEnd
        $hash = Get-DuoForgeSha256 -Bytes ([System.Text.UTF8Encoding]::new($false).GetBytes($seed))
        $blueprints.Add([ordered]@{
            candidateId = ('candidate-{0:D3}-{1:D4}-{2}' -f ([int]$Source.sourceOrdinal),($blueprints.Count + 1),$hash.Substring(7, 10))
            sourceOrdinal = [int]$Source.sourceOrdinal
            sourceId = [string]$Source.sourceId
            sourceSha256 = [string]$Source.sourceSha256
            role = [string]$Source.role
            documentId = [string]$Source.documentId
            localOrder = $blueprints.Count + 1
            sectionIds = @($current | ForEach-Object { [string]$_.sectionId })
            byteStart = [long]$first.byteStart
            byteEnd = [long]$last.byteEnd
            coreBytes = [long]$last.byteEnd - [long]$first.byteStart
            lineStart = [int]$first.lineStart
            lineEnd = [int]$last.lineEnd
        })
    }
    return @($blueprints)
}

function Select-DuoForgeBalancedBatchBlueprintsInternal {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][Parameter(Mandatory)][object[]]$Blueprints,
        [Parameter(Mandatory)][ValidateRange(0, 10000)][int]$Capacity
    )

    if ($Capacity -ge $Blueprints.Count) { return @($Blueprints) }
    if ($Capacity -le 0) { return @() }
    $groups = [System.Collections.Generic.List[object]]::new()
    foreach ($documentId in @($Blueprints | ForEach-Object { [string]$_.documentId } | Sort-Object -Unique)) {
        $groups.Add([ordered]@{
            Name = $documentId
            Group = @($Blueprints | Where-Object { [string]$_.documentId -eq $documentId } | Sort-Object sourceOrdinal, localOrder)
        })
    }
    $quotas = @{}
    foreach ($group in $groups) { $quotas[[string]$group.Name] = 0 }
    $remaining = $Capacity
    while ($remaining -gt 0) {
        $allocated = $false
        foreach ($group in $groups) {
            $key = [string]$group.Name
            if ([int]$quotas[$key] -ge @($group.Group).Count) { continue }
            $quotas[$key] = [int]$quotas[$key] + 1
            $remaining--
            $allocated = $true
            if ($remaining -eq 0) { break }
        }
        if (-not $allocated) { break }
    }

    $selectedIds = @{}
    foreach ($group in $groups) {
        $items = @($group.Group | Sort-Object sourceOrdinal, localOrder)
        $quota = [int]$quotas[[string]$group.Name]
        if ($quota -le 0) { continue }
        if ($quota -eq 1) {
            $selectedIds[[string]$items[[int][Math]::Floor(($items.Count - 1) / 2)].candidateId] = $true
            continue
        }
        for ($slot = 0; $slot -lt $quota; $slot++) {
            $position = [int][Math]::Round(($slot * ($items.Count - 1)) / [double]($quota - 1), [MidpointRounding]::AwayFromZero)
            $selectedIds[[string]$items[$position].candidateId] = $true
        }
    }
    return @($Blueprints | Where-Object { $selectedIds.ContainsKey([string]$_.candidateId) })
}

function New-DuoForgeContextBatchPlanInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$ValidationResult,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config,
        [Parameter(Mandatory)][System.Collections.IDictionary]$BaseExecutionPlan
    )

    $sources = @(Get-DuoForgeValidationSourceDescriptorsInternal -ValidationResult $ValidationResult)
    $totalBytes = 0L
    foreach ($source in $sources) { $totalBytes += [long]$source.bytes }
    $maxInputBytes = [long]$Config.limits.maxInputBytesPerCall
    $directThreshold = [long][Math]::Floor($maxInputBytes * 0.55)
    $targetCoreBytes = [long][Math]::Max(4096, [Math]::Floor($maxInputBytes * 0.20))
    $maximumPackBytes = [long][Math]::Max(16384, [Math]::Floor($maxInputBytes * 0.62))
    $bridgeBytesPerSide = [long][Math]::Max(512, [Math]::Min(2048, [Math]::Floor($maxInputBytes * 0.02)))
    $documentMapBytes = [long][Math]::Max(2048, [Math]::Min(8192, [Math]::Floor($maxInputBytes * 0.08)))
    $maximumEscapedCoreBytes = [long][Math]::Max(1024, $maximumPackBytes - [Math]::Max(16384, $documentMapBytes + 8192))
    $base = [ordered]@{
        schemaVersion = 2
        segmentationPolicy = 'semantic-markdown-v1'
        envelopePolicy = 'document-map-extractive-bridge-v1'
        enabled = $totalBytes -gt $directThreshold
        totalFiles = $sources.Count
        totalBytes = $totalBytes
        maxInputBytesPerCall = $maxInputBytes
        targetBatchBytes = $targetCoreBytes
        targetCoreBytes = $targetCoreBytes
        maximumPackBytes = $maximumPackBytes
        bridgeBytesPerSide = $bridgeBytesPerSide
        documentMapBytes = $documentMapBytes
        requiredBatchCount = 0
        selectedBatchCount = 0
        selectedBytes = $totalBytes
        coreBytes = $totalBytes
        overlapBytes = 0L
        transmittedBytes = 0L
        predictedFileCoveragePercent = 100.0
        predictedByteCoveragePercent = 100.0
        requiresPartialConsent = $false
        completionStatus = 'COMPLETED'
        sourceBlueprints = @()
        candidateBlueprints = @()
        selectedCandidateIds = @()
    }
    if ($totalBytes -le $directThreshold) {
        return $base
    }

    $sourceBlueprints = [System.Collections.Generic.List[object]]::new()
    $candidateBlueprints = [System.Collections.Generic.List[object]]::new()
    foreach ($source in $sources) {
        $bytes = [System.IO.File]::ReadAllBytes([string]$source.path)
        if ($bytes.Length -ne [long]$source.bytes -or (Get-DuoForgeSha256 -Bytes $bytes) -ne [string]$source.sourceSha256) {
            throw (New-DuoForgeException -Code 'DF-CONTEXT-SOURCE-DRIFT' -Message "문맥 계획 중 입력 원본의 무결성이 변경되었습니다: $($source.sourceId)")
        }
        $map = New-DuoForgeMarkdownStructureMapInternal -Bytes $bytes -SourceSha256 ([string]$source.sourceSha256) -SourceId ([string]$source.sourceId) -MaximumSectionBytes ([int]$targetCoreBytes) -MaximumEscapedSectionBytes $maximumEscapedCoreBytes
        $sections = @($map.sections | ForEach-Object {
            [ordered]@{
                sectionId = [string]$_.sectionId
                parentSectionId = Get-DuoForgeObjectValue -Object $_ -Name 'parentSectionId'
                order = [int]$_.order
                kind = [string]$_.kind
                headingLevel = [int]$_.headingLevel
                headingPathHashes = @($_.headingPathText | ForEach-Object { Get-DuoForgeSha256 -Bytes ([System.Text.UTF8Encoding]::new($false).GetBytes([string]$_)) })
                lineStart = [int]$_.lineStart
                lineEnd = [int]$_.lineEnd
                byteStart = [long]$_.byteStart
                byteEnd = [long]$_.byteEnd
                bytes = [long]$_.bytes
                sha256 = [string]$_.sha256
                splitReason = Get-DuoForgeObjectValue -Object $_ -Name 'splitReason'
                continuationId = Get-DuoForgeObjectValue -Object $_ -Name 'continuationId'
                continuationIndex = [int](Get-DuoForgeObjectValue -Object $_ -Name 'continuationIndex' -Default 0)
                continuationCount = [int](Get-DuoForgeObjectValue -Object $_ -Name 'continuationCount' -Default 0)
            }
        })
        $sourceBlueprints.Add([ordered]@{
            sourceOrdinal = [int]$source.sourceOrdinal
            sourceId = [string]$source.sourceId
            sourceSha256 = [string]$source.sourceSha256
            bytes = [long]$source.bytes
            role = [string]$source.role
            documentId = [string]$source.documentId
            sectionCount = $sections.Count
            sections = $sections
        })
        foreach ($candidate in @(New-DuoForgeSemanticBatchBlueprintsInternal -Source $source -StructureMap $map -TargetCoreBytes ([int]$targetCoreBytes) -MaximumEscapedCoreBytes $maximumEscapedCoreBytes)) {
            $candidateBlueprints.Add($candidate)
        }
    }
    $capacity = [int]::MaxValue
    foreach ($provider in @('codex', 'claude')) {
        $remainingCalls = [Math]::Max(0, [int]$Config.limits.maxCallsPerProviderPerRun - [int]$BaseExecutionPlan.providers[$provider].maximumCalls)
        $providerCapacity = [int][Math]::Floor($remainingCalls / 2)
        $capacity = [Math]::Min($capacity, $providerCapacity)
    }
    if ($capacity -eq [int]::MaxValue) { $capacity = 0 }
    $selected = @(Select-DuoForgeBalancedBatchBlueprintsInternal -Blueprints @($candidateBlueprints) -Capacity $capacity)
    $selectedBatchCount = $selected.Count
    $selectedBytes = 0L
    foreach ($candidate in $selected) { $selectedBytes += [long]$candidate.coreBytes }
    $byteCoverage = if ($totalBytes -eq 0) { 100.0 } else { [Math]::Round(($selectedBytes / [double]$totalBytes) * 100, 2) }
    $fullySelectedSources = 0
    foreach ($source in $sourceBlueprints) {
        $sourceCoreBytes = 0L
        foreach ($candidate in @($selected | Where-Object { [string]$_.sourceId -eq [string]$source.sourceId })) { $sourceCoreBytes += [long]$candidate.coreBytes }
        if ($sourceCoreBytes -eq [long]$source.bytes) { $fullySelectedSources++ }
    }
    $fileCoverage = if ($sources.Count -eq 0) { 100.0 } else { [Math]::Round(($fullySelectedSources / [double]$sources.Count) * 100, 2) }
    $partial = $selectedBytes -lt $totalBytes
    $base.requiredBatchCount = $candidateBlueprints.Count
    $base.selectedBatchCount = $selectedBatchCount
    $base.selectedBytes = $selectedBytes
    $base.coreBytes = $selectedBytes
    $base.predictedFileCoveragePercent = $fileCoverage
    $base.predictedByteCoveragePercent = $byteCoverage
    $base.requiresPartialConsent = $partial
    $base.completionStatus = if ($partial) { 'COMPLETED_PARTIAL' } else { 'COMPLETED' }
    $base.sourceBlueprints = @($sourceBlueprints)
    $base.candidateBlueprints = @($candidateBlueprints)
    $base.selectedCandidateIds = @($selected | ForEach-Object { [string]$_.candidateId })
    return $base
}

function Split-DuoForgeTextByUtf8BytesInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][ValidateRange(1024, 10485760)][int]$MaximumBytes
    )

    $encoding = [System.Text.UTF8Encoding]::new($false)
    $chunks = [System.Collections.Generic.List[string]]::new()
    $offset = 0
    while ($offset -lt $Text.Length) {
        $remaining = $Text.Length - $offset
        $low = 1
        $high = $remaining
        $best = 1
        while ($low -le $high) {
            $middle = [int][Math]::Floor(($low + $high) / 2)
            $bytes = $encoding.GetByteCount($Text.Substring($offset, $middle))
            if ($bytes -le $MaximumBytes) { $best = $middle; $low = $middle + 1 } else { $high = $middle - 1 }
        }
        if ($offset + $best -lt $Text.Length) {
            $candidate = $Text.Substring($offset, $best)
            $lineBreak = $candidate.LastIndexOf("`n", [StringComparison]::Ordinal)
            if ($lineBreak -gt [Math]::Floor($best * 0.5)) { $best = $lineBreak + 1 }
        }
        $chunks.Add($Text.Substring($offset, $best))
        $offset += $best
    }
    if ($Text.Length -eq 0) { $chunks.Add('') }
    return @($chunks)
}

function Get-DuoForgeUtf8BridgeRangeInternal {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][Parameter(Mandatory)][byte[]]$Bytes,
        [Parameter(Mandatory)][ValidateSet('before', 'after')][string]$Direction,
        [Parameter(Mandatory)][int]$CoreStart,
        [Parameter(Mandatory)][int]$CoreEnd,
        [Parameter(Mandatory)][ValidateRange(0, 1048576)][int]$MaximumBytes
    )

    if ($MaximumBytes -eq 0) { return [ordered]@{ byteStart = [long]$(if ($Direction -eq 'before') { $CoreStart } else { $CoreEnd }); byteEnd = [long]$(if ($Direction -eq 'before') { $CoreStart } else { $CoreEnd }) } }
    if ($Direction -eq 'before') {
        $end = $CoreStart
        $start = [Math]::Max(0, $end - $MaximumBytes)
        while ($start -lt $end -and (($Bytes[$start] -band 0xC0) -eq 0x80)) { $start++ }
        return [ordered]@{ byteStart = [long]$start; byteEnd = [long]$end }
    }
    $start = $CoreEnd
    $end = [Math]::Min($Bytes.Length, $start + $MaximumBytes)
    while ($end -gt $start -and $end -lt $Bytes.Length -and (($Bytes[$end] -band 0xC0) -eq 0x80)) { $end-- }
    return [ordered]@{ byteStart = [long]$start; byteEnd = [long]$end }
}

function Get-DuoForgeSemanticBridgeRangeInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$StructureMap,
        [AllowEmptyCollection()][Parameter(Mandatory)][byte[]]$Bytes,
        [Parameter(Mandatory)][ValidateSet('before', 'after')][string]$Direction,
        [Parameter(Mandatory)][int]$CoreStart,
        [Parameter(Mandatory)][int]$CoreEnd,
        [Parameter(Mandatory)][ValidateRange(0, 1048576)][int]$MaximumBytes
    )

    if ($MaximumBytes -le 0) { return [ordered]@{ byteStart = [long]$CoreStart; byteEnd = [long]$CoreStart } }
    $seen = @{}
    $blocks = [System.Collections.Generic.List[object]]::new()
    foreach ($block in @($StructureMap.sections | ForEach-Object { @($_.blocks) })) {
        $key = '{0}:{1}' -f [long]$block.byteStart,[long]$block.byteEnd
        if (-not $seen.ContainsKey($key)) { $seen[$key] = $true; $blocks.Add($block) }
    }
    if ($Direction -eq 'before') {
        $start = $CoreStart
        foreach ($block in @($blocks | Where-Object { [long]$_.byteEnd -le $CoreStart } | Sort-Object { [long]$_.byteStart } -Descending)) {
            $candidateStart = [int]$block.byteStart
            if (($CoreStart - $candidateStart) -gt $MaximumBytes) { break }
            $start = $candidateStart
        }
        if ($start -lt $CoreStart) { return [ordered]@{ byteStart = [long]$start; byteEnd = [long]$CoreStart } }
    }
    else {
        $end = $CoreEnd
        foreach ($block in @($blocks | Where-Object { [long]$_.byteStart -ge $CoreEnd } | Sort-Object { [long]$_.byteStart })) {
            $candidateEnd = [int]$block.byteEnd
            if (($candidateEnd - $CoreEnd) -gt $MaximumBytes) { break }
            $end = $candidateEnd
        }
        if ($end -gt $CoreEnd) { return [ordered]@{ byteStart = [long]$CoreEnd; byteEnd = [long]$end } }
    }
    return Get-DuoForgeUtf8BridgeRangeInternal -Bytes $Bytes -Direction $Direction -CoreStart $CoreStart -CoreEnd $CoreEnd -MaximumBytes $MaximumBytes
}

function ConvertTo-DuoForgeContextEnvelopeTextInternal {
    [CmdletBinding()]
    param([AllowEmptyString()][Parameter(Mandatory)][string]$Text)

    return $Text.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;')
}

function New-DuoForgeDocumentMapRegionTextInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$StructureMap,
        [Parameter(Mandatory)][string[]]$CoreSectionIds,
        [Parameter(Mandatory)][ValidateRange(256, 65536)][int]$MaximumBytes
    )

    $encoding = [System.Text.UTF8Encoding]::new($false)
    $allSections = @($StructureMap.sections | Sort-Object order)
    $render = {
        param([object[]]$Sections, [int]$Omitted, [switch]$IdsOnly)
        $lines = [System.Collections.Generic.List[string]]::new()
        $lines.Add('문서 섹션 지도 (모든 항목은 위치 이해 전용이며 근거가 아닙니다)')
        $lines.Add("전체 섹션: $($allSections.Count), 표시 생략: $Omitted")
        foreach ($section in $Sections) {
            $marker = if ([string]$section.sectionId -in $CoreSectionIds) { 'CORE' } else { 'context' }
            if ($IdsOnly) {
                $lines.Add("- [$marker] $($section.sectionId) · lines $($section.lineStart)-$($section.lineEnd)")
            }
            else {
                $path = if (@($section.headingPathText).Count -eq 0) { '[서문]' } else { @($section.headingPathText) -join ' > ' }
                $lines.Add("- [$marker] $($section.sectionId) · lines $($section.lineStart)-$($section.lineEnd) · $path")
            }
        }
        return ($lines -join "`n")
    }.GetNewClosure()

    $text = & $render $allSections 0
    $omittedCount = 0
    if ($encoding.GetByteCount($text) -gt $MaximumBytes) {
        $coreOrders = @($allSections | Where-Object { [string]$_.sectionId -in $CoreSectionIds } | ForEach-Object { [int]$_.order })
        $minimumOrder = if ($coreOrders.Count -gt 0) { ($coreOrders | Measure-Object -Minimum).Minimum } else { 1 }
        $maximumOrder = if ($coreOrders.Count -gt 0) { ($coreOrders | Measure-Object -Maximum).Maximum } else { 1 }
        $selectedOrders = @{}
        foreach ($order in @(1, $allSections.Count, ($minimumOrder - 2), ($minimumOrder - 1), $minimumOrder, $maximumOrder, ($maximumOrder + 1), ($maximumOrder + 2))) {
            if ($order -ge 1 -and $order -le $allSections.Count) { $selectedOrders[[int]$order] = $true }
        }
        $selected = @($allSections | Where-Object { $selectedOrders.ContainsKey([int]$_.order) })
        $omittedCount = $allSections.Count - $selected.Count
        $text = & $render $selected $omittedCount
        if ($encoding.GetByteCount($text) -gt $MaximumBytes) { $text = & $render $selected $omittedCount -IdsOnly }
    }
    if ($encoding.GetByteCount($text) -gt $MaximumBytes) {
        $coreSummary = if ($CoreSectionIds.Count -eq 0) { '없음' } elseif ($CoreSectionIds.Count -eq 1) { [string]$CoreSectionIds[0] } else { '{0} .. {1} ({2}개)' -f [string]$CoreSectionIds[0],[string]$CoreSectionIds[-1],$CoreSectionIds.Count }
        $text = "문서 섹션 지도 축약됨`n전체 섹션: $($allSections.Count)`n현재 CORE: $coreSummary"
        $omittedCount = [Math]::Max(0, $allSections.Count - $CoreSectionIds.Count)
    }
    if ($encoding.GetByteCount($text) -gt $MaximumBytes) {
        $text = "전체 섹션: $($allSections.Count); CORE 섹션: $($CoreSectionIds.Count); 지도 축약됨"
    }
    if ($encoding.GetByteCount($text) -gt $MaximumBytes) { throw (New-DuoForgeException -Code 'DF-CONTEXT-MAP-SIZE' -Message '문서 지도를 예약 상한 안에 축약할 수 없습니다.') }
    return [ordered]@{ text = $text; omittedSectionCount = $omittedCount }
}

function New-DuoForgeContextPackEnvelopeInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BatchId,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Source,
        [Parameter(Mandatory)][System.Collections.IDictionary]$StructureMap,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Candidate,
        [AllowEmptyCollection()][Parameter(Mandatory)][byte[]]$SourceBytes,
        [Parameter(Mandatory)][ValidateRange(0, 1048576)][int]$BridgeBytesPerSide,
        [Parameter(Mandatory)][ValidateRange(256, 65536)][int]$DocumentMapBytes
    )

    $encoding = [System.Text.UTF8Encoding]::new($false, $true)
    $coreStart = [int]$Candidate.byteStart
    $coreEnd = [int]$Candidate.byteEnd
    $beforeRange = Get-DuoForgeSemanticBridgeRangeInternal -StructureMap $StructureMap -Bytes $SourceBytes -Direction before -CoreStart $coreStart -CoreEnd $coreEnd -MaximumBytes $BridgeBytesPerSide
    $afterRange = Get-DuoForgeSemanticBridgeRangeInternal -StructureMap $StructureMap -Bytes $SourceBytes -Direction after -CoreStart $coreStart -CoreEnd $coreEnd -MaximumBytes $BridgeBytesPerSide
    $beforeBytes = Get-DuoForgeByteSliceInternal -Bytes $SourceBytes -Start ([int]$beforeRange.byteStart) -End ([int]$beforeRange.byteEnd)
    $coreBytes = Get-DuoForgeByteSliceInternal -Bytes $SourceBytes -Start $coreStart -End $coreEnd
    $afterBytes = Get-DuoForgeByteSliceInternal -Bytes $SourceBytes -Start ([int]$afterRange.byteStart) -End ([int]$afterRange.byteEnd)
    $coreHash = Get-DuoForgeSha256 -Bytes $coreBytes
    $evidenceContract = [ordered]@{
        sourceDocumentId = [string]$Source.documentId
        path = "snapshot:$($Source.snapshotName)"
        location = 'sections={0};lines={1}-{2};bytes={3}-{4}' -f (@($Candidate.sectionIds) -join ','),[int]$Candidate.lineStart,[int]$Candidate.lineEnd,$coreStart,$coreEnd
        excerptHash = $coreHash
    }
    $map = New-DuoForgeDocumentMapRegionTextInternal -StructureMap $StructureMap -CoreSectionIds @($Candidate.sectionIds) -MaximumBytes $DocumentMapBytes
    $beforeText = if ($beforeBytes.Length -eq 0) { '' } else { $encoding.GetString($beforeBytes) }
    $coreText = $encoding.GetString($coreBytes)
    $afterText = if ($afterBytes.Length -eq 0) { '' } else { $encoding.GetString($afterBytes) }
    $newline = "`n"
    $outerPrefix = "<DUOFORGE_CONTEXT_PACK schemaVersion=`"2`" content-encoding=`"xml-escaped`" batchId=`"$BatchId`" source=`"$($Source.snapshotName)`" role=`"$($Source.role)`">$newline"
    $outerSuffix = "</DUOFORGE_CONTEXT_PACK>$newline"
    $regionTexts = [ordered]@{
        documentMap = "<DUOFORGE_DOCUMENT_MAP context-only=`"true`">$newline$(ConvertTo-DuoForgeContextEnvelopeTextInternal -Text ([string]$map.text))$newline</DUOFORGE_DOCUMENT_MAP>$newline"
        before = "<DUOFORGE_BEFORE context-only=`"true`">$newline$(ConvertTo-DuoForgeContextEnvelopeTextInternal -Text $beforeText)$(if ($beforeText.EndsWith($newline, [StringComparison]::Ordinal) -or $beforeText.Length -eq 0) { '' } else { $newline })</DUOFORGE_BEFORE>$newline"
        core = "<DUOFORGE_CORE context-only=`"false`" evidence-eligible=`"true`" source-document-id=`"$($evidenceContract.sourceDocumentId)`" path=`"$($evidenceContract.path)`" location=`"$($evidenceContract.location)`" excerpt-hash=`"$coreHash`">$newline$(ConvertTo-DuoForgeContextEnvelopeTextInternal -Text $coreText)$(if ($coreText.EndsWith($newline, [StringComparison]::Ordinal) -or $coreText.Length -eq 0) { '' } else { $newline })</DUOFORGE_CORE>$newline"
        after = "<DUOFORGE_AFTER context-only=`"true`">$newline$(ConvertTo-DuoForgeContextEnvelopeTextInternal -Text $afterText)$(if ($afterText.EndsWith($newline, [StringComparison]::Ordinal) -or $afterText.Length -eq 0) { '' } else { $newline })</DUOFORGE_AFTER>$newline"
    }
    $contentBuilder = [System.Text.StringBuilder]::new()
    [void]$contentBuilder.Append($outerPrefix)
    $offset = $encoding.GetByteCount($outerPrefix)
    $regions = [ordered]@{}
    foreach ($name in @('documentMap', 'before', 'core', 'after')) {
        $regionText = [string]$regionTexts[$name]
        $regionBytes = $encoding.GetBytes($regionText)
        $start = $offset
        [void]$contentBuilder.Append($regionText)
        $offset += $regionBytes.Length
        $sourceRange = switch ($name) {
            'before' { $beforeRange }
            'core' { [ordered]@{ byteStart = [long]$coreStart; byteEnd = [long]$coreEnd } }
            'after' { $afterRange }
            default { $null }
        }
        $sourceLength = if ($null -eq $sourceRange) { 0L } else { [long]$sourceRange.byteEnd - [long]$sourceRange.byteStart }
        $regions[$name] = [ordered]@{
            contextOnly = $name -ne 'core'
            evidenceEligible = $name -eq 'core'
            packStartByte = [long]$start
            packEndByte = [long]$offset
            packBytes = [long]$regionBytes.Length
            bytes = $sourceLength
            sha256 = Get-DuoForgeSha256 -Bytes $regionBytes
            sourceRanges = if ($null -eq $sourceRange -or $sourceLength -eq 0) { @() } else { @([ordered]@{
                sourceId = [string]$Source.sourceId
                snapshotName = [string]$Source.snapshotName
                byteStart = [long]$sourceRange.byteStart
                byteEnd = [long]$sourceRange.byteEnd
                sha256 = Get-DuoForgeSha256 -Bytes $(switch ($name) { 'before' { $beforeBytes } 'core' { $coreBytes } 'after' { $afterBytes } })
            }) }
        }
    }
    [void]$contentBuilder.Append($outerSuffix)
    $content = $contentBuilder.ToString()
    $contentBytes = $encoding.GetBytes($content)
    return [ordered]@{
        content = $content
        bytes = [long]$contentBytes.Length
        sha256 = Get-DuoForgeSha256 -Bytes $contentBytes
        coreBytes = [long]$coreBytes.Length
        overlapBytes = [long]$beforeBytes.Length + [long]$afterBytes.Length
        documentMapOmittedSectionCount = [int]$map.omittedSectionCount
        evidenceContract = $evidenceContract
        regions = $regions
    }
}

function New-DuoForgeContextPackWithinLimitInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BatchId,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Source,
        [Parameter(Mandatory)][System.Collections.IDictionary]$StructureMap,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Candidate,
        [AllowEmptyCollection()][Parameter(Mandatory)][byte[]]$SourceBytes,
        [Parameter(Mandatory)][ValidateRange(0, 1048576)][int]$BridgeBytesPerSide,
        [Parameter(Mandatory)][ValidateRange(256, 65536)][int]$DocumentMapBytes,
        [Parameter(Mandatory)][ValidateRange(1, 2147483647)][long]$MaximumPackBytes
    )

    $bridgeLimit = $BridgeBytesPerSide
    $mapLimit = $DocumentMapBytes
    $envelope = $null
    for ($attempt = 0; $attempt -lt 12; $attempt++) {
        $envelope = New-DuoForgeContextPackEnvelopeInternal -BatchId $BatchId -Source $Source -StructureMap $StructureMap -Candidate $Candidate -SourceBytes $SourceBytes -BridgeBytesPerSide $bridgeLimit -DocumentMapBytes $mapLimit
        if ([long]$envelope.bytes -le $MaximumPackBytes) {
            return [ordered]@{ envelope = $envelope; bridgeBytesPerSide = $bridgeLimit; documentMapBytes = $mapLimit }
        }
        if ($bridgeLimit -gt 0) { $bridgeLimit = if ($bridgeLimit -le 256) { 0 } else { [int][Math]::Floor($bridgeLimit / 2) }; continue }
        if ($mapLimit -gt 256) { $mapLimit = [Math]::Max(256, [int][Math]::Floor($mapLimit / 2)); continue }
        break
    }
    throw (New-DuoForgeException -Code 'DF-CONTEXT-PACK-SIZE' -Message "문맥 배치를 호출 상한 안에 구성할 수 없습니다: $BatchId")
}

function New-DuoForgeContextBatchFilesV2Internal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunDirectory,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Inventory,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Plan
    )

    $result = ConvertTo-DuoForgeHashtable -InputObject $Plan
    if (-not [bool]$Plan.enabled) {
        $result.batches = @()
        $result.sources = @()
        $result.sourceCoverage = @()
        $result.documentCoverage = @()
        $result.omittedSectionIds = @()
        $result.omittedBytes = 0L
        $result.actualFileCoveragePercent = 100.0
        $result.actualByteCoveragePercent = 100.0
        return $result
    }
    if ([int]$Plan.selectedBatchCount -lt 1) { throw (New-DuoForgeException -Code 'DF-CONTEXT-NO-CAPACITY' -Message '큰 문서를 나눠 읽는 데 필요한 AI 요청 횟수가 부족합니다. 입력 범위를 줄여 주세요.') }

    $documents = @(Get-DuoForgePromptDocuments -RunDirectory $RunDirectory -Inventory $Inventory)
    $plannedSources = @($Plan.sourceBlueprints | Sort-Object sourceOrdinal)
    if ($documents.Count -ne $plannedSources.Count) { throw (New-DuoForgeException -Code 'DF-CONTEXT-PLAN-MISMATCH' -Message '문맥 계획의 입력 수와 불변 스냅샷 수가 다릅니다.') }
    $runtimeSources = [System.Collections.Generic.List[object]]::new()
    $runtimeMaps = @{}
    $runtimeCandidates = [System.Collections.Generic.List[object]]::new()
    $maximumEscapedCoreBytes = [long][Math]::Max(1024, [long]$Plan.maximumPackBytes - [Math]::Max(16384, [long]$Plan.documentMapBytes + 8192))
    for ($sourceIndex = 0; $sourceIndex -lt $plannedSources.Count; $sourceIndex++) {
        $plannedSource = $plannedSources[$sourceIndex]
        $document = $documents[$sourceIndex]
        $snapshotPath = Join-Path $RunDirectory ("inputs\snapshots\{0}" -f [string]$document.snapshotName)
        $sourceBytes = [System.IO.File]::ReadAllBytes($snapshotPath)
        if ((Get-DuoForgeSha256 -Bytes $sourceBytes) -ne [string]$plannedSource.sourceSha256 -or $sourceBytes.Length -ne [long]$plannedSource.bytes) {
            throw (New-DuoForgeException -Code 'DF-CONTEXT-PLAN-MISMATCH' -Message "문맥 계획과 불변 스냅샷이 다릅니다: $($plannedSource.sourceId)")
        }
        $map = New-DuoForgeMarkdownStructureMapInternal -Bytes $sourceBytes -SourceSha256 ([string]$plannedSource.sourceSha256) -SourceId ([string]$plannedSource.sourceId) -MaximumSectionBytes ([int]$Plan.targetCoreBytes) -MaximumEscapedSectionBytes $maximumEscapedCoreBytes
        $plannedSections = @($plannedSource.sections)
        if (@($map.sections).Count -ne $plannedSections.Count) { throw (New-DuoForgeException -Code 'DF-CONTEXT-PLAN-MISMATCH' -Message "문맥 섹션 수가 계획과 다릅니다: $($plannedSource.sourceId)") }
        for ($sectionIndex = 0; $sectionIndex -lt $plannedSections.Count; $sectionIndex++) {
            $actualSection = $map.sections[$sectionIndex]
            $plannedSection = $plannedSections[$sectionIndex]
            if ([string]$actualSection.sectionId -ne [string]$plannedSection.sectionId -or [string]$actualSection.sha256 -ne [string]$plannedSection.sha256 -or [long]$actualSection.byteStart -ne [long]$plannedSection.byteStart -or [long]$actualSection.byteEnd -ne [long]$plannedSection.byteEnd) {
                throw (New-DuoForgeException -Code 'DF-CONTEXT-PLAN-MISMATCH' -Message "문맥 섹션 범위가 계획과 다릅니다: $($plannedSource.sourceId)")
            }
        }
        $runtimeSource = [ordered]@{
            sourceOrdinal = [int]$plannedSource.sourceOrdinal
            sourceId = [string]$plannedSource.sourceId
            snapshotName = [string]$document.snapshotName
            sourceSha256 = [string]$plannedSource.sourceSha256
            bytes = [long]$plannedSource.bytes
            role = [string]$plannedSource.role
            documentId = [string]$plannedSource.documentId
            sections = @($plannedSections)
            sourceBytes = $sourceBytes
        }
        $runtimeSources.Add($runtimeSource)
        $runtimeMaps[[string]$runtimeSource.sourceId] = $map
        foreach ($candidate in @(New-DuoForgeSemanticBatchBlueprintsInternal -Source $runtimeSource -StructureMap $map -TargetCoreBytes ([int]$Plan.targetCoreBytes) -MaximumEscapedCoreBytes $maximumEscapedCoreBytes)) { $runtimeCandidates.Add($candidate) }
    }
    if (($runtimeCandidates.candidateId -join "`n") -cne (@($Plan.candidateBlueprints).candidateId -join "`n")) {
        throw (New-DuoForgeException -Code 'DF-CONTEXT-PLAN-MISMATCH' -Message '문맥 배치 청사진이 계획과 다릅니다.')
    }
    $candidateById = @{}
    foreach ($candidate in $runtimeCandidates) { $candidateById[[string]$candidate.candidateId] = $candidate }
    $sourceById = @{}
    foreach ($source in $runtimeSources) { $sourceById[[string]$source.sourceId] = $source }

    $batches = [System.Collections.Generic.List[object]]::new()
    $batchIndex = 0
    foreach ($candidateId in @($Plan.selectedCandidateIds)) {
        if (-not $candidateById.ContainsKey([string]$candidateId)) { throw (New-DuoForgeException -Code 'DF-CONTEXT-PLAN-MISMATCH' -Message "선택된 문맥 배치 청사진을 찾을 수 없습니다: $candidateId") }
        $candidate = $candidateById[[string]$candidateId]
        $source = $sourceById[[string]$candidate.sourceId]
        $batchIndex++
        $batchId = 'batch-{0:D3}' -f $batchIndex
        $sizedEnvelope = New-DuoForgeContextPackWithinLimitInternal -BatchId $batchId -Source $source -StructureMap $runtimeMaps[[string]$source.sourceId] -Candidate $candidate -SourceBytes ([byte[]]$source.sourceBytes) -BridgeBytesPerSide ([int]$Plan.bridgeBytesPerSide) -DocumentMapBytes ([int]$Plan.documentMapBytes) -MaximumPackBytes ([long]$Plan.maximumPackBytes)
        $envelope = $sizedEnvelope.envelope
        $bridgeLimit = [int]$sizedEnvelope.bridgeBytesPerSide
        $mapLimit = [int]$sizedEnvelope.documentMapBytes
        $relativePath = "inputs\context-packs\$batchId.md"
        $path = Join-Path $RunDirectory $relativePath
        Write-DuoForgeTextAtomic -Path $path -Text ([string]$envelope.content)
        $actualBytes = [long](Get-Item -LiteralPath $path).Length
        $actualHash = Get-DuoForgeSha256 -Path $path
        if ($actualBytes -ne [long]$envelope.bytes -or $actualHash -ne [string]$envelope.sha256) {
            throw (New-DuoForgeException -Code 'DF-CONTEXT-PACK-INTEGRITY' -Message "문맥 배치 저장 결과가 렌더링 결과와 다릅니다: $batchId")
        }
        $batches.Add([ordered]@{
            batchId = $batchId
            candidateId = [string]$candidate.candidateId
            relativePath = $relativePath
            sha256 = $actualHash
            bytes = $actualBytes
            transmittedBytes = $actualBytes
            sourceId = [string]$source.sourceId
            snapshotName = [string]$source.snapshotName
            sourceSha256 = [string]$source.sourceSha256
            role = [string]$source.role
            documentId = [string]$source.documentId
            sectionIds = @($candidate.sectionIds)
            coreBytes = [long]$envelope.coreBytes
            overlapBytes = [long]$envelope.overlapBytes
            documentMapOmittedSectionCount = [int]$envelope.documentMapOmittedSectionCount
            bridgeBytesPerSide = $bridgeLimit
            documentMapBytes = $mapLimit
            evidenceContract = $envelope.evidenceContract
            regions = $envelope.regions
        })
    }
    if ($batches.Count -ne [int]$Plan.selectedBatchCount) { throw (New-DuoForgeException -Code 'DF-CONTEXT-PLAN-MISMATCH' -Message '실제 문맥 배치 수가 실행 계획과 다릅니다.') }

    $coverage = [System.Collections.Generic.List[object]]::new()
    $omittedIds = [System.Collections.Generic.List[string]]::new()
    $coreTotal = 0L
    $overlapTotal = 0L
    $transmittedTotal = 0L
    $fullyCoveredSources = 0
    foreach ($batch in $batches) { $coreTotal += [long]$batch.coreBytes; $overlapTotal += [long]$batch.overlapBytes; $transmittedTotal += [long]$batch.transmittedBytes }
    foreach ($source in $runtimeSources) {
        $sourceBatches = @($batches | Where-Object { [string]$_.sourceId -eq [string]$source.sourceId })
        $sourceCore = 0L
        $selectedSectionIds = @($sourceBatches | ForEach-Object { @($_.sectionIds) } | Sort-Object -Unique)
        foreach ($batch in $sourceBatches) { $sourceCore += [long]$batch.coreBytes }
        $omitted = @($source.sections | Where-Object { [string]$_.sectionId -notin $selectedSectionIds })
        $omittedBytes = 0L
        foreach ($section in $omitted) { $omittedBytes += [long]$section.bytes; $omittedIds.Add([string]$section.sectionId) }
        if ($sourceCore -eq [long]$source.bytes) { $fullyCoveredSources++ }
        $coverage.Add([ordered]@{
            sourceId = [string]$source.sourceId
            snapshotName = [string]$source.snapshotName
            documentId = [string]$source.documentId
            role = [string]$source.role
            totalBytes = [long]$source.bytes
            coreBytes = $sourceCore
            coveragePercent = if ([long]$source.bytes -eq 0) { 100.0 } else { [Math]::Round(($sourceCore / [double][long]$source.bytes) * 100, 2) }
            totalSections = @($source.sections).Count
            selectedSectionIds = $selectedSectionIds
            omittedSectionIds = @($omitted | ForEach-Object { [string]$_.sectionId })
            omittedBytes = $omittedBytes
        })
    }
    $documentCoverage = [System.Collections.Generic.List[object]]::new()
    foreach ($documentId in @($runtimeSources | ForEach-Object { [string]$_.documentId } | Sort-Object -Unique)) {
        $documentEntries = @($coverage | Where-Object { [string]$_.documentId -eq $documentId })
        $groupTotal = 0L
        $groupCore = 0L
        foreach ($entry in $documentEntries) { $groupTotal += [long]$entry.totalBytes; $groupCore += [long]$entry.coreBytes }
        $documentCoverage.Add([ordered]@{
            documentId = $documentId
            totalBytes = $groupTotal
            coreBytes = $groupCore
            coveragePercent = if ($groupTotal -eq 0) { 100.0 } else { [Math]::Round(($groupCore / [double]$groupTotal) * 100, 2) }
            sourceIds = @($documentEntries | ForEach-Object { [string]$_.sourceId })
        })
    }
    $actualByteCoverage = if ([long]$Plan.totalBytes -eq 0) { 100.0 } else { [Math]::Round(($coreTotal / [double][long]$Plan.totalBytes) * 100, 2) }
    $actualFileCoverage = if ($runtimeSources.Count -eq 0) { 100.0 } else { [Math]::Round(($fullyCoveredSources / [double]$runtimeSources.Count) * 100, 2) }
    $result.sources = @($runtimeSources | ForEach-Object {
        [ordered]@{
            sourceOrdinal = [int]$_.sourceOrdinal
            sourceId = [string]$_.sourceId
            snapshotName = [string]$_.snapshotName
            sourceSha256 = [string]$_.sourceSha256
            bytes = [long]$_.bytes
            role = [string]$_.role
            documentId = [string]$_.documentId
            sections = @($_.sections)
        }
    })
    $result.batches = @($batches)
    $result.selectedBatchCount = $batches.Count
    $result.selectedBytes = $coreTotal
    $result.coreBytes = $coreTotal
    $result.overlapBytes = $overlapTotal
    $result.transmittedBytes = $transmittedTotal
    $result.actualFileCoveragePercent = $actualFileCoverage
    $result.actualByteCoveragePercent = $actualByteCoverage
    $result.sourceCoverage = @($coverage)
    $result.documentCoverage = @($documentCoverage)
    $result.omittedSectionIds = @($omittedIds)
    $result.omittedBytes = [long]$Plan.totalBytes - $coreTotal
    $result.completionStatus = if ($coreTotal -eq [long]$Plan.totalBytes) { 'COMPLETED' } else { 'COMPLETED_PARTIAL' }
    return $result
}

function New-DuoForgeContextBatchFilesInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunDirectory,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Inventory,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Plan
    )

    $schemaVersion = [int](Get-DuoForgeObjectValue -Object $Plan -Name 'schemaVersion' -Default 1)
    if ($schemaVersion -eq 2) {
        return New-DuoForgeContextBatchFilesV2Internal -RunDirectory $RunDirectory -Inventory $Inventory -Plan $Plan
    }
    if ($schemaVersion -ne 1) { throw (New-DuoForgeException -Code 'DF-CONTEXT-PLAN-SCHEMA' -Message "지원하지 않는 문맥 계획 세대입니다: $schemaVersion") }

    if (-not [bool]$Plan.enabled) {
        $result = ConvertTo-DuoForgeHashtable -InputObject $Plan
        $result.batches = @()
        $result.actualFileCoveragePercent = 100.0
        $result.actualByteCoveragePercent = 100.0
        return $result
    }
    if ([int]$Plan.selectedBatchCount -lt 1) { throw (New-DuoForgeException -Code 'DF-CONTEXT-NO-CAPACITY' -Message '큰 문서를 나눠 읽는 데 필요한 AI 요청 횟수가 부족합니다. 입력 범위를 줄여 주세요.') }

    $documents = @(Get-DuoForgePromptDocuments -RunDirectory $RunDirectory -Inventory $Inventory)
    $pieces = [System.Collections.Generic.List[object]]::new()
    $pieceLimit = [int][Math]::Max(1024, [long]$Plan.targetBatchBytes - 4096)
    foreach ($document in $documents) {
        $part = 0
        foreach ($chunk in @(Split-DuoForgeTextByUtf8BytesInternal -Text ([string]$document.content) -MaximumBytes $pieceLimit)) {
            $part++
            $pieces.Add([ordered]@{
                snapshotName = [string]$document.snapshotName
                role = [string]$document.role
                part = $part
                content = $chunk
                bytes = [System.Text.UTF8Encoding]::new($false).GetByteCount($chunk)
            })
        }
    }

    $packedPieces = [System.Collections.Generic.List[object]]::new()
    $currentPieces = [System.Collections.Generic.List[object]]::new()
    $currentBytes = 0L
    foreach ($piece in $pieces) {
        if ($currentPieces.Count -gt 0 -and ($currentBytes + [long]$piece.bytes) -gt [long]$Plan.targetBatchBytes) {
            $packedPieces.Add(@($currentPieces))
            $currentPieces = [System.Collections.Generic.List[object]]::new()
            $currentBytes = 0L
        }
        $currentPieces.Add($piece)
        $currentBytes += [long]$piece.bytes
    }
    if ($currentPieces.Count -gt 0) { $packedPieces.Add(@($currentPieces)) }

    $batches = [System.Collections.Generic.List[object]]::new()
    $analyzedSnapshots = @{}
    $analyzedBytes = 0L
    $limit = [Math]::Min([int]$Plan.selectedBatchCount, $packedPieces.Count)
    for ($index = 0; $index -lt $limit; $index++) {
        $batchPieces = @($packedPieces[$index])
        $batchId = 'batch-{0:D3}' -f ($index + 1)
        $contentParts = [System.Collections.Generic.List[string]]::new()
        foreach ($piece in $batchPieces) {
            $contentParts.Add(@"
<DUOFORGE_CONTEXT_PART batch="$batchId" source="$($piece.snapshotName)" role="$($piece.role)" part="$($piece.part)">
$($piece.content)
</DUOFORGE_CONTEXT_PART>
"@)
        }
        $content = $contentParts -join [Environment]::NewLine
        $path = Join-Path $RunDirectory ("inputs\context-packs\{0}.md" -f $batchId)
        Write-DuoForgeTextAtomic -Path $path -Text $content
        $bytes = [long](Get-Item -LiteralPath $path).Length
        $sourceBytes = 0L
        foreach ($batchPiece in $batchPieces) { $sourceBytes += [long]$batchPiece.bytes }
        $snapshotNames = @($batchPieces | ForEach-Object { [string]$_.snapshotName } | Sort-Object -Unique)
        $roles = @($batchPieces | ForEach-Object { [string]$_.role } | Sort-Object -Unique)
        $batches.Add([ordered]@{ batchId = $batchId; path = $path; sha256 = Get-DuoForgeSha256 -Path $path; bytes = $bytes; snapshotNames = $snapshotNames; roles = $roles; sourceBytes = $sourceBytes })
        foreach ($name in $snapshotNames) { $analyzedSnapshots[$name] = $true }
        $analyzedBytes += $sourceBytes
    }
    $actualByteCoverage = if ([long]$Plan.totalBytes -eq 0) { 100.0 } else { [Math]::Round(($analyzedBytes / [double][long]$Plan.totalBytes) * 100, 2) }
    $actualFileCoverage = if ([int]$Plan.totalFiles -eq 0) { 100.0 } else { [Math]::Round(($analyzedSnapshots.Count / [double][int]$Plan.totalFiles) * 100, 2) }
    $result = ConvertTo-DuoForgeHashtable -InputObject $Plan
    $result.selectedBatchCount = $batches.Count
    $result.selectedBytes = $analyzedBytes
    $result.actualFileCoveragePercent = $actualFileCoverage
    $result.actualByteCoveragePercent = $actualByteCoverage
    $result.batches = @($batches)
    $result.completionStatus = if ($actualFileCoverage -ge 99.99 -and $actualByteCoverage -ge 99.99) { 'COMPLETED' } else { 'COMPLETED_PARTIAL' }
    return $result
}

function New-DuoForgeCoverageMarkdownInternal {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$ContextPlan)

    $schemaVersion = [int](Get-DuoForgeObjectValue -Object $ContextPlan -Name 'schemaVersion' -Default 1)
    if ($schemaVersion -eq 2) {
        $lines = @(
            '# 문맥 커버리지', '',
            "- 계획 스키마: 2",
            "- 분할 정책: $($ContextPlan.segmentationPolicy)",
            "- 봉투 정책: $($ContextPlan.envelopePolicy)",
            "- 완료 판정: $($ContextPlan.completionStatus)",
            "- 분석 가능 파일: $($ContextPlan.totalFiles)",
            "- 전체 텍스트 바이트: $($ContextPlan.totalBytes)",
            "- CORE 바이트: $($ContextPlan.coreBytes)",
            "- context-only 중복 바이트: $($ContextPlan.overlapBytes)",
            "- 전송 팩 바이트: $($ContextPlan.transmittedBytes)",
            "- 실제 파일 커버리지: $($ContextPlan.actualFileCoveragePercent)%",
            "- 실제 CORE 바이트 커버리지: $($ContextPlan.actualByteCoveragePercent)%",
            "- 실행 배치: $(@($ContextPlan.batches).Count) / 필요 배치 $($ContextPlan.requiredBatchCount)", ''
        )
        if ([string]$ContextPlan.completionStatus -eq 'COMPLETED_PARTIAL') {
            $lines += '> 문서 크기와 AI 요청 횟수 제한 때문에 일부 내용은 읽지 못했습니다. 이 결과만으로 문서 전체를 판단하면 안 됩니다.'
            $lines += ''
        }
        $lines += '## 문서별 CORE 커버리지'
        $lines += ''
        $lines += '| 문서 | 전체 바이트 | CORE 바이트 | 커버리지 |'
        $lines += '|---|---:|---:|---:|'
        foreach ($document in @($ContextPlan.documentCoverage)) {
            $lines += "| $($document.documentId) | $($document.totalBytes) | $($document.coreBytes) | $($document.coveragePercent)% |"
        }
        $lines += ''
        $lines += '## 소스별 섹션 커버리지'
        $lines += ''
        $lines += '| 소스 | 문서 | 역할 | 전체 섹션 | 누락 섹션 | 누락 바이트 | CORE 커버리지 |'
        $lines += '|---|---|---|---:|---:|---:|---:|'
        foreach ($source in @($ContextPlan.sourceCoverage)) {
            $lines += "| $($source.sourceId) | $($source.documentId) | $($source.role) | $($source.totalSections) | $(@($source.omittedSectionIds).Count) | $($source.omittedBytes) | $($source.coveragePercent)% |"
        }
        $lines += ''
        $lines += '## 배치 메타데이터'
        $lines += ''
        $lines += '| 배치 | 소스 | 문서 | 섹션 ID | CORE 바이트 | context-only 바이트 | 전송 바이트 |'
        $lines += '|---|---|---|---|---:|---:|---:|'
        foreach ($batch in @($ContextPlan.batches)) {
            $lines += "| $($batch.batchId) | $($batch.sourceId) | $($batch.documentId) | $(@($batch.sectionIds) -join ', ') | $($batch.coreBytes) | $($batch.overlapBytes) | $($batch.transmittedBytes) |"
        }
        if (@($ContextPlan.omittedSectionIds).Count -gt 0) {
            $lines += ''
            $lines += "- 누락 섹션 ID: $(@($ContextPlan.omittedSectionIds) -join ', ')"
            $lines += "- 누락 CORE 바이트: $($ContextPlan.omittedBytes)"
        }
        return ($lines -join [Environment]::NewLine) + [Environment]::NewLine
    }
    if ($schemaVersion -ne 1) { throw (New-DuoForgeException -Code 'DF-CONTEXT-PLAN-SCHEMA' -Message "지원하지 않는 문맥 계획 세대입니다: $schemaVersion") }

    $lines = @(
        '# 문맥 커버리지', '',
        "- 완료 판정: $($ContextPlan.completionStatus)",
        "- 분석 가능 파일: $($ContextPlan.totalFiles)",
        "- 전체 텍스트 바이트: $($ContextPlan.totalBytes)",
        "- 실제 파일 커버리지: $($ContextPlan.actualFileCoveragePercent)%",
        "- 실제 바이트 커버리지: $($ContextPlan.actualByteCoveragePercent)%",
        "- 실행 배치: $(@($ContextPlan.batches).Count) / 필요 배치 $($ContextPlan.requiredBatchCount)", ''
    )
    if ([string]$ContextPlan.completionStatus -eq 'COMPLETED_PARTIAL') {
        $lines += '> 문서 크기와 AI 요청 횟수 제한 때문에 일부 내용은 읽지 못했습니다. 이 결과만으로 문서 전체를 판단하면 안 됩니다.'
        $lines += ''
    }
    $lines += '| 배치 | 스냅샷 | 역할 | 원문 바이트 |'
    $lines += '|---|---|---|---:|'
    foreach ($batch in @($ContextPlan.batches)) { $lines += "| $($batch.batchId) | $(@($batch.snapshotNames) -join ', ') | $(@($batch.roles) -join ', ') | $($batch.sourceBytes) |" }
    return ($lines -join [Environment]::NewLine) + [Environment]::NewLine
}
