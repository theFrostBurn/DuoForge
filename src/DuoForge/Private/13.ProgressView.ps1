function ConvertTo-DuoForgeProgressTextInternal {
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyString()][string]$Text,
        [ValidateRange(1, 4000)][int]$MaximumCharacters = 1200
    )

    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $safe = $Text -replace "`e\][^`a]*(?:`a|`e\\)", ''
    $safe = $safe -replace "`e\[[0-?]*[ -/]*[@-~]", ''
    $safe = $safe -replace '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F-\x9F]', ' '
    $safe = $safe -replace '\s+', ' '
    $safe = $safe.Trim()
    if ($safe.Length -gt $MaximumCharacters) {
        $cutLength = $MaximumCharacters
        if ($cutLength -gt 0 -and [char]::IsHighSurrogate($safe[$cutLength - 1]) -and [char]::IsLowSurrogate($safe[$cutLength])) {
            $cutLength--
        }
        $safe = $safe.Substring(0, $cutLength)
    }
    return $safe
}

function Get-DuoForgeProgressTextUnitsInternal {
    [CmdletBinding()]
    param([AllowEmptyString()][Parameter(Mandatory)][string]$Text)

    $units = [System.Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt $Text.Length; $index++) {
        $isSurrogatePair = [char]::IsHighSurrogate($Text[$index]) -and $index + 1 -lt $Text.Length -and [char]::IsLowSurrogate($Text[$index + 1])
        $codePoint = if ($isSurrogatePair) { [System.Char]::ConvertToUtf32($Text, $index) } elseif ([char]::IsSurrogate($Text[$index])) { 0xFFFD } else { [int]$Text[$index] }
        $unitText = if ($isSurrogatePair) {
            $value = $Text.Substring($index, 2)
            $index++
            $value
        }
        else {
            [string]$Text[$index]
        }

        $category = [System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($unitText, 0)
        $width = if ($category -in @(
            [System.Globalization.UnicodeCategory]::NonSpacingMark,
            [System.Globalization.UnicodeCategory]::SpacingCombiningMark,
            [System.Globalization.UnicodeCategory]::EnclosingMark
        )) {
            0
        }
        elseif (
            ($codePoint -ge 0x1100 -and $codePoint -le 0x115F) -or
            ($codePoint -ge 0x2329 -and $codePoint -le 0x232A) -or
            ($codePoint -ge 0x2E80 -and $codePoint -le 0xA4CF) -or
            ($codePoint -ge 0xAC00 -and $codePoint -le 0xD7A3) -or
            ($codePoint -ge 0xF900 -and $codePoint -le 0xFAFF) -or
            ($codePoint -ge 0xFE10 -and $codePoint -le 0xFE6F) -or
            ($codePoint -ge 0xFF01 -and $codePoint -le 0xFF60) -or
            ($codePoint -ge 0xFFE0 -and $codePoint -le 0xFFE6) -or
            ($codePoint -ge 0x1F300 -and $codePoint -le 0x1FAFF) -or
            ($codePoint -ge 0x20000 -and $codePoint -le 0x3FFFD)
        ) {
            2
        }
        else {
            1
        }
        $units.Add([ordered]@{ text = $unitText; width = $width })
    }
    return @($units)
}

function Get-DuoForgeProgressTextWidthInternal {
    [CmdletBinding()]
    param([AllowEmptyString()][Parameter(Mandatory)][string]$Text)

    $width = 0
    foreach ($unit in @(Get-DuoForgeProgressTextUnitsInternal -Text $Text)) { $width += [int]$unit.width }
    return $width
}

function Limit-DuoForgeProgressTextInternal {
    [CmdletBinding()]
    param(
        [AllowEmptyString()][Parameter(Mandatory)][string]$Text,
        [ValidateRange(1, 1000)][int]$Width
    )

    if ((Get-DuoForgeProgressTextWidthInternal -Text $Text) -le $Width) { return $Text }
    if ($Width -eq 1) { return '…' }
    $builder = [System.Text.StringBuilder]::new()
    $used = 0
    foreach ($unit in @(Get-DuoForgeProgressTextUnitsInternal -Text $Text)) {
        if ($used + [int]$unit.width -gt $Width - 1) { break }
        $null = $builder.Append([string]$unit.text)
        $used += [int]$unit.width
    }
    return $builder.ToString().TrimEnd() + '…'
}

function Split-DuoForgeProgressTextInternal {
    [CmdletBinding()]
    param(
        [AllowEmptyString()][Parameter(Mandatory)][string]$Text,
        [ValidateRange(4, 1000)][int]$Width,
        [ValidateRange(1, 100)][int]$MaximumLines = 3
    )

    $safe = ConvertTo-DuoForgeProgressTextInternal -Text $Text
    if ([string]::IsNullOrWhiteSpace($safe)) { return @() }
    $lines = [System.Collections.Generic.List[string]]::new()
    $remaining = $safe
    $truncated = $false
    while (-not [string]::IsNullOrWhiteSpace($remaining) -and $lines.Count -lt $MaximumLines) {
        if ((Get-DuoForgeProgressTextWidthInternal -Text $remaining) -le $Width) {
            $lines.Add($remaining.Trim())
            $remaining = ''
            break
        }

        $builder = [System.Text.StringBuilder]::new()
        $used = 0
        $lastBreakLength = -1
        $consumedLength = 0
        foreach ($unit in @(Get-DuoForgeProgressTextUnitsInternal -Text $remaining)) {
            $unitText = [string]$unit.text
            $unitWidth = [int]$unit.width
            if ($used + $unitWidth -gt $Width) { break }
            $null = $builder.Append($unitText)
            $used += $unitWidth
            $consumedLength += $unitText.Length
            if ($unitText -eq ' ') { $lastBreakLength = $builder.Length }
        }
        if ($builder.Length -eq 0) { break }
        $nextUnitIsSpace = $consumedLength -lt $remaining.Length -and [char]::IsWhiteSpace($remaining[$consumedLength])
        $takeLength = if ($nextUnitIsSpace) { $builder.Length } elseif ($lastBreakLength -gt 0) { $lastBreakLength - 1 } else { $builder.Length }
        $line = $remaining.Substring(0, $takeLength).Trim()
        if ([string]::IsNullOrWhiteSpace($line)) {
            $takeLength = $consumedLength
            $line = $remaining.Substring(0, $takeLength).Trim()
        }
        $lines.Add($line)
        $remaining = $remaining.Substring([Math]::Min($remaining.Length, $takeLength)).TrimStart()
    }
    if (-not [string]::IsNullOrWhiteSpace($remaining)) { $truncated = $true }
    if ($truncated -and $lines.Count -gt 0) {
        $last = [string]$lines[$lines.Count - 1]
        $lines[$lines.Count - 1] = Limit-DuoForgeProgressTextInternal -Text ($last.TrimEnd('…') + '…') -Width $Width
    }
    return @($lines)
}

function Get-DuoForgeProgressStageLabelInternal {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Stage)

    return Get-DuoForgeDisplayStageLabelInternal -Stage $Stage
}

function Get-DuoForgeProgressModeLabelInternal {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Mode)

    return Get-DuoForgeDisplayModeLabelInternal -Mode $Mode
}

function Get-DuoForgeProgressTargetLabelInternal {
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyString()][string]$TargetDocumentId,
        [AllowNull()][AllowEmptyString()][string]$Mode
    )

    switch ($TargetDocumentId) {
        'A' { '문서 A' }
        'B' { '문서 B' }
        'merged' {
            switch ($Mode) {
                'shared-document' { '공동 문서' }
                'document-merge' { '합의 문서 C' }
                default { '통합 문서' }
            }
        }
        default {
            if ([string]::IsNullOrWhiteSpace($TargetDocumentId)) { return '' }
            '대상 ' + (ConvertTo-DuoForgeProgressTextInternal -Text $TargetDocumentId -MaximumCharacters 80)
        }
    }
}

function Get-DuoForgeProgressRecordTargetLabelInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Record,
        [AllowNull()][AllowEmptyString()][string]$Mode
    )

    $targetLabel = Get-DuoForgeProgressTargetLabelInternal -TargetDocumentId ([string](Get-DuoForgeObjectValue -Object $Record -Name 'targetDocumentId')) -Mode $Mode
    if (-not [string]::IsNullOrWhiteSpace($targetLabel)) { return $targetLabel }
    if ($Mode -ne 'dual-document') { return '' }

    $documentIds = @(
        @(Get-DuoForgeObjectValue -Object $Record -Name 'sourceDocumentIds' -Default @()) |
            ForEach-Object { [string]$_ } |
            Where-Object { $_ -in @('A', 'B') } |
            Select-Object -Unique
    )
    if ($documentIds.Count -eq 2 -and 'A' -in $documentIds -and 'B' -in $documentIds) { return '문서 A/B' }
    if ($documentIds.Count -eq 1) { return Get-DuoForgeProgressTargetLabelInternal -TargetDocumentId $documentIds[0] -Mode $Mode }
    return ''
}

function Get-DuoForgeProgressStateLabelInternal {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Status)

    return Get-DuoForgeDisplayStateLabelInternal -Status $Status
}

function Get-DuoForgeProgressRetryLabelInternal {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$RetryMode)

    switch ($RetryMode) {
        'FORMAT_REPAIR' { '답변 형식 다시 확인 대기' }
        'STANDARD_RETRY' { 'AI 답변 재시도 대기' }
        default { '재시도 대기' }
    }
}

function Get-DuoForgeProgressDiagnosticReferenceInternal {
    [CmdletBinding()]
    param(
        [AllowNull()]$Source,
        [string]$RunDirectory
    )

    if ($null -eq $Source) { return $null }
    $data = Get-DuoForgeObjectValue -Object $Source -Name 'data' -Default $Source
    $diagnosticId = [string](Get-DuoForgeObjectValue -Object $data -Name 'diagnosticId')
    $code = [string](Get-DuoForgeObjectValue -Object $data -Name 'code')
    $location = [string](Get-DuoForgeObjectValue -Object $data -Name 'diagnosticsLocation')
    $relativePath = [string](Get-DuoForgeObjectValue -Object $data -Name 'diagnosticsRelativePath')
    $diagnosticsPath = Resolve-DuoForgeDiagnosticsPathInternal -RunDirectory $RunDirectory -Location $location -RelativePath $relativePath -DiagnosticsPath ([string](Get-DuoForgeObjectValue -Object $data -Name 'diagnosticsPath'))
    $warningCode = [string](Get-DuoForgeObjectValue -Object $data -Name 'diagnosticWarningCode')
    if ([string]::IsNullOrWhiteSpace($diagnosticId) -and [string]::IsNullOrWhiteSpace($warningCode)) { return $null }
    return [ordered]@{ code = $code; diagnosticId = $diagnosticId; diagnosticsPath = $diagnosticsPath; diagnosticWarningCode = $warningCode }
}

