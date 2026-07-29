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
    $builder = [System.Text.StringBuilder]::new()
    $used = 0
    foreach ($unit in @(Get-DuoForgeProgressTextUnitsInternal -Text $safe)) {
        $unitText = [string]$unit.text
        $unitWidth = [int]$unit.width
        if ($used + $unitWidth -gt $Width -and $builder.Length -gt 0) {
            $lines.Add($builder.ToString().TrimEnd())
            $null = $builder.Clear()
            $used = 0
            if ($lines.Count -ge $MaximumLines) { break }
            if ($unitText -eq ' ') { continue }
        }
        $null = $builder.Append($unitText)
        $used += $unitWidth
    }
    if ($lines.Count -lt $MaximumLines -and $builder.Length -gt 0) { $lines.Add($builder.ToString().TrimEnd()) }
    if ($lines.Count -eq $MaximumLines -and (Get-DuoForgeProgressTextWidthInternal -Text ($lines -join ' ')) -lt (Get-DuoForgeProgressTextWidthInternal -Text $safe)) {
        $lines[$lines.Count - 1] = Limit-DuoForgeProgressTextInternal -Text ($lines[$lines.Count - 1] + '…') -Width $Width
    }
    return @($lines)
}

function Get-DuoForgeProgressStageLabelInternal {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Stage)

    switch ($Stage) {
        'context-batch-analysis' { '문맥 배치 분석' }
        'independent-draft' { '독립 초안' }
        'independent-merge-draft' { '독립 병합 후보' }
        'cross-review' { '교차 비평' }
        'author-response' { '작성자 응답' }
        'joint-document-review' { '공동 문서 검토' }
        'document-review' { '문서 A/B 검토' }
        'review-response' { '검토 응답' }
        'synthesis' { '공동 문서 합성' }
        'final-validation' { '최종 검증' }
        'owner-response' { '소유자 응답' }
        'owned-document-revision' { '소유 문서 개정' }
        'document-revision' { '대상 문서 개정' }
        'document-validation' { '대상 문서 최종 검증' }
        default { $Stage }
    }
}

function Get-DuoForgeProgressModeLabelInternal {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Mode)

    switch ($Mode) {
        'shared-document' { '컨셉으로 공동 문서 만들기' }
        'document-merge' { '두 문서를 하나로 합의하기' }
        'dual-document' { '두 문서를 각각 개선하기' }
        'dual-project-audit' { '두 프로젝트 비교하기(비활성)' }
        default { $Mode }
    }
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

    switch ($Status) {
        'CREATED' { '실행 생성' }
        'PREFLIGHT' { '사전 검사' }
        'SNAPSHOTTED' { '실행 준비' }
        'RUNNING' { '진행 중' }
        'BLOCKED_PREFLIGHT' { '사전 검사 차단' }
        'PAUSED_USER' { '사용자 일시정지' }
        'PAUSED_QUOTA' { '구독 한도 대기' }
        'AWAITING_USER' { '사용자 결정 대기' }
        'AWAITING_EVIDENCE' { '추가 근거 대기' }
        'COMPLETED' { '완료' }
        'COMPLETED_PARTIAL' { '부분 완료' }
        'RESUMABLE_ERROR' { '재개 가능 오류' }
        'SOURCE_DRIFT' { '입력 변경 감지' }
        default { $Status }
    }
}

