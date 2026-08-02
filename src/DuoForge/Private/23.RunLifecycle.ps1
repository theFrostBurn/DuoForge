function Get-DuoForgeSafeSchemaReferenceFailureInternal {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Step)

    $lastError = Get-DuoForgeObjectValue -Object $Step -Name 'lastError'
    if ($null -eq $lastError) { return [ordered]@{ eligible = $false; legacy = $false; failures = @() } }
    $code = [string](Get-DuoForgeObjectValue -Object $lastError -Name 'code' -Default '')
    if ($code -ceq 'DF-STAGE-REFERENCE') {
        $allowedCodes = @('DF-REF-DUPLICATE', 'DF-REF-KEY-REUSED', 'DF-REF-DANGLING', 'DF-REF-TARGET-MISMATCH', 'DF-REF-PROVIDER-MISMATCH')
        $failures = @(Get-DuoForgeObjectValue -Object $lastError -Name 'validationFailures' -Default @())
        if ($failures.Count -lt 1) { return [ordered]@{ eligible = $false; legacy = $false; failures = @() } }
        $safe = [System.Collections.Generic.List[object]]::new()
        foreach ($failure in $failures) {
            $failureCode = [string](Get-DuoForgeObjectValue -Object $failure -Name 'code' -Default '')
            $path = [string](Get-DuoForgeObjectValue -Object $failure -Name 'path' -Default '')
            $count = [int](Get-DuoForgeObjectValue -Object $failure -Name 'count' -Default 0)
            $expected = @((Get-DuoForgeObjectValue -Object $failure -Name 'expected' -Default @()) | ForEach-Object { [string]$_ })
            if ($failureCode -notin $allowedCodes -or
                $path -notmatch '^(?:issues|issueResponses|adoptions|openQuestions)\[\d+\]\.[A-Za-z][A-Za-z0-9]*$' -or
                $count -lt 1 -or
                @($expected | Where-Object { $_ -notin @('A', 'B', 'merged', 'brief', 'codex', 'claude') }).Count -gt 0) {
                return [ordered]@{ eligible = $false; legacy = $false; failures = @() }
            }
            $safe.Add([ordered]@{ code = $failureCode; path = $path; count = $count; expected = @($expected) })
        }
        return [ordered]@{ eligible = $true; legacy = $false; failures = @($safe) }
    }
    if ($code -cne 'DF-STAGE-SCHEMA') { return [ordered]@{ eligible = $false; legacy = $false; failures = @() } }

    $legacyErrors = @(Get-DuoForgeObjectValue -Object $lastError -Name 'validationErrors' -Default @())
    if ($legacyErrors.Count -lt 1) { return [ordered]@{ eligible = $false; legacy = $true; failures = @() } }
    $legacyCounts = [ordered]@{
        'DF-REF-KEY-REUSED|issues[].issueKey' = 0
        'DF-REF-DANGLING|adoptions[].issueKey' = 0
        'DF-REF-TARGET-MISMATCH|adoptions[].targetDocumentId' = 0
    }
    foreach ($legacyErrorValue in $legacyErrors) {
        $legacyError = [string]$legacyErrorValue
        if ($legacyError -match '^issues\.issueKey가 (?:보존된 다른 쟁점에서 이미 사용되었습니다|이전 단계에서 이미 정의되었습니다): .+$') {
            $legacyCounts['DF-REF-KEY-REUSED|issues[].issueKey']++
        }
        elseif ($legacyError -match '^adoptions\.issueKey가 정의된 쟁점을 참조하지 않습니다: .+$') {
            $legacyCounts['DF-REF-DANGLING|adoptions[].issueKey']++
        }
        elseif ($legacyError -match '^adoptions\.targetDocumentId가 참조 쟁점의 대상과 다릅니다: .+$') {
            $legacyCounts['DF-REF-TARGET-MISMATCH|adoptions[].targetDocumentId']++
        }
        else {
            return [ordered]@{ eligible = $false; legacy = $true; failures = @() }
        }
    }
    $safeLegacy = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in $legacyCounts.GetEnumerator()) {
        if ([int]$entry.Value -lt 1) { continue }
        $parts = [string]$entry.Key -split '\|', 2
        $safeLegacy.Add([ordered]@{ code = $parts[0]; path = $parts[1]; count = [int]$entry.Value; expected = @() })
    }
    return [ordered]@{ eligible = $true; legacy = $true; failures = @($safeLegacy) }
}

function Get-DuoForgeRecoveryPlanInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('workflow-v1', 'workflow-v2', 'workflow-v3')][string]$WorkflowVersion,
        [Parameter(Mandatory)][string]$FailureCode,
        [Parameter(Mandatory)]$Step
    )

    $internalCause = switch ($FailureCode) {
        'DF-RUN-TIME-LIMIT' { 'runtime-extension'; break }
        'DF-STAGE-REFERENCE' { 'reference-regeneration'; break }
        'DF-PROMPT-SIZE-LIMIT' { 'prompt-projection'; break }
        { $_ -in @('DF-PROJECT-CONTRACT', 'DF-PROJECT-CONTRACT-MISMATCH') } { 'project-contract'; break }
        default { 'transient-retry' }
    }
    return [ordered]@{
        workflowVersion = $WorkflowVersion
        internalCause = $internalCause
        failureCode = $FailureCode
        stepKey = [string](Get-DuoForgeObjectValue -Object $Step -Name 'stepKey' -Default '')
        userAction = 'prepare-recovery'
        userCommand = 'recover'
        confirmationToken = 'RECOVER'
        userState = 'RESUMABLE_ERROR'
        providerCalls = 0
        requiresLive = $true
        consumesUserRetryBudget = $internalCause -eq 'transient-retry'
    }
}

function Get-DuoForgeDecisionApplicationRepairEligibilityInternal {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunDirectory)

    $manifest = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path (Join-Path $RunDirectory 'manifest.json'))
    $state = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path (Join-Path $RunDirectory 'state.json'))
    $workflowVersion = Get-DuoForgeWorkflowVersionInternal -Manifest $manifest
    $ineligible = {
        param([string]$Reason)
        return [ordered]@{ eligible = $false; reason = $Reason; workflowVersion = $workflowVersion }
    }
    try { $null = Assert-DuoForgeRunStorageContractInternal -RunDirectory $RunDirectory }
    catch { return & $ineligible '저장 실행 계약이 유효하지 않아 결정 반영 복구를 준비할 수 없습니다.' }
    if ($workflowVersion -ne 'workflow-v3' -or [string]$state.status -ne 'QUESTION_LIMIT_REACHED' -or -not [bool](Get-DuoForgeObjectValue -Object $state -Name 'decisionReviewLimitReached' -Default $false)) {
        return & $ineligible '사용자 결정 반영 결함으로 질문 한도에 도달한 workflow-v3 실행이 아닙니다.'
    }
    if ([string](Get-DuoForgeObjectValue -Object $state -Name 'recoveryCause' -Default '') -eq 'decision-application') {
        return & $ineligible '이 실행의 사용자 결정 반영 복구를 이미 사용했습니다.'
    }
    $stepsPath = Join-Path $RunDirectory 'steps.json'
    if (-not (Test-Path -LiteralPath $stepsPath -PathType Leaf)) { return & $ineligible '복구할 단계 기록이 없습니다.' }
    $graph = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path $stepsPath)
    if (@($graph.steps | Where-Object { [string]$_.stage -eq 'integration' }).Count -ne 1 -or
        @($graph.steps | Where-Object { [string]$_.stage -eq 'final-validation' }).Count -ne 1 -or
        @($graph.steps | Where-Object { [string]$_.status -ne 'COMMITTED' }).Count -gt 0) {
        return & $ineligible '결정 반영 복구에 필요한 완료 단계 그래프가 아닙니다.'
    }

    $pendingPath = Join-Path $RunDirectory 'decisions\pending.json'
    $pending = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path $pendingPath)
    $questions = @($pending.questions)
    if ($questions.Count -lt 1) { return & $ineligible '반복 여부를 확인할 보존 질문이 없습니다.' }
    $ledger = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path (Join-Path $RunDirectory 'issues.json'))
    $records = @(Read-DuoForgeJsonLines -Path (Join-Path $RunDirectory 'decisions\user-answers.jsonl') -AllowMissing)
    $effective = @(Get-DuoForgeEffectiveUserDecisionsInternal -Records $records | Where-Object { [string](Get-DuoForgeObjectValue -Object $_ -Name 'action' -Default '') -eq 'ANSWER' })
    foreach ($question in $questions) {
        $issueId = [string](Get-DuoForgeObjectValue -Object $question -Name 'issueKey' -Default '')
        $issue = @($ledger.issues | Where-Object { [string]$_.issueId -eq $issueId } | Select-Object -First 1)
        $decision = @($effective | Where-Object { [string]$_.issueId -eq $issueId } | Select-Object -Last 1)
        if ($issue.Count -ne 1 -or $decision.Count -ne 1) { return & $ineligible '모든 보존 질문에 일치하는 기존 답변이 있지 않습니다.' }
        $fingerprint = [string](Get-DuoForgeObjectValue -Object $decision[0] -Name 'issueFingerprint' -Default '')
        if ([string]::IsNullOrWhiteSpace($fingerprint) -or $fingerprint -cne [string]$issue[0].fingerprint) { return & $ineligible '기존 답변과 현재 쟁점의 식별 계약이 다릅니다.' }
        $recordedQuestion = ([string](Get-DuoForgeObjectValue -Object $decision[0] -Name 'questionText' -Default '') -replace '\s+', ' ').Trim()
        $currentQuestion = ([string](Get-DuoForgeObjectValue -Object $question -Name 'question' -Default '') -replace '\s+', ' ').Trim()
        $recordedTitle = ([string](Get-DuoForgeObjectValue -Object $decision[0] -Name 'questionTitle' -Default '') -replace '\s+', ' ').Trim()
        $currentTitle = ([string](Get-DuoForgeObjectValue -Object $question -Name 'title' -Default '') -replace '\s+', ' ').Trim()
        $recordedRecommendation = ([string](Get-DuoForgeObjectValue -Object $decision[0] -Name 'recommendedOption' -Default '') -replace '\s+', ' ').Trim()
        $currentRecommendation = ([string](Get-DuoForgeObjectValue -Object $question -Name 'recommendedOption' -Default '') -replace '\s+', ' ').Trim()
        $recordedClaim = ([string](Get-DuoForgeObjectValue -Object $decision[0] -Name 'claim' -Default '') -replace '\s+', ' ').Trim()
        $currentClaim = ([string](Get-DuoForgeObjectValue -Object $issue[0] -Name 'claim' -Default '') -replace '\s+', ' ').Trim()
        $recordedProposal = ([string](Get-DuoForgeObjectValue -Object $decision[0] -Name 'proposal' -Default '') -replace '\s+', ' ').Trim()
        $currentProposal = ([string](Get-DuoForgeObjectValue -Object $issue[0] -Name 'proposal' -Default '') -replace '\s+', ' ').Trim()
        $recordedOptions = @((Get-DuoForgeObjectValue -Object $decision[0] -Name 'questionOptions' -Default @()) | ForEach-Object { ([string]$_ -replace '\s+', ' ').Trim() })
        $currentOptions = @((Get-DuoForgeObjectValue -Object $question -Name 'options' -Default @()) | ForEach-Object { ([string]$_ -replace '\s+', ' ').Trim() })
        $selected = ([string](Get-DuoForgeObjectValue -Object $decision[0] -Name 'selectedOption' -Default '') -replace '\s+', ' ').Trim()
        if ($recordedQuestion -cne $currentQuestion -or $recordedTitle -cne $currentTitle -or
            $recordedRecommendation -cne $currentRecommendation -or $recordedClaim -cne $currentClaim -or
            $recordedProposal -cne $currentProposal -or ($recordedOptions -join "`n") -cne ($currentOptions -join "`n") -or
            $selected -cnotin $currentOptions) {
            return & $ineligible '보존 질문이 기존 답변의 질문 계약과 달라 새 사용자 판단이 필요합니다.'
        }
    }
    $integrationStep = @($graph.steps | Where-Object { [string]$_.stage -eq 'integration' })[0]
    $plan = [ordered]@{
        workflowVersion = 'workflow-v3'; internalCause = 'decision-application'; failureCode = 'DF-DECISION-APPLICATION'
        stepKey = [string]$integrationStep.stepKey
        userAction = 'prepare-recovery'; userCommand = 'recover'; confirmationToken = 'RECOVER'
        userState = 'PAUSED_USER'; providerCalls = 0; requiresLive = $true; consumesUserRetryBudget = $false
    }
    return [ordered]@{ eligible = $true; reason = ''; workflowVersion = $workflowVersion; state = $state; graph = $graph; plan = $plan; repeatedQuestionCount = $questions.Count }
}

