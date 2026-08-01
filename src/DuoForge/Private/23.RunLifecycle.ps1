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
    $recoveryKind = if ($failureCode -eq 'DF-PROMPT-SIZE-LIMIT') { 'prompt-size-repair' }
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