function Get-DuoForgeProgressBarrierStatusInternal {
    [CmdletBinding()]
    param([AllowEmptyCollection()][Parameter(Mandatory)][object[]]$Steps)

    $statuses = @($Steps | ForEach-Object { [string]$_.status })
    if ($statuses.Count -gt 0 -and @($statuses | Where-Object { $_ -eq 'COMMITTED' }).Count -eq $statuses.Count) { return 'COMMITTED' }
    if ('STARTED' -in $statuses) { return 'STARTED' }
    if ('FAILED' -in $statuses) { return 'FAILED' }
    if ('STALE' -in $statuses) { return 'STALE' }
    if ('COMMITTED' -in $statuses) { return 'PARTIAL' }
    return 'PENDING'
}

function Get-DuoForgeProgressBarrierMarkInternal {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Status)

    switch ($Status) {
        'COMMITTED' { '✓' }
        'STARTED' { '●' }
        'FAILED' { '↻' }
        'STALE' { '↻' }
        'PARTIAL' { '◐' }
        default { '○' }
    }
}

function Get-DuoForgeProgressProviderMarkInternal {
    [CmdletBinding()]
    param([AllowEmptyCollection()][Parameter(Mandatory)][object[]]$Steps)

    if ($Steps.Count -eq 0) { return '—' }
    return Get-DuoForgeProgressBarrierMarkInternal -Status (Get-DuoForgeProgressBarrierStatusInternal -Steps $Steps)
}

function Get-DuoForgeProgressBarriersInternal {
    [CmdletBinding()]
    param([AllowEmptyCollection()][Parameter(Mandatory)][object[]]$Steps)

    $barriers = [System.Collections.Generic.List[object]]::new()
    $current = $null
    foreach ($step in $Steps) {
        $key = '{0}|{1}' -f [int]$step.round, [string]$step.stage
        if ($null -eq $current -or [string]$current.key -ne $key) {
            if ($null -ne $current) {
                $current.steps = @($current.stepList)
                $current.Remove('stepList')
                $current.status = Get-DuoForgeProgressBarrierStatusInternal -Steps @($current.steps)
                $barriers.Add($current)
            }
            $current = [ordered]@{
                key = $key
                round = [int]$step.round
                stage = [string]$step.stage
                label = Get-DuoForgeProgressStageLabelInternal -Stage ([string]$step.stage)
                stepList = [System.Collections.Generic.List[object]]::new()
            }
        }
        $current.stepList.Add($step)
    }
    if ($null -ne $current) {
        $current.steps = @($current.stepList)
        $current.Remove('stepList')
        $current.status = Get-DuoForgeProgressBarrierStatusInternal -Steps @($current.steps)
        $barriers.Add($current)
    }
    return @($barriers)
}

function Get-DuoForgeProgressArtifactRecordInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Step,
        [Parameter(Mandatory)][ValidateSet('workflow-v1', 'workflow-v2')][string]$WorkflowVersion
    )

    if ([string]$Step.status -ne 'COMMITTED' -or [string]::IsNullOrWhiteSpace([string]$Step.artifactPath)) { return $null }
    if (-not (Test-Path -LiteralPath ([string]$Step.artifactPath) -PathType Leaf)) { return $null }
    if ([string]::IsNullOrWhiteSpace([string]$Step.artifactHash)) { return $null }
    try {
        if ((Get-DuoForgeSha256 -Path ([string]$Step.artifactPath)) -ne [string]$Step.artifactHash) { return $null }
        $artifact = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path ([string]$Step.artifactPath))
        $result = Get-DuoForgeObjectValue -Object $artifact -Name 'result'
        if ($null -eq $result) { return $null }
        $null = Test-DuoForgeStageResultInternal -Result $result -ExpectedStage ([string]$Step.stage) -ExpectedProvider ([string]$Step.provider) -WorkflowVersion $WorkflowVersion -ExpectedTargetDocumentId (Get-DuoForgeObjectValue -Object $Step -Name 'targetDocumentId') -ExpectedSourceDocumentIds @(Get-DuoForgeObjectValue -Object $Step -Name 'sourceDocumentIds' -Default @()) -ThrowOnError
    }
    catch { return $null }

    $issueCounts = [ordered]@{ critical = 0; major = 0; minor = 0 }
    foreach ($issue in @((Get-DuoForgeObjectValue -Object $result -Name 'issues' -Default @()))) {
        $severity = [string](Get-DuoForgeObjectValue -Object $issue -Name 'severity')
        if ($issueCounts.Contains($severity)) { $issueCounts[$severity]++ }
    }
    $responseCounts = [ordered]@{ ACCEPTED = 0; PARTIALLY_ACCEPTED = 0; REJECTED = 0; DEFERRED = 0; NEEDS_EVIDENCE = 0; ASK_USER = 0 }
    foreach ($response in @((Get-DuoForgeObjectValue -Object $result -Name 'issueResponses' -Default @()))) {
        $disposition = [string](Get-DuoForgeObjectValue -Object $response -Name 'disposition')
        if ($responseCounts.Contains($disposition)) { $responseCounts[$disposition]++ }
    }
    $adoptionCounts = [ordered]@{ ACCEPTED = 0; PARTIALLY_ACCEPTED = 0; REJECTED = 0; DEFERRED = 0 }
    foreach ($adoption in @((Get-DuoForgeObjectValue -Object $result -Name 'adoptions' -Default @()))) {
        $disposition = [string](Get-DuoForgeObjectValue -Object $adoption -Name 'disposition')
        if ($adoptionCounts.Contains($disposition)) { $adoptionCounts[$disposition]++ }
    }
    return [ordered]@{
        stepKey = [string]$Step.stepKey
        provider = [string]$Step.provider
        round = [int]$Step.round
        stage = [string]$Step.stage
        targetDocumentId = [string](Get-DuoForgeObjectValue -Object $Step -Name 'targetDocumentId')
        sourceDocumentIds = @(Get-DuoForgeObjectValue -Object $Step -Name 'sourceDocumentIds' -Default @())
        label = Get-DuoForgeProgressStageLabelInternal -Stage ([string]$Step.stage)
        summary = if ([string]$Step.stage -eq 'context-batch-analysis') { '나눈 문서의 분석 결과를 안전하게 확인하고 저장했습니다.' } else { ConvertTo-DuoForgeProgressTextInternal -Text ([string](Get-DuoForgeObjectValue -Object $result -Name 'summary')) }
        issueCounts = $issueCounts
        responseCounts = $responseCounts
        adoptionCounts = $adoptionCounts
        questionCount = @((Get-DuoForgeObjectValue -Object $result -Name 'openQuestions' -Default @())).Count
        attemptCount = [int]$Step.attemptCount
    }
}

function Get-DuoForgeProgressActionSummaryInternal {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Record)

    $groups = [System.Collections.Generic.List[string]]::new()
    $issues = Get-DuoForgeObjectValue -Object $Record -Name 'issueCounts' -Default ([ordered]@{})
    $issueParts = [System.Collections.Generic.List[string]]::new()
    foreach ($item in @(
        [ordered]@{ key = 'critical'; label = '반드시 해결' },
        [ordered]@{ key = 'major'; label = '중요' },
        [ordered]@{ key = 'minor'; label = '참고' }
    )) {
        $count = [int](Get-DuoForgeObjectValue -Object $issues -Name ([string]$item.key) -Default 0)
        if ($count -gt 0) { $issueParts.Add(('{0} {1}' -f $item.label, $count)) }
    }
    if ($issueParts.Count -gt 0) { $groups.Add('새 검토 항목: ' + ($issueParts -join ' · ')) }

    $responses = Get-DuoForgeObjectValue -Object $Record -Name 'responseCounts' -Default ([ordered]@{})
    $responseParts = [System.Collections.Generic.List[string]]::new()
    foreach ($item in @(
        [ordered]@{ key = 'ACCEPTED'; label = '수용' },
        [ordered]@{ key = 'PARTIALLY_ACCEPTED'; label = '일부 수용' },
        [ordered]@{ key = 'REJECTED'; label = '거부' },
        [ordered]@{ key = 'DEFERRED'; label = '보류' },
        [ordered]@{ key = 'NEEDS_EVIDENCE'; label = '자료 필요' },
        [ordered]@{ key = 'ASK_USER'; label = '답변 필요' }
    )) {
        $count = [int](Get-DuoForgeObjectValue -Object $responses -Name ([string]$item.key) -Default 0)
        if ($count -gt 0) { $responseParts.Add(('{0} {1}' -f $item.label, $count)) }
    }
    if ($responseParts.Count -gt 0) { $groups.Add('검토 의견 처리: ' + ($responseParts -join ' · ')) }

    $adoptions = Get-DuoForgeObjectValue -Object $Record -Name 'adoptionCounts' -Default ([ordered]@{})
    $adoptionParts = [System.Collections.Generic.List[string]]::new()
    foreach ($item in @(
        [ordered]@{ key = 'ACCEPTED'; label = '반영' },
        [ordered]@{ key = 'PARTIALLY_ACCEPTED'; label = '일부 반영' },
        [ordered]@{ key = 'REJECTED'; label = '미반영' },
        [ordered]@{ key = 'DEFERRED'; label = '보류' }
    )) {
        $count = [int](Get-DuoForgeObjectValue -Object $adoptions -Name ([string]$item.key) -Default 0)
        if ($count -gt 0) { $adoptionParts.Add(('{0} {1}' -f $item.label, $count)) }
    }
    if ($adoptionParts.Count -gt 0) { $groups.Add('문서 반영: ' + ($adoptionParts -join ' · ')) }

    return $groups -join ' | '
}

function Get-DuoForgeProgressSnapshotInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunDirectory,
        [System.Collections.IDictionary]$LastEvent
    )

    $manifest = Read-DuoForgeJson -Path (Join-Path $RunDirectory 'manifest.json')
    $state = Read-DuoForgeJson -Path (Join-Path $RunDirectory 'state.json')
    $stepsPath = Join-Path $RunDirectory 'steps.json'
    if (Test-Path -LiteralPath $stepsPath -PathType Leaf) {
        $graph = Read-DuoForgeJson -Path $stepsPath
    }
    else {
        $firstSynthesizer = if ([string]::IsNullOrWhiteSpace([string]$manifest.firstSynthesizer)) { 'alternate' } else { [string]$manifest.firstSynthesizer }
        $contextPlanPath = Join-Path $RunDirectory 'inputs\context-plan.json'
        $contextBatchCount = if (Test-Path -LiteralPath $contextPlanPath -PathType Leaf) { @((Read-DuoForgeJson -Path $contextPlanPath).batches).Count } else { 0 }
        $workflowVersion = Get-DuoForgeWorkflowVersionInternal -Manifest $manifest
        $contextBatchDocumentIds = @(Get-DuoForgeContextBatchDocumentIdsInternal -RunDirectory $RunDirectory)
        $graph = New-DuoForgeStageGraph -Mode ([string]$manifest.mode) -MaxRounds ([int]$manifest.maxRounds) -FirstSynthesizer $firstSynthesizer -ContextBatchCount $contextBatchCount -ContextBatchDocumentIds $contextBatchDocumentIds -WorkflowVersion $workflowVersion
    }

    $workflowVersion = Get-DuoForgeWorkflowVersionInternal -Manifest $manifest
    $artifactRecords = [System.Collections.Generic.List[object]]::new()
    foreach ($step in @($graph.steps)) {
        $record = Get-DuoForgeProgressArtifactRecordInternal -Step $step -WorkflowVersion $workflowVersion
        if ($null -ne $record) { $artifactRecords.Add($record) }
    }
    $recentCommitted = @($artifactRecords | Select-Object -Last 3)
    $latest = @($recentCommitted | Select-Object -Last 1)

    $activeSteps = @($graph.steps | Where-Object { [string]$_.status -eq 'STARTED' })
    $committed = @($graph.steps | Where-Object { [string]$_.status -eq 'COMMITTED' }).Count
    $ledger = Read-DuoForgeJson -Path (Join-Path $RunDirectory 'issues.json')
    return [ordered]@{
        runDirectory = $RunDirectory
        runId = [string]$state.runId
        name = ConvertTo-DuoForgeProgressTextInternal -Text ([string]$manifest.name) -MaximumCharacters 160
        mode = [string]$state.mode
        modeLabel = Get-DuoForgeProgressModeLabelInternal -Mode ([string]$state.mode)
        status = [string]$state.status
        statusLabel = Get-DuoForgeProgressStateLabelInternal -Status ([string]$state.status)
        round = [int]$state.round
        maxRounds = [int]$state.maxRounds
        steps = @($graph.steps)
        barriers = @(Get-DuoForgeProgressBarriersInternal -Steps @($graph.steps))
        activeSteps = $activeSteps
        committedSteps = $committed
        totalSteps = @($graph.steps).Count
        recentCommitted = $recentCommitted
        latest = if ($latest.Count -gt 0) { $latest[0] } else { $null }
        issueCount = @($ledger.issues).Count
        openIssueCount = @($ledger.issues | Where-Object { [string]$_.resolutionStatus -notin @('RESOLVED', 'SUPERSEDED') }).Count
        blockingIssueCount = @($ledger.issues | Where-Object { [bool]$_.blocking -and [string]$_.resolutionStatus -notin @('RESOLVED', 'SUPERSEDED') }).Count
        lastEvent = $LastEvent
    }
}

function Get-DuoForgeVisibleProgressBarriersInternal {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][Parameter(Mandatory)][object[]]$Barriers,
        [ValidateRange(1, 30)][int]$Maximum
    )

    if ($Barriers.Count -le $Maximum) { return @($Barriers) }
    $focus = 0
    for ($index = 0; $index -lt $Barriers.Count; $index++) {
        if ([string]$Barriers[$index].status -in @('STARTED', 'FAILED', 'STALE', 'PARTIAL')) { $focus = $index; break }
        if ([string]$Barriers[$index].status -eq 'COMMITTED') { $focus = [Math]::Min($index + 1, $Barriers.Count - 1) }
    }
    $start = [Math]::Max(0, [Math]::Min($focus - [Math]::Floor($Maximum / 2), $Barriers.Count - $Maximum))
    return @($Barriers[$start..($start + $Maximum - 1)])
}

function Get-DuoForgeProgressSpinnerFrameInternal {
    [CmdletBinding()]
    param(
        [ValidateRange(0, 2147483647)][int]$ElapsedSeconds,
        [switch]$Ascii
    )

    $frames = if ($Ascii) { @('|', '/', '-', '\') } else { @('⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏') }
    return [string]$frames[$ElapsedSeconds % $frames.Count]
}

function Get-DuoForgeProgressSelectedCommittedIndexInternal {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][Parameter(Mandatory)][object[]]$Records,
        [System.Collections.IDictionary]$ViewState
    )

    if ($Records.Count -eq 0) { return -1 }
    $selected = $Records.Count - 1
    if ($null -ne $ViewState -and $ViewState.Contains('selectedCommittedIndex')) {
        $stored = [int]$ViewState.selectedCommittedIndex
        if ($stored -ge 0) { $selected = $stored }
    }
    $selected = [Math]::Max(0, [Math]::Min($selected, $Records.Count - 1))
    if ($null -ne $ViewState) { $ViewState.selectedCommittedIndex = $selected }
    return $selected
}

function Get-DuoForgeProgressCurrentLineInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Snapshot,
        [System.Collections.IDictionary]$ViewState,
        [ValidateRange(0, 1000)][int]$Width = 0
    )

    $active = @($Snapshot.activeSteps | Select-Object -First 1)
    $lastEventType = if ($null -ne $Snapshot.lastEvent) { [string]$Snapshot.lastEvent.type } else { '' }
    if ($active.Count -gt 0) {
        $providerLabel = if ([string]$active[0].provider -eq 'codex') { 'Codex' } else { 'Claude' }
        $stageLabel = Get-DuoForgeProgressStageLabelInternal -Stage ([string]$active[0].stage)
        $targetLabel = Get-DuoForgeProgressTargetLabelInternal -TargetDocumentId ([string](Get-DuoForgeObjectValue -Object $active[0] -Name 'targetDocumentId')) -Mode ([string]$Snapshot.mode)
        $elapsed = if ($null -ne $ViewState -and $ViewState.Contains('providerElapsedSeconds')) { [Math]::Max(0, [int]$ViewState.providerElapsedSeconds) } else { 0 }
        $asciiSpinner = $null -ne $ViewState -and -not [bool](Get-DuoForgeObjectValue -Object $ViewState -Name 'unicodeSpinner' -Default $true)
        $spinner = Get-DuoForgeProgressSpinnerFrameInternal -ElapsedSeconds $elapsed -Ascii:$asciiSpinner
        $activity = if ($lastEventType -eq 'STAGE_RESULT_RECEIVED') { '답변 도착 · 형식 확인 중' } else { "답변을 기다리는 중 $([timespan]::FromSeconds($elapsed).ToString('mm\:ss'))" }
        $parts = @($providerLabel, $stageLabel)
        if (-not [string]::IsNullOrWhiteSpace($targetLabel)) { $parts += $targetLabel }
        $parts += $activity
        $current = "지금 작업 중  $spinner " + ($parts -join ' · ')
        if ($Width -gt 0 -and (Get-DuoForgeProgressTextWidthInternal -Text $current) -gt $Width -and -not [string]::IsNullOrWhiteSpace($targetLabel)) {
            $current = "지금 작업 중  $spinner " + (@($providerLabel, $stageLabel, $activity) -join ' · ')
        }
        return $current
    }
    if ($lastEventType -eq 'STAGE_RETRY_SCHEDULED') {
        $data = $Snapshot.lastEvent.data
        $provider = if ([string]$data.provider -eq 'codex') { 'Codex' } else { 'Claude' }
        $parts = @($provider, (Get-DuoForgeProgressStageLabelInternal -Stage ([string]$data.stage)))
        $target = Get-DuoForgeProgressTargetLabelInternal -TargetDocumentId ([string](Get-DuoForgeObjectValue -Object $data -Name 'targetDocumentId')) -Mode ([string]$Snapshot.mode)
        if (-not [string]::IsNullOrWhiteSpace($target)) { $parts += $target }
        $parts += Get-DuoForgeProgressRetryLabelInternal -RetryMode ([string](Get-DuoForgeObjectValue -Object $data -Name 'retryMode'))
        return '지금 작업 중  ↻ ' + ($parts -join ' · ')
    }
    if ($lastEventType -eq 'STAGE_FAILED') {
        $data = $Snapshot.lastEvent.data
        $provider = if ([string]$data.provider -eq 'codex') { 'Codex' } else { 'Claude' }
        $parts = @($provider, (Get-DuoForgeProgressStageLabelInternal -Stage ([string]$data.stage)))
        $target = Get-DuoForgeProgressTargetLabelInternal -TargetDocumentId ([string](Get-DuoForgeObjectValue -Object $data -Name 'targetDocumentId')) -Mode ([string]$Snapshot.mode)
        if (-not [string]::IsNullOrWhiteSpace($target)) { $parts += $target }
        $parts += [string]$Snapshot.statusLabel
        $code = [string](Get-DuoForgeObjectValue -Object $data -Name 'code')
        if (-not [string]::IsNullOrWhiteSpace($code)) { $parts += $code }
        return '지금 작업 중  ! ' + ($parts -join ' · ')
    }
    if ($lastEventType -eq 'FINAL_ARTIFACTS_FAILED') {
        return ('지금 작업 중  ! 최종 결과 만들기 · {0} · {1}' -f $Snapshot.statusLabel, [string](Get-DuoForgeObjectValue -Object $Snapshot.lastEvent.data -Name 'code'))
    }
    if ($lastEventType -eq 'STAGE_INTERRUPTED_RECOVERED') {
        return ('지금 작업 중  ↻ 중단 단계 복구 · {0}' -f [string](Get-DuoForgeObjectValue -Object $Snapshot.lastEvent.data -Name 'code'))
    }
    return ('지금 상태  {0}' -f $Snapshot.statusLabel)
}

function New-DuoForgeProgressRecordHeaderInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Record,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Snapshot,
        [ValidateRange(0, 100)][int]$Index,
        [ValidateRange(1, 100)][int]$Count,
        [switch]$Selected
    )

    $providerLabel = if ([string]$Record.provider -eq 'codex') { 'Codex' } else { 'Claude' }
    $parts = @($providerLabel, ("{0}차 {1}" -f $Record.round, $Record.label))
    $target = Get-DuoForgeProgressRecordTargetLabelInternal -Record $Record -Mode ([string]$Snapshot.mode)
    if (-not [string]::IsNullOrWhiteSpace($target)) { $parts += $target }
    $selectionMark = if ($Selected) { '› ' } else { '  ' }
    $sectionPrefix = if ($Index -eq 0) { '── 최근 완료' } else { '   최근 완료' }
    return ('{0}  {1}/{2}  {3}✓ {4}' -f $sectionPrefix, ($Index + 1), $Count, $selectionMark, ($parts -join ' · '))
}

function New-DuoForgeProgressOverviewLinesInternal {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][Parameter(Mandatory)][object[]]$Records,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Snapshot,
        [ValidateRange(4, 1000)][int]$Width,
        [ValidateRange(16, 100)][int]$Height,
        [ValidateRange(1, 100)][int]$AvailableLines,
        [System.Collections.IDictionary]$ViewState
    )

    if ($Records.Count -eq 0) { return @('── 최근 완료  아직 완료된 토론 단계가 없습니다.') }
    $selected = Get-DuoForgeProgressSelectedCommittedIndexInternal -Records $Records -ViewState $ViewState
    $expanded = [System.Collections.Generic.List[int]]::new()
    $expanded.Add($selected)
    if ($Height -ge 32) {
        foreach ($index in 0..($Records.Count - 1)) { if ($index -notin $expanded) { $expanded.Add($index) } }
    }
    elseif ($Height -ge 24 -and $Records.Count -gt 1) {
        $other = if ($selected -eq $Records.Count - 1) { $selected - 1 } else { $Records.Count - 1 }
        if ($other -ge 0 -and $other -notin $expanded) { $expanded.Add($other) }
    }

    $summaryMaximum = if ($Height -ge 24) { 3 } else { 2 }
    $actionContentWidth = [Math]::Max(4, $Width - 13)
    $descriptors = [System.Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt $Records.Count; $index++) {
        $record = $Records[$index]
        $isExpanded = $index -in $expanded
        $summaryLines = if ($isExpanded) { @(Split-DuoForgeProgressTextInternal -Text ([string]$record.summary) -Width ([Math]::Max(4, $Width - 2)) -MaximumLines $summaryMaximum) } else { @() }
        $action = if ($isExpanded) { Get-DuoForgeProgressActionSummaryInternal -Record $record } else { '' }
        if (-not [string]::IsNullOrWhiteSpace($action)) {
            $action = $action.Replace('새 검토 항목:', '새 항목:').Replace('검토 의견 처리:', '의견:').Replace('문서 반영:', '반영:')
        }
        $summaryList = [System.Collections.Generic.List[string]]::new()
        foreach ($summaryLine in $summaryLines) { $summaryList.Add([string]$summaryLine) }
        $actionList = [System.Collections.Generic.List[string]]::new()
        if (-not [string]::IsNullOrWhiteSpace($action)) {
            foreach ($actionLine in @(Split-DuoForgeProgressTextInternal -Text $action -Width $actionContentWidth -MaximumLines 3)) { $actionList.Add([string]$actionLine) }
        }
        $descriptors.Add([ordered]@{
            index = $index
            record = $record
            selected = $index -eq $selected
            visible = $true
            summaryLines = $summaryList
            actionLines = $actionList
        })
    }
    $getLineCount = {
        $count = 0
        foreach ($descriptor in $descriptors) {
            if (-not [bool]$descriptor.visible) { continue }
            $count++
            $count += $descriptor.summaryLines.Count
            $count += $descriptor.actionLines.Count
        }
        return $count
    }
    while ((& $getLineCount) -gt $AvailableLines) {
        $changed = $false
        foreach ($descriptor in @($descriptors | Sort-Object { if ([bool]$_.selected) { 1 } else { 0 } }, index)) {
            $minimum = if ($descriptor.summaryLines.Count -gt 0) { 1 } else { 0 }
            if ($descriptor.summaryLines.Count -gt $minimum) {
                $descriptor.summaryLines.RemoveAt($descriptor.summaryLines.Count - 1)
                if ($descriptor.summaryLines.Count -gt 0) {
                    $last = [string]$descriptor.summaryLines[$descriptor.summaryLines.Count - 1]
                    $descriptor.summaryLines[$descriptor.summaryLines.Count - 1] = Limit-DuoForgeProgressTextInternal -Text ($last.TrimEnd('…') + '…') -Width ([Math]::Max(4, $Width - 2))
                }
                $changed = $true
                break
            }
        }
        if ($changed) { continue }
        foreach ($descriptor in @($descriptors | Sort-Object { if ([bool]$_.selected) { 0 } else { 1 } }, index)) {
            if ($descriptor.actionLines.Count -gt 1) {
                $descriptor.actionLines.RemoveAt($descriptor.actionLines.Count - 1)
                $last = [string]$descriptor.actionLines[$descriptor.actionLines.Count - 1]
                $descriptor.actionLines[$descriptor.actionLines.Count - 1] = Limit-DuoForgeProgressTextInternal -Text ($last.TrimEnd('…') + '…') -Width $actionContentWidth
                $changed = $true
                break
            }
        }
        if ($changed) { continue }
        foreach ($descriptor in @($descriptors | Where-Object { -not [bool]$_.selected } | Sort-Object index)) {
            if ($descriptor.actionLines.Count -gt 0) { $descriptor.actionLines.Clear(); $changed = $true; break }
            if ($descriptor.summaryLines.Count -gt 0) { $descriptor.summaryLines.Clear(); $changed = $true; break }
        }
        if ($changed) { continue }
        foreach ($descriptor in @($descriptors | Where-Object { -not [bool]$_.selected -and [bool]$_.visible } | Sort-Object index)) {
            $descriptor.visible = $false
            $changed = $true
            break
        }
        if (-not $changed) { break }
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($descriptor in $descriptors) {
        if (-not [bool]$descriptor.visible) { continue }
        $lines.Add((New-DuoForgeProgressRecordHeaderInternal -Record $descriptor.record -Snapshot $Snapshot -Index ([int]$descriptor.index) -Count $Records.Count -Selected:([bool]$descriptor.selected)))
        foreach ($summaryLine in $descriptor.summaryLines) { $lines.Add(('  {0}' -f $summaryLine)) }
        for ($actionIndex = 0; $actionIndex -lt $descriptor.actionLines.Count; $actionIndex++) {
            $prefix = if ($actionIndex -eq 0) { '  변경 사항  ' } else { '             ' }
            $lines.Add(($prefix + [string]$descriptor.actionLines[$actionIndex]))
        }
    }
    return @($lines | Select-Object -First $AvailableLines)
}

function New-DuoForgeProgressDetailLinesInternal {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][Parameter(Mandatory)][object[]]$Records,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Snapshot,
        [ValidateRange(4, 1000)][int]$Width,
        [ValidateRange(1, 100)][int]$AvailableLines,
        [System.Collections.IDictionary]$ViewState
    )

    if ($Records.Count -eq 0) { return @('── 최근 완료 상세  표시할 완료 항목이 없습니다.') }
    $selected = Get-DuoForgeProgressSelectedCommittedIndexInternal -Records $Records -ViewState $ViewState
    $record = $Records[$selected]
    $content = [System.Collections.Generic.List[string]]::new()
    $content.Add((New-DuoForgeProgressRecordHeaderInternal -Record $record -Snapshot $Snapshot -Index $selected -Count $Records.Count -Selected))
    $content.Add('── 요약')
    $summaryLines = @(Split-DuoForgeProgressTextInternal -Text ([string]$record.summary) -Width ([Math]::Max(4, $Width - 2)) -MaximumLines 100)
    if ($summaryLines.Count -eq 0) { $content.Add('  검증된 세부 요약이 없습니다.') }
    else { foreach ($line in $summaryLines) { $content.Add(('  {0}' -f $line)) } }
    $action = Get-DuoForgeProgressActionSummaryInternal -Record $record
    if (-not [string]::IsNullOrWhiteSpace($action)) {
        $content.Add('')
        $content.Add('── 변경 사항')
        foreach ($line in @(Split-DuoForgeProgressTextInternal -Text $action -Width ([Math]::Max(4, $Width - 2)) -MaximumLines 100)) { $content.Add(('  {0}' -f $line)) }
    }

    $maximumOffset = [Math]::Max(0, $content.Count - $AvailableLines)
    $offset = if ($null -ne $ViewState) { [int](Get-DuoForgeObjectValue -Object $ViewState -Name 'detailScrollOffset' -Default 0) } else { 0 }
    $offset = [Math]::Max(0, [Math]::Min($offset, $maximumOffset))
    if ($null -ne $ViewState) {
        $ViewState.detailScrollOffset = $offset
        $ViewState.detailMaximumOffset = $maximumOffset
        $ViewState.detailPageSize = $AvailableLines
    }
    if ($content.Count -eq 0) { return @() }
    return @($content | Select-Object -Skip $offset -First $AvailableLines)
}

function New-DuoForgeProgressFrameInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Snapshot,
        [ValidateRange(48, 400)][int]$Width,
        [ValidateRange(16, 100)][int]$Height,
        [datetimeoffset]$Now = [datetimeoffset]::Now,
        [System.Collections.IDictionary]$ViewState
    )

    $lineWidth = $Width - 1
    $maximumLines = $Height - 1
    $displayLayout = Get-DuoForgeDisplayLayoutInternal -Width $Width -Height $Height -NoColor
    $divider = '─' * [Math]::Min($lineWidth, 120)
    $recentCommitted = @(
        if ($Snapshot.Contains('recentCommitted')) { $Snapshot.recentCommitted | Select-Object -Last 3 }
        elseif ($null -ne $Snapshot.latest) { $Snapshot.latest }
    )
    if ($null -ne $ViewState) { $ViewState.recentCommittedCount = $recentCommitted.Count }
    $screenMode = if ($null -ne $ViewState) { [string](Get-DuoForgeObjectValue -Object $ViewState -Name 'screenMode' -Default 'overview') } else { 'overview' }
    if ($screenMode -notin @('overview', 'detail') -or $recentCommitted.Count -eq 0) { $screenMode = 'overview' }
    if ($null -ne $ViewState) { $ViewState.screenMode = $screenMode }

    $diagnosticReference = Get-DuoForgeProgressDiagnosticReferenceInternal -Source $(if ($null -ne $ViewState -and $ViewState.Contains('diagnosticId')) { $ViewState } else { $Snapshot.lastEvent }) -RunDirectory ([string](Get-DuoForgeObjectValue -Object $Snapshot -Name 'runDirectory'))
    $diagnosticLines = [System.Collections.Generic.List[string]]::new()
    if ($null -ne $diagnosticReference) {
        $summary = Get-DuoForgeDiagnosticPublicSummaryInternal -Code ([string]$diagnosticReference.code)
        foreach ($row in @(New-DuoForgeFieldRowsInternal -Label '오류' -Value $summary -Layout $displayLayout -Indent 2 -KeyWidth 10 -Role 'error')) { $diagnosticLines.Add([string]$row.text) }
        foreach ($row in @(New-DuoForgeFieldRowsInternal -Label '오류 코드' -Value ([string]$diagnosticReference.code) -Layout $displayLayout -Indent 2 -KeyWidth 10 -Role 'error')) { $diagnosticLines.Add([string]$row.text) }
        foreach ($row in @(New-DuoForgeFieldRowsInternal -Label '진단 ID' -Value ([string]$diagnosticReference.diagnosticId) -Layout $displayLayout -Indent 2 -KeyWidth 10 -Role 'meta')) { $diagnosticLines.Add([string]$row.text) }
        if (-not [string]::IsNullOrWhiteSpace([string]$diagnosticReference.diagnosticsPath)) {
            $pathMaximum = if ($Height -le 23) { 4 } else { 5 }
            foreach ($row in @(New-DuoForgeFieldRowsInternal -Label '진단 파일' -Value ([string]$diagnosticReference.diagnosticsPath) -Layout $displayLayout -Indent 2 -KeyWidth 10 -MaximumLines $pathMaximum -Role 'meta')) { $diagnosticLines.Add([string]$row.text) }
        }
        if ([string]$diagnosticReference.diagnosticWarningCode -eq 'DF-DIAGNOSTIC-WRITE') {
            foreach ($row in @(New-DuoForgeFieldRowsInternal -Label '기록 상태' -Value '진단 기록 실패 · DF-DIAGNOSTIC-WRITE' -Layout $displayLayout -Indent 2 -KeyWidth 10 -Role 'warning')) { $diagnosticLines.Add([string]$row.text) }
        }
    }
    $finalMessage = if ($null -ne $ViewState -and $ViewState.Contains('finalMessage')) { [string]$ViewState.finalMessage } else { '' }
    $issueSummary = if ([string]$Snapshot.status -eq 'RUNNING') {
        '전체 단계 완료 후 집계'
    }
    else {
        "전체 $($Snapshot.issueCount) · 미해결 $($Snapshot.openIssueCount) · 계속하려면 해결 $($Snapshot.blockingIssueCount)"
    }
    $pauseRequestStatus = if ($null -eq $ViewState) { '' } else { [string](Get-DuoForgeObjectValue -Object $ViewState -Name 'pauseRequestStatus' -Default '') }
    $footer = if ($null -ne $ViewState -and [bool](Get-DuoForgeObjectValue -Object $ViewState -Name 'waitForInput' -Default $false)) {
        if ([string](Get-DuoForgeObjectValue -Object $ViewState -Name 'returnTarget' -Default 'shell') -eq 'work-menu') { 'Enter 키 또는 Esc를 누르면 작업 메뉴로 돌아갑니다.' } else { 'Enter 키 또는 Esc를 누르면 셸 프롬프트로 돌아갑니다.' }
    }
    elseif ($pauseRequestStatus -eq 'requested') { '멈추기 요청됨 · 현재 AI 작업이 끝난 뒤 멈춥니다.' }
    elseif ($pauseRequestStatus -eq 'failed') { '일시정지 요청을 저장하지 못했습니다 · P 키로 다시 시도하세요.' }
    elseif (-not [string]::IsNullOrWhiteSpace([string](Get-DuoForgeObjectValue -Object $ViewState -Name 'controlNotice' -Default ''))) { [string]$ViewState.controlNotice }
    elseif ($screenMode -eq 'detail') { 'PgUp/PgDn 스크롤 · Home/End · Esc 개요 · P 현재 작업 후 멈추기' }
    elseif ($recentCommitted.Count -gt 0) { 'P 현재 작업 후 멈추기 · ↑↓ 또는 J/K 이동 · D 상세 · Esc/Q 안내' }
    else { 'P 현재 작업 후 멈추기 · Esc/Q는 AI를 중단하지 않고 안내' }

    $tailLines = [System.Collections.Generic.List[string]]::new()
    if ($diagnosticLines.Count -gt 0) { $tailLines.Add('── 작업 오류') }
    foreach ($line in $diagnosticLines) { $tailLines.Add([string]$line) }
    if (-not [string]::IsNullOrWhiteSpace($finalMessage)) {
        foreach ($row in @(New-DuoForgeTextRowsInternal -Text $finalMessage -Layout $displayLayout -MaximumLines 3 -Role 'text')) { $tailLines.Add([string]$row.text) }
    }
    if ($Height -ge 24) { $tailLines.Add('── 확인할 내용') }
    $issueLabel = if ($Height -ge 24) { '집계' } else { '확인할 내용' }
    foreach ($row in @(New-DuoForgeFieldRowsInternal -Label $issueLabel -Value $issueSummary -Layout $displayLayout -Indent $(if ($Height -ge 24) { 2 } else { 0 }) -KeyWidth $(if ($Height -ge 24) { 8 } else { 0 }) -Role 'meta')) { $tailLines.Add([string]$row.text) }
    foreach ($row in @(New-DuoForgeTextRowsInternal -Text $footer -Layout $displayLayout -MaximumLines 2 -Role 'meta')) { $tailLines.Add([string]$row.text) }

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('DUOFORGE · AI 작업 진행')
    foreach ($row in @(New-DuoForgeFieldRowsInternal -Label '작업' -Value ("{0} · {1} · {2}" -f $Snapshot.name, $Snapshot.modeLabel, $Snapshot.runId) -Layout $displayLayout -Indent 0 -KeyWidth 8 -Role 'meta')) { $lines.Add([string]$row.text) }
    $total = [Math]::Max(1, [int]$Snapshot.totalSteps)
    $barWidth = [Math]::Max(10, [Math]::Min(28, $Width - 42))
    $filled = [Math]::Min($barWidth, [Math]::Floor($barWidth * [int]$Snapshot.committedSteps / $total))
    $bar = ('█' * $filled) + ('░' * ($barWidth - $filled))
    $lines.Add(("진행  {0}  {1}/{2} · {3}" -f $bar, $Snapshot.committedSteps, $Snapshot.totalSteps, $Snapshot.statusLabel))
    $currentLine = Get-DuoForgeProgressCurrentLineInternal -Snapshot $Snapshot -ViewState $ViewState -Width $lineWidth
    $currentLines = [System.Collections.Generic.List[string]]::new()
    if ($currentLine -match '^(?<label>지금 작업 중|지금 상태)\s{2}(?<value>.+)$') {
        foreach ($row in @(New-DuoForgeFieldRowsInternal -Label ([string]$Matches.label) -Value ([string]$Matches.value) -Layout $displayLayout -Indent 0 -Role 'warning')) { $currentLines.Add([string]$row.text) }
    }
    else {
        foreach ($row in @(New-DuoForgeTextRowsInternal -Text $currentLine -Layout $displayLayout -MaximumLines 3 -Role 'warning')) { $currentLines.Add([string]$row.text) }
    }
    $activeForTarget = @($Snapshot.activeSteps | Select-Object -First 1)
    if ($activeForTarget.Count -gt 0) {
        $currentTarget = Get-DuoForgeProgressTargetLabelInternal -TargetDocumentId ([string](Get-DuoForgeObjectValue -Object $activeForTarget[0] -Name 'targetDocumentId')) -Mode ([string]$Snapshot.mode)
        if (-not [string]::IsNullOrWhiteSpace($currentTarget) -and -not $currentLine.Contains($currentTarget, [StringComparison]::Ordinal)) {
            foreach ($row in @(New-DuoForgeFieldRowsInternal -Label '작업 대상' -Value $currentTarget -Layout $displayLayout -Indent 0 -Role 'meta')) { $currentLines.Add([string]$row.text) }
        }
    }

    if ($screenMode -eq 'detail') {
        foreach ($line in $currentLines) { $lines.Add($line) }
        $lines.Add('── 최근 완료 상세')
        $detailBudget = [Math]::Max(1, $maximumLines - $lines.Count - $tailLines.Count)
        foreach ($line in @(New-DuoForgeProgressDetailLinesInternal -Records $recentCommitted -Snapshot $Snapshot -Width $lineWidth -AvailableLines $detailBudget -ViewState $ViewState)) { $lines.Add([string]$line) }
    }
    else {
        $desiredBarrierCount = if ($Height -ge 32) { 6 } elseif ($Height -ge 30) { 5 } else { 3 }
        $barrierCount = [Math]::Min($desiredBarrierCount, [Math]::Max(3, @($Snapshot.barriers).Count))
        $minimumFeed = if ($recentCommitted.Count -eq 0) { 1 } else { 1 }
        while ($barrierCount -gt 3 -and ($maximumLines - (3 + 1 + $barrierCount + 1 + 1) - $tailLines.Count) -lt $minimumFeed) { $barrierCount-- }
        $lines.Add('── 단계별 진행 ' + ('─' * [Math]::Max(1, $lineWidth - (Get-DuoForgeProgressTextWidthInternal -Text '── 단계별 진행 '))))
        $visibleBarriers = @(Get-DuoForgeVisibleProgressBarriersInternal -Barriers @($Snapshot.barriers) -Maximum ([Math]::Max(1, $barrierCount)))
        foreach ($barrierItem in $visibleBarriers) {
            $mark = Get-DuoForgeProgressBarrierMarkInternal -Status ([string]$barrierItem.status)
            $roundLabel = if ([int]$barrierItem.round -eq 0) { '준비' } else { "$([int]$barrierItem.round)차" }
            $codexMark = Get-DuoForgeProgressProviderMarkInternal -Steps @($barrierItem.steps | Where-Object { [string]$_.provider -eq 'codex' })
            $claudeMark = Get-DuoForgeProgressProviderMarkInternal -Steps @($barrierItem.steps | Where-Object { [string]$_.provider -eq 'claude' })
            $lines.Add(("{0} {1,-5} {2}  Codex {3}  Claude {4}" -f $mark, $roundLabel, $barrierItem.label, $codexMark, $claudeMark))
        }
        $lines.Add('── 지금 작업')
        foreach ($line in $currentLines) { $lines.Add($line) }
        $feedBudget = [Math]::Max(1, $maximumLines - $lines.Count - $tailLines.Count)
        foreach ($line in @(New-DuoForgeProgressOverviewLinesInternal -Records $recentCommitted -Snapshot $Snapshot -Width $lineWidth -Height $Height -AvailableLines $feedBudget -ViewState $ViewState)) { $lines.Add([string]$line) }
    }
    foreach ($line in $tailLines) { $lines.Add([string]$line) }

    $hadWidthTruncation = @($lines | Where-Object { (Get-DuoForgeProgressTextWidthInternal -Text ([string]$_)) -gt $lineWidth }).Count -gt 0
    $result = @($lines | ForEach-Object { Limit-DuoForgeProgressTextInternal -Text ([string]$_) -Width $lineWidth })
    if ($result.Count -gt $maximumLines) {
        if ($null -ne $ViewState) { $ViewState.layoutTruncated = $true }
        $result = @($result | Select-Object -First $maximumLines)
    }
    elseif ($null -ne $ViewState) { $ViewState.layoutTruncated = $hadWidthTruncation }
    return $result
}

