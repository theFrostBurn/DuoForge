function Resolve-DuoForgeDecisionChoice {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Choice,
        [Parameter(Mandatory)][string[]]$Options
    )

    $trimmed = $Choice.Trim()
    $index = -1
    if ($trimmed -match '^[A-Za-z]$') { $index = [int][char]$trimmed.ToUpperInvariant() - [int][char]'A' }
    elseif ($trimmed -match '^\d+$') { $index = [int]$trimmed - 1 }
    else {
        for ($i = 0; $i -lt $Options.Count; $i++) {
            if ($Options[$i] -eq $trimmed) { $index = $i; break }
        }
    }
    if ($index -lt 0 -or $index -ge $Options.Count) {
        throw (New-DuoForgeException -Code 'DF-DECISION-CHOICE' -Message '선택지가 유효하지 않습니다.')
    }
    return [ordered]@{ code = [char]([int][char]'A' + $index); option = [string]$Options[$index] }
}

function Get-DuoForgeDecisionReviewProgressInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunDirectory,
        [System.Collections.IDictionary]$State,
        [switch]$InferPendingGate
    )

    $currentState = if ($null -eq $State) {
        ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path (Join-Path $RunDirectory 'state.json'))
    }
    else {
        $State
    }
    $maximum = 3
    $cycle = [int](Get-DuoForgeObjectValue -Object $currentState -Name 'decisionReviewCycle' -Default 0)
    $cycle = [Math]::Max(0, [Math]::Min($maximum, $cycle))
    if ($cycle -eq 0) {
        $answerRecords = @(Read-DuoForgeJsonLines -Path (Join-Path $RunDirectory 'decisions\user-answers.jsonl') -AllowMissing | Where-Object { [string](Get-DuoForgeObjectValue -Object $_ -Name 'action' -Default '') -eq 'ANSWER' })
        if ($answerRecords.Count -gt 0) {
            $cycle = 1
        }
        elseif ($InferPendingGate) {
            $pendingPath = Join-Path $RunDirectory 'decisions\pending.json'
            $pendingQuestions = if (Test-Path -LiteralPath $pendingPath -PathType Leaf) { @((Read-DuoForgeJson -Path $pendingPath).questions) } else { @() }
            if ($pendingQuestions.Count -gt 0) { $cycle = 1 }
        }
    }
    return [ordered]@{
        cycle = $cycle
        maximum = $maximum
        remaining = [Math]::Max(0, $maximum - $cycle)
        limitReached = [bool](Get-DuoForgeObjectValue -Object $currentState -Name 'decisionReviewLimitReached' -Default $false)
    }
}

function Register-DuoForgeDecisionReviewGateInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunDirectory,
        [ValidateRange(1, 1000)][int]$QuestionCount
    )

    $statePath = Join-Path $RunDirectory 'state.json'
    $state = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path $statePath)
    $progress = Get-DuoForgeDecisionReviewProgressInternal -RunDirectory $RunDirectory -State $state
    $state.maxDecisionReviewCycles = 3
    if ([int]$progress.cycle -ge [int]$progress.maximum) {
        $state.decisionReviewCycle = [int]$progress.maximum
        $state.decisionReviewLimitReached = $true
        $state.updatedAt = Get-DuoForgeUtcNow
        Write-DuoForgeJsonAtomic -Path $statePath -Value $state
        return [ordered]@{ allowed = $false; cycle = [int]$progress.maximum; maximum = [int]$progress.maximum; questionCount = $QuestionCount; limitReached = $true }
    }

    $nextCycle = [int]$progress.cycle + 1
    $state.decisionReviewCycle = $nextCycle
    $state.decisionReviewLimitReached = $false
    $state.updatedAt = Get-DuoForgeUtcNow
    Write-DuoForgeJsonAtomic -Path $statePath -Value $state
    return [ordered]@{ allowed = $true; cycle = $nextCycle; maximum = [int]$progress.maximum; questionCount = $QuestionCount; limitReached = $false }
}