function Get-DuoForgeProgressRetryLabelInternal {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$RetryMode)

    switch ($RetryMode) {
        'FORMAT_REPAIR' { '형식 복구 재시도 대기' }
        'STANDARD_RETRY' { '공급자 호출 재시도 대기' }
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
        summary = if ([string]$Step.stage -eq 'context-batch-analysis') { '문맥 배치 분석 결과가 검증·저장되었습니다.' } else { ConvertTo-DuoForgeProgressTextInternal -Text ([string](Get-DuoForgeObjectValue -Object $result -Name 'summary')) }
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
        [ordered]@{ key = 'critical'; label = '치명적' },
        [ordered]@{ key = 'major'; label = '주요' },
        [ordered]@{ key = 'minor'; label = '경미' }
    )) {
        $count = [int](Get-DuoForgeObjectValue -Object $issues -Name ([string]$item.key) -Default 0)
        if ($count -gt 0) { $issueParts.Add(('{0} {1}' -f $item.label, $count)) }
    }
    if ($issueParts.Count -gt 0) { $groups.Add('새 쟁점 ' + ($issueParts -join ' · ')) }

    $responses = Get-DuoForgeObjectValue -Object $Record -Name 'responseCounts' -Default ([ordered]@{})
    $responseParts = [System.Collections.Generic.List[string]]::new()
    foreach ($item in @(
        [ordered]@{ key = 'ACCEPTED'; label = '수용' },
        [ordered]@{ key = 'PARTIALLY_ACCEPTED'; label = '부분 수용' },
        [ordered]@{ key = 'REJECTED'; label = '거부' },
        [ordered]@{ key = 'DEFERRED'; label = '보류' },
        [ordered]@{ key = 'NEEDS_EVIDENCE'; label = '근거 필요' },
        [ordered]@{ key = 'ASK_USER'; label = '사용자 결정' }
    )) {
        $count = [int](Get-DuoForgeObjectValue -Object $responses -Name ([string]$item.key) -Default 0)
        if ($count -gt 0) { $responseParts.Add(('{0} {1}' -f $item.label, $count)) }
    }
    if ($responseParts.Count -gt 0) { $groups.Add('검토 응답 ' + ($responseParts -join ' · ')) }

    $adoptions = Get-DuoForgeObjectValue -Object $Record -Name 'adoptionCounts' -Default ([ordered]@{})
    $adoptionParts = [System.Collections.Generic.List[string]]::new()
    foreach ($item in @(
        [ordered]@{ key = 'ACCEPTED'; label = '반영' },
        [ordered]@{ key = 'PARTIALLY_ACCEPTED'; label = '부분 반영' },
        [ordered]@{ key = 'REJECTED'; label = '미반영' },
        [ordered]@{ key = 'DEFERRED'; label = '보류' }
    )) {
        $count = [int](Get-DuoForgeObjectValue -Object $adoptions -Name ([string]$item.key) -Default 0)
        if ($count -gt 0) { $adoptionParts.Add(('{0} {1}' -f $item.label, $count)) }
    }
    if ($adoptionParts.Count -gt 0) { $groups.Add('실제 편집 ' + ($adoptionParts -join ' · ')) }

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
    $lines = [System.Collections.Generic.List[string]]::new()
    $addLine = {
        param([AllowEmptyString()][string]$Text)
        $lines.Add((Limit-DuoForgeProgressTextInternal -Text $Text -Width $lineWidth))
    }
    $divider = '─' * [Math]::Min($lineWidth, 120)
    $diagnosticReference = Get-DuoForgeProgressDiagnosticReferenceInternal -Source $(if ($null -ne $ViewState -and $ViewState.Contains('diagnosticId')) { $ViewState } else { $Snapshot.lastEvent }) -RunDirectory ([string](Get-DuoForgeObjectValue -Object $Snapshot -Name 'runDirectory'))
    $recentCommitted = @(
        if ($Snapshot.Contains('recentCommitted')) {
            $Snapshot.recentCommitted | Select-Object -Last 3
        }
        elseif ($null -ne $Snapshot.latest) {
            $Snapshot.latest
        }
    )
    if ($null -ne $diagnosticReference -and $Height -le 20 -and $recentCommitted.Count -gt 1) { $recentCommitted = @($recentCommitted | Select-Object -Last 1) }
    $finalMessage = if ($null -ne $ViewState -and $ViewState.Contains('finalMessage')) { [string]$ViewState.finalMessage } else { '' }
    [object[]]$diagnosticPathLines = @(if ($null -ne $diagnosticReference -and -not [string]::IsNullOrWhiteSpace([string]$diagnosticReference.diagnosticsPath)) { Split-DuoForgeProgressTextInternal -Text ("진단 파일: {0}" -f $diagnosticReference.diagnosticsPath) -Width $lineWidth -MaximumLines 6 })
    $diagnosticLineCount = if ($null -eq $diagnosticReference) { 0 } else { 1 + $diagnosticPathLines.Count + $(if ([string]$diagnosticReference.diagnosticWarningCode -eq 'DF-DIAGNOSTIC-WRITE') { 1 } else { 0 }) }
    & $addLine 'DUOFORGE  토론 진행판'
    & $addLine ("{0} · {1} · {2}" -f $Snapshot.name, $Snapshot.modeLabel, $Snapshot.runId)

    $total = [Math]::Max(1, [int]$Snapshot.totalSteps)
    $barWidth = [Math]::Max(10, [Math]::Min(28, $Width - 42))
    $filled = [Math]::Min($barWidth, [Math]::Floor($barWidth * [int]$Snapshot.committedSteps / $total))
    $bar = ('█' * $filled) + ('░' * ($barWidth - $filled))
    & $addLine ("진행  {0}  {1}/{2} · {3}" -f $bar, $Snapshot.committedSteps, $Snapshot.totalSteps, $Snapshot.statusLabel)
    & $addLine ('장벽 레일 ' + ('─' * [Math]::Max(1, $lineWidth - (Get-DuoForgeProgressTextWidthInternal -Text '장벽 레일 '))))

    $feedLineCount = if ($recentCommitted.Count -eq 0) { 1 } else { $recentCommitted.Count * 2 }
    $fixedLines = 9 + $feedLineCount + $diagnosticLineCount + $(if ([string]::IsNullOrWhiteSpace($finalMessage)) { 0 } else { 1 })
    $barrierBudget = [Math]::Max(3, [Math]::Min(8, ($Height - 1) - $fixedLines))
    $visibleBarriers = @(Get-DuoForgeVisibleProgressBarriersInternal -Barriers @($Snapshot.barriers) -Maximum $barrierBudget)
    foreach ($barrier in $visibleBarriers) {
        $mark = Get-DuoForgeProgressBarrierMarkInternal -Status ([string]$barrier.status)
        $roundLabel = if ([int]$barrier.round -eq 0) { '준비' } else { "R$([int]$barrier.round)" }
        $codexMark = Get-DuoForgeProgressProviderMarkInternal -Steps @($barrier.steps | Where-Object { [string]$_.provider -eq 'codex' })
        $claudeMark = Get-DuoForgeProgressProviderMarkInternal -Steps @($barrier.steps | Where-Object { [string]$_.provider -eq 'claude' })
        $providerText = if ($Width -ge 76) { "Codex $codexMark  Claude $claudeMark" } else { "C:$codexMark A:$claudeMark" }
        & $addLine ("{0} {1,-4} {2}  {3}" -f $mark, $roundLabel, $barrier.label, $providerText)
    }

    & $addLine $divider
    $active = @($Snapshot.activeSteps | Select-Object -First 1)
    $lastEventType = if ($null -ne $Snapshot.lastEvent) { [string]$Snapshot.lastEvent.type } else { '' }
    if ($active.Count -gt 0) {
        $providerLabel = if ([string]$active[0].provider -eq 'codex') { 'Codex' } else { 'Claude' }
        $stageLabel = Get-DuoForgeProgressStageLabelInternal -Stage ([string]$active[0].stage)
        $targetLabel = Get-DuoForgeProgressTargetLabelInternal -TargetDocumentId ([string](Get-DuoForgeObjectValue -Object $active[0] -Name 'targetDocumentId')) -Mode ([string]$Snapshot.mode)
        $elapsed = if ($null -ne $ViewState -and $ViewState.Contains('providerElapsedSeconds')) { [int]$ViewState.providerElapsedSeconds } else { 0 }
        $activity = if ($lastEventType -eq 'STAGE_RESULT_RECEIVED') { '응답 수신 · 구조 검증 중' } else { "응답 대기 $([timespan]::FromSeconds($elapsed).ToString('mm\:ss'))" }
        $currentParts = @($providerLabel, $stageLabel)
        if (-not [string]::IsNullOrWhiteSpace($targetLabel)) { $currentParts += $targetLabel }
        $currentParts += $activity
        & $addLine ("현재  ● {0}" -f ($currentParts -join ' · '))
    }
    elseif ($lastEventType -eq 'STAGE_RETRY_SCHEDULED') {
        $retryData = $Snapshot.lastEvent.data
        $retryProvider = if ([string]$retryData.provider -eq 'codex') { 'Codex' } else { 'Claude' }
        $retryParts = @($retryProvider, (Get-DuoForgeProgressStageLabelInternal -Stage ([string]$retryData.stage)))
        $retryTarget = Get-DuoForgeProgressTargetLabelInternal -TargetDocumentId ([string](Get-DuoForgeObjectValue -Object $retryData -Name 'targetDocumentId')) -Mode ([string]$Snapshot.mode)
        if (-not [string]::IsNullOrWhiteSpace($retryTarget)) { $retryParts += $retryTarget }
        $retryParts += Get-DuoForgeProgressRetryLabelInternal -RetryMode ([string](Get-DuoForgeObjectValue -Object $retryData -Name 'retryMode'))
        & $addLine ("현재  ↻ {0}" -f ($retryParts -join ' · '))
    }
    elseif ($lastEventType -eq 'STAGE_FAILED') {
        $failedData = $Snapshot.lastEvent.data
        $failedProvider = if ([string]$failedData.provider -eq 'codex') { 'Codex' } else { 'Claude' }
        $failedParts = @($failedProvider, (Get-DuoForgeProgressStageLabelInternal -Stage ([string]$failedData.stage)))
        $failedTarget = Get-DuoForgeProgressTargetLabelInternal -TargetDocumentId ([string](Get-DuoForgeObjectValue -Object $failedData -Name 'targetDocumentId')) -Mode ([string]$Snapshot.mode)
        if (-not [string]::IsNullOrWhiteSpace($failedTarget)) { $failedParts += $failedTarget }
        $failedParts += [string]$Snapshot.statusLabel
        $failureCode = [string](Get-DuoForgeObjectValue -Object $failedData -Name 'code')
        if (-not [string]::IsNullOrWhiteSpace($failureCode)) { $failedParts += $failureCode }
        & $addLine ("현재  ! {0}" -f ($failedParts -join ' · '))
    }
    elseif ($lastEventType -eq 'FINAL_ARTIFACTS_FAILED') {
        & $addLine ("현재  ! 최종 산출물 생성 · {0} · {1}" -f $Snapshot.statusLabel, [string](Get-DuoForgeObjectValue -Object $Snapshot.lastEvent.data -Name 'code'))
    }
    elseif ($lastEventType -eq 'STAGE_INTERRUPTED_RECOVERED') {
        & $addLine ("현재  ↻ 중단 단계 복구 · {0}" -f [string](Get-DuoForgeObjectValue -Object $Snapshot.lastEvent.data -Name 'code'))
    }
    else {
        & $addLine ("현재  {0}" -f $Snapshot.statusLabel)
    }

    if ($recentCommitted.Count -gt 0) {
        foreach ($record in $recentCommitted) {
            $providerLabel = if ([string]$record.provider -eq 'codex') { 'Codex' } else { 'Claude' }
            $headerParts = @($providerLabel, ("R{0} {1}" -f $record.round, $record.label))
            $targetLabel = Get-DuoForgeProgressRecordTargetLabelInternal -Record $record -Mode ([string]$Snapshot.mode)
            if (-not [string]::IsNullOrWhiteSpace($targetLabel)) { $headerParts += $targetLabel }
            & $addLine ("최근 확정  ✓ {0}" -f ($headerParts -join ' · '))

            $summary = ConvertTo-DuoForgeProgressTextInternal -Text ([string]$record.summary)
            $actionSummary = Get-DuoForgeProgressActionSummaryInternal -Record $record
            $detailWidth = [Math]::Max(4, $lineWidth - 2)
            if (-not [string]::IsNullOrWhiteSpace($summary) -and -not [string]::IsNullOrWhiteSpace($actionSummary)) {
                $actionWidth = Get-DuoForgeProgressTextWidthInternal -Text $actionSummary
                $summaryFullWidth = Get-DuoForgeProgressTextWidthInternal -Text $summary
                $minimumSummaryWidth = [Math]::Min($summaryFullWidth, 4)
                $visibleActionWidth = [Math]::Min($actionWidth, [Math]::Max(1, $detailWidth - $minimumSummaryWidth - 1))
                $summaryWidth = [Math]::Max(1, $detailWidth - $visibleActionWidth - 1)
                $visibleSummary = Limit-DuoForgeProgressTextInternal -Text $summary -Width $summaryWidth
                $remainingActionWidth = [Math]::Max(1, $detailWidth - (Get-DuoForgeProgressTextWidthInternal -Text $visibleSummary) - 1)
                $visibleAction = Limit-DuoForgeProgressTextInternal -Text $actionSummary -Width $remainingActionWidth
                $detail = $visibleSummary + '—' + $visibleAction
            }
            elseif (-not [string]::IsNullOrWhiteSpace($actionSummary)) {
                $detail = Limit-DuoForgeProgressTextInternal -Text $actionSummary -Width $detailWidth
            }
            elseif (-not [string]::IsNullOrWhiteSpace($summary)) {
                $detail = Limit-DuoForgeProgressTextInternal -Text $summary -Width $detailWidth
            }
            else {
                $detail = '검증된 세부 요약이 없습니다.'
            }
            & $addLine ("  $detail")
        }
    }
    else {
        & $addLine '최근 확정  아직 커밋된 토론 단계가 없습니다.'
    }

    & $addLine $divider
    if ($null -ne $diagnosticReference) {
        & $addLine ("오류 코드: {0} · 진단 ID: {1}" -f $diagnosticReference.code, $diagnosticReference.diagnosticId)
        foreach ($pathLine in $diagnosticPathLines) { $lines.Add([string]$pathLine) }
        if ([string]$diagnosticReference.diagnosticWarningCode -eq 'DF-DIAGNOSTIC-WRITE') { & $addLine '진단 기록 실패: DF-DIAGNOSTIC-WRITE' }
    }
    if (-not [string]::IsNullOrWhiteSpace($finalMessage)) { & $addLine $finalMessage }
    if ([string]$Snapshot.status -eq 'RUNNING') {
        & $addLine '쟁점 원장  전체 단계 확정 후 집계'
    }
    else {
        & $addLine ("쟁점 전체 {0} · 미해결 {1} · 차단 {2}" -f $Snapshot.issueCount, $Snapshot.openIssueCount, $Snapshot.blockingIssueCount)
    }
    $footer = if ($null -ne $ViewState -and [bool](Get-DuoForgeObjectValue -Object $ViewState -Name 'waitForInput' -Default $false)) {
        if ([string](Get-DuoForgeObjectValue -Object $ViewState -Name 'returnTarget' -Default 'shell') -eq 'menu') { 'Enter 키를 누르면 작업 메뉴로 돌아갑니다.' } else { 'Enter 키를 누르면 셸 프롬프트로 돌아갑니다.' }
    }
    else {
        '확정된 구조화 결과만 표시합니다 · 실행 중에는 키 입력을 받지 않습니다.'
    }
    & $addLine $footer

    $maximumLines = $Height - 1
    if ($lines.Count -gt $maximumLines) {
        $tailCount = [Math]::Min(4, $maximumLines - 1)
        $headCount = [Math]::Max(1, $maximumLines - $tailCount)
        return @($lines | Select-Object -First $headCount) + @($lines | Select-Object -Last $tailCount)
    }
    return @($lines)
}

