function Test-DuoForgeSnapshotIntegrity {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunDirectory)

    $inventory = Read-DuoForgeJson -Path (Join-Path $RunDirectory 'inputs\inventory.json')
    $problems = [System.Collections.Generic.List[string]]::new()
    foreach ($record in @($inventory.snapshots)) {
        $path = Join-Path $RunDirectory ("inputs\snapshots\{0}" -f [string]$record.snapshotName)
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            $problems.Add([string]$record.snapshotName)
            continue
        }
        if ((Get-DuoForgeSha256 -Path $path) -ne [string]$record.snapshotHash) {
            $problems.Add([string]$record.snapshotName)
        }
    }
    return [ordered]@{ valid = $problems.Count -eq 0; invalidSnapshots = @($problems) }
}

function Get-DuoForgeRemainingCallBudget {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunDirectory)

    $manifest = Read-DuoForgeJson -Path (Join-Path $RunDirectory 'manifest.json')
    $stepsPath = Join-Path $RunDirectory 'steps.json'
    if (Test-Path -LiteralPath $stepsPath -PathType Leaf) {
        $graph = Read-DuoForgeJson -Path $stepsPath
    }
    else {
        $firstSynthesizer = if ([string]::IsNullOrWhiteSpace([string]$manifest.firstSynthesizer)) { 'alternate' } else { [string]$manifest.firstSynthesizer }
        $workflowVersion = Get-DuoForgeWorkflowVersionInternal -Manifest $manifest
        $contextPlanPath = Join-Path $RunDirectory 'inputs\context-plan.json'
        $contextBatchCount = if (Test-Path -LiteralPath $contextPlanPath -PathType Leaf) { @((Read-DuoForgeJson -Path $contextPlanPath).batches).Count } else { 0 }
        $contextBatchDocumentIds = @(Get-DuoForgeContextBatchDocumentIdsInternal -RunDirectory $RunDirectory)
        $graph = New-DuoForgeStageGraph -Mode ([string]$manifest.mode) -MaxRounds ([int]$manifest.maxRounds) -FirstSynthesizer $firstSynthesizer -ContextBatchCount $contextBatchCount -ContextBatchDocumentIds $contextBatchDocumentIds -WorkflowVersion $workflowVersion
    }

    $providers = [ordered]@{}
    foreach ($provider in @('codex', 'claude')) {
        $providerSteps = @($graph.steps | Where-Object { $_.provider -eq $provider })
        $remainingSteps = @($providerSteps | Where-Object { $_.status -ne 'COMMITTED' })
        $planned = $providerSteps.Count
        $completed = $planned - $remainingSteps.Count
        $attempted = 0
        foreach ($step in $providerSteps) { $attempted += [int](Get-DuoForgeObjectValue -Object $step -Name 'totalAttemptCount' -Default ([int]$step.attemptCount)) }
        $baseCallsRemaining = @($remainingSteps | Where-Object { [int]$_.attemptCount -eq 0 }).Count
        $retryBudgetRemaining = @($remainingSteps | Where-Object { [int]$_.attemptCount -lt 2 }).Count
        $blockedSteps = @($remainingSteps | Where-Object { [string]$_.status -eq 'FAILED' -and [string]$_.retryMode -in @('RETRY_EXHAUSTED', 'REFERENCE_REPAIR_REQUIRED') })
        $runnableSteps = @($remainingSteps | Where-Object { $_ -notin $blockedSteps })
        $scheduledCallsRemaining = $runnableSteps.Count
        $failureRetryCallsRemaining = @($runnableSteps | Where-Object { [int]$_.attemptCount -eq 0 }).Count
        $maximumPlannedAdditionalCalls = $scheduledCallsRemaining + $failureRetryCallsRemaining
        $providerPlans = Get-DuoForgeObjectValue -Object $manifest.executionPlan -Name 'providers'
        $providerPlan = Get-DuoForgeObjectValue -Object $providerPlans -Name $provider
        $maximum = [int](Get-DuoForgeObjectValue -Object $providerPlan -Name 'maximumCalls' -Default 0)
        $providers[$provider] = [ordered]@{
            plannedRemaining = [Math]::Max(0, $planned - $completed)
            maximumAdditionalCalls = [Math]::Max(0, $maximum - $attempted)
            baseCallsRemaining = $baseCallsRemaining
            retryBudgetRemaining = $retryBudgetRemaining
            scheduledCallsRemaining = $scheduledCallsRemaining
            failureRetryCallsRemaining = $failureRetryCallsRemaining
            maximumPlannedAdditionalCalls = $maximumPlannedAdditionalCalls
            blockedWorkItems = $blockedSteps.Count
            canContinue = $blockedSteps.Count -eq 0
            attempted = $attempted
        }
    }
    return [ordered]@{ providers = $providers }
}

function Invoke-DuoForgeResumeLiveInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [string]$ResultsRoot,
        [Parameter(Mandatory)][bool]$LiveConsent,
        [scriptblock]$ProgressObserver
    )

    if (-not $LiveConsent) {
        throw (New-DuoForgeException -Code 'DF-LIVE-CONSENT' -Message '문서 전송과 AI 작업 시작에 대한 확인이 없습니다.')
    }
    $run = Get-DuoForgeRunInternal -RunId $RunId -ResultsRoot $ResultsRoot
    $directory = [string]$run.runDirectory
    $null = Invoke-WithDuoForgeRunLock -RunDirectory $directory -ScriptBlock { $true }
    $run = Get-DuoForgeRunInternal -RunId $RunId -ResultsRoot $ResultsRoot
    if ([string]$run.manifest.mode -eq 'dual-project-audit') {
        throw (New-DuoForgeException -Code 'DF-PREFLIGHT-3A-ISOLATION' -Message '두 프로젝트 비교 기능은 현재 Windows에서 프로젝트 밖 파일 접근과 추가 프로그램 실행을 충분히 막지 못해 사용할 수 없습니다.')
    }
    $null = Assert-DuoForgeRunStorageContractInternal -RunDirectory $directory
    $null = Assert-DuoForgeProviderSelectionsInternal -Selections (Get-DuoForgeObjectValue -Object $run.manifest -Name 'providerSelections')
    if ([string]$run.state.status -in @('COMPLETED', 'COMPLETED_PARTIAL', 'QUESTION_LIMIT_REACHED', 'FAILED_STAGE', 'SOURCE_DRIFT', 'CANCELLED')) {
        return [ordered]@{ status = [string]$run.state.status; invoked = 0 }
    }
    $pendingPath = Join-Path $directory 'decisions\pending.json'
    $pendingQuestions = @()
    if (Test-Path -LiteralPath $pendingPath -PathType Leaf) {
        $pendingQuestions = @((Read-DuoForgeJson -Path $pendingPath).questions)
    }
    if ($pendingQuestions.Count -gt 0) {
        throw (New-DuoForgeException -Code 'DF-DECISION-PENDING' -Message ("아직 답하지 않은 질문이 {0}개 있습니다. 모두 답한 뒤 다시 검토할 수 있습니다." -f $pendingQuestions.Count))
    }
    $null = Assert-DuoForgeStagePromptPolicyInternal -Manifest $run.manifest

    $integrity = Test-DuoForgeSnapshotIntegrity -RunDirectory ([string]$run.runDirectory)
    if (-not $integrity.valid) {
        throw (New-DuoForgeException -Code 'DF-SNAPSHOT-INTEGRITY' -Message ('실행 스냅샷 무결성 검증에 실패했습니다: ' + ($integrity.invalidSnapshots -join ', ')))
    }

    $doctor = Invoke-DuoForgeDoctorInternal
    if (-not [bool]$doctor.readyForDocumentModes) {
        throw (New-DuoForgeException -Code 'DF-DOCTOR-BLOCKED' -Message '현재 실행 환경에서는 문서 AI 작업을 시작할 수 없습니다. 환경 확인 결과를 먼저 살펴봐 주세요.')
    }

    $providerStageCommand = Get-Command -Name 'Invoke-DuoForgeLiveProviderStage' -CommandType Function -ErrorAction Stop
    $callback = {
        param($step, $prompt, $graph)
        & $providerStageCommand -RunDirectory $directory -Graph $graph -Step $step -Prompt $prompt -LiveConsent $true -ProgressObserver $ProgressObserver
    }.GetNewClosure()
    return Invoke-DuoForgeStageEngine -RunDirectory $directory -ProviderInvoker $callback -ProgressObserver $ProgressObserver
}