function Get-DuoForgeProgressTerminalCapabilityInternal {
    [CmdletBinding()]
    param()

    if (-not (Test-DuoForgeInteractiveHost)) { return [ordered]@{ fullscreen = $false; reason = 'non-interactive'; width = 0; height = 0; unicodeSpinner = $false } }
    try {
        $unicodeSpinner = [Console]::OutputEncoding.WebName -match 'utf-(8|16|32)|unicode'
        if (-not [bool]$Host.UI.SupportsVirtualTerminal) { return [ordered]@{ fullscreen = $false; reason = 'virtual-terminal-unsupported'; width = 0; height = 0; unicodeSpinner = $unicodeSpinner } }
        if ([string]$env:TERM -eq 'dumb') { return [ordered]@{ fullscreen = $false; reason = 'dumb-terminal'; width = 0; height = 0; unicodeSpinner = $false } }
        $width = [Math]::Min(400, [Console]::WindowWidth)
        $height = [Math]::Min(100, [Console]::WindowHeight)
        if ($width -lt 72 -or $height -lt 20) { return [ordered]@{ fullscreen = $false; reason = 'terminal-too-small'; width = $width; height = $height; unicodeSpinner = $unicodeSpinner } }
        return [ordered]@{ fullscreen = $true; reason = 'ready'; width = $width; height = $height; unicodeSpinner = $unicodeSpinner }
    }
    catch {
        return [ordered]@{ fullscreen = $false; reason = 'console-unavailable'; width = 0; height = 0; unicodeSpinner = $false }
    }
}

function ConvertTo-DuoForgeProgressColoredLineInternal {
    [CmdletBinding()]
    param(
        [AllowEmptyString()][Parameter(Mandatory)][string]$Line,
        [switch]$NoColor
    )

    if ($NoColor) { return $Line }
    $escape = [char]27
    $reset = "$escape[0m"
    if ($Line.StartsWith('DUOFORGE')) { return "$escape[1;36m$Line$reset" }
    if ($Line -match '(^|\s)!\s' -or $Line -match '작업 오류|실패') { return "$escape[31m$Line$reset" }
    if ($Line -match '✓|\bOK\b' -and $Line -match '최근 완료') { return "$escape[32m$Line$reset" }
    if ($Line.StartsWith('●') -or $Line.StartsWith('지금 작업 중')) { return "$escape[33m$Line$reset" }
    if ($Line.StartsWith('↻')) { return "$escape[31m$Line$reset" }
    if ($Line.StartsWith('─') -or $Line.StartsWith('단계별 진행') -or $Line.StartsWith('Enter 키') -or $Line.StartsWith('↑↓') -or $Line.StartsWith('PgUp')) { return "$escape[90m$Line$reset" }
    return $Line
}

function Write-DuoForgeProgressFrameInternal {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$View)

    try {
        $width = [Console]::WindowWidth
        $height = [Console]::WindowHeight
        if ($width -lt 72 -or $height -lt 20) { throw 'terminal-too-small' }
        $snapshot = Get-DuoForgeProgressSnapshotInternal -RunDirectory ([string]$View.runDirectory) -LastEvent $View.lastEvent
        $frame = @(New-DuoForgeProgressFrameInternal -Snapshot $snapshot -Width $width -Height $height -ViewState $View)
        $displayLayout = Get-DuoForgeDisplayLayoutInternal -Width $width -Height $height -Ascii:(-not [bool](Get-DuoForgeObjectValue -Object $View -Name 'unicodeSpinner' -Default $true))
        $escape = [char]27
        $builder = [System.Text.StringBuilder]::new()
        $null = $builder.Append("$escape[H")
        foreach ($line in $frame) {
            $null = $builder.Append("$escape[2K")
            $displayLine = ConvertTo-DuoForgeDisplayFallbackTextInternal -Text ([string]$line) -Layout $displayLayout
            $null = $builder.Append((ConvertTo-DuoForgeProgressColoredLineInternal -Line $displayLine -NoColor:(-not [bool]$displayLayout.color)))
            $null = $builder.Append([Environment]::NewLine)
        }
        $null = $builder.Append("$escape[J")
        [Console]::Write($builder.ToString())
    }
    catch {
        if ([bool]$View.enteredAlternateScreen) {
            $escape = [char]27
            try { [Console]::Write("$escape[0m$escape[?25h$escape[?1049l") } catch { }
            $View.enteredAlternateScreen = $false
        }
        $View.mode = 'log'
        Write-Host '진행 화면을 유지할 수 없어 줄 단위 작업 기록으로 전환합니다.' -ForegroundColor Yellow
        Write-DuoForgeProgressLogEventInternal -View $View -Event $View.lastEvent
    }
}

function Write-DuoForgeProgressLogEventInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$View,
        [System.Collections.IDictionary]$Event
    )

    if ($null -eq $Event) { return }
    $layout = Get-DuoForgeDisplayLayoutInternal -NoColor
    $type = [string]$Event.type
    $data = Get-DuoForgeObjectValue -Object $Event -Name 'data' -Default ([ordered]@{})
    $stepKey = [string](Get-DuoForgeObjectValue -Object $data -Name 'stepKey')
    if ($type -eq 'PROGRESS_INITIALIZED') {
        Write-DuoForgeDisplayRowsInternal -Rows @(New-DuoForgePageHeaderRowsInternal -Title 'DuoForge 작업 진행' -Tag 'AI 작업 기록' -Layout $layout) -Layout $layout
        return
    }
    if ($type -eq 'PROVIDER_TICK') { return }
    $snapshot = Get-DuoForgeProgressSnapshotInternal -RunDirectory ([string]$View.runDirectory) -LastEvent $Event
    $step = @($snapshot.steps | Where-Object { [string]$_.stepKey -eq $stepKey } | Select-Object -First 1)
    $label = if ($step.Count -gt 0) {
        $stepParts = @("R$([int]$step[0].round)", [string]$step[0].provider, (Get-DuoForgeProgressStageLabelInternal -Stage ([string]$step[0].stage)))
        $stepTarget = Get-DuoForgeProgressTargetLabelInternal -TargetDocumentId ([string](Get-DuoForgeObjectValue -Object $step[0] -Name 'targetDocumentId')) -Mode ([string]$snapshot.mode)
        if (-not [string]::IsNullOrWhiteSpace($stepTarget)) { $stepParts += $stepTarget }
        $stepParts -join ' '
    }
    else {
        $checkpointLabel = Get-DuoForgeDisplayCheckpointLabelInternal -StepKey $stepKey -RunDirectory ([string]$View.runDirectory)
        if ($checkpointLabel -eq '완료된 AI 작업') { 'AI 작업' } else { $checkpointLabel }
    }
    if ($type -eq 'STAGE_COMMITTED' -and -not [string]::IsNullOrWhiteSpace($stepKey)) {
        if ([string](Get-DuoForgeObjectValue -Object $View -Name 'lastLoggedCommittedStepKey' -Default '') -eq $stepKey) { return }
        $View.lastLoggedCommittedStepKey = $stepKey
    }
    $eventRows = [System.Collections.Generic.List[object]]::new()
    $append = { param([object[]]$Block) foreach ($row in @($Block)) { $eventRows.Add($row) } }
    switch ($type) {
        'STAGE_STARTED' { & $append @(New-DuoForgeNoticeRowsInternal -Kind warning -Title ("{0} 시작" -f $label) -Layout $layout) }
        'STAGE_RESULT_RECEIVED' { & $append @(New-DuoForgeNoticeRowsInternal -Kind info -Title ("{0} 답변 도착 · 형식 확인 중" -f $label) -Layout $layout) }
        'STAGE_COMMITTED' {
            & $append @(New-DuoForgeNoticeRowsInternal -Kind success -Title ("{0} 결과 저장 완료" -f $label) -Layout $layout)
            if ($null -ne $snapshot.latest) { & $append @(New-DuoForgeTextRowsInternal -Text ([string]$snapshot.latest.summary -replace '^\s*$', '') -Layout $layout -Indent 2 -MaximumLines 3 -Role 'text') }
        }
        'STAGE_RETRY_SCHEDULED' {
            $retryLabel = Get-DuoForgeProgressRetryLabelInternal -RetryMode ([string](Get-DuoForgeObjectValue -Object $data -Name 'retryMode'))
            & $append @(New-DuoForgeNoticeRowsInternal -Kind warning -Title ("{0} · {1}" -f $label, $retryLabel) -Layout $layout)
        }
        'STAGE_FAILED' { & $append @(New-DuoForgeNoticeRowsInternal -Kind error -Title ("{0} 실패 · {1}" -f $label, $snapshot.statusLabel) -Layout $layout) }
        'STAGE_INTERRUPTED_RECOVERED' { & $append @(New-DuoForgeNoticeRowsInternal -Kind warning -Title '이전에 중단된 단계를 다시 진행할 대상으로 복구했습니다.' -Message $label -Layout $layout) }
        'FINAL_ARTIFACTS_FAILED' { & $append @(New-DuoForgeNoticeRowsInternal -Kind error -Title '최종 결과 만들기에 실패했습니다.' -NextAction '오류를 고친 뒤 이어서 진행할 수 있습니다.' -Layout $layout) }
        'PROGRESS_OBSERVER_FAILED' { & $append @(New-DuoForgeNoticeRowsInternal -Kind warning -Title '진행 화면 갱신이 중단되어 누적 로그로 전환했습니다.' -Message 'AI 작업은 계속되며 화면에는 안전한 상태 정보만 표시됩니다.' -Layout $layout) }
    }
    if ($eventRows.Count -gt 0) { Write-DuoForgeDisplayRowsInternal -Rows @($eventRows) -Layout $layout }
    if ($type -in @('STAGE_RETRY_SCHEDULED', 'STAGE_FAILED', 'STAGE_INTERRUPTED_RECOVERED', 'FINAL_ARTIFACTS_FAILED')) {
        Write-DuoForgeDiagnosticReferenceInternal -Source $data -RunDirectory ([string]$View.runDirectory)
    }
}

