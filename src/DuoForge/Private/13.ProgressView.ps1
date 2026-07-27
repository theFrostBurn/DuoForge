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

function Get-DuoForgeProgressStateLabelInternal {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Status)

    switch ($Status) {
        'SNAPSHOTTED' { '실행 준비' }
        'RUNNING' { '진행 중' }
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
    param([Parameter(Mandatory)]$Step)

    if ([string]$Step.status -ne 'COMMITTED' -or [string]::IsNullOrWhiteSpace([string]$Step.artifactPath)) { return $null }
    if (-not (Test-Path -LiteralPath ([string]$Step.artifactPath) -PathType Leaf)) { return $null }
    if ([string]::IsNullOrWhiteSpace([string]$Step.artifactHash)) { return $null }
    try {
        if ((Get-DuoForgeSha256 -Path ([string]$Step.artifactPath)) -ne [string]$Step.artifactHash) { return $null }
        $artifact = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path ([string]$Step.artifactPath))
        $result = Get-DuoForgeObjectValue -Object $artifact -Name 'result'
        if ($null -eq $result) { return $null }
        $workflowVersion = if ([int](Get-DuoForgeObjectValue -Object $result -Name 'schemaVersion' -Default 1) -eq 2) { 'workflow-v2' } else { 'workflow-v1' }
        $null = Test-DuoForgeStageResultInternal -Result $result -ExpectedStage ([string]$Step.stage) -ExpectedProvider ([string]$Step.provider) -WorkflowVersion $workflowVersion -ExpectedTargetDocumentId (Get-DuoForgeObjectValue -Object $Step -Name 'targetDocumentId') -ExpectedSourceDocumentIds @(Get-DuoForgeObjectValue -Object $Step -Name 'sourceDocumentIds' -Default @()) -ThrowOnError
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
        label = Get-DuoForgeProgressStageLabelInternal -Stage ([string]$Step.stage)
        summary = ConvertTo-DuoForgeProgressTextInternal -Text ([string](Get-DuoForgeObjectValue -Object $result -Name 'summary'))
        issueCounts = $issueCounts
        responseCounts = $responseCounts
        adoptionCounts = $adoptionCounts
        questionCount = @((Get-DuoForgeObjectValue -Object $result -Name 'openQuestions' -Default @())).Count
        attemptCount = [int]$Step.attemptCount
    }
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
        $graph = New-DuoForgeStageGraph -Mode ([string]$manifest.mode) -MaxRounds ([int]$manifest.maxRounds) -FirstSynthesizer $firstSynthesizer -ContextBatchCount $contextBatchCount
    }

    $artifactRecords = [System.Collections.Generic.List[object]]::new()
    foreach ($step in @($graph.steps)) {
        $record = Get-DuoForgeProgressArtifactRecordInternal -Step $step
        if ($null -ne $record) { $artifactRecords.Add($record) }
    }
    $lastStepKey = if ($null -ne $LastEvent -and $LastEvent.Contains('data')) { [string](Get-DuoForgeObjectValue -Object $LastEvent.data -Name 'stepKey') } else { '' }
    if ([string]::IsNullOrWhiteSpace($lastStepKey) -or @($artifactRecords | Where-Object { $_.stepKey -eq $lastStepKey }).Count -eq 0) {
        $lastStepKey = [string]$state.lastCompletedStage
    }
    $latest = @($artifactRecords | Where-Object { $_.stepKey -eq $lastStepKey } | Select-Object -Last 1)
    if ($latest.Count -eq 0) { $latest = @($artifactRecords | Select-Object -Last 1) }

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
    & $addLine 'DUOFORGE  토론 진행판'
    & $addLine ("{0} · {1} · {2}" -f $Snapshot.name, $Snapshot.modeLabel, $Snapshot.runId)

    $total = [Math]::Max(1, [int]$Snapshot.totalSteps)
    $barWidth = [Math]::Max(10, [Math]::Min(28, $Width - 42))
    $filled = [Math]::Min($barWidth, [Math]::Floor($barWidth * [int]$Snapshot.committedSteps / $total))
    $bar = ('█' * $filled) + ('░' * ($barWidth - $filled))
    & $addLine ("진행  {0}  {1}/{2} · {3}" -f $bar, $Snapshot.committedSteps, $Snapshot.totalSteps, $Snapshot.statusLabel)
    & $addLine $divider
    & $addLine '장벽 레일'

    $summaryBudget = if ($Height -ge 26) { 4 } else { 2 }
    $fixedLines = 13 + $summaryBudget
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
        $elapsed = if ($null -ne $ViewState -and $ViewState.Contains('providerElapsedSeconds')) { [int]$ViewState.providerElapsedSeconds } else { 0 }
        $activity = if ($lastEventType -eq 'STAGE_RESULT_RECEIVED') { '응답 수신 · 구조 검증 중' } else { "응답 대기 $([timespan]::FromSeconds($elapsed).ToString('mm\:ss'))" }
        & $addLine ("현재  ● {0} · {1} · {2}" -f $providerLabel, $stageLabel, $activity)
    }
    elseif ($lastEventType -eq 'STAGE_RETRY_SCHEDULED') {
        $retryData = $Snapshot.lastEvent.data
        $retryProvider = if ([string]$retryData.provider -eq 'codex') { 'Codex' } else { 'Claude' }
        & $addLine ("현재  ↻ {0} · {1} · 형식 복구 재시도 대기" -f $retryProvider, (Get-DuoForgeProgressStageLabelInternal -Stage ([string]$retryData.stage)))
    }
    elseif ($lastEventType -eq 'STAGE_FAILED') {
        $failedData = $Snapshot.lastEvent.data
        $failedProvider = if ([string]$failedData.provider -eq 'codex') { 'Codex' } else { 'Claude' }
        & $addLine ("현재  ! {0} · {1} · 재개 가능 오류" -f $failedProvider, (Get-DuoForgeProgressStageLabelInternal -Stage ([string]$failedData.stage)))
    }
    else {
        & $addLine ("현재  {0}" -f $Snapshot.statusLabel)
    }

    if ($null -ne $Snapshot.latest) {
        $latestProvider = if ([string]$Snapshot.latest.provider -eq 'codex') { 'Codex' } else { 'Claude' }
        & $addLine ("최근 확정  ✓ {0} · R{1} {2}" -f $latestProvider, $Snapshot.latest.round, $Snapshot.latest.label)
        foreach ($summaryLine in @(Split-DuoForgeProgressTextInternal -Text ([string]$Snapshot.latest.summary) -Width ([Math]::Max(12, $lineWidth - 2)) -MaximumLines $summaryBudget)) {
            & $addLine ("  $summaryLine")
        }
        $issues = $Snapshot.latest.issueCounts
        $responses = $Snapshot.latest.responseCounts
        $adoptions = $Snapshot.latest.adoptionCounts
        & $addLine ("  쟁점 C {0} · M {1} · m {2} | 응답 수용 {3} · 부분 {4} · 거부 {5} | 채택 {6}" -f $issues.critical, $issues.major, $issues.minor, $responses.ACCEPTED, $responses.PARTIALLY_ACCEPTED, $responses.REJECTED, ($adoptions.ACCEPTED + $adoptions.PARTIALLY_ACCEPTED))
    }
    else {
        & $addLine '최근 확정  아직 커밋된 토론 단계가 없습니다.'
    }

    & $addLine $divider
    $finalMessage = if ($null -ne $ViewState -and $ViewState.Contains('finalMessage')) { [string]$ViewState.finalMessage } else { '' }
    if (-not [string]::IsNullOrWhiteSpace($finalMessage)) { & $addLine $finalMessage }
    if ([string]$Snapshot.status -eq 'RUNNING') {
        & $addLine '쟁점 원장  전체 단계 확정 후 집계'
    }
    else {
        & $addLine ("쟁점 전체 {0} · 미해결 {1} · 차단 {2}" -f $Snapshot.issueCount, $Snapshot.openIssueCount, $Snapshot.blockingIssueCount)
    }
    $footer = if ($null -ne $ViewState -and [bool](Get-DuoForgeObjectValue -Object $ViewState -Name 'waitForInput' -Default $false)) {
        'Enter 키를 누르면 작업 메뉴로 돌아갑니다.'
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
    $label = if ($step.Count -gt 0) { "R$([int]$step[0].round) $([string]$step[0].provider) $(Get-DuoForgeProgressStageLabelInternal -Stage ([string]$step[0].stage))" } else { $stepKey }
    switch ($type) {
        'STAGE_STARTED' { Write-Host ("● {0} 시작" -f $label) -ForegroundColor Yellow }
        'STAGE_RESULT_RECEIVED' { Write-Host ("● {0} 응답 수신 · 검증 중" -f $label) -ForegroundColor DarkYellow }
        'STAGE_COMMITTED' {
            Write-Host ("✓ {0} 확정" -f $label) -ForegroundColor Green
            if ($null -ne $snapshot.latest) { Write-Host ("  {0}" -f (Limit-DuoForgeProgressTextInternal -Text ([string]$snapshot.latest.summary) -Width 120)) }
        }
        'STAGE_RETRY_SCHEDULED' { Write-Host ("↻ {0} 형식 복구 재시도 대기" -f $label) -ForegroundColor Yellow }
        'STAGE_FAILED' { Write-Host ("! {0} 실패 · 재개 가능 상태로 보존" -f $label) -ForegroundColor Red }
        'STAGE_INTERRUPTED_RECOVERED' { Write-Host ("↻ 이전에 중단된 단계를 재개 대상으로 복구: {0}" -f $label) -ForegroundColor Yellow }
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
        runDirectory = $RunDirectory
        data = ConvertTo-DuoForgeHashtable -InputObject $Data
    }
    try { $null = & $Observer $event }
    catch { Write-Verbose ("DuoForge 진행 관찰자 오류를 무시했습니다: {0}" -f $_.Exception.Message) }
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
        [string]$ErrorMessage,
        [switch]$WaitForAcknowledgement
    )

    if ([bool]$View.closed) { return }
    $View.closed = $true
    $View.waitForInput = [bool]$WaitForAcknowledgement -and [string]$View.mode -eq 'fullscreen'
    if (-not [string]::IsNullOrWhiteSpace($ErrorMessage)) {
        $View.finalMessage = '실행 오류 · ' + (ConvertTo-DuoForgeProgressTextInternal -Text $ErrorMessage -MaximumCharacters 240)
    }
    elseif ($null -ne $Result) {
        $View.finalMessage = '실행 종료 · ' + (Get-DuoForgeProgressStateLabelInternal -Status ([string]$Result.status))
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
    }
}

function Invoke-DuoForgeResumeWithProgressInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [string]$ResultsRoot,
        [switch]$WaitForAcknowledgement
    )

    $run = Get-DuoForgeRunInternal -RunId $RunId -ResultsRoot $ResultsRoot
    $view = New-DuoForgeProgressViewInternal -RunDirectory ([string]$run.runDirectory)
    $result = $null
    $errorMessage = $null
    try {
        $result = Invoke-DuoForgeResumeLiveInternal -RunId $RunId -ResultsRoot $ResultsRoot -LiveConsent $true -ProgressObserver $view.observer
        return $result
    }
    catch {
        $errorMessage = $_.Exception.Message
        throw
    }
    finally {
        try {
            Close-DuoForgeProgressViewInternal -View $view -Result $result -ErrorMessage $errorMessage -WaitForAcknowledgement:$WaitForAcknowledgement
        }
        catch { }
    }
}