function Get-DuoForgeTerminalRecommendationRepairEligibilityInternal {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunDirectory)

    $manifest = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path (Join-Path $RunDirectory 'manifest.json'))
    $state = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path (Join-Path $RunDirectory 'state.json'))
    $workflowVersion = Get-DuoForgeWorkflowVersionInternal -Manifest $manifest
    $ineligible = {
        param([string]$Reason)
        return [ordered]@{ eligible = $false; reason = $Reason; workflowVersion = $workflowVersion }
    }
    try { $null = Assert-DuoForgeRunStorageContractInternal -RunDirectory $RunDirectory }
    catch { return & $ineligible '저장 실행 계약이 유효하지 않아 마지막 권장안 복구를 준비할 수 없습니다.' }
    if ($workflowVersion -ne 'workflow-v3' -or [string]$state.status -ne 'QUESTION_LIMIT_REACHED' -or
        -not [bool](Get-DuoForgeObjectValue -Object $state -Name 'decisionReviewLimitReached' -Default $false)) {
        return & $ineligible '마지막 권장안 복구가 필요한 workflow-v3 질문 한도 실행이 아닙니다.'
    }
    if ([string](Get-DuoForgeObjectValue -Object $state -Name 'recoveryCause' -Default '') -eq 'terminal-recommendation') {
        return & $ineligible '이 실행의 마지막 권장안 복구를 이미 사용했습니다.'
    }
    $graph = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path (Join-Path $RunDirectory 'steps.json'))
    $integration = @($graph.steps | Where-Object { [string]$_.stage -eq 'integration' })
    $validation = @($graph.steps | Where-Object { [string]$_.stage -eq 'final-validation' })
    if ($integration.Count -ne 1 -or $validation.Count -ne 1 -or
        @($graph.steps | Where-Object { [string]$_.status -ne 'COMMITTED' }).Count -gt 0 -or
        @($graph.steps | Where-Object { [string]$_.stage -eq 'final-revision' }).Count -gt 0) {
        return & $ineligible '마지막 권장안만 최종 수정에 반영할 수 있는 완료 단계 그래프가 아닙니다.'
    }
    $pending = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path (Join-Path $RunDirectory 'decisions\pending.json'))
    $questions = @($pending.questions)
    if ($questions.Count -lt 1 -or $questions.Count -gt 3) { return & $ineligible '마지막 권장안으로 안전하게 처리할 질문 수가 아닙니다.' }
    $ledger = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path (Join-Path $RunDirectory 'issues.json'))
    $records = @(Read-DuoForgeJsonLines -Path (Join-Path $RunDirectory 'decisions\user-answers.jsonl') -AllowMissing)
    $effective = @(Get-DuoForgeEffectiveUserDecisionsInternal -Records $records | Where-Object { [string]$_.action -eq 'ANSWER' })
    $revisionIssues = [System.Collections.Generic.List[object]]::new()
    foreach ($question in $questions) {
        $issueId = [string](Get-DuoForgeObjectValue -Object $question -Name 'issueKey' -Default '')
        $issue = @($ledger.issues | Where-Object { [string]$_.issueId -eq $issueId })
        if ($issue.Count -ne 1 -or -not [bool](Get-DuoForgeObjectValue -Object $issue[0] -Name 'blocking' -Default $false) -or
            @($effective | Where-Object { [string]$_.issueId -eq $issueId }).Count -gt 0) {
            return & $ineligible '마지막 권장안 복구는 아직 답하지 않은 단일 차단 쟁점 계약에만 사용할 수 있습니다.'
        }
        $options = @(Get-DuoForgeQuestionOptionsForInteractionInternal -Options @(Get-DuoForgeObjectValue -Object $question -Name 'options' -Default @()))
        $recommended = ([string](Get-DuoForgeObjectValue -Object $question -Name 'recommendedOption' -Default '')).Trim()
        $matched = $false
        for ($index = 0; $index -lt $options.Count; $index++) {
            $letter = [string][char]([int][char]'A' + $index)
            $raw = [string]$options[$index]
            $prefix = '^\s*' + [regex]::Escape($letter) + '\s*[:：.)-]\s*'
            $label = [regex]::Replace($raw, $prefix, '', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase).Trim()
            if ($recommended -ieq $letter -or $recommended -ieq $raw -or $recommended -ieq $label -or $recommended -match $prefix) { $matched = $true; break }
        }
        if (-not $matched) { return & $ineligible '마지막 질문에 실제 선택지와 일치하는 AI 권장안이 없습니다.' }
        $revisionIssues.Add([ordered]@{
            severity = [string](Get-DuoForgeObjectValue -Object $issue[0] -Name 'severity' -Default '')
            blockingProposal = [bool](Get-DuoForgeObjectValue -Object $issue[0] -Name 'blocking' -Default $false)
        })
    }
    $plan = [ordered]@{
        workflowVersion = 'workflow-v3'; internalCause = 'terminal-recommendation'; failureCode = 'DF-TERMINAL-RECOMMENDATION'
        stepKey = [string]$validation[0].stepKey; userAction = 'prepare-recovery'; userCommand = 'recover'; confirmationToken = 'RECOVER'
        userState = 'PAUSED_USER'; providerCalls = 0; requiresLive = $true; consumesUserRetryBudget = $false
    }
    return [ordered]@{
        eligible = $true; reason = ''; workflowVersion = $workflowVersion; state = $state; graph = $graph; plan = $plan
        questionCount = $questions.Count; revisionRequirement = [ordered]@{ issues = @($revisionIssues) }
    }
}

function Get-DuoForgeUnifiedRecoveryEligibilityInternal {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunDirectory)

    $manifest = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path (Join-Path $RunDirectory 'manifest.json'))
    $state = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path (Join-Path $RunDirectory 'state.json'))
    $workflowVersion = Get-DuoForgeWorkflowVersionInternal -Manifest $manifest
    $stepsPath = Join-Path $RunDirectory 'steps.json'
    if (-not (Test-Path -LiteralPath $stepsPath -PathType Leaf)) { return [ordered]@{ eligible = $false; reason = '복구할 단계 기록이 없습니다.'; workflowVersion = $workflowVersion } }
    $graph = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path $stepsPath)
    if ([string]$state.status -eq 'QUESTION_LIMIT_REACHED') {
        $decisionApplication = Get-DuoForgeDecisionApplicationRepairEligibilityInternal -RunDirectory $RunDirectory
        if ([bool]$decisionApplication.eligible) { return $decisionApplication }
        return Get-DuoForgeTerminalRecommendationRepairEligibilityInternal -RunDirectory $RunDirectory
    }
    $failed = @($graph.steps | Where-Object { [string]$_.status -eq 'FAILED' })
    if ($failed.Count -ne 1 -or [string]$state.status -notin @('FAILED_STAGE', 'RESUMABLE_ERROR')) {
        return [ordered]@{ eligible = $false; reason = '복구할 실패 단계를 하나로 특정할 수 없습니다.'; workflowVersion = $workflowVersion }
    }
    $step = $failed[0]
    $lastError = Get-DuoForgeObjectValue -Object $step -Name 'lastError' -Default ([ordered]@{})
    $failureCode = if (-not [string]::IsNullOrWhiteSpace([string](Get-DuoForgeObjectValue -Object $lastError -Name 'projectContractFixId' -Default ''))) {
        'DF-PROJECT-CONTRACT'
    }
    else { [string](Get-DuoForgeObjectValue -Object $lastError -Name 'code' -Default 'DF-STAGE-UNEXPECTED') }
    $plan = Get-DuoForgeRecoveryPlanInternal -WorkflowVersion $workflowVersion -FailureCode $failureCode -Step $step
    if ([bool]$plan.consumesUserRetryBudget -and [int](Get-DuoForgeObjectValue -Object $step -Name 'manualRetryCount' -Default 0) -ge 1) {
        return [ordered]@{ eligible = $false; reason = '사용자 복구 준비 1회를 이미 사용했습니다.'; workflowVersion = $workflowVersion; step = $step; plan = $plan }
    }
    return [ordered]@{ eligible = $true; reason = ''; workflowVersion = $workflowVersion; state = $state; graph = $graph; step = $step; plan = $plan }
}