function Invoke-DuoForgeProgressObserverInternal {
    [CmdletBinding()]
    param(
        [scriptblock]$Observer,
        [Parameter(Mandatory)][string]$Type,
        [Parameter(Mandatory)][string]$RunDirectory,
        [System.Collections.IDictionary]$Data = ([ordered]@{}),
        [switch]$ThrowOnError
    )

    if ($null -eq $Observer) { return }
    $event = [ordered]@{
        at = Get-DuoForgeUtcNow
        type = $Type
        runId = Split-Path -Leaf ([System.IO.Path]::GetFullPath($RunDirectory))
        data = ConvertTo-DuoForgeHashtable -InputObject $Data
    }
    try { $null = & $Observer $event }
    catch {
        if ($ThrowOnError) { throw }
        Write-Verbose 'DuoForge 진행 관찰자 오류를 안전하게 격리했습니다.'
    }
}

function Read-DuoForgeProgressActionsInternal {
    [CmdletBinding()]
    param([scriptblock]$KeyReader)

    $rawKeys = @()
    if ($null -ne $KeyReader) {
        try { $rawKeys = @(& $KeyReader) }
        catch { return @() }
    }
    else {
        try {
            $buffer = [System.Collections.Generic.List[object]]::new()
            foreach ($availableKey in @(Read-DuoForgeAvailableConsoleKeysInternal)) { $buffer.Add($availableKey) }
            $rawKeys = @($buffer)
        }
        catch { return @() }
    }

    $actions = [System.Collections.Generic.List[string]]::new()
    foreach ($rawKey in $rawKeys) {
        $key = ConvertTo-DuoForgeInteractionKeyInternal -Key $rawKey
        switch ([string]$key.action) {
            'Up' { $actions.Add('Up') }
            'Down' { $actions.Add('Down') }
            'Home' { $actions.Add('Home') }
            'End' { $actions.Add('End') }
            'Enter' { $actions.Add('Enter') }
            'Interrupt' { $actions.Add('Interrupt') }
            'Escape' { $actions.Add('Escape') }
            'PageUp' { $actions.Add('PageUp') }
            'PageDown' { $actions.Add('PageDown') }
            'Character' {
                switch ([string]$key.character) {
                    { $_ -ieq 'J' } { $actions.Add('Down'); break }
                    { $_ -ieq 'K' } { $actions.Add('Up'); break }
                    { $_ -ieq 'D' } { $actions.Add('Detail'); break }
                    { $_ -ieq 'P' } { $actions.Add('Pause'); break }
                    { $_ -ieq 'Q' } { $actions.Add('Cancel'); break }
                }
            }
        }
    }
    return @($actions)
}

function Test-DuoForgeProgressPauseKeyInternal {
    [CmdletBinding()]
    param([scriptblock]$KeyReader)

    return 'Pause' -in @(Read-DuoForgeProgressActionsInternal -KeyReader $KeyReader)
}

function Invoke-DuoForgeProgressControlInputInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$View,
        [scriptblock]$KeyReader,
        [scriptblock]$PauseRequester
    )

    if ([string]$View.mode -eq 'log' -and [string]$View.pauseRequestStatus -eq 'requested') { return }
    $actions = @(Read-DuoForgeProgressActionsInternal -KeyReader $KeyReader)
    foreach ($action in $actions) {
        $View.controlNotice = ''
        if ($action -eq 'Pause') {
            if ($null -eq $PauseRequester -or [string]$View.pauseRequestStatus -eq 'requested') { continue }
            try {
                $result = ConvertTo-DuoForgeHashtable -InputObject (& $PauseRequester)
                $accepted = [bool](Get-DuoForgeObjectValue -Object $result -Name 'requested' -Default $false) -or
                    [bool](Get-DuoForgeObjectValue -Object $result -Name 'alreadyRequested' -Default $false) -or
                    [bool](Get-DuoForgeObjectValue -Object $result -Name 'alreadyPaused' -Default $false)
                if (-not $accepted) { throw 'pause-request-not-accepted' }
                $View.pauseRequestStatus = 'requested'
                $View.pauseRequestId = [string](Get-DuoForgeObjectValue -Object $result -Name 'requestId' -Default '')
                if ([string]$View.mode -eq 'log') { $layout = Get-DuoForgeDisplayLayoutInternal -NoColor; Write-DuoForgeDisplayRowsInternal -Rows @(New-DuoForgeNoticeRowsInternal -Kind warning -Title '멈추기를 요청했습니다.' -Message '현재 AI 작업이 끝난 뒤 멈춥니다.' -Layout $layout) -Layout $layout }
            }
            catch {
                $View.pauseRequestStatus = 'failed'
                $View.pauseRequestId = ''
                if ([string]$View.mode -eq 'log') { $layout = Get-DuoForgeDisplayLayoutInternal -NoColor; Write-DuoForgeDisplayRowsInternal -Rows @(New-DuoForgeNoticeRowsInternal -Kind error -Title '일시정지 요청을 저장하지 못했습니다.' -NextAction 'P 키로 다시 시도해 주세요.' -Layout $layout) -Layout $layout }
            }
            continue
        }
        if ([string]$View.mode -eq 'log') { continue }

        $returnTarget = [string](Get-DuoForgeObjectValue -Object $View -Name 'returnTarget' -Default 'shell')
        if ($action -eq 'Interrupt') {
            $View.lastInteraction = New-DuoForgeInteractionResultInternal -Action interrupt -Source key -ReturnTarget $returnTarget
            $View.controlNotice = '긴급 중단 입력을 확인했습니다. 현재 체크포인트 보존 경계에서 처리합니다.'
            continue
        }
        if ($action -eq 'Cancel' -or $action -eq 'Enter') {
            $View.controlNotice = 'AI 작업은 계속됩니다. 안전하게 멈추려면 P를 누르세요.'
            continue
        }

        $recordCount = [Math]::Max(0, [int](Get-DuoForgeObjectValue -Object $View -Name 'recentCommittedCount' -Default 0))
        $screenMode = [string](Get-DuoForgeObjectValue -Object $View -Name 'screenMode' -Default 'overview')
        if ($screenMode -eq 'detail') {
            $pageSize = [Math]::Max(1, [int](Get-DuoForgeObjectValue -Object $View -Name 'detailPageSize' -Default 1))
            $maximumOffset = [Math]::Max(0, [int](Get-DuoForgeObjectValue -Object $View -Name 'detailMaximumOffset' -Default 0))
            $offset = [Math]::Max(0, [int](Get-DuoForgeObjectValue -Object $View -Name 'detailScrollOffset' -Default 0))
            switch ($action) {
                'PageUp' { $View.detailScrollOffset = [Math]::Max(0, $offset - $pageSize) }
                'PageDown' { $View.detailScrollOffset = [Math]::Min($maximumOffset, $offset + $pageSize) }
                'Home' { $View.detailScrollOffset = 0 }
                'End' { $View.detailScrollOffset = $maximumOffset }
                'Escape' { $View.screenMode = 'overview'; $View.detailScrollOffset = 0 }
            }
            continue
        }
        if ($action -eq 'Escape') {
            $View.controlNotice = 'AI 작업은 계속됩니다. 안전하게 멈추려면 P를 누르세요.'
            continue
        }
        if ($recordCount -le 0) { continue }
        $selected = [int](Get-DuoForgeObjectValue -Object $View -Name 'selectedCommittedIndex' -Default ($recordCount - 1))
        switch ($action) {
            'Up' { $View.selectedCommittedIndex = [Math]::Max(0, $selected - 1); $View.detailScrollOffset = 0 }
            'Down' { $View.selectedCommittedIndex = [Math]::Min($recordCount - 1, $selected + 1); $View.detailScrollOffset = 0 }
            'Home' { $View.selectedCommittedIndex = 0; $View.detailScrollOffset = 0 }
            'End' { $View.selectedCommittedIndex = $recordCount - 1; $View.detailScrollOffset = 0 }
            'Detail' { $View.screenMode = 'detail'; $View.detailScrollOffset = 0 }
        }
    }
}

function Read-DuoForgeProgressCompletionInteractionInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('work-menu', 'shell')][string]$ReturnTarget,
        [scriptblock]$KeyReader
    )

    while ($true) {
        $rawKey = Read-DuoForgeConsoleKeyInternal -KeyReader $KeyReader
        $key = ConvertTo-DuoForgeInteractionKeyInternal -Key $rawKey
        switch ([string]$key.action) {
            'Enter' { return New-DuoForgeInteractionResultInternal -Action submit -Source key -ReturnTarget $ReturnTarget }
            'Escape' { return New-DuoForgeInteractionResultInternal -Action back -Source key -ReturnTarget $ReturnTarget }
            'Interrupt' { return New-DuoForgeInteractionResultInternal -Action interrupt -Source key -ReturnTarget $ReturnTarget }
            'Character' {
                if ([string]$key.character -ieq 'Q') { return New-DuoForgeInteractionResultInternal -Action cancel -Source key -ReturnTarget $ReturnTarget }
            }
        }
    }
}

