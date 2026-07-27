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

function New-DuoForgeContextBatchPlanInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$ValidationResult,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config,
        [Parameter(Mandatory)][System.Collections.IDictionary]$BaseExecutionPlan
    )

    $sources = @(Get-DuoForgeValidationSourceRecordsInternal -ValidationResult $ValidationResult)
    $totalBytes = 0L
    foreach ($source in $sources) { $totalBytes += [long](Get-DuoForgeObjectValue -Object $source -Name 'bytes' -Default 0) }
    $maxInputBytes = [long]$Config.limits.maxInputBytesPerCall
    $directThreshold = [long][Math]::Floor($maxInputBytes * 0.65)
    $targetBatchBytes = [long][Math]::Max(32768, [Math]::Floor($maxInputBytes * 0.55))
    if ($totalBytes -le $directThreshold) {
        return [ordered]@{
            schemaVersion = 1
            enabled = $false
            totalFiles = $sources.Count
            totalBytes = $totalBytes
            targetBatchBytes = $targetBatchBytes
            requiredBatchCount = 0
            selectedBatchCount = 0
            selectedBytes = $totalBytes
            predictedFileCoveragePercent = 100.0
            predictedByteCoveragePercent = 100.0
            requiresPartialConsent = $false
            completionStatus = 'COMPLETED'
        }
    }

    $pieceLimit = [long][Math]::Max(1024, $targetBatchBytes - 4096)
    $requiredBatchCount = 0
    $packedBytes = 0L
    foreach ($source in $sources) {
        $remainingSourceBytes = [long](Get-DuoForgeObjectValue -Object $source -Name 'bytes' -Default 0)
        while ($remainingSourceBytes -gt 0) {
            $pieceBytes = [Math]::Min($pieceLimit, $remainingSourceBytes)
            if ($packedBytes -eq 0 -or ($packedBytes + $pieceBytes) -gt $targetBatchBytes) {
                $requiredBatchCount++
                $packedBytes = 0L
            }
            $packedBytes += $pieceBytes
            $remainingSourceBytes -= $pieceBytes
        }
    }
    $capacity = [int]::MaxValue
    foreach ($provider in @('codex', 'claude')) {
        $remainingCalls = [Math]::Max(0, [int]$Config.limits.maxCallsPerProviderPerRun - [int]$BaseExecutionPlan.providers[$provider].maximumCalls)
        $providerCapacity = [int][Math]::Floor($remainingCalls / 2)
        $capacity = [Math]::Min($capacity, $providerCapacity)
    }
    if ($capacity -eq [int]::MaxValue) { $capacity = 0 }
    $selectedBatchCount = [Math]::Min($requiredBatchCount, $capacity)
    $selectedBytes = [Math]::Min($totalBytes, [long]$selectedBatchCount * $pieceLimit)
    $byteCoverage = if ($totalBytes -eq 0) { 100.0 } else { [Math]::Round(($selectedBytes / [double]$totalBytes) * 100, 2) }
    $fileCoverage = if ($selectedBytes -ge $totalBytes) { 100.0 } else { [Math]::Round(($selectedBatchCount / [double]$requiredBatchCount) * 100, 2) }
    $partial = $selectedBytes -lt $totalBytes
    return [ordered]@{
        schemaVersion = 1
        enabled = $true
        totalFiles = $sources.Count
        totalBytes = $totalBytes
        targetBatchBytes = $targetBatchBytes
        requiredBatchCount = $requiredBatchCount
        selectedBatchCount = $selectedBatchCount
        selectedBytes = $selectedBytes
        predictedFileCoveragePercent = $fileCoverage
        predictedByteCoveragePercent = $byteCoverage
        requiresPartialConsent = $partial
        completionStatus = if ($partial) { 'COMPLETED_PARTIAL' } else { 'COMPLETED' }
    }
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

function New-DuoForgeContextBatchFilesInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunDirectory,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Inventory,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Plan
    )

    if (-not [bool]$Plan.enabled) {
        $result = ConvertTo-DuoForgeHashtable -InputObject $Plan
        $result.batches = @()
        $result.actualFileCoveragePercent = 100.0
        $result.actualByteCoveragePercent = 100.0
        return $result
    }
    if ([int]$Plan.selectedBatchCount -lt 1) { throw (New-DuoForgeException -Code 'DF-CONTEXT-NO-CAPACITY' -Message '대용량 문맥을 분석할 호출 예산이 없습니다. 입력 범위를 줄여 주세요.') }

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
        $lines += '> 일부 입력은 문맥·호출 예산 제한으로 분석되지 않았습니다. 이 결과는 전체 입력에 대한 단정적 결론이 아닙니다.'
        $lines += ''
    }
    $lines += '| 배치 | 스냅샷 | 역할 | 원문 바이트 |'
    $lines += '|---|---|---|---:|'
    foreach ($batch in @($ContextPlan.batches)) { $lines += "| $($batch.batchId) | $(@($batch.snapshotNames) -join ', ') | $(@($batch.roles) -join ', ') | $($batch.sourceBytes) |" }
    return ($lines -join [Environment]::NewLine) + [Environment]::NewLine
}