function Enable-DuoForgeUnifiedRecoveryInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [string]$ResultsRoot,
        [scriptblock]$FaultInjector
    )

    $run = Get-DuoForgeRunInternal -RunId $RunId -ResultsRoot $ResultsRoot
    $runDirectory = [string]$run.runDirectory
    $eligibility = Get-DuoForgeUnifiedRecoveryEligibilityInternal -RunDirectory $runDirectory
    if (-not [bool]$eligibility.eligible) { throw (New-DuoForgeException -Code 'DF-RUN-RECOVERY-NOT-ELIGIBLE' -Message ([string]$eligibility.reason)) }
    if ([string]$eligibility.plan.internalCause -eq 'terminal-recommendation') {
        return Invoke-WithDuoForgeRunLock -RunDirectory $runDirectory -ScriptBlock {
            return Invoke-WithDuoForgeRunMutationTransactionInternal -RunDirectory $runDirectory -RelativePaths @('state.json', 'steps.json', 'decisions\pending.json', 'events.jsonl') -RelativeDirectories @('history\decisions') -ScriptBlock {
                $current = Get-DuoForgeTerminalRecommendationRepairEligibilityInternal -RunDirectory $runDirectory
                if (-not [bool]$current.eligible) { throw (New-DuoForgeException -Code 'DF-RUN-RECOVERY-NOT-ELIGIBLE' -Message ([string]$current.reason)) }
                $graph = ConvertTo-DuoForgeHashtable -InputObject $current.graph
                $validationStep = @($graph.steps | Where-Object { [string]$_.stage -eq 'final-validation' })[0]
                if ([string]::IsNullOrWhiteSpace([string]$validationStep.artifactPath) -or
                    (Get-DuoForgeSha256 -Path ([string]$validationStep.artifactPath)) -cne [string]$validationStep.artifactHash) {
                    throw (New-DuoForgeException -Code 'DF-PROMPT-DEPENDENCY-INTEGRITY' -Message '최종 검증 산출물의 무결성이 변경되었습니다.')
                }
                $graph = Add-DuoForgeThinFinalRevisionStepInternal -Graph $graph -ValidationResult (ConvertTo-DuoForgeHashtable -InputObject $current.revisionRequirement)
                $revisionSteps = @($graph.steps | Where-Object { [string]$_.stage -eq 'final-revision' -and [string]$_.status -eq 'PENDING' })
                if ($revisionSteps.Count -ne 1) { throw (New-DuoForgeException -Code 'DF-PROJECT-CONTRACT' -Message '마지막 권장안을 반영할 최종 수정 단계를 만들지 못했습니다.') }
                Write-DuoForgeJsonAtomic -Path (Join-Path $runDirectory 'steps.json') -Value $graph
                $state = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path (Join-Path $runDirectory 'state.json'))
                $state.status = 'PAUSED_USER'
                $state.lastCompletedStage = [string]$validationStep.stepKey
                $state.decisionReviewLimitReached = $false
                $state.recoveryPreparationCount = [int](Get-DuoForgeObjectValue -Object $state -Name 'recoveryPreparationCount' -Default 0) + 1
                $state.recoveryPreparedAt = Get-DuoForgeUtcNow
                $state.recoveryCause = 'terminal-recommendation'
                $state.updatedAt = Get-DuoForgeUtcNow
                Write-DuoForgeJsonAtomic -Path (Join-Path $runDirectory 'state.json') -Value $state
                if ($null -ne $FaultInjector) { & $FaultInjector 'after-state-and-steps' }
                Add-DuoForgeRunEvent -RunDirectory $runDirectory -Type 'TERMINAL_RECOMMENDATION_RECOVERY_PREPARED' -Status 'PAUSED_USER' -Data ([ordered]@{ questionCount = [int]$current.questionCount; resetSteps = @($revisionSteps.stepKey); providerCalls = 0 })
                return [ordered]@{
                    runId = $RunId; status = 'PAUSED_USER'; recoveryKind = 'terminal-recommendation'
                    userCommand = 'recover'; confirmationToken = 'RECOVER'; providerCalls = 0; requiresLive = $true
                    consumesUserRetryBudget = $false; resetSteps = @($revisionSteps.stepKey)
                }
            }
        }
    }
    if ([string]$eligibility.plan.internalCause -eq 'decision-application') {
        return Invoke-WithDuoForgeRunLock -RunDirectory $runDirectory -ScriptBlock {
            return Invoke-WithDuoForgeRunMutationTransactionInternal -RunDirectory $runDirectory -RelativePaths @('state.json', 'steps.json', 'decisions\pending.json', 'events.jsonl') -RelativeDirectories @('history\decisions') -ScriptBlock {
                $current = Get-DuoForgeDecisionApplicationRepairEligibilityInternal -RunDirectory $runDirectory
                if (-not [bool]$current.eligible) { throw (New-DuoForgeException -Code 'DF-RUN-RECOVERY-NOT-ELIGIBLE' -Message ([string]$current.reason)) }
                $reset = Reset-DuoForgeDecisionAffectedSteps -RunDirectory $runDirectory -Mode ([string]$current.state.mode)
                Write-DuoForgeJsonAtomic -Path (Join-Path $runDirectory 'decisions\pending.json') -Value ([ordered]@{ schemaVersion = 1; questions = @() })
                $state = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path (Join-Path $runDirectory 'state.json'))
                $state.status = 'PAUSED_USER'
                $state.lastCompletedStage = [string]$reset.lastCommittedStep
                $state.decisionReviewLimitReached = $false
                $state.recoveryPreparationCount = [int](Get-DuoForgeObjectValue -Object $state -Name 'recoveryPreparationCount' -Default 0) + 1
                $state.recoveryPreparedAt = Get-DuoForgeUtcNow
                $state.recoveryCause = 'decision-application'
                $state.updatedAt = Get-DuoForgeUtcNow
                Write-DuoForgeJsonAtomic -Path (Join-Path $runDirectory 'state.json') -Value $state
                if ($null -ne $FaultInjector) { & $FaultInjector 'after-state-and-steps' }
                Add-DuoForgeRunEvent -RunDirectory $runDirectory -Type 'DECISION_APPLICATION_RECOVERY_PREPARED' -Status 'PAUSED_USER' -Data ([ordered]@{ repeatedQuestionCount = [int]$current.repeatedQuestionCount; resetSteps = @($reset.resetSteps); providerCalls = 0 })
                return [ordered]@{
                    runId = $RunId; status = 'PAUSED_USER'; recoveryKind = 'decision-application'
                    userCommand = 'recover'; confirmationToken = 'RECOVER'; providerCalls = 0; requiresLive = $true
                    consumesUserRetryBudget = $false; resetSteps = @($reset.resetSteps)
                }
            }
        }
    }
    if ([string]$eligibility.workflowVersion -ne 'workflow-v3') {
        $cause = [string]$eligibility.plan.internalCause
        $legacy = switch ($cause) {
            'project-contract' { Enable-DuoForgeProjectContractRepairInternal -RunId $RunId -ResultsRoot $ResultsRoot; break }
            'reference-regeneration' { Enable-DuoForgeSchemaRepairInternal -RunId $RunId -ResultsRoot $ResultsRoot; break }
            'prompt-projection' { Enable-DuoForgePromptRepairInternal -RunId $RunId -ResultsRoot $ResultsRoot; break }
            default { Enable-DuoForgeFailedStageRetryInternal -RunId $RunId -ResultsRoot $ResultsRoot; break }
        }
        $legacy = ConvertTo-DuoForgeHashtable -InputObject $legacy
        $legacy.userCommand = 'recover'
        $legacy.confirmationToken = 'RECOVER'
        $legacy.providerCalls = 0
        $legacy.requiresLive = $true
        return $legacy
    }

    return Invoke-WithDuoForgeRunLock -RunDirectory $runDirectory -ScriptBlock {
        return Invoke-WithDuoForgeRunMutationTransactionInternal -RunDirectory $runDirectory -RelativePaths @('state.json', 'steps.json', 'events.jsonl') -ScriptBlock {
            $current = Get-DuoForgeUnifiedRecoveryEligibilityInternal -RunDirectory $runDirectory
            if (-not [bool]$current.eligible) { throw (New-DuoForgeException -Code 'DF-RUN-RECOVERY-NOT-ELIGIBLE' -Message ([string]$current.reason)) }
            $state = ConvertTo-DuoForgeHashtable -InputObject $current.state
            $graph = ConvertTo-DuoForgeHashtable -InputObject $current.graph
            $step = @($graph.steps | Where-Object { [string]$_.stepKey -eq [string]$current.step.stepKey })[0]
            if ([bool]$current.plan.consumesUserRetryBudget) { $step.manualRetryCount = [int](Get-DuoForgeObjectValue -Object $step -Name 'manualRetryCount' -Default 0) + 1 }
            elseif (-not $step.Contains('manualRetryCount')) { $step.manualRetryCount = 0 }
            $step.status = 'PENDING'
            $step.retryMode = 'USER_RECOVERY_PREPARED'
            $state.status = 'RESUMABLE_ERROR'
            $state.recoveryPreparationCount = [int](Get-DuoForgeObjectValue -Object $state -Name 'recoveryPreparationCount' -Default 0) + 1
            $state.recoveryPreparedAt = Get-DuoForgeUtcNow
            $state.recoveryCause = [string]$current.plan.internalCause
            $state.updatedAt = Get-DuoForgeUtcNow
            Write-DuoForgeJsonAtomic -Path (Join-Path $runDirectory 'steps.json') -Value $graph
            Write-DuoForgeJsonAtomic -Path (Join-Path $runDirectory 'state.json') -Value $state
            if ($null -ne $FaultInjector) { & $FaultInjector 'after-state-and-steps' }
            Add-DuoForgeRunEvent -RunDirectory $runDirectory -Type 'RECOVERY_PREPARED' -Status 'RESUMABLE_ERROR' -Data ([ordered]@{ stepKey = [string]$step.stepKey; cause = [string]$current.plan.internalCause; providerCalls = 0 })
            return [ordered]@{
                runId = $RunId; status = 'RESUMABLE_ERROR'; recoveryKind = [string]$current.plan.internalCause
                userCommand = 'recover'; confirmationToken = 'RECOVER'; providerCalls = 0; requiresLive = $true
                consumesUserRetryBudget = [bool]$current.plan.consumesUserRetryBudget
            }
        }
    }
}

function Get-DuoForgeProjectContractFixDefinitionInternal {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$FixId)

    $knownFixId = 'DF-FIX-STAGE-RESULT-V2-PROFILE-EQUIVALENCE-20260802'
    if ($FixId -cne $knownFixId) { return $null }
    return [ordered]@{
        fixId = $knownFixId
        knownLegacyRunIdHash = '5d336d94ce261c77b829a0cc3ed434410d977b1bc39921c9e49236dfa9725aa6'
        sourceContract = [ordered]@{
            manifestSchemaVersion = 4
            workflowVersion = 'workflow-v2'
            storageContractVersion = 'duoforge-run-v2'
            stateSchemaVersion = 2
            stageGraphSchemaVersion = 2
            stageResultSchemaVersion = 2
            promptContractVersion = 'duoforge-stage-v5'
        }
        scope = [ordered]@{
            stepKey = 'r01-claude-independent-merge-draft'
            provider = 'claude'
            performedBy = 'claude'
            stage = 'independent-merge-draft'
            round = 1
            targetDocumentId = 'merged'
            sourceDocumentIds = @('A', 'B')
            inputGeneration = 1
            attemptCount = 3
            totalAttemptCount = 3
            manualRetryCount = 1
            retryMode = 'RETRY_EXHAUSTED'
        }
        failure = [ordered]@{
            code = 'DF-STAGE-SCHEMA'
            validationCode = 'DF-VAL-STRUCTURE'
            path = '$'
            count = 1
        }
    }
}