function New-DuoForgeProgressViewInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunDirectory,
        [ValidateSet('auto', 'fullscreen', 'log')][string]$Mode = 'auto',
        [scriptblock]$KeyReader,
        [scriptblock]$PauseRequester,
        [scriptblock]$FrameWriter
    )

    $capability = Get-DuoForgeProgressTerminalCapabilityInternal
    $selectedMode = if ($Mode -eq 'auto') { if ([bool]$capability.fullscreen) { 'fullscreen' } else { 'log' } } else { $Mode }
    if ($selectedMode -eq 'fullscreen' -and -not [bool]$capability.fullscreen) { $selectedMode = 'log' }
    $view = [ordered]@{
        runDirectory = [System.IO.Path]::GetFullPath($RunDirectory)
        mode = $selectedMode
        capabilityReason = [string]$capability.reason
        enteredAlternateScreen = $false
        lastEvent = $null
        providerElapsedSeconds = 0
        unicodeSpinner = [bool](Get-DuoForgeObjectValue -Object $capability -Name 'unicodeSpinner' -Default $false)
        screenMode = 'overview'
        selectedCommittedIndex = -1
        recentCommittedCount = 0
        detailScrollOffset = 0
        detailMaximumOffset = 0
        detailPageSize = 1
        layoutTruncated = $false
        finalMessage = ''
        waitForInput = $false
        returnTarget = 'shell'
        pauseRequestStatus = ''
        pauseRequestId = ''
        keyReader = $KeyReader
        pauseRequester = $PauseRequester
        observerFailureCount = 0
        observerFailureCode = ''
        observerFailureReported = $false
        closed = $false
    }
    $convertToHashtableCommand = Get-Command -Name 'ConvertTo-DuoForgeHashtable' -CommandType Function -ErrorAction Stop
    $getObjectValueCommand = Get-Command -Name 'Get-DuoForgeObjectValue' -CommandType Function -ErrorAction Stop
    $controlInputCommand = Get-Command -Name 'Invoke-DuoForgeProgressControlInputInternal' -CommandType Function -ErrorAction Stop
    $writeFrameCommand = if ($null -ne $FrameWriter) { $FrameWriter } else { Get-Command -Name 'Write-DuoForgeProgressFrameInternal' -CommandType Function -ErrorAction Stop }
    $writeLogCommand = Get-Command -Name 'Write-DuoForgeProgressLogEventInternal' -CommandType Function -ErrorAction Stop
    $observer = {
        param($event)
        $view.lastEvent = & $convertToHashtableCommand -InputObject $event
        if ([string]$event.type -eq 'STAGE_STARTED') { $view.providerElapsedSeconds = 0 }
        if ([string]$event.type -eq 'PROVIDER_TICK') { $view.providerElapsedSeconds = [int](& $getObjectValueCommand -Object $event.data -Name 'elapsedSeconds' -Default 0) }
        & $controlInputCommand -View $view -KeyReader $KeyReader -PauseRequester $PauseRequester
        if ([string]$view.mode -eq 'fullscreen') {
            try { & $writeFrameCommand $view }
            catch {
                $view.observerFailureCount = [int]$view.observerFailureCount + 1
                $view.observerFailureCode = 'DF-PROGRESS-FRAME'
                $view.mode = 'log'
                if (-not [bool]$view.observerFailureReported) {
                    $view.observerFailureReported = $true
                    & $writeLogCommand -View $view -Event ([ordered]@{ type = 'PROGRESS_OBSERVER_FAILED'; data = [ordered]@{ code = 'DF-PROGRESS-FRAME'; count = 1 } })
                }
            }
        }
        else { & $writeLogCommand -View $view -Event $view.lastEvent }
    }.GetNewClosure()
    $view.observer = $observer

    if ($selectedMode -eq 'fullscreen') {
        $escape = [char]27
        try {
            [Console]::Write("$escape[?1049h$escape[?25l")
            $view.enteredAlternateScreen = $true
        }
        catch {
            $view.mode = 'log'
        }
    }
    Invoke-DuoForgeProgressObserverInternal -Observer $view.observer -Type 'PROGRESS_INITIALIZED' -RunDirectory $RunDirectory
    return $view
}

function Close-DuoForgeProgressViewInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$View,
        [System.Collections.IDictionary]$Result,
        [System.Collections.IDictionary]$ErrorDiagnostic,
        [switch]$WaitForAcknowledgement
    )

    if ([bool]$View.closed) { return }
    $View.closed = $true
    $View.waitForInput = [bool]$WaitForAcknowledgement -and [string]$View.mode -eq 'fullscreen'
    if ($null -ne $ErrorDiagnostic) {
        $View.finalMessage = '작업 오류 · ' + (Get-DuoForgeDiagnosticPublicSummaryInternal -Code ([string]$ErrorDiagnostic.code))
        foreach ($name in @('code', 'diagnosticId', 'diagnosticsLocation', 'diagnosticsRelativePath', 'diagnosticsPath', 'diagnosticWarningCode')) { $View[$name] = Get-DuoForgeObjectValue -Object $ErrorDiagnostic -Name $name }
    }
    elseif ($null -ne $Result) {
        $View.finalMessage = '작업 종료 · ' + (Get-DuoForgeProgressStateLabelInternal -Status ([string]$Result.status))
        foreach ($name in @('code', 'diagnosticId', 'diagnosticsLocation', 'diagnosticsRelativePath', 'diagnosticsPath', 'diagnosticWarningCode')) { $View[$name] = Get-DuoForgeObjectValue -Object $Result -Name $name }
    }
    if ([string]$View.mode -eq 'fullscreen') {
        if ($View.waitForInput) {
            Clear-DuoForgeConsoleInputBufferInternal
        }
        Write-DuoForgeProgressFrameInternal -View $View
        $escape = [char]27
        try {
            if ([string]$View.mode -eq 'fullscreen' -and [bool]$View.enteredAlternateScreen) {
                [Console]::Write("$escape[?25h")
                if ($View.waitForInput) {
                    $View.completionInteraction = Read-DuoForgeProgressCompletionInteractionInternal -ReturnTarget ([string](Get-DuoForgeObjectValue -Object $View -Name 'returnTarget' -Default 'shell')) -KeyReader $View.keyReader
                }
            }
            elseif ($null -ne $Result) {
                $layout = Get-DuoForgeDisplayLayoutInternal
                Write-DuoForgeDisplayRowsInternal -Rows @(New-DuoForgeNoticeRowsInternal -Kind info -Title ('작업 종료 · {0}' -f (Get-DuoForgeProgressStateLabelInternal -Status ([string]$Result.status))) -Message ('이번에 진행한 단계 {0}개' -f $Result.invoked) -Layout $layout) -Layout $layout
            }
        }
        finally {
            if ([bool]$View.enteredAlternateScreen) {
                try { [Console]::Write("$escape[0m$escape[?25h$escape[?1049l") } catch { }
                $View.enteredAlternateScreen = $false
            }
        }
    }
    elseif ($null -ne $Result) {
        $layout = Get-DuoForgeDisplayLayoutInternal
        Write-DuoForgeDisplayRowsInternal -Rows @(New-DuoForgeNoticeRowsInternal -Kind info -Title ('작업 종료 · {0}' -f (Get-DuoForgeProgressStateLabelInternal -Status ([string]$Result.status))) -Message ('이번에 진행한 단계 {0}개 · 누적 로그 모드는 입력을 기다리지 않고 {1}(으)로 돌아갑니다.' -f $Result.invoked, $(if ([string]$View.returnTarget -eq 'work-menu') { '작업 메뉴' } else { '셸 프롬프트' })) -Layout $layout) -Layout $layout
        if (-not [string]::IsNullOrWhiteSpace([string](Get-DuoForgeObjectValue -Object $Result -Name 'diagnosticId'))) { Write-DuoForgeDiagnosticReferenceInternal -Source $Result -RunDirectory ([string]$View.runDirectory) }
    }
}

function Invoke-DuoForgeResumeWithProgressInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [string]$ResultsRoot,
        [switch]$WaitForAcknowledgement,
        [ValidateSet('work-menu', 'shell')][string]$ReturnTarget = 'shell'
    )

    $run = Get-DuoForgeRunInternal -RunId $RunId -ResultsRoot $ResultsRoot
    $requestPauseCommand = Get-Command -Name 'Request-DuoForgePauseInternal' -CommandType Function -ErrorAction Stop
    $pauseRequester = {
        & $requestPauseCommand -RunId $RunId -ResultsRoot $ResultsRoot
    }.GetNewClosure()
    $view = New-DuoForgeProgressViewInternal -RunDirectory ([string]$run.runDirectory) -PauseRequester $pauseRequester
    $view.returnTarget = $ReturnTarget
    $result = $null
    $errorDiagnostic = $null
    try {
        $result = Invoke-DuoForgeResumeLiveInternal -RunId $RunId -ResultsRoot $ResultsRoot -LiveConsent $true -ProgressObserver $view.observer
        return $result
    }
    catch [System.Management.Automation.PipelineStoppedException] {
        throw
    }
    catch {
        if (-not $_.Exception.Data.Contains('DuoForgeDiagnosticId')) {
            $manifest = Get-DuoForgeObjectValue -Object $run -Name 'manifest' -Default ([ordered]@{})
            $state = Get-DuoForgeObjectValue -Object $run -Name 'state' -Default ([ordered]@{})
            $code = if ($_.Exception.Data.Contains('DuoForgeCode')) { [string]$_.Exception.Data['DuoForgeCode'] } else { 'DF-STAGE-UNEXPECTED' }
            $diagnostic = Write-DuoForgeDiagnosticInternal -RunDirectory ([string]$run.runDirectory) -Code $code -Category 'resume' -Phase 'resume' -Scope 'run' -Run ([ordered]@{ runId = $RunId; workflowVersion = Get-DuoForgeWorkflowVersionInternal -Manifest $manifest; status = Get-DuoForgeObjectValue -Object $state -Name 'status'; lastCompletedStage = Get-DuoForgeObjectValue -Object $state -Name 'lastCompletedStage' }) -ErrorRecord $_
            Add-DuoForgeDiagnosticMetadataToExceptionInternal -Exception $_.Exception -Diagnostic $diagnostic
        }
        $errorDiagnostic = Get-DuoForgeDiagnosticSourceFromExceptionInternal -Exception $_.Exception
        throw
    }
    finally {
        try {
            Close-DuoForgeProgressViewInternal -View $view -Result $result -ErrorDiagnostic $errorDiagnostic -WaitForAcknowledgement:$WaitForAcknowledgement
        }
        catch { }
    }
}