function Reset-DuoForgeDecisionAffectedSteps {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunDirectory,
        [Parameter(Mandatory)][string]$Mode
    )

    $stepsPath = Join-Path $RunDirectory 'steps.json'
    if (-not (Test-Path -LiteralPath $stepsPath -PathType Leaf)) {
        throw (New-DuoForgeException -Code 'DF-DECISION-NO-STEPS' -Message '사용자 결정을 반영할 단계 그래프가 없습니다.')
    }
    $graph = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path $stepsPath)
    $manifest = Read-DuoForgeJson -Path (Join-Path $RunDirectory 'manifest.json')
    $workflowVersion = Get-DuoForgeWorkflowVersionInternal -Manifest $manifest
    $maximumRound = [int]$graph.maxRounds
    if ($Mode -in @('shared-document', 'document-merge')) {
        $affected = @($graph.steps | Where-Object { [int]$_.round -eq $maximumRound -and [string]$_.stage -in @('synthesis', 'final-validation') })
    }
    elseif ($workflowVersion -eq 'workflow-v2') {
        $affected = @($graph.steps | Where-Object { [int]$_.round -eq $maximumRound -and [string]$_.stage -in @('document-revision', 'document-validation') })
    }
    else {
        $affected = @($graph.steps | Where-Object { [int]$_.round -eq $maximumRound -and [string]$_.stage -eq 'owned-document-revision' })
    }
    if ($affected.Count -eq 0) {
        throw (New-DuoForgeException -Code 'DF-DECISION-NO-AFFECTED-STEPS' -Message '사용자 결정의 영향을 받을 마지막 문서 단계를 찾지 못했습니다.')
    }
    foreach ($step in $affected) {
        if ([string]$step.status -eq 'COMMITTED' -and -not [string]::IsNullOrWhiteSpace([string]$step.artifactPath) -and (Test-Path -LiteralPath ([string]$step.artifactPath) -PathType Leaf)) {
            $historyDirectory = Join-Path $RunDirectory 'history\decisions'
            [System.IO.Directory]::CreateDirectory($historyDirectory) | Out-Null
            $suffix = if ([string]::IsNullOrWhiteSpace([string]$step.artifactHash)) { [Guid]::NewGuid().ToString('N').Substring(0, 12) } else { ([string]$step.artifactHash).Substring(0, [Math]::Min(12, ([string]$step.artifactHash).Length)) }
            $preservedPath = Join-Path $historyDirectory ("{0}-{1}.json" -f [string]$step.stepKey, $suffix)
            [System.IO.File]::Copy([string]$step.artifactPath, $preservedPath, $true)
            $history = [System.Collections.Generic.List[object]]::new()
            if ($step.Contains('history')) { foreach ($entry in @($step.history)) { $history.Add($entry) } }
            $history.Add([ordered]@{ invalidatedAt = Get-DuoForgeUtcNow; reason = 'USER_DECISION_CHANGED'; previousArtifactHash = [string]$step.artifactHash; preservedPath = $preservedPath })
            $step.history = @($history)
            $step.status = 'STALE'
        }
        else {
            $step.status = 'PENDING'
        }
        $step.inputHash = $null
        $step.artifactPath = $null
        $step.artifactHash = $null
        $step.lastError = $null
        $step.retryMode = $null
        $step.lastPromptKind = $null
    }
    Write-DuoForgeJsonAtomic -Path $stepsPath -Value $graph
    return [ordered]@{
        resetSteps = @($affected | ForEach-Object { $_.stepKey })
        lastCommittedStep = @($graph.steps | Where-Object { $_.status -eq 'COMMITTED' } | Select-Object -Last 1 | ForEach-Object { $_.stepKey })[0]
    }
}

function Set-DuoForgeUserDecisionInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$IssueId,
        [ValidateSet('answer', 'defer')][string]$Action = 'answer',
        [string]$Choice,
        [string]$CustomText,
        [string]$ResultsRoot,
        [switch]$ConfirmPartial,
        [switch]$ReplacePrevious
    )

    $run = Get-DuoForgeRunInternal -RunId $RunId -ResultsRoot $ResultsRoot
    $null = Assert-DuoForgeStagePromptPolicyInternal -Manifest $run.manifest
    return Invoke-WithDuoForgeRunLock -RunDirectory ([string]$run.runDirectory) -ScriptBlock {
        $directory = [string]$run.runDirectory
        $statePath = Join-Path $directory 'state.json'
        $state = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path $statePath)
        if ([string]$state.status -in @('COMPLETED', 'COMPLETED_PARTIAL', 'QUESTION_LIMIT_REACHED', 'FAILED_STAGE', 'SOURCE_DRIFT', 'CANCELLED')) {
            throw (New-DuoForgeException -Code 'DF-DECISION-TERMINAL' -Message '종료된 실행의 쟁점은 변경할 수 없습니다.')
        }

        $ledgerPath = Join-Path $directory 'issues.json'
        $ledger = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path $ledgerPath)
        $issue = @($ledger.issues | Where-Object { [string]$_.issueId -eq $IssueId } | Select-Object -First 1)
        if ($issue.Count -ne 1) { throw (New-DuoForgeException -Code 'DF-ISSUE-NOT-FOUND' -Message "쟁점을 찾을 수 없습니다: $IssueId") }
        $issue = $issue[0]

        $pendingPath = Join-Path $directory 'decisions\pending.json'
        $pending = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path $pendingPath)
        $question = @($pending.questions | Where-Object { [string]$_.issueKey -eq $IssueId } | Select-Object -Last 1)
        $previousDecision = $null
        if ($ReplacePrevious) {
            $previousDecision = @(Read-DuoForgeJsonLines -Path (Join-Path $directory 'decisions\user-answers.jsonl') -AllowMissing | Where-Object { [string]$_.issueId -eq $IssueId -and [string]$_.action -eq 'ANSWER' } | Select-Object -Last 1)
            if ($previousDecision.Count -ne 1) { throw (New-DuoForgeException -Code 'DF-DECISION-NO-PREVIOUS' -Message '변경할 기존 사용자 결정을 찾지 못했습니다.') }
            $previousDecision = $previousDecision[0]
        }
        $decisionRecord = [ordered]@{
            schemaVersion = 1
            decisionId = 'decision-' + [Guid]::NewGuid().ToString('N')
            runId = $RunId
            issueId = $IssueId
            issueFingerprint = [string]$issue.fingerprint
            claim = [string]$issue.claim
            proposal = [string]$issue.proposal
            action = $Action.ToUpperInvariant()
            choiceCode = $null
            selectedOption = $null
            questionOptions = @()
            questionTitle = $null
            questionText = $null
            recommendedOption = $null
            revision = if ($null -eq $previousDecision) { 1 } else { [int](Get-DuoForgeObjectValue -Object $previousDecision -Name 'revision' -Default 1) + 1 }
            supersedesDecisionId = if ($null -eq $previousDecision) { $null } else { [string]$previousDecision.decisionId }
            recordedAt = Get-DuoForgeUtcNow
        }

        if ($Action -eq 'answer') {
            if ($question.Count -ne 1 -and $null -eq $previousDecision) { throw (New-DuoForgeException -Code 'DF-DECISION-NO-QUESTION' -Message '이 쟁점에 답변 가능한 질문 카드가 없습니다.') }
            $hasChoice = -not [string]::IsNullOrWhiteSpace($Choice)
            $hasCustomText = -not [string]::IsNullOrWhiteSpace($CustomText)
            if ($hasChoice -eq $hasCustomText) { throw (New-DuoForgeException -Code 'DF-DECISION-CHOICE' -Message 'answer에는 객관식 선택 또는 주관식 답변 중 하나만 필요합니다.') }
            $options = if ($question.Count -eq 1) { @($question[0].options) } else { @($previousDecision.questionOptions) }
            if ($options.Count -eq 0) { throw (New-DuoForgeException -Code 'DF-DECISION-NO-OPTIONS' -Message '기존 결정의 선택지 기록이 없어 변경할 수 없습니다.') }
            if ($hasCustomText) {
                $normalizedCustomText = ($CustomText -replace '\s+', ' ').Trim()
                if ($normalizedCustomText.Length -gt 2000) { throw (New-DuoForgeException -Code 'DF-DECISION-CUSTOM-LENGTH' -Message '주관식 답변은 2,000자 이하여야 합니다.') }
                $resolvedChoice = [ordered]@{ code = 'CUSTOM'; option = $normalizedCustomText }
            }
            else {
                $resolvedChoice = Resolve-DuoForgeDecisionChoice -Choice $Choice -Options $options
            }
            $decisionRecord.choiceCode = [string]$resolvedChoice.code
            $decisionRecord.selectedOption = [string]$resolvedChoice.option
            $decisionRecord.questionOptions = $options
            $decisionRecord.questionTitle = if ($question.Count -eq 1) { [string](Get-DuoForgeObjectValue -Object $question[0] -Name 'title' -Default '') } else { [string](Get-DuoForgeObjectValue -Object $previousDecision -Name 'questionTitle' -Default '') }
            $decisionRecord.questionText = if ($question.Count -eq 1) { [string](Get-DuoForgeObjectValue -Object $question[0] -Name 'question' -Default '') } else { [string](Get-DuoForgeObjectValue -Object $previousDecision -Name 'questionText' -Default '') }
            $decisionRecord.recommendedOption = if ($question.Count -eq 1) { [string]$question[0].recommendedOption } else { [string]$previousDecision.recommendedOption }
            Add-DuoForgeJsonLine -Path (Join-Path $directory 'decisions\user-answers.jsonl') -Value $decisionRecord

            $combinedResponses = [System.Collections.Generic.List[object]]::new()
            if ($issue.responses.Contains('user')) { foreach ($response in @($issue.responses['user'])) { $combinedResponses.Add($response) } }
            $combinedResponses.Add($decisionRecord)
            $issue.responses['user'] = @($combinedResponses)
            $issue.resolutionStatus = 'OPEN'
            $historyEvent = if ($ReplacePrevious) { 'USER_DECISION_CHANGED' } else { 'USER_ANSWERED' }
            $issue.history = @($issue.history) + @([ordered]@{ at = $decisionRecord.recordedAt; event = $historyEvent; actor = 'user'; status = 'OPEN'; decisionId = $decisionRecord.decisionId; supersedesDecisionId = $decisionRecord.supersedesDecisionId })
            Write-DuoForgeJsonAtomic -Path $ledgerPath -Value $ledger
            $pending.questions = @($pending.questions | Where-Object { [string]$_.issueKey -ne $IssueId })
            Write-DuoForgeJsonAtomic -Path $pendingPath -Value $pending

            $reset = Reset-DuoForgeDecisionAffectedSteps -RunDirectory $directory -Mode ([string]$state.mode)
            $state.status = 'PAUSED_USER'
            $state.lastCompletedStage = [string]$reset.lastCommittedStep
            $state.openIssues = @($state.openIssues | Where-Object { $_ -ne $IssueId }) + @($IssueId)
            $state.blockingIssues = @($state.blockingIssues | Where-Object { $_ -ne $IssueId }) + @($IssueId)
            $state.updatedAt = Get-DuoForgeUtcNow
            Write-DuoForgeJsonAtomic -Path $statePath -Value $state
            Add-DuoForgeRunEvent -RunDirectory $directory -Type 'USER_DECISION_RECORDED' -Status 'PAUSED_USER' -Data ([ordered]@{ issueId = $IssueId; action = if ($ReplacePrevious) { 'CHANGE' } else { 'ANSWER' }; choiceCode = $decisionRecord.choiceCode; revision = $decisionRecord.revision; resetSteps = $reset.resetSteps })
            return [ordered]@{ status = 'PAUSED_USER'; issueId = $IssueId; choiceCode = $decisionRecord.choiceCode; revision = $decisionRecord.revision; resetSteps = $reset.resetSteps }
        }

        if (-not $ConfirmPartial) { throw (New-DuoForgeException -Code 'DF-DEFER-CONFIRM' -Message '보류에는 부분 완료에 대한 명시적 확인이 필요합니다.') }
        if ([string]$issue.severity -eq 'critical') { throw (New-DuoForgeException -Code 'DF-DEFER-CRITICAL' -Message 'Critical 쟁점은 보류로 종료할 수 없습니다. 답변 후 다시 검증해 주세요.') }
        Add-DuoForgeJsonLine -Path (Join-Path $directory 'decisions\user-answers.jsonl') -Value $decisionRecord
        $combinedResponses = [System.Collections.Generic.List[object]]::new()
        if ($issue.responses.Contains('user')) { foreach ($response in @($issue.responses['user'])) { $combinedResponses.Add($response) } }
        $combinedResponses.Add($decisionRecord)
        $issue.responses['user'] = @($combinedResponses)
        $issue.resolutionStatus = 'DEFERRED'
        $issue.history = @($issue.history) + @([ordered]@{ at = $decisionRecord.recordedAt; event = 'USER_DEFERRED'; actor = 'user'; status = 'DEFERRED' })
        Write-DuoForgeJsonAtomic -Path $ledgerPath -Value $ledger
        $pending.questions = @($pending.questions | Where-Object { [string]$_.issueKey -ne $IssueId })
        Write-DuoForgeJsonAtomic -Path $pendingPath -Value $pending
        $state.status = 'COMPLETED_PARTIAL'
        $state.openIssues = @($state.openIssues | Where-Object { $_ -ne $IssueId })
        $state.blockingIssues = @($state.blockingIssues | Where-Object { $_ -ne $IssueId })
        $state.answeredIssues = @($state.answeredIssues | Where-Object { $_ -ne $IssueId }) + @($IssueId)
        $state.updatedAt = Get-DuoForgeUtcNow
        Write-DuoForgeJsonAtomic -Path $statePath -Value $state
        Add-DuoForgeRunEvent -RunDirectory $directory -Type 'USER_DECISION_RECORDED' -Status 'COMPLETED_PARTIAL' -Data ([ordered]@{ issueId = $IssueId; action = 'DEFER' })
        return [ordered]@{ status = 'COMPLETED_PARTIAL'; issueId = $IssueId; action = 'DEFER' }
    }
}