function Get-DuoForgeProjectContractRunIdHashInternal {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$RunId)

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($RunId)
    return [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function Resolve-DuoForgeProjectContractFixInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)]$Manifest,
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)]$Graph
    )

    $notRecognized = { [ordered]@{ recognized = $false; legacy = $false; fixId = ''; step = $null } }
    if ([string](Get-DuoForgeObjectValue -Object $State -Name 'runId' -Default '') -cne $RunId) { return & $notRecognized }
    $failedSteps = @($Graph.steps | Where-Object { [string]$_.status -eq 'FAILED' })
    if ($failedSteps.Count -ne 1) { return & $notRecognized }
    $step = $failedSteps[0]
    $lastError = Get-DuoForgeObjectValue -Object $step -Name 'lastError'
    if ($null -eq $lastError) { return & $notRecognized }

    $storedFixId = [string](Get-DuoForgeObjectValue -Object $lastError -Name 'projectContractFixId' -Default '')
    $legacy = $false
    if ([string]::IsNullOrWhiteSpace($storedFixId)) {
        $definition = Get-DuoForgeProjectContractFixDefinitionInternal -FixId 'DF-FIX-STAGE-RESULT-V2-PROFILE-EQUIVALENCE-20260802'
        if ((Get-DuoForgeProjectContractRunIdHashInternal -RunId $RunId) -cne [string]$definition.knownLegacyRunIdHash) { return & $notRecognized }
        $legacy = $true
    }
    else {
        $definition = Get-DuoForgeProjectContractFixDefinitionInternal -FixId $storedFixId
        if ($null -eq $definition) { return & $notRecognized }
    }

    $contract = $definition.sourceContract
    if ([int](Get-DuoForgeObjectValue -Object $Manifest -Name 'schemaVersion' -Default 0) -ne [int]$contract.manifestSchemaVersion -or
        [string](Get-DuoForgeObjectValue -Object $Manifest -Name 'workflowVersion' -Default '') -cne [string]$contract.workflowVersion -or
        [string](Get-DuoForgeObjectValue -Object $Manifest -Name 'storageContractVersion' -Default '') -cne [string]$contract.storageContractVersion -or
        [int](Get-DuoForgeObjectValue -Object $Manifest -Name 'stateSchemaVersion' -Default 0) -ne [int]$contract.stateSchemaVersion -or
        [int](Get-DuoForgeObjectValue -Object $Manifest -Name 'stageGraphSchemaVersion' -Default 0) -ne [int]$contract.stageGraphSchemaVersion -or
        [int](Get-DuoForgeObjectValue -Object $Manifest -Name 'stageResultSchemaVersion' -Default 0) -ne [int]$contract.stageResultSchemaVersion -or
        [string](Get-DuoForgeObjectValue -Object $Manifest -Name 'promptTemplateVersion' -Default '') -cne [string]$contract.promptContractVersion -or
        [int](Get-DuoForgeObjectValue -Object $State -Name 'schemaVersion' -Default 0) -ne [int]$contract.stateSchemaVersion -or
        [string](Get-DuoForgeObjectValue -Object $State -Name 'workflowVersion' -Default '') -cne [string]$contract.workflowVersion -or
        [string](Get-DuoForgeObjectValue -Object $State -Name 'promptContractVersion' -Default '') -cne [string]$contract.promptContractVersion -or
        [int](Get-DuoForgeObjectValue -Object $Graph -Name 'schemaVersion' -Default 0) -ne [int]$contract.stageGraphSchemaVersion -or
        [string](Get-DuoForgeObjectValue -Object $Graph -Name 'workflowVersion' -Default '') -cne [string]$contract.workflowVersion) {
        return & $notRecognized
    }

    $scope = $definition.scope
    $sourceDocumentIds = @((Get-DuoForgeObjectValue -Object $step -Name 'sourceDocumentIds' -Default @()) | ForEach-Object { [string]$_ })
    if ([string]$step.stepKey -cne [string]$scope.stepKey -or
        [string]$step.provider -cne [string]$scope.provider -or
        [string](Get-DuoForgeObjectValue -Object $step -Name 'performedBy' -Default '') -cne [string]$scope.performedBy -or
        [string]$step.stage -cne [string]$scope.stage -or
        [int]$step.round -ne [int]$scope.round -or
        [string](Get-DuoForgeObjectValue -Object $step -Name 'targetDocumentId' -Default '') -cne [string]$scope.targetDocumentId -or
        ($sourceDocumentIds -join ',') -cne (@($scope.sourceDocumentIds) -join ',') -or
        [int](Get-DuoForgeObjectValue -Object $step -Name 'inputGeneration' -Default 0) -ne [int]$scope.inputGeneration -or
        [int](Get-DuoForgeObjectValue -Object $step -Name 'attemptCount' -Default 0) -ne [int]$scope.attemptCount -or
        [int](Get-DuoForgeObjectValue -Object $step -Name 'totalAttemptCount' -Default 0) -ne [int]$scope.totalAttemptCount -or
        [int](Get-DuoForgeObjectValue -Object $step -Name 'manualRetryCount' -Default 0) -ne [int]$scope.manualRetryCount -or
        [string](Get-DuoForgeObjectValue -Object $step -Name 'retryMode' -Default '') -cne [string]$scope.retryMode -or
        -not [string]::IsNullOrWhiteSpace([string](Get-DuoForgeObjectValue -Object $step -Name 'artifactPath' -Default '')) -or
        -not [string]::IsNullOrWhiteSpace([string](Get-DuoForgeObjectValue -Object $step -Name 'artifactHash' -Default ''))) {
        return & $notRecognized
    }

    $failure = $definition.failure
    $validationFailures = @(Get-DuoForgeObjectValue -Object $lastError -Name 'validationFailures' -Default @())
    if ([string](Get-DuoForgeObjectValue -Object $lastError -Name 'code' -Default '') -cne [string]$failure.code -or
        -not [bool](Get-DuoForgeObjectValue -Object $lastError -Name 'retryable' -Default $false) -or
        $validationFailures.Count -ne 1) {
        return & $notRecognized
    }
    $validationFailure = $validationFailures[0]
    $expected = @(Get-DuoForgeObjectValue -Object $validationFailure -Name 'expected' -Default @())
    if ([string](Get-DuoForgeObjectValue -Object $validationFailure -Name 'code' -Default '') -cne [string]$failure.validationCode -or
        [string](Get-DuoForgeObjectValue -Object $validationFailure -Name 'path' -Default '') -cne [string]$failure.path -or
        [int](Get-DuoForgeObjectValue -Object $validationFailure -Name 'count' -Default 0) -ne [int]$failure.count -or
        $expected.Count -ne 0) {
        return & $notRecognized
    }

    return [ordered]@{
        recognized = $true
        legacy = $legacy
        fixId = [string]$definition.fixId
        step = $step
        definition = $definition
    }
}

function Get-DuoForgeProjectContractRepairEligibilityInternal {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunDirectory)

    $manifest = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path (Join-Path $RunDirectory 'manifest.json'))
    $state = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path (Join-Path $RunDirectory 'state.json'))
    $graph = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path (Join-Path $RunDirectory 'steps.json'))
    $match = Resolve-DuoForgeProjectContractFixInternal -RunId ([string]$state.runId) -Manifest $manifest -State $state -Graph $graph
    if (-not [bool]$match.recognized) {
        return [ordered]@{ recognized = $false; eligible = $false; reason = '이 실패는 알려진 프로젝트 계약 오류로 확인되지 않았습니다.'; fixId = ''; step = $null }
    }
    if ([string]$state.status -cne 'FAILED_STAGE') {
        return [ordered]@{ recognized = $true; eligible = $false; reason = '프로젝트 계약 오류가 난 실패 상태에서만 복구를 준비할 수 있습니다.'; fixId = [string]$match.fixId; step = $match.step }
    }
    if ([int](Get-DuoForgeObjectValue -Object $state -Name 'projectContractRepairGrantCount' -Default 0) -ne 0) {
        return [ordered]@{ recognized = $true; eligible = $false; reason = '이 실행의 프로젝트 오류 복구를 이미 사용했습니다.'; fixId = [string]$match.fixId; step = $match.step }
    }
    $pendingPath = Join-Path $RunDirectory 'decisions\pending.json'
    if ((Test-Path -LiteralPath $pendingPath -PathType Leaf) -and @((Read-DuoForgeJson -Path $pendingPath).questions).Count -gt 0) {
        return [ordered]@{ recognized = $true; eligible = $false; reason = '답하지 않은 질문이 있어 프로젝트 오류 복구를 준비할 수 없습니다.'; fixId = [string]$match.fixId; step = $match.step }
    }
    $callBudget = Get-DuoForgeRemainingCallBudget -RunDirectory $RunDirectory
    $providerBudget = Get-DuoForgeObjectValue -Object $callBudget.providers -Name ([string]$match.step.provider)
    if ($null -eq $providerBudget -or [int](Get-DuoForgeObjectValue -Object $providerBudget -Name 'maximumAdditionalCalls' -Default 0) -lt 1) {
        return [ordered]@{ recognized = $true; eligible = $false; reason = '이 AI에 허용된 전체 요청 횟수가 남아 있지 않습니다.'; fixId = [string]$match.fixId; step = $match.step }
    }
    $runtimeBudget = Get-DuoForgeRuntimeBudgetInternal -RunDirectory $RunDirectory
    if ([bool]$runtimeBudget.exhausted) {
        return [ordered]@{ recognized = $true; eligible = $false; reason = '남은 총 실행시간이 없어 먼저 시간 한도를 확인해야 합니다.'; fixId = [string]$match.fixId; step = $match.step }
    }
    return [ordered]@{
        recognized = $true
        eligible = $true
        reason = ''
        fixId = [string]$match.fixId
        legacy = [bool]$match.legacy
        step = $match.step
        runtimeBudget = $runtimeBudget
    }
}

function Get-DuoForgeSchemaRepairEligibilityInternal {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunDirectory)

    $state = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path (Join-Path $RunDirectory 'state.json'))
    $graph = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path (Join-Path $RunDirectory 'steps.json'))
    $failedSteps = @($graph.steps | Where-Object { [string]$_.status -eq 'FAILED' })
    if ([string]$state.status -ne 'FAILED_STAGE' -or $failedSteps.Count -ne 1) {
        return [ordered]@{ eligible = $false; reason = '쟁점 참조 오류가 난 단일 실패 단계에서만 복구를 준비할 수 있습니다.'; step = $null; failures = @() }
    }
    $step = $failedSteps[0]
    $classification = Get-DuoForgeSafeSchemaReferenceFailureInternal -Step $step
    if (-not [bool]$classification.eligible) {
        return [ordered]@{ eligible = $false; reason = '이 실패는 안전하게 분류된 쟁점 참조 오류가 아닙니다.'; step = $step; failures = @() }
    }
    $grantCount = [int](Get-DuoForgeObjectValue -Object $state -Name 'schemaRepairGrantCount' -Default 0)
    if ($grantCount -ne 0) {
        return [ordered]@{ eligible = $false; reason = '이 실행의 쟁점 참조 복구 1회를 이미 사용했습니다.'; step = $step; failures = @($classification.failures) }
    }
    $pendingPath = Join-Path $RunDirectory 'decisions\pending.json'
    if ((Test-Path -LiteralPath $pendingPath -PathType Leaf) -and @((Read-DuoForgeJson -Path $pendingPath).questions).Count -gt 0) {
        return [ordered]@{ eligible = $false; reason = '답하지 않은 질문이 있어 쟁점 참조 복구를 준비할 수 없습니다.'; step = $step; failures = @($classification.failures) }
    }
    $callBudget = Get-DuoForgeRemainingCallBudget -RunDirectory $RunDirectory
    $providerBudget = Get-DuoForgeObjectValue -Object $callBudget.providers -Name ([string]$step.provider)
    if ($null -eq $providerBudget -or [int](Get-DuoForgeObjectValue -Object $providerBudget -Name 'maximumAdditionalCalls' -Default 0) -lt 1) {
        return [ordered]@{ eligible = $false; reason = '이 AI에 허용된 전체 요청 횟수가 남아 있지 않습니다.'; step = $step; failures = @($classification.failures) }
    }
    $runtimeBudget = Get-DuoForgeRuntimeBudgetInternal -RunDirectory $RunDirectory
    if ([bool]$runtimeBudget.exhausted) {
        return [ordered]@{ eligible = $false; reason = '남은 총 실행시간이 없어 먼저 시간 한도를 확인해야 합니다.'; step = $step; failures = @($classification.failures) }
    }
    return [ordered]@{ eligible = $true; reason = ''; step = $step; failures = @($classification.failures); legacy = [bool]$classification.legacy; runtimeBudget = $runtimeBudget }
}