function Get-DuoForgeProgressTerminalCapabilityInternal {
    [CmdletBinding()]
    param()

    if (-not (Test-DuoForgeInteractiveHost)) { return [ordered]@{ fullscreen = $false; reason = 'non-interactive'; width = 0; height = 0 } }
    try {
        if (-not [bool]$Host.UI.SupportsVirtualTerminal) { return [ordered]@{ fullscreen = $false; reason = 'virtual-terminal-unsupported'; width = 0; height = 0 } }
        if ([string]$env:TERM -eq 'dumb') { return [ordered]@{ fullscreen = $false; reason = 'dumb-terminal'; width = 0; height = 0 } }
        $width = [Math]::Min(400, [Console]::WindowWidth)
        $height = [Math]::Min(100, [Console]::WindowHeight)
        if ($width -lt 72 -or $height -lt 20) { return [ordered]@{ fullscreen = $false; reason = 'terminal-too-small'; width = $width; height = $height } }
        return [ordered]@{ fullscreen = $true; reason = 'ready'; width = $width; height = $height }
    }
    catch {
        return [ordered]@{ fullscreen = $false; reason = 'console-unavailable'; width = 0; height = 0 }
    }
}

function ConvertTo-DuoForgeProgressColoredLineInternal {
    [CmdletBinding()]
    param([AllowEmptyString()][Parameter(Mandatory)][string]$Line)

    $escape = [char]27
    $reset = "$escape[0m"
    if ($Line.StartsWith('DUOFORGE')) { return "$escape[1;36m$Line$reset" }
    if ($Line.StartsWith('✓') -or $Line.StartsWith('최근 확정  ✓')) { return "$escape[32m$Line$reset" }
    if ($Line.StartsWith('●') -or $Line.StartsWith('현재  ●')) { return "$escape[33m$Line$reset" }
    if ($Line.StartsWith('↻') -or $Line.StartsWith('!')) { return "$escape[31m$Line$reset" }
    if ($Line.StartsWith('─') -or $Line.StartsWith('확정된 구조화') -or $Line.StartsWith('Enter 키')) { return "$escape[90m$Line$reset" }
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
        $escape = [char]27
        $builder = [System.Text.StringBuilder]::new()
        $null = $builder.Append("$escape[H")
        foreach ($line in $frame) {
            $null = $builder.Append("$escape[2K")
            $null = $builder.Append((ConvertTo-DuoForgeProgressColoredLineInternal -Line ([string]$line)))
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
        Write-Host '고정형 진행판을 유지할 수 없어 누적 진행 로그로 전환합니다.' -ForegroundColor Yellow
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
    $type = [string]$Event.type
    $data = Get-DuoForgeObjectValue -Object $Event -Name 'data' -Default ([ordered]@{})
    $stepKey = [string](Get-DuoForgeObjectValue -Object $data -Name 'stepKey')
    if ($type -eq 'PROGRESS_INITIALIZED') {
        Write-Host 'DuoForge 토론 진행을 시작합니다.' -ForegroundColor Cyan
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
    else { $stepKey }
    switch ($type) {
        'STAGE_STARTED' { Write-Host ("● {0} 시작" -f $label) -ForegroundColor Yellow }
        'STAGE_RESULT_RECEIVED' { Write-Host ("● {0} 응답 수신 · 검증 중" -f $label) -ForegroundColor DarkYellow }
        'STAGE_COMMITTED' {
            Write-Host ("✓ {0} 확정" -f $label) -ForegroundColor Green
            if ($null -ne $snapshot.latest) { Write-Host ("  {0}" -f (Limit-DuoForgeProgressTextInternal -Text ([string]$snapshot.latest.summary) -Width 120)) }
        }
        'STAGE_RETRY_SCHEDULED' {
            $retryLabel = Get-DuoForgeProgressRetryLabelInternal -RetryMode ([string](Get-DuoForgeObjectValue -Object $data -Name 'retryMode'))
            Write-Host ("↻ {0} {1}" -f $label, $retryLabel) -ForegroundColor Yellow
        }
        'STAGE_FAILED' { Write-Host ("! {0} 실패 · {1} 상태로 보존" -f $label, $snapshot.statusLabel) -ForegroundColor Red }
        'STAGE_INTERRUPTED_RECOVERED' { Write-Host ("↻ 이전에 중단된 단계를 재개 대상으로 복구: {0}" -f $label) -ForegroundColor Yellow }
        'FINAL_ARTIFACTS_FAILED' { Write-Host '! 최종 산출물 생성 실패 · 재개 가능 상태로 보존' -ForegroundColor Red }
    }
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
        [System.Collections.IDictionary]$Data = ([ordered]@{})
    )

    if ($null -eq $Observer) { return }
    $event = [ordered]@{
        at = Get-DuoForgeUtcNow
        type = $Type
        runId = Split-Path -Leaf ([System.IO.Path]::GetFullPath($RunDirectory))
        data = ConvertTo-DuoForgeHashtable -InputObject $Data
    }
    try { $null = & $Observer $event }
    catch { Write-Verbose 'DuoForge 진행 관찰자 오류를 무시했습니다.' }
}

function New-DuoForgeProgressViewInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunDirectory,
        [ValidateSet('auto', 'fullscreen', 'log')][string]$Mode = 'auto'
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
        finalMessage = ''
        waitForInput = $false
        returnTarget = 'shell'
        closed = $false
    }
    $observer = {
        param($event)
        $view.lastEvent = ConvertTo-DuoForgeHashtable -InputObject $event
        if ([string]$event.type -eq 'STAGE_STARTED') { $view.providerElapsedSeconds = 0 }
        if ([string]$event.type -eq 'PROVIDER_TICK') { $view.providerElapsedSeconds = [int](Get-DuoForgeObjectValue -Object $event.data -Name 'elapsedSeconds' -Default 0) }
        if ([string]$view.mode -eq 'fullscreen') { Write-DuoForgeProgressFrameInternal -View $view }
        else { Write-DuoForgeProgressLogEventInternal -View $view -Event $view.lastEvent }
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
        $View.finalMessage = '실행 오류 · ' + (Get-DuoForgeDiagnosticPublicSummaryInternal -Code ([string]$ErrorDiagnostic.code))
        foreach ($name in @('code', 'diagnosticId', 'diagnosticsLocation', 'diagnosticsRelativePath', 'diagnosticsPath', 'diagnosticWarningCode')) { $View[$name] = Get-DuoForgeObjectValue -Object $ErrorDiagnostic -Name $name }
    }
    elseif ($null -ne $Result) {
        $View.finalMessage = '실행 종료 · ' + (Get-DuoForgeProgressStateLabelInternal -Status ([string]$Result.status))
        foreach ($name in @('code', 'diagnosticId', 'diagnosticsLocation', 'diagnosticsRelativePath', 'diagnosticsPath', 'diagnosticWarningCode')) { $View[$name] = Get-DuoForgeObjectValue -Object $Result -Name $name }
    }
    if ([string]$View.mode -eq 'fullscreen') {
        if ($View.waitForInput) {
            try { while ([Console]::KeyAvailable) { $null = [Console]::ReadKey($true) } } catch { }
        }
        Write-DuoForgeProgressFrameInternal -View $View
        $escape = [char]27
        try {
            if ([string]$View.mode -eq 'fullscreen' -and [bool]$View.enteredAlternateScreen) {
                [Console]::Write("$escape[?25h")
                if ($View.waitForInput) { $null = [Console]::ReadLine() }
            }
            elseif ($null -ne $Result) {
                Write-Host ("실행 상태: {0}, 이번 호출 단계: {1}" -f $Result.status, $Result.invoked) -ForegroundColor Cyan
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
        Write-Host ("실행 상태: {0}, 이번 호출 단계: {1}" -f $Result.status, $Result.invoked) -ForegroundColor Cyan
        if (-not [string]::IsNullOrWhiteSpace([string](Get-DuoForgeObjectValue -Object $Result -Name 'diagnosticId'))) { Write-DuoForgeDiagnosticReferenceInternal -Source $Result -RunDirectory ([string]$View.runDirectory) }
    }
}

function Invoke-DuoForgeResumeWithProgressInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [string]$ResultsRoot,
        [switch]$WaitForAcknowledgement,
        [ValidateSet('menu', 'shell')][string]$ReturnTarget = 'shell'
    )

    $run = Get-DuoForgeRunInternal -RunId $RunId -ResultsRoot $ResultsRoot
    $view = New-DuoForgeProgressViewInternal -RunDirectory ([string]$run.runDirectory)
    $view.returnTarget = $ReturnTarget
    $result = $null
    $errorDiagnostic = $null
    try {
        $result = Invoke-DuoForgeResumeLiveInternal -RunId $RunId -ResultsRoot $ResultsRoot -LiveConsent $true -ProgressObserver $view.observer
        return $result
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