function Get-DuoForgePromptRepairEligibilityInternal {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunDirectory)

    $state = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path (Join-Path $RunDirectory 'state.json'))
    $manifest = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path (Join-Path $RunDirectory 'manifest.json'))
    $graph = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path (Join-Path $RunDirectory 'steps.json'))
    $failedSteps = @($graph.steps | Where-Object { [string]$_.status -eq 'FAILED' })
    if ([string]$state.status -notin @('RESUMABLE_ERROR', 'FAILED_STAGE') -or $failedSteps.Count -ne 1) {
        return [ordered]@{ eligible = $false; reason = '입력 크기 오류가 난 단일 실패 단계에서만 복구를 준비할 수 있습니다.'; step = $null }
    }
    $step = $failedSteps[0]
    $lastError = Get-DuoForgeObjectValue -Object $step -Name 'lastError'
    if ([string](Get-DuoForgeObjectValue -Object $lastError -Name 'code' -Default '') -cne 'DF-PROMPT-SIZE-LIMIT' -or
        [string]$step.stage -notin @('final-validation', 'document-validation') -or
        [int](Get-DuoForgeObjectValue -Object $step -Name 'attemptCount' -Default 0) -ne 0) {
        return [ordered]@{ eligible = $false; reason = '이 실패는 AI 호출 전에 발생한 최종 확인 입력 크기 오류가 아닙니다.'; step = $step }
    }
    if ([string]$manifest.workflowVersion -ne 'workflow-v2' -or
        [string]$manifest.promptTemplateVersion -ne 'duoforge-stage-v4' -or
        [string]$state.promptContractVersion -ne 'duoforge-stage-v4') {
        return [ordered]@{ eligible = $false; reason = '이 실행의 입력 계약은 안전한 크기 복구 대상이 아닙니다.'; step = $step }
    }
    if ([int](Get-DuoForgeObjectValue -Object $state -Name 'promptRepairGrantCount' -Default 0) -ne 0) {
        return [ordered]@{ eligible = $false; reason = '이 실행의 입력 크기 복구 1회를 이미 사용했습니다.'; step = $step }
    }
    $pendingPath = Join-Path $RunDirectory 'decisions\pending.json'
    if ((Test-Path -LiteralPath $pendingPath -PathType Leaf) -and @((Read-DuoForgeJson -Path $pendingPath).questions).Count -gt 0) {
        return [ordered]@{ eligible = $false; reason = '답하지 않은 질문이 있어 입력 크기 복구를 준비할 수 없습니다.'; step = $step }
    }
    $callBudget = Get-DuoForgeRemainingCallBudget -RunDirectory $RunDirectory
    $providerBudget = Get-DuoForgeObjectValue -Object $callBudget.providers -Name ([string]$step.provider)
    if ($null -eq $providerBudget -or [int](Get-DuoForgeObjectValue -Object $providerBudget -Name 'maximumAdditionalCalls' -Default 0) -lt 1) {
        return [ordered]@{ eligible = $false; reason = '이 AI에 허용된 전체 요청 횟수가 남아 있지 않습니다.'; step = $step }
    }
    $runtimeBudget = Get-DuoForgeRuntimeBudgetInternal -RunDirectory $RunDirectory
    if ([bool]$runtimeBudget.exhausted) {
        return [ordered]@{ eligible = $false; reason = '남은 총 실행시간이 없어 먼저 시간 한도를 확인해야 합니다.'; step = $step }
    }
    try {
        $prompt = New-DuoForgeStagePrompt -RunDirectory $RunDirectory -Graph $graph -Step $step -PromptTemplateVersionOverride 'duoforge-stage-v5'
    }
    catch {
        return [ordered]@{
            eligible = $false
            reason = '대상별 입력 축소를 적용해도 현재 호출 한도 안에 안전하게 들어오지 않습니다.'
            step = $step
            failureCode = if ($_.Exception.Data.Contains('DuoForgeCode')) { [string]$_.Exception.Data['DuoForgeCode'] } else { 'DF-PROMPT-REPAIR-PREFLIGHT' }
        }
    }
    return [ordered]@{
        eligible = $true
        reason = ''
        step = $step
        promptBytes = [long]$prompt.bytes
        maximumInputBytes = [long]$prompt.maximumInputBytes
        runtimeBudget = $runtimeBudget
    }
}

function Get-DuoForgeContinuationEligibilityInternal {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunDirectory)

    $state = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path (Join-Path $RunDirectory 'state.json'))
    if ([string]$state.status -in @('COMPLETED', 'COMPLETED_PARTIAL', 'QUESTION_LIMIT_REACHED', 'SOURCE_DRIFT', 'CANCELLED')) {
        return [ordered]@{ eligible = $false; reason = '이미 종료된 작업입니다.'; failureCode = ''; recoveryKind = '' }
    }
    $stepsPath = Join-Path $RunDirectory 'steps.json'
    if (-not (Test-Path -LiteralPath $stepsPath -PathType Leaf)) {
        return [ordered]@{ eligible = $true; reason = ''; failureCode = ''; recoveryKind = '' }
    }
    $graph = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path $stepsPath)
    $failedSteps = @($graph.steps | Where-Object { [string]$_.status -eq 'FAILED' })
    if ($failedSteps.Count -eq 0) {
        return [ordered]@{ eligible = $true; reason = ''; failureCode = ''; recoveryKind = '' }
    }
    $step = $failedSteps[0]
    $lastError = Get-DuoForgeObjectValue -Object $step -Name 'lastError'
    $failureCode = [string](Get-DuoForgeObjectValue -Object $lastError -Name 'code' -Default '')
    $projectContractRepair = Get-DuoForgeProjectContractRepairEligibilityInternal -RunDirectory $RunDirectory
    $recoveryKind = if ([bool]$projectContractRepair.recognized) { 'project-contract-repair' }
        elseif ($failureCode -eq 'DF-PROMPT-SIZE-LIMIT') { 'prompt-size-repair' }
        elseif ([bool](Get-DuoForgeSafeSchemaReferenceFailureInternal -Step $step).eligible) { 'schema-reference-repair' }
        else { 'failed-stage-retry' }
    return [ordered]@{
        eligible = $false
        reason = '실패 단계의 복구를 먼저 준비해야 합니다.'
        failureCode = $failureCode
        recoveryKind = $recoveryKind
        step = $step
    }
}

function Get-DuoForgeFailedStageRetryEligibilityInternal {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunDirectory)

    $state = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path (Join-Path $RunDirectory 'state.json'))
    $graph = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path (Join-Path $RunDirectory 'steps.json'))
    $failedSteps = @($graph.steps | Where-Object { [string]$_.status -eq 'FAILED' })
    if (Test-DuoForgeRuntimeLimitFailureInternal -RunDirectory $RunDirectory) {
        $step = $failedSteps[0]
        $budget = Get-DuoForgeRuntimeBudgetInternal -RunDirectory $RunDirectory
        if ([int]$budget.extensionGrantCount -ge 1) {
            return [ordered]@{ eligible = $false; reason = '이 실행의 총 실행시간 연장 1회를 이미 사용했습니다.'; recoveryKind = 'runtime-extension'; step = $step; runtimeBudget = $budget }
        }
        if (-not [bool]$budget.exhausted) {
            return [ordered]@{ eligible = $false; reason = '저장된 시간 제한 실패와 현재 총 실행시간 한도가 일치하지 않습니다.'; recoveryKind = 'runtime-extension'; step = $step; runtimeBudget = $budget }
        }
        return [ordered]@{ eligible = $true; reason = ''; recoveryKind = 'runtime-extension'; step = $step; runtimeBudget = $budget }
    }
    if ([string]$state.status -ne 'FAILED_STAGE') {
        return [ordered]@{ eligible = $false; reason = '작업 실패 상태에서만 다시 시도를 준비할 수 있습니다.'; recoveryKind = ''; step = $null }
    }
    if ($failedSteps.Count -ne 1) {
        return [ordered]@{ eligible = $false; reason = '실패 단계를 하나로 안전하게 특정할 수 없습니다.'; recoveryKind = 'failed-stage-retry'; step = $null }
    }

    $step = $failedSteps[0]
    $projectContractRepair = Get-DuoForgeProjectContractRepairEligibilityInternal -RunDirectory $RunDirectory
    if ([bool]$projectContractRepair.recognized) {
        return [ordered]@{ eligible = $false; reason = '알려진 프로젝트 계약 오류는 별도의 프로젝트 오류 복구 준비를 사용해야 합니다.'; recoveryKind = 'failed-stage-retry'; step = $step }
    }
    if ([bool](Get-DuoForgeSafeSchemaReferenceFailureInternal -Step $step).eligible) {
        return [ordered]@{ eligible = $false; reason = '쟁점 참조 오류는 별도의 REPAIR 복구 준비를 사용해야 합니다.'; recoveryKind = 'failed-stage-retry'; step = $step }
    }
    if ([string](Get-DuoForgeObjectValue -Object $step -Name 'retryMode' -Default '') -ne 'RETRY_EXHAUSTED') {
        return [ordered]@{ eligible = $false; reason = '자동 재시도가 소진된 단계가 아닙니다.'; recoveryKind = 'failed-stage-retry'; step = $step }
    }
    $lastError = Get-DuoForgeObjectValue -Object $step -Name 'lastError'
    if ($null -eq $lastError -or -not [bool](Get-DuoForgeObjectValue -Object $lastError -Name 'retryable' -Default $false)) {
        return [ordered]@{ eligible = $false; reason = '이 오류는 같은 단계의 추가 시도를 허용하지 않습니다.'; recoveryKind = 'failed-stage-retry'; step = $step }
    }
    if ([int](Get-DuoForgeObjectValue -Object $step -Name 'manualRetryCount' -Default 0) -ge 1) {
        return [ordered]@{ eligible = $false; reason = '사용자가 허용할 수 있는 추가 시도 1회를 이미 사용했습니다.'; recoveryKind = 'failed-stage-retry'; step = $step }
    }
    $budget = Get-DuoForgeRemainingCallBudget -RunDirectory $RunDirectory
    $providerBudget = Get-DuoForgeObjectValue -Object $budget.providers -Name ([string]$step.provider)
    if ($null -eq $providerBudget -or [int](Get-DuoForgeObjectValue -Object $providerBudget -Name 'maximumAdditionalCalls' -Default 0) -lt 1) {
        return [ordered]@{ eligible = $false; reason = '이 AI에 허용된 전체 요청 횟수가 남아 있지 않습니다.'; recoveryKind = 'failed-stage-retry'; step = $step }
    }

    return [ordered]@{ eligible = $true; reason = ''; recoveryKind = 'failed-stage-retry'; step = $step }
}

function Enable-DuoForgeSchemaRepairInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [string]$ResultsRoot
    )

    $run = Get-DuoForgeRunInternal -RunId $RunId -ResultsRoot $ResultsRoot
    $runDirectory = [string]$run.runDirectory
    return Invoke-WithDuoForgeRunLock -RunDirectory $runDirectory -ScriptBlock {
        $null = Assert-DuoForgeRunStorageContractInternal -RunDirectory $runDirectory
        $eligibility = Get-DuoForgeSchemaRepairEligibilityInternal -RunDirectory $runDirectory
        if (-not [bool]$eligibility.eligible) {
            throw (New-DuoForgeException -Code 'DF-SCHEMA-REPAIR-UNAVAILABLE' -Message ([string]$eligibility.reason))
        }
        return Invoke-WithDuoForgeRunMutationTransactionInternal -RunDirectory $runDirectory -RelativePaths @('manifest.json', 'state.json', 'steps.json', 'events.jsonl') -ScriptBlock {
            $manifestPath = Join-Path $runDirectory 'manifest.json'
            $statePath = Join-Path $runDirectory 'state.json'
            $stepsPath = Join-Path $runDirectory 'steps.json'
            $manifest = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path $manifestPath)
            $state = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path $statePath)
            $graph = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path $stepsPath)
            $step = @($graph.steps | Where-Object { [string]$_.status -eq 'FAILED' })[0]
            $previousCode = [string](Get-DuoForgeObjectValue -Object (Get-DuoForgeObjectValue -Object $step -Name 'lastError') -Name 'code' -Default '')
            $preparedAt = Get-DuoForgeUtcNow
            $previousGeneration = [Math]::Max(1, [int](Get-DuoForgeObjectValue -Object $step -Name 'inputGeneration' -Default 1))
            $nextGeneration = $previousGeneration + 1
            $totalAttemptCount = [int](Get-DuoForgeObjectValue -Object $step -Name 'totalAttemptCount' -Default ([int](Get-DuoForgeObjectValue -Object $step -Name 'attemptCount' -Default 0)))
            $manualRetryCount = [int](Get-DuoForgeObjectValue -Object $step -Name 'manualRetryCount' -Default 0)
            $history = [System.Collections.Generic.List[object]]::new()
            foreach ($entry in @(Get-DuoForgeObjectValue -Object $step -Name 'history' -Default @())) { $history.Add($entry) }
            $history.Add([ordered]@{
                at = $preparedAt
                event = 'SCHEMA_REPAIR_PREPARED'
                previousCode = $previousCode
                validationFailures = @($eligibility.failures)
                previousInputGeneration = $previousGeneration
                inputGeneration = $nextGeneration
                totalAttemptCount = $totalAttemptCount
                manualRetryCount = $manualRetryCount
            })

            $step.history = @($history)
            $step.status = 'PENDING'
            $step.inputGeneration = $nextGeneration
            $step.attemptCount = 0
            $step.retryMode = $null
            $step.inputHash = $null
            $step.lastPromptKind = $null
            $step.lastError = $null
            $state.status = 'RESUMABLE_ERROR'
            $state.schemaRepairGrantCount = 1
            $state.schemaRepairPreparedAt = $preparedAt
            $state.promptContractVersion = 'duoforge-stage-v4'
            $state.updatedAt = $preparedAt
            $manifest.promptTemplateVersion = 'duoforge-stage-v4'
            $manifest.updatedAt = $preparedAt

            Write-DuoForgeJsonAtomic -Path $stepsPath -Value $graph
            Write-DuoForgeJsonAtomic -Path $statePath -Value $state
            Write-DuoForgeJsonAtomic -Path $manifestPath -Value $manifest
            Add-DuoForgeRunEvent -RunDirectory $runDirectory -Type 'SCHEMA_REPAIR_PREPARED' -Status 'RESUMABLE_ERROR' -Data ([ordered]@{
                previousCode = $previousCode
                previousInputGeneration = $previousGeneration
                inputGeneration = $nextGeneration
                totalAttemptCount = $totalAttemptCount
                manualRetryCount = $manualRetryCount
                schemaRepairGrantCount = 1
                providerCalls = 0
            })
            $null = Assert-DuoForgeRunStorageContractInternal -RunDirectory $runDirectory
            return [ordered]@{
                runId = $RunId
                status = 'RESUMABLE_ERROR'
                recoveryKind = 'schema-reference-repair'
                inputGeneration = $nextGeneration
                attemptCount = 0
                totalAttemptCount = $totalAttemptCount
                manualRetryCount = $manualRetryCount
                schemaRepairGrantCount = 1
                providerCalls = 0
                runDirectory = $runDirectory
            }
        }
    }
}

function Enable-DuoForgeProjectContractRepairInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [string]$ResultsRoot
    )

    $run = Get-DuoForgeRunInternal -RunId $RunId -ResultsRoot $ResultsRoot
    $runDirectory = [string]$run.runDirectory
    return Invoke-WithDuoForgeRunLock -RunDirectory $runDirectory -ScriptBlock {
        $null = Assert-DuoForgeRunStorageContractInternal -RunDirectory $runDirectory
        $eligibility = Get-DuoForgeProjectContractRepairEligibilityInternal -RunDirectory $runDirectory
        if (-not [bool]$eligibility.eligible) {
            throw (New-DuoForgeException -Code 'DF-PROJECT-CONTRACT-REPAIR-UNAVAILABLE' -Message ([string]$eligibility.reason))
        }
        return Invoke-WithDuoForgeRunMutationTransactionInternal -RunDirectory $runDirectory -RelativePaths @('state.json', 'steps.json', 'events.jsonl') -ScriptBlock {
            $statePath = Join-Path $runDirectory 'state.json'
            $stepsPath = Join-Path $runDirectory 'steps.json'
            $state = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path $statePath)
            $graph = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path $stepsPath)
            $step = @($graph.steps | Where-Object { [string]$_.status -eq 'FAILED' })[0]
            $preparedAt = Get-DuoForgeUtcNow
            $previousGeneration = [int](Get-DuoForgeObjectValue -Object $step -Name 'inputGeneration' -Default 0)
            $nextGeneration = $previousGeneration + 1
            $totalAttemptCount = [int](Get-DuoForgeObjectValue -Object $step -Name 'totalAttemptCount' -Default ([int]$step.attemptCount))
            $manualRetryCount = [int](Get-DuoForgeObjectValue -Object $step -Name 'manualRetryCount' -Default 0)
            $history = [System.Collections.Generic.List[object]]::new()
            foreach ($entry in @(Get-DuoForgeObjectValue -Object $step -Name 'history' -Default @())) { $history.Add($entry) }
            $history.Add([ordered]@{
                at = $preparedAt
                event = 'PROJECT_CONTRACT_REPAIR_PREPARED'
                fixId = [string]$eligibility.fixId
                sourceContract = 'workflow-v2/stage-result-v2/duoforge-stage-v5'
                previousInputGeneration = $previousGeneration
                inputGeneration = $nextGeneration
                totalAttemptCount = $totalAttemptCount
                manualRetryCount = $manualRetryCount
            })

            $step.history = @($history)
            $step.status = 'PENDING'
            $step.retryMode = 'PROJECT_CONTRACT_REPAIR'
            $step.inputGeneration = $nextGeneration
            $step.attemptCount = 0
            $step.inputHash = $null
            $step.lastPromptKind = $null
            $state.status = 'RESUMABLE_ERROR'
            $state.projectContractRepairGrantCount = 1
            $state.projectContractRepairFixId = [string]$eligibility.fixId
            $state.projectContractRepairPreparedAt = $preparedAt
            $state.updatedAt = $preparedAt

            Write-DuoForgeJsonAtomic -Path $stepsPath -Value $graph
            Write-DuoForgeJsonAtomic -Path $statePath -Value $state
            Add-DuoForgeRunEvent -RunDirectory $runDirectory -Type 'PROJECT_CONTRACT_REPAIR_PREPARED' -Status 'RESUMABLE_ERROR' -Data ([ordered]@{
                fixId = [string]$eligibility.fixId
                stepKey = [string]$step.stepKey
                previousInputGeneration = $previousGeneration
                inputGeneration = $nextGeneration
                attemptCount = 0
                totalAttemptCount = $totalAttemptCount
                manualRetryCount = $manualRetryCount
                providerCalls = 0
            })
            $null = Assert-DuoForgeRunStorageContractInternal -RunDirectory $runDirectory
            return [ordered]@{
                runId = $RunId
                status = 'RESUMABLE_ERROR'
                recoveryKind = 'project-contract-repair'
                fixId = [string]$eligibility.fixId
                stepKey = [string]$step.stepKey
                inputGeneration = $nextGeneration
                attemptCount = 0
                totalAttemptCount = $totalAttemptCount
                manualRetryCount = $manualRetryCount
                providerCalls = 0
                runDirectory = $runDirectory
            }
        }
    }
}

function Enable-DuoForgePromptRepairInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [string]$ResultsRoot
    )

    $run = Get-DuoForgeRunInternal -RunId $RunId -ResultsRoot $ResultsRoot
    $runDirectory = [string]$run.runDirectory
    return Invoke-WithDuoForgeRunLock -RunDirectory $runDirectory -ScriptBlock {
        $null = Assert-DuoForgeRunStorageContractInternal -RunDirectory $runDirectory
        $eligibility = Get-DuoForgePromptRepairEligibilityInternal -RunDirectory $runDirectory
        if (-not [bool]$eligibility.eligible) {
            throw (New-DuoForgeException -Code 'DF-PROMPT-REPAIR-UNAVAILABLE' -Message ([string]$eligibility.reason))
        }
        return Invoke-WithDuoForgeRunMutationTransactionInternal -RunDirectory $runDirectory -RelativePaths @('manifest.json', 'state.json', 'steps.json', 'events.jsonl') -ScriptBlock {
            $manifestPath = Join-Path $runDirectory 'manifest.json'
            $statePath = Join-Path $runDirectory 'state.json'
            $stepsPath = Join-Path $runDirectory 'steps.json'
            $manifest = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path $manifestPath)
            $state = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path $statePath)
            $graph = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path $stepsPath)
            $step = @($graph.steps | Where-Object { [string]$_.status -eq 'FAILED' })[0]
            $lastError = Get-DuoForgeObjectValue -Object $step -Name 'lastError'
            $previousCode = [string](Get-DuoForgeObjectValue -Object $lastError -Name 'code' -Default '')
            $preparedAt = Get-DuoForgeUtcNow
            $previousGeneration = [Math]::Max(1, [int](Get-DuoForgeObjectValue -Object $step -Name 'inputGeneration' -Default 1))
            $nextGeneration = $previousGeneration + 1
            $totalAttemptCount = [int](Get-DuoForgeObjectValue -Object $step -Name 'totalAttemptCount' -Default ([int](Get-DuoForgeObjectValue -Object $step -Name 'attemptCount' -Default 0)))
            $history = [System.Collections.Generic.List[object]]::new()
            foreach ($entry in @(Get-DuoForgeObjectValue -Object $step -Name 'history' -Default @())) { $history.Add($entry) }
            $history.Add([ordered]@{
                at = $preparedAt
                event = 'PROMPT_REPAIR_PREPARED'
                previousCode = $previousCode
                previousInputGeneration = $previousGeneration
                inputGeneration = $nextGeneration
                totalAttemptCount = $totalAttemptCount
                promptBytes = [long]$eligibility.promptBytes
                maximumInputBytes = [long]$eligibility.maximumInputBytes
            })

            $step.history = @($history)
            $step.status = 'PENDING'
            $step.inputGeneration = $nextGeneration
            $step.attemptCount = 0
            $step.retryMode = $null
            $step.inputHash = $null
            $step.lastPromptKind = $null
            $step.lastError = $null
            $state.status = 'RESUMABLE_ERROR'
            $state.promptRepairGrantCount = 1
            $state.promptRepairPreparedAt = $preparedAt
            $state.promptContractVersion = 'duoforge-stage-v5'
            $state.updatedAt = $preparedAt
            $manifest.promptTemplateVersion = 'duoforge-stage-v5'
            $manifest.artifactProjectionPolicy = 'stage-relevance-v1'
            $manifest.updatedAt = $preparedAt

            Write-DuoForgeJsonAtomic -Path $stepsPath -Value $graph
            Write-DuoForgeJsonAtomic -Path $statePath -Value $state
            Write-DuoForgeJsonAtomic -Path $manifestPath -Value $manifest
            $preparedPrompt = New-DuoForgeStagePrompt -RunDirectory $runDirectory -Graph $graph -Step $step
            Add-DuoForgeRunEvent -RunDirectory $runDirectory -Type 'PROMPT_REPAIR_PREPARED' -Status 'RESUMABLE_ERROR' -Data ([ordered]@{
                stepKey = [string]$step.stepKey
                previousCode = $previousCode
                previousInputGeneration = $previousGeneration
                inputGeneration = $nextGeneration
                totalAttemptCount = $totalAttemptCount
                promptBytes = [long]$preparedPrompt.bytes
                maximumInputBytes = [long]$preparedPrompt.maximumInputBytes
                promptRepairGrantCount = 1
                providerCalls = 0
            })
            $null = Assert-DuoForgeRunStorageContractInternal -RunDirectory $runDirectory
            return [ordered]@{
                runId = $RunId
                status = 'RESUMABLE_ERROR'
                recoveryKind = 'prompt-size-repair'
                stepKey = [string]$step.stepKey
                inputGeneration = $nextGeneration
                attemptCount = 0
                totalAttemptCount = $totalAttemptCount
                promptBytes = [long]$preparedPrompt.bytes
                maximumInputBytes = [long]$preparedPrompt.maximumInputBytes
                promptRepairGrantCount = 1
                providerCalls = 0
                runDirectory = $runDirectory
            }
        }
    }
}

function Enable-DuoForgeFailedStageRetryInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [string]$ResultsRoot
    )

    $run = Get-DuoForgeRunInternal -RunId $RunId -ResultsRoot $ResultsRoot
    $runDirectory = [string]$run.runDirectory
    return Invoke-WithDuoForgeRunLock -RunDirectory $runDirectory -ScriptBlock {
        $current = Get-DuoForgeRunInternal -RunId $RunId -ResultsRoot $ResultsRoot
        $runtimeLimitFailure = Test-DuoForgeRuntimeLimitFailureInternal -RunDirectory $runDirectory
        if ([string]$current.state.status -ne 'FAILED_STAGE' -and -not $runtimeLimitFailure) {
            throw (New-DuoForgeException -Code 'DF-RUN-RETRY-STATE' -Message '다시 시도 준비는 실패한 작업에만 사용할 수 있습니다.')
        }

        $null = Assert-DuoForgeRunStorageContractInternal -RunDirectory $runDirectory
        $eligibility = Get-DuoForgeFailedStageRetryEligibilityInternal -RunDirectory $runDirectory
        if (-not [bool]$eligibility.eligible) {
            throw (New-DuoForgeException -Code 'DF-RUN-RETRY-UNAVAILABLE' -Message ([string]$eligibility.reason))
        }
        $pendingPath = Join-Path $runDirectory 'decisions\pending.json'
        if ((Test-Path -LiteralPath $pendingPath -PathType Leaf) -and @((Read-DuoForgeJson -Path $pendingPath).questions).Count -gt 0) {
            throw (New-DuoForgeException -Code 'DF-RUN-RETRY-PENDING' -Message '답하지 않은 질문이 있어 실패 단계를 다시 준비할 수 없습니다.')
        }

        if ([string]$eligibility.recoveryKind -eq 'runtime-extension') {
            return Invoke-WithDuoForgeRunMutationTransactionInternal -RunDirectory $runDirectory -RelativePaths @('state.json', 'steps.json', 'events.jsonl') -ScriptBlock {
                $statePath = Join-Path $runDirectory 'state.json'
                $stepsPath = Join-Path $runDirectory 'steps.json'
                $state = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path $statePath)
                $graph = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path $stepsPath)
                $step = @($graph.steps | Where-Object { [string]$_.status -eq 'FAILED' })[0]
                $budget = Get-DuoForgeRuntimeBudgetInternal -RunDirectory $runDirectory
                $preparedAt = Get-DuoForgeUtcNow

                $state.runtimeExtensionMinutes = 60
                $state.runtimeExtensionGrantCount = 1
                $state.status = 'RESUMABLE_ERROR'
                $state.updatedAt = $preparedAt
                $step.status = 'PENDING'
                if ([string]::IsNullOrWhiteSpace([string](Get-DuoForgeObjectValue -Object $step -Name 'retryMode' -Default '')) -and
                    [int](Get-DuoForgeObjectValue -Object $step -Name 'manualRetryCount' -Default 0) -ge 1) {
                    $step.retryMode = 'MANUAL_RETRY'
                }

                Write-DuoForgeJsonAtomic -Path $stepsPath -Value $graph
                Write-DuoForgeJsonAtomic -Path $statePath -Value $state
                Add-DuoForgeRunEvent -RunDirectory $runDirectory -Type 'RUNTIME_EXTENSION_GRANTED' -Status 'RESUMABLE_ERROR' -Data ([ordered]@{
                    stepKey = [string]$step.stepKey
                    usedSeconds = [double]$budget.usedSeconds
                    baseMaximumMinutes = [int]$budget.baseMaximumMinutes
                    extensionMinutes = 60
                    effectiveMaximumMinutes = [int]$budget.baseMaximumMinutes + 60
                    extensionGrantCount = 1
                    providerCalls = 0
                })
                $null = Assert-DuoForgeRunStorageContractInternal -RunDirectory $runDirectory
                return [ordered]@{
                    runId = $RunId
                    status = 'RESUMABLE_ERROR'
                    recoveryKind = 'runtime-extension'
                    stepKey = [string]$step.stepKey
                    attemptCount = [int]$step.attemptCount
                    totalAttemptCount = [int](Get-DuoForgeObjectValue -Object $step -Name 'totalAttemptCount' -Default ([int]$step.attemptCount))
                    manualRetryCount = [int](Get-DuoForgeObjectValue -Object $step -Name 'manualRetryCount' -Default 0)
                    runtimeSeconds = [double]$budget.usedSeconds
                    baseMaximumMinutes = [int]$budget.baseMaximumMinutes
                    extensionMinutes = 60
                    effectiveMaximumMinutes = [int]$budget.baseMaximumMinutes + 60
                    extensionGrantCount = 1
                    providerCalls = 0
                    runDirectory = $runDirectory
                }
            }
        }

        return Invoke-WithDuoForgeRunMutationTransactionInternal -RunDirectory $runDirectory -RelativePaths @('state.json', 'steps.json', 'events.jsonl') -ScriptBlock {
            $statePath = Join-Path $runDirectory 'state.json'
            $stepsPath = Join-Path $runDirectory 'steps.json'
            $state = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path $statePath)
            $graph = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path $stepsPath)
            $step = @($graph.steps | Where-Object { [string]$_.status -eq 'FAILED' })[0]
            $lastError = Get-DuoForgeObjectValue -Object $step -Name 'lastError'
            $preparedAt = Get-DuoForgeUtcNow

            $step.status = 'PENDING'
            $step.retryMode = 'MANUAL_RETRY'
            $step.manualRetryCount = 1
            $state.status = 'RESUMABLE_ERROR'
            $state.updatedAt = $preparedAt

            Write-DuoForgeJsonAtomic -Path $stepsPath -Value $graph
            Write-DuoForgeJsonAtomic -Path $statePath -Value $state
            Add-DuoForgeRunEvent -RunDirectory $runDirectory -Type 'FAILED_STAGE_RETRY_PREPARED' -Status 'RESUMABLE_ERROR' -Data ([ordered]@{
                stepKey = [string]$step.stepKey
                provider = [string]$step.provider
                stage = [string]$step.stage
                targetDocumentId = Get-DuoForgeObjectValue -Object $step -Name 'targetDocumentId'
                round = [int]$step.round
                previousAttemptCount = [int]$step.attemptCount
                totalAttemptCount = [int](Get-DuoForgeObjectValue -Object $step -Name 'totalAttemptCount' -Default ([int]$step.attemptCount))
                manualRetryCount = 1
                diagnosticId = [string](Get-DuoForgeObjectValue -Object $lastError -Name 'diagnosticId' -Default '')
                providerCalls = 0
            })
            $null = Assert-DuoForgeRunStorageContractInternal -RunDirectory $runDirectory
            return [ordered]@{
                runId = $RunId
                status = 'RESUMABLE_ERROR'
                recoveryKind = 'failed-stage-retry'
                stepKey = [string]$step.stepKey
                attemptCount = [int]$step.attemptCount
                totalAttemptCount = [int](Get-DuoForgeObjectValue -Object $step -Name 'totalAttemptCount' -Default ([int]$step.attemptCount))
                manualRetryCount = 1
                providerCalls = 0
                runDirectory = $runDirectory
            }
        }
    }
}

function Abandon-DuoForgeRunInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [string]$ResultsRoot
    )

    $run = Get-DuoForgeRunInternal -RunId $RunId -ResultsRoot $ResultsRoot
    $runDirectory = [string]$run.runDirectory
    return Invoke-WithDuoForgeRunLock -RunDirectory $runDirectory -ScriptBlock {
        $current = Get-DuoForgeRunInternal -RunId $RunId -ResultsRoot $ResultsRoot
        $state = ConvertTo-DuoForgeHashtable -InputObject $current.state
        if ([string]$state.status -eq 'CANCELLED') {
            return [ordered]@{
                runId = $RunId
                name = [string]$current.manifest.name
                status = 'CANCELLED'
                abandoned = $false
                alreadyAbandoned = $true
                runDirectory = $runDirectory
            }
        }

        $otherTerminalStates = @('COMPLETED', 'COMPLETED_PARTIAL', 'QUESTION_LIMIT_REACHED')
        if ([string]$state.status -in $otherTerminalStates) {
            throw (New-DuoForgeException -Code 'DF-RUN-ABANDON-TERMINAL' -Message '이미 종료된 작업은 포기 상태로 바꿀 수 없습니다.')
        }

        $null = Assert-DuoForgeRunStorageContractInternal -RunDirectory $runDirectory
        $previousStatus = [string]$state.status
        return Invoke-WithDuoForgeRunMutationTransactionInternal -RunDirectory $runDirectory -RelativePaths @('state.json', 'events.jsonl') -ScriptBlock {
            $abandonedAt = Get-DuoForgeUtcNow
            $state.status = 'CANCELLED'
            $state.updatedAt = $abandonedAt
            $state.abandonedAt = $abandonedAt
            $state.abandonedFromStatus = $previousStatus
            Write-DuoForgeJsonAtomic -Path (Join-Path $runDirectory 'state.json') -Value $state
            Add-DuoForgeRunEvent -RunDirectory $runDirectory -Type 'STATE_CHANGED' -Status 'CANCELLED' -Data ([ordered]@{ lastCompletedStage = $state.lastCompletedStage; round = $state.round })
            Add-DuoForgeRunEvent -RunDirectory $runDirectory -Type 'RUN_ABANDONED' -Status 'CANCELLED' -Data ([ordered]@{ previousStatus = $previousStatus })
            $null = Assert-DuoForgeRunStorageContractInternal -RunDirectory $runDirectory
            return [ordered]@{
                runId = $RunId
                name = [string]$current.manifest.name
                status = 'CANCELLED'
                abandoned = $true
                alreadyAbandoned = $false
                previousStatus = $previousStatus
                abandonedAt = $abandonedAt
                runDirectory = $runDirectory
            }
        }
    }
}

function Restore-DuoForgeRunInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [string]$ResultsRoot
    )

    $run = Get-DuoForgeRunInternal -RunId $RunId -ResultsRoot $ResultsRoot
    $runDirectory = [string]$run.runDirectory
    return Invoke-WithDuoForgeRunLock -RunDirectory $runDirectory -ScriptBlock {
        $current = Get-DuoForgeRunInternal -RunId $RunId -ResultsRoot $ResultsRoot
        $state = ConvertTo-DuoForgeHashtable -InputObject $current.state
        if ([string]$state.status -ne 'CANCELLED') {
            throw (New-DuoForgeException -Code 'DF-RUN-RESTORE-STATE' -Message '복원은 포기한 작업에만 사용할 수 있습니다.')
        }

        $null = Assert-DuoForgeRunStorageContractInternal -RunDirectory $runDirectory
        return Invoke-WithDuoForgeRunMutationTransactionInternal -RunDirectory $runDirectory -RelativePaths @('state.json', 'events.jsonl') -ScriptBlock {
            $restoredAt = Get-DuoForgeUtcNow
            $abandonedFromStatus = [string](Get-DuoForgeObjectValue -Object $state -Name 'abandonedFromStatus' -Default '')
            $restoredStatus = if ($abandonedFromStatus -in @('FAILED_STAGE', 'SOURCE_DRIFT')) { $abandonedFromStatus } else { 'PAUSED_USER' }
            $state.status = $restoredStatus
            $state.updatedAt = $restoredAt
            $state.restoredAt = $restoredAt
            Write-DuoForgeJsonAtomic -Path (Join-Path $runDirectory 'state.json') -Value $state
            Add-DuoForgeRunEvent -RunDirectory $runDirectory -Type 'STATE_CHANGED' -Status $restoredStatus -Data ([ordered]@{ lastCompletedStage = $state.lastCompletedStage; round = $state.round })
            Add-DuoForgeRunEvent -RunDirectory $runDirectory -Type 'RUN_RESTORED' -Status $restoredStatus -Data ([ordered]@{ previousStatus = 'CANCELLED'; restoredStatus = $restoredStatus })
            $null = Assert-DuoForgeRunStorageContractInternal -RunDirectory $runDirectory
            return [ordered]@{
                runId = $RunId
                name = [string]$current.manifest.name
                status = $restoredStatus
                restored = $true
                previousStatus = 'CANCELLED'
                restoredAt = $restoredAt
                runDirectory = $runDirectory
            }
        }
    }
}

function Resolve-DuoForgeRunDeletionTargetInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [string]$ResultsRoot
    )

    if ([string]::IsNullOrWhiteSpace($RunId) -or
        [System.IO.Path]::GetFileName($RunId) -cne $RunId -or
        $RunId -notmatch '^run-[A-Za-z0-9][A-Za-z0-9._-]*$') {
        throw (New-DuoForgeException -Code 'DF-RUN-DELETE-TARGET' -Message '영구 삭제 대상 작업 ID가 안전한 단일 폴더 이름이 아닙니다.')
    }

    if ([string]::IsNullOrWhiteSpace($ResultsRoot)) { $ResultsRoot = (Get-DuoForgeConfig).resultsRoot }
    $resolvedRoot = [System.IO.Path]::GetFullPath((Resolve-DuoForgePathInternal -Path $ResultsRoot -ExpectedType Directory))
    $target = [System.IO.Path]::GetFullPath((Join-Path $resolvedRoot $RunId))
    $targetParent = [System.IO.Path]::GetDirectoryName($target)
    if (-not [string]::Equals($targetParent.TrimEnd('\', '/'), $resolvedRoot.TrimEnd('\', '/'), [StringComparison]::OrdinalIgnoreCase)) {
        throw (New-DuoForgeException -Code 'DF-RUN-DELETE-TARGET' -Message '영구 삭제 대상이 실행 결과 폴더의 직계 작업 폴더가 아닙니다.')
    }
    if (-not (Test-Path -LiteralPath $target -PathType Container)) {
        throw (New-DuoForgeException -Code 'DF-RUN-NOT-FOUND' -Message "실행을 찾을 수 없습니다: $RunId")
    }

    $targetItem = Get-Item -LiteralPath $target -Force
    if (($targetItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw (New-DuoForgeException -Code 'DF-RUN-DELETE-REPARSE' -Message '연결 지점인 작업 폴더는 영구 삭제할 수 없습니다.')
    }
    $reparseDescendants = @(Get-ChildItem -LiteralPath $target -Recurse -Force -ErrorAction Stop | Where-Object { ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 })
    if ($reparseDescendants.Count -gt 0) {
        throw (New-DuoForgeException -Code 'DF-RUN-DELETE-REPARSE' -Message '작업 폴더 안에 연결 지점이 있어 영구 삭제를 중단했습니다.')
    }

    $run = Get-DuoForgeRunInternal -RunId $RunId -ResultsRoot $resolvedRoot
    if ([string]$run.state.runId -cne $RunId) {
        throw (New-DuoForgeException -Code 'DF-RUN-DELETE-TARGET' -Message '작업 폴더 이름과 저장된 작업 ID가 일치하지 않습니다.')
    }
    return [ordered]@{
        runId = $RunId
        name = [string]$run.manifest.name
        status = [string]$run.state.status
        resultsRoot = $resolvedRoot
        runDirectory = $target
    }
}

function Remove-DuoForgeRunInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [string]$ResultsRoot
    )

    $target = Resolve-DuoForgeRunDeletionTargetInternal -RunId $RunId -ResultsRoot $ResultsRoot
    if ([string]$target.status -ne 'CANCELLED') {
        throw (New-DuoForgeException -Code 'DF-RUN-DELETE-STATE' -Message '영구 삭제는 먼저 포기한 작업에만 사용할 수 있습니다.')
    }

    $null = Invoke-WithDuoForgeRunLock -RunDirectory ([string]$target.runDirectory) -ScriptBlock {
        $lockedTarget = Resolve-DuoForgeRunDeletionTargetInternal -RunId $RunId -ResultsRoot ([string]$target.resultsRoot)
        if ([string]$lockedTarget.status -ne 'CANCELLED') {
            throw (New-DuoForgeException -Code 'DF-RUN-DELETE-STATE' -Message '영구 삭제 직전에 작업 상태가 달라졌습니다.')
        }
        $null = Assert-DuoForgeRunStorageContractInternal -RunDirectory ([string]$lockedTarget.runDirectory)
        return $true
    }

    $deletingRoot = Join-Path ([string]$target.resultsRoot) '.deleting'
    [System.IO.Directory]::CreateDirectory($deletingRoot) | Out-Null
    $quarantinePath = Join-Path $deletingRoot ('{0}-{1}' -f $RunId, [Guid]::NewGuid().ToString('N'))
    $moved = $false
    try {
        [System.IO.Directory]::Move([string]$target.runDirectory, $quarantinePath)
        $moved = $true
        $quarantineReparsePoints = @(Get-ChildItem -LiteralPath $quarantinePath -Recurse -Force -ErrorAction Stop | Where-Object { ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 })
        if ($quarantineReparsePoints.Count -gt 0) {
            throw (New-DuoForgeException -Code 'DF-RUN-DELETE-REPARSE' -Message '삭제 직전 작업 폴더에서 연결 지점이 발견되었습니다.')
        }
        foreach ($file in @(Get-ChildItem -LiteralPath $quarantinePath -File -Recurse -Force -ErrorAction Stop)) {
            if (($file.Attributes -band [System.IO.FileAttributes]::ReadOnly) -ne 0) { $file.Attributes = [System.IO.FileAttributes]::Normal }
        }
        [System.IO.Directory]::Delete($quarantinePath, $true)
        if ((Test-Path -LiteralPath $deletingRoot -PathType Container) -and @(Get-ChildItem -LiteralPath $deletingRoot -Force).Count -eq 0) {
            [System.IO.Directory]::Delete($deletingRoot, $false)
        }
    }
    catch {
        $deleteError = $_
        if ($moved -and (Test-Path -LiteralPath $quarantinePath -PathType Container) -and -not (Test-Path -LiteralPath ([string]$target.runDirectory))) {
            try { [System.IO.Directory]::Move($quarantinePath, [string]$target.runDirectory) } catch { }
        }
        if ((Test-Path -LiteralPath $deletingRoot -PathType Container) -and @(Get-ChildItem -LiteralPath $deletingRoot -Force).Count -eq 0) {
            try { [System.IO.Directory]::Delete($deletingRoot, $false) } catch { }
        }
        if ([string]$deleteError.Exception.Data['DuoForgeCode'] -eq 'DF-RUN-DELETE-REPARSE') { throw $deleteError.Exception }
        throw (New-DuoForgeException -Code 'DF-RUN-DELETE-FAILED' -Message '작업 폴더를 영구 삭제하지 못했습니다. 남은 작업 폴더를 확인해 주세요.')
    }

    return [ordered]@{
        runId = $RunId
        name = [string]$target.name
        status = 'DELETED'
        deleted = $true
    }
}
